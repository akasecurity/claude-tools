#!/usr/bin/env bash
# aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
# harness-pointer.sh — PreToolUse hook for the Bash tool.
#
# Points the harness in the right direction. When the agent reaches for a command
# that's wrong for THIS environment, intercept it and hand back a hint that steers
# it to the correct approach — instead of letting it run a command that fails
# confusingly, isn't installed, or is the wrong tool for your setup.
#
# Mechanism: it blocks the command (exit 2) and returns your hint. The block is
# the lever; the hint is the point. This is GUIDANCE, not a security boundary —
# it scans every command POSITION (the first word of each segment split on
# ; && || | & newlines, $( / ` substitution openers, and the ( { group openers
# that themselves sit at a command position, after peeling leading
# sudo/env/command/… wrappers), so `cd x && gh …`, `echo …; gh …`, `… | gh`,
# `$(gh …)` and `sudo gh …` are all caught — not just the first word of the line.
# Best-effort, NOT a full shell parser: a blocked name placed right after a shell
# operator INSIDE a double-quoted literal can still false-positive, and eval/alias
# indirection isn't parsed. Real restrictions belong in settings.json permissions.deny.
#
# Ships DISABLED and with an EMPTY list — most engineers want every CLI. Opt in via
# aka-claude-tools.config (canonical example: self-hosted VCS, point `gh` users to git):
#
#     CT_BLOCKED_CMDS="gh|kubectl"
#     CT_BLOCKED_HINT="Use plain git — this team's remote is self-hosted, not GitHub."
#
# With CT_BLOCKED_CMDS empty (the default), this hook is a no-op.

set -euo pipefail

input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

# ── Load opt-in org config ──
_cfg="${CLAUDETOOLS_CONFIG:-}"
if [ -z "$_cfg" ]; then
    for c in "${CLAUDE_CONFIG_DIR:-}/aka-claude-tools.config" "$HOME/.claude/aka-claude-tools.config"; do
        [ -n "${c%/aka-claude-tools.config}" ] && [ -f "$c" ] && { _cfg="$c"; break; }
    done
fi
CT_BLOCKED_CMDS=""
CT_BLOCKED_HINT="This command isn't the right tool here (aka-claude-tools harness-pointer). Check aka-claude-tools.config for the intended approach."
# shellcheck disable=SC1090
[ -n "$_cfg" ] && [ -f "$_cfg" ] && source "$_cfg" 2>/dev/null || true

[ -z "$CT_BLOCKED_CMDS" ] && exit 0

# Find a blocked command at ANY command position — not just the first word of the
# line. Drop single-quoted literals first (sed/awk/grep patterns routinely carry
# | ; & and would split spuriously), then break the command on shell operators and
# substitution openers so each resulting segment STARTS at a command position.
# Heredoc bodies are data, not commands: drop every line from a `<<WORD` / `<<'WORD'`
# / `<<-WORD` opener up to its closing WORD, or prose like "(open questions)" in a
# heredoc'd file would read as `open` at a command position. `<<<` is untouched.
scan="$(printf '%s\n' "$cmd" | awk -v q="'" '
    d != "" { t = $0; sub(/^\t+/, "", t); if (t == d) d = ""; next }
    { print
      if (match($0, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*/)) {
          d = substr($0, RSTART, RLENGTH); gsub(/<<-?[ \t]*/, "", d); gsub(/["]/, "", d); gsub(q, "", d)
      } }')"
scan="$(printf '%s' "$scan" | sed -E "s/'[^']*'/ /g")"
scan="$(printf '%s' "$scan" | sed -E 's/(\|\||&&|;|\||&|\$\(|`|\)|\})/\n/g')"
# `(` and `{` open a command position only where a command may START. Glued to an
# identifier character they are a call or expansion in EMBEDDED code, not shell:
# python's `json.load(open(…))` would otherwise split into a segment beginning
# `open` and block it. So split them only at the start of the line or after a
# non-identifier character — `$(` and `${` are already excluded by the `$`.
scan="$(printf '%s' "$scan" | sed -E 's/^[({]/\n/; s/([^[:alnum:]_.$])[({]/\1\n/g')"
# Leading wrappers that precede the real command at a position (repeatable):
# env-assignments (FOO=bar) and sudo/command/builtin/nohup/time/env/xargs.
wrap='^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|(sudo|command|builtin|nohup|time|env|xargs)[[:space:]]+)'
hit=""
while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//')"
    while printf '%s' "$seg" | grep -qE "$wrap"; do
        seg="$(printf '%s' "$seg" | sed -E "s/$wrap//")"
    done
    fw="$(printf '%s' "$seg" | awk '{print $1; exit}')"
    if printf '%s' "$fw" | grep -qE "^(${CT_BLOCKED_CMDS})$"; then hit="$fw"; break; fi
done <<EOF
$scan
EOF
if [ -n "$hit" ]; then
    printf 'blocked: `%s` is disallowed in this environment.\n%s\n' "$hit" "$CT_BLOCKED_HINT" >&2
    exit 2
fi

exit 0
