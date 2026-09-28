// tests/statusline.test.ts — in-process unit coverage for config/hooks/statusline.ts.
//
// The flow suite is all-bash and can only diff the rendered statusline END-TO-END; it
// can't reach the port's pure layer. This closes that gap: it imports the exported pure
// functions and asserts (1) golden render() output for every width band, and (2) the
// display-width helpers on exactly the cases the old bash version got WRONG (CJK width 2,
// combining marks width 0, flag width 2, column-not-byte truncation) plus parseEpoch /
// deriveModel / widthMode / meter / levelColor.
//
// Run directly: `bun tests/statusline.test.ts` (the test_statusline_unit.sh wrapper does
// this so the test_*.sh glob in run.sh picks it up). Exits non-zero if any assert fails.
import {
  render, stringWidth, truncateToWidth, parseEpoch, deriveModel, widthMode, meter, levelColor,
  sidecarPayload, sidecarPath, writeSidecar,
} from '../config/hooks/statusline.ts';
import { mkdtempSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

let pass = 0, fail = 0;
function ok(desc: string, cond: boolean, detail = ''): void {
  if (cond) { pass++; console.log(`  \x1b[32m✓\x1b[0m ${desc}`); }
  else { fail++; console.log(`  \x1b[31m✗ ${desc}\x1b[0m`); if (detail) console.log(`      └ ${detail}`); }
}
function eq(desc: string, actual: unknown, expected: unknown): void {
  ok(desc, actual === expected, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

console.log('statusline.test:');

// ── render() golden output, one fixture per width band ───────────────────────
const baseGit = { isRepo: true, repo: 'myrepo', branch: 'feat/x', dirty: 2, ahead: 1, behind: 0, stash: 1, worktree: 'wtA' };
const noUsage = { has: false, five: 0, week: 0, fiveReset: '', weekReset: '', extraEnabled: false, extraUsed: 0, extraLimit: 0 };
const noAmb = { time: '', weather: '', locText: '', flag: '🌐', sessionUpper: '' };

const nano: any = { mode: 'nano', termWidth: 30, hostShort: 'dev', modelShort: 'Fable 5', effort: '', dirName: 'proj',
  ctxPct: 42, git: baseGit, pr: { number: '', state: '' }, usage: noUsage, lines: { added: 0, removed: 0 }, ambient: noAmb };
const micro: any = { ...nano, mode: 'micro', termWidth: 45, effort: 'high' };
const mini: any = { ...nano, mode: 'mini', termWidth: 70, effort: 'high' };
const normal: any = { mode: 'normal', termWidth: 120, hostShort: 'dev', modelShort: 'Fable 5', effort: 'high', dirName: 'proj',
  ctxPct: 42, git: baseGit, pr: { number: '7', state: 'approved' },
  usage: { has: true, five: 55, week: 88, fiveReset: 'MON 1:00PM', weekReset: 'WED 8:00AM', extraEnabled: true, extraUsed: 3, extraLimit: 50 },
  lines: { added: 12, removed: 3 }, ambient: { time: '1:30 PM', weather: '☀️ 70°F', locText: 'NY', flag: '🇺🇸', sessionUpper: 'MY SESSION' } };

eq('render nano (golden)', render(nano),
  "\x1b[1m\x1b[38;2;0;224;184mAKA\x1b[0m \x1b[38;2;0;224;184m42%\x1b[0m\n\x1b[38;2;106;217;255mfeat/x\x1b[0m\n");
eq('render micro (golden)', render(micro),
  "\x1b[1m\x1b[38;2;0;224;184mAKA\x1b[0m \x1b[38;2;107;125;143m▸\x1b[0m \x1b[38;2;0;224;184m42%\x1b[0m \x1b[38;2;107;125;143m│\x1b[0m \x1b[38;2;138;152;255mFable 5\x1b[0m\n\x1b[38;2;106;217;255mfeat/x\x1b[0m \x1b[38;2;221;107;32m*2\x1b[0m\n");
eq('render mini (golden)', render(mini),
  "\x1b[38;2;61;78;94m╭\x1b[0m \x1b[1m\x1b[38;2;0;224;184mAKA\x1b[0m\x1b[38;2;107;125;143m/\x1b[0m\x1b[38;2;154;170;187mdev\x1b[0m \x1b[38;2;107;125;143m▸\x1b[0m \x1b[38;2;195;208;222mmyrepo\x1b[0m\x1b[38;2;107;125;143m/\x1b[0m\x1b[38;2;106;217;255mfeat/x\x1b[0m \x1b[38;2;221;107;32m*2\x1b[0m \x1b[38;2;107;125;143m↑1 ↓0\x1b[0m \x1b[38;2;107;125;143mstash:1\x1b[0m \x1b[38;2;107;125;143mwt:wtA\x1b[0m \x1b[38;2;107;125;143m│\x1b[0m \x1b[38;2;138;152;255mFable 5\x1b[0m \x1b[38;2;107;125;143mhigh\x1b[0m\n\x1b[38;2;61;78;94m╰\x1b[0m \x1b[38;2;107;125;143mCTX\x1b[0m \x1b[38;2;0;224;184m▰\x1b[0m\x1b[38;2;0;224;184m▰\x1b[0m\x1b[38;2;0;224;184m▰\x1b[0m\x1b[38;2;0;224;184m▰\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m \x1b[38;2;0;224;184m42%\x1b[0m\n");
eq('render normal (golden)', render(normal),
  "\x1b[38;2;61;78;94m╭\x1b[0m \x1b[1m\x1b[38;2;0;224;184mAKA\x1b[0m\x1b[38;2;107;125;143m/\x1b[0m\x1b[38;2;154;170;187mdev\x1b[0m \x1b[38;2;107;125;143m▸\x1b[0m \x1b[38;2;195;208;222mmyrepo\x1b[0m\x1b[38;2;107;125;143m/\x1b[0m\x1b[38;2;106;217;255mfeat/x\x1b[0m \x1b[38;2;221;107;32m*2\x1b[0m \x1b[38;2;107;125;143m↑1 ↓0\x1b[0m \x1b[38;2;107;125;143mstash:1\x1b[0m \x1b[38;2;107;125;143mwt:wtA\x1b[0m \x1b[38;2;107;125;143m│\x1b[0m \x1b[38;2;195;208;222mPR#7\x1b[0m \x1b[38;2;0;224;184m✓\x1b[0m \x1b[38;2;107;125;143m│\x1b[0m \x1b[38;2;138;152;255mFable 5\x1b[0m \x1b[38;2;107;125;143mhigh\x1b[0m\n\x1b[38;2;61;78;94m│\x1b[0m \x1b[38;2;107;125;143mCTX\x1b[0m \x1b[38;2;0;224;184m▰\x1b[0m\x1b[38;2;0;224;184m▰\x1b[0m\x1b[38;2;0;224;184m▰\x1b[0m\x1b[38;2;0;224;184m▰\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m\x1b[38;2;61;78;94m▱\x1b[0m \x1b[38;2;0;224;184m42%\x1b[0m \x1b[38;2;107;125;143m│\x1b[0m \x1b[38;2;107;125;143m5H\x1b[0m \x1b[38;2;0;224;184m55%\x1b[0m \x1b[38;2;61;78;94m↻MON 1:00PM\x1b[0m \x1b[38;2;107;125;143m│\x1b[0m \x1b[38;2;107;125;143mWK\x1b[0m \x1b[38;2;247;111;104m88%\x1b[0m \x1b[38;2;61;78;94m↻WED 8:00AM\x1b[0m \x1b[38;2;107;125;143m│\x1b[0m \x1b[38;2;107;125;143m+$3/$50\x1b[0m \x1b[38;2;107;125;143m│\x1b[0m \x1b[38;2;0;224;184m+12\x1b[0m \x1b[38;2;247;111;104m−3\x1b[0m\n\x1b[38;2;61;78;94m╰\x1b[0m \x1b[38;2;154;170;187m1:30 PM\x1b[0m  \x1b[38;2;154;170;187m☀️ 70°F\x1b[0m  🇺🇸 \x1b[38;2;154;170;187mNY\x1b[0m \x1b[38;2;107;125;143m│\x1b[0m \x1b[38;2;154;170;187mMY SESSION\x1b[0m\n");

// Non-git fallback shows the dir name; a non-repo nano shows no branch line.
ok('non-git nano shows no branch line',
  render({ ...nano, git: { ...baseGit, isRepo: false } }) === "\x1b[1m\x1b[38;2;0;224;184mAKA\x1b[0m \x1b[38;2;0;224;184m42%\x1b[0m\n");
ok('non-git normal shows dir name, not repo/branch',
  render({ ...normal, git: { ...baseGit, isRepo: false } }).includes('\x1b[38;2;154;170;187mproj\x1b[0m'));

// ── stringWidth: the cases the bash byte/char count got wrong ────────────────
eq('stringWidth ASCII', stringWidth('hello'), 5);
eq('stringWidth CJK is 2 per glyph', stringWidth('日本'), 4);
eq('stringWidth combining mark is 0 (é = e + U+0301)', stringWidth('é'), 1);
eq('stringWidth flag emoji is 2', stringWidth('🇺🇸'), 2);
eq('stringWidth strips ANSI', stringWidth('\x1b[38;2;1;2;3mhi\x1b[0m'), 2);
eq('stringWidth VS16 emoji (☀️) is 2', stringWidth('☀️'), 2);

// ── truncateToWidth: cut on display columns, not bytes ───────────────────────
eq('truncateToWidth no-op when it fits', truncateToWidth('hello', 10), 'hello');
eq('truncateToWidth cuts ASCII with ellipsis', truncateToWidth('hello world', 5), 'hell…');
// 5 CJK glyphs = width 10; budget 6 columns → keep 2 glyphs (width 4) + "…" (width 1) = 5 ≤ 6.
eq('truncateToWidth counts CJK columns', truncateToWidth('一二三四五', 6), '一二…');

// ── parseEpoch: Z / offset / fractional parity ───────────────────────────────
eq('parseEpoch Z', parseEpoch('1970-01-01T00:00:10Z'), 10);
eq('parseEpoch +05:30 offset', parseEpoch('1970-01-01T05:30:10+05:30'), 10);
eq('parseEpoch fractional seconds', parseEpoch('1970-01-01T00:00:10.500Z'), 10);
eq('parseEpoch bare digits pass through', parseEpoch('12345'), 12345);
eq('parseEpoch empty → 0', parseEpoch(''), 0);
eq('parseEpoch garbage → 0', parseEpoch('not-a-date'), 0);

// ── deriveModel: id-authoritative, with display-name fallback ─────────────────
eq('deriveModel fable from id', deriveModel('claude-fable-5', 'Opus'), 'Fable 5');
eq('deriveModel opus dotted version', deriveModel('claude-opus-4-8', 'Opus'), 'Opus 4.8');
eq('deriveModel drops date snapshot', deriveModel('claude-sonnet-4-6-20990101', 'x'), 'Sonnet 4.6');
eq('deriveModel haiku', deriveModel('claude-haiku-4-5-20251001', 'x'), 'Haiku 4.5');
eq('deriveModel unknown family → strip "Claude " from display name', deriveModel('claude-mystery', 'Claude Mystery'), 'Mystery');
eq('deriveModel no id → display name fallback', deriveModel('', 'Claude Sonnet 4.6'), 'Sonnet 4.6');

// ── widthMode bands ──────────────────────────────────────────────────────────
eq('widthMode <35 nano', widthMode(34), 'nano');
eq('widthMode 35-54 micro', widthMode(35), 'micro');
eq('widthMode 55-79 mini', widthMode(55), 'mini');
eq('widthMode 80+ normal', widthMode(80), 'normal');

// ── meter / levelColor ───────────────────────────────────────────────────────
const SEV_GOOD = '\x1b[38;2;0;224;184m', SEV_WARN = '\x1b[38;2;221;107;32m', SEV_HIGH = '\x1b[38;2;247;111;104m';
eq('levelColor good (<60)', levelColor(59), SEV_GOOD);
eq('levelColor warn (60-84)', levelColor(60), SEV_WARN);
eq('levelColor high (>=85)', levelColor(85), SEV_HIGH);
// Any nonzero usage shows at least one filled block; 0 shows none.
ok('meter nonzero fills at least one block', (meter(10, 1).match(/▰/g)?.length ?? 0) === 1);
ok('meter zero fills no blocks', (meter(10, 0).match(/▰/g)?.length ?? 0) === 0);
ok('meter full fills all blocks', (meter(10, 100).match(/▰/g)?.length ?? 0) === 10);

// ── status sidecar (opt-in CLAUDE_TOOLS_STATUS_SIDECAR_DIR) ─────────────────
const scIn: any = {
  session_id: 'abc-123', transcript_path: '/t/abc-123.jsonl', cwd: '/w/proj',
  model: { id: 'claude-opus-5-5', display_name: 'Opus 5.5' },
  context_window: { used_percentage: 46, context_window_size: 1000000, total_input_tokens: 461076 },
};
eq('sidecarPayload maps fields', JSON.stringify(sidecarPayload(scIn)), JSON.stringify({
  v: 1, session_id: 'abc-123', transcript_path: '/t/abc-123.jsonl', cwd: '/w/proj', model_id: 'claude-opus-5-5',
  context_window: { used_percentage: 46, context_window_size: 1000000, total_input_tokens: 461076 },
}));
eq('sidecarPayload null without session_id', sidecarPayload({}), null);
eq('sidecarPayload tolerates string model + missing ctx',
  JSON.stringify(sidecarPayload({ session_id: 'x', model: 'm' } as any)?.context_window),
  JSON.stringify({ used_percentage: null, context_window_size: null, total_input_tokens: null }));
eq('sidecarPath rejects traversal', sidecarPath('/d', '../etc/x'), null);
eq('sidecarPath rejects empty dir', sidecarPath('', 'abc'), null);
eq('sidecarPath ok', sidecarPath('/d', 'abc-123'), '/d/abc-123.json');
eq('writeSidecar env unset writes nothing', writeSidecar(scIn, undefined), null);
{
  const d = mkdtempSync(join(tmpdir(), 'sc-'));
  const target = join(d, 'nested');
  const p = writeSidecar(scIn, target, 1000);
  eq('writeSidecar returns path', p, join(target, 'abc-123.json'));
  const j = JSON.parse(readFileSync(p!, 'utf8'));
  eq('writeSidecar stamps updated_at', j.updated_at, 1000);
  eq('writeSidecar same values → no rewrite', writeSidecar(scIn, target, 2000), null);
  eq('updated_at unchanged after no-op', JSON.parse(readFileSync(p!, 'utf8')).updated_at, 1000);
  const moved = { ...scIn, context_window: { ...scIn.context_window, used_percentage: 47 } };
  eq('writeSidecar changed values → rewrite', writeSidecar(moved, target, 3000), p);
  eq('rewrite stamps new updated_at', JSON.parse(readFileSync(p!, 'utf8')).updated_at, 3000);
  ok('no temp files left behind', readdirSync(target).every((f) => !f.includes('.tmp.')));
  eq('writeSidecar bad session id writes nothing', writeSidecar({ ...scIn, session_id: 'a/b' }, target), null);
  const home = process.env.HOME!;
  const tp = writeSidecar(scIn, '~/sc-tilde', 1);
  eq('writeSidecar expands leading ~', tp, join(home, 'sc-tilde', 'abc-123.json'));
  ok('tilde file exists', existsSync(join(home, 'sc-tilde', 'abc-123.json')));
}

console.log(`  \x1b[1m${pass} passed, ${fail} failed\x1b[0m`);
process.exit(fail > 0 ? 1 : 0);
