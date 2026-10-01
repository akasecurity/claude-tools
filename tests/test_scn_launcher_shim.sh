#!/usr/bin/env bash
# Scenario — the PATH-visible launcher: shim + guarded PATH line + conflict gate.
#
# The launcher is now BOTH a shell alias and an executable shim at
# <config_dir>/bin/<name>, with the managed rc block gaining a guarded PATH
# export — so scripts, non-interactive shells, and ai-tc's git-style dispatcher
# (`aka claude` → execs `aka-claude` from PATH) can launch the profile.
#
# Invariants:
#   A. --alias writes the shim (exists, executable, embeds the config dir) and a
#      SINGLE managed block containing BOTH the alias line and the PATH case-guard
#      (with $PATH literal — proving write_managed_block handles multi-line content).
#   B. The shim actually launches: with a stub `claude` on PATH it execs claude
#      with CLAUDE_CONFIG_DIR set to the profile and forwards its arguments.
#   C. Re-run idempotency — still exactly one block / one alias line / one PATH
#      line; the shim survives intact and is repaired if deleted.
#   D. PATH-conflict, strict: a command named `aka` on PATH makes --alias
#      CT_ALIAS=aka exit non-zero, rc untouched, no shim written.
#   E. No false self-conflict: a re-run with the profile's OWN bin dir on PATH
#      (the shim resolves) still succeeds.
#   F. --delete-alias removes the block AND the shim — but NEVER a user file of
#      the same name that lacks the shim marker.
#   G. Default-name derivation: a full --defaults install into ~/.claude-aka
#      claims `aka-claude`, NOT bare `aka` (reserved for the ai-tc CLI).
#   H. A second launcher name lands its own shim and leaves the first one's shim
#      intact — the first name's rc block survives a rename, so its shim must too.
#   I. A profile path containing ':' gets the alias and the shim but NO PATH entry
#      (a colon would split into a relative PATH entry), and the skip is reported.
#
# Fully sandboxed: fake $HOME, fake rc, hermetic PATH (install_path — so a real
# `aka`/`aka-claude` on the operator's machine can't flake the suite). SHELL is
# pinned to /bin/bash so detect_shell_rc resolves to .bashrc on every host.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_launcher_shim:"

INSTALL="$REPO_ROOT/install.sh"
IPATH="$(install_path)"
SHIM_MARKER='aka-claude-tools launcher shim'

# ── A. --alias writes shim + two-line managed block ───────────────────────────
SB="$(sandbox)"; export HOME="$SB"; RC="$SB/.bashrc"; touch "$RC"
CFG="$SB/.claude-aka"
PATH="$IPATH" CT_CONFIG_DIR="$CFG" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --alias --no-auth-inherit >"$SB/log" 2>&1
assert_eq   "A: --alias exits 0" "0" "$?"
SHIM="$CFG/bin/aka-claude"
assert_file "A: shim exists" "$SHIM"
assert_ok   "A: shim is executable" test -x "$SHIM"
assert_lit  "A: shim embeds the config dir" "CLAUDE_CONFIG_DIR=\"$CFG\"" "$SHIM"
assert_lit  "A: shim carries the kit marker" "$SHIM_MARKER" "$SHIM"
assert_lit  "A: shim execs claude with forwarded args" 'exec claude "$@"' "$SHIM"
assert_eq   "A: exactly one managed block" "1" "$(grep -c '>>> aka-claude-tools managed' "$RC")"
assert_lit  "A: block contains the alias line" \
  "alias aka-claude='CLAUDE_CONFIG_DIR=\"$CFG\" claude'" "$RC"
assert_lit  "A: block contains the guarded PATH line" \
  "case \":\$PATH:\" in *\":$CFG/bin:\"*) ;; *) export PATH=\"$CFG/bin:\$PATH\" ;; esac" "$RC"
# $PATH must reach the rc UNEXPANDED (a literal \$PATH, not this shell's value).
assert_lit  "A: PATH reaches the rc literally (unexpanded)" 'bin:$PATH" ;; esac' "$RC"
# Both lines are INSIDE the one block: alias line first after the begin marker.
assert_ok   "A: alias + PATH lines live inside the block" \
  bash -c "grep -A2 '>>> aka-claude-tools managed: aka-claude >>>' '$RC' | grep -q 'alias aka-claude=' && grep -A2 '>>> aka-claude-tools managed: aka-claude >>>' '$RC' | grep -q 'case \":\$PATH:\"'"

# ── B. the shim launches: stub claude proves env + arg forwarding ─────────────
STUB="$SB/stubbin"; mkdir -p "$STUB"
cat > "$STUB/claude" <<'C'
#!/bin/sh
echo "CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR args=$*"
C
chmod +x "$STUB/claude"
OUT="$(PATH="$STUB:/usr/bin:/bin" "$SHIM" --resume x 2>&1)"
assert_eq "B: shim launches claude with the profile dir and forwarded args" \
  "CLAUDE_CONFIG_DIR=$CFG args=--resume x" "$OUT"

