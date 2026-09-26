#!/usr/bin/env bun
// Capture or check the exact exit/stderr/stdout of the guard hooks for tests/golden/guard-cases.json.
import { chmodSync, cpSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync, readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

type Case = {
  id: string; hook: string; input?: unknown; raw?: string; env?: string; org?: Record<string, string>;
  // env "mcp-policy": the hooks copy gets lib/mcp-policy.json built from this.
  mcp?: { allow?: string[]; deny?: string[] };
  // Optional: for a case whose stderr embeds something incidental (e.g. a JS engine's
  // own TypeError text on an unexpected-error path) rather than a message this repo
  // owns, pin only a fixed prefix instead of the exact line. See --check below.
  stderrPrefix?: string;
};
const root = join(import.meta.dir, '..');
const cases: Case[] = JSON.parse(readFileSync(join(root, 'tests/golden/guard-cases.json'), 'utf-8'));

// Build a trufflehog-free PATH so the golden output never depends on whether the
// host happens to have trufflehog installed (both guards degrade to the regex
// tiers when it's absent, and that degraded-mode line is part of what we pin).
//
// A naive `PATH.split(':').filter(dir has no trufflehog)` drops the WHOLE directory
// that trufflehog lives in — which on a Homebrew host is also where `bun` and `rtk`
// live (/opt/homebrew/bin), so the spawned hook process itself (or its internal `rtk
// --version` probe in rtk-safe.ts) can no longer be found. Instead, shadow any PATH
// entry that contains trufflehog with a temp dir of symlinks to everything in it
// EXCEPT trufflehog, so every other tool on that PATH entry stays resolvable.
const shadowDirs: string[] = [];
function buildPathNoTrufflehog(): string {
  const dirs = (process.env.PATH ?? '').split(':').filter(Boolean);
  const out: string[] = [];
  for (const d of dirs) {
    if (!Bun.which('trufflehog', { PATH: d })) { out.push(d); continue; }
    const shadow = mkdtempSync(join(tmpdir(), 'golden-path-'));
    shadowDirs.push(shadow);
    let entries: string[] = [];
    try { entries = readdirSync(d); } catch { continue; }
    for (const e of entries) {
      if (e === 'trufflehog') continue;
      try { symlinkSync(join(d, e), join(shadow, e)); } catch { /* dup/unreadable entry — skip */ }
    }
    out.push(shadow);
  }
  return out.join(':');
}
const pathNoTruffle = buildPathNoTrufflehog();

// A PATH whose `trufflehog` is a stub that ALWAYS reports a detection, regardless of
// input — for pinning the trufflehog-DETECTS-a-secret block lines (command-guard.ts's
// "outbound command contains a detected secret" / leak-guard.ts's "query contains a
// detected secret"). Built on top of pathNoTruffle (the real trufflehog, if any, is
// already hidden from PATH there) with one more temp dir — holding only the stub —
// prepended, so the stub always wins PATH resolution. Host-independent and
// deterministic: it never shells out to a real trufflehog binary or depends on one
// being installed.
function buildPathTrufflehogHit(): string {
  const stubDir = mkdtempSync(join(tmpdir(), 'golden-stub-'));
  shadowDirs.push(stubDir);
  const stubPath = join(stubDir, 'trufflehog');
  writeFileSync(stubPath, '#!/bin/sh\ncat >/dev/null\necho \'{"DetectorName":"X"}\'\n');
  chmodSync(stubPath, 0o755);
  return [stubDir, pathNoTruffle].join(':');
}
const pathTrufflehogHit = buildPathTrufflehogHit();

function hooksDirFor(c: Case): { dir: string; cleanup: () => void } {
  const isOrgStale = c.id.endsWith('-org-stale');
  if (c.env !== 'patterns-missing' && c.env !== 'org' && c.env !== 'mcp-policy' && c.env !== 'core-missing' && !isOrgStale) {
    return { dir: join(root, 'config/hooks'), cleanup: () => {} };
  }
  const tmp = mkdtempSync(join(tmpdir(), 'golden-'));
  cpSync(join(root, 'config/hooks'), join(tmp, 'hooks'), { recursive: true });
  if (c.env === 'patterns-missing') rmSync(join(tmp, 'hooks/lib/secret-patterns.json'));
  if (c.env === 'org') writeFileSync(join(tmp, 'hooks/lib/org-egress.json'), JSON.stringify(c.org));
  if (c.env === 'mcp-policy') {
    writeFileSync(join(tmp, 'hooks/lib/mcp-policy.json'),
      JSON.stringify({ allow: c.mcp?.allow ?? [], deny: c.mcp?.deny ?? [], sourceHash: '' }));
  }
  if (c.env === 'core-missing') rmSync(join(tmp, 'hooks/lib/guard-core.js'));
  if (isOrgStale) {
    // A sidecar whose sourceHash doesn't match the (freshly-written) config file, so
    // both guards' stale-config advisory fires alongside the org-marker block.
    writeFileSync(join(tmp, 'hooks/lib/org-egress.json'), JSON.stringify({ pattern: 'corp-internal\\.example', sourceHash: '0' }));
    writeFileSync(join(tmp, 'aka-claude-tools.config'), 'CT_EGRESS_PATTERNS=x\n');
  }
  return { dir: join(tmp, 'hooks'), cleanup: () => rmSync(tmp, { recursive: true, force: true }) };
}

if (!Bun.which('rtk')) {
  console.error('capture-guard-golden: rtk is required (rs-git-status depends on it) — install rtk before capturing.');
  process.exit(1);
}

const out = cases.map((c) => {
  const { dir, cleanup } = hooksDirFor(c);
  const r = Bun.spawnSync([process.execPath, join(dir, `${c.hook}.ts`)], {
    stdin: new TextEncoder().encode(c.raw ?? JSON.stringify(c.input)),
    env: {
      ...process.env,
      PATH: c.env === 'trufflehog-hit' ? pathTrufflehogHit
        : c.env === 'notrufflehog' || c.env === 'patterns-missing' || c.env === 'org'
          || c.env === 'mcp-policy' || c.env === 'core-missing' ? pathNoTruffle
        : process.env.PATH,
    },
  });
  cleanup();
  return {
    id: c.id, exit: r.exitCode, stderr: r.stderr.toString(), stdout: r.stdout.toString(),
    ...(c.stderrPrefix !== undefined ? { stderrPrefix: c.stderrPrefix } : {}),
  };
});

for (const shadow of shadowDirs) rmSync(shadow, { recursive: true, force: true });

const goldenPath = join(root, 'tests/golden/guard-output.json');
if (process.argv.includes('--check')) {
  const want = JSON.parse(readFileSync(goldenPath, 'utf-8')) as typeof out;
  // Two-way id check FIRST: `out` is built from the LIVE guard-cases.json, so a case
  // added there without re-capturing must fail loudly here rather than passing
  // silently because the compare loop below only ever walks `want`'s ids. Equally, a
  // case removed from guard-cases.json but still sitting in the golden file (stale)
  // must fail too — the golden file no longer describes what the case list produces.
  const wantIds = new Set(want.map((w) => w.id));
  const gotIds = new Set(out.map((o) => o.id));
  const newInCases = out.map((o) => o.id).filter((id) => !wantIds.has(id));
  const missingFromCases = want.map((w) => w.id).filter((id) => !gotIds.has(id));
  if (newInCases.length || missingFromCases.length) {
    if (newInCases.length) console.error(`golden mismatch: case(s) in guard-cases.json not captured in guard-output.json: ${newInCases.join(', ')} — re-run without --check to capture`);
    if (missingFromCases.length) console.error(`golden mismatch: case(s) in guard-output.json no longer in guard-cases.json: ${missingFromCases.join(', ')} — stale golden entries, re-run without --check to recapture`);
    process.exit(1);
  }
  for (const w of want) {
    const g = out.find((o) => o.id === w.id);
    // A case with stderrPrefix carries something incidental in its full stderr (a JS
    // engine's own error text on an unexpected-error path, not a message this repo
    // owns) — exit and stdout still compare exactly, but stderr only has to START WITH
    // the fixed prefix rather than match byte-for-byte.
    const stderrOk = w.stderrPrefix !== undefined
      ? !!g && g.stderr.startsWith(w.stderrPrefix)
      : g?.stderr === w.stderr;
    if (!g || g.exit !== w.exit || !stderrOk || g.stdout !== w.stdout) {
      console.error(`golden mismatch: ${w.id}\n want: ${JSON.stringify(w)}\n got:  ${JSON.stringify(g)}`);
      process.exit(1);
    }
  }
  console.log(`golden ok: ${want.length} cases`);
} else {
  writeFileSync(goldenPath, JSON.stringify(out, null, 2) + '\n');
  console.log(`captured ${out.length} cases`);
}
