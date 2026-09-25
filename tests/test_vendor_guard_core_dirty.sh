#!/usr/bin/env bash
# tools/vendor-guard-core.sh's ONLY freshness check was `bun scripts/build.ts --check`,
# which verifies dist/ matches the CURRENT working tree — not the recorded HEAD. A
# reviewer could dirty guard-core's src/ (tracked, staged, or untracked), rebuild, and
# vendor successfully: the resulting lock.json's "source" would record the clean HEAD
# SHA even though the vendored bytes came from an uncommitted tree, misattributing them.
# The fix refuses a dirty checkout before --check ever runs. This scenario proves it,
# covering all three dirty shapes, against a disposable fake guard-core checkout and a
# disposable fake target repo — NEVER the real config/hooks/lib/.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_vendor_guard_core_dirty:"

SB="$(sandbox)"

# ---- fake guard-core checkout: minimal layout the vendor script needs ----
FAKE="$SB/fake-guard-core"
mkdir -p "$FAKE/scripts" "$FAKE/src" "$FAKE/dist"
cat > "$FAKE/scripts/build.ts" <<'EOF'
// Stub: reports "up to date" unconditionally, exactly like the real bug — the
// freshness check alone can't see an uncommitted working-tree edit.
if (process.argv[2] === "--check") process.exit(0);
process.exit(1);
EOF
echo 'export const marker = 1;' > "$FAKE/src/index.ts"
echo '// fake guard-core.js' > "$FAKE/dist/guard-core.js"
echo '// fake guard-core.d.ts' > "$FAKE/dist/guard-core.d.ts"
printf '{"version":"9.9.9","sha256":"deadbeef","dtsSha256":"deadbeef"}' > "$FAKE/dist/guard-core.lock.json"

git -C "$FAKE" init -q -b main
git -C "$FAKE" -c user.email=test@example.com -c user.name=test add -A
git -C "$FAKE" -c user.email=test@example.com -c user.name=test commit -q -m "fake guard-core baseline"

# ---- fake target repo: its own tools/vendor-guard-core.sh + empty config/hooks/lib ----
# The real script resolves its target as "$(dirname "${BASH_SOURCE[0]}")/..", so running
# a COPY of it from inside a scratch repo keeps every write inside that scratch repo.
TARGET="$SB/fake-target"
mkdir -p "$TARGET/tools" "$TARGET/config/hooks/lib"
cp "$REPO_ROOT/tools/vendor-guard-core.sh" "$TARGET/tools/vendor-guard-core.sh"
chmod +x "$TARGET/tools/vendor-guard-core.sh"
echo "sentinel" > "$TARGET/config/hooks/lib/SENTINEL"
LIB="$TARGET/config/hooks/lib"

run_vendor() { bash "$TARGET/tools/vendor-guard-core.sh" "$FAKE" >"$SB/out" 2>&1; echo $?; }

# ---- sanity: a CLEAN checkout vendors successfully (baseline, proves the new guard
# doesn't false-positive on a clean tree) ----
rc="$(run_vendor)"
assert_eq "clean checkout vendors successfully" "0" "$rc"
assert_file "clean vendor places guard-core.js" "$LIB/guard-core.js"
rm -f "$LIB/guard-core.js" "$LIB/guard-core.d.ts" "$LIB/guard-core.lock.json"

# ---- case A: tracked file modified, NOT staged ----
echo '// tracked edit' >> "$FAKE/src/index.ts"
rc="$(run_vendor)"
assert_eq "tracked-dirty checkout refused (nonzero exit)" "1" "$rc"
assert_grep "tracked-dirty refusal names the reason" "uncommitted changes" "$SB/out"
if [ -e "$LIB/guard-core.js" ] || [ -e "$LIB/guard-core.d.ts" ] || [ -e "$LIB/guard-core.lock.json" ]; then
  fail "tracked-dirty run left config/hooks/lib/ unchanged" "guard-core files were written despite the dirty checkout"
else
  pass "tracked-dirty run left config/hooks/lib/ unchanged"
fi
assert_file "sentinel survives the refused run" "$LIB/SENTINEL"
git -C "$FAKE" checkout -q -- src/index.ts

# ---- case B: tracked file modified AND staged ----
echo '// staged edit' >> "$FAKE/src/index.ts"
git -C "$FAKE" add src/index.ts
rc="$(run_vendor)"
assert_eq "staged-dirty checkout refused (nonzero exit)" "1" "$rc"
if [ -e "$LIB/guard-core.js" ]; then
  fail "staged-dirty run left config/hooks/lib/ unchanged" "guard-core.js was written despite the staged edit"
else
  pass "staged-dirty run left config/hooks/lib/ unchanged"
fi
git -C "$FAKE" reset -q --hard HEAD

# ---- case C: untracked file added ----
echo '// new file' > "$FAKE/src/extra.ts"
rc="$(run_vendor)"
assert_eq "untracked-dirty checkout refused (nonzero exit)" "1" "$rc"
if [ -e "$LIB/guard-core.js" ]; then
  fail "untracked-dirty run left config/hooks/lib/ unchanged" "guard-core.js was written despite the untracked file"
else
  pass "untracked-dirty run left config/hooks/lib/ unchanged"
fi
git -C "$FAKE" clean -q -fd

# ---- back to clean: vendoring works again (the guard isn't sticky/broken) ----
rc="$(run_vendor)"
assert_eq "checkout clean again vendors successfully" "0" "$rc"

t_summary
