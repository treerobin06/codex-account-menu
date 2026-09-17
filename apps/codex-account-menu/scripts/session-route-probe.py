#!/usr/bin/env python3
"""Probe one persisted synthetic thread across a metadata-only provider migration.

Exactly two turn attempts use fake credentials and local HTTP 400 responders.
macOS sandbox-exec permits the native runtime to reach only the two responder
ports; all other networking is denied. No real model or existing user thread is
used. This verifies request routing, not successful generation or encrypted
reasoning compatibility. Run after building codex-menu's isolated sync command.
"""
import argparse
import datetime
import hashlib
import http.server
import json
import os
from pathlib import Path
import queue
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_NATIVE = Path("/Applications/ChatGPT.app/Contents/Resources/codex")
MODEL = "gpt-6-astra"


def write_private(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("wb") as stream:
        stream.write(data)
    path.chmod(0o600)


class RejectingServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), RejectingHandler)
        self.requests = []
        self.lock = threading.Lock()

    @property
    def port(self):
        return self.server_address[1]

    def response_requests(self):
        with self.lock:
            return [item for item in self.requests
                    if item["method"] in ("POST", "GET") and item["path"].split("?")[0].endswith("/responses")]


class RejectingHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reject(self):
        length = min(int(self.headers.get("Content-Length", "0")), 4 * 1024 * 1024)
        body = self.rfile.read(length) if length else b""
        entry = {"method": self.command, "path": self.path, "status": 400,
                 "websocket_upgrade": self.headers.get("Upgrade", "").lower() == "websocket",
                 "body_bytes": len(body), "body_sha256": hashlib.sha256(body).hexdigest()}
        with self.server.lock:
            self.server.requests.append(entry)
        payload = json.dumps({"error": {"type": "invalid_request_error", "code": "route_probe",
                                       "message": "Intentional local route probe rejection; no model was called."}}).encode()
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    do_POST = reject
    do_GET = reject


