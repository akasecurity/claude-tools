#!/usr/bin/env bash
# Version scenario: install.sh --version reports the VERSION file, exits 0, and
# does so WITHOUT needing a config dir, deps, or any prompt (it must short-circuit
# before preflight). Also pins VERSION ↔ CHANGELOG ↔ --version output in sync, so a
# release bump that forgets one of the three is caught here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_version:"

INSTALL="$REPO_ROOT/install.sh"
VERSION_FILE="$REPO_ROOT/VERSION"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"
CITATION="$REPO_ROOT/CITATION.cff"

assert_file "VERSION file exists" "$VERSION_FILE"
assert_file "CHANGELOG.md exists" "$CHANGELOG"

ver="$(cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')"

# Well-formed semver (major.minor.patch, optional pre-release/build).
assert_grep "VERSION is semver-shaped" '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' "$VERSION_FILE"

# --version prints "aka-claude-tools <version>" and exits 0, with NO env set
# (no CT_CONFIG_DIR, no CT_ADDITIONS) — it must not reach the preflight/config logic.
out="$(bash "$INSTALL" --version 2>/dev/null)"; rc=$?
assert_eq   "--version exits 0" "0" "$rc"
assert_eq   "--version prints the kit name + VERSION" "aka-claude-tools $ver" "$out"

# -V is the documented short alias.
outV="$(bash "$INSTALL" -V 2>/dev/null)"; rcV=$?
assert_eq   "-V exits 0" "0" "$rcV"
assert_eq   "-V prints the same as --version" "aka-claude-tools $ver" "$outV"

# --version short-circuits even when a later flag would otherwise run logic.
out2="$(bash "$INSTALL" --version --apply 2>/dev/null)"; rc2=$?
assert_eq   "--version wins over a following --apply (no engine run)" "0" "$rc2"
assert_eq   "--version output unchanged with a trailing flag" "aka-claude-tools $ver" "$out2"

# Release-sync: the VERSION must be documented in the CHANGELOG (catches a bump that
# forgets the changelog entry).
assert_lit  "CHANGELOG documents the current version" "[$ver]" "$CHANGELOG"

# Release-sync: CITATION.cff carries the same version. It sat a patch behind for a
# whole release because nothing pinned it.
assert_file "CITATION.cff exists" "$CITATION"
assert_grep "CITATION.cff states the current version" "^version: ${ver//./\\.}$" "$CITATION"

t_summary