# ── C. re-run idempotency: one block, shim intact / repaired ──────────────────
PATH="$IPATH" CT_CONFIG_DIR="$CFG" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --alias --no-auth-inherit >"$SB/log2" 2>&1
assert_eq "C: re-run exits 0" "0" "$?"
assert_eq "C: still exactly one managed block"  "1" "$(grep -c '>>> aka-claude-tools managed' "$RC")"
assert_eq "C: exactly one alias line"           "1" "$(grep -cE '^alias aka-claude=' "$RC")"
assert_eq "C: exactly one PATH case-guard line" "1" "$(grep -cF 'case ":$PATH:"' "$RC")"
assert_ok "C: shim still executable after re-run" test -x "$SHIM"
# A deleted shim is REPAIRED by a re-run.
rm -f "$SHIM"
PATH="$IPATH" CT_CONFIG_DIR="$CFG" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --alias --no-auth-inherit >"$SB/log3" 2>&1
assert_file "C: deleted shim repaired by re-run" "$SHIM"

# ── D. PATH conflict, strict: a real `aka` command on PATH blocks --alias ─────
SBD="$(sandbox)"; export HOME="$SBD"; RCD="$SBD/.bashrc"; touch "$RCD"
CFGD="$SBD/.claude-aka"
AKABIN="$SBD/akabin"; mkdir -p "$AKABIN"
printf '#!/bin/sh\necho ai-tc\n' > "$AKABIN/aka"; chmod +x "$AKABIN/aka"
PATH="$AKABIN:$IPATH" CT_CONFIG_DIR="$CFGD" CT_ALIAS="aka" SHELL=/bin/bash HOME="$SBD" \
  bash "$INSTALL" --alias --no-auth-inherit >"$SBD/log" 2>&1
D_RC=$?
assert_ok   "D: --alias exits non-zero on a PATH conflict" bash -c "[ '$D_RC' -ne 0 ]"
assert_eq   "D: rc untouched (0 bytes)" "0" "$(wc -c < "$RCD" | tr -d ' ')"
[ -e "$CFGD/bin/aka" ] && fail "D: no shim written on refusal" "shim exists" \
                       || pass "D: no shim written on refusal"
assert_grep "D: names the conflicting command" "already a command on your PATH" "$SBD/log"
assert_grep "D: points at the ai-tc CLI + aka-claude dispatch" "AI Traffic Control" "$SBD/log"

# ── E. no false self-conflict: the profile's own shim on PATH is fine ─────────
PATH="$CFG/bin:$IPATH" CT_CONFIG_DIR="$CFG" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --alias --no-auth-inherit >"$SB/log4" 2>&1
assert_eq "E: re-run with own shim on PATH exits 0" "0" "$?"
assert_eq "E: still exactly one managed block" "1" "$(grep -c '>>> aka-claude-tools managed' "$RC")"
assert_file "E: shim still present" "$SHIM"

# ── F. --delete-alias removes block + shim, but never a non-shim user file ────
PATH="$IPATH" CT_CONFIG_DIR="$CFG" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >"$SB/dlog" 2>&1
assert_eq   "F: --delete-alias exits 0" "0" "$?"
assert_ngrep "F: managed block gone from rc" "aka-claude-tools managed" "$RC"
[ -e "$SHIM" ] && fail "F: shim removed with the alias" "still present" \
               || pass "F: shim removed with the alias"
[ -e "$CFG/bin" ] && fail "F: empty bin dir pruned" "still present" \
                  || pass "F: empty bin dir pruned"
# A USER file at <cfg>/bin/<name> WITHOUT the marker must survive deletion.
PATH="$IPATH" CT_CONFIG_DIR="$CFG" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --alias --no-auth-inherit >/dev/null 2>&1
printf '#!/bin/sh\necho my own tool\n' > "$SHIM"   # overwrite: no marker now
PATH="$IPATH" CT_CONFIG_DIR="$CFG" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >"$SB/dlog2" 2>&1
assert_eq  "F: delete over a user file still exits 0" "0" "$?"
assert_file "F: marker-less user file at the shim path SURVIVES" "$SHIM"
assert_lit  "F: user file content untouched" "my own tool" "$SHIM"

# ── G. default-name derivation: --defaults claims aka-claude, not aka ─────────
SBG="$(sandbox)"; export HOME="$SBG"; RCG="$SBG/.bashrc"; touch "$RCG"
CFGG="$SBG/.claude-aka"
PATH="$IPATH" CT_ADDITIONS="secure-settings wrap-up" SHELL=/bin/bash HOME="$SBG" \
  bash "$INSTALL" --defaults --no-auth-inherit >"$SBG/log" 2>&1
assert_eq  "G: --defaults install exits 0" "0" "$?"
assert_lit "G: managed block keyed on aka-claude" \
  ">>> aka-claude-tools managed: aka-claude >>>" "$RCG"
assert_ngrep "G: NO block keyed on bare aka" \
  ">>> aka-claude-tools managed: aka >>>" "$RCG"
assert_lit "G: aka-claude alias points at the profile" \
  "alias aka-claude='CLAUDE_CONFIG_DIR=\"$CFGG\" claude'" "$RCG"
