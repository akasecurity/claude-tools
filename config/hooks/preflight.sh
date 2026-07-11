#!/usr/bin/env sh
# aka-claude-tools:managed-hook — SessionStart preflight. Fail-open guards are silent per-call; this
# is the ONE loud, per-session notice that the guards are inactive when bun is missing. For SessionStart,
# exit 2 is NON-blocking (docs: SessionStart can't block) but surfaces stderr to the user — exit 0's stderr is discarded.
set -u
_cands="${AKA_BUN_CANDIDATES:-$HOME/.bun/bin/bun /opt/homebrew/bin/bun /usr/local/bin/bun $HOME/.local/bin/bun}"
if command -v bun >/dev/null 2>&1; then exit 0; fi
for c in $_cands; do [ -x "$c" ] && exit 0; done
printf '[aka-claude-tools] ⚠️  The AKA guards are INACTIVE: bun was not found, so command-guard / leak-guard are not running and your tool calls are NOT being scanned. Install bun (https://bun.sh) and restart, or use the standalone installer for a fully hardened profile.\n' >&2
exit 2
