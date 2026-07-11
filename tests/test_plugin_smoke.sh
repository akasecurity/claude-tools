#!/usr/bin/env bash
# tests/test_plugin_smoke.sh — opt-in end-to-end fail-open smoke test.
#
# Everything else in tests/run.sh is a sandboxed unit/flow test against the repo's own
# scripts; this one is the real thing: build the plugin, install it into a real `claude`
# CLI via a throwaway local marketplace, then prove that with bun hidden a Bash tool call
# STILL SUCCEEDS (the guard fails open rather than blocking). Skips cleanly unless opted
# in — it spawns a real `claude -p` session and must never run in CI or a plain
# `tests/run.sh` pass.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ "${AKA_SMOKE:-0}" == 1 ]] || { echo "SKIP test_plugin_smoke (set AKA_SMOKE=1 + real claude session)"; exit 0; }
command -v claude >/dev/null 2>&1 || { echo "SKIP test_plugin_smoke (no claude on PATH)"; exit 0; }

# Resolve the real claude binary now, before any PATH restriction below — `command -v`
# here (plain bash, no inherited shell functions) already returns the executable path,
# but pin it so a later `env PATH=/usr/bin:/bin` can still find + exec it directly.
claude_bin="$(command -v claude)"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CLAUDE_CONFIG_DIR="$tmp/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"

bash tools/build-plugin.sh || { echo "FAIL: tools/build-plugin.sh errored"; exit 1; }

# Self-contained temp local marketplace: this repo has no top-level
# .claude-plugin/marketplace.json (that lives in the separate marketplace repo, out of
# scope here), so synthesize a throwaway one that points at the freshly built plugin.
mp="$tmp/marketplace"
mkdir -p "$mp/.claude-plugin"
cat > "$mp/.claude-plugin/marketplace.json" <<'EOF'
{"name":"aka-smoke-test","owner":{"name":"AKA"},"plugins":[{"name":"claude-tools","source":"./plugin"}]}
EOF
cp -R plugins/claude-tools "$mp/plugin"

"$claude_bin" plugin marketplace add "$mp" || { echo "FAIL: marketplace add"; exit 1; }
"$claude_bin" plugin install claude-tools@aka-smoke-test || { echo "FAIL: plugin install"; exit 1; }

# With bun hidden (PATH stripped to /usr/bin:/bin and the launcher's fallback candidate
# list overridden to a nonexistent path), a Bash tool call must STILL SUCCEED — proving
# the guard fails open instead of blocking when its bun runtime is unavailable.
out="$(env PATH=/usr/bin:/bin AKA_BUN_CANDIDATES="/no/bun" "$claude_bin" -p 'run: echo aka-smoke-ok' 2>&1)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"aka-smoke-ok"* ]]; then
  echo "PASS test_plugin_smoke (fail-open verified)"
else
  echo "FAIL: tool was blocked without bun (should fail-open): rc=$rc out=$out"
  exit 1
fi
