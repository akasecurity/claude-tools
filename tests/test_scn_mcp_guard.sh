#!/usr/bin/env bash
# mcp-guard: the PreToolUse guard on MCP tool calls (mcp__.*). Runs a sandbox copy of
# config/hooks and checks the server allow/deny policy (from hooks/lib/mcp-policy.json),
# the secret scan over nested MCP input, the ai-tc deferral (scan skipped, policy kept),
# the fail-closed paths (core missing or incompatible, unexpected error) and the plugin
# copy, which ships without a policy sidecar and so runs the scan alone.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v bun >/dev/null 2>&1 || { echo "SKIP: bun not installed"; exit 0; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Profiles: bare (no ai-tc) and ai-tc stubbed in (registry + enabled + cache dir).
bare="$tmp/bare"; mkdir -p "$bare"
prof="$tmp/aitc"; mkdir -p "$prof/plugins/cache/akasecurity/ai-tc/1"
printf '%s' '{"plugins":{"ai-tc@akasecurity":[{}]}}' > "$prof/plugins/installed_plugins.json"
printf '%s' '{"enabledPlugins":{"ai-tc@akasecurity":true}}' > "$prof/settings.json"

# fresh_hooks <name> — a sandbox copy of config/hooks at $tmp/<name>/hooks; echoes its path.
fresh_hooks() { mkdir -p "$tmp/$1"; cp -R config/hooks "$tmp/$1/hooks"; printf '%s' "$tmp/$1/hooks"; }
policy() { # <hooks-dir> <policy-json>
  printf '%s' "$2" > "$1/lib/mcp-policy.json"
}

fails=0
# run <hooks-dir> <config-dir> <input-json> → sets GOT (exit) and $tmp/err (stderr)
run() {
  set +e
  printf '%s' "$3" | CLAUDE_CONFIG_DIR="$2" bun "$1/mcp-guard.ts" >"$tmp/out" 2>"$tmp/err"
  GOT=$?
  set -e
}
expect() { # <label> <want-exit> <hooks-dir> <config-dir> <input-json>
  run "$3" "$4" "$5"
  if [ "$GOT" = "$2" ]; then echo "  ok   $1 (exit $GOT)"
  else echo "  FAIL $1: want exit $2, got $GOT"; sed 's/^/       /' "$tmp/err"; fails=$((fails+1)); fi
}
expect_err() { # <label> <fixed-string> — checks the stderr of the last run
  if grep -qF -- "$2" "$tmp/err"; then echo "  ok   $1"
  else echo "  FAIL $1: stderr lacks: $2"; sed 's/^/       /' "$tmp/err"; fails=$((fails+1)); fi
}
expect_no_err() { # <label> <fixed-string>
  if grep -qF -- "$2" "$tmp/err"; then echo "  FAIL $1: stderr has: $2"; fails=$((fails+1))
  else echo "  ok   $1"; fi
}

GHP='ghp_0123456789abcdefghij0123456789ABCD'
cred_in="$(jq -cn --arg s "$GHP" '{tool_name:"mcp__github__create_issue",tool_input:{title:"t",fields:{nested:[{body:("token " + $s)}]}}}')"
benign_in='{"tool_name":"mcp__github__create_issue","tool_input":{"title":"fix typo","labels":["docs"]}}'
bad_in='{"tool_name":"mcp__bad__t","tool_input":{}}'
BAD_DENIED='mcp-guard: blocked — MCP server "bad" is denied by policy (CT_MCP_DENY).'
GH_NOT_ALLOWED='mcp-guard: blocked — MCP server "github" is not on the allow list (CT_MCP_ALLOW).'
CRED_MSG='mcp-guard: blocked — MCP tool input contains a token or key value.'
CORE_MSG='mcp-guard: blocked — the guard-core library is missing, unreadable or incompatible; blocking as a precaution. Reinstall to restore it.'
POLICY_WARN='mcp-guard: warn — mcp-policy.json is unreadable; MCP allow/deny policy inactive.'
STALE_WARN='mcp-guard: warn — aka-claude-tools.config changed since install; re-run the installer to recompile the MCP policy.'

