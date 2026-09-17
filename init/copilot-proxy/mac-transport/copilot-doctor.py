#!/usr/bin/env python3
"""Read-only layered Copilot health. No inference, credentials or route changes."""
import concurrent.futures
import datetime
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import extend_paths

ROOT = Path.home() / '.local/state/copilot-transport'
PORTS = {'primary': 14141, 'backup': 14142, 'direct': 14143, 'jump': 14144}
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def fetch(port, path):
    started = time.monotonic()
    row = {}
    try:
        request = urllib.request.Request('http://127.0.0.1:%d%s' % (port, path), headers={'Authorization': 'Bearer local'})
        try:
            response = OPENER.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            body = json.loads(response.read(256_000))
            row['http'] = response.status
        if not isinstance(body, dict):
            raise ValueError('Expected a JSON object')
        if path == '/v1/models':
            ids = sorted(item['id'] for item in body.get('data', []) if isinstance(item, dict) and isinstance(item.get('id'), str))
            row.update(models=len(ids), catalog_sha256=hashlib.sha256('\n'.join(ids).encode()).hexdigest(),
                       valid=response.status == 200 and bool(ids))
        else:
            row.update({key: body.get(key) for key in ('status', 'pid', 'enabled', 'activeRequests', 'activeWebSockets',
                'transportVersion', 'httpIdleTimeoutMs', 'upstreamConnectTimeoutMs') if key in body})
            if isinstance(body.get('networkPolicy'), dict):
                row['networkPolicy'] = {key: body['networkPolicy'].get(key) for key in
                    ('version', 'source', 'active', 'httpIdleTimeoutMs', 'appliesToNewHttpRequests', 'appliedRequests')}
            row['valid'] = response.status == 200 and body.get('status') in ('ready', 'enabled', 'disabled')
    except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException) as error:
        row.update(valid=False, error=type(error).__name__)
    row['elapsed_ms'] = round((time.monotonic() - started) * 1000, 1)
    return row


def service(name):
    label = 'com.tree.copilot-link-' + name
    try:
        result = subprocess.run(['launchctl', 'print', 'gui/%d/%s' % (os.getuid(), label)], capture_output=True, text=True, timeout=4)
    except (OSError, subprocess.SubprocessError) as error:
        return {'loaded': False, 'state': 'unavailable', 'pid': None, 'error': type(error).__name__}
    state = re.search(r'^\s*state = (.+)$', result.stdout, re.MULTILINE)
    pid = re.search(r'^\s*pid = (\d+)$', result.stdout, re.MULTILINE)
    return {'loaded': result.returncode == 0, 'state': state.group(1) if state else None,
            'pid': int(pid.group(1)) if pid else None}


def timeout_policy_ready(relay):
    return relay.get('httpIdleTimeoutMs') == 600000 and (
        relay.get('transportVersion') == 2 or relay.get('networkPolicy', {}).get('active') is True)


def diagnose():
    result = {'at': datetime.datetime.now().astimezone().isoformat(), 'read_only': True, 'model_requests': 0}
    try:
        rows = extend_paths.stats()
        result['gateway'] = {'reachable': True}
    except (OSError, ValueError) as error:
        rows = {}
        result['gateway'] = {'reachable': False, 'error': type(error).__name__}
    active_paths = {name: port for name, port in PORTS.items() if name in rows or name in ('primary', 'backup')}
    jobs = {'relay': (4142, '/healthz'), 'application': (4141, '/readyz'), 'client_catalog': (4142, '/v1/models')}
    jobs.update({name: (port, '/v1/models') for name, port in active_paths.items()})
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {name: pool.submit(fetch, *args) for name, args in jobs.items()}
        checks = {name: future.result() for name, future in futures.items()}
    for name in ('relay', 'application', 'client_catalog'):
        result[name] = checks[name]
    result['paths'] = {}
    for name, port in active_paths.items():
        result['paths'][name] = {'port': port, 'service': service(name),
            'health': {key: rows.get(name, {}).get(key) for key in ('status', 'check_status', 'check_duration', 'scur')},
            'catalog': checks[name]}
    hashes = {checks[name]['catalog_sha256'] for name in active_paths if checks[name].get('valid')}
    if checks['client_catalog'].get('valid'):
        hashes.add(checks['client_catalog']['catalog_sha256'])
    result['catalogs_consistent'] = len(hashes) == 1
    result['available_paths'] = [name for name in active_paths if checks[name].get('valid')]
    result['independent_path_available'] = any(name in result['available_paths'] for name in ('direct', 'jump'))
    result['relay_upgrade_pending'] = checks['relay'].get('transportVersion') != 2
    result['relay_binary_upgrade_pending'] = result['relay_upgrade_pending']
    result['network_timeout_optimized'] = timeout_policy_ready(checks['relay'])
    result['healthy'] = (checks['relay'].get('enabled') is True and checks['application'].get('valid') is True
                         and checks['client_catalog'].get('valid') is True and result['catalogs_consistent'])
    return result


if __name__ == '__main__':
    report = diagnose()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    sys.exit(0 if report['healthy'] else 2)
