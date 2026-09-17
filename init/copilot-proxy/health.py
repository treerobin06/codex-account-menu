#!/usr/bin/env python3
"""Inspect the private socket; sustained failure uses the existing alert relay."""
import argparse
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import time

SOCKET = '/run/tree-copilot-proxy/http.sock'
STATE = Path('/var/lib/tree-copilot-health/state.json')


class PrivateHTTP(http.client.HTTPConnection):
    def __init__(self):
        super().__init__('localhost', timeout=4)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(4)
        self.sock.connect(SOCKET)


def observe():
    result = {'healthy': False, 'layer': 'private_socket'}
    connection = PrivateHTTP()
    try:
        connection.request('GET', '/readyz', headers={'Host': '127.0.0.1', 'Connection': 'close'})
        response = connection.getresponse()
        body = json.loads(response.read(256_000))
        result.update(http=response.status, layer='application_readiness')
        if isinstance(body, dict):
            result['ready'] = body.get('status') == 'ready'
            result['healthy'] = response.status == 200 and result['ready']
    except (OSError, ValueError, http.client.HTTPException) as error:
        result['error'] = type(error).__name__
    finally:
        connection.close()
    return result


def transition(previous, observation, now, boot):
    if previous.get('boot_id') != boot:
        previous = {}
    current = dict(previous)
    current.update(boot_id=boot, observed_at_unix=time.time(), observation=observation)
    if observation['healthy']:
        current.update(consecutive_failures=0, first_failure_monotonic=None)
        return current, False
    first = previous.get('first_failure_monotonic')
    if first is None or first > now:
        first = now
    failures = previous.get('consecutive_failures', 0) + 1
    current.update(consecutive_failures=failures, first_failure_monotonic=first)
    alert = failures >= 3 and now - first >= 180 and now - previous.get('last_alert_attempt_monotonic', -21600) >= 21600
    return current, alert


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--notify', action='store_true')
    parser.add_argument('--state-file', type=Path, default=STATE)
    args = parser.parse_args()
    previous = json.loads(args.state_file.read_text()) if args.state_file.exists() else {}
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    now = time.clock_gettime(time.CLOCK_MONOTONIC)
    current, alert = transition(previous, observe(), now, boot)
    if alert and args.notify:
        message = ('Copilot 私有 API 持续至少 3 分钟未就绪；Mac 模型请求可能失败。'
                   '服务已配置自动退避重启；若持续不恢复，请检查服务日志和授权/出口状态。'
                   '排查：systemctl status tree-copilot-proxy.service；'
                   'journalctl -u tree-copilot-proxy.service -n 50。'
                   '本检查未请求模型，也不会因授权错误反复重启 SSH。')
        outcome = subprocess.run(['/usr/local/sbin/notify.sh', '--email-critical', 'copilot-api-unavailable', message],
                                 capture_output=True, text=True, timeout=45)
        if outcome.returncode == 0:
            current['last_alert_attempt_monotonic'] = now
        current['notify_exit_code'] = outcome.returncode
    args.state_file.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = args.state_file.with_suffix('.new')
    temporary.write_text(json.dumps(current, ensure_ascii=False, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(args.state_file)
    print(json.dumps({'healthy': current['observation']['healthy'], 'layer': current['observation']['layer'],
                      'consecutive_failures': current['consecutive_failures'], 'alert_due': alert,
                      'model_requests': 0}, ensure_ascii=False))


if __name__ == '__main__':
    os.umask(0o077)
    main()
