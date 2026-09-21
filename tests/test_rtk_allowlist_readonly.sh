#!/usr/bin/env bash
# The rtk-safe rewrite changes the command string, so a rewritten command is re-evaluated
# against rtk-allowlist.json. The security contract: ONLY strictly read-only rtk forms are
# auto-approved; every mutating/egress rewrite (rtk git push, rtk docker run, rtk pip
# install, rtk curl, …) must still prompt. This pins that contract so a future allowlist
# edit can't silently broaden it — the anti-criterion made executable (don't eyeball it).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_rtk_allowlist_readonly:"

AL="$REPO_ROOT/config/rtk-allowlist.json"
assert_ok "rtk-allowlist.json valid JSON" jq -e . "$AL"

# (1) the allow set is EXACTLY the strictly read-only rtk forms — any addition fails here.
EXPECTED="$(printf '%s\n' \
  'Bash(rtk diff:*)' 'Bash(rtk git diff:*)' 'Bash(rtk grep:*)' 'Bash(rtk rg:*)' \
  'Bash(rtk git log:*)' 'Bash(rtk git show:*)' 'Bash(rtk git stash list:*)' \
  'Bash(rtk git stash show:*)' 'Bash(rtk git status:*)' 'Bash(rtk ls:*)' \
  'Bash(rtk read:*)' 'Bash(rtk wc:*)' | sort)"
GOT="$(jq -r '.permissions.allow[]' "$AL" | sort)"
if [ "$EXPECTED" = "$GOT" ]; then
  pass "allow set is exactly the read-only rtk forms"
else
  fail "allow set is exactly the read-only rtk forms" "drift:
$(diff <(echo "$EXPECTED") <(echo "$GOT"))"
fi

# (2) defense-in-depth: no blanket wildcard, and no mutating/egress verb is auto-approved.
assert_eq "no blanket Bash(rtk:*) / Bash(rtk git:*)" "0" \
  "$(jq '[.permissions.allow[] | select(test("rtk(:\\*\\)|\\s+git:\\*\\))$"))] | length' "$AL")"
assert_eq "no mutating/egress rtk form auto-approved" "0" \
  "$(jq '[.permissions.allow[] | select(test("rtk (git (push|pull|fetch|add|commit)|docker|kubectl|cargo|pip|curl|wget|aws|psql|npm|pnpm|go )"))] | length' "$AL")"

# (3) no rtk form whose underlying tool can exec, UNLESS command-guard blocks that tool's
# exec flags. These are prefix rules, so approving the verb approves every suffix.
#   - rtk find  -> find -exec/-delete, nothing blocks it  => must NOT be approved
#   - rtk rg    -> ripgrep --pre/--hostname-bin/RIPGREP_CONFIG_PATH, command-guard blocks
#                  all three => approved, but ONLY while that block exists
#   - rtk grep  -> system grep, no exec primitive         => approved unconditionally
assert_eq "no unbacked exec-capable rtk verb auto-approved (find/xargs)" "0" \
  "$(jq '[.permissions.allow[] | select(test("^Bash\\(rtk (find|xargs)[: ]"))] | length' "$AL")"

# The pairing invariant: `Bash(rtk rg:*)` and the command-guard block ship together, or
# not at all. Approving rg without the block is silent arbitrary code execution.
#
# This is asserted BEHAVIOURALLY — by running the guard — not by grepping command-guard.ts
# for marker strings. A textual check is tautological: gutting detectSearchExec to
# `return false` while leaving its comment block intact passed every assertion, so the one
# invariant the whole approval rests on was pinned by nothing. Each vector below must make
# the real guard exit 2, and ordinary searches must still pass.
CG="$REPO_ROOT/config/hooks/command-guard.ts"
if ! jq -e '[.permissions.allow[] | select(test("^Bash\\(rtk rg[: ]"))] | length > 0' "$AL" >/dev/null; then
  pass "rtk rg not approved — no command-guard pairing required"
elif ! command -v bun >/dev/null 2>&1; then
  pass "skipped behavioural pairing check (bun absent — command-guard cannot run)"
else
  guard_rc() { # <command> -> exit code of command-guard on it
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(jq -Rn --arg v "$1" '$v')" | bun "$CG" >/dev/null 2>&1; echo $?
  }
  # Every shape that reaches ripgrep's exec surface while matching the Bash(rtk rg:*)
  # prefix rule, plus the wrapper/export forms that reach it without the prefix.
  while IFS= read -r vec; do
    [ -z "$vec" ] && continue
    assert_eq "rtk rg approved => guard blocks: $vec" "2" "$(guard_rc "$vec")"
  done <<'VECTORS'
rtk rg --pre /tmp/payload.sh needle .
rtk rg --pre=/tmp/payload.sh needle .
rtk rg --hostname-bin /tmp/payload.sh needle .
RIPGREP_CONFIG_PATH=/tmp/evil.rc rtk rg needle .
export RIPGREP_CONFIG_PATH=/tmp/evil.rc; rtk rg needle .
declare -x RIPGREP_CONFIG_PATH=/tmp/evil.rc
env RIPGREP_CONFIG_PATH=/tmp/evil.rc rtk rg needle .
env rg --pre /tmp/payload.sh needle .
command rg --pre /tmp/payload.sh needle .
rtk -v rg --pre /tmp/payload.sh needle .
rtk --ultra-compact rg --pre /tmp/payload.sh needle .
{ rtk rg --pre /tmp/payload.sh needle .; }
VECTORS
  # …and the approval must not come at the cost of blocking ordinary searches.
  while IFS= read -r ok_cmd; do
    [ -z "$ok_cmd" ] && continue
    assert_eq "guard allows ordinary search: $ok_cmd" "0" "$(guard_rc "$ok_cmd")"
  done <<'BENIGN'
rtk rg -n needle src
rtk rg -n -- --pre src
rtk rg --preview needle src
rtk git log --pretty=oneline
env FOO=bar rg -n needle src
export FOO=bar; rtk rg needle .
BENIGN
fi

t_summary
