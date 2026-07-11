#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * command-guard.ts — PreToolUse hook for the Bash tool. The SOLE Bash egress guard
 * (bun is a hard dependency of this addition; see install.sh). leak-guard.ts is now
 * WEB-only — all Bash egress checking lives here. It blocks:
 *   - DENY: piping output into a shell (curl … | bash) — structural.
 *   - DENY: writing to a shell STARTUP file (~/.zshrc, ~/.bashrc, …) via a Bash
 *     redirection or write-capable command — a persistence vector the secure-settings
 *     Edit/Write deny can't reach through a Bash redirection. Legit alias writes go
 *     through `./install.sh --alias`, whose command string doesn't match this check.
 * On an OUTBOUND command (one naming curl/wget/nc/ncat/socat/fetch — the ~2% fast
 * gate; ~98% of Bash calls pay ~0 ms), it additionally runs three egress tiers,
 * mirroring leak-guard's old Bash branch so no coverage is lost in the consolidation:
 *   - DENY Tier 1: a detected secret (trufflehog, run local / --no-verification so the
 *     candidate never leaves the box). Degrades to the regex tiers if trufflehog absent.
 *   - DENY Tier 2: a match against your opt-in org markers (CT_EGRESS_PATTERNS). The
 *     pattern is read from the install-COMPILED sidecar lib/org-egress.json — this hook
 *     NEVER sources the user's shell config (a bun process can't safely evaluate
 *     arbitrary shell). install.sh compiles + validates the pattern; here we only
 *     consume validated JSON.
 *   - DENY Tier 3: a shared credential key-SHAPE (from lib/secret-patterns.json — one
 *     source of truth, also read by leak-guard for web egress).
 *   - ALERT (allow + log): other egress vectors (nc/socat/sendmail, env dumps,
 *     inline interpreter execution).
 *
 * Protocol: deny → exit 2 (Claude Code blocks); alert/allow → exit 0.
 *
 * FAIL STATES:
 *   - Shared patterns file missing/corrupt → FAIL CLOSED on outbound commands (block),
 *     since we cannot run the credential scan we're here to run.
 *   - Org sidecar missing / unparseable / malformed → org tier INACTIVE (it is opt-in),
 *     never a crash: this is the sole Bash guard, so a bad sidecar parse must not take
 *     down the pipe-to-shell + trufflehog tiers with it.
 *   - Unparseable stdin → fail open, but LOUDLY (stderr).
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

// Degraded-mode fallback ONLY (patterns unloadable) to find the risky subset to
// fail closed on. NOT the source of truth — that's lib/secret-patterns.json.
const FALLBACK_OUTBOUND = /\b(curl|wget|nc|ncat|socat|fetch)\b/i;

// CONSERVATIVE raw-string fallbacks — used ONLY if the tokenizer throws (pathological
// input). They OVER-block (the very FPs this PR removes) but must never UNDER-block what
// the tokenizer would catch, so a parser failure degrades to "too strict", never to a
// silent allow on the sole Bash guard. Deliberately broad: any pipe (incl. |&) into an
// interpreter — bare, by path (`| /bin/bash`), or wrapped in env (`| env -i bash`); any
// '>'-ish redirection OR write-verb anywhere on a line that names a startup dotfile (a rare
// fallback path, so over-blocking a read like `cp .zshrc x` is fine).
// The env wrapper-word class is \S+ (not [-\w=]+) so a slash-bearing option ARG — `-C /tmp`,
// BSD `-P /usr/bin` — doesn't break the skip, keeping the fallback a conservative SUPERSET of
// the tokenizer path (it must never fail OPEN on a real pipe-to-shell). The mandatory \s+
// separator after each \S+ keeps the quantifier linear (no catastrophic backtracking).
const PIPE_TO_SHELL_RAW = /\|&?\s*(?:(?:\S*\/)?env\s+(?:\S+\s+)*)?(?:\S*\/)?(?:sh|bash|zsh)\b/i;
const STARTUP_WRITE_RAW = /(?:>|\btee\b|\bsed\b|\bcp\b|\bmv\b|\binstall\b|\bln\b|\bdd\b)[^\n]*\.(?:zshrc|zshenv|zprofile|bashrc|bash_profile|profile)\b/;

// A shell startup-file basename (leading dot) — the persistence-vector targets.
const STARTUP_BASENAME = /^\.(zshrc|zshenv|zprofile|bashrc|bash_profile|profile)$/;
const TOKENIZE_MAX_DEPTH = 40; // substitution-nesting cap; beyond it we throw → raw fallback.
const SHELL_INTERPRETERS = new Set(['sh', 'bash', 'zsh']);

