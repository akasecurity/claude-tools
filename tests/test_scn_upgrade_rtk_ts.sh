#!/usr/bin/env bash
# Upgrade migration: rtk-safe.sh → rtk-safe.ts (the in-kit .sh→.ts port). A profile that
# already has the managed-marked bash hook `rtk-safe.sh` registered is re-run with the
# CURRENT manifest (which ships rtk-safe.ts). This pins that the marker-based self-clean
# (install.sh 4d-pre2) migrates a renamed PreToolUse hook cleanly — the path the generic
# manifest/deselect pruners do NOT cover, since a `.sh` command is not full-command-equal
# to the new `.ts` command.
#
# Invariants pinned:
#   (a) the old rtk-safe.sh hook FILE is removed (no orphaned payload),
#   (b) the old rtk-safe.sh REGISTRATION is pruned (no stale/double registration),
#   (c) exactly one rtk-safe.ts registration exists, launched via bun (absolute path),
#   (d) an unrelated user-owned hook + its registration are left untouched.
#
# Fully sandboxed: fake $HOME, --no-auth-inherit; never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_rtk_ts:"

# rtk-safe.ts is a bun hook; the install gate aborts selection without bun. Skip cleanly
# on a bun-less leg (the missing-deps scenario covers the abort path explicitly).
if ! command -v bun >/dev/null 2>&1; then
  pass "skipped (bun absent — rtk-safe.ts upgrade path needs bun)"
  t_summary; exit 0
fi

SB="$(sandbox)"
RC="$SB/.bashrc"; touch "$RC"
PROFILE="$SB/.claude-aka"; mkdir -p "$PROFILE/hooks"

run() { CT_ADDITIONS="$1" SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# ── (0) seed a PRE-PORT profile: managed-marked rtk-safe.sh + its Bash registration,
#        plus an unrelated user-owned hook we expect to survive ───────────────────
printf '#!/bin/bash\n# aka-claude-tools:managed-hook — installer-owned.\nexit 0\n' > "$PROFILE/hooks/rtk-safe.sh"
chmod +x "$PROFILE/hooks/rtk-safe.sh"
printf '#!/bin/bash\n# my own thing\nexit 0\n' > "$PROFILE/hooks/my-own.sh"   # unmarked = user's
chmod +x "$PROFILE/hooks/my-own.sh"
cat > "$PROFILE/settings.json" <<JSON
{ "hooks": { "PreToolUse": [
  { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'$PROFILE'/hooks/rtk-safe.sh" } ] },
  { "matcher": "Bash", "hooks": [ { "type": "command", "command": "$PROFILE/hooks/my-own.sh" } ] }
] }, "permissions": { "allow": ["Bash(rtk find:*)", "Bash(rtk git branch:*)", "Bash(echo:*)"] } }
JSON

# ── (1) upgrade: re-run install with the current manifest, selecting rtk-safe ─────
run "secure-settings rtk-safe"; rc=$?
assert_eq "upgrade install exits 0" "0" "$rc"

# (a) old .sh file removed; (new) .ts placed
[ -e "$PROFILE/hooks/rtk-safe.sh" ] && fail "old rtk-safe.sh file removed" "still present" || pass "old rtk-safe.sh file removed"
assert_file "rtk-safe.ts placed" "$PROFILE/hooks/rtk-safe.ts"

S="$PROFILE/settings.json"
assert_ok "settings.json valid JSON after upgrade" jq -e . "$S"

# (b) old .sh registration pruned; (c) exactly one .ts reg, via bun
sh_regs="$(jq '[.hooks.PreToolUse[].hooks[].command | select(contains("rtk-safe.sh"))] | length' "$S")"
ts_regs="$(jq '[.hooks.PreToolUse[].hooks[].command | select(contains("rtk-safe.ts"))] | length' "$S")"
bun_ts="$(jq '[.hooks.PreToolUse[].hooks[].command | select(test("bun.*rtk-safe\\.ts"))] | length' "$S")"
assert_eq "no stale rtk-safe.sh registration" "0" "$sh_regs"
assert_eq "exactly one rtk-safe.ts registration" "1" "$ts_regs"
assert_eq "rtk-safe.ts registered via bun" "1" "$bun_ts"

# (d) unrelated user hook + registration untouched
assert_file "user hook my-own.sh kept" "$PROFILE/hooks/my-own.sh"
assert_lit  "user my-own.sh registration kept" "$PROFILE/hooks/my-own.sh" "$S"

assert_ok "upgrade retires broad find/branch approvals" jq -e \
  '.permissions.allow | index("Bash(rtk find:*)") == null and index("Bash(rtk git branch:*)") == null' "$S"
assert_ok "upgrade preserves user approval" jq -e \
  '.permissions.allow | index("Bash(echo:*)") != null' "$S"

t_summary
