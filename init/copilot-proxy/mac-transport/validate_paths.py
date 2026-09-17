#!/usr/bin/env python3
"""Validate each real SSH path through an isolated copy of the HAProxy config."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
import extend_paths as extend


def wait_up(name, control):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        row = extend.stats(control).get(name, {})
        if row.get('status') == 'UP' and row.get('check_status', '').endswith('L7OK'):
            return
        time.sleep(.25)
    raise RuntimeError('Preview path did not become healthy: ' + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    link = extend.link
    if not link.port_free(4143):
        raise RuntimeError('Preview port 4143 is occupied')
    original = (link.RUNTIME / 'haproxy.cfg').read_text()
    before = link.preflight()
    results = []
    with tempfile.TemporaryDirectory(prefix='cp-path-validation-', dir='/tmp') as directory:
        root = Path(directory)
        control = root / 'admin.sock'
        candidate = original.replace('bind 127.0.0.1:4141\n', 'bind 127.0.0.1:4143\n')
        candidate = candidate.replace(str(link.RUNTIME / 'admin.sock'), str(control))
        if 'bind 127.0.0.1:4141\n' in candidate or str(link.RUNTIME / 'admin.sock') in candidate:
            raise RuntimeError('Preview isolation failed')
        if candidate == original or 'bind 127.0.0.1:4143\n' not in candidate:
            raise RuntimeError('Unknown production listener configuration')
        config = root / 'haproxy.cfg'
        config.write_text(candidate)
        link.run([str(link.TOOLS / 'haproxy'), '-c', '-f', str(config)])
        with (root / 'haproxy.log').open('w') as log:
            process = subprocess.Popen([str(link.TOOLS / 'haproxy'), '-db', '-f', str(config)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 4
                while not control.exists() and time.monotonic() < deadline:
                    time.sleep(.05)
                names = ['primary', 'backup', 'direct', 'jump']
                for selected in names:
                    # Only this disposable preview socket is ever mutated.
                    for name in names:
                        extend.control('set server copilot_paths/' + name + ' state ' + ('ready' if name == selected else 'maint'), control)
                    wait_up(selected, control)
                    before_count = int(extend.stats(control)[selected]['stot'])
                    started = time.monotonic()
                    catalog = link.http_json(4143, '/v1/models', timeout=12)
                    ids = sorted(item['id'] for item in catalog.get('data', []))
                    after_count = int(extend.stats(control)[selected]['stot'])
                    if not ids or after_count <= before_count:
                        raise RuntimeError('No verified catalog traffic through ' + selected)
                    results.append({'selected': selected, 'models': len(ids),
                                    'catalog_sha256': hashlib.sha256('\n'.join(ids).encode()).hexdigest(),
                                    'server_counter_before': before_count, 'server_counter_after': after_count,
                                    'catalog_ms': round((time.monotonic() - started) * 1000, 1)})
            except Exception as error:
                try:
                    last_state = {name: {k: row.get(k) for k in ('status', 'check_status', 'check_duration', 'last_chk')}
                                  for name, row in extend.stats(control).items()}
                except OSError:
                    last_state = {}
                args.output.write_text(json.dumps({'failed': True, 'error': str(error), 'results': results,
                    'preview_state': last_state, 'production_routing_modified': False, 'model_requests': 0}, indent=2) + '\n')
                raise
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    # Only the disposable preview is owned by this probe.
                    process.kill(); process.wait(timeout=3)
    after = link.preflight()
    result = {'at_unix': time.time(), 'model_requests': 0, 'production_routing_modified': False,
              'production_config_unchanged': original == (link.RUNTIME / 'haproxy.cfg').read_text(),
              'relay_pid_preserved': before['relay_pid'] == after['relay_pid'], 'results': results,
              'catalogs_identical': len({r['catalog_sha256'] for r in results}) == 1}
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if not result['catalogs_identical'] or not result['production_config_unchanged'] or not result['relay_pid_preserved']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
