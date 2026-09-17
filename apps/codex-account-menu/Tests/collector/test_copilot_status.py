#!/usr/bin/env python3
import contextlib
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch
import urllib.error

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[2] / "Sources/SwitcherCore/Resources/copilot-status.py"
SPEC = importlib.util.spec_from_file_location("copilot_status", SCRIPT)
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)

FIXTURE_SECRET = "DO_NOT_LEAK_FIXTURE_SECRET"
OBSERVED = dt.datetime(2026, 9, 16, 8, 30, 15, 123000, tzinfo=dt.timezone.utc)


def fixture():
    return {
        "user": {"login": "fixture-user", "token": FIXTURE_SECRET, "email": "private@example.invalid"},
        "usage": {
            "copilot_plan": "enterprise",
            "token_based_billing": True,
            "quota_reset_date_utc": "2026-10-01T00:00:00Z",
            "quota_reset_date": "2026-09-30",
            "quota_snapshots": {
                "premium_interactions": {
                    "percent_remaining": 96.6,
                    "remaining": 966334,
                    "quota_remaining": 966334.6,
                    "entitlement": 1000000,
                    "credits_used": 33457,
                    "overage_permitted": True,
                    "token": FIXTURE_SECRET,
                }
            },
        },
    }


class NormalizeTests(unittest.TestCase):
    def test_exact_percent_utc_and_output_whitelist(self):
        data = fixture()
        result = collector.normalize(data["user"], data["usage"], OBSERVED)
        self.assertEqual(result, {
            "observedAt": "2026-09-16T08:30:15.123Z",
            "login": "fixture-user",
            "plan": "enterprise",
            "remainingPercent": 96.6,
            "resetsAt": "2026-10-01T00:00:00.000Z",
            "tokenBasedBilling": True,
            "overagePermitted": True,
            "modelsAvailable": None,
        })
        encoded = json.dumps(result)
        for excluded in ("966334", "1000000", "33457", "private@example.invalid", FIXTURE_SECRET):
            self.assertNotIn(excluded, encoded)

    def test_no_percent_is_unknown_even_when_integer_quota_exists(self):
        data = fixture()
        del data["usage"]["quota_snapshots"]["premium_interactions"]["percent_remaining"]
        result = collector.normalize(data["user"], data["usage"])
        self.assertIsNone(result["remainingPercent"])

    def test_zero_and_outside_normal_range_are_not_clamped(self):
        for value in (0, 100, -1.25, 102.75):
            with self.subTest(value=value):
                data = fixture()
                data["usage"]["quota_snapshots"]["premium_interactions"]["percent_remaining"] = value
                self.assertEqual(collector.normalize(data["user"], data["usage"])["remainingPercent"], value)

    def test_invalid_percent_types_are_null(self):
        for value in (None, True, "96.6", float("nan"), float("inf"), 10 ** 1000, {}, []):
            with self.subTest(value=type(value).__name__):
                data = fixture()
                data["usage"]["quota_snapshots"]["premium_interactions"]["percent_remaining"] = value
                result = collector.normalize(data["user"], data["usage"])
                self.assertIsNone(result["remainingPercent"])
                json.dumps(result, allow_nan=False)

    def test_missing_snapshot_does_not_invent_unlimited_or_zero(self):
        data = fixture()
        data["usage"]["quota_snapshots"] = None
        result = collector.normalize(data["user"], data["usage"])
        self.assertIsNone(result["remainingPercent"])
        self.assertFalse(result["overagePermitted"])

    def test_reset_fallback_and_timezone_conversion(self):
        data = fixture()
        data["usage"]["quota_reset_date_utc"] = "invalid"
        self.assertEqual(collector.normalize(data["user"], data["usage"])["resetsAt"], "2026-09-30T00:00:00.000Z")
        data["usage"]["quota_reset_date_utc"] = "2026-10-01T08:00:00.125+08:00"
        self.assertEqual(collector.normalize(data["user"], data["usage"])["resetsAt"], "2026-10-01T00:00:00.125Z")
        data["usage"]["quota_reset_date_utc"] = None
        data["usage"]["quota_reset_date"] = "not-a-date"
        self.assertIsNone(collector.normalize(data["user"], data["usage"])["resetsAt"])

    def test_naive_timestamp_not_assumed_local_timezone(self):
        self.assertIsNone(collector.utc_timestamp("2026-10-01T00:00:00"))
        self.assertIsNone(collector.utc_timestamp(True))

    def test_missing_identity_or_plan_fails_without_payload(self):
        for user, usage in (({}, fixture()["usage"]), (fixture()["user"], {})):
            with self.assertRaises(collector.CollectorError) as caught:
                collector.normalize(user, usage)
            self.assertEqual(str(caught.exception), "invalid_upstream_response")


