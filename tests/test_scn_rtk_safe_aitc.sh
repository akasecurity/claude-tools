#!/usr/bin/env bash
# With ai-tc installed and enabled in the profile, rtk-safe must not rewrite Bash.
# With ai-tc merely registered (not explicitly enabled), rtk-safe keeps rewriting.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v rtk >/dev/null || { echo "SKIP: rtk not installed"; exit 0; }
cfg="$(mktemp -d)"; trap 'rm -rf "$cfg"' EXIT
cp -R config/hooks "$cfg/hooks"
in='{"tool_name":"Bash","tool_input":{"command":"git status"}}'
out="$(printf '%s' "$in" | CLAUDE_CONFIG_DIR="$cfg" HOME="$cfg/home" bun "$cfg/hooks/rtk-safe.ts")"
grep -q updatedInput <<<"$out" || { echo "FAIL: baseline did not rewrite"; exit 1; }

mkdir -p "$cfg/plugins/cache/akasecurity/ai-tc/1.0.0"
echo '{"version":2,"plugins":{"ai-tc@akasecurity":[{"version":"1.0.0"}]}}' > "$cfg/plugins/installed_plugins.json"

# registered + cached, but NOT explicitly enabled (enabledPlugins false): must NOT count
# as present, so the rewrite still happens.
echo '{"enabledPlugins":{"ai-tc@akasecurity":false}}' > "$cfg/settings.json"
out="$(printf '%s' "$in" | CLAUDE_CONFIG_DIR="$cfg" HOME="$cfg/home" bun "$cfg/hooks/rtk-safe.ts")"
grep -q updatedInput <<<"$out" || { echo "FAIL: did not rewrite while ai-tc registered but enabledPlugins false: $out"; exit 1; }

# registered + cached + explicitly enabled: rtk-safe defers to ai-tc, no rewrite.
echo '{"enabledPlugins":{"ai-tc@akasecurity":true}}' > "$cfg/settings.json"
out="$(printf '%s' "$in" | CLAUDE_CONFIG_DIR="$cfg" HOME="$cfg/home" bun "$cfg/hooks/rtk-safe.ts")"
[ -z "$out" ] || { echo "FAIL: rewrote while ai-tc present: $out"; exit 1; }

echo PASS
