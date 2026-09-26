#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * mcp-guard.ts — PreToolUse hook for MCP tool calls (matcher mcp__.*). bun is a hard
 * dependency of this addition (see install.sh). Two layers, in this order:
 *   - Server policy (always applies, even where ai-tc covers the tool): CT_MCP_DENY
 *     blocks the named servers; a non-empty CT_MCP_ALLOW blocks every server not on it.
 *     Matching is case-insensitive. The lists are read from the install-COMPILED sidecar
 *     lib/mcp-policy.json; this hook never sources the user's shell config.
 *   - Secret scan over the whole tool input, keys and values at any depth, on the regex
 *     tiers only: an org internal-identifier match (CT_EGRESS_PATTERNS via
 *     lib/org-egress.json) and a shared credential key-shape (from lib/secret-patterns.json).
 *     trufflehog is not run here: this hook fires on every MCP call, so the per-call
 *     process cost stays on the Bash and web egress guards. Input that is too large or too deeply nested to walk is
 *     blocked rather than passed unscanned. Skipped where ai-tc covers MCP tools in this
 *     profile; ai-tc does the content detection there.
 *
 * This file is a thin adapter over the vendored guard-core library (lib/guard-core.js,
 * evaluateMcpInput). The adapter owns I/O: it reads the hook JSON, loads the sidecars,
 * asks guard-core whether ai-tc covers this tool, and maps rule and notice codes to this
 * kit's messages.
 *
 * Protocol: deny → exit 2 (Claude Code blocks); allow → exit 0.
 *
 * FAIL STATES:
 *   - guard-core missing, unloadable, incompatible (missing exports), throwing or returning
 *     a malformed decision → FAIL CLOSED: every MCP call is blocked, loudly.
 *   - A block decision always exits 2, even for a rule this adapter has no message for.
 *   - ai-tc detection throws → scan (the safe direction).
 *   - Shared patterns file missing/corrupt → FAIL CLOSED.
 *   - mcp-policy.json missing → no policy, silently (the plugin ships without one).
 *     Present but unreadable, unparseable or malformed → no policy, with a warning.
 *   - Config drifted from the compiled policy → advisory stale warning, never blocks.
 *   - Unparseable hook input, a body that isn't a JSON object, a missing or non-string
 *     tool_name, or any unexpected error → FAIL CLOSED (exit 2) with a clear line. A
 *     guard that cannot read the call it is guarding blocks it.
 *   - A string tool_name that isn't mcp__* → one warning line, exit 0 (a matcher
 *     misconfiguration; that tool belongs to another guard).
 * Requires: bun.
 */
import { readFileSync } from 'fs';
import { createHash } from 'crypto';
import { dirname, isAbsolute, join } from 'path';
import { homedir } from 'os';
import { fileURLToPath } from 'url';
import type { McpPolicy, OrgTier, RuleId } from './lib/guard-core.js';

interface HookInput { tool_name?: string; tool_input?: unknown; cwd?: unknown }

const P = 'mcp-guard: ';
const CORE_MISSING_MSG = P + 'blocked — the guard-core library is missing, unreadable or incompatible; blocking as a precaution. Reinstall to restore it.';

// Messages are the kit's public contract; tests/golden pins them. Keys are guard-core
// RuleIds. The Bash structural rules are never returned by evaluateMcpInput, but the
// map stays total so an unexpected one still reads well.
const BLOCK_MSG: Record<RuleId, (server: string) => string> = {
  'mcp-server-denied': (s) => `blocked — MCP server "${s}" is denied by policy (CT_MCP_DENY).`,
  // A tool name with no server segment has no server to name; the core's reason says so.
  'mcp-server-not-allowed': (s) => s
    ? `blocked — MCP server "${s}" is not on the allow list (CT_MCP_ALLOW).`
    : 'blocked — MCP tool name has no server segment; blocked by the allow list (CT_MCP_ALLOW).',
  'mcp-input-unscannable': () => 'blocked — MCP tool input has too many fields, is too large, or is too deeply nested to scan.',
  // Unreachable while the scanner is pinned to 'clean' (see main); kept so the map stays total.
  'secret-detected': () => 'blocked — MCP tool input contains a detected secret (trufflehog).',
  'org-marker': () => 'blocked — MCP tool input matches an internal identifier from aka-claude-tools.config.',
  'credential-shape': () => 'blocked — MCP tool input contains a token or key value.',
  'patterns-unavailable': () => 'blocked — the secret patterns are missing or corrupt; blocking as a precaution. Reinstall to restore them.',
  'pipe-to-shell': () => 'blocked — MCP tool input was rejected by a Bash-only rule (pipe-to-shell).',
  'startup-write': () => 'blocked — MCP tool input was rejected by a Bash-only rule (startup-write).',
  'search-exec': () => 'blocked — MCP tool input was rejected by a Bash-only rule (search-exec).',
};
const NOTICE_MSG: Record<string, string> = {
  // Not emitted while the scanner is pinned to 'clean'; kept for completeness.
  'scanner-unavailable': 'warn — trufflehog not installed; secret detection degraded to the regex tiers (org markers and shared key shapes).',
  'org-stale': 'warn — aka-claude-tools.config changed since install; the org-marker tier is using the last-compiled patterns. Re-run the installer to recompile them.',
  'org-pattern-invalid': 'warn — the compiled org-marker pattern is not a valid regex; org-marker tier skipped. Re-run the installer.',
};
const POLICY_UNREADABLE_MSG = P + 'warn — mcp-policy.json is unreadable; MCP allow/deny policy inactive.';
const POLICY_STALE_MSG = P + 'warn — aka-claude-tools.config changed since install; re-run the installer to recompile the MCP policy.';

