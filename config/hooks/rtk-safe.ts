#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * rtk-safe.ts — PreToolUse rewrite hook for the Bash tool. Transparently rewrites the
 * command of a Bash invocation to its compact `rtk` equivalent so verbose tool output
 * (git/gh/ls/find/test runners/…) is token-reduced before it reaches the model. It only
 * ever REWRITES the command string (via hookSpecificOutput.updatedInput); it never
 * approves anything — the rewritten command still flows through the normal permission
 * rules, so a mutating/outbound form (rtk curl, rtk git push, …) keeps prompting.
 *
 * This is a thin adapter over the vendored guard-core library (lib/guard-core.js), which
 * owns the rule table and `rewrite`/`supportedVersion`. This file re-exports both for
 * tests/rtk-safe*.test.ts, and adds ai-tc coexistence: when ai-tc is installed and enabled
 * for this profile and hooks Bash, this hook defers to it and never rewrites.
 *
 * The import of guard-core is static and deliberate. If the core is missing, unreadable,
 * or fails to load for any reason, the module itself fails to load: bun exits non-zero but
 * NOT with exit 2, so Claude Code never treats it as a block. No `updatedInput` is ever
 * emitted in that case, so the net effect is fail-open — the command runs unrewritten under
 * the normal permission rules, same as every other rtk-safe error path below.
 *
 * Self-skip (exit 0, no rewrite) when:
 *   - the tool is not Bash, or the command is empty;
 *   - ai-tc is installed, enabled for this profile, and hooks Bash (or ai-tc detection
 *     itself throws — see `aitcAllowsRewrite`, conservative on ambiguity);
 *   - `rtk` is absent, older than 0.49.0, a prerelease, or cannot report its version;
 *   - the command already invokes rtk or contains shell operators, substitutions,
 *     escapes, comments, or multiple lines (even quoted operators conservatively skip);
 *   - the command carries a standalone `-h`/`--help`;
 *   - no rule matches.
 *
 * Requires: bun (registered as `<bun> <dir>/rtk-safe.ts`). Unlike the old bash version it
 * cannot degrade-run without bun; the installer makes bun a hard dependency of this addition.
 */
import { readFileSync } from 'fs';
import { spawnSync } from 'child_process';
import { rewrite, supportedVersion, detectAitc, coexistencePolicy } from './lib/guard-core.js';
import { dirname, join } from 'path';
import { homedir } from 'os';
import { fileURLToPath } from 'url';
export { rewrite, supportedVersion };

interface HookInput {
  tool_name?: string;
  tool_input?: Record<string, unknown> | string;
}

// The profile this session runs in: ai-tc only counts if its hooks run here too.
function profileRoots(): string[] {
  const env = process.env.CLAUDE_CONFIG_DIR;
  if (env && env.startsWith('/')) return [env];
  const hooksDir = dirname(fileURLToPath(import.meta.url));
  if (hooksDir.endsWith('/hooks') && !hooksDir.includes('/plugins/')) return [dirname(hooksDir)];
  return [join(homedir(), '.claude')];
}

// ai-tc detection only ever turns rewriting off; if it throws, treat ai-tc as present and
// skip the rewrite — the conservative choice for a rewriter unsure whether ai-tc is here.
function aitcAllowsRewrite(): boolean {
  try {
    return coexistencePolicy(detectAitc('claude', { home: homedir(), roots: profileRoots() }))
      .allowRewrite('Bash');
  } catch {
    return false;
  }
}

function main(): void {
  // Inert until rtk is installed — nothing to rewrite onto.
  if (!Bun.which('rtk')) process.exit(0);

  let input: HookInput;
  try {
    const raw = readFileSync('/dev/stdin', 'utf-8');
    if (!raw.trim()) process.exit(0);
    input = JSON.parse(raw);
  } catch {
    process.exit(0); // a rewrite hook fails open: a parse miss must never block a command.
  }

  if (input.tool_name !== 'Bash') process.exit(0);
  const command =
    typeof input.tool_input === 'string'
      ? input.tool_input
      : (input.tool_input?.command as string | undefined) ?? '';
  if (!command) process.exit(0);

  if (!aitcAllowsRewrite()) process.exit(0);

  const rewritten = rewrite(command);
  if (rewritten === null || rewritten === command) process.exit(0);

  const version = spawnSync('rtk', ['--version'], {
    encoding: 'utf-8', timeout: 1000, maxBuffer: 4096,
  });
  if (version.error || version.status !== 0 || !supportedVersion(version.stdout)) process.exit(0);

  // Preserve all original tool_input fields; change only `command`. No permissionDecision:
  // the rewritten command is re-evaluated by the normal allow/deny/ask flow (returning
  // "allow" here would silently grant every rewritten curl/docker/git push).
  const toolInput =
    typeof input.tool_input === 'object' && input.tool_input !== null ? input.tool_input : {};
  const updatedInput = { ...toolInput, command: rewritten };
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', updatedInput },
    }),
  );
  process.exit(0);
}

// Only run main() when executed directly; importing for tests must not read stdin/exit.
// A rewrite hook must FAIL OPEN: any unexpected throw → no rewrite (the command runs
// as-is under the normal permission rules). It never blocks and never auto-approves, so
// failing open here cannot weaken a security boundary (that is command-guard's job).
if (import.meta.main) {
  try {
    main();
  } catch {
    process.exit(0);
  }
}
