#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * integrity-check.ts — SessionStart self-integrity check for a kit-installed profile.
 *
 * At install time, install.sh records <profile>/.aka-integrity.json:
 *
 *   { version: 1,
 *     files:    { "<relpath>": "<sha256>" },   // every kit-placed file under hooks/ and bin/
 *     settings: "<sha256>",                    // sha256 of the kit-managed settings subset
 *     kit:      { deny: [...], sandbox: bool, statusLine: bool } }
 *
 * The settings subset is defined once, in hooks/lib/managed-settings.jq, and both sides run
 * that same program through `jq -S -c` and hash its output bytes. `kit` records the inputs
 * the program needs that settings.json alone can't supply (which deny rules the kit shipped,
 * and whether it installed the sandbox and status line).
 *
 * At session start this hook recomputes both:
 *   - every manifest file is re-hashed; a changed or missing file counts as drift;
 *   - every file under hooks/lib/ that the manifest doesn't list counts as drift too. Those
 *     sidecars (trusted-bootstrap.json, mcp-policy.json, …) are plain JSON a Bash tool call
 *     can write, so a forged one must not pass just because it looks well-formed;
 *   - the settings subset is re-extracted and re-hashed. If jq isn't on PATH this part is
 *     skipped silently; the file check still runs.
 *
 * Nothing differs: silent, exit 0. Anything differs: ONE stderr line naming the count and
 * pointing at `aka-claude-tools --audit` (which lists the specifics), a kind:"integrity"
 * audit-log event, and exit 2. For SessionStart, exit 2 is not a block (a SessionStart hook
 * can't block); Claude Code shows its stderr to the user, while exit 0's stderr is dropped.
 *
 * This is detection, not a boundary: anything that can rewrite the manifest as well as the
 * files can hide its changes. It exists to surface accidental drift and a tool call quietly
 * rewriting a hook or sidecar.
 *
 * Never blocks, and fails silent on its own errors: no profile meta, no manifest, an
 * unreadable manifest, guard-core missing, a plugin install path, or any unexpected throw
 * all end in exit 0 with no output.
 * Requires: bun. jq is optional (settings check only).
 */
import { createHash } from 'crypto';
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'fs';
import { dirname, join } from 'path';
import { homedir } from 'os';
import { fileURLToPath } from 'url';

type Core = typeof import('./lib/guard-core.js');

interface Manifest {
  version: 1;
  files: Record<string, string>;
  settings?: string;
  kit?: { deny?: string[]; sandbox?: boolean; statusLine?: boolean };
}

export function notice(changedFiles: number, settingsDrift: boolean): string {
  return `claude-tools: ${changedFiles} kit file(s) changed or missing, `
    + `${settingsDrift ? 'settings drift' : 'settings OK'}; run aka-claude-tools --audit`;
}

// The profile this session runs in. Same resolution as the other kit hooks.
function profileRoots(): string[] {
  const env = process.env.CLAUDE_CONFIG_DIR;
  if (env && env.startsWith('/')) return [env];
  const hooksDir = dirname(fileURLToPath(import.meta.url));
  if (hooksDir.endsWith('/hooks') && !hooksDir.includes('/plugins/')) return [dirname(hooksDir)];
  return [join(homedir(), '.claude')];
}

// A plugin copy has no manifest of its own to check, and must never report against a
// full-kit profile it happens to run inside (that profile's own copy does that).
function isPluginInstall(): boolean {
  return dirname(fileURLToPath(import.meta.url)).includes('/plugins/');
}

function sha256(buf: Buffer | string): string {
  return createHash('sha256').update(buf).digest('hex');
}

function readManifest(root: string): Manifest | null {
  try {
    const m = JSON.parse(readFileSync(join(root, '.aka-integrity.json'), 'utf-8'));
    if (!m || typeof m !== 'object' || Array.isArray(m) || m.version !== 1) return null;
    if (!m.files || typeof m.files !== 'object' || Array.isArray(m.files)) return null;
    return m as Manifest;
  } catch {
    return null;
  }
}

// A manifest path must stay inside the profile: relative, no `..` segment.
function safeRel(rel: string): boolean {
  return rel.length > 0 && !rel.startsWith('/') && !rel.split('/').includes('..');
}

// Every regular file under <root>/<rel>, as profile-relative paths, recursively.
function listFiles(root: string, rel: string): string[] {
  const out: string[] = [];
  let names: string[];
  try { names = readdirSync(join(root, rel)); } catch { return out; }
  for (const name of names) {
    const child = `${rel}/${name}`;
    let st;
    try { st = statSync(join(root, child)); } catch { out.push(child); continue; }
    if (st.isDirectory()) out.push(...listFiles(root, child));
    else out.push(child);
  }
  return out;
}

/** Changed, missing and unexpected (hooks/lib/) files, as profile-relative paths. */
export function fileDrift(root: string, m: Manifest): { changed: string[]; missing: string[]; unexpected: string[] } {
  const changed: string[] = [];
  const missing: string[] = [];
  for (const [rel, want] of Object.entries(m.files)) {
    if (!safeRel(rel) || typeof want !== 'string') { changed.push(rel); continue; }
    let buf: Buffer;
    try { buf = readFileSync(join(root, rel)); } catch { missing.push(rel); continue; }
    if (sha256(buf) !== want) changed.push(rel);
  }
  const unexpected = listFiles(root, 'hooks/lib').filter((rel) => !(rel in m.files));
  return { changed, missing, unexpected };
}

/**
 * True when the kit-managed settings subset no longer hashes to the manifest's value,
 * false when it matches, null when it can't be checked (no jq, no recorded hash, or jq
 * failing on the input) — the caller treats null as "skip", never as drift.
 */
export function settingsDrift(root: string, m: Manifest): boolean | null {
  if (typeof m.settings !== 'string') return null;
  const jq = Bun.which('jq');
  if (!jq) return null;
  const prog = join(root, 'hooks', 'lib', 'managed-settings.jq');
  if (!existsSync(prog)) return null;
  let settings = '{}';
  try { settings = readFileSync(join(root, 'settings.json'), 'utf-8'); } catch { settings = '{}'; }
  const roots = [root];
  try { const real = realpathSync(root); if (!roots.includes(real)) roots.push(real); } catch { /* keep as given */ }
  const r = Bun.spawnSync([
    jq, '-S', '-c',
    '--argjson', 'm', JSON.stringify({ files: m.files, kit: m.kit ?? {} }),
    '--arg', 'home', homedir(),
    '--argjson', 'roots', JSON.stringify(roots),
    '-f', prog,
  ], { stdin: Buffer.from(settings), stdout: 'pipe', stderr: 'ignore' });
  if (r.exitCode !== 0 || !r.stdout) return null;
  return sha256(Buffer.from(r.stdout)) !== m.settings;
}

async function main(): Promise<number> {
  if (isPluginInstall()) return 0;
  const root = profileRoots()[0];
  if (!root || !existsSync(join(root, '.aka-claude-tools-meta'))) return 0;
  const m = readManifest(root);
  if (!m) return 0;

  let core: Core;
  try {
    core = await import('./lib/guard-core.js');
    for (const fn of ['coexistencePolicy', 'detectAitc', 'formatAuditLine'] as const) {
      if (typeof core[fn] !== 'function') throw new Error(`guard-core export ${fn} missing`);
    }
  } catch {
    return 0;
  }

  const f = fileDrift(root, m);
  const n = f.changed.length + f.missing.length + f.unexpected.length;
  let sd = false;
  try { sd = settingsDrift(root, m) === true; } catch { sd = false; }
  if (n === 0 && !sd) return 0;

  const line = notice(n, sd);
  console.error(line);

  // The check itself always runs (ai-tc or not); only the audit line follows the log policy.
  try {
    let auditLog = true;
    try {
      auditLog = core.coexistencePolicy(core.detectAitc('claude', { home: homedir(), roots: [root] })).auditLog !== false;
    } catch { auditLog = true; }
    const { appendAudit } = await import('./lib/audit.ts');
    appendAudit(
      { hook: 'integrity-check', kind: 'integrity', detail: line.replace(/^claude-tools: /, '') },
      { profileRoot: root, enabled: auditLog, patterns: core.DEFAULT_PATTERNS },
    );
  } catch { /* audit logging must never affect the check */ }
  return 2;
}

if (import.meta.main) {
  let code = 0;
  try { code = await main(); } catch { code = 0; }
  process.exit(code);
}
