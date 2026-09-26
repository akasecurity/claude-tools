#!/usr/bin/env bash
# Scenario T26 — UNINSTALL/edge: the alias name is defined BOTH in our managed
# block AND in a user-authored line ELSEWHERE in the rc.
#
# Real-world shape: the user installs the kit (alias `aka` → ~/.claude-aka lands in
# a marker-delimited managed block), and SEPARATELY has their own hand-written
# `alias aka=...` line somewhere else in the rc — e.g. a personal shortcut to a
# different command, predating or unrelated to the kit. The two coexist.
#
# The documented uninstall (README "Uninstall") is the kit's own primitive:
#
#     rm -rf ~/.claude-aka
#     remove_managed_block <rc> <alias>
#
# The contract under test: remove_managed_block deletes ONLY the marker-delimited
# managed block (begin/end markers + the alias line BETWEEN them). The user's own
# `alias aka=...` line living OUTSIDE that block must survive verbatim — uninstall
# must not greedily strip every line that happens to mention the alias name.
#
# remove_managed_block matches its markers with awk `$0==marker` (whole-line exact),
# and only suppresses lines while BETWEEN begin/end — so a user alias line that is
# neither a marker nor inside the block should be untouched. This test pins that.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit; never touches a real
# ~/.claude* profile.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../shared/lib/common.sh
source "$REPO_ROOT/shared/lib/common.sh"
echo "test_scn_uninstall_alias_elsewhere:"

SB="$(sandbox)"
PROFILE="$SB/.claude-aka"
ALIAS="claude-aka"   # the derived default launcher name (bare aka is reserved for ai-tc)
RC="$SB/.bashrc"

# The user's OWN alias line — same NAME as the kit alias, but a totally different
# command (NOT a CLAUDE_CONFIG_DIR launcher). This is the line that must survive.
USER_ALIAS_LINE="alias ${ALIAS}='git add --all && git status'"

# ── create a real kit profile dir (so `rm -rf` is over a genuine install) ─────
# We install into a clean rc (no pre-existing user alias yet) so the installer
# writes its managed block keyed on the requested ALIAS, exactly as a normal
# install does. We seed the user's OWN `alias aka` line AFTERWARD — this models
# the user adding their own shortcut later, leaving the kit block keyed on `aka`.
touch "$RC"
PATH="$(install_path)" CT_ADDITIONS="leak-guard" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
assert_eq "install.sh exits 0" "0" "$?"
assert_file "profile dir created" "$PROFILE"
# The installer, on a clean rc, must have keyed its block on the requested ALIAS
# (no rename) — guard the precondition so the residue check below is meaningful.
assert_lit "installer wrote a managed block keyed on the requested alias" \
  "# >>> aka-claude-tools managed: ${ALIAS} >>>" "$RC"

# Now PREPEND the user's own content + their own `alias aka` line ABOVE the kit's
# managed block, plus surrounding content, so "both present" is the genuine state
# and "user line + surrounding rc survive" is testable.
KIT_BLOCK="$(cat "$RC")"
cat >"$RC" <<EOF
# user line at the very top
export PATH="\$HOME/bin:\$PATH"
${USER_ALIAS_LINE}
alias ll='ls -la'

# trailing user line
export EDITOR=vim
${KIT_BLOCK}
EOF

# Precondition assertions: BOTH the managed block AND the user's own line present.
assert_lit "managed begin marker present pre-uninstall" \
  "# >>> aka-claude-tools managed: ${ALIAS} >>>" "$RC"
assert_lit "managed end marker present pre-uninstall" \
  "# <<< aka-claude-tools managed: ${ALIAS} <<<" "$RC"
assert_lit "managed launcher alias line present pre-uninstall" \
  "alias ${ALIAS}='CLAUDE_CONFIG_DIR=\"${PROFILE}\" claude'" "$RC"
assert_lit "user's OWN alias line present pre-uninstall" "$USER_ALIAS_LINE" "$RC"
# Sanity: there really are TWO `alias aka=` lines at this point (ours + theirs).
PRE_COUNT="$(grep -cE "^alias ${ALIAS}=" "$RC")"
assert_eq "exactly two 'alias aka=' lines before uninstall" "2" "$PRE_COUNT"

# Capture the user's own line's exact bytes for a verbatim-survival check.
USER_LINE_BEFORE="$(grep -F -- "$USER_ALIAS_LINE" "$RC")"

# ── the documented uninstall ─────────────────────────────────────────────────
rm -rf "$PROFILE"
remove_managed_block "$RC" "$ALIAS"
rc=$?
assert_eq "remove_managed_block reports it removed a block (exit 0)" "0" "$rc"

# Profile gone.
[ -e "$PROFILE" ] && fail "profile dir removed" "still present: $PROFILE" \
                  || pass "profile dir removed"

# Managed block fully gone: markers + the launcher alias line stripped.
assert_nlit "begin marker removed" \
  "# >>> aka-claude-tools managed: ${ALIAS} >>>" "$RC"
assert_nlit "end marker removed" \
  "# <<< aka-claude-tools managed: ${ALIAS} <<<" "$RC"
assert_nlit "managed launcher alias line removed" \
  "alias ${ALIAS}='CLAUDE_CONFIG_DIR=" "$RC"
assert_nlit "no 'aka-claude-tools managed' residue anywhere" \
  "aka-claude-tools managed" "$RC"

# THE CORE CLAIM: the user's OWN alias line survives verbatim, untouched.
assert_lit "user's OWN alias line survived uninstall" "$USER_ALIAS_LINE" "$RC"
USER_LINE_AFTER="$(grep -F -- "$USER_ALIAS_LINE" "$RC")"
assert_eq "user's OWN alias line byte-identical after uninstall" \
  "$USER_LINE_BEFORE" "$USER_LINE_AFTER"

# Exactly ONE `alias aka=` line remains, and it's the USER's (not a launcher).
POST_COUNT="$(grep -cE "^alias ${ALIAS}=" "$RC")"
assert_eq "exactly one 'alias aka=' line after uninstall" "1" "$POST_COUNT"
assert_ngrep "the surviving alias is NOT a Claude launcher" \
  "^alias ${ALIAS}='CLAUDE_CONFIG_DIR=" "$RC"

# Surrounding user content untouched.
assert_lit "top user line preserved"      '# user line at the very top' "$RC"
assert_lit "user PATH export preserved"   'export PATH="$HOME/bin:$PATH"' "$RC"
assert_lit "user ll alias preserved"      "alias ll='ls -la'" "$RC"
assert_lit "trailing user line preserved" '# trailing user line' "$RC"
assert_lit "user EDITOR export preserved" 'export EDITOR=vim' "$RC"

t_summary
