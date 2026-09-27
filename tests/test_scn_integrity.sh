#!/usr/bin/env bash
# Scenario — the self-integrity manifest (<profile>/.aka-integrity.json), the
# SessionStart drift check (hooks/integrity-check.ts) and `install.sh --audit`.
#
#   A. a clean install writes the manifest and registers the check; the check is
#      silent (exit 0, no output)
#   B. editing a kit hook file → one stderr notice, exit 2, one kind:"integrity"
#      audit line
#   C. deleting a kit Read deny rule → settings drift
#   D. the user's own hook, permission rule and env key → no drift
#   E. a hand-written hooks/lib/trusted-bootstrap.json carrying a matching
#      sourceHash → drift; so does any unexpected file under hooks/lib/
#   F. re-running the installer → clean again
#   G. `--audit` names the changed file and the missing managed setting, and
#      suggests re-running the installer; positional PROFILE_DIR works
#   H. guard-core missing, or the manifest missing, or no profile meta → silent
#      exit 0 even with drift; jq missing → settings check skipped silently
#   I. a deleted kit file counts as missing
#   J. deselecting every bun hook removes the check and its registration
#   K. a removed kit hook registration or statusLine, or sandbox.enabled flipped
#      off, is settings drift, and --audit names the missing registration
#   L. a launcher shim written by --alias is recorded (and dropped again by
#      --delete-alias); editing it is drift
#
# Fully sandboxed: HOME, CT_CONFIG_DIR and CLAUDE_CONFIG_DIR all point into a
# temp dir for every install.sh and hook invocation.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_integrity:"
command -v bun >/dev/null 2>&1 || { echo "  SKIP: bun not installed"; exit 0; }

INSTALL="$REPO_ROOT/install.sh"
SB="$(sandbox)"; DIR="$SB/.claude-aka"
ADDS="secure-settings command-guard post-guard statusline"
NOTICE_FILE='claude-tools: 1 kit file(s) changed or missing, settings OK; run aka-claude-tools --audit'
NOTICE_SET='claude-tools: 0 kit file(s) changed or missing, settings drift; run aka-claude-tools --audit'

inst() { # [additions] — --apply into $DIR
  CT_CONFIG_DIR="$DIR" CLAUDE_CONFIG_DIR="$DIR" CT_ADDITIONS="${1:-$ADDS}" HOME="$SB" \
    bash "$INSTALL" --apply --no-auth-inherit >"$SB/install.log" 2>&1
}
# run_ic [hook-file] — runs the check the way Claude Code would, env pinned to the sandbox.
run_ic() {
  local f="${1:-$DIR/hooks/integrity-check.ts}"
  CLAUDE_CONFIG_DIR="$DIR" HOME="$SB" bun "$f" </dev/null >"$SB/out" 2>"$SB/err"
  RC=$?
}
expect_silent() { # <label>
  run_ic "${2:-}"
  if [ "$RC" = "0" ] && [ ! -s "$SB/out" ] && [ ! -s "$SB/err" ]; then pass "$1"
  else fail "$1" "rc=$RC out=$(cat "$SB/out") err=$(cat "$SB/err")"; fi
}
expect_notice() { # <label> <exact-stderr>
  run_ic
  if [ "$RC" = "2" ] && [ ! -s "$SB/out" ] && [ "$(cat "$SB/err")" = "$2" ]; then pass "$1"
  else fail "$1" "rc=$RC out=$(cat "$SB/out") err=$(cat "$SB/err")"; fi
}
audit_lines() { cat "$DIR"/logs/security-*.jsonl 2>/dev/null | jq -c 'select(.kind=="integrity")' 2>/dev/null | wc -l | tr -d ' '; }
settings_edit() { jq "$1" "$DIR/settings.json" > "$SB/s.tmp" && mv "$SB/s.tmp" "$DIR/settings.json"; }

# ── A. clean install ─────────────────────────────────────────────────────────
inst; assert_eq "install exits 0" "0" "$?"
assert_file "manifest written" "$DIR/.aka-integrity.json"
assert_file "integrity-check placed" "$DIR/hooks/integrity-check.ts"
assert_file "managed-settings.jq placed" "$DIR/hooks/lib/managed-settings.jq"
assert_ok "manifest shape: version 1, files map, settings hash" \
  jq -e '.version==1 and (.files|type)=="object" and (.settings|test("^[0-9a-f]{64}$"))' "$DIR/.aka-integrity.json"
assert_ok "manifest covers a kit hook, the vendored core, the jq program and a sidecar" \
  jq -e '.files | has("hooks/command-guard.ts") and has("hooks/lib/guard-core.js")
         and has("hooks/lib/managed-settings.jq") and has("hooks/lib/trusted-bootstrap.json")
         and has("hooks/integrity-check.ts")' "$DIR/.aka-integrity.json"
assert_ok "file hashes are sha256 of the placed file" bash -c \
  "[ \"\$(jq -r '.files[\"hooks/command-guard.ts\"]' '$DIR/.aka-integrity.json')\" = \"\$(shasum -a 256 '$DIR/hooks/command-guard.ts' | awk '{print \$1}')\" ]"
