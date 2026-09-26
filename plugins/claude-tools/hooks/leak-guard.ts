#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * leak-guard.ts — PreToolUse hook for the WEB-egress tools (WebSearch / WebFetch /
 * SearXNG MCP). The WEB egress guard (bun is a hard dependency of this addition; see
 * install.sh). It scans WEB tool inputs ONLY — Bash egress is command-guard.ts's surface
 * (one PreToolUse process per tool surface). It blocks a web query/url/prompt whose
 * CONTENT carries a secret, via:
 *   - DENY Tier 1: a detected secret (trufflehog, run local / --no-verification so the
 *     candidate never leaves the box). Degrades to the regex tiers if trufflehog absent.
 *   - DENY Tier 2: a match against your opt-in org markers (CT_EGRESS_PATTERNS). The
 *     pattern is read from the install-COMPILED sidecar lib/org-egress.json — this hook
 *     NEVER sources the user's shell config (a bun process can't safely evaluate arbitrary
 *     shell). install.sh compiles + validates the pattern; here we only consume validated
 *     JSON. Both guards consume the same sidecar, so they can't drift.
 *   - DENY Tier 3: a shared credential key-SHAPE (from lib/secret-patterns.json — one
 *     source of truth, also read by command-guard for Bash egress).
 *
 * It reads DIFFERENT tool_input fields than command-guard: the WebSearch `query`, the
 * WebFetch `url`/`prompt`, and the SearXNG MCP fields (searxng_web_search → .query,
 * web_url_read → .url) — all extracted as the same {query,url,prompt} join below. The
 * SearXNG surface is scanned because secure-deep-research routes SENSITIVE topics through
 * self-hosted SearXNG precisely for privacy, so that egress must be scanned too; admitted
 * unconditionally (a no-op when no SearXNG server is configured).
 *
 * This file is a thin adapter: the tier logic lives in the vendored guard-core library
 * (lib/guard-core.js, evaluateWebQuery). The adapter owns I/O: it reads the hook JSON,
 * loads lib/secret-patterns.json and the org sidecar, asks guard-core whether ai-tc covers
 * this tool in this profile (if so the scan is skipped for that tool; WebSearch is not an
 * ai-tc tool and is always scanned), and maps the core's rule and notice codes to this
 * kit's messages.
 *
 * Protocol: deny → exit 2 (Claude Code blocks); allow → exit 0.
 *
 * FAIL STATES (mirroring the prior bash version's decisions exactly):
 *   - guard-core missing, unloadable, incompatible (missing exports), throwing or returning
 *     a malformed decision → FAIL CLOSED: every web query is blocked, loudly.
 *   - A block decision always exits 2, even for a rule this adapter has no message for.
 *   - ai-tc detection throws → scan (the safe direction).
 *   - Shared patterns file missing/corrupt → FAIL CLOSED (block the web query loudly),
 *     since we cannot run the credential scan we exist to run.
 *   - Org sidecar missing / unparseable / malformed / bad-regex → org tier INACTIVE
 *     (it is opt-in); a bad config is a loud WARNING, never a silent skip or a crash.
 *   - Config drifted from the compiled sidecar → advisory STALE warning, never blocks.
 *   - Unparseable stdin → fail open, but LOUDLY (stderr). (The old bash version warned +
 *     allowed only on a missing jq — its one fail-open; under bun there is no jq, so the
 *     equivalent fail-open is an unparseable hook input.)
 * Requires: bun.
 */
import { readFileSync } from 'fs';
import { createHash } from 'crypto';
import { dirname, isAbsolute, join } from 'path';
import { homedir } from 'os';
import { fileURLToPath } from 'url';
import type { OrgTier, RuleId } from './lib/guard-core.js';

interface HookInput { tool_name?: string; tool_input?: Record<string, unknown> | string; cwd?: unknown }

const CORE_MISSING_MSG = 'egress blocked (leak-guard): the guard-core library is missing or unreadable, so the egress scan can\'t run — blocking this query as a precaution. Reinstall to restore config/hooks/lib/guard-core.js.';

// Messages are the kit's public contract; tests/golden pins them. Keys are guard-core RuleIds.
// leak-guard only ever sees the web tiers; the structural rules are Bash-only and never
// returned by evaluateWebQuery, but the map stays total so an unexpected one still reads well.
const BLOCK_MSG: Record<RuleId, string> = {
  'patterns-unavailable': 'egress blocked (leak-guard): secret-patterns.json is missing or unreadable, so the egress scan can\'t run — blocking this query as a precaution. Restore config/hooks/lib/secret-patterns.json or reinstall.',
  'secret-detected': 'egress blocked (leak-guard): query contains a detected secret (trufflehog). Reference it via an environment variable instead of pasting the literal value.',
  'org-marker': 'egress blocked (leak-guard): query matches an internal identifier from aka-claude-tools.config (hostname, IP, path, or username). Describe it generically instead.',
  'credential-shape': 'egress blocked (leak-guard): query contains a token or key value.',
  'pipe-to-shell': 'egress blocked (leak-guard): query was rejected by a structural rule (pipe-to-shell).',
  'startup-write': 'egress blocked (leak-guard): query was rejected by a structural rule (startup-write).',
  'search-exec': 'egress blocked (leak-guard): query was rejected by a structural rule (search-exec).',
};
const NOTICE_MSG: Record<string, string> = {
  'scanner-unavailable': 'warn (leak-guard): trufflehog not installed — secret detection degraded to regex tiers (org markers + shared key shapes).',
  'org-stale': 'warn (leak-guard): aka-claude-tools.config changed since install but its org-egress patterns were not recompiled — the org-marker tier is using STALE patterns. Re-run ./install.sh to recompile. (Web egress is still scanned with the last-compiled patterns.)',
  'org-pattern-invalid': 'warn (leak-guard): the compiled org-marker pattern isn\'t a valid regex — org-marker tier skipped (not silently allowed). Re-run ./install.sh.',
};

// WEB-egress tools this guard acts on. Anything else passes through (exit 0). WebSearch /
// WebFetch are exact; the SearXNG MCP tools are matched by the mcp__searxng__ prefix —
// mirrors the bash version's `case` (WebSearch|WebFetch) ;; mcp__searxng__*) ;; gate.
function isWebEgressTool(tool: string): boolean {
  return tool === 'WebSearch' || tool === 'WebFetch' || tool.startsWith('mcp__searxng__');
}

function loadPatternsRaw(): unknown {
  try { return JSON.parse(readFileSync(new URL('./lib/secret-patterns.json', import.meta.url), 'utf-8')); }
  catch { return null; }
}

// Org-marker tier (opt-in). Reads the install-COMPILED sidecar — never sources the user's
// shell config. FAIL-SOFT on every error (missing / unparseable / malformed / bad-regex →
// org tier inactive), NEVER throws. `stale` is computed independently of whether a pattern
// is set, so a user who ADDS CT_EGRESS_PATTERNS after install (sidecar pattern still empty)
// still gets the "re-run install" nudge. `patternError` reproduces the bash version's
// distinct "compiled pattern isn't a valid regex" warning (its grep exit > 1 branch).
function loadOrgTier(): OrgTier {
  try {
    const sc = JSON.parse(readFileSync(new URL('./lib/org-egress.json', import.meta.url), 'utf-8')) as
      { pattern?: string; sourceHash?: string };
    let stale = false;
    if (sc.sourceHash) {
      try {
        // Hash the RAW config FILE BYTES — the same byte domain install.sh hashes (NOT the
        // shell-expanded value), so quoting-identical edits don't false-drift. sha256 hex is
        // implementation-independent, so this equals install.sh's portable sha256.
        const cfg = readFileSync(new URL('../aka-claude-tools.config', import.meta.url));
        stale = createHash('sha256').update(cfg).digest('hex') !== sc.sourceHash;
      } catch { /* config gone/unreadable → can't compare; treat as not-stale */ }
    }
    let pattern: RegExp | null = null;
    let patternError = false;
    if (sc.pattern) {
      try { pattern = new RegExp(sc.pattern); } catch { pattern = null; patternError = true; }
    }
    return { pattern, stale, patternError };
  } catch {
    return { pattern: null, stale: false, patternError: false };
  }
}

// The session's project directory, from the hook input's `cwd`. Only an absolute path is
// passed on: a project's .claude/settings(.local).json can switch ai-tc off for itself.
function projectOpt(input: { cwd?: unknown }): { projectDir?: string } {
  return typeof input.cwd === 'string' && isAbsolute(input.cwd) ? { projectDir: input.cwd } : {};
}

// The profile this session runs in: ai-tc only counts if its hooks run here too.
function profileRoots(): string[] {
  const env = process.env.CLAUDE_CONFIG_DIR;
  if (env && env.startsWith('/')) return [env];
  const hooksDir = dirname(fileURLToPath(import.meta.url));
  if (hooksDir.endsWith('/hooks') && !hooksDir.includes('/plugins/')) return [dirname(hooksDir)];
  return [join(homedir(), '.claude')];
}

// guard-core missing, unreadable, incompatible, throwing or malformed: fail closed.
function coreUnavailable(): never {
  console.error(CORE_MISSING_MSG);
  process.exit(2);
}

async function main(): Promise<void> {
  let input: HookInput;
  try {
    const raw = readFileSync('/dev/stdin', 'utf-8');
    if (!raw.trim()) process.exit(0);
    input = JSON.parse(raw);
  } catch {
    // Fail open, but loudly. (The bash version's only fail-open was a missing jq; under
    // bun the equivalent is an unparseable hook input.)
    console.error('warn (leak-guard): could not parse hook input — egress scan SKIPPED this call. If this recurs, the hook may be misconfigured.');
    process.exit(0);
  }

  // Deliberately no null-guard on the parsed value: a JSON `null` body throws here and
  // is surfaced by the top-level catch, as before.
  const tool = typeof input.tool_name === 'string' ? input.tool_name : '';
  // Web egress tools only — Bash (and everything else) is not this hook's surface.
  if (!isWebEgressTool(tool)) process.exit(0);

  // Scan the same fields the bash version joined: query, url, prompt (drop nulls, space-join).
  const ti = (typeof input.tool_input === 'object' && input.tool_input !== null)
    ? (input.tool_input as Record<string, unknown>) : {};
  const query = [ti.query, ti.url, ti.prompt]
    .filter((v): v is string => typeof v === 'string')
    .join(' ');
  if (!query) process.exit(0);

  type Core = typeof import('./lib/guard-core.js');
  let core: Core;
  try {
    core = await import('./lib/guard-core.js');
    for (const fn of ['evaluateWebQuery', 'detectAitc', 'coexistencePolicy', 'parsePatterns'] as const) {
      if (typeof core[fn] !== 'function') throw new Error(`guard-core export ${fn} missing`);
    }
  } catch {
    coreUnavailable();
  }

  // ai-tc detection only ever turns scanning off; if it throws, scan (the safe direction).
  let scanSecrets = true;
  try {
    scanSecrets = core.coexistencePolicy(core.detectAitc('claude', { home: homedir(), roots: profileRoots(), ...projectOpt(input) }))
      .scanSecrets(tool) !== false;
  } catch { scanSecrets = true; }

  let d: ReturnType<Core['evaluateWebQuery']>;
  try {
    d = core.evaluateWebQuery(query, {
      patterns: core.parsePatterns(loadPatternsRaw()),
      org: loadOrgTier(),
      scanSecrets,
    });
    if (!d || typeof d !== 'object' || !Array.isArray(d.notices) || (d.kind !== 'allow' && d.kind !== 'block')) {
      throw new Error('malformed guard-core decision');
    }
  } catch {
    coreUnavailable();
  }
  for (const n of d.notices as unknown[]) {
    if (!n || typeof n !== 'object') continue;
    const code = (n as { code?: unknown }).code;
    const line = typeof code === 'string' ? NOTICE_MSG[code] : undefined;
    if (line) console.error(line);
  }
  if (d.kind === 'block') {
    const msg = BLOCK_MSG[d.rule] as string | undefined;
    console.error(msg ?? `egress blocked (leak-guard): ${typeof d.reason === 'string' ? d.reason : 'unrecognised guard-core rule.'}`);
    process.exit(2);
  }
  process.exit(0);
}

// Top-level guard: a deliberate decision exits inside main() (process.exit 0/2); only an
// UNEXPECTED throw reaches here. Degrade the documented way — loud on stderr, allow
// (exit 0) — rather than into bun's undefined non-zero exit. Only runs when executed
// directly, so importing for a test never reads stdin / exits.
if (import.meta.main) {
  try {
    await main();
  } catch (e) {
    console.error('warn (leak-guard): unexpected error — egress scan SKIPPED this call (surfaced, not silent). ' + String(e));
    process.exit(0);
  }
}
