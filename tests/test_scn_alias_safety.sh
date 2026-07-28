#!/usr/bin/env bash
# Scenario — setup_alias refuses to write an injectable alias name / config dir.
#
# install.sh is the SOLE sanctioned shell-rc writer. The block it writes is
#   alias NAME='CLAUDE_CONFIG_DIR="DIR" claude'
# An unsanitized NAME (unquoted before '=') or DIR (inside "…" inside '…') can break out
# of that quoting and inject code at rc-source or alias-expansion time. setup_alias now
# fails closed on such values rather than escaping.
#
# Invariants:
#   A. A config dir with a single quote is REJECTED (non-zero) and writes NOTHING to the rc.
#   B. A config dir with a double quote is REJECTED.
#   C. An alias name with a shell metacharacter is REJECTED.
#   D. A normal name + a dir CONTAINING A SPACE is still ACCEPTED (no over-rejection),
#      and the alias is written + resolves back to that dir.
#
# Fully sandboxed: fake $HOME, --no-auth-inherit, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_alias_safety:"

INSTALL="$REPO_ROOT/install.sh"
COMMON="$REPO_ROOT/shared/lib/common.sh"

# run_alias <subpath-under-sandbox> <alias_name> [precreate] — fresh sandbox, fake HOME,
# config dir = "$SB/<subpath>" (built INSIDE here so NO call site references the real
# $HOME — the dir's unsafe chars live in <subpath>). precreate=1 mkdirs the dir first
# (for accept cases). Sets SB/RC/CDIR/RC_RC for the asserting caller.
run_alias() {
  SB="$(sandbox)"; export HOME="$SB"; RC="$SB/.bashrc"; touch "$RC"
  CDIR="$SB/$1"
  [ "${3:-0}" = "1" ] && mkdir -p "$CDIR"
  # Hermetic PATH: the installer refuses a launcher name that is already a PATH
  # command (e.g. a real ai-tc `aka` on the operator's machine).
  PATH="$(install_path)" SHELL=/bin/bash CT_CONFIG_DIR="$CDIR" CT_ALIAS="$2" \
    bash "$INSTALL" --alias --no-auth-inherit >"$SB/log" 2>&1
  RC_RC=$?
}

# expect_reject <desc> <config_dir> <alias_name> [msg-substr] — run --alias and assert it
# is REFUSED: non-zero exit AND the rc left byte-for-byte unchanged (empty), not merely
# "no alias line". Optionally assert the refusal message.
expect_reject() {
  run_alias "$2" "$3"
  local nz=0; [ "$RC_RC" -ne 0 ] && nz=1
  assert_eq "$1: install exits non-zero"      "1" "$nz"
  assert_eq "$1: rc left unchanged (0 bytes)" "0" "$(wc -c <"$RC" | tr -d ' ')"
  [ -n "${4:-}" ] && assert_grep "$1: explains the refusal" "$4" "$SB/log"
  return 0
}

# ── A–C. rc-source-time breakouts (subpaths are single-quoted so the test shell ──
# never expands them; run_alias roots each under its own sandbox). ────────────
expect_reject "single-quote dir"    "x'/.claude-aka"   "aka" "unsafe config dir"
expect_reject "double-quote dir"    'a"b/.claude-aka'  "aka" "unsafe config dir"
expect_reject "metachar name"       ".claude-aka"      "a;rm -rf ~" "unsafe alias name"
expect_reject "leading-hyphen name" ".claude-aka"      "-rf"

# ── A2. alias-EXPANSION-time injection: $(), backtick, ${}, trailing \ ────────
# These carry no quote, so quote-only rejection would let them through — they execute
# when the alias is invoked (the "DIR" is reparsed inside live double quotes).
expect_reject "command-sub dir \$()"   '$(touch PWNED)/.claude-aka' "aka" "unsafe config dir"
expect_reject "backtick dir"           '`touch PWNED`/.claude-aka'  "aka" "unsafe config dir"
expect_reject "param-expansion dir"    '${HOME}/.claude-aka'        "aka" "unsafe config dir"
expect_reject "trailing-backslash dir" 'x\/.claude-aka'             "aka" "unsafe config dir"

