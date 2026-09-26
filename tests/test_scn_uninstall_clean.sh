#!/usr/bin/env bash
# Scenario T23 — UNINSTALL/clean: full removal of a cleanly-installed NON-default
# profile. The kit ships no one-shot uninstall command; the documented procedure
# (README "Uninstall") is a manual two-step that uses the kit's own primitives:
#
#     rm -rf ~/.claude-aka                       # the profile dir
#     remove_managed_block <rc> <alias>          # the managed rc block
#
# This test installs a non-default profile (alias `aka` → ~/.claude-aka) into a
# sandbox whose rc has REAL user content above AND below the spot the block lands,
# and a separate DEFAULT ~/.claude profile seeded with its own marker file. It
# then runs the documented uninstall and asserts:
#   • the profile dir is gone,
#   • the managed rc block is removed EXACTLY (begin/end markers + alias line),
#   • the surrounding rc is byte-for-byte what it was before install (no residue,
#     no stray blank-line damage to the user's own lines),
#   • the default ~/.claude profile is never touched.
#
# remove_managed_block lives in shared/lib/common.sh — the same primitive the
# installer itself uses to drop a redundant alias block — so the uninstall path
# under test is the kit's own code, not an ad-hoc sed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../shared/lib/common.sh
source "$REPO_ROOT/shared/lib/common.sh"
echo "test_scn_uninstall_clean:"

SB="$(sandbox)"
PROFILE="$SB/.claude-aka"
ALIAS="claude-aka"   # the derived default launcher name (bare aka is reserved for ai-tc)
RC="$SB/.bashrc"

# Seed an rc with distinct user content BEFORE and AFTER where our block lands,
# so "surrounding rc untouched" is actually testable. Capture its exact bytes.
cat >"$RC" <<'EOF'
# user line BEFORE the managed block
export PATH="$HOME/bin:$PATH"
alias ll='ls -la'

# trailing user line AFTER the managed block
export EDITOR=vim
EOF
RC_BEFORE="$(cat "$RC")"

# Seed a DEFAULT ~/.claude profile that the installer must never touch.
DEFAULT="$SB/.claude"
mkdir -p "$DEFAULT"
printf 'DO NOT TOUCH default profile\n' >"$DEFAULT/settings.json"
DEFAULT_SETTINGS_BEFORE="$(cat "$DEFAULT/settings.json")"
DEFAULT_SNAP="$(ls -1 "$DEFAULT")"

# ── install the non-default profile ──────────────────────────────────────────
PATH="$(install_path)" CT_ADDITIONS="leak-guard" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
rc=$?
assert_eq   "install.sh exits 0" "0" "$rc"
assert_file "non-default profile dir created" "$PROFILE"
assert_lit  "managed begin marker written to rc" \
  "# >>> aka-claude-tools managed: ${ALIAS} >>>" "$RC"
assert_lit  "managed end marker written to rc" \
  "# <<< aka-claude-tools managed: ${ALIAS} <<<" "$RC"
assert_lit  "alias line written to rc" \
  "alias ${ALIAS}='CLAUDE_CONFIG_DIR=\"${PROFILE}\" claude'" "$RC"
# Default profile must be untouched by the install itself.
assert_eq   "default ~/.claude/settings.json unchanged after install" \
  "$DEFAULT_SETTINGS_BEFORE" "$(cat "$DEFAULT/settings.json")"

# ── the documented uninstall ─────────────────────────────────────────────────
rm -rf "$PROFILE"
remove_managed_block "$RC" "$ALIAS"

# Profile fully gone.
[ -e "$PROFILE" ] && fail "profile dir removed" "still present: $PROFILE" \
                  || pass "profile dir removed"

# Managed block removed exactly: no markers, no alias line left behind.
assert_nlit "begin marker removed from rc" \
  "# >>> aka-claude-tools managed: ${ALIAS} >>>" "$RC"
assert_nlit "end marker removed from rc" \
  "# <<< aka-claude-tools managed: ${ALIAS} <<<" "$RC"
assert_nlit "alias line removed from rc" \
  "alias ${ALIAS}='CLAUDE_CONFIG_DIR=" "$RC"
assert_nlit "no 'aka-claude-tools managed' residue anywhere in rc" \
  "aka-claude-tools managed" "$RC"

# Surrounding rc untouched: the user's own lines survive verbatim.
assert_lit  "user line BEFORE block preserved" \
  '# user line BEFORE the managed block' "$RC"
assert_lit  "user PATH export preserved"  'export PATH="$HOME/bin:$PATH"' "$RC"
assert_lit  "user ll alias preserved"     "alias ll='ls -la'" "$RC"
assert_lit  "user line AFTER block preserved" \
  '# trailing user line AFTER the managed block' "$RC"
assert_lit  "user EDITOR export preserved" 'export EDITOR=vim' "$RC"

# Strongest claim: the rc is byte-for-byte its pre-install self. install (append)
# + uninstall (block removal) must be a perfect round-trip on the user's file.
assert_eq   "rc byte-identical to pre-install state" "$RC_BEFORE" "$(cat "$RC")"

# Default profile still present and untouched.
assert_file "default ~/.claude dir still present" "$DEFAULT"
assert_eq   "default ~/.claude/settings.json byte-identical" \
  "$DEFAULT_SETTINGS_BEFORE" "$(cat "$DEFAULT/settings.json")"
assert_eq   "default ~/.claude dir listing unchanged" \
  "$DEFAULT_SNAP" "$(ls -1 "$DEFAULT")"

t_summary
