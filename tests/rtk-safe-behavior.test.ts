// Hook protocol + compatibility checks. All subprocess state lives in a temporary
// directory; real RTK checks are optional locally and required by the CI job.
import { strict as assert } from 'node:assert';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { rewrite, supportedVersion } from '../config/hooks/rtk-safe.ts';

const hook = resolve(import.meta.dir, '../config/hooks/rtk-safe.ts');
const realRtk = Bun.which('rtk');
const sb = mkdtempSync(join(tmpdir(), 'aka-rtk-behavior-'));
const env = { ...process.env, HOME: sb, TMPDIR: sb, XDG_CONFIG_HOME: sb,
  XDG_DATA_HOME: sb, XDG_CACHE_HOME: sb, CLAUDE_CONFIG_DIR: join(sb, 'profile') };
let checked = 0;
function check(name: string, fn: () => void) {
  fn(); checked++; console.log(`  ✓ ${name}`);
}
try {
  const bin = join(sb, 'bin');
  mkdirSync(bin);
  // Version probing is the only mocked boundary. No command execution is faked.
  writeFileSync(join(bin, 'rtk'), '#!/bin/sh\n[ "$1" = --version ] || exit 99\nprintf "%s\\n" "$RTK_TEST_VERSION"\nexit "${RTK_TEST_STATUS:-0}"\n', { mode: 0o755 });
  const input = { tool_name: 'Bash', tool_input: { command: 'grep -n needle input.txt', timeout: 3210, description: 'search' } };
  function invoke(version: string, value: unknown = input, status = '0', path = bin) {
    const r = spawnSync(process.execPath, [hook], { cwd: sb, encoding: 'utf8',
      env: { ...env, PATH: path, RTK_TEST_VERSION: version, RTK_TEST_STATUS: status },
      input: JSON.stringify(value), timeout: 5000 });
    assert.equal(r.status, 0, r.stderr);
    return r.stdout;
  }
  check('supported hook rewrites without granting permission or dropping fields', () => {
    assert.deepEqual(JSON.parse(invoke('rtk 0.49.0')), {
      hookSpecificOutput: { hookEventName: 'PreToolUse', updatedInput: {
        ...input.tool_input, command: 'rtk grep -n needle input.txt',
      } },
    });
  });
  for (const version of ['rtk 0.42.4', 'rtk 0.48.9', 'rtk 0.49.0-rc.1', 'garbage', '']) {
    check(`unsupported version leaves the command alone: ${version}`, () => assert.equal(invoke(version), ''));
  }
  check('failed version probe leaves the command alone', () => assert.equal(invoke('rtk 0.49.0', input, '1'), ''));
  check('missing RTK leaves the command alone', () => assert.equal(invoke('', input, '0', join(sb, 'absent')), ''));
  check('non-Bash tools are ignored', () => assert.equal(invoke('rtk 0.49.0', { ...input, tool_name: 'Read' }), ''));
  check('newer stable RTK passes numeric version comparison', () => {
    assert.equal(supportedVersion('rtk 0.100.0'), true);
    assert.equal(supportedVersion('rtk 1.0.0'), true);
  });

  writeFileSync(join(sb, 'input.txt'), 'needle\nother\nneedle two\n');
  writeFileSync(join(sb, 'b.txt'), 'needle elsewhere\n'); // second operand for `grep -h`
  // Long enough that `rtk read --max-lines N` truncates for every N under test — the
  // head counterfactual is only meaningful when truncation is actually in play.
  writeFileSync(join(sb, 'big.txt'), Array.from({ length: 60 }, (_, i) => `line ${i + 1}`).join('\n') + '\n');
  function shell(command: string) {
    return spawnSync('/bin/bash', ['-c', rewrite(command) ?? command], { cwd: sb, env, encoding: 'utf8', timeout: 5000 });
  }
  // NOTE: each of these carries a shell operator, so `rewrite()` returns null and the
  // ORIGINAL command runs. That is the point — they are skip-guard regressions: if the
  // operator guard ever regressed, the rewritten form would change the observed result.
  // They are not evidence that any rewrite is correct; the real-RTK block below is.
  check('skip guard: a piped head is left unrewritten, so wc sees two lines', () => {
    assert.equal(rewrite('head -2 input.txt | wc -l'), null);
    const r = shell('head -2 input.txt | wc -l');
    assert.equal(r.status, 0, r.stderr); assert.equal(r.stdout.trim(), '2');
  });
  check('skip guard: a chained head is left unrewritten, so both outputs survive', () => {
    assert.equal(rewrite('head -2 input.txt && echo done'), null);
    const r = shell('head -2 input.txt && echo done');
    assert.equal(r.status, 0, r.stderr); assert.equal(r.stdout, 'needle\nother\ndone\n');
  });
  check('skip guard: a redirected read is left unrewritten, so bytes are preserved', () => {
    assert.equal(rewrite('cat input.txt > copy.txt'), null);
    assert.equal(shell('cat input.txt > copy.txt').status, 0);
    assert.equal(readFileSync(join(sb, 'copy.txt'), 'utf8'), 'needle\nother\nneedle two\n');
  });

  // These literal dangerous commands must not match a shipped prefix approval.
  // This tests our policy, not Claude Code's permission matcher implementation.
  const allow: string[] = JSON.parse(readFileSync(resolve(import.meta.dir, '../config/rtk-allowlist.json'), 'utf8')).permissions.allow;
  for (const command of ['rtk find . -delete', 'rtk find . -exec sh payload.sh ;', 'rtk git branch -D topic', 'rtk git branch -m renamed']) {
    check(`no kit prefix approval for ${command}`, () => {
      assert.equal(allow.some(rule => {
        const prefix = rule.match(/^Bash\((.*):\*\)$/)?.[1];
        return prefix && (command === prefix || command.startsWith(prefix + ' '));
      }), false);
    });
  }

  if (!realRtk) {
    assert.notEqual(process.env.CT_REQUIRE_RTK, '1', 'CI requires a real RTK binary');
    console.log('  SKIP real RTK compatibility (rtk not installed)');
  } else {
    const version = spawnSync(realRtk, ['--version'], { env, encoding: 'utf8' });
    assert.equal(version.status, 0);
    assert.equal(supportedVersion(version.stdout), true, 'compatibility checks require RTK >= 0.49.0 stable');
    for (const [command, stdout, status] of [
      ['grep -n needle input.txt', '1:needle\n3:needle two\n', 0],
      ['grep -v needle input.txt', 'other\n', 0],
      ['grep -c needle input.txt', '2\n', 0],
      ['grep -q needle input.txt', '', 0],
      ['grep missing input.txt', '', 1],
      ["grep 'needle+' input.txt", '', 1], // BRE: + is literal
      ['rg -n needle input.txt', '1:needle\n3:needle two\n', 0],
      ['rg -v needle input.txt', 'other\n', 0],
      ['rg missing input.txt', '', 1],
      ["rg 'needle+' input.txt", 'needle\nneedle two\n', 0], // regex quantifier
    ] as const) {
      check(`real RTK preserves search contract: ${command}`, () => {
        const r = shell(command); assert.equal(r.status, status, r.stderr); assert.equal(r.stdout, stdout);
      });
    }
    check('real RTK preserves search errors', () => {
      const r = shell('grep needle nonexistent-file');
      assert.equal(r.status, 2); assert.notEqual(r.stderr, '');
    });

    // Coverage for the NON-search rules — its absence is what let two real divergences
    // ship: `head -N` -> `rtk read --max-lines N` (renders ~N/2 lines) and a standalone
    // `-h` eaten by rtk's own parser.
    const raw = (command: string) =>
      spawnSync('/bin/bash', ['-c', command], { cwd: sb, env, encoding: 'utf8', timeout: 5000 });
    const outcome = (r: ReturnType<typeof raw>) => `${r.status}\u0000${r.stdout}`;

    // A rule we DO apply: running the rewritten form must match the native tool.
    const rewriteMatchesNative = (command: string) => {
      const rewritten = rewrite(command);
      assert.notEqual(rewritten, null, `expected a rewrite for: ${command}`);
      assert.equal(outcome(raw(rewritten!)), outcome(raw(command)), `drift: ${command} -> ${rewritten}`);
    };
    // A rule we deliberately DON'T apply. Asserting only "it isn't rewritten" would be
    // tautological, so also pin the counterfactual: the form we refuse to emit really
    // does diverge from the native tool. If rtk ever fixes it, this fails and tells us
    // to reconsider the skip — rather than leaving the skip in place forever unexamined.
    const skippedForGoodReason = (command: string, wouldHaveBeen: string) => {
      assert.equal(rewrite(command), null, `expected no rewrite for: ${command}`);
      assert.notEqual(outcome(raw(wouldHaveBeen)), outcome(raw(command)),
        `'${wouldHaveBeen}' no longer diverges from '${command}' — re-evaluate the skip`);
    };

    check('real RTK: cat of a whole file is byte-identical', () => rewriteMatchesNative('cat input.txt'));

    // Result elision on the search rules, pinned at a size that actually triggers it.
    // The 3-line fixture above structurally cannot: rtk shows the first ~25 matches and
    // summarises the rest, so every equivalence assertion on a small file is vacuous.
    //
    // This is the line between the search rules (kept) and `head -N` (removed), and it is
    // NOT "elision is fine". rtk grep/rg elide with an ACCURATE count and a recall handle
    // — shown + hidden equals the native match total exactly, and the remainder is
    // retrievable. `rtk read --max-lines N` instead silently reinterprets N (asked 10,
    // renders 5), so the caller cannot tell it got a smaller window than it requested.
    // If rtk ever makes a search count inaccurate, that distinction collapses and the
    // grep/rg rules have to be re-argued — this test is what would catch it.
    check('real RTK: search elision is accurate and recoverable, not silent', () => {
      const nativeTotal = Number(raw('grep -c line big.txt').stdout.trim());
      assert.ok(nativeTotal > 40, `fixture must exceed rtk's display cap, got ${nativeTotal}`);
      const rewritten = rewrite('grep -n line big.txt');
      assert.notEqual(rewritten, null);
      const out = raw(rewritten!).stdout;

      const shown = (out.match(/^\d+:line /gm) ?? []).length;
      const hidden = Number(out.match(/\+(\d+) hidden/)?.[1] ?? NaN);
      assert.ok(shown > 0 && shown < nativeTotal, `expected partial display, got ${shown}/${nativeTotal}`);
      assert.ok(Number.isFinite(hidden), 'elided output must state how many matches are hidden');
      assert.equal(shown + hidden, nativeTotal,
        `elision count must be exact: ${shown} shown + ${hidden} hidden != ${nativeTotal} native`);
      assert.match(out, /rtk recall [0-9a-f]+/, 'elided matches must be recoverable');
    });
    for (const n of [1, 2, 20]) {
      check(`head -${n} skipped, and rtk read --max-lines ${n} really does diverge`, () =>
        skippedForGoodReason(`head -${n} big.txt`, `rtk read big.txt --max-lines ${n}`));
    }
    for (const [command, wouldHaveBeen] of [
      ['grep -h needle input.txt b.txt', 'rtk grep -h needle input.txt b.txt'],
      ['ls -h', 'rtk ls -h'],
    ] as const) {
      check(`standalone -h skipped, and rtk would have eaten it: ${command}`, () =>
        skippedForGoodReason(command, wouldHaveBeen));
    }
    // The exec-primitive criterion that decides which search verbs may be approved, and
    // therefore which ones rtk-safe rewrites at all. Both halves are asserted against the
    // real binary, because the whole policy rests on them staying true.
    const preScript = (marker: string) => {
      writeFileSync(join(sb, 'pre.sh'), `#!/bin/sh\ntouch ${marker}\ncat "$1"\n`, { mode: 0o755 });
    };
    check('rtk grep has no exec primitive (why Bash(rtk grep:*) is approved)', () => {
      const marker = join(sb, 'grep-pre-ran');
      preScript(marker);
      const r = raw('rtk grep --pre ./pre.sh needle input.txt');
      assert.notEqual(r.status, 0, 'expected grep to reject --pre, not run it');
      assert.equal(existsSync(marker), false, 'rtk grep executed a preprocessor binary');
    });
    // rg is auto-approved, and ripgrep DOES have an exec primitive — so the approval is
    // only safe while command-guard refuses the exec flags. Assert the pair together:
    // the vector is real, and the guard blocks it. If rtk/ripgrep ever stops exec'ing
    // --pre the first assert fails and the coupling can be revisited deliberately.
    check('rtk rg execs --pre, and command-guard blocks it (the pairing)', () => {
      const marker = join(sb, 'rg-pre-ran');
      preScript(marker);
      raw('rtk rg --pre ./pre.sh needle input.txt');
      assert.equal(existsSync(marker), true,
        'rtk rg no longer executes --pre — re-evaluate the command-guard coupling');

      const guard = resolve(import.meta.dir, '../config/hooks/command-guard.ts');
      const ask = (command: string) => spawnSync(process.execPath, [guard], {
        cwd: sb, env, encoding: 'utf8', timeout: 5000,
        input: JSON.stringify({ tool_name: 'Bash', tool_input: { command } }),
      }).status;
      for (const blocked of [
        'rtk rg --pre ./pre.sh needle .',
        'rtk rg --pre=./pre.sh needle .',
        'rtk rg --hostname-bin ./pre.sh needle .',
        'RIPGREP_CONFIG_PATH=./rc rtk rg needle .',
      ]) assert.equal(ask(blocked), 2, `command-guard must block: ${blocked}`);
      // …without blocking the searches the approval exists to make frictionless.
      for (const allowed of ['rtk rg -n needle .', 'rtk rg -n -- --pre .', 'rtk grep -n needle input.txt']) {
        assert.equal(ask(allowed), 0, `command-guard must allow: ${allowed}`);
      }
    });
    check('npm lifecycle-named scripts remain scripts, not package operations', () => {
      // Capture npm argv without allowing any real package operation/network.
      const capture = join(sb, 'npm-argv');
      writeFileSync(join(bin, 'npm'), '#!/bin/sh\nprintf "%s\\n" "$@" > "$RTK_ARGV"\n', { mode: 0o755 });
      const command = rewrite('npm run install -- --dry-run');
      assert.notEqual(command, null);
      const args = command!.split(' ').slice(1);
      const r = spawnSync(realRtk, args, { cwd: sb, encoding: 'utf8', timeout: 5000,
        env: { ...env, PATH: `${bin}:${process.env.PATH}`, RTK_ARGV: capture } });
      assert.equal(r.status, 0, r.stderr);
      assert.equal(readFileSync(capture, 'utf8'), 'run\ninstall\n--\n--dry-run\n');
    });
  }
  console.log(`rtk-safe-behavior: ${checked} passed`);
} finally {
  rmSync(sb, { recursive: true, force: true });
}