# ── D. a normal name + a dir WITH A SPACE is still accepted ──────────────────
run_alias "my profile/.claude-aka" "aka" 1
assert_eq   "spaced dir: install exits 0" "0" "$RC_RC"
assert_lit  "spaced dir: alias written"   "alias aka=" "$RC"
LINE="$(grep -E "^[[:space:]]*alias aka=" "$RC")"
RESOLVED="$(source "$COMMON"; _alias_resolve_target "$LINE")"
assert_eq   "spaced dir: alias resolves back to the spaced dir" "$CDIR" "$RESOLVED"

# ── E. unit-level: the shared guards (common.sh) accept/reject directly ──────
# setup_alias's collision branch re-gates the prompted newalias through the SAME
# assert_safe_alias_name, so proving the helper here covers that path too.
chk() { ( source "$COMMON"; "$1" "$2" ) >/dev/null 2>&1; }   # subshell: die→exit 1
chk assert_safe_alias_name "aka"        && pass "guard accepts a normal name 'aka'"            || fail "guard accepts 'aka'"
chk assert_safe_alias_name "2fa"        && pass "guard accepts a digit-leading name '2fa'"     || fail "guard accepts '2fa'"
chk assert_safe_alias_name "a;b"        && fail "guard rejects 'a;b'"                           || pass "guard rejects metachar name 'a;b'"
chk assert_safe_alias_name '$(x)'       && fail "guard rejects '\$(x)'"                         || pass "guard rejects command-sub name '\$(x)'"
chk assert_safe_alias_name "-r"         && fail "guard rejects leading-hyphen '-r'"             || pass "guard rejects leading-hyphen name '-r'"
chk assert_safe_alias_name "a-b"        && pass "guard accepts a hyphenated name 'a-b'"          || fail "guard accepts 'a-b'"
# '.' is rejected: it is an ERE metachar and the collision/enumerate greps interpolate the
# name unescaped, so an accepted dotted name (e.g. a.b) would over-match a sibling 'axb'.
chk assert_safe_alias_name "a.b"        && fail "guard rejects dotted name 'a.b'"                || pass "guard rejects dotted (ERE-wildcard) name 'a.b'"
chk assert_safe_config_dir "/a/b c"     && pass "guard accepts a dir with a space"             || fail "guard accepts spaced dir"
chk assert_safe_config_dir "/Users/joão/.claude-aka" && pass "guard accepts a non-ASCII (UTF-8) dir" || fail "guard accepts UTF-8 dir"
chk assert_safe_config_dir "/a/b'c"     && fail "guard rejects single-quote dir"               || pass "guard rejects single-quote dir"
chk assert_safe_config_dir '/a/b"c'     && fail "guard rejects double-quote dir"               || pass "guard rejects double-quote dir"
chk assert_safe_config_dir '/a/$(id)'   && fail "guard rejects command-sub dir"                 || pass "guard rejects command-sub dir '\$(id)'"
chk assert_safe_config_dir '/a/`id`'    && fail "guard rejects backtick dir"                    || pass "guard rejects backtick dir"
chk assert_safe_config_dir '/a/${HOME}' && fail "guard rejects param-expansion dir"             || pass "guard rejects param-expansion dir '\${HOME}'"
chk assert_safe_config_dir '/a/b\'      && fail "guard rejects trailing-backslash dir"          || pass "guard rejects trailing-backslash dir"
NLDIR="$(printf '/a/b\nc')"
chk assert_safe_config_dir "$NLDIR"     && fail "guard rejects a newline (line-splitting) dir"  || pass "guard rejects a newline dir"

t_summary
