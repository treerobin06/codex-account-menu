#!/usr/bin/env python3
"""Three explicitly authorized real model turns, using isolated account homes.

The current Desktop is never closed here. Full configuration preservation is
checked on a private copy; generation uses the same selected identity/provider
with a minimal config so unrelated MCPs and skills are not started by the test.
Each model turn starts an isolated new thread. This does not validate switching
the main Desktop, its existing conversations, or Remote/cloud tasks.
"""
import argparse
import datetime
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
NATIVE = "/Applications/ChatGPT.app/Contents/Resources/codex"
USER_HOME = Path.home() / ".codex"
RPC_SOURCE = ROOT.parents[1] / "init/copilot-proxy/check-thread-switching.py"


def private_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def minimal_config(provider):
    return ('''model = "gpt-6-astra"
model_reasoning_effort = "low"
model_provider = "PROVIDER"
cli_auth_credentials_store = "file"
[features]
apps = false
[model_providers.copilot]
name = "Copilot proxy"
base_url = "http://127.0.0.1:4141/v1"
wire_api = "responses"
requires_openai_auth = true
experimental_bearer_token = "local"
supports_websockets = true
request_max_retries = 0
stream_max_retries = 0
'''.replace("PROVIDER", provider)).encode()


_KEY = r'''(?:[A-Za-z0-9_-]+|"[^"\\\r\n]*"|'[^'\\\r\n]*')'''
_KEY_PATH = _KEY + r"(?:[ \t]*\.[ \t]*" + _KEY + r")*"
_HEADER = re.compile(r"[ \t]*(\[\[?)[ \t]*(" + _KEY_PATH
                     + r")[ \t]*(\]\]?)[ \t]*(?:#[^\r\n]*)?(?:\r?\n)?\Z")
_ASSIGNMENT = re.compile(r"[ \t]*(" + _KEY_PATH + r")[ \t]*=[ \t]*")
_VALUE = re.compile(r'''(true|false|"[^"\\\r\n]*"|'[^'\\\r\n]*')[ \t]*(?:#[^\r\n]*)?(?:\r?\n)?\Z''')
_PROVIDER = ("model_provider",)
_COPILOT = ("model_providers", "copilot")
_REQUIRES = _COPILOT + ("requires_openai_auth",)
_BEARER = _COPILOT + ("experimental_bearer_token",)
_MANAGED = {_PROVIDER, _REQUIRES, _BEARER}


def _statements(text):
    """Locate TOML statements without interpreting unrelated values."""
    start = i = 0
    quote, multiline, escaped, comment, brackets = None, False, False, False, []
    while i < len(text):
        char = text[i]
        if comment:
            if char == "\n":
                comment = False
        elif quote:
            if escaped:
                escaped = False
            elif quote == '"' and char == "\\":
                escaped = True
            elif multiline and text.startswith(quote * 3, i):
                end = i + 3
                while end < len(text) and text[end] == quote:
                    end += 1
                if end - i > 5:
                    raise ValueError("ambiguous multiline string")
                quote, multiline, i = None, False, end - 1
            elif not multiline and char == quote:
                quote = None
            elif not multiline and char in "\r\n":
                raise ValueError("unterminated string")
        elif char == "#":
            comment = True
        elif char in "\"'":
            quote = char
            multiline = text.startswith(char * 3, i)
            if multiline:
                i += 2
        elif char in "[{":
            brackets.append(char)
        elif char in "]}":
            if not brackets or brackets.pop() != ("]" == char and "[" or "{"):
                raise ValueError("unbalanced brackets")
        if char == "\n" and quote is None and not brackets:
            yield start, i + 1
            start = i + 1
        i += 1
    if quote or brackets:
        raise ValueError("unterminated value")
    if start < len(text):
        yield start, len(text)


