#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only Copilot status. Credentials never leave this process.

Production: pass this file to ssh copilot-server 'sudo -n python3 -' on stdin.
Tests: python3 copilot-status.py --fixture fixture.json (or --fixture -).
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import argparse
import datetime as dt
import json
import math
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request


CONFIG_PATH = Path.home() / ".copilot/config.json"
PROXY_PATH = Path("/etc/copilot-proxy/network.env")
MAX_BYTES = 1_048_576
REQUEST_TIMEOUT = 9


class CollectorError(Exception):
    """Only a fixed, non-sensitive code is allowed across the SSH boundary."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


def parse_jsonc(source: str) -> dict:
    """Strip JSONC comments/trailing commas without altering quoted strings."""
    source = source.lstrip("\ufeff")
    output = []
    index = 0
    quoted = False
    escaped = False
    while index < len(source):
        char = source[index]
        if quoted:
            output.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            index += 1
        elif char == '"':
            quoted = True
            output.append(char)
            index += 1
        elif source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
        elif source.startswith("/*", index):
            end = source.find("*/", index + 2)
            if end < 0:
                raise CollectorError("credentials_unavailable")
            output.append(" ")
            index = end + 2
        elif char == ",":
            lookahead = index + 1
            while lookahead < len(source) and source[lookahead].isspace():
                lookahead += 1
            if lookahead == len(source) or source[lookahead] not in "}]":
                output.append(char)
            index += 1
        else:
            output.append(char)
            index += 1
    # A comment can occur between a trailing comma and the closing delimiter.
    cleaned = "".join(output)
    if cleaned != source:
        return parse_jsonc(cleaned)
    try:
        result = json.loads(cleaned)
    except (ValueError, TypeError):
        raise CollectorError("credentials_unavailable") from None
    if not isinstance(result, dict):
        raise CollectorError("credentials_unavailable")
    return result


def utc_timestamp(value) -> str | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value.strip()):
                return None
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    except (ValueError, OverflowError):
        return None


def normalize(user: dict, usage: dict, observed_at: dt.datetime | None = None) -> dict:
    """Project upstream data onto a whitelist; never infer request/credit units."""
    if not isinstance(user, dict) or not isinstance(usage, dict):
        raise CollectorError("invalid_upstream_response")
    login = user.get("login")
    plan = usage.get("copilot_plan")
    if not isinstance(login, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,99}", login):
        raise CollectorError("invalid_upstream_response")
    if not isinstance(plan, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", plan):
        raise CollectorError("invalid_upstream_response")
    snapshots = usage.get("quota_snapshots")
    premium = snapshots.get("premium_interactions") if isinstance(snapshots, dict) else None
    premium = premium if isinstance(premium, dict) else {}
    percent = premium.get("percent_remaining")
    try:
        valid_percent = not isinstance(percent, bool) and isinstance(percent, (float, int)) and math.isfinite(percent)
    except OverflowError:
        valid_percent = False
    if not valid_percent:
        percent = None
    resets = utc_timestamp(usage.get("quota_reset_date_utc")) or utc_timestamp(usage.get("quota_reset_date"))
    observed = observed_at or dt.datetime.now(dt.timezone.utc)
    if observed.tzinfo is None:
        raise CollectorError("invalid_upstream_response")
    return {
        "observedAt": observed.astimezone(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "login": login,
        "plan": plan,
        "remainingPercent": percent,
        "resetsAt": resets,
        "tokenBasedBilling": usage.get("token_based_billing") is True,
        "overagePermitted": premium.get("overage_permitted") is True,
        "modelsAvailable": None,
    }


def read_bounded(path: Path) -> str:
    try:
        with path.open("rb") as handle:
            raw = handle.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise CollectorError("credentials_unavailable")
        return raw.decode("utf-8-sig")
    except (OSError, UnicodeError):
        raise CollectorError("credentials_unavailable") from None


def selected_credential(config: dict) -> tuple[str, str]:
    try:
        account = config["lastLoggedInUser"]
        host = account["host"]
        login = account["login"]
        if host.rstrip("/") not in ("github.com", "https://github.com"):
            raise CollectorError("unsupported_account_host")
        token = config["authTokens"][host + ":" + login]["token"]
        if not isinstance(token, str) or not token or len(token) > 16_384 or any(c.isspace() for c in token):
            raise CollectorError("credentials_unavailable")
        return login, token
    except (KeyError, TypeError, AttributeError):
        raise CollectorError("credentials_unavailable") from None


def proxy_url(source: str) -> str:
    entries = dict(line.split("=", 1) for line in source.splitlines() if "=" in line and not line.lstrip().startswith("#"))
    try:
        user, password = entries["DIRECT_USER"], entries["DIRECT_PASS"]
        if not user or not password:
            raise CollectorError("proxy_unavailable")
        return "http://" + urllib.parse.quote(user, safe="") + ":" + urllib.parse.quote(password, safe="") + "@127.0.0.1:17998"
    except KeyError:
        raise CollectorError("proxy_unavailable") from None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        # Never forward an OAuth bearer to a redirected origin.
        return None


def get_json(opener, path: str, token: str) -> dict:
    request = urllib.request.Request(
        "https://api.github.com" + path,
        headers={"Authorization": "Bearer " + token, "Accept": "application/json", "User-Agent": "codex-account-menu/1.0"},
    )
    try:
        with opener.open(request, timeout=REQUEST_TIMEOUT) as response:
            data = response.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise CollectorError("invalid_upstream_response")
        result = json.loads(data)
        if not isinstance(result, dict):
            raise CollectorError("invalid_upstream_response")
        return result
    except urllib.error.HTTPError as error:
        if error.code in (401, 403):
            raise CollectorError("authentication_failed") from None
        if error.code == 429:
            raise CollectorError("rate_limited") from None
        raise CollectorError("upstream_unavailable") from None
    except (urllib.error.URLError, OSError):
        raise CollectorError("upstream_unavailable") from None
    except (ValueError, UnicodeError):
        raise CollectorError("invalid_upstream_response") from None


def collect() -> dict:
    expected_login, token = selected_credential(parse_jsonc(read_bounded(CONFIG_PATH)))
    # A remote network proxy is optional. If explicitly configured, malformed
    # credentials remain an error; never silently fall back after a bad file.
    proxies = {"https": proxy_url(read_bounded(PROXY_PATH))} if PROXY_PATH.exists() else {}
    opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies), NoRedirect())
    user = get_json(opener, "/user", token)
    if not isinstance(user.get("login"), str) or user["login"].casefold() != expected_login.casefold():
        raise CollectorError("identity_mismatch")
    usage = get_json(opener, "/copilot_internal/user", token)
    return normalize(user, usage)


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise CollectorError("invalid_arguments")


def main(argv=None) -> int:
    try:
        parser = SafeArgumentParser(description=__doc__)
        parser.add_argument("--fixture", nargs="?", const="-")
        args = parser.parse_args(argv)
        if args.fixture is not None:
            raw = sys.stdin.read(MAX_BYTES + 1) if args.fixture == "-" else read_bounded(Path(args.fixture))
            if len(raw.encode("utf-8")) > MAX_BYTES:
                raise CollectorError("invalid_fixture")
            fixture = json.loads(raw)
            result = normalize(fixture["user"], fixture["usage"])
        else:
            result = collect()
        print(json.dumps(result, ensure_ascii=True, allow_nan=False, separators=(",", ":")))
        return 0
    except CollectorError as error:
        print(json.dumps({"error": {"code": error.code}}, separators=(",", ":")))
        return 1
    except Exception:
        # Never serialize an upstream body, credential file, URL, or exception text.
        print('{"error":{"code":"collector_failed"}}')
        return 1


if __name__ == "__main__":
    sys.exit(main())
