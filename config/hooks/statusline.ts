#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
// ═══════════════════════════════════════════════════════════════════════════════
// aka-claude-tools status line — design-first, AKA-branded. Width-responsive:
//   nano (<35) · micro (35-54) · mini (55-79) · normal (80+)
// Normal layout (boxed card, 3 lines; dim │ between major segments; segments
// in [brackets] are conditional and only appear when CC provides the data):
//   ╭ AKA/host ▸ repo/branch [*dirty ↑a ↓b stash:n wt:name] [│ PR#n ✓] │ model [effort]
//   │ CTX <gauge> % │ 5H % ↻reset │ WK % ↻reset [│ +credits] [│ +added −removed]
//   ╰ <time>  <weather>  <region> [│ SESSION SUMMARY]
//     (clock + temp localized by geolocation; region is the abbreviated
//     state/region code; session summary is CC's session_name, uppercased +
//     truncated to the terminal width — by DISPLAY columns, not bytes.)
//
// TypeScript port of the original statusline.sh, run under `bun` (the same runtime
// as command-guard.ts). It is a behaviour-preserving port: it reproduces the bash
// version's output for the same input + environment, EXCEPT where the bash version
// was provably wrong about display width (wide-glyph/flag column counting in the
// ambient line — now grapheme/width-aware; see stringWidth/truncateToWidth). The
// pure render layer is pinned by golden tests (tests/statusline.test.ts); the
// original bash is deleted, so there is no byte-for-byte oracle in CI — equivalence
// of the IO layer (clock, usage, weather) was checked by live-probe during review.
//
// There is no shell `eval`/`source` anywhere here, so the shell-injection class the
// bash version defended against (printf %q / @sh quoting of branch/dir/weather into
// sourced fragments) does not exist in this port — typed JSON.parse + argv-array
// subprocesses replace it. This is NOT a security boundary; requiring bun here is
// acceptable (the security guards leak-guard + command-guard also require bun).
//
// Resolves its config dir from $CLAUDE_CONFIG_DIR so it works in any isolated config
// folder created by the aka-claude-tools installer (defaults to ~/.claude).
// ═══════════════════════════════════════════════════════════════════════════════
import { readFileSync, writeFileSync, renameSync, statSync, mkdirSync, mkdtempSync, chmodSync, existsSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';

// ─────────────────────────────────────────────────────────────────────────────
// TYPED CONTRACTS (replace the five `jq … | eval` round-trips of the bash version)
// ─────────────────────────────────────────────────────────────────────────────
interface HookInput {
  workspace?: { current_dir?: string; git_worktree?: string };
  cwd?: string;
  session_id?: string; session_name?: string;
  transcript_path?: string;
  model?: { display_name?: string; id?: string } | string;
  version?: string;
  context_window?: { context_window_size?: number; used_percentage?: number; total_input_tokens?: number };
  rate_limits?: {
    five_hour?: { used_percentage?: number; utilization?: number; resets_at?: string };
    seven_day?: { used_percentage?: number; utilization?: number; resets_at?: string };
    extra_usage?: { is_enabled?: boolean; monthly_limit?: number; used_credits?: number };
  } | null;
  pr?: { number?: number | string; review_state?: string };
  worktree?: { name?: string };
  effort?: { level?: string };
  cost?: { total_lines_added?: number; total_lines_removed?: number };
}

interface Settings {
  preferences?: { temperatureUnit?: string; timezone?: string;
                  location?: { latitude?: number; longitude?: number;
                              countryCode?: string; regionCode?: string; city?: string } };
  principal?: { timezone?: string };
}

type Mode = 'nano' | 'micro' | 'mini' | 'normal';

// Fully-resolved render state — assembled by the IO layer, consumed by pure render().
interface State {
  mode: Mode;
  termWidth: number;
  hostShort: string;
  modelShort: string;
  effort: string;
  dirName: string;
  ctxPct: number;
  git: { isRepo: boolean; repo: string; branch: string; dirty: number;
         ahead: number; behind: number; stash: number; worktree: string };
  pr: { number: string; state: string };
  usage: { has: boolean; five: number; week: number; fiveReset: string; weekReset: string;
           extraEnabled: boolean; extraUsed: number; extraLimit: number };
  lines: { added: number; removed: number };
  ambient: { time: string; weather: string; locText: string; flag: string; sessionUpper: string };
}

// ─────────────────────────────────────────────────────────────────────────────
// PALETTE — AKA-inspired, tuned for dark terminals (identical ANSI to statusline.sh).
// ─────────────────────────────────────────────────────────────────────────────
const RESET = '\x1b[0m', BOLD = '\x1b[1m';
const AKA_GREEN = '\x1b[38;2;0;224;184m';      // #00E0B8 — signature accent / brand mark
const AKA_CYAN = '\x1b[38;2;106;217;255m';     // #6AD9FF — branch, info
const AKA_LAVENDER = '\x1b[38;2;138;152;255m'; // #8A98FF — model
const AKA_TEXT = '\x1b[38;2;195;208;222m';     // #C3D0DE — primary text on dark
const AKA_MUTED = '\x1b[38;2;154;170;187m';    // #9AAABB — ambient values
const AKA_DIM = '\x1b[38;2;107;125;143m';      // #6B7D8F — labels, separators
const AKA_FAINT = '\x1b[38;2;61;78;94m';       // #3D4E5E — empty gauge cells
const SEV_GOOD = '\x1b[38;2;0;224;184m';       // green   — healthy
const SEV_WARN = '\x1b[38;2;221;107;32m';      // #DD6B20 — filling up
const SEV_HIGH = '\x1b[38;2;247;111;104m';     // #F76F68 — danger

const LOCATION_CACHE_TTL = 3600;
const WEATHER_CACHE_TTL = 900;
const USAGE_CACHE_TTL = 900;

// Countries that read time as AM/PM and default to Fahrenheit (the imperial holdouts).
const US_STYLE = new Set(['US', 'LR', 'KY', 'BS', 'BZ', 'PW', 'FM', 'MH', 'GU', 'VI', 'PR', 'AS']);

// ═════════════════════════════════════════════════════════════════════════════
// PURE LAYER (exported, testable) — no IO.
// ═════════════════════════════════════════════════════════════════════════════

// Integer part of a possibly-decimal value, matching bash `${v%%.*}` (truncate, not round).
export function toInt(v: unknown): number {
  const n = Math.trunc(Number(v));
  return Number.isFinite(n) ? n : 0;
}

// Model name: derive from the AUTHORITATIVE model.id (e.g. claude-fable-5 → "Fable 5"),
// not model.display_name. Claude Code's display_name is a generic family label that can
// mislabel a newer tier — a Fable 5 session reports "Opus"/"Opus 4.8" because Fable
// shares Opus's underlying model. model.id carries the true identifier. Fall back to a
// "Claude "-stripped display name when the id is absent or an unrecognized shape.
export function deriveModel(modelId: string, modelName: string): string {
  let short = '';
  if (modelId.startsWith('claude-')) {
    const mid = modelId.slice('claude-'.length);   // fable-5 | opus-4-8 | sonnet-4-6-20990101
    const dash = mid.indexOf('-');
    if (dash !== -1) {                              // a version segment is present
      const fam = mid.slice(0, dash);              // fable | opus | sonnet
      const ver = mid.slice(dash + 1).replace(/-[0-9]{8}$/, '').replace(/-/g, '.'); // drop date snapshot, dot the version
      if (['opus', 'sonnet', 'haiku', 'fable', 'mythos'].includes(fam)) {
        short = `${fam.charAt(0).toUpperCase()}${fam.slice(1)} ${ver}`;
      }
    }
  }
  if (!short) {
    short = modelName.replace(/^[Cc]laude[- ]/, '');
    if (short === '') short = 'Claude';
  }
  return short;
}

export function widthMode(w: number): Mode {
  if (w < 35) return 'nano';
  if (w < 55) return 'micro';
  if (w < 80) return 'mini';
  return 'normal';
}

// ISO timestamp → epoch seconds. Date.parse handles Z / ±HH:MM offsets / fractional
// seconds natively, replacing the bash BSD/GNU `date` fork and the manual regex cleanup.
export function parseEpoch(ts: string): number {
  if (!ts) return 0;
  if (/^[0-9]+$/.test(ts)) return Number(ts);
  const ms = Date.parse(ts);
  return Number.isNaN(ms) ? 0 : Math.floor(ms / 1000);
}

// Severity color by fill level.
export function levelColor(pct: number): string {
  const p = toInt(pct);
  if (p >= 85) return SEV_HIGH;
  if (p >= 60) return SEV_WARN;
  return SEV_GOOD;
}

// Solid block gauge (▰ filled / ▱ empty), fill colored by level.
export function meter(w: number, pct: number): string {
  const p = toInt(pct);
  let filled = Math.trunc((p * w + 50) / 100);
  // Any nonzero usage shows at least one block — an empty gauge next to "12%" reads as broken.
  if (p > 0 && filled < 1) filled = 1;
  if (filled > w) filled = w;
  if (filled < 0) filled = 0;
  const col = levelColor(p);
  let out = '';
  for (let i = 1; i <= w; i++) {
    out += i <= filled ? `${col}▰${RESET}` : `${AKA_FAINT}▱${RESET}`;
  }
  return out;
}

// ── display-width handling (the correctness fix over the bash byte/`xx` math) ──
const ANSI = /\x1b\[[0-9;]*m/g;
function charWidth(cp: number): number {
  if (cp === 0) return 0;
  // zero-width: combining marks, ZWJ, variation selectors
  if ((cp >= 0x300 && cp <= 0x36f) || cp === 0x200d || (cp >= 0xfe00 && cp <= 0xfe0f)) return 0;
  // wide: CJK, Hangul, Misc-Symbols emoji block (weather icons: ☀ ⛅ ☁ ⛈), regional
  // indicators (flags), most pictographic emoji
  if ((cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2600 && cp <= 0x26ff) ||
      (cp >= 0x2e80 && cp <= 0xa4cf) || (cp >= 0xac00 && cp <= 0xd7a3) ||
      (cp >= 0xf900 && cp <= 0xfaff) || (cp >= 0xfe30 && cp <= 0xfe4f) ||
      (cp >= 0xff00 && cp <= 0xff60) || (cp >= 0x1f300 && cp <= 0x1faff) || cp >= 0x1f000) return 2;
  return 1;
}
const SEGMENTER = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
function graphemeWidth(g: string): number {
  // An emoji variation selector (U+FE0F) forces wide presentation (e.g. ☀️ ☁️ 🌫️) —
  // count the cluster as 2 columns regardless of its base char's default width.
  for (const c of g) if (c.codePointAt(0) === 0xfe0f) return 2;
  let w = 0;
  for (const c of g) w = Math.max(w, charWidth(c.codePointAt(0)!));
  return w;
}
export function stringWidth(s: string): number {
  s = s.replace(ANSI, '');
  let w = 0;
  for (const { segment } of SEGMENTER.segment(s)) w += graphemeWidth(segment);
  return w;
}
// Cut S to at most `max` display columns, appending "…" (1 column) when truncated.
export function truncateToWidth(s: string, max: number): string {
  if (stringWidth(s) <= max) return s;
  let out = '', w = 0;
  for (const { segment } of SEGMENTER.segment(s)) {
    const gw = graphemeWidth(segment);
    if (w + gw > max - 1) break;
    out += segment; w += gw;
  }
  return out + '…';
}

// Two-letter country code → regional-indicator flag emoji (a real 2-column glyph),
// else the globe fallback. Mirrors the bash cc_to_flag byte math (requires A-Z).
export function ccToFlag(code: string): string {
  if (code.length !== 2) return '🌐';
  const c1 = code.charCodeAt(0), c2 = code.charCodeAt(1);
  if (c1 < 65 || c1 > 90 || c2 < 65 || c2 > 90) return '🌐';
  return String.fromCodePoint(0x1f1e6 + (c1 - 65)) + String.fromCodePoint(0x1f1e6 + (c2 - 65));
}

// ── render fragments (brand mark, frame edge, separators, segments) ──
function mark(host: string): string {
  let s = `${BOLD}${AKA_GREEN}AKA${RESET}`;
  if (host) s += `${AKA_DIM}/${RESET}${AKA_MUTED}${host}${RESET}`;
  return s + ` ${AKA_DIM}▸${RESET} `;
}
const edge = (c: string): string => `${AKA_FAINT}${c}${RESET} `;
const pipe = (): string => ` ${AKA_DIM}│${RESET} `;

// repo/branch [*dirty] [↑a ↓b] [stash:n] [wt:name], or cwd when not a git repo.
function gitSegment(g: State['git'], dirName: string): string {
  if (!g.isRepo) return `${AKA_MUTED}${dirName}${RESET}`;
  let s = `${AKA_TEXT}${g.repo}${RESET}${AKA_DIM}/${RESET}${AKA_CYAN}${g.branch}${RESET}`;
  if (g.dirty > 0) s += ` ${SEV_WARN}*${g.dirty}${RESET}`;
  if (g.ahead > 0 || g.behind > 0) s += ` ${AKA_DIM}↑${g.ahead} ↓${g.behind}${RESET}`;
  if (g.stash > 0) s += ` ${AKA_DIM}stash:${g.stash}${RESET}`;
  if (g.worktree) s += ` ${AKA_DIM}wt:${g.worktree}${RESET}`;
  return s;
}

// │ PR#<n> <state-glyph> — only while an open PR exists for the branch.
function prSegment(pr: State['pr']): string {
  if (!pr.number) return '';
  let badge = '';
  switch (pr.state) {
    case 'approved':          badge = ` ${SEV_GOOD}✓${RESET}`; break;
    case 'changes_requested': badge = ` ${SEV_HIGH}✗${RESET}`; break;
    case 'pending':           badge = ` ${SEV_WARN}○${RESET}`; break;
    case 'draft':             badge = ` ${AKA_DIM}◌${RESET}`; break;
  }
  return `${pipe()}${AKA_TEXT}PR#${pr.number}${RESET}${badge}`;
}

// The testable core — assembles the exact output bytes for the resolved State.
export function render(state: State): string {
  const eff = state.effort ? ` ${AKA_DIM}${state.effort}${RESET}` : '';
  const ctxColor = levelColor(state.ctxPct);
  const g = state.git;

  if (state.mode === 'nano') {
    let out = `${BOLD}${AKA_GREEN}AKA${RESET} ${ctxColor}${state.ctxPct}%${RESET}\n`;
    if (g.isRepo) out += `${AKA_CYAN}${g.branch}${RESET}\n`;
    return out;
  }

  if (state.mode === 'micro') {
    let out = `${BOLD}${AKA_GREEN}AKA${RESET} ${AKA_DIM}▸${RESET} ${ctxColor}${state.ctxPct}%${RESET}` +
              `${pipe()}${AKA_LAVENDER}${state.modelShort}${RESET}\n`;
    if (g.isRepo) {
      out += `${AKA_CYAN}${g.branch}${RESET}`;
      if (g.dirty > 0) out += ` ${SEV_WARN}*${g.dirty}${RESET}`;
      out += '\n';
    }
    return out;
  }

  if (state.mode === 'mini') {
    const l1 = `${edge('╭')}${mark(state.hostShort)}${gitSegment(g, state.dirName)}` +
               `${pipe()}${AKA_LAVENDER}${state.modelShort}${RESET}${eff}\n`;
    const l2 = `${edge('╰')}${AKA_DIM}CTX${RESET} ${meter(10, state.ctxPct)} ${ctxColor}${state.ctxPct}%${RESET}\n`;
    return l1 + l2;
  }

  // ── NORMAL — boxed card (identity · meters · ambient) ──
  // Line 1 — identity.
  const l1 = `${edge('╭')}${mark(state.hostShort)}${gitSegment(g, state.dirName)}${prSegment(state.pr)}` +
             `${pipe()}${AKA_LAVENDER}${state.modelShort}${RESET}${eff}\n`;

  // Line 2 — meters.
  let l2 = `${edge('│')}${AKA_DIM}CTX${RESET} ${meter(10, state.ctxPct)} ${ctxColor}${state.ctxPct}%${RESET}`;
  const u = state.usage;
  if (u.has) {
    const r5 = u.fiveReset ? ` ${AKA_FAINT}↻${u.fiveReset}${RESET}` : '';
    const r7 = u.weekReset ? ` ${AKA_FAINT}↻${u.weekReset}${RESET}` : '';
    l2 += `${pipe()}${AKA_DIM}5H${RESET} ${levelColor(u.five)}${u.five}%${RESET}${r5}`;
    l2 += `${pipe()}${AKA_DIM}WK${RESET} ${levelColor(u.week)}${u.week}%${RESET}${r7}`;
    if (u.extraEnabled) l2 += `${pipe()}${AKA_DIM}+$${u.extraUsed}/$${u.extraLimit}${RESET}`;
  }
  if (state.lines.added > 0 || state.lines.removed > 0) {
    l2 += `${pipe()}${SEV_GOOD}+${state.lines.added}${RESET} ${SEV_HIGH}−${state.lines.removed}${RESET}`;
  }
  l2 += '\n';

  // Line 3 — ambient (dimmed, localized). Region (abbreviated state) rather than city:
  // IP geolocation is often a metro off within the right region, so the coarser unit is
  // the honest one. Session summary is truncated to the REAL remaining display width.
  const a = state.ambient;
  let amb = '';
  if (a.time) amb = `${AKA_MUTED}${a.time}${RESET}`;
  if (a.weather && a.weather !== '—') { if (amb) amb += '  '; amb += `${AKA_MUTED}${a.weather}${RESET}`; }
  if (a.locText && a.locText !== 'UNKNOWN') { if (amb) amb += '  '; amb += `${a.flag} ${AKA_MUTED}${a.locText}${RESET}`; }
  if (a.sessionUpper) {
    const avail = state.termWidth - 2 - stringWidth(amb) - 3;
    if (avail >= 8) {
      const sess = truncateToWidth(a.sessionUpper, avail);
      if (amb) amb += ` ${AKA_DIM}│${RESET} `;
      amb += `${AKA_MUTED}${sess}${RESET}`;
    }
  }
  const l3 = `${edge('╰')}${amb}\n`;

  return l1 + l2 + l3;
}

// ═════════════════════════════════════════════════════════════════════════════
// IO LAYER — caches, subprocesses, network. Never sources/evals anything.
// ═════════════════════════════════════════════════════════════════════════════

const CFG_DIR = process.env.CLAUDE_CONFIG_DIR || `${process.env.HOME}/.claude`;
const SETTINGS_FILE = `${CFG_DIR}/settings.json`;
const NOW_EPOCH = Math.floor(Date.now() / 1000);

// Secure per-user cache dir. Prefer a per-user base ($XDG_RUNTIME_DIR on systemd Linux,
// $TMPDIR on macOS — both already 0700 and per-user) over bare /tmp; create it 0700, and
// if it isn't owned by us (someone pre-created it) fall back to a private mktemp dir. The
// bash version needed this because it SOURCED cache files; this port never does, but the
// secure derivation is kept verbatim (cheap, and avoids cross-user cache poisoning).
function resolveCacheDir(): string {
  const base = (process.env.XDG_RUNTIME_DIR || process.env.TMPDIR || '/tmp').replace(/\/+$/, '');
  let dir = `${base}/aka-claude-tools-${process.env.USER || 'anon'}`;
  try {
    mkdirSync(dir, { recursive: true });
    if (statSync(dir).uid !== process.geteuid!()) throw new Error('not owned by us');
  } catch {
    try { dir = mkdtempSync(`${tmpdir()}/aka-claude-tools-`); } catch { dir = '/tmp'; }
  }
  try { chmodSync(dir, 0o700); } catch { /* best-effort */ }
  return dir;
}
const CACHE_DIR = resolveCacheDir();
// Per-config cache key so multiple config folders don't collide.
const CFG_KEY = CFG_DIR.replace(/[^A-Za-z0-9]/g, '_');
const LOCATION_CACHE = `${CACHE_DIR}/location-${CFG_KEY}.json`;
const WEATHER_CACHE = `${CACHE_DIR}/weather-${CFG_KEY}.txt`;
const USAGE_CACHE = `${CACHE_DIR}/usage-${CFG_KEY}.json`;

function mtimeMs(path: string): number {
  try { return statSync(path).mtimeMs; } catch { return 0; }
}
function ageSeconds(path: string): number {
  const m = mtimeMs(path);
  return m === 0 ? 999999 : NOW_EPOCH - Math.floor(m / 1000);
}
function readFile(path: string): string {
  try { return readFileSync(path, 'utf-8'); } catch { return ''; }
}
function readJSON<T>(path: string): T | null {
  const raw = readFile(path);
  if (!raw) return null;
  try { return JSON.parse(raw) as T; } catch { return null; }
}
// Atomic write (tmp + rename) so a concurrent refresh never reads a partial file.
function writeAtomic(path: string, content: string): void {
  try {
    const tmp = `${path}.tmp.${process.pid}`;
    writeFileSync(tmp, content);
    renameSync(tmp, path);
  } catch { /* cache writes are best-effort */ }
}

// ─────────────────────────────────────────────────────────────────────────────
// STATUS SIDECAR — opt-in (CLAUDE_TOOLS_STATUS_SIDECAR_DIR). The status line is the only
// surface where Claude Code hands a program the session's context-window usage; this
// persists the fields CC already provides to <dir>/<session_id>.json so other local
// tools can read them. Unset = no file, no behavior change. Best-effort: never throws.
// ─────────────────────────────────────────────────────────────────────────────
export interface SidecarPayload {
  v: 1; session_id: string; transcript_path: string | null; cwd: string | null; model_id: string | null;
  context_window: { used_percentage: number | null; context_window_size: number | null; total_input_tokens: number | null };
}
const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);
export function sidecarPayload(input: HookInput): SidecarPayload | null {
  if (!input.session_id) return null;
  const modelId = typeof input.model === 'object' && input.model ? input.model.id ?? null
                : typeof input.model === 'string' ? input.model : null;
  const cw = input.context_window ?? {};
  return {
    v: 1, session_id: input.session_id, transcript_path: input.transcript_path ?? null,
    cwd: input.workspace?.current_dir || input.cwd || null, model_id: modelId,
    context_window: { used_percentage: num(cw.used_percentage), context_window_size: num(cw.context_window_size),
                      total_input_tokens: num(cw.total_input_tokens) },
  };
}
export function sidecarPath(dir: string, sessionId: string): string | null {
  if (!dir || !/^[A-Za-z0-9-]+$/.test(sessionId)) return null;
  return `${dir.replace(/\/+$/, '')}/${sessionId}.json`;
}
export function writeSidecar(input: HookInput, dirEnv: string | undefined, now = Date.now()): string | null {
  try {
    if (!dirEnv) return null;
    // Collapse any run of slashes (e.g. a HOME env var carrying a trailing slash meeting the
    // leading "/" below) so the resulting path matches what path.join-style callers expect.
    const dir = (dirEnv.startsWith('~/') ? `${process.env.HOME}/${dirEnv.slice(2)}` : dirEnv).replace(/\/{2,}/g, '/');
    // After ~ expansion, only an absolute path is acceptable (e.g. $HOME unset would leave
    // "~/foo" expanding to "/foo" — fine — or "undefined/foo" — not absolute, reject it).
    if (!dir.startsWith('/')) return null;
    const payload = sidecarPayload(input);
    const path = payload && sidecarPath(dir, payload.session_id);
    if (!payload || !path) return null;
    const body = JSON.stringify(payload);
    const prev = readJSON<SidecarPayload & { updated_at?: number }>(path);
    if (prev) { const { updated_at: _u, ...rest } = prev; if (JSON.stringify(rest) === body) return null; }
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeAtomic(path, JSON.stringify({ ...payload, updated_at: now }) + '\n');
    return path;
  } catch { return null; }
}

// Run a subprocess with an argv array (no shell) and return trimmed stdout, or '' on error.
function run(cmd: string, args: string[], cwd?: string): string {
  try {
    return execFileSync(cmd, args, { cwd, encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return ''; }
}

// curl --max-time 3 → fetch with an AbortController timeout. null on any failure.
async function getJSON(url: string, opts: RequestInit = {}, ms = 3000): Promise<any> {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), ms);
  try {
    const r = await fetch(url, { ...opts, signal: ac.signal });
    return r.ok ? await r.json() : null;
  } catch { return null; } finally { clearTimeout(t); }
}

function loadSettings(): Settings {
  return readJSON<Settings>(SETTINGS_FILE) ?? {};
}

// Timezone resolution: explicit pref → principal → default-profile fallback → system zone.
function resolveTimezone(s: Settings): string {
  let tz = s.preferences?.timezone || s.principal?.timezone || 'UTC';
  if (tz === 'UTC' && process.env.HOME) {
    const def = readJSON<Settings>(`${process.env.HOME}/.claude/settings.json`);
    const ftz = def?.principal?.timezone || def?.preferences?.timezone;
    if (ftz) tz = ftz;
  }
  if (tz === 'UTC') {
    // No explicit zone → the machine's local zone (Intl resolved option replaces the
    // bash /etc/localtime readlink), so usage-reset windows match the user's region.
    tz = process.env.TZ || Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';
  }
  return tz;
}

// Wall-clock hour/minute/dayPeriod/weekday for an epoch in a timezone, via Intl (so the
// formatting is built by hand to match `date`'s exact output — leading zeros, "00" at
// midnight, AM/PM casing — rather than relying on locale-specific defaults).
function tzParts(epoch: number, tz: string, hour12: boolean): { h: string; m: string; ap: string; dow: string } {
  // An h12 format yields an automatic AM/PM `dayPeriod` part; do NOT set the dayPeriod
  // OPTION (en-US 'short' would render "in the morning" rather than the AM/PM marker).
  const opts: Intl.DateTimeFormatOptions = {
    hourCycle: hour12 ? 'h12' : 'h23', hour: '2-digit', minute: '2-digit', weekday: 'short',
  };
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = new Intl.DateTimeFormat('en-US', { ...opts, timeZone: tz }).formatToParts(new Date(epoch * 1000));
  } catch {
    parts = new Intl.DateTimeFormat('en-US', opts).formatToParts(new Date(epoch * 1000));
  }
  const get = (t: string) => parts.find((p) => p.type === t)?.value || '';
  return { h: get('hour'), m: get('minute'), ap: get('dayPeriod').toUpperCase(), dow: get('weekday').toUpperCase() };
}

