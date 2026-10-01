#!/usr/bin/env bash
# scn_launcher_alternate_rc_collision: INSTALL/edge — the primary launcher name
# collides, and the offered ALTERNATE (default `<name>2`) is ALSO already an alias
# in the user's shell config (rc or a sourced file).
#
# The alternate must be re-gated against rc-defined aliases the same way the
# primary is (alias_target_elsewhere), not only against PATH commands. Otherwise
# the new managed block would shadow the user's own `aka-claude2`. Bounded: no
# re-prompt loop — the installer reports and writes no alias.
#
# Two shapes, each its own sandbox:
#   A) primary + alternate both defined in the rc itself;
#   B) primary in the rc, alternate in a file the rc sources.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_launcher_alternate_rc_collision:"

SEL="secure-settings leak-guard wrap-up"
IPATH="$(install_path)"

# ── shape A: both names in the rc ─────────────────────────────────────────────
SB_A="$(sandbox)"
RC_A="$SB_A/.bashrc"
USER1_A="alias aka-claude='echo mine-1'"
USER2_A="alias aka-claude2='echo mine-2'"
printf '%s\n%s\n' "$USER1_A" "$USER2_A" > "$RC_A"

PATH="$IPATH" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_A" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB_A/log" 2>&1
rc=$?

assert_eq   "A: install exits 0" "0" "$rc"
assert_lit  "A: user's 'aka-claude' preserved" "$USER1_A" "$RC_A"
assert_lit  "A: user's 'aka-claude2' preserved" "$USER2_A" "$RC_A"
assert_nlit "A: no managed block for 'aka-claude2' (would shadow the user's alias)" \
  ">>> aka-claude-tools managed: aka-claude2 >>>" "$RC_A"
assert_nlit "A: no managed block written at all" \
  ">>> aka-claude-tools managed" "$RC_A"
assert_grep "A: alternate collision reported" "'aka-claude2' is also" "$SB_A/log"

# ── shape B: alternate lives in a sourced file ────────────────────────────────
SB_B="$(sandbox)"
RC_B="$SB_B/.bashrc"
FLEET_B="$SB_B/.aliases"
USER2_B="alias aka-claude2='CLAUDE_CONFIG_DIR=\"\$HOME/.claude-other\" claude'"
printf '%s\n' "$USER2_B" > "$FLEET_B"
printf "alias aka-claude='echo mine-1'\nsource %s\n" "$FLEET_B" > "$RC_B"

PATH="$IPATH" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_B" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB_B/log" 2>&1
rc=$?

assert_eq   "B: install exits 0" "0" "$rc"
assert_lit  "B: sourced 'aka-claude2' preserved" "$USER2_B" "$FLEET_B"
assert_nlit "B: no managed block for 'aka-claude2' in rc" \
  ">>> aka-claude-tools managed: aka-claude2 >>>" "$RC_B"
assert_grep "B: alternate collision reported" "'aka-claude2' is also" "$SB_B/log"

t_summary
