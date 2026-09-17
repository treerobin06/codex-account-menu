import unittest
from health import transition


class HealthTests(unittest.TestCase):
    def test_transient_failure_does_not_notify_and_success_resets_episode(self):
        state, alert = transition({}, {'healthy': False}, 1000, 'boot')
        self.assertFalse(alert)
        state, alert = transition(state, {'healthy': False}, 1060, 'boot')
        self.assertFalse(alert)
        state, alert = transition(state, {'healthy': True}, 1120, 'boot')
        self.assertFalse(alert)
        self.assertEqual(state['consecutive_failures'], 0)
        state, alert = transition(state, {'healthy': False}, 1180, 'boot')
        self.assertFalse(alert)
        self.assertEqual(state['first_failure_monotonic'], 1180)

    def test_sustained_failure_alerts_once_then_cools_down(self):
        state = {}
        for now in (1000, 1060, 1120):
            state, alert = transition(state, {'healthy': False}, now, 'boot')
            self.assertFalse(alert)
        state, alert = transition(state, {'healthy': False}, 1180, 'boot')
        self.assertTrue(alert)
        state['last_alert_attempt_monotonic'] = 1180
        state, alert = transition(state, {'healthy': False}, 1240, 'boot')
        self.assertFalse(alert)
        state, alert = transition(state, {'healthy': False}, 23000, 'boot')
        self.assertTrue(alert)

    def test_reboot_cannot_reuse_an_old_failure_episode(self):
        old = {'boot_id': 'old', 'consecutive_failures': 10, 'first_failure_monotonic': 10}
        state, alert = transition(old, {'healthy': False}, 500, 'new')
        self.assertFalse(alert)
        self.assertEqual(state['consecutive_failures'], 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
