// audit.ts — local security-event audit log, shared by command-guard, leak-guard,
// mcp-guard and prompt-guard. A small, dependency-light module: it is placed into
// every installed profile's hooks/lib alongside guard-core.js (install.sh's
// place_dir wholesale-copies config/hooks/lib), and it ships in the plugin build
// too. A plugin-install caller disables audit logging OUTRIGHT (its own `enabled`
// computation ANDs in "am I running from a /plugins/ path?") rather than relying
// on profile-root resolution alone: CLAUDE_CONFIG_DIR is checked BEFORE the
// hooksDir-based "own profile" fallback, so a plugin copy running inside a profile
// that ALSO has the full kit installed (a real `.aka-claude-tools-meta`) would
// otherwise double-log every decision alongside that profile's own hooks.
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
//     is false whenever ai-tc is present — ai-tc keeps its own audit trail — ANDed
//     with "not a plugin install", see above), AND
//   - `opts.profileRoot` is non-null AND `<profileRoot>/.aka-claude-tools-meta`
//     exists — i.e. this is a kit-managed profile, not an ad hoc directory a hook
//     happens to be running from (the repo's own config/hooks, a bare checkout, …).
//
// Every line is produced by guard-core's `formatAuditLine`, which redacts and caps
// every free-text field and never throws. `opts.patterns` is passed as
// `?? undefined`, NEVER as a bare `null`: a caller's `parsePatterns(...)` returns
// `null` when secret-patterns.json is missing or corrupt, and `formatAuditLine`
// treats an explicit `null` as "don't scan" (by design, for a caller that means it
// deliberately) — passing that straight through here would silently write RAW,
// unredacted secrets whenever the patterns file happened to be unavailable, exactly
// when the guard's own scan tier degrades to failing closed on the raw command/
// query/input (see e.g. evaluateBash's `patterns-unavailable` rule, whose snippet
// IS the raw command). `undefined` instead asks formatAuditLine for its own bundled
// `DEFAULT_PATTERNS`, so the audit line still gets a real redaction pass regardless
// of whether the installed patterns file is present. The `rule === 'secret-detected'`
// tier goes one step further and drops the snippet FIELD entirely, independent of
// patterns: that block comes from the trufflehog scanner, which can flag secret
// shapes the bundled regex patterns don't recognise, so no regex-based redaction
// pass can be trusted to have caught it.
//
// This function adds one more layer on top of formatAuditLine: directory/file
// creation, permissions, and the symlink/race defenses below are ALL best-effort
// and swallow every error — a broken or hostile logs/ directory must never be the
// reason a guard hook fails or changes its decision.
import {
  chmodSync, closeSync, constants, existsSync, fchmodSync, fstatSync, lstatSync,
  mkdirSync, openSync, realpathSync, writeSync,
} from 'fs';
import { join } from 'path';
import { formatAuditLine } from './guard-core.js';
import type { AuditEvent, PatternSet } from './guard-core.js';

const KIT = 'aka-claude-tools';
const HARNESS = 'claude';

export interface AppendAuditOptions {
  /** The active profile root (profileRoots()[0]), or null when there is none. */
  profileRoot: string | null;
  /**
   * coexistencePolicy(...).auditLog, ANDed by the caller with "not a plugin
   * install" — false whenever ai-tc is present, or the calling hook is running
   * from a /plugins/ install path.
   */
  enabled: boolean;
  /**
   * The caller's parsed secret-patterns.json, or `null` when it's missing/corrupt.
   * appendAudit itself converts a `null` here to `undefined` before handing it to
   * formatAuditLine, so redaction always falls back to guard-core's bundled
   * DEFAULT_PATTERNS rather than being skipped — see the module doc above.
   */
  patterns: PatternSet | null;
}

// True when `p` exists and is a symlink — checked with lstat (not stat) so the
// check inspects the link itself rather than whatever it resolves to. A path that
// doesn't exist yet is not a symlink (return false, not an error): the directory
// is about to be created fresh.
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
    // The trufflehog tier can flag a secret shape none of the bundled regex
    // patterns recognise, so no regex-based redaction pass can be trusted here —
    // drop the snippet outright rather than rely on formatAuditLine to catch it.
    if (full.rule === 'secret-detected') delete full.snippet;
    // `?? undefined`, never a bare `null` — see the module doc's patterns note.
    const line = formatAuditLine(full, opts.patterns ?? undefined);

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

    // Defense-in-depth against a symlinked ANCESTOR (profileRoot itself, or
    // something between it and logsDir): resolve both ends and require the
    // directory we're about to write into to be EXACTLY <real profileRoot>/logs.
    // A plain lstat on logsDir alone (above) can't see a swap further up the tree.
    let resolvedProfileRoot: string, resolvedLogsDir: string;
    try {
      resolvedProfileRoot = realpathSync(opts.profileRoot);
      resolvedLogsDir = realpathSync(logsDir);
    } catch { return; }
    if (resolvedLogsDir !== join(resolvedProfileRoot, 'logs')) return;

    // Open with O_NOFOLLOW so a symlink swapped in for `file` between any earlier
    // check and this open fails the open() call itself (ELOOP) — atomic, unlike a
    // separate lstat-then-write pair, which leaves a TOCTOU race window. Verify
    // the opened fd is a regular file we actually own before writing to it (belt
    // and suspenders against e.g. a pre-existing hardlink to another user's file).
    let fd: number;
    try {
      fd = openSync(file, constants.O_WRONLY | constants.O_APPEND | constants.O_CREAT | constants.O_NOFOLLOW, 0o600);
    } catch {
      return; // ELOOP (symlink), EACCES (read-only dir), or any other open failure
    }
    try {
      const st = fstatSync(fd);
      const uid = typeof process.getuid === 'function' ? process.getuid() : null;
      if (!st.isFile() || (uid !== null && st.uid !== uid)) return;
      if ((st.mode & 0o777) !== 0o600) { try { fchmodSync(fd, 0o600); } catch { /* best effort */ } }
      writeSync(fd, line);
    } finally {
      try { closeSync(fd); } catch { /* best effort */ }
    }
  } catch {
    // Swallow everything: an audit-log failure must never surface to, or change
    // the outcome of, the guard hook that called us.
  }
}
