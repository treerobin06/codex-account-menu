#!/usr/bin/env python3
"""Check Codex provider persistence and new/old/new thread isolation.

The default run only inspects metadata. --live performs three model calls in
diagnostic threads. Original conversations are never resumed for writing.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import queue
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid


CODEX = os.environ.get("CODEX_NATIVE_BINARY", "/Applications/Codex.app/Contents/Resources/codex")
STATE = (Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "state_5.sqlite").resolve().as_uri() + "?mode=ro"


def metadata(thread_id):
    with sqlite3.connect(STATE, uri=True, timeout=5) as connection:
        connection.row_factory = sqlite3.Row
        row = connection.execute(
            "SELECT id, name, model_provider, model, reasoning_effort, "
            "rollout_path FROM threads WHERE id=?", (thread_id,)
        ).fetchone()
    if row is None:
        raise ValueError("Unknown source thread")
    return dict(row)


class Client:
    def __init__(self, output, label):
        self.stderr = (output / (label + ".stderr.log")).open("w")
        self.process = subprocess.Popen(
            [CODEX, "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.stderr, text=True, bufsize=1,
        )
        self.messages = queue.Queue()
        self.pending = []
        self.sequence = 0
        threading.Thread(target=self._read, daemon=True).start()
        try:
            self.rpc("initialize", {
                "clientInfo": {"name": "copilot_switch_regression", "version": "1.0"},
                "capabilities": {"experimentalApi": True},
            })
            self.send({"method": "initialized", "params": {}})
        except BaseException:
            self.close()
            raise

    def _read(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except json.JSONDecodeError:
                pass
        self.messages.put({"_eof": True})

    def send(self, value):
        self.process.stdin.write(json.dumps(value) + "\n")
        self.process.stdin.flush()

    def receive(self, deadline):
        while time.monotonic() < deadline:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                value = self.messages.get(timeout=min(1, remaining))
            except queue.Empty:
                continue
            if value.get("_eof"):
                raise RuntimeError("Diagnostic app server exited")
            return value
        raise TimeoutError("Diagnostic app-server response")

    def rpc(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 40
        while True:
            value = self.receive(deadline)
            if value.get("id") == request_id:
                if "error" in value:
                    raise RuntimeError(method + ": " + json.dumps(value["error"]))
                return value["result"]
            self.pending.append(value)

    def generate(self, thread_id, prompt, expected, effort="low"):
        started = time.monotonic()
        response = self.rpc("turn/start", {
            "threadId": thread_id,
            "input": [{"type": "text", "text": prompt}],
            "effort": effort, "summary": "none",
        })
        turn_id = response["turn"]["id"]
        deadline = time.monotonic() + 100
        result = {"thread_id": thread_id, "turn_id": turn_id, "output": ""}
        while True:
            value = self.pending.pop(0) if self.pending else self.receive(deadline)
            method, params = value.get("method", ""), value.get("params", {})
            if params.get("threadId") not in (None, thread_id):
                continue
            if params.get("turnId") not in (None, turn_id):
                continue
            if method == "item/agentMessage/delta":
                result["output"] += params.get("delta", "")
            elif method == "thread/tokenUsage/updated":
                result["last_token_usage"] = params.get("tokenUsage", {}).get("last")
            elif method == "error":
                result.setdefault("errors", []).append(params.get("error"))
            elif method == "turn/completed" and params.get("turn", {}).get("id") == turn_id:
                turn = params["turn"]
                result.update(status=turn.get("status"), error=turn.get("error"))
                break
        result["duration_seconds"] = round(time.monotonic() - started, 2)
        result["effort"] = effort
        if result["status"] != "completed":
            result.pop("last_token_usage", None)
        result["passed"] = result["status"] == "completed" and result["output"].strip() == expected
        print(json.dumps(result, ensure_ascii=False), flush=True)
        return result

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            self.process.terminate()
            self.process.wait(timeout=5)
        finally:
            self.stderr.close()


def effective(result):
    return {key: result.get(key) for key in ("modelProvider", "model", "reasoningEffort")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-thread", required=True)
    parser.add_argument("--live", action="store_true", help="Authorize three short model calls")
    parser.add_argument("--provider-roundtrip", action="store_true",
                        help="Use the same diagnostic thread for Copilot/OpenAI/Copilot")
    arguments = parser.parse_args()
    output = Path(tempfile.mkdtemp(prefix="tree-thread-switching-", dir="/tmp"))
    original = metadata(arguments.source_thread)
    original_hash = hashlib.sha256(Path(original["rollout_path"]).read_bytes()).hexdigest()
    report = {"source": original, "output_directory": str(output), "live": arguments.live,
              "provider_roundtrip": arguments.provider_roundtrip, "steps": []}
    synthetic = None
    instructions = "仅执行连通性校验：按最新用户消息回复校验文本，禁止调用任何工具、修改文件或继续历史任务。"
    try:
        client = Client(output, "new-a")
        try:
            result = client.rpc("thread/start", {
                "modelProvider": "copilot", "model": original["model"],
                "config": {"model_reasoning_effort": "low"},
                "cwd": str(output), "ephemeral": False,
                "sandbox": "read-only", "approvalPolicy": "never",
                "baseInstructions": instructions, "developerInstructions": instructions,
            })
            synthetic = result["thread"]["id"]
            client.rpc("thread/name/set", {"threadId": synthetic, "name": "Tree 切换回归临时会话"})
            report["steps"].append({"phase": "new_a", "effective": effective(result)})
            nonce_a, nonce_b = uuid.uuid4().hex[:12], uuid.uuid4().hex[:12]
            if arguments.live:
                item = client.generate(synthetic, "本会话的校验词是 " + nonce_a + "。记住它，只回复 A1:" + nonce_a, "A1:" + nonce_a)
                report["steps"][-1]["generation"] = item
                if not item["passed"]:
                    raise RuntimeError("New A generation failed; remaining model calls skipped")
            client.rpc("thread/unsubscribe", {"threadId": synthetic})
        finally:
            client.close()

        client = Client(output, "old-b")
        try:
            if arguments.provider_roundtrip:
                result = client.rpc("thread/resume", {
                    "threadId": synthetic, "modelProvider": "openai", "excludeTurns": True,
                })
                if result["modelProvider"] != "openai":
                    raise RuntimeError("Requested OpenAI provider was not activated")
                phase = "switch_to_openai"
            else:
                result = client.rpc("thread/fork", {
                    "threadId": arguments.source_thread, "modelProvider": "copilot",
                    "ephemeral": True, "excludeTurns": True,
                    "sandbox": "read-only", "approvalPolicy": "never",
                    "developerInstructions": instructions,
                })
                phase = "old_b"
            report["steps"].append({"phase": phase, "effective": effective(result)})
            if arguments.live:
                if arguments.provider_roundtrip:
                    prompt = "本会话第一次消息让你记住的校验词是什么？只回复 O1: 后面接那个校验词。"
                    expected = "O1:" + nonce_a
                else:
                    prompt = "本临时会话的校验词是 " + nonce_b + "。只回复 B1:" + nonce_b
                    expected = "B1:" + nonce_b
                item = client.generate(result["thread"]["id"], prompt, expected)
                report["steps"][-1]["generation"] = item
                if not item["passed"]:
                    raise RuntimeError("Old B generation failed; remaining model calls skipped")
            client.rpc("thread/unsubscribe", {"threadId": result["thread"]["id"]})
        finally:
            client.close()

        if arguments.provider_roundtrip:
            report["stored_provider_after_openai"] = metadata(synthetic)["model_provider"]

        client = Client(output, "return-a")
        try:
            params = {"threadId": synthetic, "excludeTurns": True}
            if arguments.provider_roundtrip:
                params["modelProvider"] = "copilot"
            result = client.rpc("thread/resume", params)
            report["steps"].append({"phase": "return_a", "effective": effective(result)})
            if result["modelProvider"] != "copilot":
                raise RuntimeError("Provider was not preserved when reopening A")
            if arguments.live:
                item = client.generate(synthetic, "本会话第一次消息让你记住的校验词是什么？只回复 A2: 后面接那个校验词。", "A2:" + nonce_a)
                report["steps"][-1]["generation"] = item
                if not item["passed"]:
                    raise RuntimeError("Return to A lost or mixed conversation state")
            client.rpc("thread/unsubscribe", {"threadId": synthetic})
        finally:
            client.close()
        report["status"] = "passed"
    except Exception as error:
        report.update(status="failed", error=type(error).__name__ + ": " + str(error))
    finally:
        if synthetic:
            client = None
            try:
                client = Client(output, "cleanup")
                client.rpc("thread/archive", {"threadId": synthetic})
                report["diagnostic_thread_archived"] = synthetic
            except Exception as error:
                report["cleanup_error"] = str(error)
            finally:
                if client is not None:
                    client.close()
        report["source_rollout_unchanged"] = hashlib.sha256(Path(original["rollout_path"]).read_bytes()).hexdigest() == original_hash
        report["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print("REPORT=" + str(output / "result.json"), flush=True)
    return 0 if report.get("status") == "passed" and report["source_rollout_unchanged"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
