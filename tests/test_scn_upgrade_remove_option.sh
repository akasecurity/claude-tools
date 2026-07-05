#!/usr/bin/env bash
# T18 — upgrade / remove-option: an existing install with additions selected, then
# re-run DESELECTING some. This is the "uninstall-by-deselect" half of the
# idempotent-both-ways promise, exercised across EVERY settings footprint a single
# addition can contribute and proven surgical (only the kit's own registrations go,
# the user's own perms/env/hooks stay):
#   • a HOOK addition       (leak-guard → .hooks.PreToolUse registration + file)
#   • a STATUSLINE addition (statusline → .statusLine + file)
#   • a PERM addition       (secure-settings → .permissions.deny, via settings.base.json)
#   • an ENV addition        (telemetry-off → .env, via settings.telemetry-off.json)
# while OTHER still-selected additions (wrap-up command, harness-pointer hook)
# stay fully intact, and a second identical re-deselect is a no-op (idempotent).
# Uses CT_ADDITIONS for a deterministic non-interactive selection, mirroring
# test_uninstall.sh's install convention exactly.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_upgrade_remove_option:"

SB="$(sandbox)"; touch "$SB/.bashrc"
PROFILE="$SB/.claude-aka"
S="$PROFILE/settings.json"
run() { CT_ADDITIONS="$1" SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# Pull the kit's actual shipped footprint from the manifest so the assertions track
# the payload rather than hardcoding rule strings: the perm (deny) from secure-settings,
# the env key from telemetry-off (which now owns the nonessential-traffic env block).
SETF="$(jq -r '.additions[] | select(.id=="secure-settings") | .settings // ""' "$ADDITIONS")"
ENVF="$(jq -r '.additions[] | select(.id=="telemetry-off") | .settings // ""' "$ADDITIONS")"
KIT_DENY="$(jq -r --arg f "$SETF" '.permissions.deny[0] // empty' "$REPO_ROOT/config/$SETF")"
KIT_ENV_KEY="$(jq -r --arg f "$ENVF" '.env | keys[0] // empty' "$REPO_ROOT/config/$ENVF")"

# ── 1. Install the full set: hook + statusLine + perm + env + two keepers ─────
run "secure-settings telemetry-off leak-guard statusline wrap-up harness-pointer"
assert_eq "install exits 0" "0" "$?"
assert_file "X(hook) leak-guard.ts deployed"          "$PROFILE/hooks/leak-guard.ts"
assert_file "X(statusLine) statusline.ts deployed"   "$PROFILE/hooks/statusline.ts"
assert_file "keeper harness-pointer.sh deployed" "$PROFILE/hooks/harness-pointer.sh"
assert_file "keeper wrap-up.md deployed"             "$PROFILE/commands/wrap-up.md"
assert_ok "leak-guard hook registered" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.ts\"))' '$S' >/dev/null"
assert_ok "statusLine registered (points at statusline.ts)" \
  bash -c "jq -e '(.statusLine.command // \"\") | endswith(\"/statusline.ts\")' '$S' >/dev/null"
assert_lit "secure-settings deny rule present"  "$KIT_DENY" "$S"
assert_ok "secure-settings env key present" \
  bash -c "jq -e --arg k '$KIT_ENV_KEY' '.env | has(\$k)' '$S' >/dev/null"

# ── 2. Plant USER-OWN registrations the kit never shipped — pruning must NOT
#       touch these (surgical removal, not blanket reset). ──────────────────────
USER_DENY='Read(//Users/me/secret/**)'
USER_HOOK='/Users/me/my-own-hook.sh'
jq --arg ud "$USER_DENY" --arg uh "$USER_HOOK" \
  '.permissions.deny += [$ud]
   | .env.MY_OWN_VAR = "keepme"
   | .hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":$uh}]}]' \
  "$S" > "$S.tmp" && mv "$S.tmp" "$S"

# ── 3. Re-run DESELECTING the three; keep wrap-up + harness-pointer ────────
run "wrap-up harness-pointer"
assert_eq "deselect re-run exits 0" "0" "$?"
assert_ok "settings.json still valid JSON after deselect" jq -e . "$S"

# X's FILES removed.
[ -e "$PROFILE/hooks/leak-guard.ts" ] && fail "leak-guard hook file removed on deselect" "still present" \
                                     || pass "leak-guard hook file removed on deselect"
[ -e "$PROFILE/hooks/statusline.ts" ] && fail "statusline file removed on deselect" "still present" \
                                      || pass "statusline file removed on deselect"

# X's hook registration pruned.
assert_ok "leak-guard registration pruned from .hooks" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.ts\")) | not' '$S' >/dev/null"
# X's statusLine pruned.
assert_ok "statusLine pruned from settings" \
  bash -c "jq -e '((.statusLine.command // \"\") | endswith(\"/statusline.ts\")) | not' '$S' >/dev/null"
# X's perm rule pruned (kit's deny gone).
assert_nlit "secure-settings kit deny rule pruned" "$KIT_DENY" "$S"
# X's env key pruned.
assert_ok "secure-settings kit env key pruned" \
  bash -c "jq -e --arg k '$KIT_ENV_KEY' '(.env // {}) | has(\$k) | not' '$S' >/dev/null"

# OTHER (still-selected) additions fully intact — file AND registration.
assert_file "keeper harness-pointer.sh retained" "$PROFILE/hooks/harness-pointer.sh"
assert_ok "keeper harness-pointer hook still registered" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/harness-pointer.sh\"))' '$S' >/dev/null"
assert_file "keeper wrap-up.md retained" "$PROFILE/commands/wrap-up.md"

# USER-OWN registrations untouched — deselect prunes only what the KIT shipped.
assert_lit "user-own deny rule preserved"  "$USER_DENY" "$S"
assert_ok "user-own env var preserved (env key NOT blanket-deleted)" \
  bash -c "jq -e '.env.MY_OWN_VAR == \"keepme\"' '$S' >/dev/null"
assert_ok "user-own hook registration preserved" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; . == \"$USER_HOOK\")' '$S' >/dev/null"

# ── 4. Idempotent on re-deselect — a second identical run changes nothing ──────
cp "$S" "$SB/after1.json"
run "wrap-up harness-pointer"
assert_eq "second identical deselect exits 0" "0" "$?"
if diff <(jq -S . "$SB/after1.json") <(jq -S . "$S") >/dev/null 2>&1; then
  pass "re-deselect is idempotent (settings.json unchanged)"
else
  fail "re-deselect is idempotent (settings.json unchanged)" "settings differ on second deselect"
fi
[ -e "$PROFILE/hooks/leak-guard.ts" ] && fail "leak-guard stays removed on re-deselect" "reappeared" \
                                     || pass "leak-guard stays removed on re-deselect"

t_summary
