#!/usr/bin/env python3
"""Independent, fail-closed cutover lease. No model/API success auto-confirms it."""
from contextlib import contextmanager
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

TERMINAL = ('committed', 'rolled_back')


def steady():
    # macOS Python 3.9 time.monotonic() has a per-process origin. Use the
    # explicit OS clock so the applier and launchd guardian share a deadline.
    return time.clock_gettime(time.CLOCK_MONOTONIC)


def save(path, data):
    temporary = path.with_suffix('.new')
    with open(temporary, 'w') as target:
        os.chmod(temporary, 0o600)
        json.dump(data, target, indent=2)
        target.write('\n')
        target.flush()
        os.fsync(target.fileno())
    temporary.replace(path)


@contextmanager
def locked(path):
    with open(str(path) + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = json.loads(path.read_text())
        yield data
        save(path, data)


def expired(data):
    # Monotonic time protects against clock steps; wall time covers a reboot.
    return (steady() >= data['deadline_monotonic'] or
            time.time() >= data['deadline_unix'] or
            steady() < data['created_monotonic'])


def fingerprint(pid):
    result = subprocess.run(['/bin/ps', '-ww', '-p', str(pid), '-o', 'uid=', '-o', 'lstart=', '-o', 'command='],
                            capture_output=True, text=True, timeout=2,
                            env=dict(os.environ, LC_ALL='C'))
    return result.stdout.strip() if result.returncode == 0 else ''


def active(path, state=None):
    with locked(path) as data:
        if data['state'] not in ('armed', 'applying', 'candidate_ready') or expired(data):
            raise RuntimeError('Cutover lease expired or rollback already claimed')
        if state is not None:
            data['state'] = state


def commit(path):
    with locked(path) as data:
        if data['state'] != 'candidate_ready' or expired(data):
            raise RuntimeError('Cannot confirm an expired or rolled-back cutover')
        data.update(state='committed', confirmed_at_unix=time.time())


def request_rollback(path):
    with locked(path) as data:
        if data['state'] not in TERMINAL:
            data['state'] = 'rollback_requested'


def watch(path, restore, poll=.2, retry=3, terminate_owner=True):
    with locked(path) as data:
        data.update(guard_pid=os.getpid(), guard_parent_pid=os.getppid(), guard_ready_at_unix=time.time())
    while True:
        terminate = None
        with locked(path) as data:
            state = data['state']
            if state in TERMINAL:
                return
            due = expired(data) or state in ('rollback_requested', 'rolling_back')
            if due:
                if state in ('armed', 'applying', 'candidate_ready'):
                    terminate = (data.get('owner_pid'), data.get('owner_fingerprint'))
                data.update(state='rolling_back', rollback_claimed_at_unix=data.get('rollback_claimed_at_unix', time.time()))
        if not due:
            time.sleep(poll)
            continue
        # End only the exact recorded cutover process, never a reused/unrelated PID.
        if terminate_owner and terminate and terminate[0] != os.getpid():
            pid, expected = terminate
            if pid and expected and fingerprint(pid) == expected:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        try:
            result = restore()
            healthy = result.get('healthy', False)
            error = None
        except Exception as exc:
            result, healthy, error = {}, False, str(exc)[-1000:]
        with locked(path) as data:
            data['rollback_attempts'] = data.get('rollback_attempts', 0) + 1
            data['rollback_result'] = result
            data['rollback_error'] = error
            if healthy:
                data.update(state='rolled_back', rollback_finished_at_unix=time.time())
                return
        # The old launchd job is restored before its health is checked. If the
        # network itself is down, keep retrying independently until it recovers.
        time.sleep(retry)


def main():
    os.umask(0o077)
    if len(sys.argv) != 2:
        raise SystemExit('Expected the private transaction ticket path')
    ticket = Path(sys.argv[1]).resolve()
    runtime = (Path.home() / '.local/state/copilot-transport').resolve()
    if ticket.parent != runtime or not ticket.name.startswith('cutover-') or ticket.suffix != '.json':
        raise SystemExit('Refusing a transaction outside the private transport directory')
    source = Path(__file__).resolve().with_name('copilot-link.py')
    spec = importlib.util.spec_from_file_location('copilot_link', source)
    link = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(link)
    watch(ticket, link.restore_old)


if __name__ == '__main__':
    main()