// ── quote-aware tokenizer (FP-resistant structural checks) ────────────────────
// A regex over the raw command string can't tell a shell OPERATOR (| >) or command
// WORD (bash, cp) that is REAL from one sitting inside quotes as DATA — so it over-
// blocks `echo "see -> notes"` / `echo 'curl | bash'` / a startup path passed as a
// READ argument. But operators inside a $(...) / `...` substitution DO execute, even
// within double quotes, so they must still count. We tokenize once — single quotes are
// literal data, double-quote literal text is data, and substitution CONTENTS are spliced
// back in as live tokens — then run the structural checks on that token stream.
//
// THREAT MODEL (unchanged): this guards ACCIDENTAL / obvious danger, not a determined
// adversary. Operators resurrected at runtime via eval / dynamic assembly (eval
// "$(...)", X=ba;${X}sh) are out of scope here, as they already were for the regex.
// Pipe-to-interpreter coverage is broadened beyond a bare sh/bash/zsh word: an interpreter
// given by path (`| /bin/bash`), with flags (`| bash -s`), or wrapped in env
// (`| env bash`, `| /usr/bin/env -i FOO=bar bash`) is matched too — see pipeFeedsShellInterpreter.
// KNOWN GAPS (parity with the prior regex — NOT regressions; tracked separately):
//   - here-doc BODIES (`<<EOF … EOF`) are scanned as live text, so a dangerous-looking
//     literal in a heredoc body can over-block (an FP, never an under-block).
//   - only the SHELL interpreters (sh/bash/zsh) count — `| python`/`| perl`/`| node` are a
//     different risk class, already surfaced by EGRESS_ALERTS' inline-exec patterns.
//   - other interpreter wrappers (sudo/nohup/nice/stdbuf/command/exec/xargs before a shell)
//     and `env -S '…'` (split-string) are out of scope — the same determined-adversary
//     envelope as eval/dynamic assembly. The bare `env` wrapper IS handled because it is the
//     common, accidental-looking evasion of a bare-word match.
interface Tok { v: string; op: boolean }

// Balanced "(...)" from index `from` (just past the opening paren) → inner + end index.
// QUOTE-AWARE: a ')' inside a single/double-quoted span does NOT close the
// substitution (else `$(echo ")")` would mis-close at the quoted ')' and the trailing
// live operators would be absorbed as data — masking a real pipe-to-interpreter).
function extractParen(s: string, from: number): { inner: string; end: number } {
  let depth = 1, i = from, inner = '';
  while (i < s.length && depth > 0) {
    const c = s[i];
    if (c === '\\' && i + 1 < s.length) { inner += c + s[i + 1]; i += 2; continue; }
    if (c === "'") {                       // single-quoted span — copy verbatim, no paren counting
      inner += c; i++;
      while (i < s.length && s[i] !== "'") { inner += s[i]; i++; }
      if (i < s.length) { inner += s[i]; i++; }
      continue;
    }
    if (c === '"') {                       // double-quoted span — copy verbatim (honoring \")
      inner += c; i++;
      while (i < s.length && s[i] !== '"') {
        if (s[i] === '\\' && i + 1 < s.length) { inner += s[i] + s[i + 1]; i += 2; continue; }
        inner += s[i]; i++;
      }
      if (i < s.length) { inner += s[i]; i++; }
      continue;
    }
    if (c === '(') depth++;
    else if (c === ')') { depth--; if (depth === 0) { i++; break; } }
    inner += c; i++;
  }
  return { inner, end: i };
}
// `...` from index `from` (just past the opening backtick) → inner + end index.
function extractBacktick(s: string, from: number): { inner: string; end: number } {
  let i = from, inner = '';
  while (i < s.length && s[i] !== '`') {
    if (s[i] === '\\' && i + 1 < s.length) { inner += s[i] + s[i + 1]; i += 2; continue; }
    inner += s[i]; i++;
  }
  return { inner, end: i + 1 };
}

