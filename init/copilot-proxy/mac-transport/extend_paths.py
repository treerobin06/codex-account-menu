#!/usr/bin/env python3
"""Add independent backups through HAProxy's runtime API without restarting it."""
import argparse
import csv
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import socket
import time

SOURCE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('copilot_link', SOURCE / 'copilot-link.py')
link = importlib.util.module_from_spec(spec)
spec.loader.exec_module(link)
PATHS = {'direct': 14143, 'jump': 14144}
MARKER = '# Independent physical-interface backups (extend_paths.py)'


def control(command, socket_path=None):
    if '\n' in command or '\r' in command:
        raise ValueError('A single HAProxy command is required')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(4)
        client.connect(str(socket_path or link.RUNTIME / 'admin.sock'))
        client.sendall((command + '\n').encode())
        client.shutdown(socket.SHUT_WR)
        data = b''
        while True:
            part = client.recv(65536)
            if not part:
                return data.decode()
            data += part
            if len(data) > 2_000_000:
                raise RuntimeError('Unexpectedly large HAProxy response')


def stats(socket_path=None):
    return {row['svname']: row for row in csv.DictReader(io.StringIO(control('show stat', socket_path).lstrip('# ')))
            if row.get('pxname') == 'copilot_paths'}


def server_options(interval='3s', rise=2, fall=2):
    return ('check backup init-state fully-down inter {0} fastinter {0} downinter {0} rise {1} fall {2}'
            .format(interval, rise, fall))


def add_path(name, port, socket_path=None, interval='3s', rise=2, fall=2):
    if name not in PATHS or not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError('Unknown dedicated backend')
    if name in stats(socket_path):
        raise RuntimeError('Backend already exists: ' + name)
    result = control('add server copilot_paths/{0} 127.0.0.1:{1} {2}'.format(
        name, port, server_options(interval, rise, fall)), socket_path)
    if name not in stats(socket_path):
        raise RuntimeError('HAProxy rejected the new backend: ' + result[:400])
    control('enable health copilot_paths/' + name, socket_path)
    control('set server copilot_paths/' + name + ' state ready', socket_path)


def remove_path(name, socket_path=None):
    if name not in PATHS:
        raise ValueError('Refusing to modify an original backend')
    row = stats(socket_path).get(name)
    if not row:
        return
    control('set server copilot_paths/' + name + ' state maint', socket_path)
    row = stats(socket_path)[name]
    if int(row.get('scur', '0')):
        raise RuntimeError('Backend is draining active streams; left running: ' + name)
    control('disable health copilot_paths/' + name, socket_path)
    result = control('del server copilot_paths/' + name, socket_path)
    if name in stats(socket_path):
        raise RuntimeError('Backend could not be removed: ' + result[:400])


def config_with_backups(original):
    if MARKER in original or any('\n    server ' + name + ' ' in original for name in PATHS):
        raise RuntimeError('Backups are already present; inspect current state')
    if not original.rstrip().endswith('# No shutdown-sessions action: health changes never evict existing streams.'):
        raise RuntimeError('Production configuration changed; review before extending')
    return original.rstrip() + '\n    ' + MARKER + '\n' + ''.join(
        '    server {0} 127.0.0.1:{1} {2}\n'.format(name, port, server_options()) for name, port in PATHS.items())


def require_production(manifest, config):
    if manifest.get('mode') != 'production' or config.count('bind 127.0.0.1:4141\n') != 1:
        raise RuntimeError('Only the committed production gateway may be extended')


