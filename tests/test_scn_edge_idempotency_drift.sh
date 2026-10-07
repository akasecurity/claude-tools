#!/usr/bin/env bash
# Edge / long-run idempotency: a --clean rebuild whose timestamped backup target
# ALREADY EXISTS must not silently reset the profile and orphan the user's data.
#
# The rebuild path moves the live config dir to "$config_dir.backup-$(date +%Y%m%d-%H%M%S)"
# and then rebuilds from that backup. The timestamp has 1-SECOND resolution, so two
# rebuilds in the same wall-clock second collide on the backup name. `mv DIR EXISTING_DIR`
# does NOT fail — it NESTS the source inside the existing dir (backup-<T>/.claude-aka/).
# default_src then points at the OUTER (wrong-level) dir, the restore finds none of the
# user's settings.json / CLAUDE.md / projects there, and the profile is rebuilt with
# kit defaults only — exit 0, no warning, rollback trap never fires. The user's data is
# orphaned one level down in the backup. A pre-existing backup dir at that path (a
# left-over, or any same-second collision) reproduces it deterministically.
#
# Convergence invariant: re-running the rebuild must PRESERVE the profile's own state
# (CLAUDE.md, conversations, user settings), never silently reset it. RED until the
# installer guards a colliding backup path (e.g. uniquifies it, or refuses to mv onto
# an existing target).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_edge_idempotency_drift:"

SB="$(sandbox)"; touch "$SB/.bashrc"
PROFILE="$SB/.claude-aka"
ALL="$(jq -r '[.additions[].id] | join(" ")' "$ADDITIONS")"

# 1. fresh install of the full kit.
CT_ADDITIONS="$ALL" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log0" 2>&1
assert_file "fresh install wrote settings.json" "$PROFILE/settings.json"

# 2. seed the profile with the user's OWN state.
jq '.permissions.deny += ["Read(//USERSENTINEL/**)"]' "$PROFILE/settings.json" >"$SB/t" \
  && mv "$SB/t" "$PROFILE/settings.json"
echo "CLAUDEMD-SENTINEL"     > "$PROFILE/CLAUDE.md"
mkdir -p "$PROFILE/projects/p/memory"
echo "CONV-SENTINEL"         > "$PROFILE/projects/p/memory/conv.md"

# 3. force the backup-name collision: pre-create the backup dir for THIS second, exactly
#    what a same-second second rebuild would hit. (No sleep games — this IS the collision.)
BK="$PROFILE.backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"

# 4. re-run the install → it should converge (preserve state), not reset.
CT_ADDITIONS="$ALL" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log1" 2>&1
rc=$?

# The live profile MUST still hold the user's data after the rebuild.
assert_ok "user deny rule survived the rebuild" \
  bash -c "jq -e '.permissions.deny | index(\"Read(//USERSENTINEL/**)\") != null' '$PROFILE/settings.json' >/dev/null 2>&1"
assert_grep "user CLAUDE.md survived the rebuild" 'CLAUDEMD-SENTINEL' "$PROFILE/CLAUDE.md"
assert_file "user conversation memory survived the rebuild" "$PROFILE/projects/p/memory/conv.md"

# A rebuild that silently reset the profile must not report clean success.
if [ "$rc" != "0" ]; then
  pass "non-converging rebuild did not report success (rc=$rc)"
else
  # rc==0 is only acceptable if the data above actually survived; the asserts cover that.
  pass "rebuild exited 0 (data-survival asserts above are the real gate)"
fi

t_summary
