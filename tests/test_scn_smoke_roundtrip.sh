#!/usr/bin/env bash
# Happy-path round-trip smoke (T4) — the end-to-end install → re-run → uninstall
# arc in ONE sandbox, asserting the user-visible product actually appears, stays
# converged on a re-run, and is fully removed on a deselect-all uninstall. This is
# the coarse "does the whole thing work" smoke that protects against gross
# end-to-end breakage; the finer invariants live in test_install / test_idempotency
# / test_uninstall. Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit,
# never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_smoke_roundtrip:"

SB="$(sandbox)"
RC="$SB/.bashrc"; touch "$RC"          # deterministic rc target for the alias block
PROFILE="$SB/.claude-aka"              # non-default config dir (default is ~/.claude)

# Deterministic recommended subset that needs no optional runtime (bun/rtk/trufflehog),
# so the smoke is stable in CI: a hook (leak-guard), a command (wrap-up), a skill
# (shell-audit), a statusLine (statusline), and base settings (secure-settings).
SEL="secure-settings leak-guard wrap-up shell-audit statusline"
# Hermetic PATH (install_path): an operator's real `aka-claude` PATH command must
# not turn this into a conflict-rename.
IPATH="$(install_path)"
run() { PATH="$IPATH" CT_ADDITIONS="$1" SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# ── (1) clean install into a fresh non-default config dir ─────────────────────
run "$SEL"; rc1=$?
assert_eq   "clean install exits 0" "0" "$rc1"
assert_file "profile dir created" "$PROFILE"
assert_ok   "settings.json is valid JSON" jq -e . "$PROFILE/settings.json"

# Selected artifacts placed (path-remapped: config/<X> -> <X> in profile).
assert_file "hook placed: leak-guard.ts"      "$PROFILE/hooks/leak-guard.ts"
assert_file "command placed: wrap-up.md"     "$PROFILE/commands/wrap-up.md"
assert_file "skill placed: shell-audit"      "$PROFILE/skills/shell-audit"
assert_file "statusline hook placed"         "$PROFILE/hooks/statusline.ts"

# Deployed kit hook carries the managed marker (drives self-clean on later rebuilds).
assert_lit  "deployed hook carries managed-hook marker" \
  "aka-claude-tools:managed-hook" "$PROFILE/hooks/leak-guard.ts"

# leak-guard registered in settings; statusLine wired.
assert_ok   "leak-guard registered in settings.PreToolUse" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.ts\"))' '$PROFILE/settings.json' >/dev/null"
assert_ok   "statusLine command wired in settings" \
  bash -c "jq -e '(.statusLine.command // \"\") | endswith(\"/statusline.ts\")' '$PROFILE/settings.json' >/dev/null"

# No maintainer-only \$comment keys leaked into the user's merged settings.
assert_ok   "no \$comment keys in deployed settings" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$PROFILE/settings.json' >/dev/null"

# Alias block written to the sandbox shell rc, pointing at THIS profile.
assert_lit  "managed alias block opener in rc" \
  ">>> aka-claude-tools managed: aka-claude" "$RC"
assert_lit  "alias points CLAUDE_CONFIG_DIR at this profile" \
  "CLAUDE_CONFIG_DIR=\"$PROFILE\"" "$RC"

# The smoke must never wire anything at the DEFAULT ~/.claude path (non-default
# install). The literal "/.claude/" (trailing slash) would only appear if a
# command/alias referenced the default dir; the profile path is ".claude-aka".
assert_nlit "rc never references default ~/.claude dir" "$SB/.claude/" "$RC"
assert_ok   "settings never reference default ~/.claude dir" \
  bash -c "jq -e '[.. | strings | select(test(\"/\\\\.claude/\"))] | length == 0' '$PROFILE/settings.json' >/dev/null"

cp "$PROFILE/settings.json" "$SB/after1.json"

# ── (2) idempotent re-run → convergence, no dup hook regs, single alias block ─
run "$SEL"; rc2=$?
assert_eq   "re-run exits 0" "0" "$rc2"
cp "$PROFILE/settings.json" "$SB/after2.json"

if diff <(jq -S . "$SB/after1.json") <(jq -S . "$SB/after2.json") >/dev/null 2>&1; then
  pass "settings.json canonical-identical across re-run"
else
  fail "settings.json canonical-identical across re-run" "re-run changed settings (non-idempotent)"
fi

n_block=$(grep -c '>>> aka-claude-tools managed' "$RC")
assert_eq   "single managed alias block in rc after re-run" "1" "$n_block"

n_tot=$(jq '.hooks.PreToolUse | length' "$SB/after2.json")
n_uniq=$(jq '.hooks.PreToolUse | unique_by(tojson) | length' "$SB/after2.json")
assert_eq   "no duplicate PreToolUse registrations after re-run" "$n_tot" "$n_uniq"

# ── (3) uninstall: deselect-all → kit files + registrations removed ──────────
run ""; rc3=$?
assert_eq   "deselect-all re-run exits 0" "0" "$rc3"

[ -e "$PROFILE/hooks/leak-guard.ts" ] && fail "leak-guard hook removed on deselect-all" "still present" \
                                     || pass "leak-guard hook removed on deselect-all"
[ -e "$PROFILE/commands/wrap-up.md" ] && fail "wrap-up command removed on deselect-all" "still present" \
                                      || pass "wrap-up command removed on deselect-all"
[ -e "$PROFILE/skills/shell-audit" ]  && fail "shell-audit skill removed on deselect-all" "still present" \
                                      || pass "shell-audit skill removed on deselect-all"
[ -e "$PROFILE/hooks/statusline.ts" ] && fail "statusline hook removed on deselect-all" "still present" \
                                      || pass "statusline hook removed on deselect-all"

assert_ok   "settings.json still valid JSON after uninstall" jq -e . "$PROFILE/settings.json"
assert_ok   "no PreToolUse hook registrations remain after uninstall" \
  bash -c "jq -e '((.hooks.PreToolUse // []) | length) == 0' '$PROFILE/settings.json' >/dev/null"
assert_ok   "statusLine pruned after uninstall" \
  bash -c "jq -e 'has(\"statusLine\") | not' '$PROFILE/settings.json' >/dev/null"

# Default ~/.claude path is never created or referenced anywhere in the round-trip.
[ -e "$SB/.claude" ] && fail "default ~/.claude never created during round-trip" "it exists" \
                     || pass "default ~/.claude never created during round-trip"

t_summary
