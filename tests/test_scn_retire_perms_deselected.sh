#!/usr/bin/env bash
# Permission retirement must not depend on which addition the engineer selects.
#
# permissions.allow is contributed by exactly ONE addition (rtk-safe, via
# rtk-allowlist.json). reconcile_managed_perms used to skip any array the current run
# ships nothing into, so a user who upgraded while DESELECTING rtk-safe kept every
# retired allow rule forever — and the deselect pruner doesn't catch them either, since
# it subtracts only the CURRENT allowlist payload, which no longer contains them.
#
# That left `Bash(rtk find:*)` (a prefix rule, so it approves `rtk find . -exec …` and
# `rtk find . -delete`) live in precisely the profiles that turned the addition off.
#
# Invariants pinned:
#   (a) retired allow rules are dropped even when NO selected addition ships allow rules,
#   (b) rules the kit never shipped (the user's own) survive untouched,
#   (c) the retired-deny path still works in the same run (no regression from (a)).
#
# Fully sandboxed: fake $HOME, --no-auth-inherit; never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_retire_perms_deselected:"

MP="$REPO_ROOT/config/managed-permissions.json"
RET_ALLOW="$(jq -r '.retired.allow[0] // empty' "$MP")"
RET_DENY="$(jq -r '.retired.deny[0] // empty' "$MP")"
if [ -z "$RET_ALLOW" ]; then
  pass "no retired allow rules to exercise (skip)"
  t_summary; exit 0
fi

SB="$(sandbox)"
RC="$SB/.bashrc"; touch "$RC"
PROFILE="$SB/.claude-aka"; mkdir -p "$PROFILE"

# Seed a profile that looks like a previous install WITH rtk-safe: it holds the retired
# allow rules, a retired deny, and two rules of the user's own the kit has never shipped.
jq -n --arg ra "$RET_ALLOW" --arg rd "$RET_DENY" '{
  permissions: {
    allow: [$ra, "Bash(echo:*)", "Bash(my-own-tool:*)"],
    deny: (if $rd == "" then ["Read(~/.my-secrets/**)"] else [$rd, "Read(~/.my-secrets/**)"] end)
  }
}' > "$PROFILE/settings.json"

# Upgrade selecting ONLY secure-settings — rtk-safe (the sole source of permissions.allow)
# is deselected, which is the exact condition that used to skip allow reconciliation.
CT_ADDITIONS="secure-settings" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
assert_eq "upgrade install exits 0" "0" "$?"

S="$PROFILE/settings.json"
assert_ok "settings.json valid JSON after upgrade" jq -e . "$S"

# (a) retired allow rules dropped even though this run shipped no allow rules at all
assert_eq "retired allow rule dropped with rtk-safe deselected" "null" \
  "$(jq --arg r "$RET_ALLOW" '(.permissions.allow // []) | index($r)' "$S")"
assert_eq "this run shipped no allow rules of its own" "0" \
  "$(jq '[(.permissions.allow // [])[] | select(startswith("Bash(rtk "))] | length' "$S")"

# (b) the user's own rules are never touched — the whole point of the retired[] gate
assert_ok "user allow rule Bash(echo:*) kept" jq -e \
  '(.permissions.allow // []) | index("Bash(echo:*)") != null' "$S"
assert_ok "user allow rule Bash(my-own-tool:*) kept" jq -e \
  '(.permissions.allow // []) | index("Bash(my-own-tool:*)") != null' "$S"
assert_ok "user deny rule kept" jq -e \
  '(.permissions.deny // []) | index("Read(~/.my-secrets/**)") != null' "$S"

# (c) the deny path this change routes around still retires in the same run
if [ -n "$RET_DENY" ]; then
  assert_eq "retired deny rule still dropped" "null" \
    "$(jq --arg r "$RET_DENY" '(.permissions.deny // []) | index($r)' "$S")"
else
  pass "no retired deny rules to exercise (skip)"
fi

t_summary
