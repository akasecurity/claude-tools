#!/usr/bin/env bash
# uninstall.sh — the one-shot teardown. Removes a profile dir + its managed rc
# alias blocks (matched by marker + the dir they point at, name-independent),
# while leaving other profiles, user aliases, and everything outside our markers
# untouched. ENV-ISOLATION is the load-bearing safety property: the destructive
# target must NEVER come from the ambient $CLAUDE_CONFIG_DIR, and the active
# session's own profile must be refused. We scrub the var (a real session sets
# it) and re-introduce it deliberately in the guard tests.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset CLAUDE_CONFIG_DIR
echo "test_uninstall_oneshot:"

UNINSTALL="$REPO_ROOT/uninstall.sh"

# ── precision: remove only the target's block + dir ──────────────────────────
SB="$(sandbox)"
mkdir -p "$SB/.claude-aka/hooks" "$SB/.claude-work"
# The target's block carries the CURRENT two-line launcher shape (alias + guarded
# PATH export) — prune_blocks must drop the WHOLE block, PATH line included.
cat > "$SB/.bashrc" <<EOF
alias ll='ls -la'
# >>> aka-claude-tools managed: aka >>>
alias aka='CLAUDE_CONFIG_DIR="$SB/.claude-aka" claude'
case ":\$PATH:" in *":$SB/.claude-aka/bin:"*) ;; *) export PATH="$SB/.claude-aka/bin:\$PATH" ;; esac
# <<< aka-claude-tools managed: aka <<<
# >>> aka-claude-tools managed: work >>>
alias work='CLAUDE_CONFIG_DIR="$SB/.claude-work" claude'
# <<< aka-claude-tools managed: work <<<
EOF
HOME="$SB" SHELL=/bin/bash bash "$UNINSTALL" "$SB/.claude-aka" --yes >"$SB/log" 2>&1
assert_eq  "exits 0"                         "0" "$?"
[ -d "$SB/.claude-aka" ] && fail "target profile dir removed" "still present" || pass "target profile dir removed"
assert_file "other profile (.claude-work) kept"   "$SB/.claude-work"
assert_nlit "target alias block removed"     "managed: aka"  "$SB/.bashrc"
assert_nlit "target block's PATH line removed with it" ".claude-aka/bin" "$SB/.bashrc"
assert_lit  "other profile's block kept"     "managed: work" "$SB/.bashrc"
assert_lit  "user's own alias kept"          "alias ll="     "$SB/.bashrc"

# ── default target is $HOME/.claude-aka, NEVER the ambient $CLAUDE_CONFIG_DIR ──
# The wipe regression: a stray $CLAUDE_CONFIG_DIR must not become the rm target.
SB="$(sandbox)"; touch "$SB/.bashrc"
mkdir -p "$SB/.claude-aka" "$SB/elsewhere"
HOME="$SB" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$SB/elsewhere" \
  bash "$UNINSTALL" --yes >"$SB/log" 2>&1
assert_eq  "no-arg run exits 0"              "0" "$?"
[ -d "$SB/.claude-aka" ] && fail "no-arg removed the HOME default" "still present" || pass "no-arg removed the HOME default (~/.claude-aka)"
assert_file "ambient CLAUDE_CONFIG_DIR dir untouched" "$SB/elsewhere"

# ── tripwire: refuse to delete the ACTIVE session's profile ──────────────────
SB="$(sandbox)"; touch "$SB/.bashrc"; mkdir -p "$SB/.claude-aka"
HOME="$SB" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$SB/.claude-aka" \
  bash "$UNINSTALL" "$SB/.claude-aka" --yes >"$SB/log" 2>&1
rc=$?
[ "$rc" != 0 ] && pass "refuses target == active \$CLAUDE_CONFIG_DIR" || fail "refuses target == active \$CLAUDE_CONFIG_DIR" "exited 0"
assert_file "active profile NOT deleted"     "$SB/.claude-aka"
assert_grep "refusal explains why"           "running inside" "$SB/log"