function loadPatternsRaw(): unknown {
  try { return JSON.parse(readFileSync(new URL('./lib/secret-patterns.json', import.meta.url), 'utf-8')); }
  catch { return null; }
}

// sha256 of the raw config file bytes, the same byte domain install.sh hashes. null when
// the config is gone or unreadable (then drift can't be compared and nothing is reported).
function configHash(): string | null {
  try {
    const cfg = readFileSync(new URL('../aka-claude-tools.config', import.meta.url));
    return createHash('sha256').update(cfg).digest('hex');
  } catch { return null; }
}

function isStringArray(v: unknown): v is string[] {
  return Array.isArray(v) && v.every((x) => typeof x === 'string');
}

// Server policy from the install-compiled sidecar. Missing → no policy and no warning (a
// plugin install or a profile that never compiled one). Anything else that isn't a valid
// {allow?: string[], deny?: string[]} object → no policy, with a warning. Never throws.
function loadPolicy(): { policy?: McpPolicy; warnings: string[] } {
  let text: string;
  try {
    text = readFileSync(new URL('./lib/mcp-policy.json', import.meta.url), 'utf-8');
  } catch (e) {
    if ((e as { code?: unknown })?.code === 'ENOENT') return { warnings: [] };
    return { warnings: [POLICY_UNREADABLE_MSG] };
  }
  let sc: unknown;
  try { sc = JSON.parse(text); } catch { return { warnings: [POLICY_UNREADABLE_MSG] }; }
  if (!sc || typeof sc !== 'object' || Array.isArray(sc)) return { warnings: [POLICY_UNREADABLE_MSG] };
  const { allow = [], deny = [], sourceHash } = sc as { allow?: unknown; deny?: unknown; sourceHash?: unknown };
  if (!isStringArray(allow) || !isStringArray(deny)) return { warnings: [POLICY_UNREADABLE_MSG] };
  const warnings: string[] = [];
  if (typeof sourceHash === 'string' && sourceHash) {
    const h = configHash();
    if (h !== null && h !== sourceHash) warnings.push(POLICY_STALE_MSG);
  }
  return { policy: { allow, deny }, warnings };
}

// Org-marker tier (opt-in), from the install-compiled sidecar shared with the other
// egress guards. Fail-soft on every error; never throws.
function loadOrgTier(): OrgTier {
  try {
    const sc = JSON.parse(readFileSync(new URL('./lib/org-egress.json', import.meta.url), 'utf-8')) as
      { pattern?: string; sourceHash?: string };
    let stale = false;
    if (sc.sourceHash) {
      const h = configHash();
      stale = h !== null && h !== sc.sourceHash;
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
  // An unparseable or non-object body, or one without a string tool_name, throws into
  // the top-level catch and blocks.
  const parsed: unknown = JSON.parse(readFileSync('/dev/stdin', 'utf-8'));
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('hook input is not a JSON object');
  }
  const input = parsed as HookInput;
  if (typeof input.tool_name !== 'string') throw new Error('hook input has no string tool_name');
  const tool = input.tool_name;
  // MCP tools only. A non-MCP tool here means the hook is registered on the wrong
  // matcher: say so once and let the call through (it is another guard's surface).
  if (!tool.startsWith('mcp__')) {
    console.error(P + `warn — invoked for non-MCP tool ${JSON.stringify(tool)}; not scanned (check the hook matcher).`);
    process.exit(0);
  }

  type Core = typeof import('./lib/guard-core.js');
  let core: Core;
  try {
    core = await import('./lib/guard-core.js');
    for (const fn of ['evaluateMcpInput', 'mcpServerOf', 'detectAitc', 'coexistencePolicy', 'parsePatterns'] as const) {
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

  const { policy, warnings } = loadPolicy();
  for (const w of warnings) console.error(w);

  let d: ReturnType<Core['evaluateMcpInput']>;
  let server: string;
  try {
    server = core.mcpServerOf(tool) ?? '';
    d = core.evaluateMcpInput(tool, input.tool_input, {
      patterns: core.parsePatterns(loadPatternsRaw()),
      // Regex tiers only (key shapes + org markers). mcp-guard runs on every MCP call,
      // so trufflehog's per-call process cost stays on the Bash and web egress guards.
      scanner: () => 'clean',
      org: loadOrgTier(),
      scanSecrets,
      ...(policy ? { mcp: policy } : {}),
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
    if (line) console.error(P + line);
  }
  if (d.kind === 'block') {
    const msg = BLOCK_MSG[d.rule] as ((s: string) => string) | undefined;
    console.error(P + (msg ? msg(server) : `blocked — ${typeof d.reason === 'string' ? d.reason : 'unrecognised guard-core rule.'}`));
    process.exit(2);
  }
  process.exit(0);
}

// Top-level guard: a deliberate decision exits inside main() (process.exit 0/2); only an
// unexpected throw reaches here, and it blocks. Only runs when executed directly, so
// importing for a test never reads stdin or exits.
if (import.meta.main) {
  try {
    await main();
  } catch (e) {
    console.error(P + 'blocked — unexpected error while checking this MCP tool call; blocking as a precaution. ' + String(e));
    process.exit(2);
  }
}
