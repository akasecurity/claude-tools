#!/usr/bin/env bash
# sandbox: the opt-in addition that enables Claude Code's native OS-level sandbox, so
# Bash and every other tool run confined — closing the gap where a Bash
# `cat ~/.aws/credentials` bypasses a Read-tool-only deny.
#
# It deliberately does NOT also write an explicit sandbox.filesystem.denyRead: Claude
# Code's OWN documented schema for that field says it is "Merged with paths from
# Read(...) deny permission rules" — the runtime already folds settings.base.json's
# credential Read(...) denies into the sandbox's effective filesystem denylist on its
# own, with the correct permission-rule glob resolution. A kit-written denyRead
# containing the SAME `Read(<path>)` strings verbatim would instead be re-resolved
# under sandbox.filesystem's own (narrower) path rules, where a no-prefix glob like
# `**/.env` resolves relative to the settings file root (~/.claude for user settings)
# rather than matching project-relative — silently protecting nothing. So this addition
# only flips sandbox.enabled on; it never writes its own denyRead.
#
# Covers:
#   1. select  → settings.json carries sandbox.enabled=true, and NO kit-written
#      sandbox.filesystem.denyRead. The Read(...) credential denies from secure-settings
#      are still present in permissions.deny (Claude Code's own runtime merge is what
#      protects them, not this addition).
#   2. deselect → sandbox.enabled is removed (no prior value to restore).
#   3. a pre-existing user `sandbox.network.allowLocalBinding` (a sibling this addition
#      never touches) survives BOTH select and deselect.
#   4. a pre-existing user `sandbox.enabled: false` is STASHED on select (overwritten to
#      true while selected) and RESTORED to false on deselect — never just deleted.
#   5. Linux with no `bwrap` on PATH → skipped with the documented notice, install
#      still exits 0 (soft-skip: opt-in addition, not a fatal dependency).
#   6. idempotent re-run (select twice in a row) produces semantically unchanged
#      settings, and does NOT corrupt the stash (a second select must not re-stash the
#      kit's own prior write as if it were a fresh user value).
#
# Fully sandboxed: fake $HOME via tests/lib.sh's sandbox(), --no-auth-inherit,
# CT_ADDITIONS explicit selection. Never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_sandbox:"

INSTALL="$REPO_ROOT/install.sh"

install_into() { # <home> <config_dir> <ct_additions> [extra env "VAR=val" ...]
  local home="$1" cfg="$2" sel="$3"; shift 3
  env "$@" CT_CONFIG_DIR="$cfg" CT_ADDITIONS="$sel" HOME="$home" \
    bash "$INSTALL" --apply --no-auth-inherit
}

# assert_install_ok <desc> <log-file> <rc> — like assert_eq but dumps the install
# log to stderr on failure (assert_eq's own return status doesn't reflect pass/fail,
# so `assert_eq ... || cat log` never actually fires).
assert_install_ok() {
  local desc="$1" log="$2" rc="$3"
  assert_eq "$desc" "0" "$rc"
  [ "$rc" != "0" ] && cat "$log" >&2
  return 0
}