// Ambient clock: AM/PM for US-style locales (per geolocated country), else 24h. Mirrors
// the bash `%I:%M %p` (leading-0 stripped) / `%H:%M` formats exactly.
function formatClock(tz: string, cc: string): string {
  if (US_STYLE.has(cc)) {
    const { h, m, ap } = tzParts(NOW_EPOCH, tz, true);
    return `${String(Number(h))}:${m} ${ap}`;
  }
  const { h, m } = tzParts(NOW_EPOCH, tz, false);
  return `${h}:${m}`;
}

// Reset clock: "DOW time", same locale rule as the ambient clock. US form is `%l:%M%p`
// (no space before AM/PM); 24h form is `%H:%M`. Only called for a future epoch.
function resetLabel(epoch: number, tz: string, cc: string): string {
  if (US_STYLE.has(cc)) {
    const { h, m, ap, dow } = tzParts(epoch, tz, true);
    return `${dow} ${String(Number(h))}:${m}${ap}`;
  }
  const { h, m, dow } = tzParts(epoch, tz, false);
  return `${dow} ${h}:${m}`;
}

// Terminal width: COLUMNS is authoritative inside Claude Code (tput/stty are unreliable
// with no controlling tty). Cache it for runs outside CC; fall back to the cache, then 80.
function detectWidth(): number {
  const widthCache = `${CACHE_DIR}/width-${process.env.KITTY_WINDOW_ID || 'default'}`;
  const cols = Number(process.env.COLUMNS);
  if (Number.isFinite(cols) && cols > 0) {
    writeAtomic(widthCache, `${cols}\n`);
    return cols;
  }
  const cached = Number(readFile(widthCache).trim());
  if (Number.isFinite(cached) && cached > 0) return cached;
  return 80;
}