function tokenize(cmd: string, depth = 0): Tok[] {
  if (depth > TOKENIZE_MAX_DEPTH) throw new Error('command-guard: substitution nesting too deep');
  const toks: Tok[] = [];
  let word = '', has = false;
  const flush = () => { if (has) toks.push({ v: word, op: false }); word = ''; has = false; };
  // Splice a substitution / process-substitution's inner command in as LIVE tokens,
  // BRACKETED by ';' separators. The brackets keep the inner as its OWN simple-command(s)
  // for verb-direction detection (so `echo "$(tee ~/.zshrc)"` / `> >(tee ~/.zshrc)` see
  // `tee` as a command word, not glued into the parent), while pipe/redirect scans, which
  // look across the whole stream, are unaffected.
  const spliceInner = (inner: string) => {
    flush();
    toks.push({ v: ';', op: true });
    for (const t of tokenize(inner, depth + 1)) toks.push(t);
    toks.push({ v: ';', op: true });
  };
  let i = 0;
  const n = cmd.length;
  while (i < n) {
    const c = cmd[i];
    if (c === ' ' || c === '\t') { flush(); i++; continue; }
    // A newline can begin a new command on the next line — emit a dedicated '\n'
    // command-separator token so command-position tracking (the case-keyword recognition
    // in caseAlternationPipes) survives across lines, e.g. `ext=foo\ncase "$ext" in …`.
    // Emit ONLY after a bare WORD: that is the sole place a following line starts a fresh
    // command at command position. After an OPERATOR we never emit — a list separator
    // (; & && || | |&) has already marked the next command position, while a pipe or a
    // redirection op EXPECTS its target/continuation on the next line, and inserting a
    // token there would sever `… | bash` or `> ~/.zshrc` across the newline and fail OPEN
    // on the sole Bash guard (the regression a cross-vendor review caught). This keeps the
    // pipe and startup-write scans byte-for-byte as they were pre-change. (Backslash-
    // newline is handled by the escape rule above; a quoted newline is data in its span.)
    if (c === '\n') {
      flush();
      const last = toks[toks.length - 1];
      if (last && !last.op) toks.push({ v: '\n', op: true });
      i++; continue;
    }
    // a '#' at a WORD BOUNDARY (not mid-word like a#b, not inside quotes) starts a shell
    // comment → skip to end of line. Prevents FPs where a comment merely MENTIONS a pipe
    // or redirect (`echo hi # see ~/.zshrc`). Operators BEFORE the '#' are already tokenized.
    if (c === '#' && !has) { while (i < n && cmd[i] !== '\n') i++; continue; }
    if (c === '\\' && i + 1 < n) { word += cmd[i + 1]; has = true; i += 2; continue; }
    if (c === "'") {                                   // single quote: literal data
      i++;
      while (i < n && cmd[i] !== "'") { word += cmd[i]; has = true; i++; }
      i++; continue;
    }
    if (c === '"') {                                   // double quote: data, but subst is live
      i++;
      while (i < n && cmd[i] !== '"') {
        if (cmd[i] === '\\' && i + 1 < n) { word += cmd[i + 1]; has = true; i += 2; continue; }
        if (cmd[i] === '$' && cmd[i + 1] === '(') { const b = extractParen(cmd, i + 2); spliceInner(b.inner); i = b.end; continue; }
        if (cmd[i] === '`') { const b = extractBacktick(cmd, i + 1); spliceInner(b.inner); i = b.end; continue; }
        word += cmd[i]; has = true; i++;
      }
      i++; continue;
    }
    if (c === '$' && cmd[i + 1] === '(') { const b = extractParen(cmd, i + 2); spliceInner(b.inner); i = b.end; continue; }
    if (c === '`') { const b = extractBacktick(cmd, i + 1); spliceInner(b.inner); i = b.end; continue; }
    // process substitution <(…) / >(…) — its inner is a LIVE command (a write/pipe there
    // executes), so recurse like $(…). Without this, `> >(tee ~/.zshrc)` would hide the
    // tee-to-startup write. The leading < / > is emitted as an op (harmless; the real
    // redirect target is the process-sub, not a file).
    if ((c === '<' || c === '>') && cmd[i + 1] === '(') { flush(); toks.push({ v: c, op: true }); const b = extractParen(cmd, i + 2); spliceInner(b.inner); i = b.end; continue; }
    // bare ( ) — subshell / grouping. Real $(…) and <(…)/>(…) were consumed above; here
    // they are WORD BOUNDARIES so a trailing ')' doesn't glue onto the last word.
    if (c === '(' || c === ')') { flush(); toks.push({ v: c, op: true }); i++; continue; }
    // operators (longest first): redirections incl. bash compound forms
    // (&>, &>>, >&, >|, fd-prefixed), then pipes (incl. |&) / lists. Compound redirect
    // forms are lexed as SINGLE tokens so the target that follows is detected (a raw lexer
    // splitting `>|` into `>`+`|` would miss the post-`|` target — a real persistence write).
    const m = /^(\d*>>|\d*>&|\d*>\||\d*>|&>>|&>|<<<|<<|<|\|\||\|&|\||&&|&|;)/.exec(cmd.slice(i));
    if (m) { flush(); toks.push({ v: m[1], op: true }); i += m[1].length; continue; }
    word += c; has = true; i++;
  }
  flush();
  return toks;
}

