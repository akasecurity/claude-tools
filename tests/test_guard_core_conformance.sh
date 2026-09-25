#!/usr/bin/env bash
# Runs guard-core's conformance fixtures (vendored at tests/fixtures/guard-core-conformance.json,
# see tools/vendor-guard-core.sh) against claude-tools' REAL hooks — command-guard.ts, rtk-safe.ts
# and leak-guard.ts — each fixture in its own hermetic sandbox profile. This complements
# guard-core's own in-process conformance.test.ts (which exercises the pure core functions
# directly): here every fixture goes through the adapter I/O layer (stdin JSON, env, exit code,
# stdout) exactly as Claude Code would invoke it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fixtures="tests/fixtures/guard-core-conformance.json"
[ -f "$fixtures" ] || { echo "FAIL: no $fixtures — run tools/vendor-guard-core.sh"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Shadow PATH without trufflehog — assumes.scanner:"clean" means trufflehog is absent, so the
# credential-shape regex tier (not the trufflehog tier) is what's under test. Same technique as
# tools/capture-guard-golden.ts's buildPathNoTrufflehog: replace any PATH entry that contains a
# trufflehog binary with a symlink farm of everything else in that dir, so co-located tools
# (bun, rtk) on the same PATH entry stay resolvable.
build_path_no_trufflehog() {
  local dirs d shadow e base out=()
  IFS=':' read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -z "$d" ] && continue
    if [ -x "$d/trufflehog" ]; then
      shadow="$(mktemp -d "$tmp/shadow.XXXXXX")"
      for e in "$d"/*; do
        [ -e "$e" ] || continue
        base="$(basename "$e")"
        [ "$base" = "trufflehog" ] && continue
        ln -sf "$e" "$shadow/$base" 2>/dev/null || true
      done
      out+=("$shadow")
    else
      out+=("$d")
    fi
  done
  ( IFS=':'; echo "${out[*]}" )
}
PATH_CLEAN="$(build_path_no_trufflehog)"

# A sandbox copy of the real hooks — never run against the repo's own config/hooks.
hooks="$tmp/hooks"; cp -R config/hooks "$hooks"

# Two sandbox profiles: bare (no ai-tc) and ai-tc stubbed in per Task 6's shape.
bare="$tmp/bare"; mkdir -p "$bare"
aitc="$tmp/aitc"; mkdir -p "$aitc/plugins/cache/akasecurity/ai-tc/1"
printf '%s' '{"plugins":{"ai-tc@akasecurity":[{}]}}' > "$aitc/plugins/installed_plugins.json"
printf '%s' '{"enabledPlugins":{"ai-tc@akasecurity":true}}' > "$aitc/settings.json"
# A decoy HOME with no .claude of its own — every case passes CLAUDE_CONFIG_DIR explicitly,
# so a case that silently fell back to $HOME/.claude instead would show up as a real failure.
decoy_home="$tmp/decoy-home"; mkdir -p "$decoy_home"

have_rtk=0
command -v rtk >/dev/null 2>&1 && have_rtk=1

fails=0
n="$(jq length "$fixtures")"
for ((i = 0; i < n; i++)); do
  fx="$(jq -c ".[$i]" "$fixtures")"
  id="$(jq -r .id <<<"$fx")"
  surface="$(jq -r .surface <<<"$fx")"
  tool="$(jq -r .tool <<<"$fx")"
  input="$(jq -r .input <<<"$fx")"
  aitc_ctx="$(jq -r '.ctx.aitc // false' <<<"$fx")"
  expect="$(jq -r .expect <<<"$fx")"
  scanner="$(jq -r '.assumes.scanner // "clean"' <<<"$fx")"
  requires_rtk="$(jq -r '([.requires[]? | select(startswith("rtk"))] | length) > 0' <<<"$fx")"

  if [ "$requires_rtk" = "true" ] && [ "$have_rtk" -eq 0 ]; then
    echo "  SKIP $id (requires rtk, not installed)"
    continue
  fi

  profile="$bare"
  [ "$aitc_ctx" = "true" ] && profile="$aitc"

  path="$PATH"
  [ "$scanner" = "clean" ] && path="$PATH_CLEAN"

  case "$tool" in
    Bash)      hook_input="$(jq -cn --arg c "$input" '{tool_name:"Bash",tool_input:{command:$c}}')" ;;
    WebSearch) hook_input="$(jq -cn --arg q "$input" '{tool_name:"WebSearch",tool_input:{query:$q}}')" ;;
    WebFetch)  hook_input="$(jq -cn --arg u "$input" '{tool_name:"WebFetch",tool_input:{url:$u}}')" ;;
    *) echo "  FAIL $id: unrecognised fixture tool '$tool'"; fails=$((fails + 1)); continue ;;
  esac

  outcome=""
  if [ "$surface" = "bash" ]; then
    set +e
    printf '%s' "$hook_input" \
      | CLAUDE_CONFIG_DIR="$profile" HOME="$decoy_home" PATH="$path" bun "$hooks/command-guard.ts" \
      >"$tmp/cg.out" 2>"$tmp/cg.err"
    cg_exit=$?
    set -e
    if [ "$cg_exit" -eq 2 ]; then
      outcome=block
    else
      set +e
      rtk_out="$(printf '%s' "$hook_input" \
        | CLAUDE_CONFIG_DIR="$profile" HOME="$decoy_home" PATH="$path" bun "$hooks/rtk-safe.ts" 2>"$tmp/rtk.err")"
      set -e
      if grep -q updatedInput <<<"$rtk_out"; then outcome=rewrite; else outcome=allow; fi
    fi
  else
    set +e
    printf '%s' "$hook_input" \
      | CLAUDE_CONFIG_DIR="$profile" HOME="$decoy_home" PATH="$path" bun "$hooks/leak-guard.ts" \
      >"$tmp/lg.out" 2>"$tmp/lg.err"
    lg_exit=$?
    set -e
    if [ "$lg_exit" -eq 2 ]; then outcome=block; else outcome=allow; fi
  fi

  if [ "$outcome" = "$expect" ]; then
    echo "  ok   $id -> $outcome"
  else
    echo "  FAIL $id: want $expect, got $outcome"
    fails=$((fails + 1))
  fi
done

[ "$fails" -eq 0 ] && echo PASS || { echo "FAIL: $fails fixture(s)"; exit 1; }
