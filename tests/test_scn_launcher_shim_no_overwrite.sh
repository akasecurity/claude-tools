#!/usr/bin/env bash
# Scenario — the launcher shim never overwrites a user-owned file at <profile>/bin/<name>.
#
# write_launcher_shim writes <config_dir>/bin/<name>. The PATH-conflict gate cannot see a
# file there when that bin dir is not on the installer's PATH (or treats it as "our own
# shim" when it is), so without its own check the installer would silently clobber a
# user's script that happens to share the launcher name.
#
# Invariants:
#   A. --alias (strict) with a user-owned file at <dir>/bin/<name>: exits non-zero, the
#      file is byte-for-byte unchanged, and no alias block is written.
#   B. Same, with the bin dir ON the installer's PATH: still refused, file unchanged.
#   C. A kit-written shim (carries the marker) IS refreshed on re-run (no regression).
#   D. The rc already resolves <name> to this profile (user-managed alias) and a
#      user-owned file sits at the shim path: the file is left unchanged.
#
# Fully sandboxed: fake $HOME, --no-auth-inherit, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_launcher_shim_no_overwrite:"

INSTALL="$REPO_ROOT/install.sh"
USER_BODY='#!/bin/sh
echo "my own script"'

# setup <extra-PATH-prefix?> — fresh sandbox + profile dir with a user file at bin/aka-x.
setup() {
  SB="$(sandbox)"; RC="$SB/.bashrc"; touch "$RC"
  CDIR="$SB/.claude-x"; mkdir -p "$CDIR/bin"
  SHIM="$CDIR/bin/aka-x"
  printf '%s\n' "$USER_BODY" > "$SHIM"; chmod +x "$SHIM"
  cp "$SHIM" "$SB/orig"
}

run_alias() {
  HOME="$SB" PATH="${1:-}$(install_path)" SHELL=/bin/bash CT_CONFIG_DIR="$CDIR" CT_ALIAS=aka-x \
    bash "$INSTALL" --alias --no-auth-inherit >"$SB/log" 2>&1
  RC_RC=$?
}

# ── A. bin dir NOT on PATH ───────────────────────────────────────────────────
setup
run_alias
nz=0; [ "$RC_RC" -ne 0 ] && nz=1
assert_eq   "A: --alias refuses (non-zero)"            "1" "$nz"
assert_ok   "A: user file left byte-for-byte unchanged" cmp -s "$SB/orig" "$SHIM"
assert_nlit "A: no alias block written"                 "alias aka-x=" "$RC"
assert_lit  "A: explains the refusal"                   "not a launcher shim" "$SB/log"

# ── B. bin dir ON PATH (resolves to the profile's own bin path) ──────────────
setup
run_alias "$CDIR/bin:"
nz=0; [ "$RC_RC" -ne 0 ] && nz=1
assert_eq   "B: --alias refuses (non-zero)"            "1" "$nz"
assert_ok   "B: user file left byte-for-byte unchanged" cmp -s "$SB/orig" "$SHIM"
assert_nlit "B: no alias block written"                 "alias aka-x=" "$RC"

# ── C. a kit-marked shim is refreshed ────────────────────────────────────────
SB="$(sandbox)"; RC="$SB/.bashrc"; touch "$RC"; CDIR="$SB/.claude-x"; mkdir -p "$CDIR"
SHIM="$CDIR/bin/aka-x"
run_alias
assert_eq   "C: first --alias succeeds"  "0" "$RC_RC"
assert_lit  "C: shim carries the marker" "aka-claude-tools launcher shim" "$SHIM"
printf '#!/usr/bin/env bash\n# aka-claude-tools launcher shim — managed by install.sh; safe to delete with the profile.\nSTALE\n' > "$SHIM"
run_alias
assert_eq   "C: re-run succeeds"         "0" "$RC_RC"
assert_nlit "C: stale kit shim refreshed" "STALE" "$SHIM"
assert_lit  "C: refreshed shim execs claude" "exec claude" "$SHIM"

# ── D. user-managed rc alias already resolves here; user file at shim path ──
setup
printf "alias aka-x='CLAUDE_CONFIG_DIR=\"%s\" claude'\n" "$CDIR" > "$RC"
run_alias
assert_ok   "D: user file left byte-for-byte unchanged" cmp -s "$SB/orig" "$SHIM"

t_summary
