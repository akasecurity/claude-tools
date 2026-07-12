#!/usr/bin/env bash
# Scenario — notify-osc suppresses the false "your turn" and speaks each terminal's dialect.
#
# notify-osc.sh emits a desktop-notification escape sequence on Stop/Notification, but
# must stay SILENT when a turn ends while a background task is still running (the false
# "your turn" this piece exists to kill), and must emit EXACTLY ONE OSC dialect chosen
# for the detected terminal (never several — Ghostty/WezTerm honor more than one code).
#
# Invariants:
#   A. Stop with a RUNNING background task → suppressed (no output, exit 0).
#   B. Stop with only a completed/failed task → still notifies.
#   C. Stop with empty / absent background_tasks → notifies (fail open).
#   D. Notification (idle/permission) fires regardless of background tasks.
#   E. Terminal → dialect: kitty=99, ghostty/wezterm=777, iTerm2(LC_TERMINAL)=9, unknown=9.
#   F. CLAUDE_NOTIFY_OSC overrides detection; =off emits nothing.
#   G. OSC 9 body never begins with a digit (Claude Code's allowlist reserves 9;4).
#   H. A ';' in a message can't inject extra OSC 777 fields (sanitizer).
#   I. additions.json wires the piece to hooks/notify-osc.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_notify_osc:"

H="$REPO_ROOT/config/hooks/notify-osc.sh"
SB="$(sandbox)"

# Run the hook with a CONTROLLED terminal env: strip every terminal-identifying var, then
# apply the per-call assignments. Event JSON on stdin via a file (no pipe-to-shell).
CLEARENV=(env -u TERM_PROGRAM -u TERM_PROGRAM_VERSION -u LC_TERMINAL -u KITTY_WINDOW_ID
          -u WEZTERM_PANE -u ITERM_SESSION_ID -u GHOSTTY_RESOURCES_DIR -u GHOSTTY_BIN_DIR
          -u CLAUDE_NOTIFY_OSC -u TERM)
run() {  # run "<VAR=val ...>" '<json>'  → stdout of the hook
  local envs="$1" json="$2"
  printf '%s' "$json" > "$SB/in.json"
  # shellcheck disable=SC2086
  "${CLEARENV[@]}" $envs bash "$H" < "$SB/in.json" 2>/dev/null
}
# Extract the numeric OSC code from a hook result (ESC ] <code> ; …).
code_of() { printf '%s' "$1" | jq -r '.terminalSequence // empty' | LC_ALL=C sed -E 's/^.\]([0-9]+);.*/\1/'; }

STOP_RUNNING="$(jq -nc '{hook_event_name:"Stop",cwd:"/x/proj",background_tasks:[{id:"a",type:"subagent",status:"running"}]}')"
STOP_DONE="$(jq -nc    '{hook_event_name:"Stop",cwd:"/x/proj",background_tasks:[{id:"a",type:"shell",status:"completed"}]}')"
STOP_EMPTY="$(jq -nc   '{hook_event_name:"Stop",cwd:"/x/proj",background_tasks:[]}')"
STOP_NOFIELD="$(jq -nc '{hook_event_name:"Stop",cwd:"/x/proj"}')"
NOTIF_IDLE="$(jq -nc   '{hook_event_name:"Notification",notification_type:"idle_prompt",cwd:"/x/proj"}')"
NOTIF_RUNNING="$(jq -nc '{hook_event_name:"Notification",notification_type:"idle_prompt",cwd:"/x/proj",background_tasks:[{status:"running"}]}')"

# A. suppressed while a task runs — force a dialect so a FIRE would have produced output.
assert_eq "Stop with a RUNNING task is suppressed (no output)" "" "$(run "CLAUDE_NOTIFY_OSC=777" "$STOP_RUNNING")"
run "CLAUDE_NOTIFY_OSC=777" "$STOP_RUNNING" >/dev/null; rc=$?
assert_eq "  …and exits 0" "0" "$rc"

