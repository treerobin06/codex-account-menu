#!/usr/bin/env python3
"""Isolated rollback-lease tests; never touches production launchd jobs."""
import json
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import rollback_guard as guard


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='copilot-guard-test-', dir='/tmp')
        self.ticket = Path(self.directory.name) / 'ticket.json'

    def tearDown(self):
        self.directory.cleanup()

    def lease(self, seconds=.2, state='candidate_ready', owner=None):
        value = {'state': state, 'deadline_monotonic': guard.steady() + seconds,
                 'created_monotonic': guard.steady(), 'deadline_unix': time.time() + seconds,
                 'owner_pid': owner, 'owner_fingerprint': guard.fingerprint(owner) if owner else ''}
        guard.save(self.ticket, value)

    def test_clock_is_shared_across_independent_processes(self):
        before = guard.steady()
        code = 'import time; time.sleep(.05); print(time.clock_gettime(time.CLOCK_MONOTONIC))'
        child = float(subprocess.check_output(['/usr/bin/python3', '-c', code], text=True))
        self.assertGreaterEqual(child, before)
        self.assertLessEqual(child, guard.steady())

    def test_deadline_restores_without_confirmation(self):
        self.lease()
        called = []
        guard.watch(self.ticket, lambda: called.append(1) or {'healthy': True}, poll=.02)
        result = json.loads(self.ticket.read_text())
        self.assertEqual(result['state'], 'rolled_back')
        self.assertEqual(called, [1])
        self.assertGreaterEqual(result['rollback_claimed_at_unix'], result['deadline_unix'])

    def test_explicit_confirmation_prevents_rollback(self):
        self.lease(seconds=2)
        guard.commit(self.ticket)
        guard.watch(self.ticket, lambda: self.fail('Confirmed transition was rolled back'))
        self.assertEqual(json.loads(self.ticket.read_text())['state'], 'committed')

    def test_late_confirmation_is_rejected(self):
        self.lease(seconds=.02)
        time.sleep(.03)
        with self.assertRaises(RuntimeError):
            guard.commit(self.ticket)
        guard.watch(self.ticket, lambda: {'healthy': True}, poll=.02)
        with self.assertRaises(RuntimeError):
            guard.commit(self.ticket)

    def test_old_path_unavailable_keeps_retrying(self):
        self.lease(seconds=0)
        calls = []
        def restore():
            calls.append(1)
            return {'restored': True, 'healthy': len(calls) >= 3}
        guard.watch(self.ticket, restore, poll=.01, retry=.02)
        result = json.loads(self.ticket.read_text())
        self.assertEqual(result['rollback_attempts'], 3)
        self.assertEqual(result['state'], 'rolled_back')

    def test_rollback_request_does_not_wait_for_deadline(self):
        self.lease(seconds=10)
        guard.request_rollback(self.ticket)
        guard.watch(self.ticket, lambda: {'healthy': True}, poll=.01)
        result = json.loads(self.ticket.read_text())
        self.assertLess(result['rollback_finished_at_unix'], result['deadline_unix'])

    def test_stuck_owned_applier_is_terminated(self):
        child = subprocess.Popen(['/bin/sleep', '10'])
        try:
            self.lease(seconds=.1, state='applying', owner=child.pid)
            guard.watch(self.ticket, lambda: {'healthy': True}, poll=.01)
            self.assertEqual(child.wait(timeout=2), -15)
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait()

    def test_unrelated_reused_pid_is_not_terminated(self):
        child = subprocess.Popen(['/bin/sleep', '10'])
        try:
            self.lease(seconds=0, state='applying', owner=child.pid)
            with guard.locked(self.ticket) as data:
                data['owner_fingerprint'] = 'different process'
            guard.watch(self.ticket, lambda: {'healthy': True}, poll=.01)
            self.assertIsNone(child.poll())
        finally:
            child.terminate()
            child.wait()


if __name__ == '__main__':
    unittest.main(verbosity=2)
