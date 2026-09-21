#!/usr/bin/env bash
# Wrapper so the test_*.sh glob in run.sh picks up the in-process TypeScript unit tests
# for config/hooks/rtk-safe.ts. The real assertions live in rtk-safe.test.ts (run under
# bun, which the suite already preflights as a hard dep). Sandbox HOME/TMPDIR so importing
# the hook never touches a real profile or the operator's shared /tmp.
SB="$(mktemp -d "${TMPDIR:-/tmp}/aka-rtk-unit.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB" TMPDIR="$SB"
unset CLAUDE_CONFIG_DIR XDG_RUNTIME_DIR
bun "$(dirname "${BASH_SOURCE[0]}")/rtk-safe.test.ts"