function isStartupFile(w: string): boolean {
  const base = w.split('/').pop() ?? w;
  return STARTUP_BASENAME.test(base);
}

// Lowercased basename of a command word: `/bin/bash` → `bash`, `./sh` → `sh`, `bash` → `bash`.
// Case-insensitive (on a case-insensitive FS like macOS, `BASH` resolves to bash).
function cmdBasename(w: string): string {
  return (w.split('/').pop() ?? w).toLowerCase();
}
function isInterpreterWord(w: string): boolean {
  return SHELL_INTERPRETERS.has(cmdBasename(w));
}

// Starting at the word AFTER a pipe operator (index j), resolve the command the pipe feeds —
// walking through any `env` wrapper(s) and a leading subshell/group opener — and report whether
// it is a SHELL interpreter. Catches a bare word (`| bash`), a path form (`| /bin/bash`), flags
// (`| bash -s`, the flags are later words so the first word already matches), a subshell/group
// (`| (bash)`, `| { bash; }`), and env (`| env bash`, `| /usr/bin/env -i X=y bash`). env's own
// options that take a SEPARATE argument (`-u NAME`, `-C DIR`, BSD `-P utilpath`, GNU `-a argv0`),
// flags with no arg (`-i`, `-v`, `-0`, `-`), long `--opt=value` forms, and NAME=VALUE assignments
// are skipped to reach the real command word; a non-interpreter, non-env word stops the walk (no
// false positive on `| env python`, `| grep bash`, `| (grep foo; wc)`).
// OUT OF SCOPE (determined-adversary, same envelope as eval/dynamic assembly — see the GAPS note
// above): `env -S '…'` (split-string embeds the command in a quoted string) and space-separated
// long-option arg forms (`env --unset FOO bash`); both are obfuscation, not accidental danger.
const SUBSHELL_OPENERS = new Set(['(', '{']);
// Once the pipe target is confirmed a shell interpreter, decide whether it actually CONSUMES
// the piped stdin (the `curl URL | bash` risk) or just runs a NAMED SCRIPT FILE and ignores
// stdin (`printf '{}' | bash ./script.sh` — a benign FP, issue #94). Starting at the token
// after the interpreter word (index j), scan its arguments:
//   • `-s`            → bash explicitly reads the program from stdin → still danger (true).
//   • `-c`            → runs the inline command-string ARG; the piped data becomes that
//                        command's stdin. This is a determined pipe-into-shell exec idiom, not
//                        a benign named-script run → danger (true). Alone or bundled (`-ic`,
//                        `-lc`, `-xc`), and the same across sh/zsh.
//   • `--`            → end of options; the NEXT non-operator word is the script file → safe.
//   • a non-flag word → the script file → bash runs it, ignores stdin → safe (false).
//   • `-o`/`-O`, `--init-file`, `--rcfile` → consume the NEXT separate token as their VALUE
//                        (not a script file); bash still reads stdin after them. Skip BOTH the
//                        flag and its value — but ONLY when that next token is actually present
//                        AND a non-operator word. If it's an operator (`| bash -O && ls`) or
//                        missing (`| bash -O`), the flag took no value, so we must NOT skip past
//                        it; bash reads stdin → danger. `-o`/`-O` handled standalone and
//                        bundled-end (`-eo`, `-xO`); mid-bundle forms embed the value in the
//                        same token and fall through to j++ (no separate token to skip).
//   • any other flag  → pass-through (`-e`, `-x`, `-u`, …) → keep scanning.
// No script-file word before an operator / end (bare `| bash`, `| bash -e`) → stdin → danger.
function shellInterpreterReadsStdin(toks: Tok[], j: number): boolean {
  while (j < toks.length && !toks[j].op) {
    const a = toks[j].v;
    if (a === '--') {                                     // end of options
      j++;
      return !(j < toks.length && !toks[j].op);           // next word = script file → safe
    }
    if (!a.startsWith('-')) return false;                 // bare word → script file → safe
    if (/^-[a-zA-Z]*s/.test(a)) return true;              // `-s` (alone or bundled) → reads stdin
    if (/^-[a-zA-Z]*c/.test(a)) return true;              // `-c` (alone or bundled) → runs inline command arg → danger
    // Flags that consume the NEXT separate token as an option value (not a script file).
    // Skip BOTH only when that value token is present and not an operator; otherwise the flag
    // took no value, bash still reads stdin, and skipping an operator/file would mis-allow it.
    if (/^-[a-zA-Z]*[oO]$/.test(a) || a === '--init-file' || a === '--rcfile') {
      if (j + 1 < toks.length && !toks[j + 1].op) { j += 2; continue; }  // value present → skip both
      return true;                                        // no value (operator/end) → reads stdin
    }
    j++;                                                  // a pass-through flag → keep scanning
  }
  return true;                                            // no script file → reads stdin
}
function pipeFeedsShellInterpreter(toks: Tok[], j: number): boolean {
  // skip a leading subshell `(`/process-group `{` opener: `| (bash)` / `| { bash; }` run a shell.
  // `(` is an operator token, `{` a bare word — accept either, then resolve the inner command.
  while (j < toks.length && SUBSHELL_OPENERS.has(toks[j].v)) j++;
  // skip leading NAME=VALUE assignments on the pipe RHS (e.g. `| IFS=x bash`) — same bypass
  // class as the command-side env-prefix (issue #114); shell runs the first bare-word command.
  while (j < toks.length && !toks[j].op && /^[A-Za-z_][A-Za-z0-9_]*=/.test(toks[j].v)) j++;
  while (j < toks.length && !toks[j].op) {
    if (isInterpreterWord(toks[j].v)) return shellInterpreterReadsStdin(toks, j + 1);
    if (cmdBasename(toks[j].v) !== 'env') return false;   // not an interpreter, not env → done
    j++;                                                   // step past `env` toward its command
    while (j < toks.length && !toks[j].op) {
      const a = toks[j].v;
      if (a === '-') { j++; continue; }                   // `env -` ignore-environment marker
      if (a.startsWith('-')) {                             // an env option flag
        if (/^-[uCPa]$/.test(a)) j++;                      // short opt taking a SEPARATE arg
        j++; continue;
      }
      if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(a)) { j++; continue; }  // NAME=VALUE assignment
      break;                                               // first bare word: env's command
    }
    // loop re-checks toks[j] as the resolved command (could itself be another env, rare)
  }
  return false;
}