def _managed_assignments(text):
    context, fields = (), {}
    for start, end in _statements(text):
        statement = text[start:end]
        if not statement.strip() or statement.lstrip().startswith("#"):
            continue
        if statement.lstrip().startswith("["):
            header = _HEADER.fullmatch(statement)
            if not header or len(header[1]) != len(header[3]):
                raise ValueError("unsupported table header")
            context = tuple(key[1:-1] if key[0] in "\"'" else key
                            for key in re.findall(_KEY, header[2]))
            if context == _PROVIDER or (context[:2] == _COPILOT and len(header[1]) != 1):
                raise ValueError("ambiguous managed table")
            continue
        assignment = _ASSIGNMENT.match(statement)
        if not assignment:
            raise ValueError("unsupported assignment")
        keys = tuple(key[1:-1] if key[0] in "\"'" else key
                     for key in re.findall(_KEY, assignment[1]))
        path = context + keys
        if path not in _MANAGED:
            continue
        if len(keys) != 1 or path in fields:
            raise ValueError("ambiguous managed assignment")
        value = _VALUE.fullmatch(statement[assignment.end():])
        if not value or (path == _REQUIRES) != (value[1] in ("true", "false")):
            raise ValueError("unsupported managed value")
        begin = start + assignment.end()
        decoded = value[1] if path == _REQUIRES else value[1][1:-1]
        fields[path] = (start, end, begin, begin + len(value[1]), decoded)
    return fields


