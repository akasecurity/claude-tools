// Installer helper: re-render already-parsed audit-log events through guard-core's
// formatAuditLine, so `install.sh --audit-log`'s "last 20 events" section is
// redacted, capped and allow-listed the SAME way as when the event was first
// written — never a raw tail of whatever bytes happen to be on disk. That matters
// because the log file itself can drift from what appendAudit originally wrote
// (a hand-edit, a future kit version's format, or an old event written before a
// redaction-tightening upgrade), so re-formatting on READ is a second, independent
// safety net, not just a formatting nicety.
//
// Usage: bun render-audit-line.ts <guard-core.js> [secret-patterns.json]
// Reads one JSON event per line on stdin (the caller has already filtered out
// lines that don't parse as JSON — see install.sh's audit_log_entry), writes one
// formatted line (already newline-terminated by formatAuditLine) per line on
// stdout. A line that still fails to parse here is skipped silently.
//
// Both path args are resolved with `path.resolve` (against process.cwd()) before
// use — a bare dynamic `import(corePath)` resolves a RELATIVE path against THIS
// FILE's own location (shared/lib/), not the caller's cwd or the path's own
// meaning, so a relative guard-core.js path would silently import the wrong file
// (or nothing at all) instead of the caller-intended one. An already-absolute
// path is returned unchanged by `resolve`, so this is a no-op in the common case
// (install.sh always passes absolute paths).
export {};
import { readFileSync } from 'fs';
import { resolve } from 'path';

const [rawCorePath, rawPatternsPath] = process.argv.slice(2);
if (!rawCorePath) {
  console.error('usage: render-audit-line.ts <guard-core.js> [secret-patterns.json]');
  process.exit(1);
}
const corePath = resolve(rawCorePath);
const patternsPath = rawPatternsPath ? resolve(rawPatternsPath) : undefined;

type Core = typeof import('../../config/hooks/lib/guard-core.js');
const core = (await import(corePath)) as Core;

// A missing/unreadable/corrupt patterns file falls back to formatAuditLine's own
// bundled DEFAULT_PATTERNS — pass `undefined`, NEVER `null` (an explicit `null`
// means "skip redaction entirely", the exact bug class this tool exists to guard
// against; see config/hooks/lib/audit.ts's module doc for the full rationale).
let patterns: ReturnType<Core['parsePatterns']> | undefined;
if (patternsPath) {
  try { patterns = core.parsePatterns(JSON.parse(readFileSync(patternsPath, 'utf-8'))) ?? undefined; }
  catch { patterns = undefined; }
}

const input = await Bun.stdin.text();
for (const line of input.split('\n')) {
  if (!line.trim()) continue;
  try {
    process.stdout.write(core.formatAuditLine(JSON.parse(line), patterns));
  } catch {
    // Skip a line that isn't valid JSON (shouldn't happen: the caller pre-filters),
    // or one formatAuditLine itself can't cope with — it never throws by contract,
    // but this stays defensive regardless.
  }
}
