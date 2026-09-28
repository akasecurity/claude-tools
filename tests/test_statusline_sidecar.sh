#!/usr/bin/env bash
# Status sidecar end to end: env set → <dir>/<session_id>.json with the stdin's
# context_window; env unset → no file. Sandboxed HOME/TMPDIR, never a real profile.
set -euo pipefail
SB="$(mktemp -d "${TMPDIR:-/tmp}/aka-sl-sc.XXXXXX")"; trap 'rm -rf "$SB"' EXIT
export HOME="$SB" TMPDIR="$SB"; unset CLAUDE_CONFIG_DIR XDG_RUNTIME_DIR CLAUDE_TOOLS_STATUS_SIDECAR_DIR
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/hooks/statusline.ts"
IN='{"session_id":"e2e-1","cwd":"/tmp","model":{"id":"m1"},"context_window":{"used_percentage":12,"context_window_size":200000,"total_input_tokens":24000}}'
fail=0
echo "$IN" | bun "$HOOK" >/dev/null
[ -z "$(find "$SB" -name 'e2e-1.json')" ] || { echo "✗ unset env wrote a sidecar"; fail=1; }
echo "$IN" | CLAUDE_TOOLS_STATUS_SIDECAR_DIR="$SB/sc" bun "$HOOK" >/dev/null
F="$SB/sc/e2e-1.json"
[ -f "$F" ] || { echo "✗ no sidecar at $F"; exit 1; }
[ "$(jq -r .context_window.used_percentage "$F")" = 12 ] || { echo "✗ used_percentage"; fail=1; }
[ "$(jq -r .model_id "$F")" = m1 ] || { echo "✗ model_id"; fail=1; }
[ "$(stat -f %Lp "$SB/sc" 2>/dev/null || stat -c %a "$SB/sc")" = 700 ] || { echo "✗ dir mode"; fail=1; }
[ $fail = 0 ] && echo "  ✓ statusline sidecar e2e" ; exit $fail
