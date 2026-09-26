#!/usr/bin/env bash
# test_egress_config_robustness.sh — two PR-review hardenings for the org-egress path,
# exercised with a web-only install (leak-guard selected, no command-guard):
#   #47-a  A config that fails to SOURCE must not silently ship an empty "tier inactive"
#          sidecar — install warns loudly and still exits 0 (tier inactive until fixed).
#   #47-b  leak-guard has the stale-config detection command-guard also has: when
#          aka-claude-tools.config drifts from the compiled sidecar, leak-guard WARNS
#          (advisory, never blocks). The sidecar's sourceHash is computed with a portable
#          sha256 in install.sh and re-hashed by leak-guard.ts via bun's createHash over
#          the same raw config bytes — implementation-independent, so they agree.
# Fully sandboxed: fake $HOME, throwaway profile; never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_egress_config_robustness:"

# Both guards are .ts now (leak-guard requires bun). Skip if bun is absent — install would
# abort on the leak-guard hard-dependency gate and there'd be no hook to exercise.
if ! command -v bun >/dev/null 2>&1; then
  echo "  note: bun absent — leak-guard requires bun; skipping (SUITE NOT EXERCISED)."
  exit 0
fi
BUN_BIN="$(command -v bun)"

# inst <config-body>  → installs leak-guard (web-only, no command-guard) with the given
# aka-claude-tools.config pre-placed. Sets SB / PROFILE / RC.
inst() {
  SB="$(sandbox)"; touch "$SB/.bashrc"
  PROFILE="$SB/.claude-aka"; mkdir -p "$PROFILE"
  printf '%s\n' "$1" > "$PROFILE/aka-claude-tools.config"
  SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="secure-settings leak-guard" \
    CT_NONINTERACTIVE=1 bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
  RC=$?
}
# run a web query through the installed leak-guard.ts; capture STDERR only.
lg_err() { printf '{"tool_name":"WebSearch","tool_input":{"query":"%s"}}' "$1" \
  | "$BUN_BIN" "$PROFILE/hooks/leak-guard.ts" 2>&1 >/dev/null; }

# ── #47-a: a config that cannot be sourced → loud warning, NOT a silent disable ──────
inst 'CT_EGRESS_PATTERNS="unterminated'   # unclosed quote → source fails (syntax error)
assert_eq   "source-error config: install still exits 0" "0" "$RC"
assert_grep "source-error config: warns the org tier is inactive (not silent)" \
  'could not be sourced|org-marker tier is INACTIVE' "$SB/log"
assert_ok   "source-error config: sidecar pattern is empty (tier inactive)" \
  bash -c "jq -e '.pattern==\"\"' '$PROFILE/hooks/lib/org-egress.json' >/dev/null"

# ── #47-a edge: a config that sets the pattern but ENDS on a non-zero command sourced
#    fine — it must NOT trigger the "tier inactive" warning, and the pattern MUST compile.
inst $'CT_EGRESS_PATTERNS="acme\\.internal"\nfalse'
assert_eq   "pattern-set-but-nonzero-exit config: install exits 0" "0" "$RC"
# NOTE: this fixture never sets CT_MCP_ALLOW/CT_MCP_DENY/CT_TRUSTED_BOOTSTRAP_URLS, so
# compile_mcp_policy_sidecar/compile_bootstrap_sidecar (also sourcing this same config,
# since mcp-policy.json rides on the leak-guard gate too) correctly warn THEIR OWN
# "could not be sourced" for THEIR OWN tiers — a bare substring check would now catch
# that unrelated, legitimate warning, so this asserts the ORG-EGRESS message specifically.
assert_ngrep "pattern-set-but-nonzero-exit: NO misleading org-egress inactive warning" \
  'org-egress patterns NOT compiled' "$SB/log"
assert_ok   "pattern-set-but-nonzero-exit: pattern still compiled" \
  bash -c "jq -e '.pattern|contains(\"acme\")' '$PROFILE/hooks/lib/org-egress.json' >/dev/null"

# ── #47-a (cross-vendor catch): a real SYNTAX error AFTER the pattern is set must still
#    be surfaced — never hidden just because a pattern happened to compile first. ──
inst $'CT_EGRESS_PATTERNS="acme\\.internal"\n"unterminated'
assert_eq   "syntax-error-after-pattern: install exits 0" "0" "$RC"
assert_grep "syntax-error-after-pattern: source failure is surfaced, not hidden" \
  'could not be sourced|sourced with an error' "$SB/log"

# ── #47-b: install populates a real sha256 sourceHash the .ts guard can re-derive ───────
inst 'CT_EGRESS_PATTERNS="acme\.internal"'
assert_eq   "valid config: install exits 0" "0" "$RC"
SC="$PROFILE/hooks/lib/org-egress.json"
assert_ok   "sidecar carries a 64-char sha256 sourceHash" \
  bash -c "jq -e '(.sourceHash|type==\"string\") and (.sourceHash|length==64)' '$SC' >/dev/null"

# unchanged config → leak-guard emits NO stale warning
err="$(lg_err "hello world")"
case "$err" in
  *"changed since install"*|*STALE*) fail "unchanged config: no stale warning" "got: $err" ;;
  *) pass "unchanged config: no stale warning" ;;
esac

# drift the config → leak-guard WARNS it is stale
printf '\n# operator edited the config after install\n' >> "$PROFILE/aka-claude-tools.config"
err="$(lg_err "hello world")"
case "$err" in
  *"changed since install"*) pass "drifted config: leak-guard emits a stale-config warning" ;;
  *) fail "drifted config: leak-guard emits a stale-config warning" "got: $err" ;;
esac

# advisory only — a stale config must NEVER change the verdict (benign query still allowed)
printf '{"tool_name":"WebSearch","tool_input":{"query":"a benign query"}}' \
  | "$BUN_BIN" "$PROFILE/hooks/leak-guard.ts" >/dev/null 2>&1; rc=$?
assert_eq "stale config is advisory: benign query still allowed (exit 0, not blocked)" "0" "$rc"

t_summary
