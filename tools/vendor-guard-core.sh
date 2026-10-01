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
# guard-core.js gets the MIT licence + attribution header (the MIT terms require the
# notice to travel with every copy). It goes right after the `// @bun` pragma, which
# bun only honours on the first line. The lock keeps upstream's dist hash as
# upstreamSha256 and records the vendored (headered) file's hash as sha256;
# tests/test_vendor_guard_core.sh checks both.
js=config/hooks/lib/guard-core.js
{
  IFS= read -r first < "$src/dist/guard-core.js" || true
  if [ "$first" = "// @bun" ]; then echo "$first"; fi
  cat <<'HDR'
/*
 * guard-core — vendored from guard-core, MIT, Copyright (c) 2026 William Lin
 *
 * MIT License
 *
 * Copyright (c) 2026 William Lin
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
HDR
  if [ "$first" = "// @bun" ]; then tail -n +2 "$src/dist/guard-core.js"; else cat "$src/dist/guard-core.js"; fi
} > "$js"
cp "$src/dist/guard-core.d.ts" config/hooks/lib/
mkdir -p tests/fixtures
cp "$src/fixtures/conformance.json" tests/fixtures/guard-core-conformance.json
fixtures_sha="$(shasum -a 256 tests/fixtures/guard-core-conformance.json | cut -d' ' -f1)"
js_sha="$(shasum -a 256 "$js" | cut -d' ' -f1)"
jq --arg s "$(git -C "$src" rev-parse HEAD)" --arg f "$fixtures_sha" --arg j "$js_sha" \
  '. + {upstreamSha256:.sha256, sha256:$j, source:$s, fixturesSha256:$f}' \
  "$src/dist/guard-core.lock.json" > config/hooks/lib/guard-core.lock.json
echo "vendored guard-core $(jq -r .version config/hooks/lib/guard-core.lock.json)"