# ── ~/.claude footgun guard: --yes cannot bypass the interactive confirm ──────
SB="$(sandbox)"; touch "$SB/.bashrc"; mkdir -p "$SB/.claude"
HOME="$SB" SHELL=/bin/bash bash "$UNINSTALL" "$SB/.claude" --yes </dev/null >"$SB/log" 2>&1
rc=$?
[ "$rc" != 0 ] && pass "default ~/.claude refused without a real confirm" || fail "default ~/.claude refused" "exited 0"
assert_file "~/.claude NOT deleted"          "$SB/.claude"

# ── idempotent: a second run on an already-gone profile is a clean no-op ──────
SB="$(sandbox)"; touch "$SB/.bashrc"; mkdir -p "$SB/.claude-aka"
HOME="$SB" SHELL=/bin/bash bash "$UNINSTALL" "$SB/.claude-aka" --yes >/dev/null 2>&1
HOME="$SB" SHELL=/bin/bash bash "$UNINSTALL" "$SB/.claude-aka" --yes >"$SB/log2" 2>&1
assert_eq  "second run exits 0"              "0" "$?"
assert_grep "second run reports already gone" "already gone" "$SB/log2"

# ── discovery: no arg, a single managed block → that profile is the target ───
SB="$(sandbox)"; mkdir -p "$SB/.claude-work"
cat > "$SB/.bashrc" <<EOF
# >>> aka-claude-tools managed: work >>>
alias work='CLAUDE_CONFIG_DIR="$SB/.claude-work" claude'
# <<< aka-claude-tools managed: work <<<
EOF
HOME="$SB" SHELL=/bin/bash bash "$UNINSTALL" --yes >"$SB/log" 2>&1
assert_eq  "discover-one exits 0"            "0" "$?"
[ -d "$SB/.claude-work" ] && fail "discovered the lone profile (~/.claude-work)" "still present" \
                          || pass "discovered the lone profile (~/.claude-work)"
assert_nlit "discovered profile's block removed" "managed: work" "$SB/.bashrc"

# ── discovery: multiple managed blocks + --yes → refuse to guess ─────────────
SB="$(sandbox)"; mkdir -p "$SB/.claude-work" "$SB/.claude-play"
cat > "$SB/.bashrc" <<EOF
# >>> aka-claude-tools managed: work >>>
alias work='CLAUDE_CONFIG_DIR="$SB/.claude-work" claude'
# <<< aka-claude-tools managed: work <<<
# >>> aka-claude-tools managed: play >>>
alias play='CLAUDE_CONFIG_DIR="$SB/.claude-play" claude'
# <<< aka-claude-tools managed: play <<<
EOF
HOME="$SB" SHELL=/bin/bash bash "$UNINSTALL" --yes >"$SB/log" 2>&1
rc=$?
[ "$rc" != 0 ] && pass "multiple + --yes refuses to guess" || fail "multiple + --yes refuses to guess" "exited 0"
assert_file "neither profile removed (.claude-work)"  "$SB/.claude-work"
assert_file "neither profile removed (.claude-play)"  "$SB/.claude-play"
assert_grep "lists the candidates"          "claude-work" "$SB/log"

# ── discovery excludes the ACTIVE profile, leaving a lone other to resolve ────
SB="$(sandbox)"; mkdir -p "$SB/.claude-aka" "$SB/.claude-work"
cat > "$SB/.bashrc" <<EOF
# >>> aka-claude-tools managed: aka >>>
alias aka='CLAUDE_CONFIG_DIR="$SB/.claude-aka" claude'
# <<< aka-claude-tools managed: aka <<<
# >>> aka-claude-tools managed: work >>>
alias work='CLAUDE_CONFIG_DIR="$SB/.claude-work" claude'
# <<< aka-claude-tools managed: work <<<
EOF
HOME="$SB" SHELL=/bin/bash CLAUDE_CONFIG_DIR="$SB/.claude-aka" \
  bash "$UNINSTALL" --yes >"$SB/log" 2>&1
assert_eq  "active-excluded discovery exits 0" "0" "$?"
assert_file "active profile (.claude-aka) untouched"  "$SB/.claude-aka"
[ -d "$SB/.claude-work" ] && fail "lone non-active profile removed" "still present" \
                          || pass "lone non-active profile removed (.claude-work)"

t_summary
