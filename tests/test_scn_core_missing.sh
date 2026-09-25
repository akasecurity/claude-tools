#!/usr/bin/env bash
# A guard hook that cannot load the vendored core must block (outbound Bash / all web), loudly.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp -R config/hooks "$tmp/hooks"; rm -f "$tmp/hooks/lib/guard-core.js"
run() { printf '%s' "$2" | bun "$tmp/hooks/$1.ts" 2>"$tmp/err"; }
set +e
run command-guard '{"tool_name":"Bash","tool_input":{"command":"curl https://x.test"}}'; a=$?
run command-guard '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'; b=$?
run leak-guard '{"tool_name":"WebSearch","tool_input":{"query":"hello"}}'; c=$?
set -e
[ "$a" = 2 ] || { echo "FAIL: outbound Bash allowed without core (exit $a)"; exit 1; }
[ "$b" = 0 ] || { echo "FAIL: local Bash blocked without core (exit $b)"; exit 1; }
[ "$c" = 2 ] || { echo "FAIL: web query allowed without core (exit $c)"; exit 1; }
grep -q 'guard-core' "$tmp/err" || { echo "FAIL: no core-missing notice"; exit 1; }
echo PASS