// ── case-statement awareness (FP fix, issue #75) ──────────────────────────────
// In a `case … in <pat>)` construct the `|` between patterns is a pattern-OR
// SEPARATOR, not a pipe — so `case "$ext" in py|sh|bash|zsh)` does NOT pipe into a
// shell, even though `sh|bash` looks like one. We do ONE structural pass to find every
// `|` that sits inside a case pattern list, so detectPipeToShell can skip exactly those.
//
// SAFETY — this must NEVER cause an under-block of a real pipe-to-shell. In real bash,
// between `in` (or an arm terminator `;;`/`;&`/`;;&`) and the `)` that closes a pattern
// list, a `|` is ALWAYS alternation — bash never runs a pipe there (a would-be pipe like
// `case x in foo|bash` is a syntax error without the `)`). So as long as our "pattern"
// state corresponds to bash's, skipping those `|` is safe. The one way to diverge is to
// treat `case`/`in` as keywords when bash sees them as ordinary WORDS (arguments) — e.g.
// `echo case in foo | bash`, where `| bash` is a genuine pipe. We therefore recognize
// `case` ONLY at command position (start of input, or right after a command separator /
// newline) — exactly where bash treats it as the keyword. We also recognize bash's
// optional leading `(` on a pattern (`case x in (a|b) …`). esac / an early-popped case
// only ever REDUCES pattern context, which is the over-block (safe) direction.
// Reserved words after which (at command position) another COMMAND begins — so a
// `case` directly following one of them is still the keyword. `{` `(` introduce a group;
// `!`/`time` prefix a pipeline; the rest are compound-command introducers.
const CMD_INTRODUCERS = new Set(['do', 'then', 'else', 'elif', 'if', 'while', 'until', '{', '!', 'time']);
function caseAlternationPipes(toks: Tok[]): Set<number> {
  const marks = new Set<number>();
  // Each open `case` is a frame: 'awaitIn' (seen `case`, want `in`) → 'pattern' (inside a
  // pattern list, `|` is alternation) → 'body' (arm commands; `|` is a real pipe again).
  const stack: { state: 'awaitIn' | 'pattern' | 'body' }[] = [];
  let atCmdPos = true;   // start of input is a command position
  let prevSemi = false;  // previous token was a single ';' (for `;;`/`;&` arm detection)
  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    const top = stack.length ? stack[stack.length - 1] : null;
    if (t.op) {
      if (t.v === '(') {
        // A `(` right inside a pattern list is bash's optional pattern-group opener
        // (`case x in (a|b) …`), matched by the arm-closing `)` — NOT a subshell, so it
        // does not change pattern state. Elsewhere it opens a subshell/group.
        atCmdPos = true; prevSemi = false;
      } else if (t.v === ')') {
        if (top && top.state === 'pattern') top.state = 'body';  // closes the pattern list
        atCmdPos = false; prevSemi = false;
      } else if (t.v === '|') {
        if (top && top.state === 'pattern') marks.add(i);        // alternation, not a pipe
        atCmdPos = true; prevSemi = false;
      } else if (t.v === ';') {
        if (top && top.state === 'body' && prevSemi) top.state = 'pattern';  // `;;`
        atCmdPos = true; prevSemi = true;
      } else if (t.v === '&') {
        if (top && top.state === 'body' && prevSemi) top.state = 'pattern';  // `;&` / `;;&`
        atCmdPos = true; prevSemi = false;
      } else if (t.v === '||' || t.v === '&&' || t.v === '|&' || t.v === '\n') {
        atCmdPos = true; prevSemi = false;
      } else {
        atCmdPos = false; prevSemi = false;  // redirections etc.
      }
    } else {
      const w = t.v;
      const wasCmdPos: boolean = atCmdPos;
      if (w === 'case' && wasCmdPos) stack.push({ state: 'awaitIn' });
      else if (w === 'in' && top && top.state === 'awaitIn') top.state = 'pattern';
      else if (w === 'esac' && top) stack.pop();
      // A command-introducing reserved word (do/then/else/{/… at command position)
      // is followed by another COMMAND, so the next word is still at command position —
      // this is what lets `do case …` / `then case …` recognize the keyword. Any other
      // word consumes the command position.
      atCmdPos = wasCmdPos && CMD_INTRODUCERS.has(w);
      prevSemi = false;
    }
  }
  return marks;
}

