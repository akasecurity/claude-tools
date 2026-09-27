#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * post-guard.ts — PostToolUse hook for tool OUTPUT (matcher WebFetch|WebSearch|Read|mcp__.*).
 * bun is a hard dependency of this addition (see install.sh). Two independent passes over a
 * finished tool call's result, before the model reads it:
 *
 *   - Redaction: replaces credential-shaped values (guard-core's redactValue, the same shared
 *     pattern set every other guard in this kit reads) in the tool's response, and rewrites
 *     the response in its ORIGINAL shape via the Claude Code PostToolUse hook fields
 *     (`updatedToolOutput` for Read/WebFetch/WebSearch, `updatedMCPToolOutput` for `mcp__*`).
 *     Skipped for a tool ai-tc's own PostToolUse hook already covers in this profile — under
 *     Claude Code that's Read and WebFetch (see guard-core's coexistencePolicy/redactOutput);
 *     WebSearch and every `mcp__*` tool are never covered there, so this hook keeps redacting
 *     them regardless of ai-tc.
 *   - Injection-marker warning: a heads-up, never a block, when fetched, searched, or
 *     MCP-returned content contains a phrase like "ignore previous instructions" — content the
 *     agent did not author and should treat as untrusted data, not new instructions. Runs on
 *     WebFetch, WebSearch and MCP output regardless of ai-tc's presence (this is a warning, not
 *     an output rewrite ai-tc already does). Read output is not scanned for injection markers:
 *     a local file the agent chose to read is not untrusted external content the same way.
 *
 * An MCP content block is scanned by both passes when it carries text: a `{ type: "text",
 * text }` block's own text, or a `{ type: "resource", resource: { text } }` embedded
 * resource's text payload. Everything else — an `image` block's data, a resource that only
 * carries `blob` (base64 binary), or any other block type — is never scanned or rewritten
 * and passes through byte-for-byte.
 *
 * A PostToolUse hook can't block a call that already ran, so this hook never exits non-zero
 * on a decision: it either rewrites the response (redaction), prints a stderr notice
 * (redaction summary, truncated-scan, or an injection marker), or emits nothing at all on a
 * clean, unremarkable result. On an internal failure that disables the whole hook —
 * unparseable stdin (or a body that isn't a usable JSON object), guard-core missing or
 * incompatible, or an unexpected error escaping the top level — it prints exactly ONE
 * stderr line saying so and passes the original tool output through unchanged; stdout stays
 * empty and it still exits 0. A failure in one sub-feature (ai-tc detection, the redaction
 * pass, the injection scan, or the audit log) degrades that feature alone and stays silent,
 * rather than disabling the other passes too.
 * Requires: bun.
 */
import { readFileSync } from 'fs';
import { dirname, isAbsolute, join } from 'path';
import { homedir } from 'os';
import { fileURLToPath } from 'url';

interface HookInput { tool_name?: string; tool_response?: unknown; cwd?: unknown }
type Core = typeof import('./lib/guard-core.js');
type RedactValueResult = ReturnType<Core['redactValue']>;

const P = 'post-guard: ';
// Printed exactly once, on the three failures that disable the WHOLE hook (see the file
// doc's fail-state contract) — never on a sub-feature failure, which stays silent instead.
const STDIN_FAIL_MSG = P + 'disabled — could not parse the hook input; original tool output passed through unchanged.';
const CORE_FAIL_MSG = P + 'disabled — the guard-core library is missing or incompatible; original tool output passed through unchanged.';
const UNEXPECTED_FAIL_MSG = P + 'disabled — unexpected internal error; original tool output passed through unchanged.';

// Tools this hook redacts output for. mcp__* is matched by prefix, not listed here.
const REDACT_TOOLS = new Set(['Read', 'WebFetch', 'WebSearch']);
function isRedactTool(tool: string): boolean {
  return REDACT_TOOLS.has(tool) || tool.startsWith('mcp__');
}
// Tools this hook scans for prompt-injection markers. Read is deliberately excluded — see
// the file doc above.
const INJECTION_TOOLS = new Set(['WebFetch', 'WebSearch']);
function isInjectionTool(tool: string): boolean {
  return INJECTION_TOOLS.has(tool) || tool.startsWith('mcp__');
}

// The scannable text out of one MCP content block: a `{ type: "text", text }` block's own
// text, or a `{ type: "resource", resource: { text } }` embedded resource's text payload.
// Anything else — `image`, a resource that only carries `blob` (base64 binary), or an
// unrecognised block type — has nothing scannable and returns ''. Shared by the redaction
// pass (redactMcpResponse) and the injection scan (injectionScanText) below, so both
// treat the same set of blocks as "has text" and neither scans image/blob content.
function mcpBlockText(block: unknown): string {
  if (!block || typeof block !== 'object' || Array.isArray(block)) return '';
  const b = block as Record<string, unknown>;
  if (b.type === 'text' && typeof b.text === 'string') return b.text;
  if (b.type === 'resource' && b.resource && typeof b.resource === 'object' && !Array.isArray(b.resource)) {
    const text = (b.resource as Record<string, unknown>).text;
    if (typeof text === 'string') return text;
  }
  return '';
}

// The content-block array to scan for an mcp__* tool_response: the documented bare-array
// shape, or (fix for a leak the review found) the `{ content: [...] }`-wrapped shape some
// servers/harness versions return instead. Anything else (e.g. a bare string result) has
// no block array to walk and returns [].
function mcpContentBlocks(resp: unknown): unknown[] {
  if (Array.isArray(resp)) return resp;
  if (resp && typeof resp === 'object' && Array.isArray((resp as { content?: unknown }).content)) {
    return (resp as { content: unknown[] }).content;
  }
  return [];
}

// The text an injection-marker scan should look at for this tool's response, per the field
// map captured in tests/fixtures/posttooluse/README.md. Only ever called for WebFetch,
// WebSearch and mcp__* (see isInjectionTool); returns '' for anything else or a response
// that doesn't match the tool's documented shape (nothing to scan, not an error).
function injectionScanText(tool: string, resp: unknown): string {
  if (tool === 'WebFetch') {
    const r = resp as { result?: unknown } | null;
    return typeof r?.result === 'string' ? r.result : '';
  }
  if (tool === 'WebSearch') {
    const r = resp as { results?: unknown[] } | null;
    const results = Array.isArray(r?.results) ? (r as { results: unknown[] }).results : [];
    // Every entry, not just results[0]/results[1]: a hit-list entry's every title AND
    // url, plus every plain-string entry (the synopsis, or any further synopsis-like
    // entry a future response shape adds).
    const parts: string[] = [];
    for (const entry of results) {
      if (typeof entry === 'string') { parts.push(entry); continue; }
      const hits = (entry as { content?: unknown[] } | null)?.content;
      if (!Array.isArray(hits)) continue;
      for (const hit of hits) {
        if (!hit || typeof hit !== 'object') continue;
        const title = (hit as { title?: unknown }).title;
        const url = (hit as { url?: unknown }).url;
        if (typeof title === 'string') parts.push(title);
        if (typeof url === 'string') parts.push(url);
      }
    }
    return parts.join(' ');
  }
  if (tool.startsWith('mcp__')) {
    if (typeof resp === 'string') return resp; // a bare-string mcp result — scan it directly
    return mcpContentBlocks(resp).map(mcpBlockText).filter(Boolean).join(' ');
  }
  return '';
}

// Redacts an mcp__* tool_response block by block: a `{ type: "text", text }` block's text,
// or a `{ type: "resource", resource: { text } }` block's embedded text payload (see
// mcpBlockText above) — never an `image` block's data, never a resource's `blob` (base64
// binary), and never anything outside a block's own text field. This block-aware walk
// applies to BOTH shapes mcpContentBlocks recognises: the documented bare array, and a
// `{ content: [...] }`-wrapped response (rewritten back into the same wrapper, only its
// `content` field replaced). Anything else — a bare string, or any shape with no content
// array at all — has no blocks to walk block-aware, so it falls back to guard-core's
// generic redactValue over the WHOLE response instead: still shape-preserving, but
// (unlike the block walk above) unable to know to skip an image/blob field nested inside
// it; that tradeoff only applies to a response shape this addition doesn't recognise.
//
// One oversized block does NOT disable redaction for the rest of the response: each block
// is scanned independently, so a block that aborts (truncatedScan) is left exactly as it
// was — raw, unmodified — while every OTHER, normally-sized block in the same array is
// still redacted and counted. The caller emits both the "redacted N" notice (if count > 0)
// and the "too large to scan" notice (if truncatedScan) — they are not mutually exclusive.
function redactMcpResponse(resp: unknown, core: Core): RedactValueResult {
  const blocks = mcpContentBlocks(resp);
  // Neither the bare array shape nor the { content: [...] } wrapped shape — including a
  // bare-string result. Nothing to walk block-by-block; scan the whole value generically.
  if (!Array.isArray(resp) && blocks.length === 0) return core.redactValue(resp);
  let count = 0;
  const labels = new Set<string>();
  let truncatedScan = false;
  let changed = false;
  const out = blocks.map((block) => {
    if (!block || typeof block !== 'object' || Array.isArray(block)) return block;
    const b = block as Record<string, unknown>;
    if (b.type === 'text' && typeof b.text === 'string') {
      const r = core.redactValue(b.text);
      if (r.truncatedScan) truncatedScan = true;
      if (r.count > 0) {
        changed = true;
        count += r.count;
        for (const l of r.labels) labels.add(l);
        return { ...b, text: r.value };
      }
      return block;
    }
    if (b.type === 'resource' && b.resource && typeof b.resource === 'object' && !Array.isArray(b.resource)) {
      const res = b.resource as Record<string, unknown>;
      if (typeof res.text === 'string') {
        const r = core.redactValue(res.text);
        if (r.truncatedScan) truncatedScan = true;
        if (r.count > 0) {
          changed = true;
          count += r.count;
          for (const l of r.labels) labels.add(l);
          return { ...b, resource: { ...res, text: r.value } };
        }
      }
      return block; // a resource with only `blob`, or no text field — nothing to scan
    }
    return block; // image, or any other block type — never scanned
  });
  const rebuilt = changed ? out : blocks;
  // Preserve the original top-level shape: the bare-array response rewrites to a new
  // array; the { content: [...] } wrapper rewrites only its content field.
  const value = Array.isArray(resp) ? rebuilt : { ...(resp as Record<string, unknown>), content: rebuilt };
  return { value: changed ? value : resp, count, labels: [...labels], truncatedScan };
}

// Picks how to redact one tool's response. Read gets a narrower rule than the generic
// object walk: a Read result's `type` is "text" for a text file but something else (e.g.
// "image", carrying base64 image data at `file.base64`) for a binary read, and running the
// generic string-leaf walk over that base64 data would corrupt it by splicing
// `[REDACTED:...]` markers into the middle of an image. Only a text-shaped Read result is
// scanned; anything else passes through completely untouched.
function redactToolResponse(tool: string, resp: unknown, core: Core): RedactValueResult {
  if (tool.startsWith('mcp__')) return redactMcpResponse(resp, core);
  if (tool === 'Read' && resp && typeof resp === 'object' && !Array.isArray(resp)
    && (resp as { type?: unknown }).type !== 'text') {
    return { value: resp, count: 0, labels: [], truncatedScan: false };
  }
  return core.redactValue(resp);
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

// True when THIS FILE is running from a Claude Code plugin install path
// (…/plugins/cache/<marketplace>/<name>/<version>/hooks/…). Independent of profileRoots():
// CLAUDE_CONFIG_DIR is checked FIRST there, so a plugin copy invoked inside a profile that
// ALSO has the full kit installed (a real .aka-claude-tools-meta) would otherwise resolve to
// that real profile and double-log every decision alongside that profile's own hooks. Audit
// logging is disabled outright for a plugin install, never left to depend on whether the
// active profile happens to carry a meta file.
function isPluginInstall(): boolean {
  return dirname(fileURLToPath(import.meta.url)).includes('/plugins/');
}

async function main(): Promise<void> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync('/dev/stdin', 'utf-8'));
  } catch {
    console.error(STDIN_FAIL_MSG);
    return;
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    console.error(STDIN_FAIL_MSG);
    return;
  }
  const input = parsed as HookInput;
  const tool = typeof input.tool_name === 'string' ? input.tool_name : '';
  // Not this hook's surface (a matcher misconfiguration, or a tool with no interesting
  // output field) — silent, exactly like every other silent path here. This is a
  // configuration mismatch, not one of the three failures the file doc's contract covers.
  if (!isRedactTool(tool) && !isInjectionTool(tool)) return;

  let core: Core;
  try {
    core = await import('./lib/guard-core.js');
    for (const fn of ['coexistencePolicy', 'detectAitc', 'redactValue', 'injectionMarkers'] as const) {
      if (typeof core[fn] !== 'function') throw new Error(`guard-core export ${fn} missing`);
    }
  } catch {
    console.error(CORE_FAIL_MSG);
    return;
  }

  // ai-tc detection throwing means "treat as absent" here: unlike the blocking guards, this
  // hook can only rewrite output or warn, never deny, so the safe fallback is to keep doing
  // its own full pass rather than assume ai-tc has it covered.
  let doRedact = true;
  let auditLog = true;
  try {
    const policy = core.coexistencePolicy(
      core.detectAitc('claude', { home: homedir(), roots: profileRoots(), ...projectOpt(input) }),
    );
    doRedact = policy.redactOutput(tool);
    auditLog = policy.auditLog !== false;
  } catch { doRedact = true; auditLog = true; }

  const profileRoot = profileRoots()[0] ?? null;
  const auditEnabled = auditLog && !isPluginInstall();
  // Loaded lazily and best-effort: a broken audit.ts must never affect this hook's own
  // always-silent-on-failure, never-blocks contract.
  let appendAudit: ((event: Parameters<typeof import('./lib/audit.ts').appendAudit>[0], opts: Parameters<typeof import('./lib/audit.ts').appendAudit>[1]) => void) | null = null;
  try {
    ({ appendAudit } = await import('./lib/audit.ts'));
  } catch { appendAudit = null; }

  if (doRedact && isRedactTool(tool)) {
    try {
      const isMcp = tool.startsWith('mcp__');
      const r = redactToolResponse(tool, input.tool_response, core);
      // Not mutually exclusive: an mcp response can have SOME blocks redacted (count > 0)
      // and ALSO one oversized block that aborted (truncatedScan) — both notices fire, and
      // the rewrite still ships whatever WAS successfully redacted. For every other tool,
      // redactValue's own truncatedScan is a full-abort (count is always 0 there), so this
      // is unchanged behavior for them: only the truncated notice fires, never a rewrite.
      if (r.count > 0) {
        const out = isMcp
          ? { hookSpecificOutput: { hookEventName: 'PostToolUse', updatedMCPToolOutput: r.value } }
          : { hookSpecificOutput: { hookEventName: 'PostToolUse', updatedToolOutput: r.value } };
        console.log(JSON.stringify(out));
        console.error(P + `redacted ${r.count} secret value(s) from ${tool} output.`);
        if (appendAudit) {
          try {
            appendAudit(
              { hook: 'post-guard', tool, kind: 'redact', detail: `labels: ${r.labels.join(', ')}` },
              { profileRoot, enabled: auditEnabled, patterns: core.DEFAULT_PATTERNS },
            );
          } catch { /* audit logging must never affect the decision */ }
        }
      }
      if (r.truncatedScan) {
        console.error(P + 'output too large to scan; passed through unredacted.');
      }
    } catch { /* a redaction failure must never surface anything beyond silence */ }
  }

  if (isInjectionTool(tool)) {
    try {
      const text = injectionScanText(tool, input.tool_response);
      if (text) {
        const notices = core.injectionMarkers(text);
        for (const n of notices) {
          if (!n || typeof n.message !== 'string') continue;
          console.error(P + n.message);
          if (appendAudit) {
            try {
              appendAudit(
                { hook: 'post-guard', tool, kind: 'alert', rule: n.code, detail: n.message },
                { profileRoot, enabled: auditEnabled, patterns: core.DEFAULT_PATTERNS },
              );
            } catch { /* audit logging must never affect the decision */ }
          }
        }
      }
    } catch { /* an injection-scan failure must never surface anything beyond silence */ }
  }
}

// Never blocks: every path — success, any recognised failure, or a throw that escaped
// main() entirely — ends the same way, exit 0, stdout empty. A throw reaching here means
// something outside every guard inside main() broke (every real decision point there is
// already wrapped in its own try/catch), so this is defense-in-depth, not an expected path
// — still exactly one stderr line, per the file doc's fail-state contract. Only runs when
// executed directly, so importing for a test never reads stdin or exits.
if (import.meta.main) {
  try {
    await main();
  } catch {
    console.error(UNEXPECTED_FAIL_MSG);
  }
  process.exit(0);
}
