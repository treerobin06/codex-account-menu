#!/bin/bash
set -euo pipefail
task_root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$task_root"

# All checks use local synthetic fixtures. No production switch or model call.
bash apps/codex-account-menu/scripts/test.sh
python3 -m unittest discover -s init/copilot-proxy -p 'test_*.py'
python3 -m unittest discover -s init/copilot-proxy/mac-transport -p 'test_*.py'
/opt/homebrew/bin/node --test init/copilot-proxy/mac-transport/test_live_http_policy.mjs
