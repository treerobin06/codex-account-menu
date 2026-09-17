#!/bin/bash
set -euo pipefail
task_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$task_root"
test_log=$(mktemp /tmp/codex-menu-tests.XXXXXX)
export SWITCHER_TEST_RPC_EXE="$task_root/Tests/fixtures/rpc-fixture.py"
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
# Native process/FD fixtures inspect shared OS state. Keep suite scheduling
# serial; individual tests explicitly exercise reader/switch/lock races.
if ! swift test -j 4 --no-parallel -Xswiftc -F -Xswiftc "$frameworks" "$@" >"$test_log" 2>&1; then
    tail -n 65 "$test_log"
    echo "Full test log: $test_log"
    exit 1
fi
if ! rg -q 'Test run with [1-9][0-9]* tests? .*passed' "$test_log"; then
    tail -n 50 "$test_log"
    echo "ERROR: Swift built but no passing Swift Testing run was recorded: $test_log"
    exit 1
fi
tail -n 18 "$test_log"
echo "Full test log: $test_log"
python3 -m unittest discover -s Tests/collector -p 'test_*.py'
/opt/homebrew/bin/node --test Tests/relay/*.test.mjs
