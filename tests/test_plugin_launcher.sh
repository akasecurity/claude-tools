#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
L="config/hooks/bun-hook-launch.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
# fake bun that proves the guard ran and echoes stdin
printf '#!/usr/bin/env sh\necho "RAN $1 <$(cat)>"; exit 5\n' > "$tmp/bun"; chmod +x "$tmp/bun"

# CASE 1: bun on PATH -> launcher execs it (guard runs), exit passes through (5)
out="$(printf '{"t":1}' | PATH="$tmp:$PATH" "$L" /g.ts)"; rc=$?
[[ "$out" == 'RAN /g.ts <{"t":1}>' && $rc -eq 5 ]] || { echo "FAIL case1: '$out' rc=$rc"; fails=1; }

# CASE 2: bun only at ~/.bun/bin (off PATH) -> probe finds it
mkdir -p "$tmp/h/.bun/bin"; cp "$tmp/bun" "$tmp/h/.bun/bin/bun"
out="$(printf '{}' | env -i HOME="$tmp/h" PATH=/usr/bin:/bin "$L" /g.ts)"; rc=$?
[[ "$out" == 'RAN /g.ts <{}>' && $rc -eq 5 ]] || { echo "FAIL case2: '$out' rc=$rc"; fails=1; }

# CASE 3: bun absent everywhere -> FAIL OPEN: exit 0, warning on stderr, no block
err="$(printf '{}' | env -i HOME="$tmp/none" PATH=/usr/bin:/bin AKA_BUN_CANDIDATES="/no/bun" "$L" /g.ts 2>&1 1>/dev/null)"; rc=$?
[[ $rc -eq 0 ]] || { echo "FAIL case3 must fail-open (exit 0) got rc=$rc"; fails=1; }
[[ "$err" == *"guard INACTIVE"* ]] || { echo "FAIL case3 must warn loudly: '$err'"; fails=1; }

# CASE 4: no guard-script arg -> FAIL OPEN (exit 0), no unbound-variable abort
printf '{}' | "$L" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] || { echo "FAIL case4: zero-arg must fail-open (exit 0) got rc=$rc"; fails=1; }

[ "$fails" -eq 0 ] && echo "PASS test_plugin_launcher" || exit 1
