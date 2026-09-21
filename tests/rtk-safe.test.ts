// tests/rtk-safe.test.ts — in-process unit coverage for config/hooks/rtk-safe.ts.
//
// The flow suite is all-bash and exercises install/registration end-to-end; it can't
// reach the hook's pure rewrite layer. This imports the exported `rewrite()` and asserts
// the rule table: each command class rewrites to the expected rtk form, env prefixes are
// preserved, credential reads and the skip conditions (already-rtk / heredoc / multiline)
// are left alone, and non-matching commands return null (no rewrite).
//
// Run directly: `bun tests/rtk-safe.test.ts` (the test_rtk_safe_unit.sh wrapper does this
// so the test_*.sh glob in run.sh picks it up). Exits non-zero if any assert fails.
import { rewrite } from '../config/hooks/rtk-safe.ts';

let pass = 0, fail = 0;
function eq(input: string, expected: string | null): void {
  const got = rewrite(input);
  if (got === expected) { pass++; console.log(`  \x1b[32m✓\x1b[0m ${JSON.stringify(input)}`); }
  else {
    fail++;
    console.log(`  \x1b[31m✗ ${JSON.stringify(input)}\x1b[0m`);
    console.log(`      └ expected ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`);
  }
}

console.log('rtk-safe.test:');

// ── git: only the common subcommands, global flags tolerated ──────────────────
eq('git status', 'rtk git status');
eq('git -C /tmp/x log --oneline', 'rtk git -C /tmp/x log --oneline');
eq('git --no-pager diff', 'rtk git --no-pager diff');
eq('git push origin main', 'rtk git push origin main');
eq('git frobnicate', null);          // unknown subcommand → no rewrite
eq('git', null);                     // bare → no rewrite
eq('github-cli status', null);       // not the git program
eq('gitk --all', null);              // prefix collision: gitk is not git

// ── gh: paginated surfaces only ───────────────────────────────────────────────
eq('gh pr list', 'rtk gh pr list');
eq('gh api /repos/x', 'rtk gh api /repos/x');
eq('gh repo view', null);            // repo not in the set

// ── cargo: optional +toolchain ────────────────────────────────────────────────
eq('cargo test', 'rtk cargo test');
eq('cargo +nightly build', 'rtk cargo +nightly build');
eq('cargo publish', null);

// ── file reads: cat/head → rtk read; credential paths left alone ──────────────
eq('cat README.md', 'rtk read README.md');
eq('cat', null);                     // bare cat (reads stdin) → no rewrite
eq('catalog list', null);            // prefix collision: not the `cat` program
// credential paths must NEVER be rewritten (would slip past the Read(...) deny) — broad set:
eq('cat ~/.ssh/id_rsa', null);
eq('cat /home/me/.aws/credentials', null);
eq('cat project/.env', null);        // .env
eq('cat ~/.gnupg/secring.gpg', null);
eq('cat ~/.config/gh/hosts.yml', null);
eq('cat .git-credentials', null);
eq('cat ~/.docker/config.json', null);
eq('cat ~/.npmrc', null);
eq('head -20 big.log', 'rtk read big.log --max-lines 20');
eq('head --lines=5 a.txt', 'rtk read a.txt --max-lines 5');
eq('head big.log', null);            // head without -N → no rewrite
eq('head -n 20 big.log', null);      // PARITY: old hook matched only `head -N`, not `-n N`
eq('head -n20 big.log', null);       // PARITY: `-nN` likewise not rewritten (unchanged)
eq('head -5 ~/.netrc', null);        // credential path → not rewritten
eq('head -10 ~/.aws/credentials', null);

// ── listings ──────────────────────────────────────────────────────────────────
eq('ls', 'rtk ls');                  // bare ls is rewritten (matches old behavior)
eq('ls -la /tmp', 'rtk ls -la /tmp');
eq('lshw -short', null);             // prefix collision: lshw is not ls
eq('tree src', 'rtk tree src');
eq('find . -name "*.ts"', 'rtk find . -name "*.ts"');
eq('find', null);                    // find needs args
eq('diff a b', 'rtk diff a b');
eq('diff', null);

