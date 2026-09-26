#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fails=0
bash tools/build-plugin.sh || { echo "FAIL: generator errored"; exit 1; }
D=plugins/claude-tools
# manifest present with correct name + version
[[ "$(jq -r .name "$D/.claude-plugin/plugin.json")" == claude-tools ]] || { echo "FAIL name"; fails=1; }
[[ "$(jq -r .version "$D/.claude-plugin/plugin.json")" == "$(cat VERSION)" ]] || { echo "FAIL version"; fails=1; }
# the three guards + launcher + preflight are present
for f in command-guard.ts leak-guard.ts mcp-guard.ts bun-hook-launch.sh preflight.sh; do
  [[ -f "$D/hooks/$f" ]] || { echo "FAIL missing $f"; fails=1; }
done
# rtk-safe is installer-only (needs a permissions allowlist a plugin can't apply) — must NOT ship
[[ -f "$D/hooks/rtk-safe.ts" ]] && { echo "FAIL: rtk-safe.ts must not ship in the plugin"; fails=1; }
# hooks.json: command-guard registered on Bash/PreToolUse via the launcher
cmd="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command' "$D/hooks/hooks.json" | grep command-guard || true)"
[[ "$cmd" == *'bun-hook-launch.sh'*'command-guard.ts'* ]] || { echo "FAIL command-guard registration: '$cmd'"; fails=1; }
# only one Bash entry (no second/rtk-safe entry riding along)
bashcount="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash")' "$D/hooks/hooks.json" | jq -s 'length')"
[[ "$bashcount" -eq 1 ]] || { echo "FAIL: expected exactly 1 Bash PreToolUse entry, got $bashcount"; fails=1; }
# hooks.json: leak-guard registered on the web-egress matcher via the launcher
leak="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="WebSearch|WebFetch|mcp__searxng__") | .hooks[].command' "$D/hooks/hooks.json" | grep leak-guard || true)"
[[ "$leak" == *'bun-hook-launch.sh'*'leak-guard.ts'* ]] || { echo "FAIL leak-guard registration: '$leak'"; fails=1; }
# hooks.json: mcp-guard registered on every MCP tool via the launcher
mcpg="$(jq -r '.hooks.PreToolUse[] | select(.matcher=="mcp__.*") | .hooks[].command' "$D/hooks/hooks.json" | grep mcp-guard || true)"
[[ "$mcpg" == *'bun-hook-launch.sh'*'mcp-guard.ts'* ]] || { echo "FAIL mcp-guard registration: '$mcpg'"; fails=1; }
# the plugin ships no compiled sidecars: mcp-guard runs there with no policy (scan only)
[[ -e "$D/hooks/lib/mcp-policy.json" ]] && { echo "FAIL: mcp-policy.json must not ship in the plugin"; fails=1; }
# preflight under SessionStart
pf="$(jq -r '.hooks.SessionStart[].hooks[].command' "$D/hooks/hooks.json" | grep preflight || true)"
[[ "$pf" == *'preflight.sh'* ]] || { echo "FAIL preflight registration"; fails=1; }
# schema gate
if command -v claude >/dev/null 2>&1; then
  claude plugin validate plugins/claude-tools >/dev/null 2>&1 || { echo "FAIL: claude plugin validate"; fails=1; }
else
  echo "note: 'claude' not on PATH — skipping validate (CI must run it)"
fi
# drift: regenerating must not change the committed tree
bash tools/build-plugin.sh
if ! git diff --quiet -- plugins/claude-tools; then
  echo "FAIL: plugins/claude-tools is stale — run tools/build-plugin.sh and commit"; git --no-pager diff --stat -- plugins/claude-tools; fails=1
fi
[ "$fails" -eq 0 ] && echo "PASS test_plugin_build" || exit 1