def apply():
    native_spec = importlib.util.spec_from_file_location('native_ssh', SOURCE / 'native-ssh.py')
    native = importlib.util.module_from_spec(native_spec)
    native_spec.loader.exec_module(native)
    native_environment = native.configuration_environment()
    state_file = link.RUNTIME / 'extensions.json'
    if state_file.exists():
        raise RuntimeError('Extension state exists; inspect it instead of redeploying')
    original_path = link.RUNTIME / 'haproxy.cfg'
    original = original_path.read_text()
    require_production(json.loads((link.RUNTIME / 'manifest.json').read_text()), original)
    before = link.preflight()
    prepared = config_with_backups(original)
    candidate = link.RUNTIME / 'haproxy-extended.check.cfg'
    link.write(candidate, prepared)
    link.run([str(link.TOOLS / 'haproxy'), '-c', '-f', str(candidate)])
    candidate.unlink()
    current = stats()
    if current.get('primary', {}).get('status') != 'UP' or current.get('backup', {}).get('status') != 'UP':
        raise RuntimeError('Both original paths must be healthy before this incremental update')
    for name, port in PATHS.items():
        label = 'com.tree.copilot-link-' + name
        if not link.port_free(port) or link.loaded(label) or (link.AGENTS / (label + '.plist')).exists():
            raise RuntimeError('Extension port/service already exists: ' + name)
    backup = link.RUNTIME / ('extension-backup-' + time.strftime('%Y%m%dT%H%M%S'))
    backup.mkdir(mode=0o700)
    link.write(backup / 'haproxy.cfg', original)
    link.write(backup / 'manifest.json', (link.RUNTIME / 'manifest.json').read_bytes())
    for filename in ('native-ssh.py', 'extend_paths.py'):
        link.write(link.TOOLS / filename, (SOURCE / filename).read_bytes(), 0o700)
    environment = {**native_environment, 'HOME': str(link.USER_HOME), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',
                   'HTTP_PROXY': '', 'HTTPS_PROXY': '', 'ALL_PROXY': '',
                   'http_proxy': '', 'https_proxy': '', 'all_proxy': '', 'NO_PROXY': '*', 'no_proxy': '*'}
    labels = {}
    receipt = {'state': 'staging', 'before': before, 'backup': str(backup), 'paths': PATHS,
               'original_sha256': hashlib.sha256(original.encode()).hexdigest(), 'services': labels}
    link.write(state_file, json.dumps(receipt, indent=2) + '\n')
    added = []
    try:
        for name in PATHS:
            label = 'com.tree.copilot-link-' + name
            plist = {'Label': label, 'ProgramArguments': ['/usr/bin/python3', str(link.TOOLS / 'native-ssh.py'), name],
                     'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 15,
                     'EnvironmentVariables': environment, 'ProcessType': 'Background',
                     'StandardOutPath': str(link.RUNTIME / (name + '.log')),
                     'StandardErrorPath': str(link.RUNTIME / (name + '.log'))}
            link.write(link.AGENTS / (label + '.plist'), plistlib.dumps(plist))
            link.bootstrap(label)
            labels[name] = label
        for name, port in PATHS.items():
            link.wait_ready(port, seconds=40)
            models = link.http_json(port, '/v1/models', timeout=8).get('data', [])
            if not models:
                raise RuntimeError('Empty model catalog through ' + name)
        if original_path.read_text() != original:
            raise RuntimeError('Concurrent production configuration edit; refusing overwrite')
        for name, port in PATHS.items():
            # Track immediately, so a partial runtime command can be cleaned up.
            added.append(name)
            add_path(name, port)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if all(stats().get(name, {}).get('status') == 'UP' for name in PATHS):
                break
            time.sleep(.25)
        else:
            raise RuntimeError('New runtime health checks did not become UP')
        if original_path.read_text() != original:
            raise RuntimeError('Concurrent configuration edit; refusing overwrite')
        link.write(original_path, prepared)
        after = link.preflight()
        if before['relay_pid'] != after['relay_pid'] or before['default_route'] != after['default_route']:
            raise RuntimeError('Relay identity or default route changed during deployment')
        receipt.update(state='active', applied_at_unix=time.time(), after=after,
                       active_sha256=hashlib.sha256(prepared.encode()).hexdigest())
        link.write(state_file, json.dumps(receipt, indent=2) + '\n')
        print(json.dumps({'state': 'active', 'paths': list(PATHS), 'relay_preserved': True,
                          'gateway_restarted': False, 'backup': str(backup)}, indent=2))
    except Exception as error:
        cleanup_errors = []
        for name in reversed(added):
            try:
                remove_path(name)
            except Exception as cleanup:
                cleanup_errors.append(str(cleanup))
        if original_path.read_text() == prepared:
            link.write(original_path, original)
        # Keep the isolated SSH listeners alive until an operator verifies that
        # no direct clients use them; never kill an unknown/active connection.
        receipt.update(state='failed', error=str(error), cleanup_errors=cleanup_errors)
        link.write(state_file, json.dumps(receipt, indent=2) + '\n')
        raise


def original_paths_ready(rows, fetch=link.http_json):
    for name, port in (('primary', 14141), ('backup', 14142)):
        if rows.get(name, {}).get('status') != 'UP':
            continue
        try:
            models = fetch(port, '/v1/models', timeout=8).get('data', [])
            if models and all(isinstance(item, dict) and isinstance(item.get('id'), str) for item in models):
                return True
        except (OSError, ValueError, TypeError, AttributeError):
            pass
    return False


def rollback():
    path = link.RUNTIME / 'extensions.json'
    receipt = json.loads(path.read_text())
    current = link.RUNTIME / 'haproxy.cfg'
    if hashlib.sha256(current.read_bytes()).hexdigest() != receipt.get('active_sha256'):
        raise RuntimeError('Current configuration differs from this deployment; refusing rollback overwrite')
    if not original_paths_ready(stats()):
        raise RuntimeError('Neither original route has verified data flow; preserving all independent backups')
    for name in reversed(PATHS):
        remove_path(name)
    link.write(current, (Path(receipt['backup']) / 'haproxy.cfg').read_bytes())
    receipt.update(state='rolled-back', rolled_back_at_unix=time.time())
    link.write(path, json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'state': 'rolled-back', 'original_paths_preserved': True,
                      'standalone_ssh_left_running': list(PATHS)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('plan', 'apply', 'rollback'))
    args = parser.parse_args()
    if args.action == 'plan':
        print(json.dumps({'paths': PATHS, 'mechanism': 'HAProxy runtime add server plus persistent config',
                          'restarts_existing_services': False, 'changes_routes_proxy_or_vpn': False,
                          'source_identity': 'Existing verified SSH host keys and private keys stay on Mac'}, indent=2))
        return
    with (link.RUNTIME / 'extensions.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        (apply if args.action == 'apply' else rollback)()


if __name__ == '__main__':
    main()