assert_ok "integrity-check registered on SessionStart" \
  jq -e '[.hooks.SessionStart[]?.hooks[]?.command | select(endswith("/hooks/integrity-check.ts"))] | length == 1' "$DIR/settings.json"
expect_silent "A. clean install → silent"

# ── B. edit a kit hook file ──────────────────────────────────────────────────
printf '\n// tampered\n' >> "$DIR/hooks/command-guard.ts"
before="$(audit_lines)"
expect_notice "B. edited hooks/command-guard.ts → drift notice" "$NOTICE_FILE"
assert_eq "B. one kind:integrity audit line written" "$((before+1))" "$(audit_lines)"

# ── G. --audit names the file ────────────────────────────────────────────────
HOME="$SB" CT_CONFIG_DIR="$DIR" CLAUDE_CONFIG_DIR="$DIR" bash "$INSTALL" --audit >"$SB/audit.out" 2>&1
assert_eq "G. --audit exits 1 on drift" "1" "$?"
assert_lit "G. --audit lists the changed file" "changed: hooks/command-guard.ts" "$SB/audit.out"
assert_lit "G. --audit suggests re-running the installer" "re-run the installer" "$SB/audit.out"

# ── F. re-run → clean ────────────────────────────────────────────────────────
inst; expect_silent "F. re-run installer → clean again"
HOME="$SB" CT_CONFIG_DIR="$DIR" CLAUDE_CONFIG_DIR="$DIR" bash "$INSTALL" --audit >"$SB/audit.out" 2>&1
assert_eq "G. --audit exits 0 when clean" "0" "$?"
assert_lit "G. --audit reports clean" "no drift" "$SB/audit.out"

# ── C. delete a Read deny rule ───────────────────────────────────────────────
settings_edit '.permissions.deny -= ["Read(~/.aws/**)"]'
expect_notice "C. deleted Read deny → settings drift" "$NOTICE_SET"
# positional PROFILE_DIR, with CT_CONFIG_DIR pointing elsewhere
HOME="$SB" CT_CONFIG_DIR="$SB/elsewhere" CLAUDE_CONFIG_DIR="$DIR" bash "$INSTALL" --audit "$DIR" >"$SB/audit.out" 2>&1
assert_eq "G. --audit PROFILE_DIR exits 1 on settings drift" "1" "$?"
assert_lit "G. --audit lists the missing deny rule" "Read(~/.aws/**)" "$SB/audit.out"
inst; expect_silent "F. re-run after settings drift → clean"

# ── D. the user's own settings are not drift ─────────────────────────────────
settings_edit '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:"/opt/user/hook.sh"}]}]
  | .hooks.SessionStart += [{hooks:[{type:"command",command:"echo hi"}]}]
  | .permissions.deny += ["Read(~/secret-notes/**)"] | .permissions.allow += ["Bash(ls:*)"]
  | .env.MY_KEY = "1"'
expect_silent "D. user hook, permission and env key → no drift"
inst

# ── E. forged sidecar / unexpected lib file ──────────────────────────────────
TB="$DIR/hooks/lib/trusted-bootstrap.json"
src_hash="$(shasum -a 256 "$DIR/aka-claude-tools.config" | awk '{print $1}')"
jq -n --arg h "$src_hash" '{rules:[{host:"evil.example",pathPrefix:"/"}], sourceHash:$h}' > "$TB"
expect_notice "E. hand-written trusted-bootstrap.json with matching sourceHash → drift" "$NOTICE_FILE"
inst; expect_silent "E. re-run restores the sidecar → clean"
printf '{}' > "$DIR/hooks/lib/forged.json"
expect_notice "E. unexpected file under hooks/lib → drift" "$NOTICE_FILE"
HOME="$SB" CT_CONFIG_DIR="$DIR" CLAUDE_CONFIG_DIR="$DIR" bash "$INSTALL" --audit >"$SB/audit.out" 2>&1
assert_lit "G. --audit lists the unexpected file" "unexpected: hooks/lib/forged.json" "$SB/audit.out"
inst; assert_ok "E. re-run clears the unexpected lib file" test ! -e "$DIR/hooks/lib/forged.json"
expect_silent "E. re-run → clean"

# ── I. missing kit file ──────────────────────────────────────────────────────
rm -f "$DIR/hooks/post-guard.ts"
expect_notice "I. deleted kit file → drift" "$NOTICE_FILE"
HOME="$SB" CT_CONFIG_DIR="$DIR" CLAUDE_CONFIG_DIR="$DIR" bash "$INSTALL" --audit >"$SB/audit.out" 2>&1
assert_lit "I. --audit lists the missing file" "missing: hooks/post-guard.ts" "$SB/audit.out"
inst

