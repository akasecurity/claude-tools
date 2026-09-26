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
#   5. OWNERSHIP, not silent clobber: once selected, sandbox.enabled belongs to this
#      addition like any other kit-managed setting — a manually-edited `false` on a
#      re-apply (still selected) is set back to `true`, but never SILENTLY: a warn line
#      names the value it overwrote and how to actually turn the sandbox off.
#   6. Linux with no `bwrap` on PATH → skipped with the documented notice, install
#      still exits 0 (soft-skip: opt-in addition, not a fatal dependency).
#   7. idempotent re-run (select twice in a row) produces semantically unchanged
#      settings, and does NOT corrupt the stash (a second select must not re-stash the
#      kit's own prior write as if it were a fresh user value), and does NOT print the
#      ownership warning when nothing was manually changed.
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

# ── 5. ownership: a manual edit back to false, while still SELECTED, is set back to
#      true — but never silently. Select once (clean), THEN hand-edit sandbox.enabled to
#      false (simulating a user turning it off without deselecting the addition), THEN
#      re-apply with the SAME selection — the fix must warn, by value, and restore true.
SB6="$(sandbox)"; PROFILE6="$SB6/profile"
install_into "$SB6" "$PROFILE6" "sandbox" >"$SB6/select.log" 2>&1
assert_install_ok "ownership: initial select exits 0" "$SB6/select.log" "$?"
S6="$PROFILE6/settings.json"
jq -e '.sandbox.enabled == true' "$S6" >/dev/null 2>&1 \
  && pass "ownership: sandbox.enabled is true after the initial select" \
  || fail "ownership: sandbox.enabled is true after the initial select" "got: $(jq -c '.sandbox' "$S6" 2>/dev/null)"
# Hand-edit: still selected, but the user flips it off directly in settings.json.
tmp6="$(mktemp)"; jq '.sandbox.enabled = false' "$S6" > "$tmp6" && mv "$tmp6" "$S6"
install_into "$SB6" "$PROFILE6" "sandbox" >"$SB6/reapply.log" 2>&1
assert_install_ok "ownership: re-apply (still selected) exits 0" "$SB6/reapply.log" "$?"
assert_lit "ownership: warns by value, names how to actually turn it off" \
  "sandbox: sandbox.enabled was false; set back to true because the sandbox addition is selected (deselect it to turn the sandbox off)." \
  "$SB6/reapply.log"
jq -e '.sandbox.enabled == true' "$S6" >/dev/null 2>&1 \
  && pass "ownership: re-apply sets sandbox.enabled back to true (never silently left false)" \
  || fail "ownership: re-apply sets sandbox.enabled back to true" "got: $(jq -c '.sandbox' "$S6" 2>/dev/null)"
# Never treated as a genuine "prior user value" to stash-and-restore — ownership means
# the kit's OWN value, not a value it owes the user a restore of.
assert_nlit "ownership: the hand-edited false is NOT stashed as a prior value" \
  '_aka_prior_sandbox_enabled' "$S6"

# ── 6. Linux with no bwrap on PATH → soft-skip with the documented notice ─────
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

# ── 7. idempotent re-run — selecting twice in a row is semantically unchanged,
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
assert_nlit "idempotent: no ownership warning when nothing was manually changed" \
  "sandbox.enabled was" "$SB4/second.log"
# And deselecting after two selects fully removes it (nothing was ever a genuine
# pre-existing user value here) rather than "restoring" the kit's own true.
install_into "$SB4" "$PROFILE4" "" >"$SB4/deselect.log" 2>&1
assert_install_ok "idempotent: deselect after repeat-select exits 0" "$SB4/deselect.log" "$?"
assert_nlit "idempotent: deselect after repeat-select removes sandbox.enabled entirely" \
  '"sandbox"' "$S4"

