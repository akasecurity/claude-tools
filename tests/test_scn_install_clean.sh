#!/usr/bin/env bash
# Scenario T5 (scn_install_clean): INSTALL/clean — fresh EMPTY non-default target
# dir, --defaults, RECOMMENDED additions (selected via --defaults driving the menu
# at each addition's recommended default — NOT via an explicit CT_ADDITIONS list).
#
# Asserts the user-visible product of a from-zero clean install:
#   • every recommended addition's declared artifact lands in the profile (remapped),
#   • settings.json is valid JSON AND the secure denies from settings.base.json are
#     present (this install pulls in secure-settings, a recommended addition),
#   • an alias block is written to the shell rc — a NON-default config dir
#     ($HOME/.claude-aka, not Claude's ~/.claude) MUST get an alias, pointing at
#     this profile,
#   • every deployed kit-owned hook carries the managed-hook self-clean marker,
#   • no maintainer-only "$comment" key leaks into the merged settings.json.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit, default
# $HOME/.claude-aka target. Never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_clean:"

SB="$(sandbox)"
RC="$SB/.bashrc"; touch "$RC"          # deterministic rc target for the alias block
PROFILE="$SB/.claude-aka"              # default of --defaults; non-default Claude dir
out="$SB/install.log"

# Fresh & empty: nothing pre-seeded in the sandbox HOME beyond the rc stub.
# --defaults (CT_NONINTERACTIVE) with CT_ADDITIONS UNSET means the menu auto-takes
# each addition's recommended default → the recommended set is installed. SHELL=bash
# + an existing .bashrc make detect_shell_rc resolve to $RC deterministically.
# Hermetic PATH (install_path): the installer refuses/renames a launcher name that
# is already a PATH command, so an operator's real `claude-aka` shim must not leak in.
PATH="$(install_path)" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$out" 2>&1
rc=$?

assert_eq   "install.sh exits 0" "0" "$rc"
assert_file "profile dir created" "$PROFILE"
assert_grep "install reported done" 'Done|ready' "$out"

# ── settings.json valid + secure denies present ──────────────────────────────
assert_ok   "settings.json is valid JSON" jq -e . "$PROFILE/settings.json"

# secure-settings is recommended, so its deny list (settings.base.json) must be
# merged into the deployed settings. Assert the array is non-empty AND that a
# representative high-value deny from the base template is actually present, so a
# silently-empty or unmerged deny list fails the probe.
assert_ok   "permissions.deny is a non-empty array" \
  bash -c "jq -e '((.permissions.deny // []) | type == \"array\") and ((.permissions.deny // []) | length > 0)' '$PROFILE/settings.json' >/dev/null"
# Every deny rule shipped by the base template must survive the merge into the
# deployed settings — dynamic, so it keeps protecting as the deny set evolves.
while IFS= read -r d; do
  [ -z "$d" ] && continue
  assert_ok "deny present in merged settings: $d" \
    bash -c "jq -e --arg d \"$d\" '((.permissions.deny // []) | index(\$d)) != null' '$PROFILE/settings.json' >/dev/null"
done < <(jq -r '.permissions.deny[]?' "$REPO_ROOT/config/settings.base.json")

# ── every recommended addition's artifact is placed (path-remapped) ──────────
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  assert_file "recommended artifact deployed (remapped): $rel" "$PROFILE/$rel"
done < <(jq -r '.additions[] | select(.recommended==true) | .skill, .hook, .command | select(.!=null)' "$ADDITIONS")

# ── managed-hook marker on every deployed kit-owned hook ─────────────────────
# Self-clean on later rebuilds keys off the aka-claude-tools:managed-hook marker;
# every kit hook that landed in the profile must carry it. (A hook the kit ships
# without the marker would be orphaned by a future deselect — a real defect.)
hook_count=0
if [ -d "$PROFILE/hooks" ]; then
  while IFS= read -r hf; do
    hook_count=$((hook_count+1))
    assert_lit "deployed hook carries managed-hook marker: $(basename "$hf")" \
      "aka-claude-tools:managed-hook" "$hf"
  done < <(find "$PROFILE/hooks" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.ts' \) 2>/dev/null)
fi
assert_ok "at least one kit hook was deployed" bash -c "[ '$hook_count' -gt 0 ]"

# ── alias block written to shell rc; points at THIS non-default profile ──────
# Default launcher name is `claude-aka` (bare `aka` is reserved for the ai-tc CLI).
assert_lit  "managed alias block opener in rc" \
  ">>> aka-claude-tools managed: claude-aka" "$RC"
assert_lit  "alias defines the 'claude-aka' launcher" \
  "alias claude-aka=" "$RC"
assert_lit  "alias points CLAUDE_CONFIG_DIR at this profile" \
  "CLAUDE_CONFIG_DIR=\"$PROFILE\"" "$RC"
assert_file "launcher shim placed and on the profile's bin/" "$PROFILE/bin/claude-aka"
assert_ok   "launcher shim is executable" test -x "$PROFILE/bin/claude-aka"
assert_lit  "rc block adds the profile bin dir to PATH (guarded)" \
  "export PATH=\"$PROFILE/bin:\$PATH\"" "$RC"
n_block=$(grep -c '>>> aka-claude-tools managed' "$RC")
assert_eq   "exactly one managed alias block in rc" "1" "$n_block"

# Non-default install: nothing should reference Claude's DEFAULT ~/.claude dir,
# and that dir must never be created.
assert_nlit "rc never references default ~/.claude dir" "$SB/.claude/" "$RC"
[ -e "$SB/.claude" ] && fail "default ~/.claude never created" "it exists" \
                     || pass "default ~/.claude never created"

# ── no maintainer-only \$comment keys leaked into deployed settings ──────────
assert_ok   "no \$comment keys in deployed settings" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$PROFILE/settings.json' >/dev/null"

t_summary
