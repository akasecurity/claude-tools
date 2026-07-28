#!/usr/bin/env bash
# Scenario T14 (scn_install_interactive): INSTALL/edge — the GENUINE interactive
# menu path, driven over a real PTY so the installer's prompt/confirm reads from
# /dev/tty are actually exercised (CT_ADDITIONS / --defaults bypass this path, so
# it was previously untested). This drives:
#   • per-addition accept/reject  (secure-settings=Y, wrap-up=Y, everything
#     else=N) — proving the menu HONORS the selection: the accepted artifacts
#     land, the rejected ones do not.
#   • the "Set up another config folder?" multi-profile LOOP — answered Y once to
#     create a SECOND, independently-named profile, then N to finish — proving the
#     loop builds a clean second profile (own dir, own alias, own settings).
#
# Mechanism: prompt()/confirm() in shared/lib/common.sh do `read -r … </dev/tty`,
# which resolves to the process's CONTROLLING terminal — not stdin — so answers
# cannot be piped in. `expect` spawns the installer with a PTY as its controlling
# terminal and scripts the answers, the closest faithful emulation of a human at
# the menu available in a sandbox. NOT --defaults / NOT CT_ADDITIONS on purpose:
# this is the one test that walks the interactive branch.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit. Never touches a
# real ~/.claude*. If `expect` is unavailable the interactive assertions are
# skipped (reported), so the file degrades gracefully off-host.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_interactive:"

if ! command -v expect >/dev/null 2>&1; then
  echo "  (expect not found — interactive PTY path cannot be emulated here; skipping)"
  # Don't silently green: record a skip as an explicit non-failure marker.
  pass "expect unavailable: interactive path skipped (limitation noted)"
  t_summary
  exit $?
fi

SB="$(sandbox)"
# Hermetic PATH for the spawned installer: an operator's real `aka-claude` PATH
# command must not trigger the installer's conflict-rename mid-PTY-script.
IPATH="$(install_path)"
RC="$SB/.bashrc"; touch "$RC"            # deterministic rc target for alias blocks
P1="$SB/.claude-aka"                     # first profile (accept the default folder)
P2="$SB/.claude-work"                    # second profile (typed in the loop)
LOG="$SB/install.log"
EXP="$SB/drive.exp"

# ── expect driver ─────────────────────────────────────────────────────────────
# Responds to each known prompt cue. Selection per addition:
#   secure-settings = y   (so settings.json gets the secure base — assertable)
#   wrap-up         = y   (a command artifact — assertable it lands)
#   ALL OTHERS      = n   (assertable they do NOT land — proves reject is honored)
# The second-profile pass reuses the same selection. exp_internal off keeps the
# log clean; a global timeout fails loudly rather than hanging the suite.
#
# The per-addition matchers are DERIVED from config/additions.json (the exact
# prompt the installer renders — .prompt // .name, matched via `expect -ex` so
# label metachars like ( | [ ? are literal) rather than hardcoded, so this test
# tracks the manifest across the public-release label rename (e.g. "RTK saver" →
# "rtk-safe", "Web guard" → "leak-guard"). Accept-by-id stays stable: secure-settings
# and wrap-up are y, everything else n.
ACCEPT_IDS=" secure-settings wrap-up "
ADDITION_MATCHERS=""
while IFS=$'\t' read -r _aid _alabel; do
  case "$ACCEPT_IDS" in *" $_aid "*) _ans=y ;; *) _ans=n ;; esac
  ADDITION_MATCHERS+="  -ex {$_alabel} { send \"$_ans\\r\"; exp_continue }"$'\n'
done < <(jq -r '.additions[] | [.id, (.prompt // .name)] | @tsv' "$ADDITIONS")

cat > "$EXP" <<EXPECT
set timeout 30
log_user 1
# Force a wide PTY so long addition prompts never soft-wrap — a wrapped line would
# split the literal label across a newline and defeat the -ex substring match.
set stty_init "rows 80 cols 1000"
# spawn the installer under a PTY; --no-auth-inherit, NO --defaults.
spawn env HOME=$SB SHELL=/bin/bash NO_COLOR=1 PATH=$IPATH bash $REPO_ROOT/install.sh --no-auth-inherit

# Track which profile pass we're in so the folder/alias answers differ.
set pass 1

