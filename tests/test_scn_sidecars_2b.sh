#!/usr/bin/env bash
# test_scn_sidecars_2b.sh — install-time compilation + STRICT validation of the two
# 2b surface sidecars: hooks/lib/mcp-policy.json (CT_MCP_ALLOW / CT_MCP_DENY) and
# hooks/lib/trusted-bootstrap.json (CT_TRUSTED_BOOTSTRAP_URLS). Modeled on
# test_sidecar_compile.sh (org-egress): the installer compiles the user's shell
# config into inert JSON no hook ever sources; invalid input dies naming the key.
#
# Ownership (see install.sh's compile_mcp_policy_sidecar / compile_bootstrap_sidecar
# call sites): mcp-policy.json is owned by mcp-guard alone; trusted-bootstrap.json is
# owned by command-guard alone. Each is placed only when its owner is selected and
# removed when its owner is deselected, independently of the shared egress libs.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_sidecars_2b:"

if ! command -v bun >/dev/null 2>&1; then
  echo "  note: bun absent — command-guard is bun-gated; sidecar tests skipped."
  exit 0
fi

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# inst <CT_ADDITIONS> [config-body]  → fresh sandbox + profile, optional pre-placed
# aka-claude-tools.config, then a non-interactive install. Sets RC / SB / PROFILE.
inst() {
  local additions="$1"
  SB="$(sandbox)"; touch "$SB/.bashrc"
  PROFILE="$SB/.claude-aka"; mkdir -p "$PROFILE"
  if [ "$#" -ge 2 ]; then printf '%s\n' "$2" > "$PROFILE/aka-claude-tools.config"; fi
  SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="$additions" CT_NONINTERACTIVE=1 \
    bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
  RC=$?
}

MP=""  # set per-inst below: $PROFILE/hooks/lib/mcp-policy.json
TB=""  # set per-inst below: $PROFILE/hooks/lib/trusted-bootstrap.json

# ── (a) no config, no guard selected → hooks/lib never placed → neither sidecar ──
inst "secure-settings"
assert_ok "(a) no-guard install succeeds" bash -c "[ $RC -eq 0 ]"
[ -e "$PROFILE/hooks/lib/mcp-policy.json" ] \
  && fail "(a) no config: mcp-policy.json does not exist" "it exists" \
  || pass "(a) no config: mcp-policy.json does not exist"
[ -e "$PROFILE/hooks/lib/trusted-bootstrap.json" ] \
  && fail "(a) no config: trusted-bootstrap.json does not exist" "it exists" \
  || pass "(a) no config: trusted-bootstrap.json does not exist"

# ── (b) keys set → both sidecars carry the parsed arrays + a matching sourceHash ──
inst "command-guard mcp-guard" 'CT_MCP_ALLOW="github,linear"
CT_MCP_DENY="bad"
CT_TRUSTED_BOOTSTRAP_URLS="https://get.example.dev/install/ https://sh.rustup.rs/"'
assert_ok "(b) valid config: install succeeds" bash -c "[ $RC -eq 0 ]"
MP="$PROFILE/hooks/lib/mcp-policy.json"; TB="$PROFILE/hooks/lib/trusted-bootstrap.json"
assert_file "(b) mcp-policy.json written" "$MP"
assert_file "(b) trusted-bootstrap.json written" "$TB"
assert_ok "(b) mcp-policy.json is valid JSON" jq -e . "$MP"
assert_ok "(b) trusted-bootstrap.json is valid JSON" jq -e . "$TB"
assert_ok "(b) allow == [github, linear]" \
  bash -c "jq -e '.allow == [\"github\",\"linear\"]' '$MP' >/dev/null"
assert_ok "(b) deny == [bad]" \
  bash -c "jq -e '.deny == [\"bad\"]' '$MP' >/dev/null"
assert_ok "(b) rules == the two parsed host/pathPrefix entries" \
  bash -c "jq -e '.rules == [{\"host\":\"get.example.dev\",\"pathPrefix\":\"/install/\"},{\"host\":\"sh.rustup.rs\",\"pathPrefix\":\"/\"}]' '$TB' >/dev/null"
EXPECT_HASH="$(sha "$PROFILE/aka-claude-tools.config")"
assert_ok "(b) mcp-policy.json sourceHash == sha256_file(config)" \
  bash -c "[ \"\$(jq -r .sourceHash '$MP')\" = \"$EXPECT_HASH\" ]"
assert_ok "(b) trusted-bootstrap.json sourceHash == sha256_file(config)" \
  bash -c "[ \"\$(jq -r .sourceHash '$TB')\" = \"$EXPECT_HASH\" ]"

