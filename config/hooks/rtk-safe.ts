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
 * Design: a single ordered rule table (RULES). Each rule inspects the leading command and
 * returns the rewritten command body or null ("not mine"); the first non-null wins. Most
 * rules just front the command with `rtk` (optionally gated to a safe subcommand set); a
 * few normalize a form (cat → rtk read, eslint → rtk lint).
 * Simple unquoted `NAME=val` env assignments are split off for matching
 * and re-attached verbatim to the rewrite.
 *
 * Self-skip (exit 0, no rewrite) when:
 *   - the tool is not Bash, or the command is empty;
 *   - `rtk` is absent, older than 0.49.0, a prerelease, or cannot report its version;
 *   - the command already invokes rtk or contains shell operators, substitutions,
 *     escapes, comments, or multiple lines (even quoted operators conservatively skip);
 *   - the command carries a standalone `-h`/`--help` (see HELP_FLAG);
 *   - no rule matches.
 *
 * Credential safety: a `cat`/`grep`/`rg` whose LITERAL text names a credential-bearing
 * path is left UNREWRITTEN, so it stays a reader Claude Code recognizes and the
 * secure-settings Read(...) deny still binds (rewriting to `rtk read` — an unrecognized
 * reader — would slip it past that deny). This is a best-effort guard on the obvious,
 * accidental case (the model typing `cat ~/.ssh/id_rsa`), matching the prior hook's
 * behavior and command-guard's threat model; it scans only the raw string, so symlink
 * targets are not resolved. Variables/substitutions are skipped conservatively.
 * Keep CRED_PATH in sync with settings.base.json's denied read paths.
 *
 * Requires: bun (registered as `<bun> <dir>/rtk-safe.ts`). Unlike the old bash version it
 * cannot degrade-run without bun; the installer makes bun a hard dependency of this addition.
 */
import { readFileSync } from 'fs';
import { spawnSync } from 'child_process';

interface HookInput {
  tool_name?: string;
  tool_input?: Record<string, unknown> | string;
}

// Leading `NAME=val ` assignment(s) — split off before matching, re-attached to the rewrite.
const ENV_PREFIX = /^([A-Za-z_]\w*=[A-Za-z0-9_./:@%+,=~-]* +)+/;
// Command already routed through rtk (bare `rtk …` or a path `…/rtk …`).
const ALREADY_RTK = /^(\S*\/)?rtk\s/;
// A STANDALONE `-h`/`--help` anywhere in the command. rtk's own argument parser claims
// these for its per-subcommand --help BEFORE the flags reach the underlying tool, so a
// rewrite would print rtk's usage and exit 0 — a silently empty result that reads like
// "no matches" (verified on 0.49.0 for grep -h, ls -h, diff -h, wc -h, git -h). Help
// output is already short, so skipping costs no meaningful compression. Bundled forms
// (-lh, -rh, -nh) are passed through by rtk untouched and stay eligible.
//
// Deliberately blanket rather than per-command. rtk forwards `-h` for a few pure
// passthrough subcommands (`rtk psql -h <host>` reaches psql intact), so this gives up
// compression on those. That's the accepted price: which subcommands claim `-h` is an
// rtk-internal detail that can shift between releases, and the failure mode it prevents
// is silent (right-looking output, exit 0) while the cost is merely a missed saving.
const HELP_FLAG = /(?:^|\s)(?:-h|--help)(?=\s|$)/;

// Compatibility floor, tested against the real binary. Unknown/prerelease builds
// fail open to the original command rather than enabling unverified rewrites.
export function supportedVersion(version: string): boolean {
  const m = version.trim().match(/^rtk (\d+)\.(\d+)\.(\d+)$/);
  return !!m && (Number(m[1]) > 0 || Number(m[2]) >= 49);
}

// Credential-bearing read targets — a cat/head of one of these must NOT be rewritten (see
// the header note). Mirrors the secure-settings denied read set; functional, not creative.
const CRED_PATH =
  /\.(ssh|gnupg|aws|azure|kube|pypirc|netrc|electrum|ethereum)($|[^\w])|\.npmrc($|[^\w])|\/gcloud\/|\.docker\/config\.json|\.gem\/credentials|\.git-credentials|\/\.config\/gh\/|Library\/Keychains\/|Application Support\/Electrum|\/Electrum\/|\/Exodus\/|Library\/Ethereum\/|\/[Mm]eta[Mm]ask\/|\/[Pp]hantom\/|\/[Ss]olflare\/|(^|[^\w.])\.env($|[^\w])/;

// ── small command helpers ─────────────────────────────────────────────────────
const leadWord = (cmd: string): string => cmd.trimStart().split(/\s+/, 1)[0] ?? '';
const startsWithWord = (cmd: string, word: string): boolean =>
  cmd === word || cmd.startsWith(word + ' ');
// Like startsWithWord but REQUIRES at least one argument — for commands that are a no-op
// bare (cat/find/diff/curl/wget/aws), matching the old hook's `^cmd[[:space:]]+` anchor.
const withArgs = (cmd: string, word: string): boolean => cmd.startsWith(word + ' ');
// front the whole body with `rtk ` (the common case).
const front = (body: string): string => 'rtk ' + body;

