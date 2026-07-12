#!/usr/bin/env bash
# aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
# notify-osc.sh — Stop / Notification hook: a desktop notification that means it's
# genuinely YOUR turn, not just that a background task is still running.
#
# WHY: Claude Code fires a notification at every turn-end. When you end a turn parked on
# a running background task (a subagent or a `run_in_background` shell), that isn't "your
# turn" — it's a wait, and the ping is a false alarm. This hook suppresses exactly that
# case, so a banner means Claude actually needs YOU. It closes the gap the rejected
# BackgroundTasksIdle request (anthropics/claude-code#45781, closed not-planned) left
# open, using the `background_tasks` array Claude Code added to the Stop payload (2.1.145).
#
# HOW: rides Claude Code's `terminalSequence` hook output (>= 2.1.141) — the escape
# sequence is emitted through Claude Code's own terminal write path, so it works over SSH
# and inside tmux/screen, where writing to /dev/tty would fail or notify the wrong host.
# The dialect is auto-detected per terminal and EXACTLY ONE sequence is emitted (never
# several: Ghostty and WezTerm honor more than one code, so "emit all" would double-fire):
#   OSC 99  → kitty
#   OSC 777 → Ghostty, WezTerm, urxvt, rio, foot
#   OSC 9   → iTerm2, and the universal fallback (Ghostty/WezTerm/kitty render it too)
#
# Bound to Stop (turn-end) and Notification (idle_prompt / permission_prompt). NOT bound
# to SubagentStop, so subagent churn stays silent. Convenience, not a security boundary.
#
# Override detection: CLAUDE_NOTIFY_OSC = 777 | 99 | 9 | off   (off = never notify).
# Dependency: jq.

set -euo pipefail

input="$(cat)"

event="$(jq -r '.hook_event_name // empty'   <<<"$input" 2>/dev/null || true)"
ntype="$(jq -r '.notification_type // empty' <<<"$input" 2>/dev/null || true)"
cwd="$(jq -r '.cwd // empty'                 <<<"$input" 2>/dev/null || true)"
msg="$(jq -r '.message // empty'             <<<"$input" 2>/dev/null || true)"

# A Stop fired while a background task is still running is a parked turn, not "your turn"
# — suppress it; the task's completion re-invocation fires a real banner later. Key on a
# "running" task (shell AND subagent both populate .background_tasks), so a lingering
# completed/failed task still notifies. Fail open: a missing/renamed field yields [] via
# `// []`, so an older/newer Claude Code just notifies as before.
if [ "$event" = "Stop" ]; then
    running="$(jq -r '[(.background_tasks // [])[] | select(.status == "running")] | length' <<<"$input" 2>/dev/null || echo 0)"
    if [ "${running:-0}" -gt 0 ]; then exit 0; fi
fi

# ── Title + body ──
# Title = project name (falls back to the session's cwd basename, then a constant).
project="$(basename "${cwd:-}" 2>/dev/null || true)"
[ -n "$project" ] && [ "$project" != "/" ] || project="session"
title="Claude · ${project}"
case "$event" in
    Stop)         body="Your turn" ;;
    Notification)
        case "$ntype" in
            idle_prompt)       body="Waiting for you (idle)" ;;
            permission_prompt) body="${msg:-Permission needed}" ;;
            *)                 body="${msg:-Notification}" ;;
        esac ;;
    *)            body="${msg:-Done}" ;;
esac

# Sanitize: collapse newlines, turn the OSC field delimiter ';' into ',', drop BEL/ESC.
# Replacing ';' also prevents a crafted title/body from injecting extra OSC parameters
# (e.g. an OSC 9 "4;" progress form). Cap length so a long message can't wall-of-text.
sanitize() { local s="${1//$'\n'/ }"; s="${s//;/,}"; printf '%s' "${s//$'\a'/}" | tr -d '\033' ; }
title="$(sanitize "$title")"
body="$(sanitize "$body")"
body="${body:0:150}"

# ── Pick the OSC dialect for this terminal ──
# Mirrors Claude Code's own terminal detection (TERM_PROGRAM / LC_TERMINAL / per-terminal
# vars / TERM). LC_TERMINAL is what makes iTerm2 detectable over SSH — LC_* is forwarded
# by default, TERM_PROGRAM is not. When nothing matches, OSC 9 is the safe fallback: it's
# the most broadly rendered single code (iTerm2, Ghostty, WezTerm, and kitty all honor it).
osc="${CLAUDE_NOTIFY_OSC:-auto}"
[ "$osc" = "off" ] && exit 0
if [ "$osc" = "auto" ]; then
    tp="${TERM_PROGRAM:-}"; lt="${LC_TERMINAL:-}"; t="${TERM:-}"
    if   [ -n "${KITTY_WINDOW_ID:-}" ] || [ "$tp" = "kitty" ] || [[ "$t" == *kitty* ]]; then osc=99
    elif [ -n "${GHOSTTY_RESOURCES_DIR:-}" ] || [ -n "${GHOSTTY_BIN_DIR:-}" ] || [ "$tp" = "ghostty" ] || [[ "$t" == *ghostty* ]]; then osc=777
    elif [ -n "${WEZTERM_PANE:-}" ] || [ "$tp" = "WezTerm" ] || [[ "$t" == *wezterm* ]]; then osc=777
    elif [ "$tp" = "iTerm.app" ] || [ "$lt" = "iTerm2" ] || [ -n "${ITERM_SESSION_ID:-}" ]; then osc=9
    elif [[ "$t" == *rxvt* || "$t" == *rio* || "$t" == *foot* ]]; then osc=777
    else osc=9
    fi
fi

# ── Emit exactly one sequence via terminalSequence ──
# OSC 777 carries a separate title + body. OSC 99 (kitty) and OSC 9 (iTerm2/fallback)
# take a single text field, so the title is folded in with an em dash. The folded text
# always starts with "Claude", so an OSC 9 body never begins with a digit (Claude Code's
# allowlist reserves a leading-digit OSC 9 for the 9;4 progress form).
case "$osc" in
    777) seq="$(printf '\033]777;notify;%s;%s\007' "$title" "$body")" ;;
    99)  seq="$(printf '\033]99;;%s — %s\007' "$title" "$body")" ;;
    9)   seq="$(printf '\033]9;%s — %s\007' "$title" "$body")" ;;
    *)   exit 0 ;;
esac
jq -nc --arg seq "$seq" '{terminalSequence: $seq}'
exit 0
