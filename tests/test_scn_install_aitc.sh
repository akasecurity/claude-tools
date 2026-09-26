#!/usr/bin/env bash
# Scenario — install-time ai-tc detection.
#
# The installer's statusline build step and offer_aitc must agree with the hooks
# (command-guard, leak-guard, rtk-safe) on ONE detection rule: guard-core's detectAitc, via the
# shared/lib/aitc-status.ts wrapper. When ai-tc is registered + enabled + cached
# for the target profile, the kit skips installing its OWN statusline (ai-tc
# provides one) and the ai-tc offer stays silent (nothing to offer).
#
# Invariants asserted:
#   A. Profile with NO ai-tc: --defaults installs the kit statusLine and still
#      prints the "Security depth." ai-tc offer.
#   B. Profile WITH ai-tc stubbed (registry + enabledPlugins + cache dir, same
#      shape as test_scn_aitc_deferral_scope.sh): --defaults does NOT write a
#      statusLine, prints the "ai-tc detected; skipping..." notice, does NOT
#      print "Security depth.", and the ai-tc plugin's own enabledPlugins entry
#      survives untouched. A pre-existing, non-kit .statusLine in this profile
#      is left byte-identical — neither stashed into _aka_prior_statusLine nor
#      pruned — because the kit never claims the slot in the first place.
#
# The UPGRADE path (ai-tc shows up AFTER the kit already installed its own
# statusLine, then the installer is re-run with the same selection) is a
# DIFFERENT case from B: the on-disk .statusLine is the kit's own, not the
# user's, so it must be actively relinquished — restoring a real stash, or just
# removed — not silently left in place pointing at hooks/statusline.ts.
#   C. Fresh kit install (no ai-tc, no prior statusLine) → add ai-tc → re-run.
#      .statusLine ends up absent, hooks/statusline.ts is gone, no stash key.
#   D. User has a prior .statusLine X → install the kit (X gets stashed) → add
#      ai-tc → re-run. .statusLine == X again, no stash key (consumed by the
#      restore), hooks/statusline.ts gone.
#   E. From D's end state, remove ai-tc → re-run. The kit statusline is
#      installed again and X is stashed again (not lost).
#
# Needs bun (aitc-status.ts's runtime); the suite already hard-requires it.
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit, never touches a
# real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_aitc:"

INSTALL="$REPO_ROOT/install.sh"
# Deterministic recommended subset that needs no OTHER optional runtime (rtk,
# trufflehog) so the scenario stays stable in CI — statusline is the addition
# under test.
SEL="secure-settings leak-guard statusline"

stub_aitc() { # <profile-dir> — registry + enabled + cache dir, the shape the hook tests use.
              # OVERWRITES settings.json — only safe to call before the profile has one.
  mkdir -p "$1/plugins/cache/akasecurity/ai-tc/1"
  printf '%s' '{"plugins":{"ai-tc@akasecurity":[{}]}}' > "$1/plugins/installed_plugins.json"
  printf '%s' '{"enabledPlugins":{"ai-tc@akasecurity":true}}' > "$1/settings.json"
}

stub_aitc_onto_existing() { # <profile-dir> — same registry + cache dir, but MERGES
  # enabledPlugins into an already-installed settings.json instead of clobbering it —
  # for the upgrade scenarios (C/D/E), where the kit ran first and ai-tc shows up after.
  mkdir -p "$1/plugins/cache/akasecurity/ai-tc/1"
  printf '%s' '{"plugins":{"ai-tc@akasecurity":[{}]}}' > "$1/plugins/installed_plugins.json"
  jq '.enabledPlugins["ai-tc@akasecurity"] = true' "$1/settings.json" > "$1/settings.json.tmp"
  mv "$1/settings.json.tmp" "$1/settings.json"
}

remove_aitc() { # <profile-dir> — undo either stub above: delete the registry + cache,
  # so detectAitc finds no markers regardless of any leftover enabledPlugins entry.
  rm -rf "$1/plugins"
}

