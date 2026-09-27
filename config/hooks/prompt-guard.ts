#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * prompt-guard.ts — OPT-IN UserPromptSubmit hook. bun is a hard dependency of this
 * addition (see install.sh), like the other bun guard hooks.
 *
 * Warns, never blocks: this hook is the inverse of the PreToolUse egress guards. It has
 * no rule to enforce and no call to deny — a human typed this prompt, so there is nothing
 * to fail closed against. It ALWAYS exits 0 and never prints its own error output; the
 * worst outcome of anything going wrong here is a missed warning, never a blocked prompt
 * and never a confusing error line in the transcript.
 *
 * Detection is the vendored guard-core's scanPrompt (lib/guard-core.js): a regex marker
 * scan for prompt-injection phrasing ("ignore previous instructions", …), a credential
 * value paired with a send/post/upload verb (using the shared lib/secret-patterns.json
 * corpus, the same one the egress guards read), and a base64/hex blob that decodes to a
 * shell command. Skipped where ai-tc is present and enabled for this profile: ai-tc
 * covers prompt content detection there, so this hook narrows to the injection-marker
 * check alone (scanPrompt's `injectionOnly`), the one class ai-tc doesn't already cover
 * for this event.
 *
 * Output channel: a UserPromptSubmit hook's plain stdout is fed to Claude, not shown to
 * the user, and its plain stderr on exit 0 is not part of the documented contract either
 * (confirmed against the CLI's own embedded hooks reference: this event's exit-0 row is
 * "stdout shown to Claude", nothing about stderr). The one field the docs guarantee is
 * displayed to the user on ANY hook, any exit code, is top-level JSON `systemMessage` on
 * stdout — verified live in ai-tc's own UserPromptSubmit script, which uses exactly this
 * field for its sensitive-content notice. So warnings here go out as
 * `{"systemMessage": "…"}` on stdout, never as `hookSpecificOutput.additionalContext`
 * (that channel injects text into the model's context, which is the opposite of what a
 * human-facing warning should do) and never relying on stderr.
 *
 * FAIL STATES (all silent, all exit 0 — never blocks, never errors of its own):
 *   - guard-core missing, unloadable, incompatible (missing exports), or throwing →
 *     no warning, exit 0.
 *   - Unparseable stdin, a body that isn't a JSON object, or a missing/non-string
 *     `prompt` field (incl. literal `null`, `[]`, or garbage) → no warning, exit 0.
 *   - ai-tc detection throws → treated as ai-tc absent, so this hook's own full scan
 *     still runs (the safe direction for a hook that only ever warns).
 *   - lib/secret-patterns.json missing or corrupt → the credential-pairing check is
 *     skipped silently (same as ai-tc coverage), but the injection-marker and
 *     encoded-shell checks still run; this hook does not have a "patterns unavailable"
 *     warning the way the blocking egress guards do, because there is nothing to fail
 *     closed against here.
 * Requires: bun.
 */
import { readFileSync } from 'fs';
import { dirname, isAbsolute, join } from 'path';
import { homedir } from 'os';
import { fileURLToPath } from 'url';

interface HookInput { prompt?: unknown; cwd?: unknown }

const P = 'prompt-guard: ⚠️ ';

function loadPatternsRaw(): unknown {
  try { return JSON.parse(readFileSync(new URL('./lib/secret-patterns.json', import.meta.url), 'utf-8')); }
  catch { return null; }
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
// active profile happens to carry a meta file. (prompt-guard itself doesn't ship
// in the plugin build today, but this keeps the four hooks' audit gating
// identical and future-proofs it if that changes.)
function isPluginInstall(): boolean {
  return dirname(fileURLToPath(import.meta.url)).includes('/plugins/');
}

async function main(): Promise<void> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync('/dev/stdin', 'utf-8'));
  } catch {
    return;
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return;
  const input = parsed as HookInput;
  if (typeof input.prompt !== 'string') return;
  const prompt = input.prompt;

  type Core = typeof import('./lib/guard-core.js');
  let core: Core;
  try {
    core = await import('./lib/guard-core.js');
    for (const fn of ['scanPrompt', 'detectAitc', 'parsePatterns'] as const) {
      if (typeof core[fn] !== 'function') throw new Error(`guard-core export ${fn} missing`);
    }
  } catch {
    return; // core missing/unreadable/incompatible: silent, never warn, never block
  }

  // ai-tc detection throwing means "treat as absent" here: unlike the blocking guards,
  // this hook's own full scan is always the safe fallback (it can only warn, never deny).
  let aitcPresent = false;
  try {
    aitcPresent = core.detectAitc('claude', { home: homedir(), roots: profileRoots(), ...projectOpt(input) }).present;
  } catch { aitcPresent = false; }

  // Missing/corrupt patterns quietly disables the credential-pairing tier (scanPrompt's
  // `pats &&` guard) without disabling the injection-marker or encoded-shell checks —
  // deliberately narrower than `injectionOnly`, which also skips encoded-shell.
  const patterns = core.parsePatterns(loadPatternsRaw());

  let notices: unknown;
  try {
    notices = core.scanPrompt(prompt, { injectionOnly: aitcPresent, patterns });
    if (!Array.isArray(notices)) return;
  } catch {
    return;
  }

  const lines: string[] = [];
  for (const n of notices) {
    if (!n || typeof n !== 'object') continue;
    const message = (n as { message?: unknown }).message;
    if (typeof message === 'string' && message) lines.push(P + message);
  }

  // Local security-event audit log — one line for the whole decision (the FIRST
  // notice's code), never the prompt text itself, and never fired on a clean
  // prompt. Best effort: loaded lazily so a broken audit.ts can never affect this
  // hook's always-exit-0, never-blocks contract, and computed independently of
  // `aitcPresent` above so a coexistencePolicy failure can't leak into (and
  // narrow) this hook's own detection scope.
  if (notices.length > 0) {
    try {
      let auditLog = true;
      try {
        auditLog = core.coexistencePolicy(core.detectAitc('claude', { home: homedir(), roots: profileRoots(), ...projectOpt(input) })).auditLog !== false;
      } catch { auditLog = true; }
      const { appendAudit } = await import('./lib/audit.ts');
      const first = notices.find((n) => n && typeof n === 'object') as { code?: unknown; message?: unknown } | undefined;
      appendAudit(
        {
          hook: 'prompt-guard', kind: 'prompt',
          rule: typeof first?.code === 'string' ? first.code : undefined,
          detail: typeof first?.message === 'string' ? first.message : undefined,
        },
        { profileRoot: profileRoots()[0] ?? null, enabled: auditLog && !isPluginInstall(), patterns },
      );
    } catch { /* audit logging must never affect this hook's behavior */ }
  }

  if (lines.length === 0) return;
  try {
    process.stdout.write(JSON.stringify({ systemMessage: lines.join('\n') }));
  } catch { /* nothing we can do; still exit 0 below */ }
}

// Never blocks, never prints its own errors: every path — success, any recognised
// failure, or an unexpected throw — ends the same way, exit 0 with no output of its own.
if (import.meta.main) {
  try {
    await main();
  } catch { /* silent, by design */ }
  process.exit(0);
}
