#!/usr/bin/env python3
"""One explicitly authorized Copilot model turn through the bundled native runtime.

Default invocation is a no-model preflight. --live makes one short turn using a
new stdin-owned relay at 4142 -> the existing 4141 proxy. No real auth/config is
read or copied; HOME and CODEX_HOME are temporary, with a deliberately fake key.
The main Desktop is never queried, closed, reopened, or reconfigured. There is
no second turn, destination fallback, or unsandboxed runtime fallback.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
NATIVE = Path("/Applications/ChatGPT.app/Contents/Resources/codex")
NODE = Path("/opt/homebrew/bin/node")
RELAY = ROOT / "Sources/SwitcherCore/Resources/codex-api-relay.mjs"
PORT, UPSTREAM = 4142, 4141
MODEL, MARKER = "gpt-6-astra", "RELAY_SMOKE_OK"
DEADLINE_SECONDS = 60


class SmokeFailure(Exception):
    """Only locally defined, non-secret diagnostics may reach the report."""


def write_private(path, value):
    data = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2)
    with path.open("w", encoding="utf-8") as stream:
        stream.write(data)
    path.chmod(0o600)


def preflight():
    if sys.platform != "darwin" or not Path("/usr/bin/sandbox-exec").is_file():
        raise SmokeFailure("macOS sandbox-exec is required; no unsandboxed fallback")
    for path in (NATIVE, NODE, RELAY):
        if not path.is_file() or not os.access(path, os.R_OK):
            raise SmokeFailure("required local runtime or relay resource is missing")
    # A racing listener is still caught by the child's exclusive listen + ready.
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", PORT))
        except OSError as error:
            raise SmokeFailure("4142 is already occupied; no process was stopped") from error
    try:
        with socket.create_connection(("127.0.0.1", UPSTREAM), timeout=2):
            pass
    except OSError as error:
        raise SmokeFailure("existing 4141 proxy is unavailable; no model was called") from error


class JSONChild:
    def __init__(self, arguments, environment, cwd):
        self.messages, self.trace, self.events = queue.Queue(maxsize=512), [], []
        self.reader_failed = False
        self.process = subprocess.Popen(arguments, env=environment, cwd=cwd,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1, start_new_session=True)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            while line := self.process.stdout.readline(65_537):
                if len(line) > 65_536 or not line.endswith("\n"):
                    raise ValueError("bounded JSONL input")
                message = json.loads(line)
                if len(self.trace) >= 1024:
                    raise ValueError("bounded event count")
                self.trace.append({"id": message.get("id"), "method": message.get("method"),
                    "event": message.get("event"), "error": "error" in message})
                if message.get("event"):
                    # Relay emits only state and path/status/timing metrics.
                    allowed = {"event", "ok", "status", "pid", "port", "host", "baseURL", "enabled",
                        "testMode", "upstreamPort", "controlSocket", "activeRequests", "activeWebSockets",
                        "method", "path", "statusCode", "outcome", "durationMs"}
                    self.events.append({key: val for key, val in message.items() if key in allowed})
                self.messages.put_nowait(message)
        except (ValueError, queue.Full, OSError):
            self.reader_failed = True
        finally:
            try:
                self.messages.put_nowait({"_eof": True})
            except queue.Full:
                self.reader_failed = True

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def receive(self, deadline):
        if self.reader_failed:
            raise SmokeFailure("child JSONL stream exceeded the safe bounds")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SmokeFailure("single-turn deadline expired; no retry was started")
        try:
            message = self.messages.get(timeout=remaining)
        except queue.Empty as error:
            raise SmokeFailure("single-turn deadline expired; no retry was started") from error
        if message.get("_eof"):
            raise SmokeFailure("owned child exited before its expected result")
        return message

    def close(self):
        # This process group was created by this script. Never signal a discovered
        # listener, the existing proxy, the Desktop, or any unrelated user task.
        if self.process.poll() is None:
            try:
                self.process.stdin.close()
                self.process.wait(timeout=2)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(self.process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    self.process.wait(timeout=2)
        self.reader.join(timeout=1)
        return self.process.poll() is not None


class NativeClient(JSONChild):
    def __init__(self, arguments, environment, cwd, deadline):
        super().__init__(arguments, environment, cwd)
        self.sequence, self.pending, self.deadline, self.turn_count = 0, [], deadline, 0
        self.fallback_seen, self.tool_seen = False, False

    def check_event(self, message):
        method = message.get("method", "")
        if "fallback" in method.lower():
            self.fallback_seen = True
            raise SmokeFailure("native runtime announced a fallback; smoke stopped")
        item = message.get("params", {}).get("item", {})
        if method in ("item/started", "item/completed") and item.get("type") not in (
                "userMessage", "agentMessage", "reasoning"):
            self.tool_seen = True
            raise SmokeFailure("unexpected tool or non-message item; smoke stopped")
        if method == "error":
            raise SmokeFailure("native runtime reported a turn error; no retry was requested")

    def rpc(self, method, params):
        if method == "turn/start":
            if self.turn_count:
                raise SmokeFailure("a second turn is forbidden")
            self.turn_count += 1
        self.sequence += 1
        request_id = self.sequence
        self.send({"id": request_id, "method": method, "params": params})
        while True:
            message = self.receive(self.deadline)
            self.check_event(message)
            if message.get("id") == request_id:
                if "error" in message:
                    raise SmokeFailure("native RPC failed: " + method)
                return message["result"]
            self.pending.append(message)

    def generate(self, thread_id):
        result = self.rpc("turn/start", {"threadId": thread_id,
            "input": [{"type": "text", "text": "Reply with exactly " + MARKER + ". Do not use tools."}],
            "effort": "low", "summary": "none"})
        turn_id = result["turn"]["id"]
        deltas, completed, usage = "", {}, None
        while True:
            message = self.pending.pop(0) if self.pending else self.receive(self.deadline)
            self.check_event(message)
            params, method = message.get("params", {}), message.get("method", "")
            if params.get("threadId") not in (None, thread_id) or params.get("turnId") not in (None, turn_id):
                continue
            if method == "item/agentMessage/delta":
                deltas += params.get("delta", "")
                if len(deltas) > 1024:
                    raise SmokeFailure("model output exceeded the short smoke limit")
            elif method == "item/completed" and params.get("item", {}).get("type") == "agentMessage":
                item = params["item"]
                completed[item["id"]] = item.get("text", "")
            elif method == "thread/tokenUsage/updated":
                usage = params.get("tokenUsage", {}).get("last")
            elif method == "turn/completed" and params.get("turn", {}).get("id") == turn_id:
                output = "".join(completed.values()) if completed else deltas
                return {"status": params["turn"].get("status"), "output": output[:1024],
                    "exact_output_match": output.strip() == MARKER, "last_token_usage": usage}


def cleanup_owned_children(native, relay, report):
    # Failure to close one owned child must never skip the other child's cleanup.
    for label, child in (("native", native), ("relay", relay)):
        if child is None:
            continue
        try:
            report["owned_" + label + "_exited"] = child.close()
        except Exception as error:
            report.setdefault("cleanup_errors", []).append({"child": label, "error": type(error).__name__})
            try:
                if child.process.poll() is None:
                    os.killpg(child.process.pid, signal.SIGKILL)
                    child.process.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired) as recovery_error:
                report["cleanup_errors"].append({"child": label, "error": type(recovery_error).__name__})
            report["owned_" + label + "_exited"] = child.process.poll() is not None
        if report.get("cleanup_errors") or not report["owned_" + label + "_exited"]:
            report["passed"] = False
            report.setdefault("error", "owned-process cleanup failed; inspect cleanup_errors")


def verify_network_policy(profile, environment, cwd):
    # The denied target is a live local listener, so ECONNREFUSED cannot be
    # mistaken for a sandbox denial. No HTTP/model request is sent in this check.
    with socket.socket() as forbidden:
        forbidden.bind(("127.0.0.1", 0))
        forbidden.listen(1)
        code = """import errno, socket, sys