# ── A. no ai-tc ───────────────────────────────────────────────────────────────
SB_A="$(sandbox)"; RC_A="$SB_A/.bashrc"; touch "$RC_A"
PROFILE_A="$SB_A/.claude-aka"

CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_A" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SB_A/log" 2>&1
assert_eq   "A: install exits 0 (no ai-tc)" "0" "$?"

SA="$PROFILE_A/settings.json"
assert_ok   "A: settings.json is valid JSON" jq -e . "$SA"
assert_ok   "A: statusLine wired in settings" \
  bash -c "jq -e '(.statusLine.command // \"\")|endswith(\"/statusline.ts\")' '$SA' >/dev/null"
assert_file "A: statusline.ts placed" "$PROFILE_A/hooks/statusline.ts"
assert_grep "A: ai-tc offer shown"     'Security depth\.' "$SB_A/log"
assert_ngrep "A: no 'skip the kit status line' notice" 'skipping the kit status line' "$SB_A/log"

# ── B. ai-tc present and enabled ─────────────────────────────────────────────
SB_B="$(sandbox)"; RC_B="$SB_B/.bashrc"; touch "$RC_B"
PROFILE_B="$SB_B/.claude-aka"
mkdir -p "$PROFILE_B"
stub_aitc "$PROFILE_B"
# A pre-existing, non-kit statusLine — must survive untouched (neither stashed
# nor pruned) since the kit never claims the slot when ai-tc is present.
PRIOR_SL='{"type":"command","command":"echo aitc"}'
jq --argjson sl "$PRIOR_SL" '.statusLine = $sl' "$PROFILE_B/settings.json" > "$PROFILE_B/settings.json.tmp"
mv "$PROFILE_B/settings.json.tmp" "$PROFILE_B/settings.json"

CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_B" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SB_B/log" 2>&1
assert_eq   "B: install exits 0 (ai-tc present)" "0" "$?"

SB_S="$PROFILE_B/settings.json"
assert_ok   "B: settings.json is valid JSON" jq -e . "$SB_S"
assert_ok   "B: .statusLine is the untouched prior value" \
  bash -c "jq -e --argjson want '$PRIOR_SL' '.statusLine == \$want' '$SB_S' >/dev/null"
assert_ok   "B: no _aka_prior_statusLine stash was created" \
  bash -c "jq -e '(has(\"_aka_prior_statusLine\"))|not' '$SB_S' >/dev/null"
assert_grep "B: 'ai-tc detected; skipping' notice shown" 'ai-tc detected; skipping the kit status line' "$SB_B/log"
assert_ngrep "B: 'Security depth.' offer NOT shown"      'Security depth\.' "$SB_B/log"
assert_ok   "B: ai-tc's own enabledPlugins entry survives" \
  bash -c "jq -e '.enabledPlugins[\"ai-tc@akasecurity\"] == true' '$SB_S' >/dev/null"
# The kit's own statusline hook file must not even be placed, since it never claims
# the slot — confirms this is a real skip, not just a settings-merge accident.
assert_ok   "B: kit statusline.ts NOT placed" \
  bash -c "[ ! -e '$PROFILE_B/hooks/statusline.ts' ]"

# ── C. fresh kit install (no ai-tc, no prior statusLine) → add ai-tc → re-run ──
SB_C="$(sandbox)"; RC_C="$SB_C/.bashrc"; touch "$RC_C"
PROFILE_C="$SB_C/.claude-aka"

CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_C" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SB_C/log1" 2>&1
assert_eq   "C: first (pre-ai-tc) install exits 0" "0" "$?"
SC="$PROFILE_C/settings.json"
assert_ok   "C: precondition — kit statusLine installed" \
  bash -c "jq -e '(.statusLine.command // \"\")|endswith(\"/statusline.ts\")' '$SC' >/dev/null"
assert_file "C: precondition — statusline.ts placed" "$PROFILE_C/hooks/statusline.ts"