# B/C. completed-only, empty, and absent all still notify.
[ -n "$(run "CLAUDE_NOTIFY_OSC=777" "$STOP_DONE")" ]    && pass "Stop with only a completed task still notifies" || fail "Stop with only a completed task still notifies" "was suppressed"
[ -n "$(run "CLAUDE_NOTIFY_OSC=777" "$STOP_EMPTY")" ]   && pass "Stop with empty background_tasks notifies"       || fail "Stop with empty background_tasks notifies" "was suppressed"
[ -n "$(run "CLAUDE_NOTIFY_OSC=777" "$STOP_NOFIELD")" ] && pass "Stop with NO field notifies (fail open)"          || fail "Stop with NO field notifies (fail open)" "was suppressed"

# D. Notification always fires (idle/permission need you regardless of background work).
[ -n "$(run "CLAUDE_NOTIFY_OSC=777" "$NOTIF_IDLE")" ]    && pass "Notification idle_prompt fires"                  || fail "Notification idle_prompt fires" "was suppressed"
[ -n "$(run "CLAUDE_NOTIFY_OSC=777" "$NOTIF_RUNNING")" ] && pass "Notification fires even with a running task"     || fail "Notification fires even with a running task" "was suppressed"

# E. Terminal → dialect (auto-detection).
assert_eq "kitty → OSC 99"                     "99"  "$(code_of "$(run "KITTY_WINDOW_ID=1 TERM=xterm-kitty" "$STOP_EMPTY")")"
assert_eq "ghostty → OSC 777"                  "777" "$(code_of "$(run "TERM_PROGRAM=ghostty TERM=xterm-256color" "$STOP_EMPTY")")"
assert_eq "wezterm → OSC 777"                  "777" "$(code_of "$(run "WEZTERM_PANE=0 TERM=xterm-256color" "$STOP_EMPTY")")"
assert_eq "iTerm2 via LC_TERMINAL (SSH-safe) → OSC 9" "9" "$(code_of "$(run "LC_TERMINAL=iTerm2 TERM=xterm-256color" "$STOP_EMPTY")")"
assert_eq "unknown terminal → OSC 9 fallback"  "9"   "$(code_of "$(run "TERM=dumb" "$STOP_EMPTY")")"

# F. Override precedence + off.
assert_eq "CLAUDE_NOTIFY_OSC=99 overrides a ghostty env" "99" "$(code_of "$(run "CLAUDE_NOTIFY_OSC=99 TERM_PROGRAM=ghostty" "$STOP_EMPTY")")"
assert_eq "CLAUDE_NOTIFY_OSC=off emits nothing" "" "$(run "CLAUDE_NOTIFY_OSC=off TERM_PROGRAM=ghostty" "$STOP_EMPTY")"

# G. OSC 9 body must not begin with a digit even when the project name does.
STOP_DIGIT="$(jq -nc '{hook_event_name:"Stop",cwd:"/x/3d-game"}')"
seq9="$(run "CLAUDE_NOTIFY_OSC=9" "$STOP_DIGIT" | jq -r '.terminalSequence // empty')"
first="$(LC_ALL=C printf '%s' "$seq9" | sed -E 's/^.\]9;(.).*/\1/')"
case "$first" in [0-9]) fail "OSC 9 body never begins with a digit (project 3d-game)" "began with '$first'";; *) pass "OSC 9 body never begins with a digit (project 3d-game)";; esac

# H. A ';' in a permission message can't add OSC 777 fields (sanitizer → ',').
NOTIF_INJ="$(jq -nc '{hook_event_name:"Notification",notification_type:"permission_prompt",cwd:"/x/proj",message:"evil;99;boom"}')"
seqI="$(run "CLAUDE_NOTIFY_OSC=777" "$NOTIF_INJ" | jq -r '.terminalSequence // empty')"
semis="$(printf '%s' "$seqI" | tr -cd ';' | wc -c | tr -d ' ')"
assert_eq "injected ';' neutralized (OSC 777 keeps exactly its 3 delimiters)" "3" "$semis"

# I. Registration source of truth.
assert_eq "additions.json wires notify-osc → hooks/notify-osc.sh" "hooks/notify-osc.sh" \
  "$(jq -r '.additions[]|select(.id=="notify-osc")|.hook' "$ADDITIONS")"

t_summary
