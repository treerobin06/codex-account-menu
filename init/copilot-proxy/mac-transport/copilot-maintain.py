#!/usr/bin/env python3
"""Recover only a missing managed relay; record bounded layered diagnostics."""
import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess

ROOT = Path.home() / '.local/state/copilot-transport'
CLI = Path(os.environ.get('CODEX_ACCOUNT_MENU_CLI', str(Path.home() / 'Applications/Codex Account Menu.app/Contents/Helpers/codex-menu')))
CODEX_HOME = Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
STATE = Path(os.environ.get('CODEX_ACCOUNT_MENU_STATE', str(Path.home() / 'Library/Application Support/Codex Account Menu')))
SOURCE = Path(__file__).resolve().parent


def main():
    os.umask(0o077)
    previous_file = ROOT / 'health.latest.json'
    try:
        previous = json.loads(previous_file.read_text())
    except (OSError, ValueError):
        previous = {}
    report = {'at': datetime.datetime.now().astimezone().isoformat(), 'model_requests': 0}
    try:
        result = subprocess.run([str(CLI), 'maintain-relay', '--home', str(CODEX_HOME),
            '--state', str(STATE)],
            capture_output=True, text=True, timeout=20,
            env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin'})
        response = json.loads(result.stdout)
        if not isinstance(response, dict):
            raise ValueError('Invalid maintenance response')
        if result.returncode:
            # Source-switch recovery/lock errors pause automatic work. No kills,
            # credentials, config rewrites, or attempted account recovery here.
            report['maintenance'] = {'action': 'paused', 'exit_code': result.returncode}
        else:
            report['maintenance'] = {key: response.get(key) for key in ('action', 'pid', 'transportVersion', 'upgradePending')}
            if response.get('action') != 'not-required':
                spec = importlib.util.spec_from_file_location('copilot_doctor', SOURCE / 'copilot-doctor.py')
                doctor = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(doctor)
                report['diagnostic'] = doctor.diagnose()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report['maintenance'] = {'action': 'error', 'type': type(error).__name__}
    temporary = previous_file.with_suffix('.new')
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(previous_file)
    def signal(value):
        maintenance = value.get('maintenance', {})
        diagnostic = value.get('diagnostic', {})
        return {'action': maintenance.get('action'), 'pid': maintenance.get('pid'),
                'upgrade_pending': maintenance.get('upgradePending'), 'healthy': diagnostic.get('healthy'),
                'available_paths': diagnostic.get('available_paths')}
    if signal(previous) != signal(report):
        print(json.dumps({'at': report['at'], **signal(report)}))


if __name__ == '__main__':
    main()
