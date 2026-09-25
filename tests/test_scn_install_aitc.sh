#!/usr/bin/env bash
# Scenario — install-time ai-tc detection (Task 7).
#
# The installer's statusline build step and offer_aitc must agree with the hooks
# (Tasks 4-6) on ONE detection rule: guard-core's detectAitc, via the
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
#      survives untouched.
#   C. A pre-existing, non-kit .statusLine in profile B is left byte-identical —
#      neither stashed into _aka_prior_statusLine nor pruned — because the kit
#      never claims the slot in the first place.
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

stub_aitc() { # <profile-dir> — registry + enabled + cache dir, matches Task 6's shape
  mkdir -p "$1/plugins/cache/akasecurity/ai-tc/1"
  printf '%s' '{"plugins":{"ai-tc@akasecurity":[{}]}}' > "$1/plugins/installed_plugins.json"
  printf '%s' '{"enabledPlugins":{"ai-tc@akasecurity":true}}' > "$1/settings.json"
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

t_summary
