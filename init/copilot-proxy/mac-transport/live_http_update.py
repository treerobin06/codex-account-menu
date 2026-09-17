#!/usr/bin/env python3
"""User-invoked HTTP settings update; no Desktop/relay restart or source switch."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import urllib.request

SOURCE = Path(__file__).resolve().parent
USER_HOME = Path.home()
HOME_DIR = Path(os.environ.get('CODEX_HOME', str(USER_HOME / '.codex')))
STORAGE = Path(os.environ.get('CODEX_ACCOUNT_MENU_STATE', str(USER_HOME / 'Library/Application Support/Codex Account Menu')))
RUNTIME = USER_HOME / '.local/state/copilot-transport'
CLI = Path(os.environ.get('CODEX_ACCOUNT_MENU_CLI', str(USER_HOME / 'Applications/Codex Account Menu.app/Contents/Helpers/codex-menu')))
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def get(path):
    with OPENER.open('http://127.0.0.1:4142' + path, timeout=5) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('apply', 'revert'))
    args = parser.parse_args()
    os.umask(0o077)
    config_file = HOME_DIR / 'config.toml'
    binding_file = STORAGE / 'home-binding.json'
    pending_file = STORAGE / 'switch-pending.json'
    original = config_file.read_bytes(), binding_file.read_bytes()
    if pending_file.exists():
        raise RuntimeError('A source switch is pending; no live settings update')
    native = subprocess.run([str(CLI), 'maintain-relay', '--home', str(HOME_DIR), '--state', str(STORAGE)], capture_output=True, text=True, timeout=20,
                            env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin'})
    state = json.loads(native.stdout)
    if native.returncode or state.get('action') != 'healthy':
        raise RuntimeError('Native source/binding guard did not confirm the current healthy API route')
    fd = os.open(HOME_DIR / '.codex-account-menu.lock', os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        held = os.fstat(fd)
        current = os.lstat(HOME_DIR / '.codex-account-menu.lock')
        if not stat.S_ISREG(current.st_mode) or (held.st_dev, held.st_ino) != (current.st_dev, current.st_ino):
            raise RuntimeError('Source lock identity changed')
        if original != (config_file.read_bytes(), binding_file.read_bytes()) or pending_file.exists():
            raise RuntimeError('Source state changed before update')
        before = get('/healthz')
        if before.get('pid') != state.get('pid') or not before.get('enabled') or before.get('testMode'):
            raise RuntimeError('Unexpected live relay')
        if args.action == 'apply' and (before.get('transportVersion') == 2 or before.get('networkPolicy', {}).get('active')):
            if before.get('httpIdleTimeoutMs') == 600000:
                print(json.dumps({'already_applied': True, 'pid': before['pid'], 'restart_required': False}))
                return
            raise RuntimeError('Unexpected existing network policy')
        owned = subprocess.run(['ps', '-p', str(before['pid']), '-o', 'uid=,comm='], capture_output=True, text=True, timeout=3)
        fields = owned.stdout.strip().split(None, 1)
        if len(fields) != 2 or int(fields[0]) != os.getuid() or Path(fields[1]).name != 'node':
            raise RuntimeError('Relay PID is not the expected user-owned Node process')
        models = get('/v1/models').get('data', [])
        ids = sorted(item['id'] for item in models)
        if not ids: raise RuntimeError('Model catalog is empty')
        directory = RUNTIME / ('live-http-' + datetime.datetime.now().strftime('%Y%m%dT%H%M%S'))
        directory.mkdir(mode=0o700)
        ticket = {'action': args.action, 'deadline': int(__import__('time').time() * 1000) + 45000,
                  'modelsHash': hashlib.sha256('\n'.join(ids).encode()).hexdigest(),
                  'config': {'pid': before['pid'], 'instanceId': before['instanceId'], 'listenPort': 4142,
                             'upstreamPort': 4141, 'oldIdleMs': 120000, 'newIdleMs': 600000, 'testMode': False}}
        path = directory / 'ticket.json'; path.write_text(json.dumps(ticket, indent=2) + '\n')
        result = subprocess.run(['/opt/homebrew/bin/node', str(SOURCE / 'apply_live_http_policy.mjs'), str(path)],
                                capture_output=True, text=True, timeout=25,
                                env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin'})
        report = json.loads(result.stdout) if result.stdout.strip() else {'error': 'updater_did_not_return_a_receipt'}
        report.update(at=datetime.datetime.now().astimezone().isoformat(),
                      configurationUnchanged=original == (config_file.read_bytes(), binding_file.read_bytes()),
                      receipt_directory=str(directory), model_requests=0)
        (directory / 'receipt.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if result.returncode or not report['configurationUnchanged']:
            raise SystemExit(1)
    finally:
        os.close(fd)


if __name__ == '__main__':
    main()