class CredentialParsingTests(unittest.TestCase):
    def test_jsonc_preserves_urls_quotes_and_comment_like_token(self):
        source = r'''
        {
          // selected account
          "lastLoggedInUser": {"host": "https://github.com", "login": "fixture-user", /* end */},
          "authTokens": {
            "https://github.com:fixture-user": {"token": "fake//token/*literal*/",},
          },
          "quoted": "quote: \" // literal",
        }
        '''
        data = collector.parse_jsonc(source)
        self.assertEqual(data["quoted"], 'quote: " // literal')
        self.assertEqual(collector.selected_credential(data), ("fixture-user", "fake//token/*literal*/"))

    def test_bad_json_does_not_include_raw_credential(self):
        with self.assertRaises(collector.CollectorError) as caught:
            collector.parse_jsonc('{"token":"' + FIXTURE_SECRET)
        self.assertEqual(str(caught.exception), "credentials_unavailable")

    def test_unknown_host_does_not_send_its_token_to_github(self):
        data = {"lastLoggedInUser": {"host": "https://private.example.invalid", "login": "fixture-user"}}
        with self.assertRaises(collector.CollectorError) as caught:
            collector.selected_credential(data)
        self.assertEqual(str(caught.exception), "unsupported_account_host")

    def test_proxy_values_are_escaped_without_shell_evaluation(self):
        result = collector.proxy_url("DIRECT_USER=fixture@direct\nDIRECT_PASS=fake:/@pass\n")
        self.assertEqual(result, "http://fixture%40direct:fake%3A%2F%40pass@127.0.0.1:17998")

    def test_missing_proxy_credentials_use_fixed_error(self):
        with self.assertRaises(collector.CollectorError) as caught:
            collector.proxy_url("UNRELATED=" + FIXTURE_SECRET)
        self.assertEqual(str(caught.exception), "proxy_unavailable")


class PublicDefaultsTests(unittest.TestCase):
    def test_default_paths_and_ssh_alias_are_user_owned_configuration(self):
        self.assertEqual(collector.CONFIG_PATH, Path.home() / ".copilot/config.json")
        self.assertEqual(collector.PROXY_PATH, Path("/etc/copilot-proxy/network.env"))
        source = SCRIPT.parent.parent / "CopilotUsage.swift"
        match = collector.re.search(r'public init\(sshHost: String = "([^"]+)"', source.read_text())
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), "copilot-server")

    def test_missing_optional_network_proxy_uses_direct_requests(self):
        config = {"lastLoggedInUser": {"host": "https://github.com", "login": "fixture-user"},
                  "authTokens": {"https://github.com:fixture-user": {"token": FIXTURE_SECRET}}}
        with tempfile.TemporaryDirectory() as directory:
            credentials = Path(directory) / "config.json"
            credentials.write_text(json.dumps(config))
            with patch.object(collector, "CONFIG_PATH", credentials), \
                 patch.object(collector, "PROXY_PATH", Path(directory) / "missing-network.env"), \
                 patch.object(collector.urllib.request, "build_opener") as build, \
                 patch.object(collector, "get_json", side_effect=[fixture()["user"], fixture()["usage"]]):
                result = collector.collect()
            self.assertEqual(build.call_args.args[0].proxies, {})
            self.assertEqual(result["login"], "fixture-user")

    def test_invalid_explicit_network_proxy_does_not_fall_back(self):
        with tempfile.TemporaryDirectory() as directory:
            network = Path(directory) / "network.env"
            network.write_text("invalid=fixture")
            with patch.object(collector, "PROXY_PATH", network), \
                 patch.object(collector, "selected_credential", return_value=("fixture-user", FIXTURE_SECRET)), \
                 patch.object(collector, "parse_jsonc", return_value={}), \
                 patch.object(collector, "read_bounded", return_value="invalid=fixture"), \
                 patch.object(collector, "get_json") as get:
                with self.assertRaises(collector.CollectorError) as caught:
                    collector.collect()
            self.assertEqual(str(caught.exception), "proxy_unavailable")
            get.assert_not_called()


class BoundaryTests(unittest.TestCase):
    def test_http_errors_never_forward_response_or_url(self):
        class Opener:
            def open(self, *args, **kwargs):
                raise urllib.error.HTTPError(
                    "https://example.invalid/" + FIXTURE_SECRET, 401,
                    FIXTURE_SECRET, {}, io.BytesIO(FIXTURE_SECRET.encode()),
                )
        with self.assertRaises(collector.CollectorError) as caught:
            collector.get_json(Opener(), "/user", FIXTURE_SECRET)
        self.assertEqual(str(caught.exception), "authentication_failed")

    def test_redirects_are_not_followed(self):
        self.assertIsNone(collector.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid"))

    def test_unexpected_exception_is_only_a_fixed_json_error(self):
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(collector, "collect", side_effect=RuntimeError(FIXTURE_SECRET)):
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                self.assertEqual(collector.main([]), 1)
        self.assertEqual(json.loads(output.getvalue()), {"error": {"code": "collector_failed"}})
        self.assertEqual(errors.getvalue(), "")
        self.assertNotIn(FIXTURE_SECRET, output.getvalue())

    def test_fixture_cli_is_strict_json_and_never_touches_credentials(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--fixture", "-"],
            input=json.dumps(fixture()), text=True, capture_output=True, timeout=4,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        status = json.loads(result.stdout)
        self.assertEqual(status["remainingPercent"], 96.6)
        self.assertTrue(status["observedAt"].endswith("Z"))
        self.assertNotIn(FIXTURE_SECRET, result.stdout)

    def test_bad_fixture_does_not_echo_input(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--fixture", "-"],
            input=FIXTURE_SECRET, text=True, capture_output=True, timeout=4,
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "")
        self.assertEqual(json.loads(result.stdout), {"error": {"code": "collector_failed"}})


if __name__ == "__main__":
    unittest.main()
