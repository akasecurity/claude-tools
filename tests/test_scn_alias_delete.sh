#!/usr/bin/env bash
# Scenario — --delete-alias removes the managed alias block from the shell rc.
#
# Invariants:
#   A. --delete-alias removes the block for CT_ALIAS and exits 0.
#   B. The rc is clean after deletion (empty); no other content is disturbed.
#   C. Wrong-profile guard: if CT_CONFIG_DIR is supplied and the alias points to a
#      DIFFERENT profile, --delete-alias exits non-zero and leaves the rc untouched.
#   D. Missing block exits non-zero (no managed block found).
#   E. Injection in the alias name is refused (same guard as --alias).
#   F. Rename round-trip: delete old name + create new name via --alias.
#
# Fully sandboxed: fake $HOME, fake rc. Never touches a real ~/.claude*.
# Every install.sh invocation pins SHELL=/bin/bash so detect_shell_rc resolves
# deterministically to .bashrc on EVERY host: the all-Mac dev fleet defaults to
# zsh (.zshrc) while Linux CI defaults to bash (.bashrc), so without pinning the
# rc target diverged and the assertions only passed on macOS (issue surfaced in
# crew review of PR #112). Mirrors tests/test_scn_alias_multi.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_alias_delete:"

INSTALL="$REPO_ROOT/install.sh"
# Hermetic PATH: the installer refuses a launcher name that is already a PATH
# command (e.g. a real ai-tc `aka` on the operator's machine), so alias-creating
# runs must not see the operator's full PATH.
IPATH="$(install_path)"

# Helper: fresh sandbox + create one alias. Sets SB (sandbox $HOME) and RC (the
# rc detect_shell_rc selects under SHELL=/bin/bash — .bashrc, which we pre-create).
mk_alias() {
  SB="$(sandbox)"; export HOME="$SB"; RC="$SB/.bashrc"; touch "$RC"
  PATH="$IPATH" CT_CONFIG_DIR="$SB/$1" CT_ALIAS="$2" SHELL=/bin/bash HOME="$SB" \
    bash "$INSTALL" --alias --no-auth-inherit >"$SB/log" 2>&1
}

# ── A. basic delete removes the block ─────────────────────────────────────────
mk_alias ".claude-aka" "aka"
CT_CONFIG_DIR="$SB/.claude-aka" CT_ALIAS="aka" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >"$SB/del-log" 2>&1
assert_eq  "A: delete exits 0"             "0" "$?"
assert_ngrep "A: alias line gone from rc"  "alias aka=" "$RC"
assert_ngrep "A: begin marker gone"        ">>> aka-claude-tools managed: aka" "$RC"

# ── B. rc is clean after deletion — no stray content ─────────────────────────
assert_eq "B: rc is empty after clean delete" "0" "$(wc -c < "$RC" | tr -d ' ')"

# ── C. wrong-profile guard refuses deletion ───────────────────────────────────
mk_alias ".claude-aka" "aka"
CT_CONFIG_DIR="$SB/.claude-WRONG" CT_ALIAS="aka" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >"$SB/del-log" 2>&1
RC_WRONG=$?
assert_eq  "C: wrong-profile exits non-zero" "1" "$RC_WRONG"
assert_grep "C: error mentions the real target" ".claude-aka" "$SB/del-log"
assert_lit  "C: alias block still present"  "alias aka=" "$RC"

# ── D. missing block exits non-zero ──────────────────────────────────────────
CT_ALIAS="nonexistent" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >"$SB/del-log" 2>&1
assert_eq "D: missing block exits non-zero" "1" "$?"
assert_grep "D: explains no block found" "No aka-claude-tools-managed alias block" "$SB/del-log"

# ── E. injection in alias name is refused ────────────────────────────────────
CT_ALIAS="a;rm -rf ~" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >"$SB/del-log" 2>&1
assert_eq "E: injected name exits non-zero" "1" "$?"
assert_grep "E: explains refusal" "unsafe alias name" "$SB/del-log"

# ── F. rename round-trip: delete + re-alias ──────────────────────────────────
mk_alias ".claude-aka" "aka"
CT_CONFIG_DIR="$SB/.claude-aka" CT_ALIAS="aka" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >/dev/null 2>&1
assert_ngrep "F: old alias gone"  "alias aka=" "$RC"
PATH="$IPATH" CT_CONFIG_DIR="$SB/.claude-aka" CT_ALIAS="aka-new" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --alias --no-auth-inherit >/dev/null 2>&1
assert_lit  "F: new alias present" "alias aka-new=" "$RC"
assert_ngrep "F: old name absent"  "alias aka=" "$RC"

# ── G. multiple-config coexistence: delete one, leave the other ──────────────
mk_alias ".claude-aka" "aka"
PATH="$IPATH" CT_CONFIG_DIR="$SB/.claude-work" CT_ALIAS="work" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --alias --no-auth-inherit >/dev/null 2>&1
CT_CONFIG_DIR="$SB/.claude-aka" CT_ALIAS="aka" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >/dev/null 2>&1
assert_ngrep "G: aka block gone"    "alias aka="  "$RC"
assert_lit   "G: work block intact" "alias work=" "$RC"

# ── H. family-isolation: delete aka does NOT remove aka2 (different profile) ──
# Validates that exact-marker deletion is used (not remove_managed_block's id[0-9]* family).
mk_alias ".claude-aka" "aka"
# Manually write an aka2 block for a different profile (simulates collision-renaming).
SB2="$(sandbox)"; export HOME="$SB2"; RC2="$SB2/.bashrc"; touch "$RC2"
PATH="$IPATH" CT_CONFIG_DIR="$SB2/.claude-work" CT_ALIAS="aka2" SHELL=/bin/bash HOME="$SB2" \
  bash "$INSTALL" --alias --no-auth-inherit >/dev/null 2>&1
# Merge aka2 block from SB2 into SB's rc.
cat "$RC2" >> "$RC"; export HOME="$SB"
# Now rc has: aka block (profile .claude-aka) and aka2 block (profile .claude-work).
CT_CONFIG_DIR="$SB/.claude-aka" CT_ALIAS="aka" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >/dev/null 2>&1
assert_ngrep "H: aka block gone"              "alias aka="   "$RC"
assert_lit   "H: aka2 block untouched"        "alias aka2="  "$RC"

t_summary
