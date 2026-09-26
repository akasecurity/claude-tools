#!/usr/bin/env bash
# Assemble plugins/claude-tools/ from config/ (single source of truth). Regenerate + commit after
# any config change; CI drift-checks. Ships ONLY the guard hooks (see plan Global Constraints).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="plugins/claude-tools"; HK="$OUT/hooks"
BUNDLED="command-guard leak-guard mcp-guard"   # guard hooks the plugin ships (recommended, runtime=bun)
rm -rf "$OUT"; mkdir -p "$OUT/.claude-plugin" "$HK"

# manifest
jq -n --arg v "$(cat VERSION)" '{
  name:"claude-tools", version:$v, author:{name:"AKA Security"},
  homepage:"https://akasecurity.io", repository:"https://github.com/akasecurity/claude-tools",
  description:"AKA Claude Tools guard hooks (command-guard, leak-guard, mcp-guard) for your active profile. Requires bun. If bun is missing, the guards fail OPEN (the tool call proceeds) and announce themselves inactive at session start; with bun present, mcp-guard blocks on its own errors. For the full hardened ISOLATED profile (credential-read denies, rtk-safe permission allowlist, status line, alias), install the full kit — see the project README for npm, Homebrew, and installer options."
}' > "$OUT/.claude-plugin/plugin.json"

# copy launcher + preflight + shared lib (secret-patterns.json for defense-in-depth,
# the vendored guard-core every bundled guard hook runs on, and audit.ts — the local
# security-event audit log the guard hooks call; in the plugin, profile-root
# resolution never finds a .aka-claude-tools-meta file, so it writes nothing here)
install -m 0755 config/hooks/bun-hook-launch.sh config/hooks/preflight.sh "$HK"/
mkdir -p "$HK/lib" && cp config/hooks/lib/secret-patterns.json config/hooks/lib/guard-core.js \
  config/hooks/lib/audit.ts "$HK/lib/"

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
