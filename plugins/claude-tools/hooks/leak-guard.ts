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
 * Protocol: deny → exit 2 (Claude Code blocks); allow → exit 0.
 *
 * FAIL STATES (mirroring the prior bash version's decisions exactly):
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
import { spawnSync } from 'child_process';
import { createHash } from 'crypto';

interface HookInput {
  tool_name?: string;
  tool_input?: Record<string, unknown> | string;
}
interface Patterns {
  outboundInvocation: string;
  credentialPatterns: { pattern: string; label: string }[];
}

// WEB-egress tools this guard acts on. Anything else passes through (exit 0). WebSearch /
// WebFetch are exact; the SearXNG MCP tools are matched by the mcp__searxng__ prefix —
// mirrors the bash version's `case` (WebSearch|WebFetch) ;; mcp__searxng__*) ;; gate.
function isWebEgressTool(tool: string): boolean {
  return tool === 'WebSearch' || tool === 'WebFetch' || tool.startsWith('mcp__searxng__');
}

// Load the shared credential key-shapes (single source of truth). Mirrors the bash:
//   CRED="$(jq -r '[.credentialPatterns[].pattern] | join("|")' …)"  → one alternation.
// Returns null → caller FAILS CLOSED (block the web query), when the file is missing /
// unreadable / has no patterns.
//
// DELIBERATE HARDENING over the bash version (cross-check finding, kept by decision): an
// INVALID regex fragment in secret-patterns.json also returns null here (new RegExp throws),
// so a CORRUPT patterns file fails CLOSED. The bash version's `[ -z "$CRED" ]` guard only
// caught an EMPTY join — a malformed-but-nonempty pattern slipped past it and surfaced as a
// `grep -qE` runtime error at Tier 3, which (a non-zero exit inside an `if`) fell through to
// ALLOW (exit 0). That exit-0-on-corrupt was a latent gap CONTRARY to leak-guard.sh's own
// documented contract ("if the shared patterns file is missing/CORRUPT, the guard blocks …
// rather than silently allowing"). This port fulfills that stated intent; it strengthens a
// fail-closed decision (never weakens one), and the patterns file is kit-shipped + tsc/corpus-
// validated, so this only fires on post-install tampering/corruption — exactly when blocking
// is correct.
function loadCredPattern(): RegExp | null {
  try {
    const p: Patterns = JSON.parse(readFileSync(new URL('./lib/secret-patterns.json', import.meta.url), 'utf-8'));
    if (!Array.isArray(p.credentialPatterns) || p.credentialPatterns.length === 0) return null;
    const alt = p.credentialPatterns.map((c) => c.pattern).filter((s) => typeof s === 'string' && s.length > 0);
    if (alt.length === 0) return null;
    // grep -qE -- "$CRED" is case-SENSITIVE (no -i); the JS RegExp must match that (no 'i').
    return new RegExp(alt.join('|'));
  } catch {
    return null;
  }
}

// trufflehog Tier-1 (local, detection-only). Mirrors the bash branch exactly, including
// --no-verification (load-bearing: without it trufflehog phones the candidate secret to
// the provider to "verify" — i.e. the secret leaves from the hook meant to stop it) and
// the missing-binary degradation: warn to stderr + fall through to the regex tiers.
function trufflehogDetects(text: string): boolean {
  const r = spawnSync('trufflehog', ['stdin', '--json', '--no-update', '--no-verification'],
    { input: text, encoding: 'utf-8' });
  if (r.error) {
    console.error('warn (leak-guard): trufflehog not installed — secret detection degraded to regex tiers (org markers + shared key shapes).');
    return false;
  }
  return (r.stdout || '').includes('"DetectorName"');
}

// Org-marker tier (opt-in). Reads the install-COMPILED sidecar — never sources the user's
// shell config. FAIL-SOFT on every error (missing / unparseable / malformed / bad-regex →
// org tier inactive), NEVER throws. `stale` is computed independently of whether a pattern
// is set, so a user who ADDS CT_EGRESS_PATTERNS after install (sidecar pattern still empty)
// still gets the "re-run install" nudge. `patternError` reproduces the bash version's
// distinct "compiled pattern isn't a valid regex" warning (its grep exit > 1 branch).
interface OrgTier { pattern: RegExp | null; stale: boolean; patternError: boolean }
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

function main(): void {
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

  // ── Load the shared credential definitions (single source of truth) ──
  const cred = loadCredPattern();
  if (!cred) {
    // FAIL CLOSED: patterns unloadable — block the web query, loudly.
    console.error('egress blocked (leak-guard): secret-patterns.json is missing or unreadable, so the egress scan can\'t run — blocking this query as a precaution. Restore config/hooks/lib/secret-patterns.json or reinstall.');
    process.exit(2);
  }

  // ── Tier 1: high-fidelity secret detection (generic, local-only) ──
  if (trufflehogDetects(query)) {
    console.error('egress blocked (leak-guard): query contains a detected secret (trufflehog). Reference it via an environment variable instead of pasting the literal value.');
    process.exit(2);
  }

  // ── Stale-config advisory (warns, NEVER blocks) + Tier 2: opt-in org markers ──
  const org = loadOrgTier();
  if (org.stale) {
    console.error('warn (leak-guard): aka-claude-tools.config changed since install but its org-egress patterns were not recompiled — the org-marker tier is using STALE patterns. Re-run ./install.sh to recompile. (Web egress is still scanned with the last-compiled patterns.)');
  }
  if (org.pattern) {
    if (org.pattern.test(query)) {
      console.error('egress blocked (leak-guard): query matches an internal identifier from aka-claude-tools.config (hostname, IP, path, or username). Describe it generically instead.');
      process.exit(2);
    }
  } else if (org.patternError) {
    console.error('warn (leak-guard): the compiled org-marker pattern isn\'t a valid regex — org-marker tier skipped (not silently allowed). Re-run ./install.sh.');
  }

  // ── Tier 3: shared generic key shapes (case-sensitive; require a real value) ──
  if (cred.test(query)) {
    console.error('egress blocked (leak-guard): query contains a token or key value.');
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
    main();
  } catch (e) {
    console.error('warn (leak-guard): unexpected error — egress scan SKIPPED this call (surfaced, not silent). ' + String(e));
    process.exit(0);
  }
}