expect {
  -re {Config folder to create/update:} {
    if {\$pass == 1} { send "\r" } else { send "$P2\r" }
    exp_continue
  }
  -re {Shell alias to launch it:} {
    if {\$pass == 1} { send "\r" } else { send "work\r" }
    exp_continue
  }
  -re {Migrate items from an existing Claude config} { send "n\r"; exp_continue }
$ADDITION_MATCHERS
  -re {Set up another config folder} {
    if {\$pass == 1} { set pass 2; send "y\r" } else { send "n\r" }
    exp_continue
  }
  -re {Show how to add ai-tc}           { send "y\r"; exp_continue }
  -re {Pin a location}                  { send "\r"; exp_continue }
  timeout { puts "EXPECT_TIMEOUT"; exit 2 }
  eof
}
catch wait result
exit [lindex \$result 3]
EXPECT

expect -f "$EXP" >"$LOG" 2>&1
rc=$?

# ── overall result ────────────────────────────────────────────────────────────
assert_eq   "interactive install exits 0" "0" "$rc"
assert_ngrep "no expect timeout (menu never hung)" "EXPECT_TIMEOUT" "$LOG"
assert_grep "install reported done" 'Done|ready' "$LOG"
# ai-tc offer fires (no ai-tc in the sandbox HOME) and, on accept, prints the
# marketplace install command — the security-depth handoff to the detection engine.
assert_grep "ai-tc offer shown" 'Show how to add ai-tc' "$LOG"
assert_grep "ai-tc install command printed on accept" 'plugin install ai-tc@akasecurity' "$LOG"

# ── profile 1: selection honored ──────────────────────────────────────────────
assert_file "profile 1 dir created" "$P1"
assert_ok   "profile 1 settings.json valid JSON" jq -e . "$P1/settings.json"
# ACCEPTED wrap-up → its command artifact lands.
assert_file "p1 accepted addition deployed: wrap-up command" "$P1/commands/wrap-up.md"
# ACCEPTED secure-settings → the secure deny base merged in (non-empty deny array).
assert_ok   "p1 secure-settings honored: deny array non-empty" \
  bash -c "jq -e '((.permissions.deny // []) | length) > 0' '$P1/settings.json' >/dev/null"
# REJECTED additions → their artifacts must be ABSENT (reject is honored).
[ -e "$P1/hooks/leak-guard.ts" ] && fail "p1 rejected leak-guard not deployed" "leak-guard.ts present" \
                               || pass "p1 rejected leak-guard not deployed"
[ -e "$P1/hooks/statusline.ts" ] && fail "p1 rejected statusline not deployed" "statusline.ts present" \
                                || pass "p1 rejected statusline not deployed"
[ -e "$P1/skills/shell-audit" ] && fail "p1 rejected shell-audit not deployed" "shell-audit present" \
                               || pass "p1 rejected shell-audit not deployed"
# No statusLine registration should have been written (statusline rejected).
assert_ok   "p1 no statusLine in settings (rejected)" \
  bash -c "jq -e '(.statusLine // null) == null' '$P1/settings.json' >/dev/null"

# ── the multi-profile loop created a clean SECOND profile ─────────────────────
assert_file "loop created profile 2 dir" "$P2"
assert_ok   "profile 2 settings.json valid JSON" jq -e . "$P2/settings.json"
assert_file "p2 selection honored: wrap-up command" "$P2/commands/wrap-up.md"
[ -e "$P2/hooks/leak-guard.ts" ] && fail "p2 rejected leak-guard not deployed" "leak-guard.ts present" \
                               || pass "p2 rejected leak-guard not deployed"
# The two profiles are INDEPENDENT directories, not the same dir reused.
assert_ok   "profiles 1 and 2 are distinct dirs" bash -c "[ '$P1' != '$P2' ] && [ -d '$P1' ] && [ -d '$P2' ]"

# ── aliases: one managed block per profile, each pointing at its own dir ───────
assert_lit  "rc has alias block for profile 1 (aka-claude — the derived default)" \
  ">>> aka-claude-tools managed: aka-claude" "$RC"
assert_lit  "rc has alias block for profile 2 (work)" \
  ">>> aka-claude-tools managed: work" "$RC"
assert_lit  "p1 alias points at profile 1 dir" "CLAUDE_CONFIG_DIR=\"$P1\"" "$RC"
assert_lit  "p2 alias points at profile 2 dir" "CLAUDE_CONFIG_DIR=\"$P2\"" "$RC"
n_block=$(grep -c '>>> aka-claude-tools managed' "$RC")
assert_eq   "exactly two managed alias blocks (one per profile)" "2" "$n_block"

# ── no maintainer-only \$comment leak in either profile's settings ────────────
for pf in "$P1" "$P2"; do
  assert_ok "no \$comment keys leaked: $(basename "$pf")" \
    bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$pf/settings.json' >/dev/null"
done

t_summary
