#!/usr/bin/env bash
# tests/lib.sh — tiny assert + sandbox helpers. Source this at the top of a test.
# No external deps beyond bash + jq + git (the project's own dependencies).
#
# Each test file is run as its own subprocess by tests/run.sh, sources this,
# runs asserts, and ends with `t_summary` (exits non-zero if any assert failed).
# Sandboxes are mktemp dirs, auto-removed on exit — a test NEVER touches a real
# ~/.claude* profile or the real repo working tree.

REPO_ROOT="$(git -C "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"
ADDITIONS="$REPO_ROOT/config/additions.json"

# Neutralize ambient config-dir vars at the sandbox boundary so a script under test
# that reads $CLAUDE_CONFIG_DIR can NEVER escape onto the operator's real profile.
# Tests pass the config dir explicitly / override HOME; this is defense-in-depth
# against an exported var from the live shell.
unset CLAUDE_CONFIG_DIR

_PASS=0 ; _FAIL=0
# One per-process sandbox root, created in THIS shell (NOT a subshell). A previous
# sandbox() appended each dir to an array, but the common `d="$(sandbox)"` call runs
# sandbox() inside command substitution, so that array mutation was lost and the dir
# leaked. Rooting every sandbox under one dir made here and removing it wholesale on
# exit is subshell-proof. `mktemp -d <template>` is portable (BSD + GNU).
_SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aka-tests.XXXXXX")"
trap '_t_cleanup' EXIT
_t_cleanup() { [ -n "${_SANDBOX_ROOT:-}" ] && rm -rf "$_SANDBOX_ROOT"; }

sandbox() { mktemp -d "$_SANDBOX_ROOT/sbx.XXXXXX"; }

# install_path — a HERMETIC PATH for driving install.sh in tests that must be
# immune to whatever launcher commands the operator's machine has on PATH. The
# installer now refuses/renames a launcher name that already resolves to a PATH
# command (e.g. a real ai-tc `aka` CLI, or an installed `claude-aka` shim from a
# genuine kit install), so a test asserting alias success/names under the
# operator's full PATH would flake per-machine. This builds a one-off symlink
# farm of exactly the tools the installer (and the test harness around it) needs
# — mirroring test_scn_install_missing_deps' stub-PATH technique — and prints it
# as a ready-to-use PATH value. Tools absent on the host are simply skipped.
install_path() {
  local d="$_SANDBOX_ROOT/hermetic-bin" t real
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    for t in bash sh env jq git awk sed grep egrep fgrep find mktemp dirname \
             basename cat cp mv rm mkdir rmdir chmod date tr wc sort head tail \
             cut printf echo ln touch uname sleep comm diff stat tee xargs expr \
             id whoami bun node curl; do
      real="$(command -v "$t" 2>/dev/null || true)"
      [ -n "$real" ] && ln -sf "$real" "$d/$t"
    done
  fi
  printf '%s\n' "$d"
}

pass() { _PASS=$((_PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { _FAIL=$((_FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; [ -n "${2:-}" ] && printf '      └ %s\n' "$2" >&2; }

# assert_ok   "desc" cmd...   → pass if cmd exits 0
assert_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "expected exit 0 from: $*"; fi; }
# assert_fail "desc" cmd...   → pass if cmd exits NON-zero (guard rejections)
assert_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d" "expected non-zero from: $*"; else pass "$d"; fi; }
# assert_file "desc" path     → pass if path exists
assert_file() { [ -e "$2" ] && pass "$1" || fail "$1" "missing: $2"; }
# assert_grep "desc" pattern file  (REGEX — grep -E)
assert_grep() { grep -qE "$2" "$3" 2>/dev/null && pass "$1" || fail "$1" "pattern '$2' not in $3"; }
# assert_ngrep "desc" pattern file → REGEX pattern must be ABSENT
assert_ngrep(){ grep -qE "$2" "$3" 2>/dev/null && fail "$1" "pattern '$2' unexpectedly in $3" || pass "$1"; }
# assert_lit  "desc" literal file → LITERAL substring present (grep -F). Use for
# filesystem paths / hook commands / JSON fragments that contain regex metachars
# (. [ ] ( ) + /) so they aren't silently mis-matched as a regex.
assert_lit()  { grep -qF -- "$2" "$3" 2>/dev/null && pass "$1" || fail "$1" "literal '$2' not in $3"; }
# assert_nlit "desc" literal file → LITERAL substring must be ABSENT
assert_nlit() { grep -qF -- "$2" "$3" 2>/dev/null && fail "$1" "literal '$2' unexpectedly in $3" || pass "$1"; }
# assert_eq "desc" expected actual
assert_eq()   { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected '$2', got '$3'"; }

t_summary() {
  printf '  \033[1m%d passed, %d failed\033[0m\n' "$_PASS" "$_FAIL"
  [ "$_FAIL" -eq 0 ]
}