# ── (c) invalid input dies, naming the key ──────────────────────────────────────
inst "command-guard mcp-guard" 'CT_MCP_ALLOW="bad name"'
assert_ok "(c) invalid server name (space) aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(c) invalid server name: dies naming CT_MCP_ALLOW" 'CT_MCP_ALLOW' "$SB/log"

inst "command-guard mcp-guard" 'CT_MCP_DENY="bad!name"'
assert_ok "(c) invalid server name (punctuation) aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(c) invalid server name: dies naming CT_MCP_DENY" 'CT_MCP_DENY' "$SB/log"

inst "command-guard mcp-guard" 'CT_TRUSTED_BOOTSTRAP_URLS="http://get.example.dev/install/"'
assert_ok "(c) http:// (not https) aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(c) http://: dies naming CT_TRUSTED_BOOTSTRAP_URLS" 'CT_TRUSTED_BOOTSTRAP_URLS' "$SB/log"

inst "command-guard mcp-guard" 'CT_TRUSTED_BOOTSTRAP_URLS="https://get.example.dev/install"'
assert_ok "(c) missing trailing slash aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(c) missing trailing slash: dies naming CT_TRUSTED_BOOTSTRAP_URLS" 'CT_TRUSTED_BOOTSTRAP_URLS' "$SB/log"

inst "command-guard mcp-guard" 'CT_TRUSTED_BOOTSTRAP_URLS="https://get.example.dev/install/?x=1"'
assert_ok "(c) URL containing ? aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(c) URL containing ?: dies naming CT_TRUSTED_BOOTSTRAP_URLS" 'CT_TRUSTED_BOOTSTRAP_URLS' "$SB/log"

inst "command-guard mcp-guard" 'CT_TRUSTED_BOOTSTRAP_URLS="https://get.example.dev/inst#all/"'
assert_ok "(c) URL containing # aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(c) URL containing #: dies naming CT_TRUSTED_BOOTSTRAP_URLS" 'CT_TRUSTED_BOOTSTRAP_URLS' "$SB/log"

inst "command-guard mcp-guard" 'CT_TRUSTED_BOOTSTRAP_URLS="https://get.example.dev/{install}/"'
assert_ok "(c) URL containing { aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(c) URL containing {: dies naming CT_TRUSTED_BOOTSTRAP_URLS" 'CT_TRUSTED_BOOTSTRAP_URLS' "$SB/log"

inst "command-guard mcp-guard" 'CT_TRUSTED_BOOTSTRAP_URLS="https://user@get.example.dev/install/"'
assert_ok "(c) URL with userinfo aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(c) userinfo: dies naming CT_TRUSTED_BOOTSTRAP_URLS" 'CT_TRUSTED_BOOTSTRAP_URLS' "$SB/log"

inst "command-guard mcp-guard" 'CT_TRUSTED_BOOTSTRAP_URLS="https://get.example.dev:443/install/"'
assert_ok "(c) URL with a port aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(c) port: dies naming CT_TRUSTED_BOOTSTRAP_URLS" 'CT_TRUSTED_BOOTSTRAP_URLS' "$SB/log"

# ── (d) keys set to empty → empty arrays ────────────────────────────────────────
inst "command-guard mcp-guard" 'CT_MCP_ALLOW=""
CT_MCP_DENY=""
CT_TRUSTED_BOOTSTRAP_URLS=""'
assert_ok "(d) empty-keys install succeeds" bash -c "[ $RC -eq 0 ]"
MP="$PROFILE/hooks/lib/mcp-policy.json"; TB="$PROFILE/hooks/lib/trusted-bootstrap.json"
assert_ok "(d) allow == []" bash -c "jq -e '.allow == []' '$MP' >/dev/null"
assert_ok "(d) deny == []"  bash -c "jq -e '.deny == []' '$MP' >/dev/null"
assert_ok "(d) rules == []" bash -c "jq -e '.rules == []' '$TB' >/dev/null"

# ── (e) deselecting every guard removes both sidecars along with the rest of lib/ ──
inst "command-guard mcp-guard" 'CT_MCP_ALLOW="github"
CT_TRUSTED_BOOTSTRAP_URLS="https://get.example.dev/install/"'
assert_ok "(e) initial command-guard install succeeds" bash -c "[ $RC -eq 0 ]"
assert_file "(e) mcp-policy.json present before deselect" "$PROFILE/hooks/lib/mcp-policy.json"
assert_file "(e) trusted-bootstrap.json present before deselect" "$PROFILE/hooks/lib/trusted-bootstrap.json"

# Re-run the SAME profile with no guard selected at all.
SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="secure-settings" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log2" 2>&1
RC2=$?
assert_ok "(e) deselect-all-guards re-run succeeds" bash -c "[ $RC2 -eq 0 ]"
[ -e "$PROFILE/hooks/lib/mcp-policy.json" ] \
  && fail "(e) mcp-policy.json removed on deselect" "still present" \
  || pass "(e) mcp-policy.json removed on deselect"
