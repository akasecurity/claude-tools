#!/usr/bin/env bash
set -euo pipefail
bun "$(dirname "${BASH_SOURCE[0]}")/rtk-safe-behavior.test.ts"
