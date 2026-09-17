#!/usr/bin/env python3
"""Private Mac SSH transport deployment. Stage is isolated; cutover is explicit."""
import argparse
import csv
import hashlib
import io
import ipaddress
import getpass
import shlex
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import time
import urllib.request
import uuid
import rollback_guard as guard

SOURCE = Path(__file__).resolve().parent
USER_HOME = Path.home()
RUNTIME = USER_HOME / '.local/state/copilot-transport'
TOOLS = USER_HOME / '.local/share/copilot-transport'
AGENTS = USER_HOME / 'Library/LaunchAgents'
DOMAIN = 'gui/' + str(os.getuid())
OLD_LABEL = 'com.tree.copilot-proxy-tunnel'
LABELS = {name: 'com.tree.copilot-link-' + name for name in ('primary', 'backup', 'gateway')}
GUARD_LABEL = 'com.tree.copilot-link-rollback'
BIN_SOURCE = Path(os.environ.get('COPILOT_HAPROXY_BINARY', str(USER_HOME / 'Library/Caches/copilot-transport/haproxy-3.4.4/haproxy')))
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def run(args, check=True, timeout=15):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError('Command failed: ' + ' '.join(args[:3]) + '\n' + result.stderr[-1200:])
    return result


def write(path, data, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(path.suffix + '.new')
    temporary.write_bytes(data.encode() if isinstance(data, str) else data)
    temporary.chmod(mode)
    temporary.replace(path)


def render(front_port, admin_socket, primary_port=14141, backup_port=14142,
           wait='20s', interval='3s', rise=2, fall=2):
    values = dict(FRONT_PORT=front_port, ADMIN_SOCKET=shlex.quote(str(admin_socket)),
                  PRIMARY_PORT=primary_port, BACKUP_PORT=backup_port, WAIT_TIME=wait,
                  CHECK_INTERVAL=interval, RISE=rise, FALL=fall)
    template = (SOURCE / 'haproxy.cfg.in').read_text()
    for key, value in values.items():
        template = template.replace('{{' + key + '}}', str(value))
    assert '{{' not in template
    return template


def http_json(port, path, timeout=4):
    with OPENER.open('http://127.0.0.1:' + str(port) + path, timeout=timeout) as response:
        return json.loads(response.read(100_000))


def admin(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(3)
        client.connect(str(RUNTIME / 'admin.sock'))
        client.sendall((command + '\n').encode())
        client.shutdown(socket.SHUT_WR)
        parts = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                return b''.join(parts).decode()
            parts.append(chunk)


def port_free(port):
    with socket.socket() as probe:
        try:
            probe.bind(('127.0.0.1', port))
            return True
        except OSError:
            return False


def loaded(label):
    return run(['launchctl', 'print', DOMAIN + '/' + label], check=False).returncode == 0


def bootstrap(label):
    if not loaded(label):
        run(['launchctl', 'bootstrap', DOMAIN, str(AGENTS / (label + '.plist'))])


def stop(label):
    if loaded(label):
        run(['launchctl', 'bootout', DOMAIN + '/' + label])


def preflight():
    route = run(['route', '-n', 'get', 'default']).stdout
    relay = http_json(4142, '/healthz')
    ready = http_json(4141, '/readyz')
    assert relay.get('status') == 'enabled' and ready.get('status') == 'ready'
    return {'default_route': '\n'.join(x.strip() for x in route.splitlines()
                                      if 'gateway:' in x or 'interface:' in x),
            'relay_pid': relay.get('pid'), 'active_requests': relay.get('activeRequests'),
            'active_websockets': relay.get('activeWebSockets')}


def transport_ssh_configuration():
    """Require explicit endpoints before creating or starting any transport."""
    def endpoint(prefix):
        raw = os.environ.get(prefix + '_HOST')
        if not raw:
            raise RuntimeError(prefix + '_HOST is required; configure your own SSH endpoint')
        host = str(ipaddress.IPv4Address(raw))
        port = int(os.environ.get(prefix + '_PORT', '22'))
        if not 1 <= port <= 65535:
            raise ValueError('SSH port must be between 1 and 65535')
        return host, port
    primary, primary_port = endpoint('COPILOT_PRIMARY')
    backup, backup_port = endpoint('COPILOT_BACKUP')
    user = os.environ.get('COPILOT_SSH_USER', getpass.getuser())
    if not user or any(c.isspace() or c in '\\"' for c in user):
        raise ValueError('Invalid SSH user')
    identity = Path(os.environ.get('COPILOT_SSH_IDENTITY_FILE', str(USER_HOME / '.ssh/id_ed25519'))).expanduser()
    if not identity.is_absolute() or any(c in str(identity) for c in ('\n', '\r')):
        raise ValueError('An absolute SSH identity path is required')
    config = f"""Host copilot-server
    HostName {primary}
    Port {primary_port}
    User {user}
    IdentityFile {json.dumps(str(identity))}
    IdentitiesOnly yes
    UserKnownHostsFile {json.dumps(str(USER_HOME / '.ssh/known_hosts'))}
    HostKeyAlias copilot-server
    StrictHostKeyChecking yes
    UpdateHostKeys no
    BatchMode yes
    ConnectTimeout 6
    ConnectionAttempts 1
    ServerAliveInterval 15
    ServerAliveCountMax 6
    TCPKeepAlive yes
    ExitOnForwardFailure yes
    ControlMaster no
    ControlPath none
    ForwardAgent no
    RequestTTY no
    Compression no
    LogLevel ERROR
"""
    return config, backup, backup_port


def stage():
    if (RUNTIME / 'manifest.json').exists():
        raise RuntimeError('Already staged. Use status; do not overwrite a running deployment.')
    ssh_config, backup_host, backup_port = transport_ssh_configuration()
    before = preflight()
    for port in (4143, 14141, 14142):
        if not port_free(port):
            raise RuntimeError('Port already in use: ' + str(port))
    for label in LABELS.values():
        if loaded(label) or (AGENTS / (label + '.plist')).exists():
            raise RuntimeError('Existing service must be inspected: ' + label)
    version = run([str(BIN_SOURCE), '-v']).stdout
    assert '3.4.4' in version
    TOOLS.mkdir(parents=True, exist_ok=True, mode=0o700)
    RUNTIME.mkdir(parents=True, exist_ok=True, mode=0o700)
    write(TOOLS / 'haproxy', BIN_SOURCE.read_bytes(), 0o700)
    write(TOOLS / 'haproxy.cfg.in', (SOURCE / 'haproxy.cfg.in').read_bytes())
    write(TOOLS / 'copilot-link.py', Path(__file__).read_bytes(), 0o700)
    write(TOOLS / 'rollback_guard.py', (SOURCE / 'rollback_guard.py').read_bytes(), 0o700)
    write(RUNTIME / 'ssh_config', ssh_config)
    write(RUNTIME / 'haproxy.cfg', render(4143, RUNTIME / 'admin.sock'))
    run([str(TOOLS / 'haproxy'), '-c', '-f', str(RUNTIME / 'haproxy.cfg')])
    original = AGENTS / (OLD_LABEL + '.plist')
    write(RUNTIME / 'original-tunnel.plist', original.read_bytes())
    manifest = {'mode': 'preview', 'preview_port': 4143, 'production_port': 4141,
                'original_sha256': hashlib.sha256(original.read_bytes()).hexdigest(),
                'haproxy_sha256': hashlib.sha256((TOOLS / 'haproxy').read_bytes()).hexdigest(),
                'before': before, 'staged_at_unix': time.time()}
    write(RUNTIME / 'manifest.json', json.dumps(manifest, indent=2) + '\n')
    environment = {'HOME': str(USER_HOME), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin',
                   'HTTP_PROXY': '', 'HTTPS_PROXY': '', 'ALL_PROXY': '',
                   'http_proxy': '', 'https_proxy': '', 'all_proxy': '',
                   'NO_PROXY': '*', 'no_proxy': '*'}
    for name, label in LABELS.items():
        if name == 'gateway':
            args = [str(TOOLS / 'haproxy'), '-db', '-f', str(RUNTIME / 'haproxy.cfg')]
        else:
            port = 14141 if name == 'primary' else 14142
            args = ['/usr/bin/ssh', '-F', str(RUNTIME / 'ssh_config'), '-NT', '-L',
                    '127.0.0.1:' + str(port) + ':/run/tree-copilot-proxy/http.sock',
                    'copilot-server']
            if name == 'backup':
                args[1:1] = ['-o', 'HostName=' + backup_host, '-p', str(backup_port)]
        plist = {'Label': label, 'ProgramArguments': args, 'RunAtLoad': True,
                 'KeepAlive': True, 'ThrottleInterval': 5 if name != 'backup' else 15,
                 'EnvironmentVariables': environment, 'ProcessType': 'Background',
                 'StandardOutPath': str(RUNTIME / (name + '.log')),
                 'StandardErrorPath': str(RUNTIME / (name + '.log'))}
        write(AGENTS / (label + '.plist'), plistlib.dumps(plist))
        bootstrap(label)
    wait_ready(4143)
    print(json.dumps({'staged': True, 'port': 4143, 'production_unchanged': True}))


def wait_ready(port, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if http_json(port, '/readyz', timeout=2).get('status') == 'ready':
                return
        except Exception:
            pass
        time.sleep(.5)
    raise RuntimeError('Transport did not become ready on port ' + str(port))


def status():
    manifest = json.loads((RUNTIME / 'manifest.json').read_text()) if (RUNTIME / 'manifest.json').exists() else {}
    result = {'mode': manifest.get('mode', 'not-staged'),
              'services': {k: loaded(v) for k, v in LABELS.items()}}
    extensions = RUNTIME / 'extensions.json'
    if extensions.exists():
        extra = json.loads(extensions.read_text())
        result['extensions_state'] = extra.get('state')
        for name in ('direct', 'jump'):
            if name in extra.get('services', {}):
                result['services'][name] = loaded('com.tree.copilot-link-' + name)
    if manifest.get('transaction'):
        ticket = RUNTIME / ('cutover-' + manifest['transaction'] + '.json')
        if ticket.exists():
            lease = json.loads(ticket.read_text())
            result['cutover_guard'] = {k: lease.get(k) for k in
                                      ('state', 'deadline_unix', 'guard_pid', 'rollback_attempts', 'rollback_result')}
    try:
        rows = csv.DictReader(io.StringIO(admin('show stat').lstrip('# ')))
        result['paths'] = [{k: row.get(k) for k in ('svname', 'status', 'scur', 'stot', 'check_status', 'check_duration')}
                           for row in rows if row.get('pxname') == 'copilot_paths']
    except OSError:
        result['paths'] = []
    print(json.dumps(result, ensure_ascii=False, indent=2))


def arm_guard(before, seconds=45):
    if loaded(GUARD_LABEL):
        raise RuntimeError('An existing rollback guard must be inspected before another cutover')
    identifier = uuid.uuid4().hex
    ticket = RUNTIME / ('cutover-' + identifier + '.json')
    now, monotonic = time.time(), guard.steady()
    lease = {'transaction': identifier, 'state': 'armed', 'created_monotonic': monotonic,
             'deadline_monotonic': monotonic + seconds, 'deadline_unix': now + seconds,
             'owner_pid': os.getpid(), 'owner_fingerprint': guard.fingerprint(os.getpid()),
             'before': before}
    guard.save(ticket, lease)
    manifest = json.loads((RUNTIME / 'manifest.json').read_text())
    manifest['transaction'] = identifier
    write(RUNTIME / 'manifest.json', json.dumps(manifest, indent=2) + '\n')
    plist = {'Label': GUARD_LABEL, 'ProgramArguments': ['/usr/bin/python3', str(TOOLS / 'rollback_guard.py'), str(ticket)],
             'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 2,
             'EnvironmentVariables': {'HOME': str(USER_HOME), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'},
             'StandardOutPath': str(RUNTIME / 'rollback-guard.log'),
             'StandardErrorPath': str(RUNTIME / 'rollback-guard.log')}
    write(AGENTS / (GUARD_LABEL + '.plist'), plistlib.dumps(plist))
    bootstrap(GUARD_LABEL)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        ready = json.loads(ticket.read_text())
        if ready.get('guard_pid'):
            os.kill(ready['guard_pid'], 0)
            if ready.get('guard_parent_pid') != 1:
                raise RuntimeError('Rollback guard is not independently owned by launchd')
            if not loaded(GUARD_LABEL):
                raise RuntimeError('Rollback guard did not remain loaded')
            guard.active(ticket)
            return ticket
        time.sleep(.1)
    raise RuntimeError('Rollback guard did not confirm readiness; old tunnel remains active')


def cutover(approved):
    if not approved:
        raise RuntimeError('Cutover interrupts active API streams and requires the user\'s specific approval.')
    manifest = json.loads((RUNTIME / 'manifest.json').read_text())
    if manifest['mode'] != 'preview':
        raise RuntimeError('Cutover requires a verified preview.')
    original = AGENTS / (OLD_LABEL + '.plist')
    if hashlib.sha256(original.read_bytes()).hexdigest() != manifest['original_sha256']:
        raise RuntimeError('Original tunnel changed since staging; re-review required.')
    if hashlib.sha256((RUNTIME / 'original-tunnel.plist').read_bytes()).hexdigest() != manifest['original_sha256']:
        raise RuntimeError('Rollback backup checksum mismatch')
    before = preflight()
    if not loaded(OLD_LABEL):
        raise RuntimeError('The expected original tunnel is not loaded')
    wait_ready(4143)
    write(RUNTIME / 'haproxy-production.cfg', render(4141, RUNTIME / 'admin.sock'))
    run([str(TOOLS / 'haproxy'), '-c', '-f', str(RUNTIME / 'haproxy-production.cfg')])
    ticket = arm_guard(before)
    try:
        guard.active(ticket, 'applying')
        manifest = json.loads((RUNTIME / 'manifest.json').read_text())
        manifest['mode'] = 'transition'
        write(RUNTIME / 'manifest.json', json.dumps(manifest, indent=2) + '\n')
        run(['launchctl', 'disable', DOMAIN + '/' + OLD_LABEL])
        guard.active(ticket)
        stop(OLD_LABEL)
        guard.active(ticket)
        write(RUNTIME / 'haproxy.cfg', (RUNTIME / 'haproxy-production.cfg').read_bytes())
        run(['launchctl', 'kickstart', '-k', DOMAIN + '/' + LABELS['gateway']])
        wait_ready(4141)
        after = http_json(4142, '/healthz')
        assert after.get('pid') == before['relay_pid']
        assert len(http_json(4142, '/v1/models').get('data', [])) > 0
        guard.active(ticket, 'candidate_ready')
        manifest = json.loads((RUNTIME / 'manifest.json').read_text())
        manifest.update(mode='provisional', cutover_at_unix=time.time(), cutover_before=before)
        write(RUNTIME / 'manifest.json', json.dumps(manifest, indent=2) + '\n')
        lease = json.loads(ticket.read_text())
        print(json.dumps({'candidate_ready': True, 'transaction': lease['transaction'],
                          'confirm_before_unix': lease['deadline_unix'], 'guard_pid': lease['guard_pid'],
                          'guard_parent_pid': lease['guard_parent_pid'], 'relay_restarted': False,
                          'next': 'A fresh post-cutover tool call must run confirm --transaction ' + lease['transaction']}))
    except Exception:
        guard.request_rollback(ticket)
        raise


def restore_old():
    manifest = json.loads((RUNTIME / 'manifest.json').read_text())
    if manifest.get('mode') != 'preview' or not loaded(OLD_LABEL):
        stop(LABELS['gateway'])
        write(RUNTIME / 'haproxy.cfg', render(4143, RUNTIME / 'admin.sock'))
        original = AGENTS / (OLD_LABEL + '.plist')
        saved = (RUNTIME / 'original-tunnel.plist').read_bytes()
        assert hashlib.sha256(saved).hexdigest() == manifest['original_sha256']
        if not original.exists() or original.read_bytes() != saved:
            if original.exists():
                write(RUNTIME / 'original-drift-on-rollback.plist', original.read_bytes())
            write(original, saved)
        run(['launchctl', 'enable', DOMAIN + '/' + OLD_LABEL])
        bootstrap(OLD_LABEL)
        manifest.update(mode='preview', rollback_at_unix=time.time())
        write(RUNTIME / 'manifest.json', json.dumps(manifest, indent=2) + '\n')
    try:
        wait_ready(4141, seconds=15)
        healthy = True
    except Exception:
        healthy = False
    preview_error = None
    try:
        bootstrap(LABELS['gateway'])
    except Exception as exc:
        preview_error = str(exc)[-500:]
    return {'restored': True, 'healthy': healthy, 'production_port': 4141,
            'preview_error': preview_error}


def confirm(identifier):
    manifest = json.loads((RUNTIME / 'manifest.json').read_text())
    if not identifier or identifier != manifest.get('transaction'):
        raise RuntimeError('The exact current transaction is required')
    ticket = RUNTIME / ('cutover-' + identifier + '.json')
    before = json.loads(ticket.read_text())['before']
    current = preflight()
    assert current['relay_pid'] == before['relay_pid'] and current['default_route'] == before['default_route']
    assert len(http_json(4142, '/v1/models').get('data', [])) > 0
    # Only this separate call can commit. The cutover process itself never does.
    guard.commit(ticket)
    manifest.update(mode='production', confirmed_at_unix=time.time())
    write(RUNTIME / 'manifest.json', json.dumps(manifest, indent=2) + '\n')
    stop(GUARD_LABEL)
    (AGENTS / (GUARD_LABEL + '.plist')).unlink(missing_ok=True)
    print(json.dumps({'confirmed': True, 'transaction': identifier, 'mode': 'production', 'guard_disarmed': True}))


def rollback(approved):
    if not approved:
        raise RuntimeError('Rollback interrupts the transport and requires specific approval.')
    manifest = json.loads((RUNTIME / 'manifest.json').read_text())
    if manifest.get('transaction'):
        ticket = RUNTIME / ('cutover-' + manifest['transaction'] + '.json')
        if ticket.exists() and json.loads(ticket.read_text())['state'] not in guard.TERMINAL:
            guard.request_rollback(ticket)
            print(json.dumps({'rollback_requested': True, 'independent_guard': True}))
            return
    print(json.dumps(restore_old()))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('stage', 'status', 'doctor', 'cutover', 'confirm', 'rollback'))
    parser.add_argument('--approve-disruption', action='store_true')
    parser.add_argument('--transaction')
    args = parser.parse_args()
    if args.action == 'stage':
        stage()
    elif args.action == 'status':
        status()
    elif args.action == 'doctor':
        result = run(['/usr/bin/python3', str(SOURCE / 'copilot-doctor.py')], check=False, timeout=30)
        print(result.stdout, end='')
        if result.stderr:
            print(result.stderr, end='', file=__import__('sys').stderr)
        raise SystemExit(result.returncode)
    elif args.action == 'cutover':
        cutover(args.approve_disruption)
    elif args.action == 'confirm':
        confirm(args.transaction)
    else:
        rollback(args.approve_disruption)


if __name__ == '__main__':
    main()