[ -e "$PROFILE/hooks/lib/trusted-bootstrap.json" ] \
  && fail "(e) trusted-bootstrap.json removed on deselect" "still present" \
  || pass "(e) trusted-bootstrap.json removed on deselect"
[ -e "$PROFILE/hooks/lib/org-egress.json" ] \
  && fail "(e) org-egress.json removed on deselect" "still present" \
  || pass "(e) org-egress.json removed on deselect"
[ -e "$PROFILE/hooks/lib/secret-patterns.json" ] \
  && fail "(e) secret-patterns.json removed on deselect" "still present" \
  || pass "(e) secret-patterns.json removed on deselect"
[ -e "$PROFILE/hooks/lib/guard-core.js" ] \
  && fail "(e) guard-core.js removed on deselect" "still present" \
  || pass "(e) guard-core.js removed on deselect"
[ -d "$PROFILE/hooks/lib" ] \
  && fail "(e) hooks/lib rmdir'd (nothing left behind)" "directory still present: $(ls -A "$PROFILE/hooks/lib" 2>/dev/null)" \
  || pass "(e) hooks/lib rmdir'd (nothing left behind)"

# ── (e-2) each owned sidecar is removed when ONLY its owner is deselected; the
#    shared egress libs stay while any egress guard remains. ──
inst "leak-guard command-guard mcp-guard" 'CT_MCP_DENY="bad"
CT_TRUSTED_BOOTSTRAP_URLS="https://get.example.dev/install/"'
assert_ok "(e-2) leak-guard+command-guard+mcp-guard install succeeds" bash -c "[ $RC -eq 0 ]"
assert_file "(e-2) trusted-bootstrap.json present before deselect" "$PROFILE/hooks/lib/trusted-bootstrap.json"
assert_file "(e-2) mcp-policy.json present before deselect" "$PROFILE/hooks/lib/mcp-policy.json"
SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="secure-settings leak-guard mcp-guard" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log3" 2>&1
RC3=$?
assert_ok "(e-2) command-guard-only-deselect re-run succeeds" bash -c "[ $RC3 -eq 0 ]"
[ -e "$PROFILE/hooks/lib/trusted-bootstrap.json" ] \
  && fail "(e-2) trusted-bootstrap.json removed (command-guard deselected)" "still present" \
  || pass "(e-2) trusted-bootstrap.json removed (command-guard deselected)"
assert_file "(e-2) mcp-policy.json kept (mcp-guard still selected)" "$PROFILE/hooks/lib/mcp-policy.json"
SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="secure-settings leak-guard" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log4" 2>&1
RC4=$?
assert_ok "(e-2) mcp-guard-only-deselect re-run succeeds" bash -c "[ $RC4 -eq 0 ]"
[ -e "$PROFILE/hooks/lib/mcp-policy.json" ] \
  && fail "(e-2) mcp-policy.json removed (mcp-guard deselected)" "still present" \
  || pass "(e-2) mcp-policy.json removed (mcp-guard deselected)"
assert_file "(e-2) secret-patterns.json kept (leak-guard still selected)" "$PROFILE/hooks/lib/secret-patterns.json"

# ── (e-3) mcp-guard alone places the shared egress libs and its own policy; an
#    install without mcp-guard never compiles mcp-policy.json, even with keys set. ──
inst "mcp-guard" 'CT_MCP_ALLOW="github"'
assert_ok "(e-3) mcp-guard-only install succeeds" bash -c "[ $RC -eq 0 ]"
assert_file "(e-3) mcp-guard.ts placed" "$PROFILE/hooks/mcp-guard.ts"
assert_file "(e-3) mcp-policy.json placed" "$PROFILE/hooks/lib/mcp-policy.json"
assert_file "(e-3) secret-patterns.json placed" "$PROFILE/hooks/lib/secret-patterns.json"
assert_file "(e-3) org-egress.json placed" "$PROFILE/hooks/lib/org-egress.json"
assert_file "(e-3) guard-core.js placed" "$PROFILE/hooks/lib/guard-core.js"
assert_ok "(e-3) mcp-guard registered on mcp__.*" \
  bash -c "jq -e '[.hooks.PreToolUse[] | select(.matcher==\"mcp__.*\") | .hooks[].command | select(endswith(\"/hooks/mcp-guard.ts\"))] | length == 1' '$PROFILE/settings.json' >/dev/null"