with socket.create_connection(('127.0.0.1', 4142), timeout=2): pass
try:
    socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=2)
except OSError as error:
    if error.errno not in (errno.EPERM, errno.EACCES): raise
else:
    raise RuntimeError('unlisted destination allowed')
"""
        result = subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile), sys.executable,
            "-c", code, str(forbidden.getsockname()[1])], env=environment, cwd=cwd,
            capture_output=True, timeout=8)
        if result.returncode:
            raise SmokeFailure("native network allow/deny preflight failed; no model was called")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="Authorize exactly one short Copilot model turn")
    args = parser.parse_args()
    preflight()
    if not args.live:
        print(json.dumps({"preflight": "passed", "model_calls": 0, "live_required": True,
            "route": "native openai -> 127.0.0.1:4142/v1 -> existing 127.0.0.1:4141/v1"}))
        return 0
    os.umask(0o077)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = Path.home() / "Library/Application Support/Codex Account Menu/validation" / (
        "relay-live-" + stamp + "-" + uuid.uuid4().hex[:8])
    output.mkdir(mode=0o700, parents=True)
    work = Path(tempfile.mkdtemp(prefix="relay-live-", dir="/private/tmp"))
    login_home, runtime_home = work / "user-home", work / "codex-home"
    for directory in (login_home, runtime_home):
        directory.mkdir(mode=0o700)
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(login_home),
        "CODEX_HOME": str(runtime_home), "TMPDIR": str(work), "LANG": "en_US.UTF-8",
        "NO_PROXY": "*", "no_proxy": "*", "HTTP_PROXY": "", "HTTPS_PROXY": "", "ALL_PROXY": "",
        "http_proxy": "", "https_proxy": "", "all_proxy": "", "RUST_LOG": "off"}
    write_private(runtime_home / "config.toml", f'''model = "{MODEL}"
model_reasoning_effort = "low"
model_provider = "openai"
openai_base_url = "http://127.0.0.1:{PORT}/v1"
cli_auth_credentials_store = "file"
[features]
apps = false
''')
    write_private(runtime_home / "auth.json", {"auth_mode": "apikey", "OPENAI_API_KEY": "relay-smoke-fake-key"})
    profile = work / "native.sb"
    protected = [Path.home() / path for path in (".codex", ".claude", ".agent-context",
        "Library/Keychains", "Library/Application Support/Codex Account Menu")]
    policy = '(version 1)\n(allow default)\n(deny network*)\n'
    policy += f'(allow network-outbound (remote ip "localhost:{PORT}"))\n'
    policy += '(deny file-read* file-write* ' + ' '.join('(subpath ' + json.dumps(str(path)) + ')' for path in protected) + ')\n'
    write_private(profile, policy)
    report = {"started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "passed": False,
        "scope": "one short new isolated native-runtime turn with synthetic API key; no official OAuth",
        "model": MODEL, "expected_output": MARKER, "turn_limit": 1, "turns_started": 0,
        "route": "builtin openai -> 127.0.0.1:4142/v1 -> existing 127.0.0.1:4141/v1",
        "real_auth_read_or_copied": False, "real_config_changed": False, "main_desktop_operated": False,
        "not_validated": ["ChatGPT OAuth and Remote identity", "main Desktop switch or existing conversations"],
        "deadline_seconds": DEADLINE_SECONDS}
    relay = native = None
    began = time.monotonic()
    write_private(output / "results.json", report)
    try:
        relay = JSONChild([str(NODE), str(RELAY), "--port", str(PORT), "--enabled"], environment, work)
        ready = relay.receive(time.monotonic() + 5)
        if not (ready.get("event") == "ready" and ready.get("pid") == relay.process.pid
                and ready.get("host") == "127.0.0.1" and ready.get("port") == PORT
                and ready.get("upstreamPort") == UPSTREAM and ready.get("enabled") is True
                and ready.get("testMode") is False and ready.get("controlSocket") is None):
            raise SmokeFailure("owned production relay did not announce the exact enabled route")
        report["relay_ready"] = relay.events[-1]
        verify_network_policy(profile, environment, runtime_home)
        report["native_network_policy_verified"] = True
        native = NativeClient(["/usr/bin/sandbox-exec", "-f", str(profile), str(NATIVE),
            "app-server", "--listen", "stdio://"], environment, runtime_home, time.monotonic() + DEADLINE_SECONDS)
        initialized = native.rpc("initialize", {"clientInfo": {"name": "tree_relay_live_smoke", "version": "1.0"},
            "capabilities": {"experimentalApi": True}})
        native.send({"method": "initialized", "params": {}})
        report["native_user_agent"] = initialized.get("userAgent")
        configuration = native.rpc("config/read", {"includeLayers": False}).get("config", {})
        if configuration.get("model_provider") != "openai" or configuration.get("openai_base_url") != f"http://127.0.0.1:{PORT}/v1":
            raise SmokeFailure("effective native config does not use the required local route")
        report["effective_config_verified"] = True
        started = native.rpc("thread/start", {"model": MODEL, "modelProvider": "openai", "cwd": str(runtime_home),
            "ephemeral": True, "sandbox": "read-only", "approvalPolicy": "never",
            "baseInstructions": "Return only the exact supplied marker. Do not use any tools.",
            "developerInstructions": "One short model connectivity check only."})
        if started.get("modelProvider") != "openai" or started.get("model") != MODEL:
            raise SmokeFailure("native thread reported a different model or provider")
        report["turn"] = native.generate(started["thread"]["id"])
        if report["turn"]["status"] != "completed" or not report["turn"]["exact_output_match"]:
            raise SmokeFailure("model turn failed or generated content did not match the expected marker")
        report["passed"] = True
    except SmokeFailure as error:
        report["error"] = str(error)
    except Exception as error:
        report["error"] = "local smoke error: " + type(error).__name__
    finally:
        if native:
            report["turns_started"] = native.turn_count
            report["model_fallback_seen"] = native.fallback_seen
            report["tool_call_seen"] = native.tool_seen
        cleanup_owned_children(native, relay, report)
        if native:
            try:
                write_private(output / "native-trace.json", native.trace)
            except OSError as error:
                report["passed"] = False
                report.setdefault("cleanup_errors", []).append({"artifact": "native-trace", "error": type(error).__name__})
                report.setdefault("error", "could not save the sanitized native trace")
        if relay:
            report["relay_events"] = relay.events
        requests = [event for event in report.get("relay_events", []) if event.get("event") == "request"
            and event.get("path") == "/v1/responses" and event.get("method") in ("POST", "GET")]
        report["relay_transport_request_count"] = len(requests)
        report["relay_transport_count_meaning"] = "HTTP requests or WebSocket handshakes; not generated responses or billing units"
        report["relay_transport_request_verified"] = any(event.get("statusCode") in (200, 101) for event in requests)
        if report["passed"] and (not report["relay_transport_request_verified"] or report["turns_started"] != 1
                or report.get("model_fallback_seen") or report.get("tool_call_seen")):
            report["passed"] = False
            report["error"] = "native result lacked the required relay request evidence or violated the scope"
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=.2):
                report["relay_port_closed"] = False
        except OSError:
            report["relay_port_closed"] = True
        if report["passed"] and not report["relay_port_closed"]:
            report["passed"] = False
            report["error"] = "4142 still accepts connections after owned-process cleanup"
        try:
            shutil.rmtree(work)
        except OSError as error:
            report["passed"] = False
            report.setdefault("cleanup_errors", []).append({"artifact": "temporary-home", "error": type(error).__name__})
            report.setdefault("error", "could not remove the isolated temporary home")
        report["temporary_home_removed"] = not work.exists()
        report["elapsed_seconds"] = round(time.monotonic() - began, 2)
        write_private(output / "results.json", report)
        print(json.dumps({"passed": report["passed"], "turns_started": report["turns_started"],
            "relay_transport_request_count": len(requests), "output": report.get("turn", {}).get("output"),
            "report": str(output / "results.json"), "error": report.get("error")}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SmokeFailure as error:
        print(json.dumps({"passed": False, "turns_started": 0, "error": str(error)}))
        raise SystemExit(1)
