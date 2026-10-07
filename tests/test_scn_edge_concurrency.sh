#!/usr/bin/env bash
# Scenario scn_edge_concurrency: CONCURRENCY / INTERRUPTION on the --clean rebuild.
#
# The rebuild path moves the live profile aside with
#     mv "$config_dir" "$config_dir.backup-$(date +%Y%m%d-%H%M%S)"
# The timestamp has only SECOND granularity and a single rebuild runs in ~0.3s, so
# two rebuilds in the same wall-clock second (a double-click, a rollback-then-retry,
# a fast CI loop, a leftover same-second backup) compute the SAME backup path.
#
# When that backup path already exists as a directory, `mv DIR EXISTING_DIR` does NOT
# fail on either BSD or GNU — it NESTS the source INSIDE the existing dir
# (EXISTING_DIR/<basename>). The installer then mkdir's a fresh empty profile and
# tries to restore from $rebuild_backup, but the user's real state now lives one level
# deeper (backup/.claude-aka/...), so the restore finds nothing. Result: the live
# profile comes back EMPTY (CLAUDE.md, history, sessions all gone), the installer exits
# 0, and the log even claims "your conversations… were restored". Silent data loss.
#
# This test forces the collision deterministically by shimming `date` to a fixed value
# and pre-creating the backup dir, so it pins the bug without relying on a real race.
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit. Never touches a real
# ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_edge_concurrency:"

SB="$(sandbox)"; touch "$SB/.bashrc"; P="$SB/.claude-aka"
SEL="secure-settings"
run() { CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB" "$@" \
        bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit; }

# ── (1) baseline install + plant precious, unrecoverable user state ────────────
CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log0" 2>&1
printf '# precious global memory\n' > "$P/CLAUDE.md"
echo '{"event":"irreplaceable"}'    > "$P/history.jsonl"
mkdir -p "$P/projects/proj/memory"; echo "a hard-won lesson" > "$P/projects/proj/memory/x.md"
assert_file "baseline planted CLAUDE.md" "$P/CLAUDE.md"

# ── (2) force a same-second backup-path collision ──────────────────────────────
# Shim `date` so the installer computes a FIXED backup suffix, then pre-create that
# backup dir (as a leftover from a "previous same-second run"). This is exactly the
# state two rebuilds in one second land in.
SHIM="$SB/bin"; mkdir -p "$SHIM"
cat > "$SHIM/date" <<'D'
#!/bin/sh
echo "FIXEDTS"
D
chmod +x "$SHIM/date"
COLLIDE="$P.backup-FIXEDTS"
mkdir -p "$COLLIDE"; echo "leftover backup from a same-second run" > "$COLLIDE/marker"

PATH="$SHIM:$PATH" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
rc=$?

# ── (3) the install must NOT silently destroy the user's state ──────────────────
# The contract of the whole rebuild path (see install.sh header + test_rebuild) is
# "an upgrade is never a fresh install — your state is restored." A backup-path
# collision must therefore either fail loudly (non-zero, original profile intact) or
# restore correctly — it must NEVER come back empty while reporting success.
#
# A successful exit with the live profile emptied is the data-loss outcome we pin.
if [ "$rc" -ne 0 ]; then
  pass "collision was rejected loudly (non-zero exit) instead of losing data silently"
else
  pass "installer exited 0 on the collision (it reports success)"
fi

# These are the assertions that catch the bug: if the rebuild reports success it MUST
# have actually preserved the state.
assert_file "CLAUDE.md survives the backup-path collision"   "$P/CLAUDE.md"
assert_grep "CLAUDE.md content intact after collision"       'precious global memory' "$P/CLAUDE.md"
assert_file "history.jsonl survives the backup-path collision" "$P/history.jsonl"
assert_grep "history content intact after collision"         'irreplaceable' "$P/history.jsonl"
assert_file "projects/memory survives the backup-path collision" "$P/projects/proj/memory/x.md"

# Defense-in-depth: the user's data must not have been silently buried INSIDE the
# pre-existing backup dir (the nesting signature of the bug).
[ -e "$COLLIDE/.claude-aka" ] \
  && fail "user profile was NOT nested inside the pre-existing backup dir" "found $COLLIDE/.claude-aka (mv-into-dir nesting)" \
  || pass "user profile was NOT nested inside the pre-existing backup dir"

t_summary
