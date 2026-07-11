#!/usr/bin/env bash
# Assemble plugins/claude-tools/ from config/ (single source of truth). Regenerate + commit after
# any config change; CI drift-checks. Ships ONLY the guard hooks (see plan Global Constraints).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="plugins/claude-tools"; HK="$OUT/hooks"
BUNDLED="command-guard leak-guard"   # guard hooks the plugin ships (recommended, runtime=bun)
rm -rf "$OUT"; mkdir -p "$OUT/.claude-plugin" "$HK"

# manifest
jq -n --arg v "$(cat VERSION)" '{
  name:"claude-tools", version:$v, author:{name:"AKA Security"},
  homepage:"https://akasecurity.io", repository:"https://github.com/akasecurity/claude-tools",
  description:"AKA Claude Tools guard hooks (command-guard, leak-guard) for your active profile. Requires bun; guards fail OPEN (never block) and announce themselves inactive at session start if bun is missing. For the full hardened ISOLATED profile (credential-read denies, rtk-safe permission allowlist, status line, alias), install the full kit — see the project README for npm, Homebrew, and installer options."
}' > "$OUT/.claude-plugin/plugin.json"

# copy launcher + preflight + shared lib (secret-patterns.json only, for defense-in-depth)
install -m 0755 config/hooks/bun-hook-launch.sh config/hooks/preflight.sh "$HK"/
mkdir -p "$HK/lib" && cp config/hooks/lib/secret-patterns.json "$HK/lib/secret-patterns.json"

# copy each bundled guard + build its hooks.json entry from additions.json
hooks='{"hooks":{"PreToolUse":[],"SessionStart":[]}}'
for id in $BUNDLED; do
  hookpath="$(jq -r --arg id "$id" '.additions[]|select(.id==$id).hook' config/additions.json)"
  matcher="$(jq -r --arg id "$id" '.additions[]|select(.id==$id).matcher' config/additions.json)"
  event="$(jq -r --arg id "$id" '.additions[]|select(.id==$id).event' config/additions.json)"
  base="$(basename "$hookpath")"
  install -m 0755 "config/$hookpath" "$HK/$base"
  cmd="\"\${CLAUDE_PLUGIN_ROOT}/hooks/bun-hook-launch.sh\" \"\${CLAUDE_PLUGIN_ROOT}/hooks/$base\""
  hooks="$(jq --arg m "$matcher" --arg e "$event" --arg c "$cmd" \
    '.hooks[$e] += [{matcher:$m,hooks:[{type:"command",command:$c}]}]' <<<"$hooks")"
done
# preflight under SessionStart
hooks="$(jq '.hooks.SessionStart += [{hooks:[{type:"command",command:"\"${CLAUDE_PLUGIN_ROOT}/hooks/preflight.sh\""}]}]' <<<"$hooks")"
echo "$hooks" | jq . > "$HK/hooks.json"
echo "built $OUT (version $(cat VERSION))"
