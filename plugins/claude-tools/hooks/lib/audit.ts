// audit.ts — local security-event audit log, shared by command-guard, leak-guard,
// mcp-guard and prompt-guard. A small, dependency-light module: it is placed into
// every installed profile's hooks/lib alongside guard-core.js (install.sh's
// place_dir wholesale-copies config/hooks/lib), and it ships in the plugin build
// too. In the plugin, profile-root resolution never finds a `.aka-claude-tools-meta`
// file, so appendAudit writes nothing there — that's expected, not a bug.
//
// Callers import this module LAZILY (`await import('./lib/audit.ts')`), AFTER their
// own dynamic `import('./lib/guard-core.js')` has already succeeded — never as a
// static top-level import. This module's own top-level `import { formatAuditLine }
// from './guard-core.js'` is itself a static (eager) import, so if a caller loaded
// it eagerly at its own module top, a missing/corrupt guard-core.js would throw
// during that caller's module evaluation — before its own try/catch around "guard-
// core missing" ever runs, breaking the documented fail-open/fail-closed contract.
// Loading this module lazily, at the point of use, keeps that failure containable
// (a throw there is caught by the call site's own try/catch, same as any other
// audit-logging failure).
//
// Writes exactly one line to <profileRoot>/logs/security-<YYYY-MM>.jsonl (UTC
// month), and ONLY when:
//   - `opts.enabled` is true (the caller's `coexistencePolicy(...).auditLog`, which
//     is false whenever ai-tc is present — ai-tc keeps its own audit trail), AND
//   - `opts.profileRoot` is non-null AND `<profileRoot>/.aka-claude-tools-meta`
//     exists — i.e. this is a kit-managed profile, not an ad hoc directory a hook
//     happens to be running from (the repo's own config/hooks, a bare checkout, …).
//
// Every line is produced by guard-core's `formatAuditLine`, which redacts and caps
// every free-text field and never throws. This function adds one more layer on top
// of that: directory/file creation, permissions, and the symlink refusal below are
// ALL best-effort and swallow every error — a broken or hostile logs/ directory
// must never be the reason a guard hook fails or changes its decision.
import { appendFileSync, chmodSync, existsSync, lstatSync, mkdirSync, statSync } from 'fs';
import { join } from 'path';
import { formatAuditLine } from './guard-core.js';
import type { AuditEvent, PatternSet } from './guard-core.js';

const KIT = 'aka-claude-tools';
const HARNESS = 'claude';

export interface AppendAuditOptions {
  /** The active profile root (profileRoots()[0]), or null when there is none. */
  profileRoot: string | null;
  /** coexistencePolicy(...).auditLog — false whenever ai-tc is present. */
  enabled: boolean;
  /** Passed straight through to formatAuditLine for redaction; null skips scanning. */
  patterns: PatternSet | null;
}

// True when `p` exists and is a symlink — checked with lstat (not stat) so the
// check inspects the link itself rather than whatever it resolves to. A path that
// doesn't exist yet is not a symlink (return false, not an error): the directory
// or file is about to be created fresh.
function isSymlink(p: string): boolean {
  try {
    return lstatSync(p).isSymbolicLink();
  } catch {
    return false;
  }
}

/**
 * Appends one redacted, capped audit line. Never throws — every failure (a
 * read-only logs/ dir, a symlinked logs/ dir or file, a missing profile, disabled
 * policy, an unwritable disk, a malformed event) is swallowed silently. The worst
 * outcome of anything going wrong here is a missing log line, never a guard hook
 * that fails, blocks incorrectly, or prints something it didn't already print.
 */
export function appendAudit(
  event: Omit<AuditEvent, 'ts' | 'kit' | 'harness'>,
  opts: AppendAuditOptions,
): void {
  try {
    if (!opts.enabled || !opts.profileRoot) return;
    if (!existsSync(join(opts.profileRoot, '.aka-claude-tools-meta'))) return;

    const full: AuditEvent = { ...event, ts: new Date().toISOString(), kit: KIT, harness: HARNESS };
    const line = formatAuditLine(full, opts.patterns);

    // toISOString() is always UTC ("...Z"); the first 7 chars are the UTC YYYY-MM.
    const month = full.ts.slice(0, 7);
    const logsDir = join(opts.profileRoot, 'logs');
    const file = join(logsDir, `security-${month}.jsonl`);

    // Refuse a symlinked logs/ dir OUTRIGHT — writing through it would follow the
    // link wherever it points (a symlink-redirect attack). Checked BEFORE mkdirSync,
    // which would otherwise silently no-op on an existing path (symlink or not).
    if (isSymlink(logsDir)) return;
    mkdirSync(logsDir, { mode: 0o700, recursive: true });
    // mkdirSync's `mode` only applies to a directory it actually creates; a
    // pre-existing logs/ dir (from a prior month) keeps whatever mode it already
    // had, so chmod it explicitly every time — cheap, and self-healing if it ever
    // drifted (e.g. a restrictive umask, or a manual edit).
    try { chmodSync(logsDir, 0o700); } catch { /* best effort */ }

    // Same symlink refusal for the file itself.
    if (isSymlink(file)) return;
    appendFileSync(file, line, { mode: 0o600 });
    try {
      const st = statSync(file);
      if ((st.mode & 0o777) !== 0o600) chmodSync(file, 0o600);
    } catch { /* best effort */ }
  } catch {
    // Swallow everything: an audit-log failure must never surface to, or change
    // the outcome of, the guard hook that called us.
  }
}
