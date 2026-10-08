#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * command-guard.ts — PreToolUse hook for the Bash tool, and the sole Bash egress guard
 * (leak-guard.ts covers web tools only). This file is a thin adapter: the decision logic
 * lives in the vendored guard-core library (lib/guard-core.js), which evaluates:
 *   - DENY: piping output into a shell (curl … | bash) — structural.
 *   - DENY: writing to a shell startup file (~/.zshrc, ~/.bashrc, …) — structural.
 *   - DENY: ripgrep --pre / --hostname-bin / RIPGREP_CONFIG_PATH — structural.
 *   - On an outbound command (curl/wget/nc/ncat/socat/fetch): a detected secret
 *     (local trufflehog, --no-verification), an opt-in org marker, or a shared
 *     credential key shape (lib/secret-patterns.json).
 *   - ALERT (allow + notice): other egress vectors.
 * The adapter owns I/O: it reads the hook JSON, loads lib/secret-patterns.json and the
 * install-compiled org sidecar (lib/org-egress.json), asks guard-core whether ai-tc
 * covers Bash in this profile (if so the secret tiers are skipped; structural blocks
 * always run), and maps the core's rule and notice codes to this kit's messages. It also
 * owns lib/trusted-bootstrap.json (the trusted-bootstrap sidecar, unlike org-egress and
 * secret-patterns which are shared with leak-guard/mcp-guard): a narrow, install-compiled
 * allowlist of `curl <allowed flags> <https url under a rule> | bash|sh` forms that
 * guard-core exempts from the pipe-to-shell block. Read only when the command contains a
 * `|`, so the common no-pipe Bash call never pays for the file read.
 *
 * Protocol: deny → exit 2 (Claude Code blocks); alert/allow → exit 0.
 *
 * FAIL STATES:
 *   - guard-core missing, unloadable, incompatible (missing exports) or throwing →
 *     conservative raw-regex structural blocks still apply, outbound-looking commands
 *     are blocked, and the rest is allowed with a loud notice.
 *   - A decision whose kind is not allow/block, or that has no notices array, is treated
 *     as an incompatible core (the path above).
 *   - A block decision always exits 2, even for a rule this adapter has no message for or
 *     alongside malformed notices.
 *   - Shared patterns file missing/corrupt → the core fails closed on outbound commands.
 *   - Org sidecar missing / unparseable / malformed → org tier inactive, never a crash.
 *   - Trusted-bootstrap sidecar missing → no exemptions, silent. Unreadable, corrupt, or
 *     wrong shape → no exemptions, loud warning. Stale sourceHash → exemptions still apply,
 *     loud warning to re-run the installer. Never a crash.
 *   - Unparseable stdin → fail open, but loudly (stderr).
 *   - Any unexpected error → fail open, loudly.
 * Requires: bun.
 */
import { readFileSync } from 'fs';
import { createHash } from 'crypto';
import { dirname, isAbsolute, join } from 'path';
import { homedir } from 'os';
import { fileURLToPath } from 'url';
import type { BootstrapRule, OrgTier, RuleId } from './lib/guard-core.js';