# ── H. fail-silent paths ─────────────────────────────────────────────────────
printf '\n// tampered\n' >> "$DIR/hooks/command-guard.ts"
mv "$DIR/hooks/lib/guard-core.js" "$SB/core.bak"
expect_silent "H. guard-core missing → silent exit 0"
mv "$SB/core.bak" "$DIR/hooks/lib/guard-core.js"
mv "$DIR/.aka-integrity.json" "$SB/manifest.bak"
expect_silent "H. manifest missing → silent exit 0"
mv "$SB/manifest.bak" "$DIR/.aka-integrity.json"
printf 'not json' > "$SB/m.json"; cp "$DIR/.aka-integrity.json" "$SB/manifest.bak"
cp "$SB/m.json" "$DIR/.aka-integrity.json"
expect_silent "H. corrupt manifest → silent exit 0"
cp "$SB/manifest.bak" "$DIR/.aka-integrity.json"
mv "$DIR/.aka-claude-tools-meta" "$SB/meta.bak"
expect_silent "H. no profile meta → silent exit 0"
mv "$SB/meta.bak" "$DIR/.aka-claude-tools-meta"
inst
# jq missing → the settings check is skipped (files still checked)
settings_edit '.permissions.deny -= ["Read(~/.aws/**)"]'
BUN="$(command -v bun)"
CLAUDE_CONFIG_DIR="$DIR" HOME="$SB" PATH="/nonexistent" "$BUN" "$DIR/hooks/integrity-check.ts" </dev/null >"$SB/out" 2>"$SB/err"
if [ "$?" = "0" ] && [ ! -s "$SB/err" ]; then pass "H. jq missing → settings check skipped silently"
else fail "H. jq missing → settings check skipped silently" "err=$(cat "$SB/err")"; fi
# the repo's own config/hooks copy never reports (no meta next to it)
before="$(audit_lines)"
CLAUDE_CONFIG_DIR= HOME="$SB" bun "$REPO_ROOT/config/hooks/integrity-check.ts" </dev/null >"$SB/out" 2>"$SB/err"
if [ "$?" = "0" ] && [ ! -s "$SB/err" ]; then pass "H. repo copy → silent"
else fail "H. repo copy → silent" "err=$(cat "$SB/err")"; fi
assert_ok "H. nothing written next to the repo's hooks" test ! -e "$REPO_ROOT/config/logs"
inst

# ── K. kit hook registration / statusLine / sandbox edited ───────────────────
settings_edit '.hooks.PreToolUse |= map(select([.hooks[]?.command | tostring | endswith("/hooks/command-guard.ts")] | any | not))'
expect_notice "K. removed the command-guard registration → settings drift" "$NOTICE_SET"
HOME="$SB" CT_CONFIG_DIR="$DIR" CLAUDE_CONFIG_DIR="$DIR" bash "$INSTALL" --audit >"$SB/audit.out" 2>&1
assert_lit "K. --audit names the missing registration" "missing: hook registration for hooks/command-guard.ts" "$SB/audit.out"
inst
settings_edit 'del(.statusLine)'
expect_notice "K. removed the kit statusLine → settings drift" "$NOTICE_SET"
inst
CT_UNAME=Darwin inst "$ADDS sandbox"; expect_silent "K. sandbox install → clean"
settings_edit '.sandbox.enabled = false'
expect_notice "K. sandbox.enabled flipped off → settings drift" "$NOTICE_SET"
CT_UNAME=Darwin inst

# ── L. launcher shim under bin/ ──────────────────────────────────────────────
CT_CONFIG_DIR="$DIR" CLAUDE_CONFIG_DIR="$DIR" CT_ALIAS="ic-test-launch" HOME="$SB" SHELL=/bin/bash \
  bash "$INSTALL" --alias >"$SB/alias.log" 2>&1
assert_eq "L. --alias exits 0" "0" "$?"
assert_ok "L. manifest records the new shim" jq -e '.files | has("bin/ic-test-launch")' "$DIR/.aka-integrity.json"
expect_silent "L. shim written → still clean"
printf 'echo hijacked\n' >> "$DIR/bin/ic-test-launch"
expect_notice "L. edited launcher shim → drift" "$NOTICE_FILE"
CT_CONFIG_DIR="$DIR" CLAUDE_CONFIG_DIR="$DIR" CT_ALIAS="ic-test-launch" HOME="$SB" SHELL=/bin/bash \
  bash "$INSTALL" --delete-alias >"$SB/alias.log" 2>&1
assert_ok "L. --delete-alias drops the shim from the manifest" jq -e '.files | has("bin/ic-test-launch") | not' "$DIR/.aka-integrity.json"
expect_silent "L. shim removed → clean"

# ── J. deselect every bun hook ───────────────────────────────────────────────
inst "secure-settings"
assert_ok "J. integrity-check removed with the last bun hook" test ! -e "$DIR/hooks/integrity-check.ts"
assert_ok "J. SessionStart registration pruned" \
  jq -e '[.hooks.SessionStart[]?.hooks[]?.command | select(endswith("/hooks/integrity-check.ts"))] | length == 0' "$DIR/settings.json"
assert_file "J. manifest still written" "$DIR/.aka-integrity.json"
HOME="$SB" CT_CONFIG_DIR="$DIR" CLAUDE_CONFIG_DIR="$DIR" bash "$INSTALL" --audit >"$SB/audit.out" 2>&1
assert_eq "J. --audit clean on a hook-less profile" "0" "$?"

t_summary