// Drop a leading program token plus a set of global option forms to expose the
// subcommand. `valued` options consume a following argument (`-C dir`); `--x=y` and the
// listed long flags are dropped inline. Used by git/docker/kubectl subcommand gating.
function subcommand(
  body: string,
  prog: string,
  opts: { valued?: RegExp; longFlags?: RegExp } = {},
): string {
  let rest = body.slice(prog.length).trimStart();
  for (;;) {
    const tok = rest.split(/\s+/, 1)[0] ?? '';
    if (!tok) break;
    if (opts.valued?.test(tok)) {
      // option + its separate argument
      const after = rest.slice(tok.length).trimStart();
      rest = after.slice((after.split(/\s+/, 1)[0] ?? '').length).trimStart();
      continue;
    }
    if (/^--[a-z][\w-]*=/.test(tok) || opts.longFlags?.test(tok)) {
      rest = rest.slice(tok.length).trimStart();
      continue;
    }
    break;
  }
  return rest.split(/\s+/, 1)[0] ?? '';
}

// ── rule table (ordered; first non-null wins) ─────────────────────────────────
type Rule = (body: string) => string | null;

const GIT_SUBCMDS = new Set([
  'status', 'diff', 'log', 'add', 'commit', 'push', 'pull', 'branch', 'fetch', 'stash', 'show',
]);
const CARGO_SUBCMDS = new Set(['test', 'build', 'clippy', 'check', 'install', 'fmt']);
const DOCKER_SUBCMDS = new Set(['ps', 'images', 'logs', 'run', 'build', 'exec']);
const DOCKER_COMPOSE_SUBCMDS = new Set(['ps', 'logs', 'build']);
const KUBECTL_SUBCMDS = new Set(['get', 'logs', 'describe', 'apply']);