class NativeClient:
    def __init__(self, native, home, profile, environment, output, label):
        self.sequence = 0
        self.queue = queue.Queue()
        self.pending = []
        self.trace = []
        self.last_method = "startup"
        self.trace_path = output / (label + ".rpc-trace.json")
        self.log = (output / (label + ".stderr.log")).open("w")
        self.process = subprocess.Popen(
            ["/usr/bin/sandbox-exec", "-f", str(profile), str(native), "app-server", "--listen", "stdio://"],
            cwd=home, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.log, text=True, bufsize=1,
        )
        threading.Thread(target=self._read, daemon=True).start()
        try:
            self.rpc("initialize", {"clientInfo": {"name": "session_route_probe", "version": "1.0"},
                                    "capabilities": {"experimentalApi": True}})
            self.send({"method": "initialized", "params": {}})
        except BaseException:
            self.close()
            raise

    def _read(self):
        for line in self.process.stdout:
            try:
                message = json.loads(line)
                self.trace.append({"id": message.get("id"), "method": message.get("method"),
                                   "result": "result" in message, "error": "error" in message})
                self.queue.put(message)
            except json.JSONDecodeError:
                continue
        self.queue.put({"_eof": True})

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def receive(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("native runtime response deadline: " + self.last_method)
        try:
            message = self.queue.get(timeout=remaining)
        except queue.Empty as error:
            raise TimeoutError("native runtime response deadline: " + self.last_method) from error
        if message.get("_eof"):
            raise RuntimeError("private native runtime exited")
        return message

    def rpc(self, method, params):
        self.last_method = method
        self.sequence += 1
        request_id = self.sequence
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 35
        while True:
            message = self.receive(deadline)
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(method + ": " + json.dumps(message["error"], ensure_ascii=False)[:1200])
                return message["result"]
            self.pending.append(message)

    def rejected_turn(self, thread_id, marker):
        result = self.rpc("turn/start", {
            "threadId": thread_id, "input": [{"type": "text", "text": marker}],
            "effort": "low", "summary": "none",
        })
        turn_id = result["turn"]["id"]
        deadline = time.monotonic() + 35
        while True:
            message = self.pending.pop(0) if self.pending else self.receive(deadline)
            params = message.get("params", {})
            if message.get("method") == "turn/completed" and params.get("turn", {}).get("id") == turn_id:
                turn = params["turn"]
                if turn.get("status") != "failed":
                    raise RuntimeError("local HTTP 400 turn did not fail as expected")
                return {"thread_id": thread_id, "turn_id": turn_id, "status": turn["status"],
                        "error": turn.get("error")}

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.close()
                self.process.wait(timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
        self.log.close()
        write_private(self.trace_path, json.dumps(self.trace, indent=2).encode())


def configuration(provider, old_port, new_port):
    return f'''model = "{MODEL}"
model_reasoning_effort = "low"
model_provider = "{provider}"
openai_base_url = "http://127.0.0.1:{new_port}/v1"
cli_auth_credentials_store = "file"
[features]
apps = false
responses_websockets = false
responses_websockets_v2 = false
[model_providers.copilot]
name = "Synthetic route probe"
base_url = "http://127.0.0.1:{old_port}/v1"
wire_api = "responses"
requires_openai_auth = false
experimental_bearer_token = "route-probe-fake-key"
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
'''.encode()


def stored_thread(home, thread_id):
    paths = [home / "state_5.sqlite", home / "sqlite/state_5.sqlite"]
    rows = []
    for path in paths:
        if not path.is_file() or path.suffix not in (".db", ".sqlite", ".sqlite3"):
            continue
        with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
            columns = {column[1] for column in db.execute("PRAGMA table_info(threads)")}
            if {"id", "model_provider", "rollout_path"} <= columns:
                row = db.execute("SELECT id,model_provider,rollout_path FROM threads WHERE id=?", (thread_id,)).fetchone()
                if row:
                    rows.append({"database": str(path), "id": row[0], "provider": row[1], "rollout": row[2]})
    if not rows:
        raise RuntimeError("native runtime did not persist the synthetic thread")
    return rows


def config_evidence(client, expected_provider, old_port, new_port):
    result = client.rpc("config/read", {"includeLayers": False})
    config = result.get("config", {})
    provider = config.get("model_providers", {}).get("copilot", {})
    bearer = provider.get("experimental_bearer_token")
    evidence = {
        "model_provider": config.get("model_provider"),
        "openai_base_url": config.get("openai_base_url"),
        "copilot": {"base_url": provider.get("base_url"),
                    "requires_openai_auth": provider.get("requires_openai_auth"),
                    "bearer_field_present": "experimental_bearer_token" in provider,
                    "bearer_is_plain_synthetic_value": bearer == "route-probe-fake-key",
                    "bearer_representation": bearer if bearer in (None, "route-probe-fake-key", "<redacted>", "[REDACTED]", "***") else "present; not echoed"},
    }
    # These are wholly synthetic values. Do not echo an unexpected inherited URL.
    if evidence["model_provider"] != expected_provider:
        evidence["model_provider"] = "unexpected or missing"
    if evidence["openai_base_url"] != f"http://127.0.0.1:{new_port}/v1":
        evidence["openai_base_url"] = "unexpected or missing"
    if evidence["copilot"]["base_url"] != f"http://127.0.0.1:{old_port}/v1":
        evidence["copilot"]["base_url"] = "unexpected or missing"
    return evidence


def verify_network_policy(profile, environment, permitted_port):
    # A listening third loopback port must be denied, so a timeout or missing
    # remote service cannot masquerade as proof that the sandbox blocks traffic.
    with socket.socket() as forbidden:
        forbidden.bind(("127.0.0.1", 0))
        forbidden.listen(1)
        code = """import errno, socket, sys
with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=2): pass
try:
    socket.create_connection(('127.0.0.1', int(sys.argv[2])), timeout=2)
except OSError as error:
    if error.errno not in (errno.EPERM, errno.EACCES): raise
else:
    raise RuntimeError('sandbox allowed an unlisted destination')
"""
        subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile), sys.executable, "-c", code,
                        str(permitted_port), str(forbidden.getsockname()[1])],
                       env=environment, capture_output=True, text=True, check=True, timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, default=DEFAULT_NATIVE)
    parser.add_argument("--cli", type=Path, default=ROOT / ".build/debug/codex-menu")
    args = parser.parse_args()
    if sys.platform != "darwin" or not Path("/usr/bin/sandbox-exec").is_file():
        parser.error("this probe requires macOS sandbox-exec; there is no unsandboxed fallback")
    os.umask(0o077)
    output = Path(tempfile.mkdtemp(prefix="codex-session-route-probe-", dir="/tmp")).resolve()
    home, state, login_home = [output / name for name in ("codex-home", "switcher-state", "empty-user-home")]
    for path in (home, state, login_home):
        path.mkdir(mode=0o700)
    old, new = RejectingServer(), RejectingServer()
    for server in (old, new):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    profile = output / "network.sb"
    policy = (f'(version 1)\n(allow default)\n(deny network*)\n'
              f'(allow network-outbound (remote ip "localhost:{old.port}") (remote ip "localhost:{new.port}"))\n')
    write_private(profile, policy.encode())
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(login_home), "CODEX_HOME": str(home),
                   "TMPDIR": str(output), "LANG": "en_US.UTF-8",
                   "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
                   "HTTP_PROXY": "", "HTTPS_PROXY": "", "ALL_PROXY": "",
                   "http_proxy": "", "https_proxy": "", "all_proxy": "",
                   "RUST_LOG": "codex_app_server=debug,codex_core=debug"}
    report = {"started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "passed": False,
              "scope": "one synthetic persisted thread, two fake-credential turn attempts, local HTTP 400 only",
              "not_validated": ["successful model generation", "encrypted reasoning compatibility", "main Desktop UI", "Remote"],
              "network_policy": "deny network* except the two exact localhost responder ports",
              "output_directory": str(output), "steps": []}
    client = None
    try:
        verify_network_policy(profile, environment, old.port)
        report["network_policy_enforcement_verified"] = True
        version = subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile), str(args.native), "--version"], env=environment, cwd=home,
                                 capture_output=True, text=True, check=True, timeout=10)
        report["native_version"] = version.stdout.strip()
        write_private(home / "config.toml", configuration("copilot", old.port, new.port))
        write_private(home / "auth.json", json.dumps({"auth_mode": "apikey", "OPENAI_API_KEY": "route-probe-fake-key"}).encode())
        client = NativeClient(args.native, home, profile, environment, output, "old-runtime")
        report["config_read_before"] = config_evidence(client, "copilot", old.port, new.port)
        started = client.rpc("thread/start", {"model": MODEL, "modelProvider": "copilot", "cwd": str(home),
                                             "ephemeral": False, "sandbox": "read-only", "approvalPolicy": "never",
                                             "baseInstructions": "Synthetic route probe only. Do not use tools.",
                                             "developerInstructions": "Connectivity to a local HTTP 400 test endpoint only."})
        thread_id = started["thread"]["id"]
        if started.get("modelProvider") != "copilot":
            raise RuntimeError("initial native thread did not use the old provider")
        report["steps"].append(client.rejected_turn(thread_id, "SYNTHETIC_OLD_ROUTE_CONTROL"))
        blocked = subprocess.run([str(args.cli), "session-provider-sync", "--isolated", "--home", str(home), "--state", str(state)],
                                 env=environment, cwd=home, capture_output=True, text=True, timeout=45)
        if blocked.returncode == 0 or "active writers" not in blocked.stdout + blocked.stderr:
            raise RuntimeError("active native writer was not rejected by the migration writer guard: "
                               + blocked.stdout[:700] + blocked.stderr[:700])
        report["active_native_writer_rejected"] = True
        client.close(); client = None
        originals = stored_thread(home, thread_id)
        if any(row["provider"] != "copilot" for row in originals) or not old.response_requests():
            raise RuntimeError("old-route positive control did not persist and reach the old endpoint")
        rollout = Path(originals[0]["rollout"])
        if not rollout.is_relative_to(home):
            raise RuntimeError("native rollout escaped the isolated home")
        before = rollout.read_bytes()
        baseline_old = len(old.response_requests())
        baseline_new = len(new.response_requests())
        report["thread_id"] = thread_id
        report["old_route_positive_control_requests"] = baseline_old
        write_private(home / "config.toml", configuration("openai", old.port, new.port))
        migrated = subprocess.run([str(args.cli), "session-provider-sync", "--isolated", "--home", str(home), "--state", str(state)],
                                  env=environment, cwd=home, capture_output=True, text=True, timeout=45)
        if migrated.returncode:
            raise RuntimeError("isolated metadata sync failed: " + migrated.stdout[:1000] + migrated.stderr[:1000])
        report["migration"] = json.loads(migrated.stdout)
        after = rollout.read_bytes()
        before_lines, after_lines = before.splitlines(keepends=True), after.splitlines(keepends=True)
        if len(before_lines) != len(after_lines):
            raise RuntimeError("metadata migration changed the record count")
        changed = 0
        for prior, current in zip(before_lines, after_lines):
            if prior == current:
                continue
            left, right = json.loads(prior), json.loads(current)
            if left.get("type") != "session_meta" or left.get("payload", {}).get("id") != thread_id:
                raise RuntimeError("metadata migration changed a message or another thread")
            left["payload"]["model_provider"] = "openai"
            if left != right:
                raise RuntimeError("metadata migration changed more than its provider field")
            changed += 1
        if changed < 1 or any(row["provider"] != "openai" for row in stored_thread(home, thread_id)):
            raise RuntimeError("both persisted provider metadata locations were not updated")
        report["non_metadata_records_byte_identical"] = True
        client = NativeClient(args.native, home, profile, environment, output, "resumed-runtime")
        report["config_read_after"] = config_evidence(client, "openai", old.port, new.port)
        # Intentionally no model, modelProvider, config, reasoning, or history override.
        resume_params = {"threadId": thread_id, "excludeTurns": True}
        resumed = client.rpc("thread/resume", resume_params)
        if resumed["thread"]["id"] != thread_id or resumed.get("modelProvider") != "openai":
            raise RuntimeError("fresh runtime did not resume the same thread on the new provider")
        report["resume_params"] = resume_params
        report["resumed_provider"] = resumed.get("modelProvider")
        new_before_turn = len(new.response_requests())
        report["steps"].append(client.rejected_turn(thread_id, "SYNTHETIC_NEW_ROUTE_CHECK"))
        client.close(); client = None
        report["old_endpoint_requests_after_migration"] = len(old.response_requests()) - baseline_old
        report["new_endpoint_requests_after_migration"] = len(new.response_requests()) - baseline_new
        report["new_endpoint_requests_during_resumed_turn"] = len(new.response_requests()) - new_before_turn
        if report["old_endpoint_requests_after_migration"] != 0 or report["new_endpoint_requests_during_resumed_turn"] < 1:
            raise RuntimeError("resumed request did not exclusively reach the new endpoint")
        if len(old.requests) + len(new.requests) > 8:
            raise RuntimeError("unexpected transport retry count")
        report["passed"] = True
    except Exception as error:
        report["error"] = type(error).__name__ + ": " + str(error)[:2000]
    finally:
        if client is not None:
            client.close()
        for server in (old, new):
            server.shutdown(); server.server_close()
        report["old_endpoint_requests"] = old.requests
        report["new_endpoint_requests"] = new.requests
        report["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        target = output / "report.json"
        write_private(target, json.dumps(report, indent=2, ensure_ascii=False).encode())
        print(json.dumps({"passed": report["passed"], "report": str(target), "error": report.get("error")}, ensure_ascii=False))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
