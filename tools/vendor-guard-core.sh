#!/usr/bin/env bash
# Vendor guard-core's built bundle into config/hooks/lib. Usage: tools/vendor-guard-core.sh <guard-core checkout>
set -euo pipefail
src="${1:?usage: $0 <guard-core checkout>}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# Refuse a dirty checkout: build.ts --check only verifies dist/ matches the
# CURRENT working tree, not the recorded HEAD, so an uncommitted edit (tracked,
# staged, or untracked) could pass --check and still get vendored, and the lock's
# "source" (HEAD's SHA) would then misattribute the vendored bytes to a commit
# that doesn't contain them.
[ -z "$(git -C "$src" status --porcelain --untracked-files=normal -- . ':!node_modules')" ] \
  || { echo "guard-core checkout has uncommitted changes; commit first" >&2; exit 1; }
( cd "$src" && bun scripts/build.ts --check ) || { echo "guard-core dist is stale; build it first" >&2; exit 1; }
cp "$src/dist/guard-core.js" "$src/dist/guard-core.d.ts" config/hooks/lib/
jq --arg s "$(git -C "$src" rev-parse HEAD)" '. + {source:$s}' "$src/dist/guard-core.lock.json" > config/hooks/lib/guard-core.lock.json
echo "vendored guard-core $(jq -r .version config/hooks/lib/guard-core.lock.json)"
