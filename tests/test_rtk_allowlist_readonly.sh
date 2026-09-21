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
  'Bash(rtk diff:*)' 'Bash(rtk git diff:*)' 'Bash(rtk grep:*)' \
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

# (3) no rtk form whose UNDERLYING tool has an exec primitive. These are prefix rules, so
# approving the verb approves every suffix: `rtk rg --pre <cmd>` and `rtk find -exec` both
# run an arbitrary binary. `rtk grep` is exempt on purpose — it dispatches to the system
# grep, which has no exec/write primitive (see the rtk-allowlist.json $comment).
assert_eq "no exec-capable rtk verb auto-approved (rg/find/xargs)" "0" \
  "$(jq '[.permissions.allow[] | select(test("^Bash\\(rtk (rg|find|xargs)[: ]"))] | length' "$AL")"

t_summary