// ── gather: git ──
function gatherGit(cwd: string): State['git'] {
  const blank = { isRepo: false, repo: '', branch: '', dirty: 0, ahead: 0, behind: 0, stash: 0, worktree: '' };
  // `git rev-parse --git-dir` exits non-zero outside a repo → run() returns ''.
  if (!run('git', ['rev-parse', '--git-dir'], cwd)) return blank;

  const branch = run('git', ['branch', '--show-current'], cwd) || 'detached';
  // Repo name: from the origin remote (the canonical name), else the working-tree folder.
  const remote = run('git', ['config', '--get', 'remote.origin.url'], cwd);
  let repo: string;
  if (remote) {
    repo = remote.replace(/\/+$/, '').split('/').pop()!.replace(/\.git$/, '');
  } else {
    const top = run('git', ['rev-parse', '--show-toplevel'], cwd);
    repo = top ? top.split('/').pop()! : '';
  }
  if (!repo) repo = '?';

  // Count lines like `wc -l` (number of newline-terminated lines; empty → 0).
  const lineCount = (s: string): number => (s === '' ? 0 : s.split('\n').length);
  const stashCount = lineCount(run('git', ['stash', 'list'], cwd));
  const dirty = lineCount(run('git', ['status', '--porcelain'], cwd));
  const sync = run('git', ['rev-list', '--left-right', '--count', 'HEAD...@{u}'], cwd);
  let ahead = 0, behind = 0;
  if (sync) { const [a, b] = sync.split(/\s+/); ahead = toInt(a); behind = toInt(b); }

  return { isRepo: true, repo, branch, dirty, ahead, behind, stash: stashCount, worktree: '' };
}

