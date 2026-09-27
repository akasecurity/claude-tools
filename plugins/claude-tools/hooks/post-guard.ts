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
 * Non-text MCP content blocks (`image`, `resource`, …) are never scanned or rewritten by
 * either pass — only `{ type: "text", text }` blocks are touched; everything else in an MCP
 * response array passes through byte-for-byte.
 *
 * A PostToolUse hook can't block a call that already ran, so this hook never exits non-zero
 * on a decision: it either rewrites the response (redaction), prints a stderr notice
 * (redaction summary, truncated-scan, or an injection marker), or emits nothing at all on a
 * clean, unremarkable result. Any internal failure (unparseable stdin, a body that isn't a
 * JSON object, guard-core missing or incompatible, or any unexpected error) degrades to
 * complete silence — exit 0, nothing on stdout, nothing on stderr — so the original tool
 * output always reaches the model unchanged.
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
    const hits = results[0] as { content?: { url?: unknown }[] } | undefined;
    const urls = Array.isArray(hits?.content)
      ? hits!.content.map((c) => (typeof c?.url === 'string' ? c.url : '')).join(' ')
      : '';
    const synopsis = typeof results[1] === 'string' ? results[1] : '';
    return [urls, synopsis].filter(Boolean).join(' ');
  }
  if (tool.startsWith('mcp__')) {
    const arr = Array.isArray(resp) ? resp : [];
    return arr
      .filter((b): b is { type: string; text: string } =>
        !!b && typeof b === 'object' && !Array.isArray(b) && (b as { type?: unknown }).type === 'text'
        && typeof (b as { text?: unknown }).text === 'string')
      .map((b) => b.text)
      .join(' ');
  }
  return '';
}

// Redacts an mcp__* tool_response ARRAY (the raw MCP tools/call content shape) block by
// block. Only `{ type: "text", text }` blocks are scanned/rewritten; every other block
// (image, resource, …) is passed through untouched, unread — this addition never scans
// non-text MCP content. A response that isn't an array (malformed / unexpected shape)
// passes through with no redaction, rather than guessing at its structure.
function redactMcpResponse(resp: unknown, core: Core): RedactValueResult {
  if (!Array.isArray(resp)) return { value: resp, count: 0, labels: [], truncatedScan: false };
  let count = 0;
  const labels = new Set<string>();
  let truncatedScan = false;
  let changed = false;
  const out = resp.map((block) => {
    if (block && typeof block === 'object' && !Array.isArray(block)
      && (block as { type?: unknown }).type === 'text' && typeof (block as { text?: unknown }).text === 'string') {
      const r = core.redactValue((block as { text: string }).text);
      if (r.truncatedScan) truncatedScan = true;
      if (r.count > 0) {
        changed = true;
        count += r.count;
        for (const l of r.labels) labels.add(l);
        return { ...(block as Record<string, unknown>), text: r.value };
      }
    }
    return block;
  });
  return { value: changed ? out : resp, count, labels: [...labels], truncatedScan };
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
    return; // unparseable stdin: silent, original output passes through
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return;
  const input = parsed as HookInput;
  const tool = typeof input.tool_name === 'string' ? input.tool_name : '';
  // Not this hook's surface (a matcher misconfiguration, or a tool with no interesting
  // output field) — silent, exactly like every other silent path here.
  if (!isRedactTool(tool) && !isInjectionTool(tool)) return;

  let core: Core;
  try {
    core = await import('./lib/guard-core.js');
    for (const fn of ['coexistencePolicy', 'detectAitc', 'redactValue', 'injectionMarkers'] as const) {
      if (typeof core[fn] !== 'function') throw new Error(`guard-core export ${fn} missing`);
    }
  } catch {
    return; // core missing/unreadable/incompatible: silent, never rewrite, never warn
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
      const r = isMcp ? redactMcpResponse(input.tool_response, core) : core.redactValue(input.tool_response);
      if (r.truncatedScan) {
        console.error(P + 'output too large to scan; passed through unredacted.');
      } else if (r.count > 0) {
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

// Never blocks, never prints on an unexpected failure: every path — success, any
// recognised failure, or a throw that escaped main() — ends the same way, exit 0. Only
// runs when executed directly, so importing for a test never reads stdin or exits.
if (import.meta.main) {
  try {
    await main();
  } catch { /* silent, by design — see the file doc's fail-state contract */ }
  process.exit(0);
}