# ── 1 & 2. select then deselect on a bare profile ───────────────────────────────
# Select BOTH secure-settings (so permissions.deny actually carries Read(...) credential
# rules to merge) and sandbox, proving the addition doesn't write its own denyRead AND
# that Claude Code's own merge target (permissions.deny) is left fully intact.
SB="$(sandbox)"; PROFILE="$SB/profile"
install_into "$SB" "$PROFILE" "secure-settings sandbox" >"$SB/select.log" 2>&1
assert_install_ok "select: install exits 0" "$SB/select.log" "$?"
S="$PROFILE/settings.json"
assert_file "select: settings.json created" "$S"
if [ -f "$S" ]; then
  if jq -e '.sandbox.enabled == true' "$S" >/dev/null 2>&1; then
    pass "select: sandbox.enabled is true"
  else
    fail "select: sandbox.enabled is true" "got: $(jq -c '.sandbox.enabled // "MISSING"' "$S" 2>/dev/null)"
  fi
  if jq -e '(.sandbox.filesystem // {}) == {}' "$S" >/dev/null 2>&1; then
    pass "select: NO kit-written sandbox.filesystem.denyRead"
  else
    fail "select: NO kit-written sandbox.filesystem.denyRead" "got: $(jq -c '.sandbox.filesystem' "$S" 2>/dev/null)"
  fi
  n_read_denies="$(jq '[ (.permissions.deny // [])[] | select(startswith("Read(")) ] | length' "$S" 2>/dev/null)"
  if [ "${n_read_denies:-0}" -gt 0 ]; then
    pass "select: Read(...) credential denies from secure-settings still present in permissions.deny ($n_read_denies rules) — Claude Code's own runtime merge protects them, not this addition"
  else
    fail "select: Read(...) credential denies still present in permissions.deny" "got: $(jq -c '.permissions.deny' "$S" 2>/dev/null)"
  fi
fi

install_into "$SB" "$PROFILE" "" >"$SB/deselect.log" 2>&1
assert_install_ok "deselect: install exits 0" "$SB/deselect.log" "$?"
if [ -f "$S" ]; then
  assert_nlit "deselect: no residual 'sandbox' key in settings.json" '"sandbox"' "$S"
  # secure-settings was ALSO deselected here, so its Read(...) denies should be gone
  # too — this is secure-settings' own prune, just confirming the sandbox addition's
  # deselect didn't interfere with it.
  n_read_denies="$(jq '[ (.permissions.deny // [])[] | select(startswith("Read(")) ] | length' "$S" 2>/dev/null)"
  assert_eq "deselect: secure-settings' own Read(...) denies pruned too (unrelated to sandbox)" "0" "${n_read_denies:-0}"
fi

# ── 3. a pre-existing user sandbox key (a sibling this addition never touches) ──
SB2="$(sandbox)"; PROFILE2="$SB2/profile"
mkdir -p "$PROFILE2"
cat > "$PROFILE2/settings.json" <<'EOF'
{
  "sandbox": {
    "network": {
      "allowLocalBinding": true
    }
  }
}
EOF
install_into "$SB2" "$PROFILE2" "sandbox" >"$SB2/select.log" 2>&1
assert_install_ok "user-key: select exits 0" "$SB2/select.log" "$?"
S2="$PROFILE2/settings.json"
if jq -e '.sandbox.network.allowLocalBinding == true' "$S2" >/dev/null 2>&1; then
  pass "user-key: survives select (sandbox.network.allowLocalBinding still true)"
else
  fail "user-key: survives select" "got: $(jq -c '.sandbox // "MISSING"' "$S2" 2>/dev/null)"
fi
jq -e '.sandbox.enabled == true' "$S2" >/dev/null 2>&1 \
  && pass "user-key: sandbox.enabled still added alongside it" \
  || fail "user-key: sandbox.enabled still added alongside it" "got: $(jq -c '.sandbox // "MISSING"' "$S2" 2>/dev/null)"

install_into "$SB2" "$PROFILE2" "" >"$SB2/deselect.log" 2>&1
assert_install_ok "user-key: deselect exits 0" "$SB2/deselect.log" "$?"
if jq -e '.sandbox.network.allowLocalBinding == true' "$S2" >/dev/null 2>&1; then
  pass "user-key: survives deselect (sandbox.network.allowLocalBinding still true)"
else
  fail "user-key: survives deselect" "got: $(jq -c '.sandbox // "MISSING"' "$S2" 2>/dev/null)"
fi
if jq -e '(.sandbox.enabled // false) == false' "$S2" >/dev/null 2>&1; then
  pass "user-key: the addition's own sandbox.enabled is gone after deselect"
else
  fail "user-key: the addition's own sandbox.enabled is gone after deselect" "got: $(jq -c '.sandbox' "$S2" 2>/dev/null)"
fi

# ── 4. a pre-existing user sandbox.enabled:false is stashed and restored ────────
SB5="$(sandbox)"; PROFILE5="$SB5/profile"
mkdir -p "$PROFILE5"
cat > "$PROFILE5/settings.json" <<'EOF'
{
  "sandbox": {
    "enabled": false
  }
}
EOF
S5="$PROFILE5/settings.json"
install_into "$SB5" "$PROFILE5" "sandbox" >"$SB5/select.log" 2>&1
assert_install_ok "prior-value: select exits 0" "$SB5/select.log" "$?"
jq -e '.sandbox.enabled == true' "$S5" >/dev/null 2>&1 \
  && pass "prior-value: select overwrites to sandbox.enabled=true while selected" \
  || fail "prior-value: select overwrites to sandbox.enabled=true while selected" "got: $(jq -c '.sandbox' "$S5" 2>/dev/null)"
jq -e 'has("_aka_prior_sandbox_enabled")' "$S5" >/dev/null 2>&1 \
  && pass "prior-value: the original false is stashed" \
  || fail "prior-value: the original false is stashed" "got: $(jq -c '.' "$S5" 2>/dev/null)"

install_into "$SB5" "$PROFILE5" "" >"$SB5/deselect.log" 2>&1
assert_install_ok "prior-value: deselect exits 0" "$SB5/deselect.log" "$?"
if jq -e '.sandbox.enabled == false' "$S5" >/dev/null 2>&1; then
  pass "prior-value: restored to sandbox.enabled=false after deselect (not just deleted)"
else
  fail "prior-value: restored to sandbox.enabled=false after deselect" "got: $(jq -c '.sandbox // \"MISSING\"' "$S5" 2>/dev/null)"
fi
assert_nlit "prior-value: the stash marker itself is cleaned up" '_aka_prior_sandbox_enabled' "$S5"

# ── 5. Linux with no bwrap on PATH → soft-skip with the documented notice ─────
SB3="$(sandbox)"; PROFILE3="$SB3/profile"
STUBBIN="$(install_path)"   # tests/lib.sh helper — a hermetic PATH that never includes bwrap
install_into "$SB3" "$PROFILE3" "sandbox" "CT_UNAME=Linux" "PATH=$STUBBIN" \
  >"$SB3/skip.log" 2>&1
rc=$?
assert_eq "linux-no-bwrap: install still exits 0 (soft-skip, not a hard failure)" "0" "$rc"
assert_lit "linux-no-bwrap: prints the documented notice" \
  "sandbox: bubblewrap (bwrap) not found; sandbox addition skipped." "$SB3/skip.log"
S3="$PROFILE3/settings.json"
if [ -f "$S3" ]; then
  assert_nlit "linux-no-bwrap: no sandbox key was written" '"sandbox"' "$S3"
else
  pass "linux-no-bwrap: no sandbox key was written (no settings.json at all)"
fi

# ── 6. idempotent re-run — selecting twice in a row is semantically unchanged,
#      and does NOT re-stash the kit's own value as if it were a fresh user one ──
# Compared with `jq -S .` (recursive key-sort), not a byte/hash diff: install.sh's
# top-level JSON key ORDER is not itself a stable contract (a pre-existing,
# sandbox-unrelated quirk — the same reordering reproduces with e.g.
# `CT_ADDITIONS="telemetry-off error-reporting-off"` run twice, from the always-on
# rtk-rg/command-guard decoupling rewrite touching `add`'s key insertion order ahead of
# the final merge).
SB4="$(sandbox)"; PROFILE4="$SB4/profile"
install_into "$SB4" "$PROFILE4" "sandbox" >"$SB4/first.log" 2>&1
assert_install_ok "idempotent: first select exits 0" "$SB4/first.log" "$?"
S4="$PROFILE4/settings.json"
first_sorted="$(jq -S . "$S4" 2>/dev/null)"
assert_nlit "idempotent: no stash created on a from-scratch select (nothing to stash)" \
  '_aka_prior_sandbox_enabled' "$S4"
install_into "$SB4" "$PROFILE4" "sandbox" >"$SB4/second.log" 2>&1
assert_install_ok "idempotent: second select exits 0" "$SB4/second.log" "$?"
second_sorted="$(jq -S . "$S4" 2>/dev/null)"
assert_eq "idempotent: settings.json content unchanged across a repeat select" \
  "$first_sorted" "$second_sorted"
assert_nlit "idempotent: a repeat select does NOT stash its own prior write" \
  '_aka_prior_sandbox_enabled' "$S4"
# And deselecting after two selects fully removes it (nothing was ever a genuine
# pre-existing user value here) rather than "restoring" the kit's own true.
install_into "$SB4" "$PROFILE4" "" >"$SB4/deselect.log" 2>&1
assert_install_ok "idempotent: deselect after repeat-select exits 0" "$SB4/deselect.log" "$?"
assert_nlit "idempotent: deselect after repeat-select removes sandbox.enabled entirely" \
  '"sandbox"' "$S4"

t_summary
