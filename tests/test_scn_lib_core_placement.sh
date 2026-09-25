#!/usr/bin/env bash
# Scenario lib_core_placement: the vendored hooks/lib/guard-core.{js,d.ts,lock.json}
# is placed whenever ANY of command-guard, leak-guard or rtk-safe is selected — not
# just the two egress guards that own hooks/lib/secret-patterns.json. Deselecting
# every consumer must remove all three guard-core files (and the now-empty hooks/lib
# dir), and an install with both guards keeps secret-patterns.json alongside them.
# Fully sandboxed: fake $HOME, --defaults --no-auth-inherit.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_lib_core_placement:"

SB="$(sandbox)"; touch "$SB/.bashrc"
P="$SB/.claude-aka"
CORE_JS="$P/hooks/lib/guard-core.js"
CORE_DTS="$P/hooks/lib/guard-core.d.ts"
CORE_LOCK="$P/hooks/lib/guard-core.lock.json"
PATTERNS="$P/hooks/lib/secret-patterns.json"

# (a) rtk-safe ONLY (no leak-guard, no command-guard) → guard-core.js still placed.
CT_ADDITIONS="rtk-safe" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log1" 2>&1
assert_eq   "install rtk-safe-only exits 0" "0" "$?"
assert_file "rtk-safe-only install places guard-core.js" "$CORE_JS"
assert_file "rtk-safe-only install places guard-core.d.ts" "$CORE_DTS"
assert_file "rtk-safe-only install places guard-core.lock.json" "$CORE_LOCK"

# (b) Deselect every consumer (leak-guard, command-guard, rtk-safe) → all three
# guard-core files are removed and hooks/lib is gone (no secret-patterns.json was
# ever placed on this path, since neither egress guard was ever selected).
CT_ADDITIONS="secure-settings" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log2" 2>&1
assert_eq "deselect re-run (no consumer) exits 0" "0" "$?"
if [ -e "$CORE_JS" ] || [ -e "$CORE_DTS" ] || [ -e "$CORE_LOCK" ]; then
  fail "guard-core files removed when no consumer remains" "RESIDUE under $P/hooks/lib"
else
  pass "guard-core files removed when no consumer remains"
fi
if [ -e "$P/hooks/lib" ]; then
  fail "hooks/lib removed when no consumer remains" "RESIDUE: $P/hooks/lib survived"
else
  pass "hooks/lib removed when no consumer remains"
fi

# (c) Both guards selected → all three guard-core files PLUS secret-patterns.json.
SB2="$(sandbox)"; touch "$SB2/.bashrc"
P2="$SB2/.claude-aka"
CT_ADDITIONS="leak-guard command-guard" SHELL=/bin/bash HOME="$SB2" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB2/log3" 2>&1
assert_eq   "install both guards exits 0" "0" "$?"
assert_file "both-guards install places guard-core.js" "$P2/hooks/lib/guard-core.js"
assert_file "both-guards install places guard-core.d.ts" "$P2/hooks/lib/guard-core.d.ts"
assert_file "both-guards install places guard-core.lock.json" "$P2/hooks/lib/guard-core.lock.json"
assert_file "both-guards install places secret-patterns.json" "$P2/hooks/lib/secret-patterns.json"

t_summary
