#!/usr/bin/env bash
# Scenario — the launcher rename: `claude-aka` is the default, `aka-claude` is a
# deprecated forwarder for one release.
#
# Bare `aka` and every `aka-*` name belong to the ai-tc CLI, so the launcher for
# ~/.claude-aka is `claude-aka`. A profile installed under the old default keeps
# working: the next --apply (or interactive/--defaults re-run) writes the
# `claude-aka` launcher and turns `aka-claude` into a forwarder that prints one
# deprecation line to stderr and runs `claude-aka` with the same arguments.
#
# Invariants:
#   A. A fresh --defaults install into ~/.claude-aka writes the `claude-aka` shim and
#      managed block, records alias=claude-aka, and writes NO `aka-claude` shim/block.
#   B. Migration on --apply: a profile recorded as alias=aka-claude (written by the
#      pre-rename --alias path) gets the `claude-aka` shim + block, alias=claude-aka,
#      deprecated_alias=aka-claude; the aka-claude block's alias line forwards and
#      drops its PATH export; the aka-claude shim keeps the kit marker.
#   C. The forwarder shim prints exactly the deprecation line once to stderr and runs
#      the profile's claude with the forwarded arguments.
#   D. The forwarder alias does the same in an interactive bash sourcing the rc.
#   E. Idempotent: a second --apply leaves the rc and both shims byte-identical.
#   F. --delete-alias aka-claude removes only the forwarder (block + shim); the
#      claude-aka launcher stays.
#   G. --delete-alias claude-aka removes both launchers, both blocks, and bin/.
#   H. uninstall.sh leaves no aka-claude or claude-aka block in the rc.
#   I. A user-owned aka-claude shim (no kit marker) is never overwritten: migration
#      warns and skips the forwarder, but still writes claude-aka.
#   J. The --defaults re-run path migrates too.
#   K. Other derivations are unchanged: ~/.claude-work still defaults to `work`.
#
# Fully sandboxed: fake $HOME, fake rc, hermetic PATH, SHELL=/bin/bash.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_launcher_rename:"

INSTALL="$REPO_ROOT/install.sh"
UNINSTALL="$REPO_ROOT/uninstall.sh"
IPATH="$(install_path)"
SHIM_MARKER='aka-claude-tools launcher shim'
DEPMSG='aka-claude is deprecated; use claude-aka'
SEL="secure-settings wrap-up"

meta() { grep -E "^$2=" "$1/.aka-claude-tools-meta" 2>/dev/null | tail -1 | cut -d= -f2-; }

# legacy_profile SB — build the pre-rename state: an applied profile at
# $SB/.claude-aka whose launcher is `aka-claude` (shim + block + alias=aka-claude),
# written through the same --alias path the old default used.
legacy_profile() {
  local sb="$1" cfg="$1/.claude-aka"
  touch "$sb/.bashrc"
  PATH="$IPATH" CT_CONFIG_DIR="$cfg" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$sb" \
    bash "$INSTALL" --apply >"$sb/legacy.log" 2>&1 || return 1
  PATH="$IPATH" CT_CONFIG_DIR="$cfg" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$sb" \
    bash "$INSTALL" --alias >>"$sb/legacy.log" 2>&1
}
apply_again() {
  PATH="$IPATH" CT_CONFIG_DIR="$1/.claude-aka" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$1" \
    bash "$INSTALL" --apply >"$1/${2:-apply}.log" 2>&1
}

STUB="$(sandbox)/stubbin"; mkdir -p "$STUB"
cat > "$STUB/claude" <<'C'
#!/bin/sh
echo "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR args=$*"
C
chmod +x "$STUB/claude"

# ── A. fresh install defaults to claude-aka ───────────────────────────────────
SBA="$(sandbox)"; RCA="$SBA/.bashrc"; touch "$RCA"; CFGA="$SBA/.claude-aka"
PATH="$IPATH" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SBA" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SBA/log" 2>&1
assert_eq   "A: --defaults install exits 0" "0" "$?"
assert_file "A: claude-aka shim placed" "$CFGA/bin/claude-aka"
assert_lit  "A: managed block keyed on claude-aka" ">>> aka-claude-tools managed: claude-aka >>>" "$RCA"
assert_lit  "A: claude-aka alias points at the profile" \
  "alias claude-aka='CLAUDE_CONFIG_DIR=\"$CFGA\" claude'" "$RCA"
