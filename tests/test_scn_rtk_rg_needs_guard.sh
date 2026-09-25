#!/usr/bin/env bash
# `Bash(rtk rg:*)` is the one rtk allow rule that is not safe standalone.
#
# rtk-safe rewrites `rg …` -> `rtk rg …`, and the allowlist auto-approves that prefix so
# the highest-value rewrite doesn't add prompt friction. But ripgrep can be made to run an
# arbitrary binary (--pre, --hostname-bin, and RIPGREP_CONFIG_PATH pointing at a file of
# flags), and a prefix rule approves every suffix. command-guard blocks all three, and that
# block is the only reason the approval is safe.
#
# So the two must ship together. When command-guard is NOT selected, the installer keeps
# the rewrite (the token saving) but withholds just that one rule, so rg prompts instead
# of being silently auto-approved with no guard behind it.
#
# Invariants pinned:
#   (a) rtk-safe WITH command-guard  -> Bash(rtk rg:*) present,
#   (b) rtk-safe WITHOUT it          -> Bash(rtk rg:*) absent, other rtk approvals kept,
#   (c) either way the rtk-safe hook is registered (compression is never sacrificed).
#
# Fully sandboxed: fake $HOME, --no-auth-inherit; never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_rtk_rg_needs_guard:"

if ! command -v bun >/dev/null 2>&1; then
  pass "skipped (bun absent — rtk-safe/command-guard both need bun)"
  t_summary; exit 0
fi

# Only meaningful while the kit actually ships the rule.
if ! jq -e '[.permissions.allow[] | select(. == "Bash(rtk rg:*)")] | length > 0' \
      "$REPO_ROOT/config/rtk-allowlist.json" >/dev/null; then
  pass "kit does not ship Bash(rtk rg:*) — nothing to pair (skip)"
  t_summary; exit 0
fi

run_into() { # <sandbox> <addition ids>
  local sb="$1" ids="$2"
  touch "$sb/.bashrc"
  CT_ADDITIONS="$ids" SHELL=/bin/bash HOME="$sb" \
    bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$sb/log" 2>&1
}

# ── (a) WITH command-guard: the approval ships ───────────────────────────────
SB_WITH="$(sandbox)"
run_into "$SB_WITH" "secure-settings command-guard rtk-safe"
assert_eq "install with command-guard exits 0" "0" "$?"
S_WITH="$SB_WITH/.claude-aka/settings.json"
assert_ok "settings valid JSON (with guard)" jq -e . "$S_WITH"
assert_ok "Bash(rtk rg:*) present when command-guard is selected" jq -e \
  '(.permissions.allow // []) | index("Bash(rtk rg:*)") != null' "$S_WITH"

# ── (b) WITHOUT command-guard: that one rule is withheld ─────────────────────
SB_NO="$(sandbox)"
run_into "$SB_NO" "secure-settings rtk-safe"
assert_eq "install without command-guard exits 0" "0" "$?"
S_NO="$SB_NO/.claude-aka/settings.json"
assert_ok "settings valid JSON (no guard)" jq -e . "$S_NO"
assert_eq "Bash(rtk rg:*) withheld without command-guard" "null" \
  "$(jq '(.permissions.allow // []) | index("Bash(rtk rg:*)")' "$S_NO")"
# The withholding must be surgical — the exec-free approvals still ship.
assert_ok "Bash(rtk grep:*) still approved (grep has no exec primitive)" jq -e \
  '(.permissions.allow // []) | index("Bash(rtk grep:*)") != null' "$S_NO"
assert_ok "Bash(rtk read:*) still approved" jq -e \
  '(.permissions.allow // []) | index("Bash(rtk read:*)") != null' "$S_NO"
assert_ok "withholding is explained to the user" grep -q "rtk rg auto-approval withheld" "$SB_NO/log"

# ── (c) compression is never sacrificed: the hook registers either way ────────
for pair in "with:$S_WITH" "without:$S_NO"; do
  label="${pair%%:*}"; f="${pair#*:}"
  assert_eq "rtk-safe hook registered ($label command-guard)" "1" \
    "$(jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(test("rtk-safe\\.ts"))] | length' "$f")"
done

# ── (d) THE UPGRADE PATH: the approval must not outlive the guard ─────────────
# Filtering only the incoming payload was not enough. merge_settings UNIONS, command-guard
# contributes no permissions payload to prune, and the rule is current (not retired), so
# re-running with command-guard DESELECTED used to leave a live approval with no guard
# behind it. Reuse the profile from (a), which already holds the approval.
run_into "$SB_WITH" "secure-settings rtk-safe"
assert_eq "upgrade (deselecting command-guard) exits 0" "0" "$?"
assert_ok "settings valid JSON after deselect-upgrade" jq -e . "$S_WITH"
assert_eq "Bash(rtk rg:*) REMOVED when command-guard is deselected on upgrade" "null" \
  "$(jq '(.permissions.allow // []) | index("Bash(rtk rg:*)")' "$S_WITH")"
assert_eq "command-guard hook unregistered on deselect" "0" \
  "$(jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(test("command-guard"))] | length' "$S_WITH")"
# The removal is surgical and the compression survives.
assert_ok "Bash(rtk grep:*) survives the deselect-upgrade" jq -e \
  '(.permissions.allow // []) | index("Bash(rtk grep:*)") != null' "$S_WITH"
assert_eq "rtk-safe hook still registered after deselect-upgrade" "1" \
  "$(jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(test("rtk-safe\\.ts"))] | length' "$S_WITH")"
assert_ok "removal is explained to the user" \
  grep -q "Removed the existing 'Bash(rtk rg:\*)' approval" "$SB_WITH/log"

t_summary
