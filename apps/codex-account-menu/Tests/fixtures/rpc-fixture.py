#!/usr/bin/env python3
"""Synthetic stdio peer. Never contacts a provider or reads real credentials."""
import json
import os
import pathlib
import signal
import sys
import time

home = pathlib.Path(os.environ["CODEX_HOME"])
mode = (home / "fixture-mode").read_text().strip()
closing = False
account_reads = 0

def record(value):
    # Test-only metadata. Never log response bodies or credential values.
    with (home / "fixture-events.jsonl").open("a") as handle:
        handle.write(json.dumps({"pid": os.getpid(), **value}) + "\n")

credential_environment_keys = [
    "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "OPENAI_API_BASE",
    "OPENROUTER_API_KEY", "SJTU_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
    "GITHUB_TOKEN", "GH_TOKEN", "COPILOT_GITHUB_TOKEN",
]
record({"event": "launch", "arguments": sys.argv[1:],
        "environmentKeys": [key for key in credential_environment_keys if key in os.environ]})

def close(*_):
    global closing
    if closing:
        return
    closing = True
    if mode == "slow-exit":
        time.sleep(0.35)
        (home / "exit-write-completed").write_text("done")
    if mode == "early-eof":
        (home / "early-exit-completed").write_text("done")
    raise SystemExit(0)

signal.signal(signal.SIGTERM, close)

def send(value):
    print(json.dumps(value), flush=True)

try:
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        params = request.get("params") or {}
        record({"event": "request", "method": method,
                **{key: params[key] for key in ("includeToken", "refreshToken") if key in params}})
        if mode == "timeout":
            continue
        if mode == "early-eof":
            break
        result = {}
        if method == "config/read":
            if mode in ("effective-config-read-failed", "effective-legacy-auth-conflict"):
                message = "fixture invalid configuration"
                if mode == "effective-legacy-auth-conflict":
                    message = "invalid configuration: provider auth cannot be combined with experimental_bearer_token, requires_openai_auth"
                # Other methods deliberately still report the initialized default
                # ChatGPT identity, reproducing the native false-positive behavior.
                send({"id": request["id"], "error": {"code": -32603, "message": message}})
                continue
            result = {"config": {"model_provider": "copilot"}, "origins": {}}
            if mode.startswith("managed-route-"):
                native = "native" in mode
                result["config"] = {"model_provider": "openai", "openai_base_url": None if native else "http://127.0.0.1:4142/v1"}
                if "wrong-provider" in mode:
                    result["config"]["model_provider"] = "copilot"
                if "wrong-base" in mode:
                    result["config"]["openai_base_url"] = "https://wrong.example.test/v1"
            if mode == "effective-config-read-malformed":
                result["config"] = None
        elif method == "getAuthStatus":
            requires_auth = mode != "effective-no-auth"
            auth_method = None if mode in ("effective-no-auth", "effective-logged-out", "effective-account-omitted") else "chatgpt"
            if mode == "effective-api-key":
                auth_method = "apikey"
            result = {"authMethod": auth_method, "requiresOpenaiAuth": requires_auth, "authToken": None}
            if mode == "effective-token-response":
                result["authToken"] = "fixture-secret-must-never-escape"
            if mode == "effective-missing-requirement":
                del result["requiresOpenaiAuth"]
        elif method == "account/read":
            account_reads += 1
            result = {"account": {"type": "chatgpt", "accountId": "fixture", "email": "fixture@example.test"},
                      "requiresOpenaiAuth": mode != "effective-no-auth"}
            if mode in ("effective-no-auth", "effective-logged-out"):
                result["account"] = None
            elif mode == "effective-api-key":
                result["account"] = {"type": "apiKey"}
            elif mode == "effective-account-omitted":
                del result["account"]
            elif mode == "effective-identity-mismatch":
                result["account"] = {"type": "chatgpt", "accountId": "other-workspace", "email": "fixture@example.test"}
            elif mode.startswith("effective-email-only"):
                del result["account"]["accountId"]
            elif mode == "effective-inconsistent":
                result["requiresOpenaiAuth"] = False
            if mode == "identity-quota-id-conflict":
                result["account"]["accountId"] = "different-workspace"
            if mode == "identity-user-changed" and account_reads >= 2:
                result["account"]["email"] = "different-user@example.test"
            if mode == "identity-missing-email" or (mode == "identity-email-disappears" and account_reads >= 2):
                del result["account"]["email"]
            if mode == "identity-empty-email":
                result["account"]["email"] = " "
            if mode == "effective-email-only-switch-user" and account_reads >= 2:
                result["account"]["email"] = "different-user@example.test"
            if mode == "effective-email-only-switch-workspace" and account_reads >= 2:
                result["account"]["accountId"] = "different-workspace"
        elif method == "account/rateLimits/read":
            if mode == "effective-email-only-error":
                send({"id": request["id"], "error": {"code": 401, "message": "fixture authorization failed"}})
                continue
            result = {"accountId": "fixture", "rateLimits": {
                "primary": {"usedPercent": 33, "windowDurationMins": 300, "resetsAt": 2000000000},
                "secondary": {"usedPercent": 58, "windowDurationMins": 10080, "resetsAt": 2000100000}}}
            if mode == "effective-email-only-no-id":
                del result["accountId"]
            if mode == "identity-quota-empty-id":
                result["accountId"] = ""
        elif method == "account/login/start":
            result = {"authUrl": "https://example.test/login"}
            if mode == "login":
                send({"method": "account/login/completed", "params": {"success": True}})
        if "id" in request:
            send({"id": request["id"], "result": result})
finally:
    close()
