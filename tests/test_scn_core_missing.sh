#!/usr/bin/env bash
# A guard hook that cannot load the vendored core must block (outbound Bash / all web), loudly.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp -R config/hooks "$tmp/hooks"; rm -f "$tmp/hooks/lib/guard-core.js"
CG_CORE_NOTICE="command-guard: the guard-core library is missing, unreadable or incompatible — only conservative fallback checks ran. Reinstall to restore config/hooks/lib/guard-core.js."
CG_CORE_BLOCK="BLOCKED (command-guard): the guard-core library is missing or unreadable, so the egress scan can't run — blocking this outbound command as a precaution. Reinstall to restore config/hooks/lib/guard-core.js."
LG_CORE_BLOCK="egress blocked (leak-guard): the guard-core library is missing or unreadable, so the egress scan can't run — blocking this query as a precaution. Reinstall to restore config/hooks/lib/guard-core.js."
run() { printf '%s' "$2" | bun "$tmp/hooks/$1.ts" 2>"$tmp/err.$3"; }
set +e
run command-guard '{"tool_name":"Bash","tool_input":{"command":"curl https://x.test"}}' a; a=$?
run command-guard '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' b; b=$?
run leak-guard '{"tool_name":"WebSearch","tool_input":{"query":"hello"}}' c; c=$?
set -e
[ "$a" = 2 ] || { echo "FAIL: outbound Bash allowed without core (exit $a)"; exit 1; }
[ "$b" = 0 ] || { echo "FAIL: local Bash blocked without core (exit $b)"; exit 1; }
[ "$c" = 2 ] || { echo "FAIL: web query allowed without core (exit $c)"; exit 1; }
grep -qF "$CG_CORE_BLOCK" "$tmp/err.a" || { echo "FAIL: no command-guard core-missing block line"; exit 1; }
grep -qF "$CG_CORE_NOTICE" "$tmp/err.b" || { echo "FAIL: no command-guard core-missing notice"; exit 1; }
grep -qF "$LG_CORE_BLOCK" "$tmp/err.c" || { echo "FAIL: no leak-guard core-missing line"; exit 1; }
echo PASS
