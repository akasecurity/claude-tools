#!/usr/bin/env bash
# Scenario — --delete-alias only clears the profile's recorded alias metadata when
# the deleted alias IS the recorded one.
#
# A launcher rename (--alias with a new name) leaves the old name's managed block
# in the rc, so one profile can carry two blocks while its metadata records only
# the newest name. Deleting the older block must not wipe that record.
#
# Invariants:
#   A. Deleting a non-recorded alias (older 'aka' while metadata says 'aka-claude')
#      removes that block and leaves alias=aka-claude in the metadata.
#   B. Deleting the recorded alias clears the metadata alias value.
#
# Fully sandboxed: fake $HOME, fake rc, SHELL pinned to bash (see test_scn_alias_delete.sh).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_alias_delete_meta:"

INSTALL="$REPO_ROOT/install.sh"
IPATH="$(install_path)"

SB="$(sandbox)"; export HOME="$SB"; RC="$SB/.bashrc"; touch "$RC"
CD="$SB/.claude-aka"; META="$CD/.aka-claude-tools-meta"

for name in aka aka-claude; do
  PATH="$IPATH" CT_CONFIG_DIR="$CD" CT_ALIAS="$name" SHELL=/bin/bash HOME="$SB" \
    bash "$INSTALL" --alias --no-auth-inherit >"$SB/log-$name" 2>&1
done
assert_lit "setup: old aka block present"         "alias aka="        "$RC"
assert_lit "setup: aka-claude block present"      "alias aka-claude=" "$RC"
assert_lit "setup: metadata records aka-claude"   "alias=aka-claude"  "$META"

# ── A. delete the older, non-recorded alias ─────────────────────────────────
CT_CONFIG_DIR="$CD" CT_ALIAS="aka" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >"$SB/del-a" 2>&1
assert_eq    "A: delete exits 0"                  "0" "$?"
assert_ngrep "A: aka block gone"                  "alias aka="        "$RC"
assert_lit   "A: aka-claude block intact"         "alias aka-claude=" "$RC"
assert_lit   "A: metadata still records aka-claude" "alias=aka-claude" "$META"

# ── B. delete the recorded alias clears the record ──────────────────────────
CT_CONFIG_DIR="$CD" CT_ALIAS="aka-claude" SHELL=/bin/bash HOME="$SB" \
  bash "$INSTALL" --delete-alias >"$SB/del-b" 2>&1
assert_eq    "B: delete exits 0"                  "0" "$?"
assert_ngrep "B: aka-claude block gone"           "alias aka-claude=" "$RC"
assert_eq    "B: metadata alias cleared"          "alias=" "$(grep -E '^alias=' "$META" | tail -1)"

t_summary