// pipe-to-shell: a real `|`/`|&` operator whose command resolves to a shell interpreter.
// A `|` that is a case pattern-list alternation (not a pipe) is skipped — see above.
function detectPipeToShell(toks: Tok[]): boolean {
  const alt = caseAlternationPipes(toks);
  for (let i = 0; i < toks.length - 1; i++) {
    if (toks[i].op && (toks[i].v === '|' || toks[i].v === '|&') && !alt.has(i) && pipeFeedsShellInterpreter(toks, i + 1)) return true;
  }
  return false;
}

// startup-file WRITE: (1) a redirection (> / >> / fd>) whose target is a startup file,
// or (2) a write-capable command with a startup file as its DESTINATION. Direction-aware:
// a startup file as a cp/mv/ln SOURCE is a read and is NOT flagged.
function detectStartupWrite(toks: Tok[]): boolean {
  // (1) any redirection operator (it contains '>': > >> n> &> &>> >& >|) whose target
  //     token is a startup file. '<' / '<<' (reads/here-docs) don't contain '>' → ignored.
  //     A fd-dup like 2>&1 has a number, not a startup path, as its next token → not flagged.
  for (let i = 0; i < toks.length - 1; i++) {
    if (toks[i].op && toks[i].v.includes('>') && !toks[i + 1].op && isStartupFile(toks[i + 1].v)) return true;
  }
  let cur: Tok[] = [];
  const cmds: Tok[][] = [];
  for (const t of toks) {
    if (t.op && (t.v === '|' || t.v === '||' || t.v === '&&' || t.v === ';' || t.v === '&' || t.v === '\n')) { if (cur.length) cmds.push(cur); cur = []; }
    else cur.push(t);
  }
  if (cur.length) cmds.push(cur);
  for (const sc of cmds) {
    const words = sc.filter((t) => !t.op).map((t) => t.v);
    if (!words.length) continue;
    // Skip leading NAME=VALUE env-assignments (e.g. `FOO=bar tee ~/.zshrc`) so
    // a prefixed env var can't hide the real command from the verb checks below.
    let ci = 0;
    while (ci < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[ci])) ci++;
    if (ci >= words.length) continue;
    const cmd = cmdBasename(words[ci]);   // normalize path (issue #115: `/usr/bin/tee ~/.zshrc`)
    const args = words.slice(ci + 1);
    const nonFlag = args.filter((a) => !a.startsWith('-'));
    if (cmd === 'tee') {                                          // tee writes ALL its file args
      if (nonFlag.some(isStartupFile)) return true;
    } else if (cmd === 'sed') {                                   // sed -i edits its file args in place
      if (args.some((a) => /^-i/.test(a) || a.startsWith('--in-place')) && nonFlag.some(isStartupFile)) return true;
    } else if (cmd === 'cp' || cmd === 'mv' || cmd === 'install' || cmd === 'ln') {
      if (nonFlag.length && isStartupFile(nonFlag[nonFlag.length - 1])) return true;  // destination only
    } else if (cmd === 'dd') {                                    // dd of=<startup file> writes it
      if (args.some((a) => a.startsWith('of=') && isStartupFile(a.slice(3)))) return true;
    }
  }
  return false;
}

