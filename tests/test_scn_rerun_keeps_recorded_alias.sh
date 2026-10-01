#!/usr/bin/env bash
# Scenario — a default re-run keeps the alias the profile already recorded.
#
# The default launcher name for ~/.claude-aka is `aka-claude`, but profiles
# installed earlier recorded `alias=aka` (or a custom name) in
# <profile>/.aka-claude-tools-meta. A plain re-run (--defaults, no CT_ALIAS) must
# keep that recorded alias: no new `aka-claude` block or shim, meta still says the
# old name, and the old block is left as the one launcher. Fresh installs still
# default to `aka-claude`.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_rerun_keeps_recorded_alias:"

INSTALL="$REPO_ROOT/install.sh"
SEL="secure-settings leak-guard wrap-up"
IPATH="$(install_path)"
blocks_for() { grep -c "managed: $1 >>>" "$2" 2>/dev/null || true; }
defaults_run() { PATH="$IPATH" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$1" \
                 bash "$INSTALL" --defaults --no-auth-inherit >"$1/log" 2>&1; }

# ── A. profile recorded `aka` (pre-rename install) → re-run keeps `aka` ──────
SB="$(sandbox)"; RC="$SB/.bashrc"; touch "$RC"; P="$SB/.claude-aka"
mkdir -p "$P"
PATH="$IPATH" CT_CONFIG_DIR="$P" CT_ALIAS=aka SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --alias >"$SB/log0" 2>&1
assert_eq "A: setup — meta records alias=aka" "aka" \
  "$(grep -E '^alias=' "$P/.aka-claude-tools-meta" | tail -1 | cut -d= -f2-)"
defaults_run "$SB"
assert_eq "A: default re-run exits 0" "0" "$?"
assert_eq "A: meta still records alias=aka" "aka" \
  "$(grep -E '^alias=' "$P/.aka-claude-tools-meta" | tail -1 | cut -d= -f2-)"
assert_eq "A: 'aka' block still present" "1" "$(blocks_for aka "$RC")"
assert_eq "A: no 'aka-claude' block written" "0" "$(blocks_for aka-claude "$RC")"
assert_ok "A: no 'aka-claude' shim written" bash -c "[ ! -e '$P/bin/aka-claude' ]"

# ── B. custom recorded name survives a default re-run ────────────────────────
SB="$(sandbox)"; RC="$SB/.bashrc"; touch "$RC"; P="$SB/.claude-aka"
mkdir -p "$P"
PATH="$IPATH" CT_CONFIG_DIR="$P" CT_ALIAS=myclaude SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --alias >"$SB/log0" 2>&1
defaults_run "$SB"
assert_eq "B: default re-run exits 0" "0" "$?"
assert_eq "B: meta still records alias=myclaude" "myclaude" \
  "$(grep -E '^alias=' "$P/.aka-claude-tools-meta" | tail -1 | cut -d= -f2-)"
assert_eq "B: no 'aka-claude' block written" "0" "$(blocks_for aka-claude "$RC")"

# ── C. fresh install still defaults to `aka-claude` ──────────────────────────
SB="$(sandbox)"; RC="$SB/.bashrc"; touch "$RC"; P="$SB/.claude-aka"
defaults_run "$SB"
assert_eq "C: fresh install exits 0" "0" "$?"
assert_eq "C: fresh install records alias=aka-claude" "aka-claude" \
  "$(grep -E '^alias=' "$P/.aka-claude-tools-meta" | tail -1 | cut -d= -f2-)"
assert_eq "C: one 'aka-claude' block" "1" "$(blocks_for aka-claude "$RC")"

t_summary
