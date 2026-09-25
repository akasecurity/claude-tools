#!/usr/bin/env bash
# Guard hooks' exact exit/stderr/stdout must match the captured golden output.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v rtk >/dev/null || { echo "SKIP: rtk not installed"; exit 0; }
bun tools/capture-guard-golden.ts --check