// ── gather: location (pin or IP) then weather (depends on the resolved location) ──
async function gatherLocation(settings: Settings, tempUnit: string): Promise<{
  city: string; region: string; cc: string; flag: string; tempUnit: string;
}> {
  // Pinned location from settings (opt-in at install): exact, VPN-proof, no IP lookup.
  // Re-applied if the cache was cleared (e.g. after a reboot).
  const pin = settings.preferences?.location;
  if (pin && pin.latitude != null && pin.longitude != null) {
    const cached = readJSON<{ pinned?: boolean }>(LOCATION_CACHE);
    if (!cached || cached.pinned !== true) {
      writeAtomic(LOCATION_CACHE, JSON.stringify({
        latitude: pin.latitude, longitude: pin.longitude,
        country_code: pin.countryCode ?? '', region_code: pin.regionCode ?? '', city: pin.city ?? '',
        success: true, pinned: true,
      }));
    }
  }

  const cur = readJSON<{ pinned?: boolean }>(LOCATION_CACHE);
  const pinned = cur?.pinned === true;
  if (!pinned && ageSeconds(LOCATION_CACHE) > LOCATION_CACHE_TTL) {
    // ipwho.is — HTTPS, free, no API key (avoids ip-api.com's free-tier HTTP IP query).
    const data = await getJSON('https://ipwho.is/');
    if (data && data.success === true) writeAtomic(LOCATION_CACHE, JSON.stringify(data));
  }

  const loc = readJSON<{ city?: string; region_code?: string; country_code?: string }>(LOCATION_CACHE);
  if (!loc) return { city: 'UNKNOWN', region: '', cc: '', flag: '🌐', tempUnit };
  const rawCc = loc.country_code ?? '';
  return {
    city: (loc.city ?? '').toUpperCase(),
    region: (loc.region_code ?? '').toUpperCase(),
    cc: rawCc.toUpperCase(),
    flag: ccToFlag(rawCc),
    tempUnit,
  };
}

