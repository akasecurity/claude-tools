// Hook protocol + compatibility checks. All subprocess state lives in a temporary
// directory; real RTK checks are optional locally and required by the CI job.
import { strict as assert } from 'node:assert';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
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
  function shell(command: string) {
    return spawnSync('/bin/bash', ['-c', rewrite(command) ?? command], { cwd: sb, env, encoding: 'utf8', timeout: 5000 });
  }
  check('head pipeline still counts exactly two lines', () => {
    const r = shell('head -2 input.txt | wc -l');
    assert.equal(r.status, 0, r.stderr); assert.equal(r.stdout.trim(), '2');
  });
  check('head followed by another command retains both outputs', () => {
    const r = shell('head -2 input.txt && echo done');
    assert.equal(r.status, 0, r.stderr); assert.equal(r.stdout, 'needle\nother\ndone\n');
  });
  check('redirected file reads preserve bytes', () => {
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