// Informational egress NOTICES — surfaced (allow + warn), never a deny. These are
// command-SHAPE heuristics local to this guard (distinct from the shared credential
// SHAPES in secret-patterns.json, which feed the deny tiers). Each rule pairs a matcher
// with the notice text; related vectors are grouped into one rule (the netcat family, the
// inline interpreters) rather than one row per binary. Because these only warn, imprecise
// matching is never a security hole — the blocking decisions are made above.
const EGRESS_NOTICES: { match: RegExp; note: string }[] = [
  { match: /\bcurl\b.*?(?:-d\b|--data(?:-[a-z]+)?\b|-X[ \t]*POST\b)/i, note: 'curl HTTP upload (POST / --data)' },
  { match: /\bwget\b.*?--post-(?:data|file)\b/i,                       note: 'wget HTTP upload (--post-*)' },
  { match: /\b(?:nc|ncat)\b[ \t]/i,                                       note: 'netcat / ncat connection' },
  { match: /\bsocat\b[ \t]/i,                                             note: 'socat relay' },
  { match: /\bsendmail\b/i,                                               note: 'sendmail invocation' },
  { match: /^[ \t]*(?:env|printenv)[ \t]*$/i,                             note: 'bare environment dump' },
  { match: /^[ \t]*set[ \t]*$/i,                                          note: 'bare shell-variable dump' },
  { match: /\bpython3?[ \t]+-c\b/i,                                       note: 'inline python execution (-c)' },
  { match: /\b(?:node|ruby|perl)[ \t]+-e\b/i,                             note: 'inline interpreter execution (-e)' },
];

function loadPatterns(): { outbound: RegExp; creds: [RegExp, string][] } | null {
  try {
    const p: Patterns = JSON.parse(readFileSync(new URL('./lib/secret-patterns.json', import.meta.url), 'utf-8'));
    if (!p.outboundInvocation || !Array.isArray(p.credentialPatterns) || p.credentialPatterns.length === 0) return null;
    return {
      outbound: new RegExp(p.outboundInvocation, 'i'),
      creds: p.credentialPatterns.map((c) => [new RegExp(c.pattern), c.label] as [RegExp, string]),
    };
  } catch {
    return null;
  }
}

// Org-marker tier (opt-in). Reads the install-COMPILED sidecar — never sources the
// user's shell config. FAIL-SOFT on every error (missing / unparseable / malformed /
// bad-regex sidecar → org tier inactive), NEVER throws: this is the sole Bash guard,
// so a bad parse must not crash pipe-to-shell + trufflehog. `stale` is computed
// independently of whether a pattern is set, so a user who ADDS CT_EGRESS_PATTERNS
// after install (sidecar pattern still empty) still gets the "re-run install" nudge.
interface OrgTier { pattern: RegExp | null; stale: boolean }
function loadOrgTier(): OrgTier {
  try {
    const sc = JSON.parse(readFileSync(new URL('./lib/org-egress.json', import.meta.url), 'utf-8')) as
      { pattern?: string; sourceHash?: string };
    let stale = false;
    if (sc.sourceHash) {
      try {
        // Hash the RAW config FILE BYTES — the same byte domain install.sh hashes
        // (NOT the shell-expanded value), so quoting-identical edits don't false-drift.
        const cfg = readFileSync(new URL('../aka-claude-tools.config', import.meta.url));
        stale = createHash('sha256').update(cfg).digest('hex') !== sc.sourceHash;
      } catch { /* config gone/unreadable → can't compare; treat as not-stale */ }
    }
    let pattern: RegExp | null = null;
    if (sc.pattern) { try { pattern = new RegExp(sc.pattern); } catch { pattern = null; } }
    return { pattern, stale };
  } catch {
    return { pattern: null, stale: false };
  }
}

// trufflehog Tier-1 (local, detection-only). Mirrors leak-guard exactly, including
// the missing-binary degradation: warn to stderr + fall through to the regex tiers.
function trufflehogDetects(command: string): boolean {
  const r = spawnSync('trufflehog', ['stdin', '--json', '--no-update', '--no-verification'],
    { input: command, encoding: 'utf-8' });
  if (r.error) {
    console.error('[aka-claude-tools SECURITY] ⚠️ command-guard: trufflehog not installed — secret detection degraded to regex tiers (org markers + shared key shapes).');
    return false;
  }
  return (r.stdout || '').includes('"DetectorName"');
}