def only_provider_changed(before, after):
    """Allow three managed fields; preserve every other byte, including comments.

    Existing fields cannot disappear. New fields must be complete assignments in
    their exact root/Copilot table; multiline values cannot impersonate fields.
    """
    try:
        a, b = before.decode("utf-8"), after.decode("utf-8")
        if "\0" in a + b:
            return False
        old, new = _managed_assignments(a), _managed_assignments(b)
        if not old.keys() <= new.keys() or _PROVIDER not in new:
            return False
        route = new[_PROVIDER][4]
        if route not in ("openai", "copilot"):
            return False
        for path, expected in ((_REQUIRES, "true"), (_BEARER, "local")):
            changed = path in new and (path not in old or old[path][4] != new[path][4])
            if (route == "copilot" or changed) and (path not in new or new[path][4] != expected):
                return False

        def untouched(text, fields):
            edits = []
            for path, (start, end, begin, finish, _) in fields.items():
                edits.append((begin, finish, "\0" + ".".join(path) + "\0") if path in old
                             else (start, end, ""))
            for start, end, replacement in sorted(edits, reverse=True):
                text = text[:start] + replacement + text[end:]
            return text

        return untouched(a, old) == untouched(b, new)
    except (UnicodeDecodeError, ValueError):
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", required=True,
                        help="Authorize exactly three short generation turns")
    parser.add_argument("--cli", default=str(ROOT / ".build/debug/codex-menu"))
    args = parser.parse_args()
    os.umask(0o077)
    stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    report_dir = Path.home() / "Library/Application Support/Codex Account Menu/validation" / stamp
    report_dir.mkdir(parents=True, mode=0o700)
    work = Path(tempfile.mkdtemp(prefix="codex-menu-live-", dir="/tmp"))
    switch_home, state, generation_home = [work / name for name in ("switch-home", "state", "generation-home")]
    for path in (switch_home, state, generation_home):
        path.mkdir(mode=0o700)
    lock = os.open(USER_HOME / ".codex-account-menu.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    config_before = (USER_HOME / "config.toml").read_bytes()
    auth_before = (USER_HOME / "auth.json").read_bytes()
    original_account = json.loads(auth_before)["tokens"]["account_id"]
    private_write(report_dir / "original-config.toml", config_before)
    private_write(report_dir / "original-auth.json", auth_before)
    private_write(switch_home / "config.toml", config_before)
    private_write(switch_home / "auth.json", auth_before)
    spec = importlib.util.spec_from_file_location("menu_smoke_rpc", RPC_SOURCE)
    rpc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rpc)
    rpc.CODEX = NATIVE
    original_environment = dict(os.environ)
    for name in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "OPENAI_API_BASE"):
        os.environ.pop(name, None)
    report = {"started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "scope": "exactly three isolated new native-runtime threads with real model responses; "
                       "copied config only; main Desktop switching, existing conversations and Remote/cloud tasks are not validated",
              "steps": [], "private_work": str(work), "report_directory": str(report_dir)}

    def cli(*words):
        command = [args.cli, *words, "--home", str(switch_home), "--state", str(state)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=80)
        if result.returncode:
            raise RuntimeError("CLI operation failed: " + result.stdout[:800])
        return json.loads(result.stdout)

    try:
        profiles = cli("import-current")
        profile = next(p for p in profiles if p["accountID"] == original_account)
        for index, provider in enumerate(("copilot", "openai", "copilot"), 1):
            target = "copilot" if provider == "copilot" else profile["id"]
            selected = cli("switch", target, "--isolated")
            assert selected["provider"] == provider
            assert cli("status")["provider"] == provider
            assert only_provider_changed(config_before, (switch_home / "config.toml").read_bytes())
            private_write(generation_home / "config.toml", minimal_config(provider))
            private_write(generation_home / "auth.json", (switch_home / "auth.json").read_bytes())
            os.environ["CODEX_HOME"] = str(generation_home)
            client = rpc.Client(report_dir, "request-" + str(index))
            marker = "MENU_" + provider.upper() + "_" + uuid.uuid4().hex[:8]
            try:
                result = client.rpc("thread/start", {
                    "model": "gpt-6-astra", "modelProvider": provider,
                    "cwd": str(generation_home), "ephemeral": True,
                    "sandbox": "read-only", "approvalPolicy": "never",
                    "baseInstructions": "Follow the requested exact output. Do not use tools.",
                    "developerInstructions": "Connectivity check only. Return the supplied marker.",
                })
                assert result["modelProvider"] == provider
                item = client.generate(result["thread"]["id"], "只回复这个校验词，不要调用工具：" + marker, marker)
                item.update(provider=provider, expected=marker, config_preserved=True,
                            validation_scope="isolated_new_thread")
                report["steps"].append(item)
                private_write(report_dir / "results.json", json.dumps(report, ensure_ascii=False, indent=2).encode())
                if not item["passed"]:
                    raise RuntimeError("Model check failed; remaining requests were not started")
            finally:
                client.close()
            newest = (generation_home / "auth.json").read_bytes()
            assert json.loads(newest)["tokens"]["account_id"] == original_account
            private_write(switch_home / "auth.json", newest)
        report["passed"] = True
    except Exception as error:
        report["passed"] = False
        report["error"] = str(error)[:1500]
    finally:
        os.environ.clear()
        os.environ.update(original_environment)
        report["global_config_unchanged"] = (USER_HOME / "config.toml").read_bytes() == config_before
        refreshed = (switch_home / "auth.json").read_bytes()
        original_tokens = json.loads(auth_before)["tokens"]
        refreshed_data = json.loads(refreshed)
        if refreshed_data.get("tokens", {}).get("account_id") == original_account and refreshed_data["tokens"] != original_tokens:
            private_write(report_dir / "refreshed-auth.json", refreshed)
            if (USER_HOME / "auth.json").read_bytes() == auth_before and report.get("passed"):
                private_write(USER_HOME / "auth.json", refreshed)
                report["same_account_native_refresh_synchronized"] = True
            else:
                report["refreshed_credential_preserved_for_review"] = True
        report["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        private_write(report_dir / "results.json", json.dumps(report, ensure_ascii=False, indent=2).encode())
        fcntl.flock(lock, fcntl.LOCK_UN)
        os.close(lock)
        print(json.dumps({"passed": report.get("passed"), "steps": len(report["steps"]),
                          "global_config_unchanged": report["global_config_unchanged"],
                          "report": str(report_dir / "results.json"), "error": report.get("error")}, ensure_ascii=False), flush=True)
    return 0 if report.get("passed") and report["global_config_unchanged"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
