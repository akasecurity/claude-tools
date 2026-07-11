#!/usr/bin/env bash
# tests/test_scn_manifest_deep.sh — MANIFEST + PRUNE SYMMETRY (T2).
#
# For EVERY addition in config/additions.json this drives a full place/prune
# cycle in a sandboxed profile:
#     1. clean install with CT_ADDITIONS=<just that id>
#     2. deselect — re-run with CT_ADDITIONS="" (select none)
# and asserts ZERO residue: the addition's files are gone AND its settings
# contributions (hooks / statusLine / permissions allow+deny / env) are fully
# pruned from settings.json. It also asserts manifest integrity for ALL payload
# keys (including .workflow, which the existing test_manifest.sh does not scan):
# every declared file exists under config/, and no shipped file under any
# deployable category is undeclared.
#
# Fully sandboxed (fake $HOME via sandbox()); never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_manifest_deep:"

INSTALL="$REPO_ROOT/install.sh"

# install_into <home> <ct_additions_value>  — run a non-interactive install with
# an explicit CT_ADDITIONS selection (empty value = select none). Returns rc.
install_into() {
  local home="$1" sel="$2"
  CT_ADDITIONS="$sel" HOME="$home" bash "$INSTALL" --defaults --no-auth-inherit >"$home/install.log" 2>&1
}

