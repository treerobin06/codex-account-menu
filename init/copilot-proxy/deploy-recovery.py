#!/usr/bin/env python3
"""Install recovery policy and a health timer without restarting Copilot."""
import argparse
import json
from pathlib import Path
import subprocess

SOURCE = Path(__file__).resolve().parent
FILES = {
    '30-recovery.conf': '/etc/systemd/system/tree-copilot-proxy.service.d/30-recovery.conf',
    'health.py': '/opt/tree-copilot-proxy/health.py',
    'tree-copilot-health.service': '/etc/systemd/system/tree-copilot-health.service',
    'tree-copilot-health.timer': '/etc/systemd/system/tree-copilot-health.timer',
}
REMOTE = r'''
import datetime,hashlib,json,pathlib,subprocess,time
def run(args,check=True):
    p=subprocess.run(args,capture_output=True,text=True,timeout=20)
    if check and p.returncode: raise RuntimeError(str(args[:3])+': '+p.stderr[-1500:])
    return p
def pid():
    return run(['systemctl','show','tree-copilot-proxy.service','-p','MainPID','--value']).stdout.strip()
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,text,mode=0o644):
    p.parent.mkdir(parents=True,exist_ok=True)
    q=p.with_suffix(p.suffix+'.new');q.write_text(text);q.chmod(mode);q.replace(p)
if run(['hostname']).stdout.strip()!=payload['expected_hostname']: raise RuntimeError('Wrong server')
if payload['action']=='rollback':
    backup=pathlib.Path(payload['backup'])
    if backup.parent != pathlib.Path('/var/backups') or not backup.name.startswith('tree-copilot-recovery-'):
        raise RuntimeError('Unknown recovery backup directory')
    receipt=json.loads((backup/'receipt.json').read_text())
    for name,sha in receipt['installed_sha256'].items():
        p=pathlib.Path(name)
        if not p.is_file() or p.is_symlink() or digest(p)!=sha: raise RuntimeError('Changed file; refusing rollback: '+name)
    before=pid()
    run(['systemctl','disable','--now','tree-copilot-health.timer'])
    for name in receipt['installed_sha256']: pathlib.Path(name).unlink()
    run(['systemctl','daemon-reload'])
    print(json.dumps({'state':'rolled-back','copilot_pid_before':before,'copilot_pid_after':pid()}))
else:
    if run(['systemctl','is-active','tree-copilot-proxy.service']).stdout.strip()!='active': raise RuntimeError('Copilot is not currently active')
    files={pathlib.Path(k):v for k,v in payload['files'].items()}
    for p in files:
        if p.exists() or p.is_symlink(): raise RuntimeError('Existing recovery asset must be reviewed: '+str(p))
    before=pid()
    backup=pathlib.Path('/var/backups/tree-copilot-recovery-'+datetime.datetime.now().strftime('%Y%m%dT%H%M%S'))
    backup.mkdir(mode=0o700)
    write(backup/'base-unit.txt',run(['systemctl','cat','tree-copilot-proxy.service']).stdout,0o600)
    receipt={'state':'preparing','copilot_pid_before':before,'backup':str(backup),'installed_sha256':{},
             'service_state':run(['systemctl','is-active','tree-copilot-proxy.service']).stdout.strip()}
    try:
        for p,text in files.items():
            write(p,text);receipt['installed_sha256'][str(p)]=digest(p)
        run(['systemd-analyze','verify','/etc/systemd/system/tree-copilot-proxy.service',
             '/etc/systemd/system/tree-copilot-health.service','/etc/systemd/system/tree-copilot-health.timer'])
        run(['systemctl','daemon-reload'])
        run(['systemctl','enable','--now','tree-copilot-health.timer'])
        receipt['copilot_pid_after']=pid()
        if before!=receipt['copilot_pid_after']: raise RuntimeError('Copilot PID changed unexpectedly')
        receipt['policy']=run(['systemctl','show','tree-copilot-proxy.service','-p','RestartUSec','-p','RestartSteps',
                              '-p','RestartMaxDelayUSec','-p','StartLimitIntervalUSec','-p','After','-p','OnFailure']).stdout
        receipt['timer']=run(['systemctl','show','tree-copilot-health.timer','-p','ActiveState','-p','UnitFileState']).stdout
        receipt.update(state='active',at=datetime.datetime.now().astimezone().isoformat(),production_restarted=False)
        write(backup/'receipt.json',json.dumps(receipt,indent=2)+'\n',0o600)
        print(json.dumps(receipt,indent=2))
    except Exception:
        run(['systemctl','disable','--now','tree-copilot-health.timer'],check=False)
        for p in files:
            if p.is_file() and digest(p)==receipt['installed_sha256'].get(str(p)):p.unlink()
        run(['systemctl','daemon-reload'],check=False)
        receipt['state']='failed-and-restored'
        write(backup/'receipt.json',json.dumps(receipt,indent=2)+'\n',0o600)
        raise
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('plan', 'apply', 'rollback'))
    parser.add_argument('--backup')
    parser.add_argument('--ssh-host', default='copilot-server')
    parser.add_argument('--ssh-config', type=Path, default=Path.home() / '.ssh/config')
    parser.add_argument('--expected-hostname', help='Required for apply/rollback; must match the remote hostname exactly')
    args = parser.parse_args()
    if args.action == 'plan':
        print(json.dumps({'files': FILES, 'daemon_reload': True, 'restart_copilot': False,
                          'automatic_recovery': '5s to 5min exponential backoff',
                          'alert': 'Only after sustained readiness failure; existing cooled-down mail relay'}, indent=2))
        return
    if not args.expected_hostname:
        parser.error('--expected-hostname is required before any SSH connection')
    if args.ssh_host.startswith('-') or any(c.isspace() for c in args.ssh_host):
        parser.error('Invalid SSH host alias')
    if args.action == 'rollback' and not args.backup:
        parser.error('--backup is required for rollback')
    payload = {'action': args.action, 'backup': args.backup, 'expected_hostname': args.expected_hostname,
               'files': {target: (SOURCE / source).read_text() for source, target in FILES.items()}}
    script = 'payload = ' + repr(payload) + '\n' + REMOTE
    command = ['ssh', '-F', str(args.ssh_config), '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6',
               '-o', 'ControlMaster=no', '-o', 'ControlPath=none', args.ssh_host, 'sudo -n python3 -']
    result = subprocess.run(command, input=script, text=True, capture_output=True, timeout=90)
    print(result.stdout, end='')
    if result.stderr:
        print(result.stderr, end='', file=__import__('sys').stderr)
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