stub_aitc_onto_existing "$PROFILE_C"
CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_C" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SB_C/log2" 2>&1
assert_eq   "C: re-run (ai-tc added) exits 0" "0" "$?"
assert_ok   "C: settings.json is valid JSON" jq -e . "$SC"
assert_ok   "C: .statusLine is absent" \
  bash -c "jq -e '(has(\"statusLine\"))|not' '$SC' >/dev/null"
assert_ok   "C: no _aka_prior_statusLine stash key" \
  bash -c "jq -e '(has(\"_aka_prior_statusLine\"))|not' '$SC' >/dev/null"
assert_ok   "C: kit statusline.ts removed" \
  bash -c "[ ! -e '$PROFILE_C/hooks/statusline.ts' ]"
assert_lit  "C: 'removed the kit status line (no previous one to restore)' shown" \
  'ai-tc detected; removed the kit status line (no previous one to restore)' "$SB_C/log2"
assert_nlit "C: does NOT claim a restore that didn't happen" \
  '(restored your previous one)' "$SB_C/log2"

# ── D. user's prior statusLine X → install kit (X stashed) → add ai-tc → re-run ─
SB_D="$(sandbox)"; RC_D="$SB_D/.bashrc"; touch "$RC_D"
PROFILE_D="$SB_D/.claude-aka"
mkdir -p "$PROFILE_D"
USER_X='{"type":"command","command":"echo mine"}'
jq -n --argjson sl "$USER_X" '{statusLine:$sl}' > "$PROFILE_D/settings.json"

CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_D" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SB_D/log1" 2>&1
assert_eq   "D: first (pre-ai-tc) install exits 0" "0" "$?"
SD="$PROFILE_D/settings.json"
assert_ok   "D: precondition — kit statusLine installed" \
  bash -c "jq -e '(.statusLine.command // \"\")|endswith(\"/statusline.ts\")' '$SD' >/dev/null"
assert_ok   "D: precondition — X stashed" \
  bash -c "jq -e --argjson want '$USER_X' '._aka_prior_statusLine == \$want' '$SD' >/dev/null"

stub_aitc_onto_existing "$PROFILE_D"
CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_D" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SB_D/log2" 2>&1
assert_eq   "D: re-run (ai-tc added) exits 0" "0" "$?"
assert_ok   "D: settings.json is valid JSON" jq -e . "$SD"
assert_ok   "D: .statusLine restored to X" \
  bash -c "jq -e --argjson want '$USER_X' '.statusLine == \$want' '$SD' >/dev/null"
assert_ok   "D: no _aka_prior_statusLine stash key (consumed by the restore)" \
  bash -c "jq -e '(has(\"_aka_prior_statusLine\"))|not' '$SD' >/dev/null"
assert_ok   "D: kit statusline.ts removed" \
  bash -c "[ ! -e '$PROFILE_D/hooks/statusline.ts' ]"
assert_lit  "D: 'removed the kit status line (restored your previous one)' shown" \
  'ai-tc detected; removed the kit status line (restored your previous one)' "$SB_D/log2"
assert_nlit "D: does NOT claim no-prior-to-restore" \
  '(no previous one to restore)' "$SB_D/log2"

# ── E. from D's end state, remove ai-tc → re-run: kit statusline comes back, ────
#      X is stashed again (not lost) ─────────────────────────────────────────
remove_aitc "$PROFILE_D"
CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_D" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SB_D/log3" 2>&1
assert_eq   "E: re-run (ai-tc removed) exits 0" "0" "$?"
assert_ok   "E: settings.json is valid JSON" jq -e . "$SD"
assert_ok   "E: kit statusLine installed again" \
  bash -c "jq -e '(.statusLine.command // \"\")|endswith(\"/statusline.ts\")' '$SD' >/dev/null"
assert_ok   "E: X stashed again (not lost)" \
  bash -c "jq -e --argjson want '$USER_X' '._aka_prior_statusLine == \$want' '$SD' >/dev/null"
assert_file "E: kit statusline.ts placed again" "$PROFILE_D/hooks/statusline.ts"

t_summary
