#!/usr/bin/env bash
# Scenario (scn_edge_uninstall_residue): UNINSTALL/edge — ORPHAN alias residue
# after a collision-renamed install.
#
# Sequence the existing matrix never tests end-to-end:
#   1. The user ALREADY has their own `alias aka=...` (a non-launcher shortcut).
#   2. They install the kit. Step 5's collision handling (alias_target_elsewhere
#      → OTHER) renames our launcher to the alternate `aka2` and writes a managed
#      block keyed on `aka2` (NOT `aka`) — proven by T12 (alias_collision).
#   3. Later they uninstall, following the README "Uninstall" section VERBATIM:
#        rm -rf ~/.claude-aka
#        remove the `# >>> aka-claude-tools managed: <alias> >>>` block
#      where `<alias>` is the documented default alias `aka` — because that is the
#      only alias name the README ever names, and the chosen alias name is recorded
#      NOWHERE in the profile (no metadata file the user could consult).
#
# THE DEFECT: remove_managed_block "$RC" "aka" finds no `aka` block (ours is keyed
# on `aka2`), removes nothing, and leaves BOTH the `aka2` managed block AND its
# live `alias aka2='CLAUDE_CONFIG_DIR="…/.claude-aka" claude'` launcher behind —
# a DANGLING alias pointing at the now-deleted profile. That is orphan residue the
# documented uninstall cannot clear, because the user has no way to learn the
# renamed alias from the docs or the profile.
#
# This test pins the INTENDED post-uninstall state (no kit residue, dangling
# launcher gone). It is RED against current behavior — that is the point: it marks
# an open defect. When fixed (record the chosen alias for uninstall, OR document
# that a collision renames the alias and the user must remove the `<alias>2` block,
# OR ship a one-shot uninstaller that finds every `aka-claude-tools managed` block),
# it goes green.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit; never touches a
# real ~/.claude* profile.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../shared/lib/common.sh
source "$REPO_ROOT/shared/lib/common.sh"
echo "test_scn_edge_uninstall_residue:"

SB="$(sandbox)"
RC="$SB/.bashrc"
PROFILE="$SB/.claude-aka"
ALIAS="aka-claude"   # the documented default launcher name the README names

# (1) The user's OWN, pre-existing `alias aka-claude=` — a non-launcher shortcut.
# This is the collision trigger: a real conflict that forces the installer to rename.
USER_ALIAS_LINE="alias ${ALIAS}='cd ~/work && git status'"
printf '# user fleet shortcut\n%s\n' "$USER_ALIAS_LINE" > "$RC"

# (2) Install — collision handling auto-takes the alternate name `aka-claude2`.
PATH="$(install_path)" CT_ADDITIONS="leak-guard wrap-up" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
assert_eq "install.sh exits 0" "0" "$?"
assert_file "profile dir created" "$PROFILE"

# Precondition: the kit keyed its block on the ALTERNATE name (aka2), not aka.
assert_lit "managed block keyed on the alternate 'aka2' (collision rename)" \
  "# >>> aka-claude-tools managed: ${ALIAS}2 >>>" "$RC"
assert_nlit "NO managed block keyed on 'aka' (user's own alias untouched)" \
  "# >>> aka-claude-tools managed: ${ALIAS} >>>" "$RC"
assert_lit "user's own 'aka' alias preserved" "$USER_ALIAS_LINE" "$RC"

# The chosen alias name (aka2) is recorded NOWHERE in the profile, so the user has
# no machine-readable way to learn it at uninstall time. Pin that gap explicitly.
if grep -rqF "${ALIAS}2" "$PROFILE" 2>/dev/null; then
  pass "chosen alias name discoverable from the profile"
else
  fail "chosen alias name discoverable from the profile" \
    "alias '${ALIAS}2' is recorded nowhere in $PROFILE — docs name only the default"
fi

# (3) The DOCUMENTED uninstall, verbatim per README:
#       rm -rf ~/.claude-aka
#       remove_managed_block <rc> <alias>   (alias = the documented default 'aka')
rm -rf "$PROFILE"
remove_managed_block "$RC" "$ALIAS"   # finds nothing — ours is keyed on aka2

# Profile gone — that half works.
[ -e "$PROFILE" ] && fail "profile dir removed" "still present: $PROFILE" \
                  || pass "profile dir removed"

# THE CORE CLAIM (RED today): after the documented uninstall the rc carries NO kit
# residue. Currently the aka2 block + its launcher survive as orphans.
assert_nlit "no 'aka-claude-tools managed' residue after documented uninstall" \
  "aka-claude-tools managed" "$RC"
assert_nlit "no orphan 'aka2' managed block left behind" \
  "# >>> aka-claude-tools managed: ${ALIAS}2 >>>" "$RC"

# A DANGLING launcher is the user-visible harm: `alias aka2=` still points at the
# deleted profile dir, so typing aka2 in a new shell launches claude with a config
# dir that no longer exists.
assert_ngrep "no dangling kit launcher alias remains" \
  "^alias ${ALIAS}2='CLAUDE_CONFIG_DIR=" "$RC"

# The user's OWN alias must of course still survive (the uninstall must be precise).
assert_lit "user's own 'aka' alias still present after uninstall" "$USER_ALIAS_LINE" "$RC"

t_summary