echo "scan (no policy sidecar):"
h="$(fresh_hooks plain)"
expect "credential nested in MCP input" 2 "$h" "$bare" "$cred_in"
expect_err "credential message" "$CRED_MSG"
expect "benign MCP input" 0 "$h" "$bare" "$benign_in"
expect_no_err "missing mcp-policy.json: no policy warning" "mcp-policy.json"
expect "non-MCP tool passes through" 0 "$h" "$bare" '{"tool_name":"Bash","tool_input":{"command":"echo ghp_0123456789abcdefghij0123456789ABCD"}}'
expect_err "non-MCP tool: matcher warning" 'mcp-guard: warn — invoked for non-MCP tool "Bash"; not scanned (check the hook matcher).'
key_in="$(jq -cn --arg s "$GHP" '{tool_name:"mcp__github__x",tool_input:{($s):"v"}}')"
expect "credential in an object key" 2 "$h" "$bare" "$key_in"

echo "policy:"
h="$(fresh_hooks deny)"; policy "$h" '{"allow":[],"deny":["bad"],"sourceHash":""}'
expect "denied server" 2 "$h" "$bare" "$bad_in"
expect_err "denied message" "$BAD_DENIED"
expect "denied server, ai-tc present (policy still applies)" 2 "$h" "$prof" "$bad_in"
expect_err "denied message with ai-tc" "$BAD_DENIED"
expect "denied match is case-insensitive" 2 "$h" "$bare" '{"tool_name":"mcp__BAD__t","tool_input":{}}'
expect "other server, benign" 0 "$h" "$bare" "$benign_in"
h="$(fresh_hooks allow)"; policy "$h" '{"allow":["linear"],"deny":[],"sourceHash":""}'
expect "server not on the allow list" 2 "$h" "$bare" "$benign_in"
expect_err "not-allowed message" "$GH_NOT_ALLOWED"
expect "serverless tool name under an allow list" 2 "$h" "$bare" '{"tool_name":"mcp__x","tool_input":{}}'
expect_err "serverless message" "mcp-guard: blocked — MCP tool name has no server segment; blocked by the allow list (CT_MCP_ALLOW)."
expect "server on the allow list" 0 "$h" "$bare" '{"tool_name":"mcp__linear__list","tool_input":{"q":"x"}}'

echo "regex tiers only (trufflehog never consulted):"
stub="$tmp/stub"; mkdir -p "$stub"
printf '#!/bin/sh\ncat >/dev/null\necho "{\\"DetectorName\\":\\"X\\"}"\n' > "$stub/trufflehog"; chmod +x "$stub/trufflehog"
h="$(fresh_hooks regex)"
set +e; printf '%s' "$benign_in" | PATH="$stub:$PATH" CLAUDE_CONFIG_DIR="$bare" bun "$h/mcp-guard.ts" >/dev/null 2>"$tmp/err"; GOT=$?; set -e
[ "$GOT" = 0 ] && echo "  ok   benign allowed with an always-detecting trufflehog on PATH" \
  || { echo "  FAIL benign blocked by trufflehog stub (exit $GOT)"; sed 's/^/       /' "$tmp/err"; fails=$((fails+1)); }
expect_no_err "no trufflehog notice" "trufflehog"
expect "credential still blocked by key shape" 2 "$h" "$bare" "$cred_in"
expect_no_err "credential: no trufflehog notice" "trufflehog"

echo "ai-tc present:"
h="$(fresh_hooks aitc)"
expect "credential deferred to ai-tc" 0 "$h" "$prof" "$cred_in"

echo "corrupt or stale policy sidecar:"
h="$(fresh_hooks corrupt)"; policy "$h" '{"allow":'
expect "corrupt policy: credential still scanned" 2 "$h" "$bare" "$cred_in"
expect_err "corrupt policy warning" "$POLICY_WARN"
expect "corrupt policy: benign allowed (no policy)" 0 "$h" "$bare" "$benign_in"
expect_err "corrupt policy warning (benign)" "$POLICY_WARN"
h="$(fresh_hooks shape)"; policy "$h" '{"allow":"github","deny":[]}'
expect "malformed policy shape: no policy" 0 "$h" "$bare" '{"tool_name":"mcp__linear__x","tool_input":{}}'
expect_err "malformed policy warning" "$POLICY_WARN"
h="$(fresh_hooks stale)"; policy "$h" '{"allow":[],"deny":["bad"],"sourceHash":"0"}'
printf 'CT_MCP_DENY="bad"\n' > "$tmp/stale/aka-claude-tools.config"
expect "stale policy still applied" 2 "$h" "$bare" "$bad_in"
expect_err "stale warning" "$STALE_WARN"
cfg_hash="$(shasum -a 256 "$tmp/stale/aka-claude-tools.config" | cut -d' ' -f1)"
policy "$h" "{\"allow\":[],\"deny\":[\"bad\"],\"sourceHash\":\"$cfg_hash\"}"
expect "matching sourceHash" 2 "$h" "$bare" "$bad_in"
expect_no_err "matching sourceHash: no stale warning" "changed since install"

