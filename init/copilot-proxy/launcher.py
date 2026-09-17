#!/usr/bin/env python3
"""Load the existing local credential into a private runtime, then exec Node."""
import json
import os
from pathlib import Path
import re
from urllib.parse import quote

os.umask(0o077)
runtime = Path(os.environ['RUNTIME_DIRECTORY'])
credential = Path(os.environ['CREDENTIALS_DIRECTORY']) / 'copilot-config'
raw = credential.read_text()
config = json.loads(re.sub(r',\s*([}\]])', r'\1',
                          re.sub(r'(?m)^\s*//.*$', '', raw)))
account = config['lastLoggedInUser']
token = config['authTokens'][account['host'] + ':' + account['login']]['token']
if not isinstance(token, str) or not token:
    raise SystemExit('The selected Copilot account has no saved credential')
app_home = runtime / 'home'
app_dir = app_home / '.local/share/copilot-proxy'
app_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
token_path = app_dir / 'github_token'
token_path.write_text(token)
token_path.chmod(0o600)
env = dict(os.environ)
env.update(HOME=str(app_home), COPILOT_PROXY_DATA_DIR=str(app_dir),
           TREE_COPILOT_SOCKET=str(runtime / 'http.sock'), NO_COLOR='1',
           COPILOT_PROXY_AUTH_MODE='github-cli')
for name in ('GITHUB_TOKEN', 'GH_TOKEN', 'COPILOT_GITHUB_TOKEN',
             'COPILOT_PROXY_EXPOSE_TOKEN', 'NODE_OPTIONS'):
    env.pop(name, None)
network_credential = Path(os.environ['CREDENTIALS_DIRECTORY']) / 'network-proxy'
use_network_proxy = network_credential.is_file()
if use_network_proxy:
    network = dict(line.split('=', 1) for line in network_credential.read_text().splitlines() if '=' in line)
    proxy_url = ('http://' + quote(network['DIRECT_USER'], safe='') + ':'
                 + quote(network['DIRECT_PASS'], safe='') + '@127.0.0.1:17998')
    env.update(HTTP_PROXY=proxy_url, HTTPS_PROXY=proxy_url,
               http_proxy=proxy_url, https_proxy=proxy_url,
               NO_PROXY='localhost,127.0.0.1,::1', no_proxy='localhost,127.0.0.1,::1')
    env.pop('ALL_PROXY', None)
    env.pop('all_proxy', None)
base = Path(os.environ.get('TREE_COPILOT_PACKAGE', '/opt/tree-copilot-proxy'))
args = ['/usr/bin/node', '--require', str(base / 'unix-listener.cjs'),
        str(base / 'dist/main.js'), 'start', '--host', '127.0.0.1',
        '--port', '4141', '--account-type', 'enterprise',
        '--preset', 'custom']
if os.environ.get('TREE_COPILOT_VERBOSE') == '1':
    args.append('--verbose')
if use_network_proxy:
    args.append('--proxy-env')
os.execve(args[0], args, env)