const P = '[aka-claude-tools SECURITY] ';
// Used only when guard-core itself cannot load, to find the outbound subset to fail closed on.
const FALLBACK_OUTBOUND = /\b(curl|wget|nc|ncat|socat|fetch)\b/i;
// Conservative raw-string structural checks, used only when guard-core cannot load or is
// incompatible. They over-block (any pipe into an interpreter, any write-ish verb on a line
// naming a startup dotfile, any rg exec marker even when quoted) so a missing core degrades
// to "too strict", never to an allow. The \s+ after each \S+ keeps the env-wrapper skip linear.
const PIPE_TO_SHELL_RAW = /\|&?\s*(?:(?:\S*\/)?env\s+(?:\S+\s+)*)?(?:\S*\/)?(?:sh|bash|zsh)\b/i;
const STARTUP_WRITE_RAW = /(?:>|\btee\b|\bsed\b|\bcp\b|\bmv\b|\binstall\b|\bln\b|\bdd\b)[^\n]*\.(?:zshrc|zshenv|zprofile|bashrc|bash_profile|profile)\b/;
const SEARCH_EXEC_RAW = /(?:^|[\s'"])--(?:pre|hostname-bin)(?![\w-])|RIPGREP_CONFIG_PATH=/;
// ── Heredoc bodies ─────────────────────────────────────────────────────────────────────
// A heredoc body fed to a data consumer (cat, tee, oharness send --stdin, python3 -, git commit -F -)
// is text, not shell: a handoff note that mentions `curl … | bash` or `.zshenv` is not that
// command. guard-core's structural rules read raw text, so they see the body as commands. A body
// fed to a shell (sh/bash/zsh/…, ssh, eval, source) IS code and stays visible to every rule.
const HEREDOC_SHELLS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh', 'ash', 'fish', 'ssh', 'eval', 'source', '.', 'exec']);
const HEREDOC_WRAPPERS = new Set(['sudo', 'env', 'command', 'nohup', 'time', 'rtk', 'xargs', 'doas']);

function heredocConsumer(before: string): string {
  const seg = before.split(/&&|\|\||[;|&(]/).pop() ?? '';
  for (const w of seg.trim().split(/\s+/)) {
    if (!w || /^[A-Za-z_][A-Za-z0-9_]*=/.test(w) || w.startsWith('-')) continue;
    const base = w.replace(/^['"]|['"]$/g, '').split('/').pop() as string;
    if (HEREDOC_WRAPPERS.has(base)) continue;
    return base;
  }
  return '';
}

// `code` is the command with data bodies removed; `flat` keeps them, appended to the line that
// opened them with shell metacharacters blanked: secret scanning still sees every byte, the
// structural rules see only inert words.
function splitDataHeredocs(cmd: string): { code: string; flat: string; hasData: boolean } {
  const code: string[] = [];
  const flat: string[] = [];
  let hasData = false;
  const pending: { tag: string; dash: boolean; data: boolean }[] = [];
  for (const line of cmd.split('\n')) {
    if (pending.length) {
      const { tag, dash, data } = pending[0];
      const end = (dash ? line.replace(/^\t+/, '') : line) === tag;
      if (end) pending.shift();
      if (!data) { code.push(line); flat.push(line); }
      else if (!end) flat[flat.length - 1] += ' ' + line.replace(/[|<>&;()`'"\\$#]/g, ' ');
      continue;
    }
    code.push(line); flat.push(line);
    for (const m of line.matchAll(/(?<!<)<<(-?)[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/g)) {
      const data = !HEREDOC_SHELLS.has(heredocConsumer(line.slice(0, m.index)));
      if (data) hasData = true;
      pending.push({ tag: m[3], dash: m[1] === '-', data });
    }
  }
  return { code: code.join('\n'), flat: flat.join('\n'), hasData };
}

const CORE_MISSING_NOTICE = '⚠️ command-guard: the guard-core library is missing, unreadable or incompatible — only conservative fallback checks ran. Reinstall to restore config/hooks/lib/guard-core.js.';
const BOOTSTRAP_UNREADABLE_NOTICE = '⚠️ command-guard: trusted-bootstrap.json is unreadable — no bootstrap exemptions apply.';
const BOOTSTRAP_STALE_NOTICE = '⚠️ command-guard: aka-claude-tools.config changed since install — re-run the installer to recompile the trusted bootstrap list.';

interface HookInput { tool_name?: string; tool_input?: Record<string, unknown> | string; cwd?: unknown }

// ── BSD pkill/pgrep misordering ────────────────────────────────────────────────────────
// BSD/macOS pkill and pgrep stop option parsing at the first pattern, so in
// `pkill -f foo -u 501 --` the `-u`, `501` and `--` become extra OR'd patterns, and almost
// every process command line contains `--`. GNU pkill permutes options, so this runs on
// macOS only. A small quote-aware segmenter: simple commands split on ; && || | & newline ( );
// quoted strings, $(...) and backticks are one word; redirections and their targets are dropped.
const PKILL_WRAPPERS: Record<string, string> = { sudo: 'ughpCDRTU', env: 'uSC', command: '', exec: '', nohup: '', time: '', rtk: '' };
const PKILL_VALUE_OPTS = 'dFGgPstUu';
const PKILL_REDIR = /^(?:\d*|&)(?:>>|>&|<&|>|<)/;

function shellSegments(cmd: string): string[][] {
  const segs: string[][] = [];
  let words: string[] = [];
  let cur = '';
  let has = false;
  const endWord = () => { if (has) words.push(cur); cur = ''; has = false; };
  const endSeg = () => { endWord(); if (words.length) segs.push(words); words = []; };
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (c === '\\') { cur += cmd[i + 1] ?? ''; has = true; i++; continue; }
    if (c === "'") {
      const j = cmd.indexOf("'", i + 1);
      const end = j < 0 ? cmd.length : j;
      cur += cmd.slice(i + 1, end); has = true; i = end; continue;
    }
    if (c === '"' || c === '`' || (c === '$' && cmd[i + 1] === '(')) {
      // Scan to the matching close; $(...) and backticks nest, and inside "..." a \ escapes.
      let depth = 0; let k = i;
      const open = c;
      for (; k < cmd.length; k++) {
        const d = cmd[k];
        if (d === '\\') { k++; continue; }
        if (open === '"') {
          if (k > i && d === '"' && depth === 0) break;
          if (d === '$' && cmd[k + 1] === '(') depth++;
          else if (d === ')' && depth > 0) depth--;
        } else if (open === '`') {
          if (k > i && d === '`') break;
        } else {
          if (d === '(') depth++;
          else if (d === ')' && --depth === 0) break;
        }
      }
      cur += cmd.slice(i, k + 1); has = true; i = k; continue;
    }
    if (c === '&' && (cmd[i + 1] === '>' || (cur !== '' && /[<>]$/.test(cur)))) { cur += c; has = true; continue; }
    if (';&|()\n'.includes(c)) { endSeg(); continue; }
    if (c === ' ' || c === '\t') { endWord(); continue; }
    cur += c; has = true;
  }
  endSeg();
  return segs;
}

// Drops heredoc bodies: their lines are data (a handoff note that mentions pgrep), not commands.
function stripHeredocs(cmd: string): string {
  const out: string[] = [];
  let pending: { tag: string; dash: boolean }[] = [];
  for (const line of cmd.split('\n')) {
    if (pending.length) {
      const { tag, dash } = pending[0];
      if ((dash ? line.replace(/^\t+/, '') : line) === tag) pending.shift();
      continue;
    }
    out.push(line);
    for (const m of line.matchAll(/(?<!<)<<(-?)[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/g)) pending.push({ tag: m[3], dash: m[1] === '-' });
  }
  return out.join('\n');
}

// Returns a block reason when `cmd` runs pkill/pgrep with a word after its first pattern.
function misorderedPkill(cmd: string, platform: string = process.platform): string | null {
  if (platform !== 'darwin' || !/pkill|pgrep/.test(cmd)) return null;
  cmd = stripHeredocs(cmd);
  for (const raw of shellSegments(cmd)) {
    const w: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      const m = PKILL_REDIR.exec(raw[i]);
      if (m) { if (m[0].length === raw[i].length) i++; continue; }
      w.push(raw[i]);
    }
    let i = 0;
    for (;;) {
      if (i < w.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(w[i])) { i++; continue; }
      const base = (w[i] ?? '').split('/').pop() as string;
      if (!Object.prototype.hasOwnProperty.call(PKILL_WRAPPERS, base)) break;
      const wrap = PKILL_WRAPPERS[base];
      i++;
      while (i < w.length && w[i].startsWith('-') && w[i] !== '--') {
        i += w[i].length === 2 && wrap.includes(w[i][1]) ? 2 : 1;
      }
    }
    const name = (w[i] ?? '').split('/').pop();
    if (name !== 'pkill' && name !== 'pgrep') continue;
    i++;
    for (; i < w.length; i++) {
      const t = w[i];
      if (t === '--') { i++; break; }
      if (!t.startsWith('-') || t === '-') break;
      if (/^-(?:\d+|[A-Z]{2,}[A-Z0-9]*)$/.test(t)) continue; // signal: -9, -TERM, -HUP
      if (PKILL_VALUE_OPTS.includes(t[t.length - 1])) i++;
    }
    if (i < w.length && w.length > i + 1) return name as string;
  }
  return null;
}

// Messages are the kit's public contract; tests/golden pins them. Keys are guard-core RuleIds.
const BLOCK_MSG: Record<RuleId, (detail?: string) => string> = {
  'pipe-to-shell': () => '🚨 BLOCKED (command-guard): piping output into a shell interpreter (curl … | bash). Download, inspect, then run.',
  'startup-write': () => '🚨 BLOCKED (command-guard): writing to a shell startup file (~/.zshrc, ~/.bashrc, …) is a persistence vector. Your dotfiles are Edit/Write-denied; a Bash redirection bypasses that. If intentional, run it in your own shell (e.g. a `! <cmd>` prompt); for a profile alias use `./install.sh --alias`.',
  'search-exec': () => '🚨 BLOCKED (command-guard): ripgrep\'s --pre / --hostname-bin run an arbitrary binary, and RIPGREP_CONFIG_PATH injects flags from a file. `rtk rg` is auto-approved for token savings, so these are blocked here. Search without them, or run it in your own shell (e.g. a `! <cmd>` prompt).',
  'patterns-unavailable': () => '🚨 BLOCKED (command-guard): secret-patterns.json is missing or corrupt, so the egress scan can\'t run — blocking this outbound command as a precaution. Restore config/hooks/lib/secret-patterns.json or reinstall.',
  'secret-detected': () => '🚨 BLOCKED (command-guard): outbound command contains a detected secret (trufflehog). Reference it via an environment variable instead of pasting the literal value.',
  'org-marker': () => '🚨 BLOCKED (command-guard): outbound command matches an internal identifier from aka-claude-tools.config (hostname, IP, path, or username). Describe it generically instead.',
  'credential-shape': (label) => `🚨 BLOCKED (command-guard): credential exfiltration — ${label} sent via an outbound tool.`,
  // Not reachable via evaluateBash (MCP-only rules from guard-core 0.3.0's
  // evaluateMcpInput); kept here so the map stays total. mcp-guard owns
  // these surfaces.
  'mcp-server-denied': () => '🚨 BLOCKED (command-guard): command was rejected by an MCP server policy (mcp-server-denied).',
  'mcp-server-not-allowed': () => '🚨 BLOCKED (command-guard): command was rejected by an MCP server policy (mcp-server-not-allowed).',
  'mcp-input-unscannable': () => '🚨 BLOCKED (command-guard): command was rejected as an unscannable MCP input (mcp-input-unscannable).',
};
const NOTICE_MSG: Record<string, (m: string) => string | null> = {
  'scanner-unavailable': () => '⚠️ command-guard: trufflehog not installed — secret detection degraded to regex tiers (org markers + shared key shapes).',
  'parse-degraded': () => '⚠️ command-guard: command too complex to parse precisely — falling back to strict structural checks (may over-block).',
  'org-stale': () => '⚠️ command-guard: aka-claude-tools.config changed since install — any CT_EGRESS_PATTERNS edit is NOT active yet. Re-run ./install.sh to recompile the org-marker tier.',
  'org-pattern-invalid': () => null, // an invalid org pattern was always silent here
  'egress-alert': (m) => `⚠️ egress alert (command-guard): ${m}`,
};

// `undefined` = empty stdin (allow silently); a parsed JSON `null` is passed through.
function readInput(): HookInput | null | undefined {
  const raw = readFileSync('/dev/stdin', 'utf-8');
  if (!raw.trim()) return undefined;
  return JSON.parse(raw);
}

function loadPatternsRaw(): unknown {
  try { return JSON.parse(readFileSync(new URL('./lib/secret-patterns.json', import.meta.url), 'utf-8')); }
  catch { return null; }
}

// Org-marker tier (opt-in). Reads the install-compiled sidecar — never sources the
// user's shell config. Fail-soft on every error (missing / unparseable / malformed /
// bad-regex sidecar → org tier inactive), never throws. `stale` is computed
// independently of whether a pattern is set, so a user who adds CT_EGRESS_PATTERNS
// after install (sidecar pattern still empty) still gets the "re-run install" nudge.
function loadOrgTier(): OrgTier {
  try {
    const sc = JSON.parse(readFileSync(new URL('./lib/org-egress.json', import.meta.url), 'utf-8')) as
      { pattern?: string; sourceHash?: string };
    let stale = false;
    if (sc.sourceHash) {
      try {
        // Hash the raw config file bytes — the same byte domain install.sh hashes
        // (not the shell-expanded value), so quoting-identical edits don't false-drift.
        const cfg = readFileSync(new URL('../aka-claude-tools.config', import.meta.url));
        stale = createHash('sha256').update(cfg).digest('hex') !== sc.sourceHash;
      } catch { /* config gone/unreadable → can't compare; treat as not-stale */ }
    }
    let pattern: RegExp | null = null;
    let patternError = false;
    if (sc.pattern) { try { pattern = new RegExp(sc.pattern); } catch { pattern = null; patternError = true; } }
    return { pattern, stale, patternError };
  } catch {
    return { pattern: null, stale: false, patternError: false };
  }
}

// Trusted-bootstrap sidecar (opt-in, command-guard's alone — see lib/trusted-bootstrap.json).
// Loaded ONLY when the caller has already seen a `|` in the command (see main()), so a file
// read never happens on the common no-pipe Bash call. States:
//   - missing (ENOENT)                => { rules: [] }, silent — nothing was ever configured.
//   - unreadable (any other read/parse
//     error) or wrong shape (not an
//     object, or `rules` not an array)  => { rules: [] } plus a loud warning.
//   - stale sourceHash (config edited
//     since install)                   => the parsed rules ARE kept, plus a re-run-installer
//                                          warning — a stale list still narrows exposure; it
//                                          just may not reflect the latest CT_TRUSTED_BOOTSTRAP_URLS.
// Never throws: every failure path returns rules: [] rather than propagating.
function loadTrustedBootstrap(): { rules: BootstrapRule[]; warn?: string } {
  let raw: string;
  try {
    raw = readFileSync(new URL('./lib/trusted-bootstrap.json', import.meta.url), 'utf-8');
  } catch (e) {
    if ((e as NodeJS.ErrnoException)?.code === 'ENOENT') return { rules: [] };
    return { rules: [], warn: BOOTSTRAP_UNREADABLE_NOTICE };
  }
  let sc: unknown;
  try { sc = JSON.parse(raw); } catch { return { rules: [], warn: BOOTSTRAP_UNREADABLE_NOTICE }; }
  if (!sc || typeof sc !== 'object' || !Array.isArray((sc as { rules?: unknown }).rules)) {
    return { rules: [], warn: BOOTSTRAP_UNREADABLE_NOTICE };
  }
  const rules = (sc as { rules: unknown }).rules as BootstrapRule[];
  const sourceHash = (sc as { sourceHash?: unknown }).sourceHash;
  let stale = false;
  if (typeof sourceHash === 'string' && sourceHash) {
    try {
      // Same byte domain install.sh hashes (raw config file bytes), matching loadOrgTier.
      const cfg = readFileSync(new URL('../aka-claude-tools.config', import.meta.url));
      stale = createHash('sha256').update(cfg).digest('hex') !== sourceHash;
    } catch { /* config gone/unreadable → can't compare; treat as not-stale */ }
  }
  return stale ? { rules, warn: BOOTSTRAP_STALE_NOTICE } : { rules };
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
// (…/plugins/cache/<marketplace>/<name>/<version>/hooks/…). Independent of
// profileRoots(): CLAUDE_CONFIG_DIR is checked FIRST there, so a plugin copy
// invoked inside a profile that ALSO has the full kit installed (a real
// .aka-claude-tools-meta) would otherwise resolve to that real profile and
// double-log every decision alongside that profile's own hooks. Audit logging is
// disabled outright for a plugin install, never left to depend on whether the
// active profile happens to carry a meta file.
function isPluginInstall(): boolean {
  return dirname(fileURLToPath(import.meta.url)).includes('/plugins/');
}

// guard-core missing, unreadable, incompatible or throwing: keep the structural blocks via
// the raw regexes, fail closed on outbound-looking commands, allow the rest loudly.
function coreUnavailable(command: string): never {
  const rule: RuleId | null = PIPE_TO_SHELL_RAW.test(command) ? 'pipe-to-shell'
    : STARTUP_WRITE_RAW.test(command) ? 'startup-write'
    : SEARCH_EXEC_RAW.test(command) ? 'search-exec' : null;
  if (rule) {
    console.error(P + CORE_MISSING_NOTICE);
    console.error(P + BLOCK_MSG[rule]());
    process.exit(2);
  }
  if (FALLBACK_OUTBOUND.test(command)) {
    console.error(P + '🚨 BLOCKED (command-guard): the guard-core library is missing, unreadable or incompatible, so the egress scan can\'t run — blocking this outbound command as a precaution. Reinstall to restore config/hooks/lib/guard-core.js.');
    process.exit(2);
  }
  console.error(P + CORE_MISSING_NOTICE);
  process.exit(0);
}

async function main(): Promise<void> {
  let input: HookInput | null | undefined;
  try { input = readInput(); } catch {
    // Fail open, but loudly — this is the sole Bash guard; surface the miss.
    console.error(P + '⚠️ command-guard: could not parse hook input — allowed. If this recurs, the hook may be misconfigured.');
    process.exit(0);
  }
  if (input === undefined) process.exit(0);
  // Deliberately no null-guard on the parsed value: a JSON `null` body throws here and
  // is surfaced by the top-level catch, as before.
  input = input as HookInput;
  if (input.tool_name !== 'Bash') process.exit(0);
  const command = typeof input.tool_input === 'string'
    ? input.tool_input : (input.tool_input?.command as string | undefined) ?? '';
  if (!command) process.exit(0);

  try {
    const bad = misorderedPkill(command);
    if (bad) {
      console.error(P + `🚨 BLOCKED (command-guard): on macOS ${bad} stops parsing options at the first pattern, so any option or word after it (-u, a uid, --) is treated as another pattern and can match almost every process. Put options first and give one pattern (join several with |): \`${bad} -u "$(id -u)" -f '<pattern>'\`. Preview matches with \`pgrep -lf\`.`);
      process.exit(2);
    }
  } catch { /* a parser bug must never block or crash the hook */ }

  type Core = typeof import('./lib/guard-core.js');
  let core: Core;
  try {
    core = await import('./lib/guard-core.js');
    for (const fn of ['evaluateBash', 'detectAitc', 'coexistencePolicy', 'parsePatterns'] as const) {
      if (typeof core[fn] !== 'function') throw new Error(`guard-core export ${fn} missing`);
    }
  } catch {
    coreUnavailable(command);
  }

  // ai-tc detection only ever turns scanning off; if it throws, scan (the safe
  // direction) and default the audit log on too (more visibility, never less).
  let scanSecrets = true;
  let auditLog = true;
  try {
    const policy = core.coexistencePolicy(core.detectAitc('claude', { home: homedir(), roots: profileRoots(), ...projectOpt(input) }));
    scanSecrets = policy.scanSecrets('Bash') !== false;
    auditLog = policy.auditLog !== false;
  } catch { scanSecrets = true; auditLog = true; }

  // Only a pipe-bearing command can possibly match the bootstrap exemption (it's exactly
  // `curl ... | bash|sh`), so the sidecar read is skipped entirely on every other Bash call.
  let trustedBootstrap: BootstrapRule[] = [];
  if (command.includes('|')) {
    const tb = loadTrustedBootstrap();
    trustedBootstrap = tb.rules;
    if (tb.warn) console.error(P + tb.warn);
  }

  // parsePatterns() is called INSIDE this try (not hoisted above it): a throw here must
  // still route to coreUnavailable() below, same as a throw from evaluateBash itself.
  let patterns: ReturnType<Core['parsePatterns']>;
  let d: ReturnType<Core['evaluateBash']>;
  try {
    patterns = core.parsePatterns(loadPatternsRaw());
    const ctx = { patterns, org: loadOrgTier(), scanSecrets, trustedBootstrap };
    const hd = splitDataHeredocs(command);
    if (!hd.hasData) {
      d = core.evaluateBash(command, ctx);
    } else {
      // Structural rules see the command without data bodies; the secret tier sees the bodies
      // too, but only when an outbound tool is in the command itself.
      d = core.evaluateBash(hd.code, { ...ctx, scanSecrets: false });
      if (d && d.kind === 'allow' && scanSecrets && (patterns ? patterns.outbound : FALLBACK_OUTBOUND).test(hd.code)) {
        d = core.evaluateBash(hd.flat, ctx);
      }
    }
    // Only allow/block are valid Bash decisions; anything else (including `rewrite`) is a
    // malformed decision and takes the core-unavailable path.
    if (!d || typeof d !== 'object' || !Array.isArray(d.notices) || (d.kind !== 'allow' && d.kind !== 'block')) {
      throw new Error('malformed guard-core decision');
    }
  } catch {
    coreUnavailable(command);
  }
  // Notices print before the block line, but no notice can abort a block: each is
  // skipped unless it is an object, and a throw while formatting one is swallowed.
  for (const n of d.notices as unknown[]) {
    if (!n || typeof n !== 'object') continue;
    try {
      const { code, message } = n as { code?: unknown; message?: unknown };
      const line = typeof code === 'string' ? NOTICE_MSG[code]?.(typeof message === 'string' ? message : '') : null;
      if (line) console.error(P + line);
    } catch { /* a malformed notice never changes the decision */ }
  }

  // Local security-event audit log (opt-out via ai-tc's presence, see lib/audit.ts).
  // Best effort: loaded lazily so a broken audit.ts can never break the fail-
  // open/fail-closed contract above, and wrapped so it never changes the decision
  // or exit code. Runs AFTER the decision is final, BEFORE process.exit below.
  try {
    const { appendAudit } = await import('./lib/audit.ts');
    const alert = (d.notices as { level?: unknown; code?: unknown; message?: unknown }[])
      .find((n) => n && typeof n === 'object' && n.level === 'alert');
    const profileRoot = profileRoots()[0] ?? null;
    const enabled = auditLog && !isPluginInstall();
    if (d.kind === 'block') {
      appendAudit(
        { hook: 'command-guard', tool: 'Bash', kind: 'block', rule: d.rule, snippet: command },
        { profileRoot, enabled, patterns },
      );
    } else if (alert) {
      appendAudit(
        {
          hook: 'command-guard', tool: 'Bash', kind: 'alert',
          rule: typeof alert.code === 'string' ? alert.code : undefined,
          detail: typeof alert.message === 'string' ? alert.message : undefined,
          snippet: command,
        },
        { profileRoot, enabled, patterns },
      );
    }
  } catch { /* audit logging must never affect the decision */ }

  if (d.kind === 'block') {
    let line = '🚨 BLOCKED (command-guard): unrecognised guard-core rule.';
    try {
      const msg = BLOCK_MSG[d.rule] as ((detail?: string) => string) | undefined;
      line = msg ? msg(d.detail) : `🚨 BLOCKED (command-guard): ${typeof d.reason === 'string' ? d.reason : 'unrecognised guard-core rule.'}`;
    } catch { /* keep the fixed line; the exit below is what blocks */ }
    console.error(P + line);
    process.exit(2);
  }
  process.exit(0);
}

// Top-level guard: deliberate decisions exit inside main() (process.exit 0/2); only an
// unexpected throw reaches here. Degrade loudly and allow (exit 0) rather than into
// bun's undefined non-zero exit.
try { await main(); } catch (e) {
  console.error(P + '⚠️ command-guard: unexpected error — allowed (surfaced, not silent). ' + String(e));
  process.exit(0);
}