assert_eq   "A: meta alias is claude-aka" "claude-aka" "$(meta "$CFGA" alias)"
[ -e "$CFGA/bin/aka-claude" ] && fail "A: no aka-claude shim" "present" || pass "A: no aka-claude shim"
assert_nlit "A: no aka-claude block" ">>> aka-claude-tools managed: aka-claude >>>" "$RCA"
assert_eq   "A: meta has no deprecated_alias" "" "$(meta "$CFGA" deprecated_alias)"

# ── B. migration on --apply ───────────────────────────────────────────────────
SB="$(sandbox)"; RC="$SB/.bashrc"; CFG="$SB/.claude-aka"
legacy_profile "$SB"
assert_eq "B: precondition — legacy meta alias is aka-claude" "aka-claude" "$(meta "$CFG" alias)"
apply_again "$SB"
assert_eq   "B: --apply exits 0" "0" "$?"
assert_file "B: claude-aka shim written" "$CFG/bin/claude-aka"
assert_lit  "B: claude-aka block written" ">>> aka-claude-tools managed: claude-aka >>>" "$RC"
assert_lit  "B: claude-aka alias points at the profile" \
  "alias claude-aka='CLAUDE_CONFIG_DIR=\"$CFG\" claude'" "$RC"
assert_eq   "B: meta alias is claude-aka" "claude-aka" "$(meta "$CFG" alias)"
assert_eq   "B: meta deprecated_alias is aka-claude" "aka-claude" "$(meta "$CFG" deprecated_alias)"
assert_lit  "B: aka-claude alias line forwards with the notice" \
  "alias aka-claude='printf \"%s\\n\" \"$DEPMSG\" >&2; claude-aka'" "$RC"
assert_nlit "B: the old direct aka-claude launcher line is gone" \
  "alias aka-claude='CLAUDE_CONFIG_DIR=" "$RC"
assert_eq   "B: exactly one PATH export (carried by claude-aka)" "1" "$(grep -cF 'export PATH=' "$RC")"
assert_eq   "B: exactly two managed blocks" "2" "$(grep -c '>>> aka-claude-tools managed' "$RC")"
assert_lit  "B: forwarder shim keeps the kit marker" "$SHIM_MARKER" "$CFG/bin/aka-claude"
assert_ok   "B: forwarder shim is executable" test -x "$CFG/bin/aka-claude"
assert_grep "B: migration is reported" "aka-claude is deprecated" "$SB/apply.log"

# ── C. the forwarder shim ─────────────────────────────────────────────────────
OUT="$(PATH="$STUB:/usr/bin:/bin" "$CFG/bin/aka-claude" --version 2>"$SB/c.err")"
assert_eq "C: forwarder runs claude with the profile dir and forwarded args" \
  "CLAUDE_CONFIG_DIR=$CFG args=--version" "$OUT"
assert_eq "C: stderr is exactly the deprecation line" "$DEPMSG" "$(cat "$SB/c.err")"

# ── D. the forwarder alias in an interactive bash ─────────────────────────────
# env -i: no inherited rc/alias state; --rcfile points at the sandbox rc.
OUT="$(env -i HOME="$SB" PATH="$STUB:/usr/bin:/bin" TERM=dumb \
        bash --rcfile "$RC" -ic 'aka-claude --version' 2>"$SB/d.err" </dev/null)"
assert_eq "D: bash -ic aka-claude runs claude with the profile dir and args" \
  "CLAUDE_CONFIG_DIR=$CFG args=--version" "$OUT"
assert_eq "D: deprecation line printed once to stderr" "1" "$(grep -cxF "$DEPMSG" "$SB/d.err")"