inst "command-guard" 'CT_MCP_ALLOW="github"'
assert_ok "(e-3) command-guard-only install succeeds" bash -c "[ $RC -eq 0 ]"
[ -e "$PROFILE/hooks/lib/mcp-policy.json" ] \
  && fail "(e-3) no mcp-policy.json without mcp-guard" "it exists" \
  || pass "(e-3) no mcp-policy.json without mcp-guard"

# ── (f) a config that fails to SOURCE BEFORE any of the three keys are ever
#    reached must not silently compile empty sidecars with no signal — WARN loudly
#    (both compile functions), same as compile_org_sidecar's own #47-a hardening. ──
inst "command-guard mcp-guard" 'CT_MCP_ALLOW="unterminated'
assert_ok "(f) unsourceable config: install still succeeds" bash -c "[ $RC -eq 0 ]"
assert_grep "(f) unsourceable config: MCP policy warns NOT compiled / INACTIVE" \
  'CT_MCP_ALLOW/CT_MCP_DENY NOT compiled|MCP policy tier is INACTIVE' "$SB/log"
assert_grep "(f) unsourceable config: trusted-bootstrap warns NOT compiled / INACTIVE" \
  'CT_TRUSTED_BOOTSTRAP_URLS NOT compiled|trusted-bootstrap tier is INACTIVE' "$SB/log"
MP="$PROFILE/hooks/lib/mcp-policy.json"; TB="$PROFILE/hooks/lib/trusted-bootstrap.json"
assert_ok "(f) allow == [] (nothing captured before the error)" \
  bash -c "jq -e '.allow == []' '$MP' >/dev/null"
assert_ok "(f) deny == [] (nothing captured before the error)" \
  bash -c "jq -e '.deny == []' '$MP' >/dev/null"
assert_ok "(f) rules == [] (nothing captured before the error)" \
  bash -c "jq -e '.rules == []' '$TB' >/dev/null"

# ── (g) leading / trailing / doubled comma → die naming the key. A trailing comma
#    is the one bash's word-splitting silently drops (unlike a leading or doubled
#    one, which split to a visible empty element) — the exact case the comment on
#    _mcp_server_name_to_json claims is rejected, so pin it explicitly. ──
inst "command-guard mcp-guard" 'CT_MCP_ALLOW="github,"'
assert_ok "(g) trailing comma in CT_MCP_ALLOW aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(g) trailing comma: dies naming CT_MCP_ALLOW" 'CT_MCP_ALLOW' "$SB/log"

inst "command-guard mcp-guard" 'CT_MCP_DENY=",bad"'
assert_ok "(g) leading comma in CT_MCP_DENY aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(g) leading comma: dies naming CT_MCP_DENY" 'CT_MCP_DENY' "$SB/log"

inst "command-guard mcp-guard" 'CT_MCP_ALLOW="github,,linear"'
assert_ok "(g) doubled comma in CT_MCP_ALLOW aborts" bash -c "[ $RC -ne 0 ]"
assert_grep "(g) doubled comma: dies naming CT_MCP_ALLOW" 'CT_MCP_ALLOW' "$SB/log"

# ── (h) a key DELETED from the config (not set to "") on a re-run must behave
#    exactly like the empty-string case — the compile functions read
#    ${CT_MCP_ALLOW:-} etc., so an unset var already defaults to empty; this pins
#    that regression rather than changing behavior. ──
inst "command-guard mcp-guard" 'CT_MCP_ALLOW="github"
CT_MCP_DENY="bad"
CT_TRUSTED_BOOTSTRAP_URLS="https://get.example.dev/install/"'
assert_ok "(h) initial populated install succeeds" bash -c "[ $RC -eq 0 ]"
MP="$PROFILE/hooks/lib/mcp-policy.json"; TB="$PROFILE/hooks/lib/trusted-bootstrap.json"
assert_ok "(h) allow non-empty before the keys are deleted" \
  bash -c "jq -e '.allow != []' '$MP' >/dev/null"

# Overwrite the config, OMITTING all three keys entirely (not "" — gone).
printf '# no CT_MCP_ALLOW / CT_MCP_DENY / CT_TRUSTED_BOOTSTRAP_URLS here\n' > "$PROFILE/aka-claude-tools.config"
SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="command-guard mcp-guard" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log2" 2>&1
RC2=$?
assert_ok "(h) re-run with keys deleted succeeds" bash -c "[ $RC2 -eq 0 ]"
assert_ok "(h) allow == [] once the key is deleted (not just emptied)" \
  bash -c "jq -e '.allow == []' '$MP' >/dev/null"
assert_ok "(h) deny == [] once the key is deleted" \
  bash -c "jq -e '.deny == []' '$MP' >/dev/null"
assert_ok "(h) rules == [] once the key is deleted" \
  bash -c "jq -e '.rules == []' '$TB' >/dev/null"

t_summary