// ── JS/TS runners ─────────────────────────────────────────────────────────────
eq('npm test', 'rtk npm test');
eq('npm run build', 'rtk npm run build');
eq('npm run install -- --dry-run', 'rtk npm run install -- --dry-run');
eq('npm run', null);                 // no script name
eq('pnpm test', null); // project scripts need not use vitest
eq('vitest', null); // preserve watch mode
eq('vitest run src', 'rtk vitest run src');
eq('npx vitest', null);
eq('pnpm vitest run --coverage', null); // preserve package-manager resolution
eq('tsc', 'rtk tsc');
eq('npx tsc --noEmit', null);
eq('npx vue-tsc', null);
eq('pnpm tsc', null);
eq('eslint .', 'rtk lint .');
eq('npx eslint src', null);
eq('pnpm lint', null);
eq('prettier --check .', 'rtk prettier --check .');
eq('npx prisma generate', null);
eq('pnpm list', 'rtk pnpm list');
eq('pnpm outdated', 'rtk pnpm outdated');
eq('pnpm install', null);            // install not in the query set

// ── containers ────────────────────────────────────────────────────────────────
eq('docker ps', 'rtk docker ps');
eq('docker -H tcp://x logs c1', 'rtk docker -H tcp://x logs c1');
eq('docker network ls', null);       // network not in the docker subset
eq('docker compose ps', 'rtk docker compose ps');
eq('docker compose up', null);       // up not in the compose subset
eq('kubectl get pods', 'rtk kubectl get pods');
eq('kubectl -n kube-system get pods', 'rtk kubectl -n kube-system get pods');
eq('kubectl delete pod x', null);

// ── network (still prompts after rewrite) ─────────────────────────────────────
eq('curl https://example.com', 'rtk curl https://example.com');
eq('curl', null);
eq('wget https://example.com/f', 'rtk wget https://example.com/f');

// ── python / go / misc ────────────────────────────────────────────────────────
eq('pytest -q', 'rtk pytest -q');
eq('pytest', 'rtk pytest');
eq('python -m pytest tests/', null); // keep the selected interpreter
eq('python -m mypy .', null);
eq('mypy src', 'rtk mypy src');
eq('ruff check .', 'rtk ruff check .');
eq('ruff format', 'rtk ruff format');
eq('pip install requests', 'rtk pip install requests');
eq('pip uninstall x', null);
eq('uv pip list', null);
eq('go test ./...', 'rtk go test ./...');
eq('go build', 'rtk go build');
eq('go run main.go', null);          // run not in the set
eq('golangci-lint run', 'rtk golangci-lint run');
eq('aws s3 ls', 'rtk aws s3 ls');
eq('aws', null);
eq('psql -c "select 1"', 'rtk psql -c "select 1"');

// ── env-prefix preserved, attached to the rewrite ─────────────────────────────
eq('FOO=bar git status', 'FOO=bar rtk git status');
eq('NODE_ENV=test A=b npm test', 'NODE_ENV=test A=b rtk npm test');

// ── skip conditions ───────────────────────────────────────────────────────────
eq('rtk git status', null);          // already rtk
eq('/usr/local/bin/rtk ls', null);   // already rtk (path form)
eq('cat <<EOF\nhi\nEOF', null);      // heredoc (also multiline)
eq('git status\ngit log', null);     // multiline
eq('echo hello', null);              // not in any rule
eq('', null);                        // empty

// Shell operators must not move options onto another command or feed compressed
// output to a program. Conservative skips also cover operators inside quotes.
for (const command of [
  'head -5 README.md | wc -l', 'head -5 README.md && echo done',
  'cat README.md > copy.md', 'cat README.md | python parse.py',
  'git status; echo done', 'git status || echo failed', 'git status &',
  'cat $(echo README.md)', 'cat `echo README.md`', 'cat "$FILE"',
  'cat <(echo hello)', 'cat README.md # comment', 'cat a\\ b',
  'cat -s README.md', 'cat -', 'cat --help',
  'FOO="two words" git status',
  'FOO="x cat file"', 'head -5 -v file.txt',
  'PATH=/old/bin:/usr/bin grep -v needle file.txt',
  'FOO=bar PATH=/old/bin rg needle file.txt',
]) eq(command, null);

eq('grep -n needle file.txt', 'rtk grep -n needle file.txt');
eq('grep -v needle file.txt', 'rtk grep -v needle file.txt');
eq('rg -n needle src', 'rtk rg -n needle src');
eq('rg --json needle src', 'rtk rg --json needle src');
eq('grep needle ~/.ssh/id_rsa', null);
eq('rg needle project/.env', null);

console.log(`\nrtk-safe.test: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