# ── E. idempotency ────────────────────────────────────────────────────────────
cp "$RC" "$SB/rc.before"; cp "$CFG/bin/aka-claude" "$SB/fwd.before"; cp "$CFG/bin/claude-aka" "$SB/new.before"
cp "$CFG/.aka-claude-tools-meta" "$SB/meta.before"
apply_again "$SB" apply2
assert_eq "E: second --apply exits 0" "0" "$?"
assert_ok "E: rc byte-identical after a second --apply" cmp -s "$SB/rc.before" "$RC"
assert_ok "E: forwarder shim unchanged" cmp -s "$SB/fwd.before" "$CFG/bin/aka-claude"
assert_ok "E: claude-aka shim unchanged" cmp -s "$SB/new.before" "$CFG/bin/claude-aka"
assert_ok "E: meta unchanged" cmp -s "$SB/meta.before" "$CFG/.aka-claude-tools-meta"
assert_ngrep "E: no migration on the second run" "aka-claude is deprecated" "$SB/apply2.log"

# ── F. --delete-alias aka-claude removes only the forwarder ───────────────────
SBF="$(sandbox)"; RCF="$SBF/.bashrc"; CFGF="$SBF/.claude-aka"
legacy_profile "$SBF"; apply_again "$SBF"
PATH="$IPATH" SHELL=/bin/bash HOME="$SBF" CT_ALIAS="aka-claude" \
  bash "$INSTALL" --delete-alias >"$SBF/del.log" 2>&1
assert_eq   "F: --delete-alias aka-claude exits 0" "0" "$?"
assert_nlit "F: aka-claude block removed" ">>> aka-claude-tools managed: aka-claude >>>" "$RCF"
[ -e "$CFGF/bin/aka-claude" ] && fail "F: forwarder shim removed" "present" || pass "F: forwarder shim removed"
assert_lit  "F: claude-aka block kept" ">>> aka-claude-tools managed: claude-aka >>>" "$RCF"
assert_file "F: claude-aka shim kept" "$CFGF/bin/claude-aka"
assert_eq   "F: meta deprecated_alias cleared" "" "$(meta "$CFGF" deprecated_alias)"

# ── G. --delete-alias claude-aka removes both ─────────────────────────────────
PATH="$IPATH" SHELL=/bin/bash HOME="$SB" CT_CONFIG_DIR="$CFG" CT_ALIAS="claude-aka" \
  bash "$INSTALL" --delete-alias >"$SB/del.log" 2>&1
assert_eq   "G: --delete-alias claude-aka exits 0" "0" "$?"
assert_ngrep "G: no managed block left" "aka-claude-tools managed" "$RC"
[ -e "$CFG/bin/aka-claude" ] && fail "G: forwarder shim removed" "present" || pass "G: forwarder shim removed"
[ -e "$CFG/bin/claude-aka" ] && fail "G: claude-aka shim removed" "present" || pass "G: claude-aka shim removed"
[ -e "$CFG/bin" ] && fail "G: empty bin/ pruned" "present" || pass "G: empty bin/ pruned"
assert_eq   "G: meta deprecated_alias cleared" "" "$(meta "$CFG" deprecated_alias)"

# Without CT_CONFIG_DIR the profile is resolved from the block itself.
SBG="$(sandbox)"; RCG="$SBG/.bashrc"; CFGG="$SBG/.claude-aka"
legacy_profile "$SBG"; apply_again "$SBG"
PATH="$IPATH" SHELL=/bin/bash HOME="$SBG" CT_ALIAS="claude-aka" \
  bash "$INSTALL" --delete-alias >"$SBG/del.log" 2>&1
assert_eq    "G: --delete-alias claude-aka (no CT_CONFIG_DIR) exits 0" "0" "$?"
assert_ngrep "G: no managed block left (no CT_CONFIG_DIR)" "aka-claude-tools managed" "$RCG"
[ -e "$CFGG/bin" ] && fail "G: bin/ pruned (no CT_CONFIG_DIR)" "present" || pass "G: bin/ pruned (no CT_CONFIG_DIR)"