echo "fail closed:"
h="$(fresh_hooks nocore)"; rm -f "$h/lib/guard-core.js"
expect "core missing" 2 "$h" "$bare" "$benign_in"
expect_err "core-missing message" "$CORE_MSG"
h="$(fresh_hooks badcore)"; printf 'export const VERSION="0";\n' > "$h/lib/guard-core.js"
expect "core incompatible" 2 "$h" "$bare" "$benign_in"
expect_err "core-incompatible message" "$CORE_MSG"
h="$(fresh_hooks toplevel)"
expect "stdin null" 2 "$h" "$bare" 'null'
expect_err "top-level catch message" "mcp-guard: blocked — unexpected error while checking this MCP tool call; blocking as a precaution."
expect "unparseable stdin" 2 "$h" "$bare" '{not json'
deep="$(jq -cn 'reduce range(0;80) as $i ("x"; {a:.}) | {tool_name:"mcp__github__x",tool_input:.}')"
expect "too deeply nested input" 2 "$h" "$bare" "$deep"
expect_err "unscannable message" "mcp-guard: blocked — MCP tool input has too many fields, is too large, or is too deeply nested to scan."
TOPLEVEL='mcp-guard: blocked — unexpected error while checking this MCP tool call; blocking as a precaution.'
expect "missing tool_name, credential in input" 2 "$h" "$bare" "$(jq -cn --arg s "$GHP" '{tool_input:{body:$s}}')"
expect_err "missing tool_name: top-level catch" "$TOPLEVEL"
expect "non-string tool_name, credential in input" 2 "$h" "$bare" "$(jq -cn --arg s "$GHP" '{tool_name:7,tool_input:{body:$s}}')"
expect_err "non-string tool_name: top-level catch" "$TOPLEVEL"
for body in '[]' '"x"' '5'; do
  expect "stdin $body (not an object)" 2 "$h" "$bare" "$body"
  expect_err "stdin $body: top-level catch" "$TOPLEVEL"
done
rows="$(jq -cn '{tool_name:"mcp__db__insert",tool_input:{table:"t",rows:[range(0;3000) | {id:., name:("row-\(.)"), note:"ok"}]}}')"
expect "3,000-row insert allows" 0 "$h" "$bare" "$rows"
h="$(fresh_hooks nopat)"; rm -f "$h/lib/secret-patterns.json"
expect "secret patterns missing" 2 "$h" "$bare" "$benign_in"
expect_err "patterns-missing message" "mcp-guard: blocked — the secret patterns are missing or corrupt; blocking as a precaution. Reinstall to restore them."

echo "plugin copy (no policy sidecar shipped; scan only):"
ph="plugins/claude-tools/hooks"
if [ -f "$ph/mcp-guard.ts" ]; then
  [ ! -e "$ph/lib/mcp-policy.json" ] && echo "  ok   plugin ships no mcp-policy.json" \
    || { echo "  FAIL plugin ships mcp-policy.json"; fails=$((fails+1)); }
  expect "plugin: credential" 2 "$ph" "$bare" "$cred_in"
  expect_err "plugin: credential message" "$CRED_MSG"
  expect "plugin: benign" 0 "$ph" "$bare" "$benign_in"
  expect_no_err "plugin: no policy warning" "mcp-policy.json"
  expect "plugin: any server allowed (no policy)" 0 "$ph" "$bare" "$bad_in"
else
  echo "  FAIL plugin copy missing: $ph/mcp-guard.ts (run tools/build-plugin.sh)"; fails=$((fails+1))
fi

[ "$fails" = 0 ] && echo PASS || { echo "FAIL: $fails check(s)"; exit 1; }
