#!/usr/bin/env bun
// Capture or check the exact exit/stderr/stdout of the guard hooks for tests/golden/guard-cases.json.
import { cpSync, mkdtempSync, readdirSync, rmSync, symlinkSync, writeFileSync, readFileSync } from 'fs';
import { join } from 'path';
import { tmpdir } from 'os';

type Case = { id: string; hook: string; input?: unknown; raw?: string; env?: string; org?: Record<string, string> };
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

function hooksDirFor(c: Case): { dir: string; cleanup: () => void } {
  const isOrgStale = c.id.endsWith('-org-stale');
  if (c.env !== 'patterns-missing' && c.env !== 'org' && !isOrgStale) {
    return { dir: join(root, 'config/hooks'), cleanup: () => {} };
  }
  const tmp = mkdtempSync(join(tmpdir(), 'golden-'));
  cpSync(join(root, 'config/hooks'), join(tmp, 'hooks'), { recursive: true });
  if (c.env === 'patterns-missing') rmSync(join(tmp, 'hooks/lib/secret-patterns.json'));
  if (c.env === 'org') writeFileSync(join(tmp, 'hooks/lib/org-egress.json'), JSON.stringify(c.org));
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
    env: { ...process.env, PATH: c.env === 'notrufflehog' || c.env === 'patterns-missing' || c.env === 'org' ? pathNoTruffle : process.env.PATH },
  });
  cleanup();
  return { id: c.id, exit: r.exitCode, stderr: r.stderr.toString(), stdout: r.stdout.toString() };
});

for (const shadow of shadowDirs) rmSync(shadow, { recursive: true, force: true });

const goldenPath = join(root, 'tests/golden/guard-output.json');
if (process.argv.includes('--check')) {
  const want = JSON.parse(readFileSync(goldenPath, 'utf-8')) as typeof out;
  for (const w of want) {
    const g = out.find((o) => o.id === w.id);
    if (!g || g.exit !== w.exit || g.stderr !== w.stderr || g.stdout !== w.stdout) {
      console.error(`golden mismatch: ${w.id}\n want: ${JSON.stringify(w)}\n got:  ${JSON.stringify(g)}`);
      process.exit(1);
    }
  }
  console.log(`golden ok: ${want.length} cases`);
} else {
  writeFileSync(goldenPath, JSON.stringify(out, null, 2) + '\n');
  console.log(`captured ${out.length} cases`);
}
