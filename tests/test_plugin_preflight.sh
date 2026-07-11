#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
P="config/hooks/preflight.sh"; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; fails=0
printf '#!/usr/bin/env sh\nexit 0\n' > "$tmp/bun"; chmod +x "$tmp/bun"
# bun present -> silent, exit 0
out="$(printf '{}' | PATH="$tmp:$PATH" "$P" 2>&1)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] || { echo "FAIL present: '$out' rc=$rc"; fails=1; }
# bun absent -> loud notice on stderr, exit 2 (non-blocking for SessionStart, but visible)
err="$(printf '{}' | env -i HOME="$tmp/none" PATH=/usr/bin:/bin AKA_BUN_CANDIDATES="/no/bun" "$P" 2>&1 1>/dev/null)"; rc=$?
[[ $rc -eq 2 && "$err" == *"guards are INACTIVE"* ]] || { echo "FAIL absent: '$err' rc=$rc"; fails=1; }
[ "$fails" -eq 0 ] && echo "PASS test_plugin_preflight" || exit 1