# ── H. uninstall.sh removes both blocks ───────────────────────────────────────
SBH="$(sandbox)"; RCH="$SBH/.bashrc"; CFGH="$SBH/.claude-aka"
legacy_profile "$SBH"; apply_again "$SBH"
printf '# user line\nalias ll=ls\n' >> "$RCH"
PATH="$IPATH" SHELL=/bin/bash HOME="$SBH" bash "$UNINSTALL" "$CFGH" --yes >"$SBH/un.log" 2>&1
assert_eq   "H: uninstall exits 0" "0" "$?"
assert_nlit "H: no aka-claude block" ">>> aka-claude-tools managed: aka-claude >>>" "$RCH"
assert_nlit "H: no claude-aka block" ">>> aka-claude-tools managed: claude-aka >>>" "$RCH"
assert_nlit "H: no forwarder alias line" "alias aka-claude=" "$RCH"
assert_lit  "H: the user's own line survives" "alias ll=ls" "$RCH"
[ -e "$CFGH" ] && fail "H: profile dir removed" "present" || pass "H: profile dir removed"

# ── I. a user-owned aka-claude is never overwritten ───────────────────────────
SBI="$(sandbox)"; RCI="$SBI/.bashrc"; CFGI="$SBI/.claude-aka"
legacy_profile "$SBI"
printf '#!/bin/sh\necho my own tool\n' > "$CFGI/bin/aka-claude"   # no marker
cp "$RCI" "$SBI/rc.before"
apply_again "$SBI"
assert_eq   "I: --apply exits 0" "0" "$?"
assert_lit  "I: user file untouched" "my own tool" "$CFGI/bin/aka-claude"
assert_nlit "I: user file not turned into a forwarder" "$SHIM_MARKER" "$CFGI/bin/aka-claude"
assert_grep "I: the skip is reported" "not a kit launcher shim" "$SBI/apply.log"
assert_file "I: claude-aka shim still written" "$CFGI/bin/claude-aka"
assert_lit  "I: claude-aka block still written" ">>> aka-claude-tools managed: claude-aka >>>" "$RCI"
assert_nlit "I: aka-claude block not rewritten as a forwarder" "$DEPMSG" "$RCI"
assert_eq   "I: no deprecated_alias recorded" "" "$(meta "$CFGI" deprecated_alias)"

# ── J. the --defaults (interactive-path) re-run migrates too ──────────────────
SBJ="$(sandbox)"; RCJ="$SBJ/.bashrc"; CFGJ="$SBJ/.claude-aka"
legacy_profile "$SBJ"
PATH="$IPATH" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SBJ" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SBJ/log" 2>&1
assert_eq  "J: --defaults re-run exits 0" "0" "$?"
assert_eq  "J: meta alias is claude-aka" "claude-aka" "$(meta "$CFGJ" alias)"
assert_eq  "J: meta deprecated_alias is aka-claude" "aka-claude" "$(meta "$CFGJ" deprecated_alias)"
assert_lit "J: forwarder alias line written" "$DEPMSG" "$RCJ"
assert_lit "J: forwarder shim written" "$DEPMSG" "$CFGJ/bin/aka-claude"
# A re-run rewrites the claude-aka block (write_managed_block moves a rewritten
# block to the end of the rc), so compare content, not byte order.
sort "$RCJ" > "$SBJ/rc.before"; cp "$CFGJ/bin/aka-claude" "$SBJ/fwd.before"
PATH="$IPATH" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SBJ" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SBJ/log2" 2>&1
assert_eq  "J: second --defaults re-run exits 0" "0" "$?"
assert_ok  "J: a second --defaults re-run leaves the rc content unchanged" \
  bash -c "sort '$RCJ' | cmp -s - '$SBJ/rc.before'"
assert_ok  "J: forwarder shim unchanged" cmp -s "$SBJ/fwd.before" "$CFGJ/bin/aka-claude"
assert_eq  "J: still exactly two managed blocks" "2" "$(grep -c '>>> aka-claude-tools managed' "$RCJ")"
assert_ngrep "J: no migration on the second run" "aka-claude is deprecated" "$SBJ/log2"

# ── K. other derivations unchanged ────────────────────────────────────────────
SBK="$(sandbox)"; RCK="$SBK/.bashrc"; touch "$RCK"
PATH="$IPATH" CT_CONFIG_DIR="$SBK/.claude-work" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SBK" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SBK/log" 2>&1
assert_eq  "K: --defaults into ~/.claude-work exits 0" "0" "$?"
assert_lit "K: ~/.claude-work still defaults to 'work'" ">>> aka-claude-tools managed: work >>>" "$RCK"

t_summary