assert_file "G: aka-claude shim placed" "$CFGG/bin/aka-claude"
assert_ok   "G: aka-claude shim executable" test -x "$CFGG/bin/aka-claude"

# ── H. a second launcher name leaves the first one intact ─────────────────────
# The old name's managed rc block survives a rename, so its shim must too —
# removing one without the other would leave that name half-working (alias fires,
# PATH lookup and `aka <name>` dispatch do not). Both go together, via
# --delete-alias or uninstall.
PATH="$IPATH" CT_CONFIG_DIR="$CFGG" CT_ALIAS="renamed" SHELL=/bin/bash HOME="$SBG" \
  bash "$INSTALL" --alias --no-auth-inherit >"$SBG/log2" 2>&1
assert_eq   "H: rename --alias exits 0" "0" "$?"
assert_file "H: new shim placed" "$CFGG/bin/renamed"
assert_file "H: prior shim kept (its rc block is still live)" "$CFGG/bin/aka-claude"
assert_lit  "H: prior alias block still present" \
  "alias aka-claude='CLAUDE_CONFIG_DIR=\"$CFGG\" claude'" "$RCG"
# A user's own (marker-less) file in bin/ is untouched.
printf 'user data\n' > "$CFGG/bin/keep-me"
PATH="$IPATH" CT_CONFIG_DIR="$CFGG" CT_ALIAS="renamed2" SHELL=/bin/bash HOME="$SBG" \
  bash "$INSTALL" --alias --no-auth-inherit >"$SBG/log3" 2>&1
assert_file "H: marker-less user file in bin/ survives" "$CFGG/bin/keep-me"

# ── I. a colon in the profile path never yields a PATH entry ──────────────────
# PATH is colon-delimited: embedding such a dir would split into two entries, one
# RELATIVE — a command-hijack foothold. The alias and shim are still written.
SBI="$(sandbox)"; export HOME="$SBI"; RCI="$SBI/.bashrc"; touch "$RCI"
CFGI="$SBI/.claude-a:b"
PATH="$IPATH" CT_CONFIG_DIR="$CFGI" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SBI" \
  bash "$INSTALL" --alias --no-auth-inherit >"$SBI/log" 2>&1
assert_eq    "I: colon-dir --alias exits 0" "0" "$?"
assert_lit   "I: alias line still written" \
  "alias aka-claude='CLAUDE_CONFIG_DIR=\"$CFGI\" claude'" "$RCI"
assert_file  "I: shim still written" "$CFGI/bin/aka-claude"
assert_ngrep "I: NO PATH export for a colon-bearing dir" "export PATH=" "$RCI"
assert_grep  "I: the skip is reported to the user" "contains ':'" "$SBI/log"
# Sourcing the rc must not introduce a relative PATH entry.
REL="$(bash -c "export PATH=/usr/bin:/bin; source '$RCI'; printf '%s' \"\$PATH\"" | tr ':' '\n' | grep -vc '^/' || true)"
assert_eq "I: no relative PATH entries after sourcing" "0" "$REL"

# ── J. a shim that can't be written leaves the shell rc untouched ─────────────
# The shim is written before the rc block precisely so this ordering holds: a
# half-configured launcher (alias present, nothing to launch) is worse than none.
SBJ="$(sandbox)"; export HOME="$SBJ"; RCJ="$SBJ/.bashrc"; touch "$RCJ"
CFGJ="$SBJ/.claude-aka"
mkdir -p "$CFGJ/bin"; : > "$CFGJ/bin/aka-claude"; chmod 000 "$CFGJ/bin"
PATH="$IPATH" CT_CONFIG_DIR="$CFGJ" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SBJ" \
  bash "$INSTALL" --alias --no-auth-inherit >"$SBJ/log" 2>&1
assert_ok    "J: unwritable bin/ makes --alias fail" test "$?" -ne 0
assert_eq    "J: shell rc left completely untouched" "0" "$(wc -c <"$RCJ" | tr -d ' ')"
assert_grep  "J: the failure names the shim and says the rc is untouched" \
  "shell rc was NOT modified" "$SBJ/log"
chmod 755 "$CFGJ/bin"

# ── K. --delete-alias reports an unreadable shim instead of silently skipping ──
SBK="$(sandbox)"; export HOME="$SBK"; RCK="$SBK/.bashrc"; touch "$RCK"
CFGK="$SBK/.claude-aka"
PATH="$IPATH" CT_CONFIG_DIR="$CFGK" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SBK" \
  bash "$INSTALL" --alias --no-auth-inherit >/dev/null 2>&1
chmod 000 "$CFGK/bin/aka-claude"
PATH="$IPATH" CT_CONFIG_DIR="$CFGK" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SBK" \
  bash "$INSTALL" --delete-alias >"$SBK/log" 2>&1
assert_grep  "K: unreadable shim is reported, not silently skipped" \
  "Couldn't read" "$SBK/log"
assert_file  "K: the unreadable file is left in place" "$CFGK/bin/aka-claude"
chmod 644 "$CFGK/bin/aka-claude"

t_summary