function main(): void {
  let input: HookInput;
  try {
    const raw = readFileSync('/dev/stdin', 'utf-8');
    if (!raw.trim()) process.exit(0);
    input = JSON.parse(raw);
  } catch {
    // Fail open, but loudly — this is the sole Bash guard; surface the miss.
    console.error('[aka-claude-tools SECURITY] ⚠️ command-guard: could not parse hook input — allowed. If this recurs, the hook may be misconfigured.');
    process.exit(0);
  }

  if (input.tool_name !== 'Bash') process.exit(0);

  const command =
    typeof input.tool_input === 'string'
      ? input.tool_input
      : (input.tool_input?.command as string | undefined) ?? '';
  if (!command) process.exit(0);

  // Structural checks run over a quote-aware token stream (operators/words inside
  // quotes are data; inside $(...)/`...` they are live), even in degraded mode. If the
  // tokenizer throws on pathological input (e.g. nesting past the depth cap), fall back
  // to the CONSERVATIVE raw-string regexes — over-block, never silently allow. This is
  // the sole Bash guard, so a parser failure must NEVER fail open.
  let pipeToShell: boolean, startupWrite: boolean;
  try {
    const toks = tokenize(command);
    pipeToShell = detectPipeToShell(toks);
    startupWrite = detectStartupWrite(toks);
  } catch {
    console.error('[aka-claude-tools SECURITY] ⚠️ command-guard: command too complex to parse precisely — falling back to strict structural checks (may over-block).');
    pipeToShell = PIPE_TO_SHELL_RAW.test(command);
    startupWrite = STARTUP_WRITE_RAW.test(command);
  }

  // Pipe-to-shell — structural, patterns-independent.
  if (pipeToShell) {
    console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): piping output into a shell interpreter (curl … | bash). Download, inspect, then run.');
    process.exit(2);
  }

  // Startup-file write — structural persistence-vector check.
  if (startupWrite) {
    console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): writing to a shell startup file (~/.zshrc, ~/.bashrc, …) is a persistence vector. Your dotfiles are Edit/Write-denied; a Bash redirection bypasses that. If intentional, run it in your own shell (e.g. a `! <cmd>` prompt); for a profile alias use `./install.sh --alias`.');
    process.exit(2);
  }

  const patterns = loadPatterns();
  if (!patterns) {
    // FAIL CLOSED on outbound: we can't run the credential scan we exist for.
    if (FALLBACK_OUTBOUND.test(command)) {
      console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): secret-patterns.json is missing or corrupt, so the egress scan can\'t run — blocking this outbound command as a precaution. Restore config/hooks/lib/secret-patterns.json or reinstall.');
      process.exit(2);
    }
    // Non-outbound: nothing to scan for; fall through to structural alerts.
  } else if (patterns.outbound.test(command)) {
    // ── Outbound subset only — mirror leak-guard's old Bash tier order ──
    // Tier 1: high-fidelity secret detection (local-only).
    if (trufflehogDetects(command)) {
      console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): outbound command contains a detected secret (trufflehog). Reference it via an environment variable instead of pasting the literal value.');
      process.exit(2);
    }
    // Tier 2: opt-in org markers (from the install-compiled sidecar).
    const org = loadOrgTier();
    if (org.stale) {
      console.error('[aka-claude-tools SECURITY] ⚠️ command-guard: aka-claude-tools.config changed since install — any CT_EGRESS_PATTERNS edit is NOT active yet. Re-run ./install.sh to recompile the org-marker tier.');
    }
    if (org.pattern && org.pattern.test(command)) {
      console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): outbound command matches an internal identifier from aka-claude-tools.config (hostname, IP, path, or username). Describe it generically instead.');
      process.exit(2);
    }
    // Tier 3: shared credential key shapes (a credential VALUE paired with an outbound tool).
    for (const [pattern, label] of patterns.creds) {
      if (pattern.test(command)) {
        console.error(`[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): credential exfiltration — ${label} sent via an outbound tool.`);
        process.exit(2);
      }
    }
  }

  // Other egress vectors — surface but allow.
  for (const { match, note } of EGRESS_NOTICES) {
    if (match.test(command)) {
      console.error(`[aka-claude-tools SECURITY] ⚠️ egress alert (command-guard): ${note} (allowed).`);
      process.exit(0);
    }
  }

  process.exit(0);
}

// Top-level guard: a deliberate decision exits inside main() (process.exit 0/2);
// only an UNEXPECTED throw reaches here. Degrade the documented way — loud on stderr,
// allow (exit 0) — rather than into bun's undefined non-zero exit, since this is the
// sole Bash guard and a bare crash has no defined open/closed semantics in the harness.
try {
  main();
} catch (e) {
  console.error('[aka-claude-tools SECURITY] ⚠️ command-guard: unexpected error — allowed (surfaced, not silent). ' + String(e));
  process.exit(0);
}
