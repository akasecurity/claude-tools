#!/usr/bin/env bash
# Scenario — alias ownership: install.sh is the SOLE sanctioned shell-rc writer
# (--alias mode), idempotent, and correct across MULTIPLE aka-managed configs.
#
# install.sh owns alias creation/checking so the agent never edits the rc itself
# (which would force loosening command-guard's startup-file-write block). This pins:
#   A. --alias writes one managed block; re-running for the same dir+alias is
#      IDEMPOTENT — it never accumulates duplicate entries across installs/upgrades.
#   B. MULTIPLE aka-managed configs coexist: distinct aliases (aka, work, play) get
#      distinct blocks; re-running one never disturbs another's.
#   C. A real name collision (the alias already targets a DIFFERENT dir) makes
#      --alias (strict policy) exit non-zero WITHOUT clobbering the user's line —
#      the agent then picks another name.
#   D. After a multi-config install the shell-audit skill reports a CLEAN rc — no
#      duplicate or dangling aliases — i.e. the audit supports multiple aka configs.
#
# Fully sandboxed: fake $HOME, fake bash rc. Never touches a real ~/.claude* or rc.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_alias_multi:"

INSTALL="$REPO_ROOT/install.sh"
AUDIT="$REPO_ROOT/config/skills/shell-audit/audit.sh"
SB="$(sandbox)"; RC="$SB/.bashrc"; touch "$RC"
mkdir -p "$SB/.claude-aka" "$SB/.claude-work" "$SB/.claude-play"

# Run install.sh --alias for <dir> <name>; rc-file resolution follows SHELL.
# Hermetic PATH (install_path): the installer refuses a launcher name that is
# already a PATH command (e.g. a real ai-tc `aka` on the operator's machine).
IPATH="$(install_path)"
mkalias() { PATH="$IPATH" CT_CONFIG_DIR="$1" CT_ALIAS="$2" SHELL=/bin/bash HOME="$SB" \
            bash "$INSTALL" --alias >"$SB/log" 2>&1; }
blocks_for() { grep -c "managed: $1 >>>" "$RC" 2>/dev/null || true; }

# ── A. idempotent single alias ───────────────────────────────────────────────
mkalias "$SB/.claude-aka" aka
assert_eq "--alias exits 0 creating 'aka'" "0" "$?"
assert_eq "one managed block for 'aka' after first run" "1" "$(blocks_for aka)"
assert_ok "rc now defines alias aka" bash -c "grep -qE '^alias aka=' '$RC'"
# Re-run twice more (simulate repeated installs/upgrades) — must NOT duplicate.
mkalias "$SB/.claude-aka" aka
mkalias "$SB/.claude-aka" aka
assert_eq "still exactly one managed block for 'aka' after re-runs (idempotent)" "1" "$(blocks_for aka)"
assert_eq "exactly one 'alias aka=' line total (no duplicate entries)" \
  "1" "$(grep -cE '^alias aka=' "$RC")"

# ── B. multiple aka-managed configs coexist ──────────────────────────────────
mkalias "$SB/.claude-work" work
mkalias "$SB/.claude-play" play
assert_eq "block for 'work' present" "1" "$(blocks_for work)"
assert_eq "block for 'play' present" "1" "$(blocks_for play)"
assert_eq "'aka' block untouched by the other installs" "1" "$(blocks_for aka)"
assert_eq "three distinct launcher alias lines total" "3" "$(grep -cE '^alias (aka|work|play)=' "$RC")"
# Re-running ONE config must leave the OTHERS' blocks intact.
mkalias "$SB/.claude-aka" aka
assert_eq "re-running 'aka' keeps 'work' block" "1" "$(blocks_for work)"
assert_eq "re-running 'aka' keeps 'play' block" "1" "$(blocks_for play)"
assert_eq "still one 'aka' block after re-run" "1" "$(blocks_for aka)"
# Each block points at its OWN dir.
assert_ok "aka → .claude-aka"   bash -c "grep -A1 'managed: aka >>>'  '$RC' | grep -q '/.claude-aka'"
assert_ok "work → .claude-work" bash -c "grep -A1 'managed: work >>>' '$RC' | grep -q '/.claude-work'"

# ── C. strict collision: alias already targets a DIFFERENT dir ───────────────
# Plant the user's own 'taken' alias pointing at a DIFFERENT profile, in the same
# rc the installer writes. --alias (strict) must NOT clobber it and must exit
# non-zero so the agent picks another name.
mkdir -p "$SB/.claude-other"
printf 'alias taken=%s\n' "'CLAUDE_CONFIG_DIR=\"$SB/.claude-other\" claude'" >> "$RC"
PATH="$IPATH" CT_CONFIG_DIR="$SB/.claude-aka" CT_ALIAS=taken SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --alias >"$SB/clog" 2>&1
assert_eq "--alias exits non-zero on a real collision (caller picks another name)" "1" "$?"
assert_eq "no managed block written for the colliding name" "0" "$(blocks_for taken)"
assert_ok "user's own 'taken' alias line left intact" bash -c "grep -qF 'CLAUDE_CONFIG_DIR=\"$SB/.claude-other\"' '$RC'"
# Remove the planted collision so the audit below sees only kit-managed aliases.
grep -v "alias taken=" "$RC" > "$RC.clean" && mv "$RC.clean" "$RC"

# ── D. shell-audit reports a clean rc over the multi-config install ───────────
SHELL=/bin/bash HOME="$SB" bash "$AUDIT" "$RC" >"$SB/audit" 2>&1
assert_eq "shell-audit exits 0" "0" "$?"
assert_grep "audit: no duplicate or dangling aliases over the multi-config rc" \
  'no duplicate or dangling aliases' "$SB/audit"
assert_ngrep "audit flags no duplicate alias among the aka configs" \
  "alias '(aka|work|play)' defined in" "$SB/audit"

t_summary
