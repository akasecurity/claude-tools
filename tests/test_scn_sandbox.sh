#!/usr/bin/env bash
# sandbox: the opt-in addition that enables Claude Code's native OS-level sandbox and
# denies reads on the same credential paths secure-settings denies to the Read tool —
# closing the gap where a Bash `cat ~/.aws/credentials` bypasses a Read-tool-only deny.
#
# Covers:
#   1. select  → settings.json carries the sandbox block, and denyRead equals the
#      Read(...) deny paths from config/settings.base.json (computed at install time,
#      not a duplicated static list).
#   2. deselect → the block (exactly the keys the addition added) is removed.
#   3. a pre-existing user `sandbox` key (a sibling this addition never touches)
#      survives BOTH select and deselect.
#   4. Linux with no `bwrap` on PATH → skipped with the documented notice, install
#      still exits 0 (soft-skip: opt-in addition, not a fatal dependency).
#   5. idempotent re-run (select twice in a row) produces byte-identical settings.
#
# Fully sandboxed: fake $HOME via tests/lib.sh's sandbox(), --no-auth-inherit,
# CT_ADDITIONS explicit selection. Never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_sandbox:"

INSTALL="$REPO_ROOT/install.sh"

# The SAME derivation install.sh uses: map every `Read(<path>)` permissions.deny rule
# in settings.base.json to <path>. Computed independently here (not sourced from
# install.sh) so this test actually PINS the contract rather than trivially agreeing
# with whatever install.sh happens to compute.
EXPECTED_DENYREAD="$(jq -c '[ (.permissions.deny // [])[]
  | select(startswith("Read(") and endswith(")"))
  | .[5:-1] ]' "$REPO_ROOT/config/settings.base.json")"
[ -n "$EXPECTED_DENYREAD" ] && [ "$EXPECTED_DENYREAD" != "[]" ] \
  && pass "sanity: settings.base.json has Read(...) deny rules to derive from" \
  || fail "sanity: settings.base.json has Read(...) deny rules to derive from" "got: $EXPECTED_DENYREAD"

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
SB="$(sandbox)"; PROFILE="$SB/profile"
install_into "$SB" "$PROFILE" "sandbox" >"$SB/select.log" 2>&1
assert_install_ok "select: install exits 0" "$SB/select.log" "$?"
S="$PROFILE/settings.json"
assert_file "select: settings.json created" "$S"
if [ -f "$S" ]; then
  if jq -e '.sandbox.enabled == true' "$S" >/dev/null 2>&1; then
    pass "select: sandbox.enabled is true"
  else
    fail "select: sandbox.enabled is true" "got: $(jq -c '.sandbox.enabled // "MISSING"' "$S" 2>/dev/null)"
  fi
  got_dr="$(jq -c '.sandbox.filesystem.denyRead // "MISSING"' "$S" 2>/dev/null)"
  assert_eq "select: denyRead equals settings.base.json's Read(...) deny paths" \
    "$EXPECTED_DENYREAD" "$got_dr"
fi

install_into "$SB" "$PROFILE" "" >"$SB/deselect.log" 2>&1
assert_install_ok "deselect: install exits 0" "$SB/deselect.log" "$?"
if [ -f "$S" ]; then
  assert_nlit "deselect: no residual 'sandbox' key in settings.json" '"sandbox"' "$S"
fi

# ── 3. a pre-existing user sandbox key survives select AND deselect ────────────
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
if jq -e '(.sandbox.enabled // false) == false and (.sandbox.filesystem // {}) == {}' "$S2" >/dev/null 2>&1; then
  pass "user-key: the addition's OWN keys (enabled, filesystem.denyRead) are gone after deselect"
else
  fail "user-key: the addition's own keys are gone after deselect" "got: $(jq -c '.sandbox' "$S2" 2>/dev/null)"
fi

# ── 4. Linux with no bwrap on PATH → soft-skip with the documented notice ─────
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

# ── 5. idempotent re-run — selecting twice in a row is semantically unchanged ──
# Compared with `jq -S .` (recursive key-sort), not a byte/hash diff: install.sh's
# top-level JSON key ORDER is not itself a stable contract (a pre-existing,
# sandbox-unrelated quirk — the same reordering reproduces with e.g.
# `CT_ADDITIONS="telemetry-off error-reporting-off"` run twice, from the always-on
# rtk-rg/command-guard decoupling rewrite touching `add`'s key insertion order
# ahead of the final merge). What idempotent means for THIS addition is content:
# re-selecting sandbox twice must not grow denyRead, duplicate it, or drift its
# value.
SB4="$(sandbox)"; PROFILE4="$SB4/profile"
install_into "$SB4" "$PROFILE4" "sandbox" >"$SB4/first.log" 2>&1
assert_install_ok "idempotent: first select exits 0" "$SB4/first.log" "$?"
S4="$PROFILE4/settings.json"
first_sorted="$(jq -S . "$S4" 2>/dev/null)"
install_into "$SB4" "$PROFILE4" "sandbox" >"$SB4/second.log" 2>&1
assert_install_ok "idempotent: second select exits 0" "$SB4/second.log" "$?"
second_sorted="$(jq -S . "$S4" 2>/dev/null)"
assert_eq "idempotent: settings.json content unchanged across a repeat select" \
  "$first_sorted" "$second_sorted"

t_summary
