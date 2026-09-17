#!/usr/bin/env python3
"""Dedicated Copilot SSH paths over physical interfaces; never edits routes/VPNs."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import shlex
import subprocess
import sys

USER_HOME = Path.home()
RUNTIME = USER_HOME / '.local/state/copilot-transport'
TOOLS = USER_HOME / '.local/share/copilot-transport'
def endpoint(prefix):
    raw = os.environ.get(prefix + '_HOST')
    if not raw:
        raise ValueError(prefix + '_HOST is required; no endpoint is assumed')
    host = str(ipaddress.IPv4Address(raw))
    port = int(os.environ.get(prefix + '_PORT', '22'))
    if not 1 <= port <= 65535:
        raise ValueError('SSH port must be between 1 and 65535')
    return host, port


def configuration_environment():
    """Validated non-secret settings copied into these helpers' launchd jobs."""
    values = {}
    for prefix in ('COPILOT_DIRECT', 'COPILOT_JUMP'):
        host, port = endpoint(prefix)
        values.update({prefix + '_HOST': host, prefix + '_PORT': str(port)})
    return values

IP_BOUND_IF = 25  # Darwin SDK netinet/in.h; deliberately no Linux fallback.


def output(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=4)
    return result.stdout.strip() if result.returncode == 0 else ''


def candidates():
    default = output(['/sbin/route', '-n', 'get', 'default'])
    match = re.search(r'^\s*interface:\s*(en\d+)\s*$', default, re.MULTILINE)
    preferred = match.group(1) if match else 'en0'
    names = [name for _, name in socket.if_nameindex() if re.fullmatch(r'en\d+', name)]
    names.sort(key=lambda name: (name != preferred, name != 'en0', name))
    for name in names:
        source = output(['/usr/sbin/ipconfig', 'getifaddr', name])
        try:
            address = ipaddress.IPv4Address(source)
        except ipaddress.AddressValueError:
            continue
        if address.is_loopback or address.is_link_local or address.is_unspecified:
            continue
        yield name, source


def choose_native(target):
    if sys.platform != 'darwin':
        raise RuntimeError('This helper requires macOS interface-scoped sockets')
    for interface, source in candidates():
        route = output(['/sbin/route', '-n', 'get', '-ifscope', interface, target[0]])
        if not re.search(r'^\s*interface:\s*' + re.escape(interface) + r'\s*$', route, re.MULTILINE):
            continue
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.settimeout(2)
                probe.setsockopt(socket.IPPROTO_IP, IP_BOUND_IF, socket.if_nametoindex(interface))
                probe.bind((source, 0))
                probe.connect(target)
            return interface, source
        except OSError:
            continue
    raise RuntimeError('No physical IPv4 path to the dedicated SSH endpoint')


def command(profile, interface=None, source=None):
    common = ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
              '-o', 'UpdateHostKeys=no', '-o', 'IdentitiesOnly=yes',
              '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
              '-o', 'ForwardAgent=no', '-o', 'ConnectionAttempts=1',
              '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3']
    direct = endpoint('COPILOT_DIRECT')
    if profile == 'jump':
        return ['/usr/bin/ssh', '-F', str(RUNTIME / 'ssh_config'), *common,
                '-o', 'ConnectTimeout=20', '-o', 'HostName=' + direct[0], '-p', str(direct[1]),
                '-o', 'ProxyCommand=/usr/bin/python3 ' + shlex.quote(str(TOOLS / 'native-ssh.py')) + ' jump-host',
                '-NT', '-L', '127.0.0.1:14144:/run/tree-copilot-proxy/http.sock', 'copilot-server']
    if not interface or not re.fullmatch(r'en\d+', interface):
        raise ValueError('A physical en interface is required')
    ipaddress.IPv4Address(source)
    bound = ['-B', interface, '-b', source]
    if profile == 'direct':
        return ['/usr/bin/ssh', '-F', str(RUNTIME / 'ssh_config'), *common, *bound,
                '-o', 'ConnectTimeout=8', '-o', 'HostName=' + direct[0], '-p', str(direct[1]),
                '-NT', '-L', '127.0.0.1:14143:/run/tree-copilot-proxy/http.sock', 'copilot-server']
    if profile == 'jump-host':
        jump = endpoint('COPILOT_JUMP')
        return ['/usr/bin/ssh', '-F', str(USER_HOME / '.ssh/config'), *common, *bound,
                '-o', 'ConnectTimeout=8', '-o', 'LogLevel=ERROR',
                '-o', 'HostName=' + jump[0], '-p', str(jump[1]),
                '-W', direct[0] + ':' + str(direct[1]), 'copilot-jump']
    raise ValueError('Unknown dedicated path')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', choices=('direct', 'jump', 'jump-host'))
    parser.add_argument('--check', action='store_true', help='Only probe physical reachability')
    args = parser.parse_args()
    selection = None
    if args.profile != 'jump' or args.check:
        selection = choose_native(endpoint('COPILOT_DIRECT' if args.profile == 'direct' else 'COPILOT_JUMP'))
    if args.check:
        print(json.dumps({'path': args.profile, 'interface': selection[0], 'source': selection[1],
                          'physical_path': True, 'configuration_changed': False}))
        return
    if selection:
        # ProxyCommand stdout carries SSH bytes only.
        print(json.dumps({'path': args.profile, 'interface': selection[0], 'source': selection[1]}), file=sys.stderr)
    os.execv('/usr/bin/ssh', command(args.profile, *(selection or (None, None))))


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
