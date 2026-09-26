#!/usr/bin/env bash
# Manifest integrity — the #1 contributor mistake is adding a file but forgetting
# the additions.json entry (or vice versa). This catches both, before review.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_manifest:"

assert_ok   "additions.json is valid JSON" jq -e . "$ADDITIONS"

# ids unique
n_ids=$(jq -r '.additions[].id' "$ADDITIONS" | wc -l | tr -d ' ')
n_uniq=$(jq -r '.additions[].id' "$ADDITIONS" | sort -u | wc -l | tr -d ' ')
assert_eq   "addition ids are unique" "$n_ids" "$n_uniq"

# Every declared file path (skill/hook/command/statusLine/settings/workflow) exists under config/.
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  assert_file "declared file exists: config/$rel" "$REPO_ROOT/config/$rel"
done < <(jq -r '.additions[] | .skill, .hook, .command, .statusLine, .settings, .workflow | select(.!=null)' "$ADDITIONS")

# No orphans: every top-level entry under config/{skills,hooks,commands,workflows}
# must be declared by some addition. (Settings/JSON live in config/ root, not scanned.)
declared="$(jq -r '.additions[] | .skill, .hook, .command, .statusLine, .workflow | select(.!=null)' "$ADDITIONS" | sort -u)"
for cat in skills hooks commands workflows; do
  [ -d "$REPO_ROOT/config/$cat" ] || continue
  for entry in "$REPO_ROOT/config/$cat"/*; do
    [ -e "$entry" ] || continue
    # Shared support dirs + plugin-build assets back the additions but aren't deployable
    # additions themselves (lib = guards' secret-patterns corpus; bun-hook-launch.sh +
    # preflight.sh = plugin-only scripts consumed by tools/build-plugin.sh). Skip them.
    case "$(basename "$entry")" in lib|bun-hook-launch.sh|preflight.sh) continue ;; esac
    rel="$cat/$(basename "$entry")"
    if printf '%s\n' "$declared" | grep -qxF "$rel"; then
      pass "shipped file is declared: $rel"
    else
      fail "orphan (undeclared) file: $rel" "add an addition to additions.json or remove the file"
    fi
  done
done

# llms.txt catalogs the additions for agents in the form "`<id>` (<blurb>)". Every id named that way
# must still exist in the manifest, or a retired addition keeps being offered (and CT_ADDITIONS
# dies on it).
while IFS= read -r cid; do
  jq -e --arg id "$cid" '.additions[] | select(.id == $id)' "$ADDITIONS" >/dev/null \
    && pass "llms.txt catalog id exists in additions.json: $cid" \
    || fail "llms.txt catalog id exists in additions.json: $cid" "not in config/additions.json"
done < <(grep -E '^(On by default|Opt-in):|Opt-in:' "$REPO_ROOT/llms.txt" | grep -oE '`[a-z][a-z0-9-]*` \(' | tr -d '`( ' | sort -u)

t_summary
