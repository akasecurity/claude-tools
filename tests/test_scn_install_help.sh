#!/usr/bin/env bash
# Help scenario: install.sh -h/--help prints usage and exits 0, and an unknown flag
# prints usage and exits 2 — both BEFORE any side effect. Before this, install.sh had
# no --help and silently ignored unknown flags, so `install.sh --help` ran a full
# install. Each case runs against a fake $HOME with CT_CONFIG_DIR pointing inside it,
# and with --defaults/--apply alongside so a regression would actually install; the
# sandbox tree must come back byte-identical. Never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_help:"

INSTALL="$REPO_ROOT/install.sh"
SB="$(sandbox)"; printf '# rc sentinel\n' > "$SB/.bashrc"
P="$SB/.claude-aka"

snapshot() { (cd "$SB" && find . -print0 | sort -z | xargs -0 shasum 2>/dev/null; find . | sort); }
before="$(snapshot)"

run() { CT_CONFIG_DIR="$P" CT_ADDITIONS="secure-settings" CT_ALIAS="zz-help-test" \
        SHELL=/bin/bash HOME="$SB" NO_COLOR=1 bash "$INSTALL" "$@" >"$SB.out" 2>"$SB.err"; }

check() { # check <label> <expected-rc> <stream-with-usage> <args...>
  local label="$1" want="$2" stream="$3"; shift 3
  run "$@"; local rc=$?
  assert_eq   "$label: exits $want" "$want" "$rc"
  assert_lit  "$label: prints usage" "Usage: install.sh" "$SB.$stream"
  assert_eq   "$label: sandbox unchanged" "$before" "$(snapshot)"
  [ -e "$P" ] && fail "$label: profile dir not created" "created: $P" || pass "$label: profile dir not created"
}

check "--help"                   0 out --help
check "-h"                       0 out -h
check "--defaults --help"        0 out --defaults --no-auth-inherit --help
check "--apply -h"               0 out --apply -h
check "unknown flag"             2 err --defaults --no-auth-inherit --bogus
check "unknown short flag"       2 err -x --apply
assert_lit "unknown flag is named" "unknown flag: -x" "$SB.err"

rm -f "$SB.out" "$SB.err"
t_summary
