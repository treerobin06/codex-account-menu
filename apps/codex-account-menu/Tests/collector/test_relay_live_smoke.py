"""Cleanup regression only: no child processes, credentials, or model calls."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch


SOURCE = Path(__file__).resolve().parents[2] / "scripts/relay-live-smoke.py"
SPEC = importlib.util.spec_from_file_location("relay_live_smoke", SOURCE)
SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SMOKE)


class RelayLiveSmokeCleanupTests(unittest.TestCase):
    def test_native_close_error_still_closes_relay_and_marks_report_failed(self):
        native, relay = Mock(), Mock()
        native.close.side_effect = RuntimeError("fixture close failure")
        native.process.poll.return_value = 0
        relay.close.return_value = True
        report = {"passed": True}
        with patch.object(SMOKE.os, "killpg") as kill:
            SMOKE.cleanup_owned_children(native, relay, report)
        relay.close.assert_called_once_with()
        kill.assert_not_called()
        self.assertFalse(report["passed"])
        self.assertTrue(report["owned_relay_exited"])
        self.assertEqual(report["cleanup_errors"], [{"child": "native", "error": "RuntimeError"}])

    def test_failed_native_recovery_does_not_skip_relay_cleanup(self):
        native, relay = Mock(), Mock()
        native.close.side_effect = RuntimeError("fixture close failure")
        native.process.poll.return_value = None
        relay.close.return_value = True
        report = {"passed": True}
        with patch.object(SMOKE.os, "killpg", side_effect=OSError("fixture signal failure")):
            SMOKE.cleanup_owned_children(native, relay, report)
        relay.close.assert_called_once_with()
        self.assertFalse(report["passed"])
        self.assertFalse(report["owned_native_exited"])
        self.assertTrue(report["owned_relay_exited"])
        self.assertEqual(len(report["cleanup_errors"]), 2)