# ── 8. never-selected: a user's OWN sandbox.enabled survives every apply ─────────
#      The deselect loop runs prune for every UNSELECTED id on every apply, so the
#      prune must be gated on the kit having set the value (the sandbox_installed meta
#      flag or the stash) — otherwise an apply that merely adds other additions would
#      delete a value the user set by hand and the kit never touched.
for _uv in true false; do
  SB8="$(sandbox)"; PROFILE8="$SB8/profile"; mkdir -p "$PROFILE8"
  printf '{"sandbox":{"enabled":%s}}\n' "$_uv" > "$PROFILE8/settings.json"
  install_into "$SB8" "$PROFILE8" "secure-settings telemetry-off" >"$SB8/apply.log" 2>&1
  assert_install_ok "never-selected ($_uv): apply with other additions exits 0" "$SB8/apply.log" "$?"
  if jq -e --argjson v "$_uv" '.sandbox.enabled == $v' "$PROFILE8/settings.json" >/dev/null 2>&1; then
    pass "never-selected ($_uv): the user's sandbox.enabled=$_uv is kept"
  else
    fail "never-selected ($_uv): the user's sandbox.enabled=$_uv is kept" "got: $(jq -c '.sandbox // "MISSING"' "$PROFILE8/settings.json" 2>/dev/null)"
  fi
  assert_nlit "never-selected ($_uv): no 'Uninstalled sandbox' line" "Uninstalled 'sandbox'" "$SB8/apply.log"
  # A second apply (still never selected) keeps it too.
  install_into "$SB8" "$PROFILE8" "secure-settings" >"$SB8/apply2.log" 2>&1
  assert_install_ok "never-selected ($_uv): second apply exits 0" "$SB8/apply2.log" "$?"
  jq -e --argjson v "$_uv" '.sandbox.enabled == $v' "$PROFILE8/settings.json" >/dev/null 2>&1 \
    && pass "never-selected ($_uv): still kept after a second apply" \
    || fail "never-selected ($_uv): still kept after a second apply" "got: $(jq -c '.sandbox // "MISSING"' "$PROFILE8/settings.json" 2>/dev/null)"
done

# ── 9. select → deselect removes the kit value and clears the meta flag; a later
#      hand-set value is then the user's own and survives further applies ─────────
SB9="$(sandbox)"; PROFILE9="$SB9/profile"; S9="$PROFILE9/settings.json"
install_into "$SB9" "$PROFILE9" "secure-settings sandbox" >"$SB9/select.log" 2>&1
assert_install_ok "select-deselect: select exits 0" "$SB9/select.log" "$?"
install_into "$SB9" "$PROFILE9" "secure-settings" >"$SB9/deselect.log" 2>&1
assert_install_ok "select-deselect: deselect exits 0" "$SB9/deselect.log" "$?"
assert_nlit "select-deselect: the kit's sandbox.enabled is removed" '"sandbox"' "$S9"
assert_lit "select-deselect: meta flag cleared" "sandbox_installed=0" "$PROFILE9/.aka-claude-tools-meta"
tmp9="$(mktemp)"; jq '.sandbox.enabled = true' "$S9" > "$tmp9" && mv "$tmp9" "$S9"
install_into "$SB9" "$PROFILE9" "secure-settings" >"$SB9/after.log" 2>&1
assert_install_ok "select-deselect: later apply exits 0" "$SB9/after.log" "$?"
jq -e '.sandbox.enabled == true' "$S9" >/dev/null 2>&1 \
  && pass "select-deselect: a value hand-set after deselect is the user's own and survives" \
  || fail "select-deselect: a value hand-set after deselect survives" "got: $(jq -c '.sandbox // "MISSING"' "$S9" 2>/dev/null)"

# ── 10. select → deselect → reselect still stashes the user's prior value ─────────
SB10="$(sandbox)"; PROFILE10="$SB10/profile"; S10="$PROFILE10/settings.json"; mkdir -p "$PROFILE10"
printf '{"sandbox":{"enabled":false}}\n' > "$S10"
install_into "$SB10" "$PROFILE10" "sandbox" >"$SB10/s1.log" 2>&1
assert_install_ok "reselect: first select exits 0" "$SB10/s1.log" "$?"
install_into "$SB10" "$PROFILE10" "" >"$SB10/d1.log" 2>&1
assert_install_ok "reselect: deselect exits 0" "$SB10/d1.log" "$?"
jq -e '.sandbox.enabled == false' "$S10" >/dev/null 2>&1 \
  && pass "reselect: deselect restored the user's false" \
  || fail "reselect: deselect restored the user's false" "got: $(jq -c '.' "$S10" 2>/dev/null)"
install_into "$SB10" "$PROFILE10" "sandbox" >"$SB10/s2.log" 2>&1
assert_install_ok "reselect: reselect exits 0" "$SB10/s2.log" "$?"
jq -e '.sandbox.enabled == true and ._aka_prior_sandbox_enabled == false' "$S10" >/dev/null 2>&1 \
  && pass "reselect: true while selected, the user's false stashed again" \
  || fail "reselect: true while selected, the user's false stashed again" "got: $(jq -c '.' "$S10" 2>/dev/null)"
assert_lit "reselect: meta flag set again" "sandbox_installed=1" "$PROFILE10/.aka-claude-tools-meta"
install_into "$SB10" "$PROFILE10" "" >"$SB10/d2.log" 2>&1
assert_install_ok "reselect: second deselect exits 0" "$SB10/d2.log" "$?"
jq -e '.sandbox.enabled == false and (has("_aka_prior_sandbox_enabled")|not)' "$S10" >/dev/null 2>&1 \
  && pass "reselect: second deselect restores false and drops the stash" \
  || fail "reselect: second deselect restores false and drops the stash" "got: $(jq -c '.' "$S10" 2>/dev/null)"

t_summary