// Weather-code → icon (exact glyphs from statusline.sh).
function weatherIcon(code: number, isDay: number): string {
  switch (code) {
    case 0: return isDay === 0 ? '🌙' : '☀️';
    case 1: return isDay === 0 ? '🌙' : '🌤️';
    case 2: return '⛅';
    case 3: return '☁️';
    case 45: case 48: return '🌫️';
    case 51: case 53: case 55: case 56: case 57: return '🌦️';
    case 61: case 63: case 65: case 66: case 67: return '🌧️';
    case 80: case 81: case 82: return '🌧️';
    case 71: case 73: case 75: case 77: case 85: case 86: return '🌨️';
    case 95: case 96: case 99: return '⛈️';
    default: return '🌡️';
  }
}

async function gatherWeather(tempUnit: string): Promise<string> {
  if (ageSeconds(WEATHER_CACHE) > WEATHER_CACHE_TTL) {
    const loc = readJSON<{ latitude?: number; longitude?: number; country_code?: string }>(LOCATION_CACHE);
    const lat = loc?.latitude, lon = loc?.longitude;
    // No fabricated default — only fetch when we actually know where the user is.
    if (lat != null && lon != null) {
      // Derive the unit from the geolocated country when the user hasn't set one.
      let unit = tempUnit;
      if (!unit) unit = US_STYLE.has((loc?.country_code ?? '').toUpperCase()) ? 'fahrenheit' : 'celsius';
      const wx = await getJSON(
        `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}` +
        `&current=temperature_2m,weather_code,is_day&temperature_unit=${unit}`);
      if (wx && wx.current) {
        const c = wx.current;
        const icon = weatherIcon(toInt(c.weather_code), toInt(c.is_day ?? 1));
        const tempInt = Math.round(Number(c.temperature_2m));
        writeAtomic(WEATHER_CACHE, `${icon} ${tempInt}°${unit === 'celsius' ? 'C' : 'F'}\n`);
      }
    }
  }
  const cached = readFile(WEATHER_CACHE).trim();
  return cached || '—';
}

