#!/usr/bin/env bash
# The vendored guard-core must match its lock byte for byte and carry no host-specific literals.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
L=config/hooks/lib
lock=$L/guard-core.lock.json
[ -f "$lock" ] || { echo "FAIL: no $lock"; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
[ "$(sha $L/guard-core.js)" = "$(jq -r .sha256 "$lock")" ] || { echo "FAIL: guard-core.js hash drift"; exit 1; }
[ "$(sha $L/guard-core.d.ts)" = "$(jq -r .dtsSha256 "$lock")" ] || { echo "FAIL: guard-core.d.ts hash drift"; exit 1; }
fixtures=tests/fixtures/guard-core-conformance.json
[ -f "$fixtures" ] || { echo "FAIL: no $fixtures"; exit 1; }
[ "$(sha "$fixtures")" = "$(jq -r .fixturesSha256 "$lock")" ] || { echo "FAIL: guard-core-conformance.json hash drift — re-run tools/vendor-guard-core.sh"; exit 1; }
if grep -nE '/Users/[a-z]|/home/[a-z]|\.ts\.net|(^|[^0-9])10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.' $L/guard-core.js $L/guard-core.d.ts; then
  echo "FAIL: host-specific literal in vendored core"; exit 1
fi
bun -e "import('./$L/guard-core.js').then(m => { if (m.VERSION !== '$(jq -r .version "$lock")') process.exit(1) })"
echo "PASS vendored guard-core $(jq -r .version "$lock")"
