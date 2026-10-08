#!/usr/bin/env bash
# Scenario — command-guard blocks BSD pkill/pgrep with options after the pattern.
#
# BSD/macOS pkill and pgrep stop option parsing at the first pattern, so
# `pkill -f foo -u 501 --` treats `-u`, `501` and `--` as extra patterns (OR'd). Nearly every
# process command line contains `--`, so that kills almost everything the user owns. GNU
# pkill permutes options and rejects a second pattern, so the check runs on macOS only.
#
# Needs bun (command-guard's runtime; the suite already requires it).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_command_guard_pkill:"

CG="$REPO_ROOT/config/hooks/command-guard.ts"
SB="$(sandbox)"
if ! command -v bun >/dev/null 2>&1; then echo "  (skip — bun not present)"; t_summary; exit $?; fi

# chk <expected-exit> <desc> <command>
chk() {
  jq -nc --arg c "$3" '{tool_name:"Bash",tool_input:{command:$c}}' > "$SB/in.json"
  bun "$CG" < "$SB/in.json" >/dev/null 2>&1
  assert_eq "$2" "$1" "$?"
}

if [ "$(uname -s)" = Darwin ]; then
  # ── BLOCK (exit 2): an option or a second word after the first pattern ──────
  chk 2 "block: options after the pattern, then --"   "pkill -f 'tools/app/server.ts' -u \$(id -u) -- 2>/dev/null"
  chk 2 "block: -u after the pattern"                  'pkill -f foo -u 501'
  chk 2 "block: pgrep with a trailing --"              "pgrep -lf 'x' --"
  chk 2 "block: after cd && sudo, quoted pattern"      'cd /x && sudo pkill -f "a b" -9; echo'
  chk 2 "block: absolute path, two patterns"           '/usr/bin/pkill -f foo bar'
  chk 2 "block: env assignment + wrapper, trailing -n" 'X=1 rtk pkill -f foo -n'
  chk 2 "block: -- then pattern then another word"     'pkill -- foo --bar'
  chk 2 "block: sudo -u <user> still inspects pkill"   'sudo -u root pkill -f foo -9'
  chk 2 "block: second segment after a pipe"           'echo hi | pkill -f foo -u 501'
  # ── ALLOW (exit 0) ────────────────────────────────────────────────────────
  chk 0 "allow: options first, redirect after"         'pkill -u $(id -u) -f '"'p'"' 2>/dev/null'
  chk 0 "allow: redirect and || true"                  'pkill -f p 2>/dev/null || true'
  chk 0 "allow: pgrep with an alternation, > file"     'pgrep -lf "a|b" > /tmp/x'
  chk 0 "allow: signal option first"                   'pkill -9 -f foo'
  chk 0 "allow: -HUP is a signal, not a -P value"      'pkill -HUP -f foo'
  chk 0 "allow: -- ends options, dash pattern"         'pkill -u 501 -- -weird'
  chk 0 "allow: 2> /dev/null with a space"             'pgrep -f foo 2> /dev/null'
  chk 0 "allow: pgrep piped to xargs"                  'pgrep -f foo | xargs ps'
  chk 0 "allow: quoted ssh argument is not inspected"  "ssh h 'pkill -f foo -u 501'"
  chk 0 "allow: pkill only as an echo argument"        'echo pkill -f foo bar'
  chk 0 "allow: bare pkill"                            'pkill'
  chk 0 "allow: pgrep only in a quoted heredoc body"   $'cat > /tmp/n <<\'EOF\'\nHost clear (pgrep gate empty) --\nEOF'
  chk 2 "block: real pkill after a heredoc ends"       $'cat <<EOF\nx\nEOF\npkill -f foo -u 501'
  chk 2 "block: pkill on the heredoc command line"     $'pkill -f foo -u 501 <<EOF\nx\nEOF'
else
  chk 0 "allow on non-macOS: GNU pkill permutes options" 'pkill -f foo -u 501'
fi

t_summary