// ── gather: usage (native rate_limits from CC JSON, or the OAuth usage API) ──
interface UsageRaw {
  five: number; week: number; fiveResetRaw: string; weekResetRaw: string;
  extraEnabled: boolean; extraUsed: number; extraLimit: number; noData: boolean; cacheExists: boolean;
}
async function gatherUsage(input: HookInput): Promise<UsageRaw> {
  const rl = input.rate_limits;
  if (rl != null) {
    return {
      five: toInt(rl.five_hour?.used_percentage ?? rl.five_hour?.utilization ?? 0),
      week: toInt(rl.seven_day?.used_percentage ?? rl.seven_day?.utilization ?? 0),
      fiveResetRaw: rl.five_hour?.resets_at ?? '',
      weekResetRaw: rl.seven_day?.resets_at ?? '',
      extraEnabled: rl.extra_usage?.is_enabled ?? false,
      extraUsed: toInt(rl.extra_usage?.used_credits ?? 0),
      extraLimit: toInt(rl.extra_usage?.monthly_limit ?? 0),
      noData: false, cacheExists: existsSync(USAGE_CACHE),
    };
  }

  // OAuth fallback — refresh the cache if stale, then read it.
  if (ageSeconds(USAGE_CACHE) > USAGE_CACHE_TTL) {
    let credJson = '';
    if (process.platform === 'darwin') {
      credJson = run('security', ['find-generic-password', '-s', 'Claude Code-credentials', '-w']);
    } else {
      credJson = readFile(`${CFG_DIR}/.credentials.json`) || readFile(`${process.env.HOME}/.claude/.credentials.json`);
    }
    let token = '';
    try { token = JSON.parse(credJson)?.claudeAiOauth?.accessToken ?? ''; } catch { /* no token */ }
    if (token) {
      const usage = await getJSON('https://api.anthropic.com/api/oauth/usage', {
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'anthropic-beta': 'oauth-2025-04-20' },
      });
      if (usage && usage.five_hour) writeAtomic(USAGE_CACHE, JSON.stringify(usage));
    }
  }

  const cache = readJSON<any>(USAGE_CACHE);
  if (cache && ageSeconds(USAGE_CACHE) < 1800) {
    return {
      five: toInt(cache.five_hour?.utilization ?? 0),
      week: toInt(cache.seven_day?.utilization ?? 0),
      fiveResetRaw: cache.five_hour?.resets_at ?? '',
      weekResetRaw: cache.seven_day?.resets_at ?? '',
      extraEnabled: cache.extra_usage?.is_enabled ?? false,
      extraUsed: toInt(cache.extra_usage?.used_credits ?? 0),
      extraLimit: toInt(cache.extra_usage?.monthly_limit ?? 0),
      noData: false, cacheExists: true,
    };
  }
  try { rmSync(USAGE_CACHE, { force: true }); } catch { /* best-effort */ }
  return { five: 0, week: 0, fiveResetRaw: '', weekResetRaw: '',
           extraEnabled: false, extraUsed: 0, extraLimit: 0, noData: true, cacheExists: false };
}