const RULES: Rule[] = [
  // git — only the common read/write subcommands (strip -C/-c <arg>, --x=y, a few long flags).
  (b) => {
    if (!startsWithWord(leadWord(b), 'git')) return null;
    const sub = subcommand(b, 'git', {
      valued: /^-[Cc]$/,
      longFlags: /^--(no-pager|no-optional-locks|bare|literal-pathspecs)$/,
    });
    return GIT_SUBCMDS.has(sub) ? front(b) : null;
  },
  // gh — the verbose, paginated surfaces.
  (b) => {
    const sub = subcommand(b, 'gh');
    return startsWithWord(leadWord(b), 'gh') && ['pr', 'issue', 'run', 'api', 'release'].includes(sub)
      ? front(b)
      : null;
  },
  // cargo — allow an optional +toolchain before the subcommand.
  (b) => {
    if (!startsWithWord(leadWord(b), 'cargo')) return null;
    let rest = b.slice('cargo'.length).trimStart();
    if (rest.startsWith('+')) rest = rest.slice((rest.split(/\s+/, 1)[0] ?? '').length).trimStart();
    return CARGO_SUBCMDS.has(rest.split(/\s+/, 1)[0] ?? '') ? front(b) : null;
  },

  // file reads — cat becomes `rtk read`; a credential-path target is left alone.
  (b) => {
    if (!withArgs(b, 'cat')) return null;
    if (CRED_PATH.test(b)) return null;
    // Only plain file operands: cat's flags/stdin are not rtk read's interface.
    if (/(?:^|\s)["']?-/.test(b.slice(4))) return null;
    return 'rtk read ' + b.slice('cat'.length).trimStart();
  },
  // `head -N` is deliberately NOT rewritten. `rtk read --max-lines N` is not a head
  // equivalent: on 0.49.0 it renders floor(N/2) content lines plus a "[… more lines]"
  // marker (head -1 → ZERO content lines, head -20 → 10), so the model silently gets
  // half the window it asked for. It also drops the `==> file <==` banners on a
  // multi-file head and applies the budget across the concatenation rather than per
  // file. Re-enable only if rtk grows a true head-N mode, and pin it with a real-RTK
  // equivalence check in rtk-safe-behavior.test.ts before shipping.

  // grep/rg — RTK >= 0.49 preserves native -n/-v and the selected engine. Keep credential
  // reads raw, and never compress a pipe's intermediate data (below). rg is the single
  // highest-value rewrite after `rtk read` (~19x grep's saving per call in the `rtk gain`
  // sample), which is why it carries its own approval rather than being skipped.
  //
  // Both are auto-approved in rtk-allowlist.json. `rtk grep` is safe by construction — it
  // dispatches to the system grep, which has no exec primitive. `rtk rg` is NOT: ripgrep's
  // `--pre`/`--hostname-bin` run an arbitrary binary and RIPGREP_CONFIG_PATH injects flags
  // from a file. Those three are blocked by command-guard (detectSearchExec), and that
  // block is what makes the approval safe. Do not approve rg in a profile without it.
  (b) => ((withArgs(b, 'grep') || withArgs(b, 'rg')) && !CRED_PATH.test(b) ? front(b) : null),
  (b) => (startsWithWord(leadWord(b), 'ls') ? front(b) : null),
  (b) => (startsWithWord(leadWord(b), 'tree') ? front(b) : null),
  (b) => (withArgs(b, 'find') ? front(b) : null),
  (b) => (withArgs(b, 'diff') ? front(b) : null),

  // Explicit runners only. Never replace pnpm scripts, npx resolution, vue-tsc,
  // python -m, or uv with a different tool/interpreter. Bare vitest keeps watch mode.
  (b) => {
    const m = b.match(/^vitest\s+run(\s.*|$)/);
    return m ? 'rtk vitest run' + m[1] : null;
  },
  (b) => (startsWithWord(b, 'npm test') ? 'rtk npm test' + b.slice('npm test'.length) : null),
  (b) => {
    const m = b.match(/^npm\s+run\s+(.+)$/);
    // Keep `run`: dropping it turns scripts named install/publish into npm operations.
    return m ? front(b) : null;
  },
  (b) => {
    const m = b.match(/^tsc(\s.*|$)/);
    return m ? 'rtk tsc' + m[1] : null;
  },
  (b) => {
    const m = b.match(/^eslint(\s.*|$)/);
    return m ? 'rtk lint' + m[1] : null;
  },
  (b) => {
    const m = b.match(/^prettier(\s.*|$)/);
    return m ? 'rtk prettier' + m[1] : null;
  },
  (b) => {
    const m = b.match(/^prisma(\s.*|$)/);
    return m ? 'rtk prisma' + m[1] : null;
  },

  // containers — gated subcommand sets (compose handled before the generic docker path).
  (b) => {
    if (!startsWithWord(leadWord(b), 'docker')) return null;
    if (/^docker\s+compose($|\s)/.test(b)) {
      const sub = b.replace(/^docker\s+compose\s*/, '').split(/\s+/, 1)[0] ?? '';
      return DOCKER_COMPOSE_SUBCMDS.has(sub) ? front(b) : null;
    }
    const sub = subcommand(b, 'docker', {
      valued: /^(-H|--context|--config)$/,
    });
    return DOCKER_SUBCMDS.has(sub) ? front(b) : null;
  },
  (b) => {
    if (!startsWithWord(leadWord(b), 'kubectl')) return null;
    const sub = subcommand(b, 'kubectl', {
      valued: /^(--context|--kubeconfig|--namespace|-n)$/,
    });
    return KUBECTL_SUBCMDS.has(sub) ? front(b) : null;
  },

  // network — fronted (still prompts; rtk curl/wget are not auto-approved).
  (b) => (withArgs(b, 'curl') ? front(b) : null),
  (b) => (withArgs(b, 'wget') ? front(b) : null),

  // pnpm package queries.
  (b) => {
    const sub = subcommand(b, 'pnpm');
    return startsWithWord(leadWord(b), 'pnpm') && ['list', 'ls', 'outdated'].includes(sub)
      ? front(b)
      : null;
  },

  // python tooling.
  (b) => (startsWithWord(leadWord(b), 'pytest') ? front(b) : null),
  (b) => {
    const sub = subcommand(b, 'ruff');
    return startsWithWord(leadWord(b), 'ruff') && ['check', 'format'].includes(sub) ? front(b) : null;
  },
  (b) => {
    const sub = subcommand(b, 'pip');
    return startsWithWord(leadWord(b), 'pip') && ['list', 'outdated', 'install', 'show'].includes(sub)
      ? front(b)
      : null;
  },
  (b) => (startsWithWord(leadWord(b), 'mypy') ? front(b) : null),

  // go tooling.
  (b) => {
    if (!startsWithWord(leadWord(b), 'go')) return null;
    const sub = b.slice('go'.length).trimStart().split(/\s+/, 1)[0] ?? '';
    return ['test', 'build', 'vet'].includes(sub) ? front(b) : null;
  },
  (b) => (startsWithWord(leadWord(b), 'golangci-lint') ? front(b) : null),

  // misc CLIs.
  (b) => (withArgs(b, 'aws') ? front(b) : null),
  (b) => (startsWithWord(leadWord(b), 'psql') ? front(b) : null),
];

/** Compute the rewritten command (incl. env prefix), or null if nothing applies. */
export function rewrite(command: string): string | null {
  // Deliberately conservative, not a shell parser. Even quoted metacharacters
  // are skipped. Compression belongs at the display boundary, never before a
  // pipe/redirection, and options must not migrate across command boundaries.
  if (ALREADY_RTK.test(command) || /[|&;<>`$(){}\\\n\r#]/.test(command)) return null;
  if (HELP_FLAG.test(command)) return null;
  const prefix = command.match(ENV_PREFIX)?.[0] ?? '';
  // The runtime version probe uses the hook's PATH. Do not rewrite onto a
  // different, unverified RTK selected by a command-local PATH assignment.
  if (/(^| )PATH=/.test(prefix)) return null;
  const body = command.slice(prefix.length);
  for (const rule of RULES) {
    const out = rule(body);
    if (out !== null) return prefix + out;
  }
  return null;
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
