#!/usr/bin/env bash
# Scenario path_normalize (cross-vendor finding): the prompted config dir was used
# verbatim (only ~ expanded), so:
#   4a) a TRAILING SLASH on ~/.claude made the exact-string default-dir test fail —
#       ~/.claude/ was mis-handled as a non-default profile (alias written; backup
#       path computed as a CHILD of the dir being moved).
#   4b) a RELATIVE path was baked verbatim into the alias + hook commands, so the
#       profile only resolved from the cwd the installer ran in.
# Fix: normalize once (strip trailing slash, make absolute). Driven through a pty
# with expect (the dir is read from /dev/tty; --defaults can't select a custom dir).
# Skips loudly if expect is absent. Fully sandboxed.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_path_normalize:"

if ! command -v expect >/dev/null 2>&1; then
  printf '  \033[33m! expect not found — cannot drive the interactive config-dir prompt; scenario not exercised\033[0m\n'
  t_summary; exit $?
fi

# ── 4a: trailing slash on the DEFAULT dir must still be detected as default ─────
SBA="$(sandbox)"; RCA="$SBA/.bashrc"; touch "$RCA"
EXPA="$SBA/a.exp"
cat > "$EXPA" <<EXPECT
set timeout 90
set env(HOME) "$SBA"
set env(SHELL) "/bin/bash"
set env(CT_ADDITIONS) "secure-settings"
spawn bash "$REPO_ROOT/install.sh" --no-auth-inherit
expect {
  -re {Config folder to create/update} { send "$SBA/.claude/\r"; exp_continue }
  -re {Modify your default}             { send "y\r"; exp_continue }
  -re {Back up.*rebuild it clean}       { send "y\r"; exp_continue }
  -re {Migrate items from an existing}  { send "n\r"; exp_continue }
  -re {Shell alias to launch it}        { send "\r";  exp_continue }
  -re {Set up another config folder}    { send "n\r"; exp_continue }
  -re {Show how to add ai-tc}           { send "n\r"; exp_continue }
  eof {}
}
catch wait result
exit [lindex \$result 3]
EXPECT
expect -f "$EXPA" > "$SBA/log" 2>&1
assert_eq   "4a: install over ~/.claude/ (trailing slash) exits 0" "0" "$?"
assert_file "4a: default profile created at the canonical path" "$SBA/.claude/settings.json"
assert_nlit "4a: NO managed alias block for the default dir (slash still detected as default)" \
  "aka-claude-tools managed" "$RCA"

# ── 4b: a RELATIVE target must be persisted as an ABSOLUTE path ─────────────────
SBB="$(sandbox)"; RCB="$SBB/.bashrc"; touch "$RCB"
EXPB="$SBB/b.exp"
cat > "$EXPB" <<EXPECT
set timeout 90
set env(HOME) "$SBB"
set env(SHELL) "/bin/bash"
set env(CT_ADDITIONS) "secure-settings"
spawn bash -c "cd '$SBB' && bash '$REPO_ROOT/install.sh' --no-auth-inherit"
expect {
  -re {Config folder to create/update} { send "relprof\r"; exp_continue }
  -re {Back up.*rebuild it clean}       { send "y\r"; exp_continue }
  -re {Migrate items from an existing}  { send "n\r"; exp_continue }
  -re {Shell alias to launch it}        { send "\r";  exp_continue }
  -re {already an alias}                { send "\r";  exp_continue }
  -re {Set up another config folder}    { send "n\r"; exp_continue }
  -re {Show how to add ai-tc}           { send "n\r"; exp_continue }
  eof {}
}
catch wait result
exit [lindex \$result 3]
EXPECT
expect -f "$EXPB" > "$SBB/log" 2>&1
assert_eq   "4b: install with a relative target exits 0" "0" "$?"
assert_file "4b: relative target created as an absolute dir" "$SBB/relprof/settings.json"
# Match the invariant (absolute path ending in /relprof), not the exact $SBB prefix —
# macOS resolves the sandbox path ($TMPDIR, /var -> /private/var), so the installer's
# $PWD can differ textually from $SBB while still being correctly absolute.
assert_grep "4b: alias binds to an ABSOLUTE config dir ending in /relprof" \
  'CLAUDE_CONFIG_DIR="/[^"]*/relprof"' "$RCB"
assert_nlit "4b: alias does NOT embed the bare relative path" \
  "CLAUDE_CONFIG_DIR=\"relprof\"" "$RCB"

t_summary