// ── parse stdin (typed; no eval) ──
export function parseInput(raw: string): HookInput {
  try { return JSON.parse(raw) as HookInput; } catch { return {}; }
}

// ── assemble the full State from input + settings + IO ──
export async function gather(input: HookInput, settings: Settings): Promise<State> {
  const termWidth = detectWidth();
  const mode = widthMode(termWidth);
  const currentDir = input.workspace?.current_dir || input.cwd || '.';
  const dirName = currentDir.replace(/\/+$/, '').split('/').pop() || '.';

  const modelObj = (typeof input.model === 'object' && input.model) ? input.model : null;
  const modelStr = typeof input.model === 'string' ? input.model : null;
  let modelName: string = modelObj?.display_name ?? modelObj?.id ?? modelStr ?? 'unknown';
  if (typeof modelName !== 'string') modelName = 'unknown';
  const modelShort = deriveModel(modelObj?.id ?? '', modelName);

  const tz = resolveTimezone(settings);
  let tempUnit = settings.preferences?.temperatureUnit ?? '';
  if (tempUnit !== 'celsius' && tempUnit !== 'fahrenheit') tempUnit = '';

  // Short hostname for the brand mark (e.g. AKA/dev); the mark falls back to a bare
  // "AKA" when no hostname resolves (run() returns '').
  const hostShort = run('hostname', ['-s']);

  // Run the independent IO groups concurrently. Location must resolve before weather
  // (weather reads the location cache), so they're sequenced inside one group; usage and
  // git are independent. Mode-gating mirrors the bash background blocks exactly:
  //   location/weather only in mini|normal, usage only in normal.
  const wantAmbient = mode === 'mini' || mode === 'normal';
  const wantUsage = mode === 'normal';

  const gitP = Promise.resolve(gatherGit(currentDir));
  const locWxP = (async () => {
    if (!wantAmbient) return { loc: null as Awaited<ReturnType<typeof gatherLocation>> | null, weather: '—' };
    const loc = await gatherLocation(settings, tempUnit);
    const weather = await gatherWeather(loc.tempUnit);
    return { loc, weather };
  })();
  const usageP = wantUsage ? gatherUsage(input)
    : Promise.resolve<UsageRaw>({ five: 0, week: 0, fiveResetRaw: '', weekResetRaw: '',
        extraEnabled: false, extraUsed: 0, extraLimit: 0, noData: true, cacheExists: false });

  const [git, locWx, usageRaw] = await Promise.all([gitP, locWxP, usageP]);

  const cc = locWx.loc?.cc ?? '';
  const time = wantAmbient ? formatClock(tz, cc) : '';
  const locText = (locWx.loc?.region || locWx.loc?.city || locWx.loc?.cc) ?? '';

  // Supplement missing reset timestamps from the usage cache (native rate_limits may omit
  // resets_at), matching the bash post-wait supplement.
  let fiveResetRaw = usageRaw.fiveResetRaw, weekResetRaw = usageRaw.weekResetRaw;
  if (wantUsage && (!fiveResetRaw || !weekResetRaw)) {
    const cache = readJSON<any>(USAGE_CACHE);
    if (cache) {
      if (!fiveResetRaw) fiveResetRaw = cache.five_hour?.resets_at ?? '';
      if (!weekResetRaw) weekResetRaw = cache.seven_day?.resets_at ?? '';
    }
  }
  const e5 = parseEpoch(fiveResetRaw), e7 = parseEpoch(weekResetRaw);
  const usageHas = !usageRaw.noData && (usageRaw.five > 0 || usageRaw.week > 0 || usageRaw.cacheExists);

  const prNumber = input.pr?.number != null ? String(input.pr.number) : '';
  const sessionUpper = (input.session_name || '').toUpperCase();

  return {
    mode, termWidth, hostShort, modelShort,
    effort: input.effort?.level || '',
    dirName,
    ctxPct: toInt(input.context_window?.used_percentage ?? 0),
    git: { ...git, worktree: input.workspace?.git_worktree || input.worktree?.name || '' },
    pr: { number: prNumber, state: input.pr?.review_state || '' },
    usage: {
      has: usageHas, five: usageRaw.five, week: usageRaw.week,
      fiveReset: e5 > NOW_EPOCH ? resetLabel(e5, tz, cc) : '',
      weekReset: e7 > NOW_EPOCH ? resetLabel(e7, tz, cc) : '',
      extraEnabled: usageRaw.extraEnabled,
      extraUsed: Math.trunc(usageRaw.extraUsed / 100),
      extraLimit: Math.trunc(usageRaw.extraLimit / 100),
    },
    lines: { added: toInt(input.cost?.total_lines_added ?? 0), removed: toInt(input.cost?.total_lines_removed ?? 0) },
    ambient: { time, weather: locWx.weather, locText, flag: locWx.loc?.flag ?? '🌐', sessionUpper },
  };
}

async function main(): Promise<string> {
  const input = parseInput(readFile('/dev/stdin'));
  writeSidecar(input, process.env.CLAUDE_TOOLS_STATUS_SIDECAR_DIR);
  const settings = loadSettings();
  const state = await gather(input, settings);
  return render(state);
}

if (import.meta.main) {
  main().then((s) => process.stdout.write(s)).catch(() => process.exit(0));
}