# settings_payload_for <id>  — echo the merged additions JSON that this addition
# alone contributes to settings (its .settings file payload, minus $comment).
# Used to know which permission/env entries to look for and to require pruned.
settings_payload_for() {
  local id="$1" setf
  setf="$(jq -r --arg i "$id" '.additions[] | select(.id==$i) | .settings // ""' "$ADDITIONS")"
  if [ -n "$setf" ] && [ -f "$REPO_ROOT/config/$setf" ]; then
    jq 'del(.["$comment"])' "$REPO_ROOT/config/$setf"
  else
    printf '{}'
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Part 1 — MANIFEST integrity across ALL payload keys (incl. .workflow).
# ─────────────────────────────────────────────────────────────────────────────
assert_ok "additions.json is valid JSON" jq -e . "$ADDITIONS"

# Every declared file path (any payload key) exists under config/.
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  assert_file "declared file exists: config/$rel" "$REPO_ROOT/config/$rel"
done < <(jq -r '.additions[] | .skill, .hook, .command, .statusLine, .settings, .workflow | select(.!=null)' "$ADDITIONS")

# No orphans across EVERY deployable category — workflows included (the existing
# manifest test only scans skills/hooks/commands, so a stray workflow file slips
# through). Shared support dirs (hooks/lib) back addons but aren't deployable.
declared="$(jq -r '.additions[] | .skill, .hook, .command, .statusLine, .workflow | select(.!=null)' "$ADDITIONS" | sort -u)"
for cat in skills hooks commands workflows; do
  [ -d "$REPO_ROOT/config/$cat" ] || continue
  for entry in "$REPO_ROOT/config/$cat"/*; do
    [ -e "$entry" ] || continue
    # Shared support dirs + plugin-build assets back the additions but aren't deployable
    # additions themselves (lib = secret-patterns corpus; bun-hook-launch.sh + preflight.sh
    # = plugin-only scripts consumed by tools/build-plugin.sh). Skip them.
    case "$(basename "$entry")" in lib|bun-hook-launch.sh|preflight.sh) continue ;; esac
    rel="$cat/$(basename "$entry")"
    if printf '%s\n' "$declared" | grep -qxF "$rel"; then
      pass "shipped file is declared: $rel"
    else
      fail "orphan (undeclared) file: $rel" "no addition declares it"
    fi
  done
done

# ─────────────────────────────────────────────────────────────────────────────
# Part 2 — per-addition place/prune symmetry.
# For each addition: install it alone, prove its artifacts + settings landed,
# then deselect and prove they are ALL removed.
# ─────────────────────────────────────────────────────────────────────────────
while IFS= read -r id; do
  [ -z "$id" ] && continue

  SB="$(sandbox)"
  PROFILE="$SB/.claude-aka"

  install_into "$SB" "$id"
  rc=$?
  assert_eq "[$id] install (alone) exits 0" "0" "$rc"

  # Collect the file artifacts this addition owns from its manifest entry — EVERY
  # payload key that names a placeable file/dir: hook, command, statusLine, skill,
  # workflow. (settings.* are payload-merge files, not placed in the profile.)
  owned=()
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    owned+=("$PROFILE/$(basename "$(dirname "$rel")")/$(basename "$rel")")
  done < <(jq -r --arg i "$id" '.additions[] | select(.id==$i) | .hook, .command, .statusLine, .skill, .workflow | select(.!=null)' "$ADDITIONS")

  # The settings basename used to register hooks/statusLine (matched by basename
  # in the prune path), and the perm/env payload this addition contributes.
  hook_rel="$(jq -r --arg i "$id" '.additions[] | select(.id==$i) | .hook // ""' "$ADDITIONS")"
  hook_b=""; [ -n "$hook_rel" ] && hook_b="$(basename "$hook_rel")"
  sline_rel="$(jq -r --arg i "$id" '.additions[] | select(.id==$i) | .statusLine // ""' "$ADDITIONS")"; sline_b="$(basename "$sline_rel" 2>/dev/null)"; [ "$sline_rel" = "" ] && sline_b=""
  payload="$(settings_payload_for "$id")"

  S="$PROFILE/settings.json"

  # ── prove placement (where the addition actually places anything) ──
  if [ "${#owned[@]}" -gt 0 ]; then
    for f in "${owned[@]}"; do
      assert_file "[$id] placed artifact present after install: ${f#$PROFILE/}" "$f"
    done
  fi
  # Hook registration present in settings (only when the addition ships a hook
  # that is actually registered — all hook additions register via inline jq).
  if [ -n "$hook_b" ] && [ -f "$S" ]; then
    if jq -e --arg b "$hook_b" '[.. | objects | (.command? // "")] | any(contains($b))' "$S" >/dev/null 2>&1; then
      pass "[$id] hook registered in settings after install"
    else
      # Every shipped hook addition must register. (The old `.requires`/soft-skip
      # tolerance is gone: bun is now a hard dependency — a bun-less host aborts the
      # install before this point, so an unregistered hook here is a real failure.)
      fail "[$id] hook NOT registered in settings after install" "expected command containing $hook_b"
    fi
  fi
  # statusLine present.
  if [ -n "$sline_b" ] && [ -f "$S" ]; then
    assert_lit "[$id] statusLine registered after install" "$sline_b" "$S"
  fi

  # ── deselect: re-run with NOTHING selected ──
  install_into "$SB" ""
  rc=$?
  assert_eq "[$id] deselect re-run exits 0" "0" "$rc"

  # 2a. EVERY owned artifact must be gone.
  for f in "${owned[@]}"; do
    [ -e "$f" ] && fail "[$id] RESIDUE: artifact survived deselect: ${f#$PROFILE/}" "prune left it behind" \
                || pass "[$id] artifact removed on deselect: ${f#$PROFILE/}"
  done

  # 2b. settings residue. If a settings.json exists, none of this addition's
  # contributions may remain.
  if [ -f "$S" ]; then
    # hook registration gone
    if [ -n "$hook_b" ]; then
      if jq -e --arg b "$hook_b" '[.. | objects | (.command? // "")] | any(contains($b))' "$S" >/dev/null 2>&1; then
        fail "[$id] RESIDUE: hook registration survived deselect" "command containing $hook_b still in $S"
      else
        pass "[$id] hook registration pruned on deselect"
      fi
    fi
    # statusLine gone
    if [ -n "$sline_b" ]; then
      assert_nlit "[$id] statusLine pruned on deselect" "$sline_b" "$S"
    fi
    # permission entries (allow/deny/ask) this addition shipped must all be gone.
    while IFS= read -r perm; do
      [ -z "$perm" ] && continue
      assert_nlit "[$id] permission rule pruned: $perm" "$perm" "$S"
    done < <(jq -r '[ (.permissions.allow // [])[], (.permissions.deny // [])[], (.permissions.ask // [])[] ] | .[]' <<<"$payload")
    # env keys this addition shipped must all be gone.
    while IFS= read -r ek; do
      [ -z "$ek" ] && continue
      if jq -e --arg k "$ek" '(.env // {}) | has($k)' "$S" >/dev/null 2>&1; then
        fail "[$id] RESIDUE: env key survived deselect: $ek" "still in .env of $S"
      else
        pass "[$id] env key pruned on deselect: $ek"
      fi
    done < <(jq -r '(.env // {}) | keys[]' <<<"$payload")
  fi

done < <(jq -r '.additions[].id' "$ADDITIONS")

t_summary
