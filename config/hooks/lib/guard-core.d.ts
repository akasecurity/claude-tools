export type Harness = "claude" | "codex" | "antigravity" | "grok";
export type RuleId = "pipe-to-shell" | "startup-write" | "search-exec" | "patterns-unavailable" | "secret-detected" | "org-marker" | "credential-shape" | "mcp-server-denied" | "mcp-server-not-allowed" | "mcp-input-unscannable";
export interface Notice {
	level: "warn" | "alert";
	code: string;
	message: string;
}
export type Decision = {
	kind: "allow";
	notices: Notice[];
} | {
	kind: "block";
	rule: RuleId;
	reason: string;
	detail?: string;
	notices: Notice[];
} | {
	kind: "rewrite";
	input: string;
	notices: Notice[];
};
export type BootstrapRule = {
	host: string;
	pathPrefix: string;
};
export interface StructuralResult {
	pipeToShell: boolean;
	startupWrite: boolean;
	searchExec: boolean;
	degraded: boolean;
}
/**
 * Quote-aware checks; on tokenizer failure, the conservative raw regexes (over-block, never allow).
 * `opts.trustedBootstrap` exempts one exact curl-to-shell install form from pipe-to-shell (see
 * bootstrap.ts). The exemption exists only on the tokenized path; the raw fallback never applies it.
 */
export declare function structuralChecks(command: string, opts?: {
	trustedBootstrap?: BootstrapRule[];
}): StructuralResult;
export interface PatternSet {
	outbound: RegExp;
	creds: [
		RegExp,
		string
	][];
	credAny: RegExp;
}
/** Validate secret-patterns data. Any missing/empty/invalid part → null (callers fail closed). */
export declare function parsePatterns(raw: unknown): PatternSet | null;
export declare const DEFAULT_PATTERNS: PatternSet | null;
export type SecretScanner = (text: string) => "found" | "clean" | "unavailable";
/** Local trufflehog. --no-verification is load-bearing: verifying sends the secret to the provider. */
export declare const trufflehogScanner: SecretScanner;
export interface OrgTier {
	pattern: RegExp | null;
	stale: boolean;
	patternError: boolean;
}
export interface EvalContext {
	patterns?: PatternSet | null;
	scanner?: SecretScanner;
	org?: OrgTier;
	scanSecrets?: boolean;
	trustedBootstrap?: BootstrapRule[];
}
export declare function evaluateBash(command: string, ctx?: EvalContext): Decision;
export declare function evaluateWebQuery(text: string, ctx?: EvalContext): Decision;
export type McpPolicy = {
	allow?: string[];
	deny?: string[];
};
/** `mcp__<server>__<tool>` → `<server>`; server names may contain single underscores. */
export declare function mcpServerOf(tool: string): string | null;
/** Policy first (always applies), then the secret tiers on every string leaf and object key. */
export declare function evaluateMcpInput(tool: string, input: unknown, ctx?: EvalContext & {
	mcp?: McpPolicy;
}): Decision;
export declare function supportedVersion(version: string): boolean;
/** Compute the rewritten command (incl. env prefix), or null if nothing applies. */
export declare function rewrite(command: string): string | null;
/** Inputs to {@link detectAitc}. The filesystem hooks exist for tests; adapters pass `home` and `roots` only. */
export interface AitcDetectOptions {
	/** Absolute home directory. Default roots (`~/.claude`, `~/.codex`) and fixed plugin paths hang off it. */
	home: string;
	/**
	 * Harness config dirs to check, e.g. `CLAUDE_CONFIG_DIR` / `CODEX_HOME`. Each must be an
	 * absolute path: relative and `~`-prefixed entries are ignored, never resolved against the cwd.
	 * Empty strings are ignored, so `[process.env.CLAUDE_CONFIG_DIR ?? '']` is safe.
	 *
	 * When omitted, the harness default roots under `home` (`~/.claude`, `~/.codex`) are checked.
	 * When provided — even as `[]` or an array that filters down to nothing — those roots alone are
	 * checked and the default is NOT added alongside them, so a kit profile installed in a
	 * different config dir never defers just because ai-tc happens to live in the default one.
	 */
	roots?: string[];
	/**
	 * Absolute path to the project/repo Claude Code is running in (its hook input `cwd`), used only
	 * for harness `claude`. Claude Code layers project settings on top of the profile: even when a
	 * plugin key is enabled at the profile root(s), `<projectDir>/.claude/settings.json` or
	 * `<projectDir>/.claude/settings.local.json` can set `"<key>": false` in `enabledPlugins` for
	 * this project, which disables the plugin's hooks here even though it stays enabled elsewhere.
	 * When either file sets a key that `detectAitc` recognises as ai-tc to `false`, that key is
	 * treated as not enabled for this call, regardless of the profile-level `enabledPlugins`.
	 *
	 * This is a disable-only override: a project file setting a key to `true` never enables a
	 * plugin that isn't already enabled at the profile level — project settings can only turn a
	 * profile-enabled plugin off for this project, never turn on a plugin the profile didn't enable.
	 * An unreadable or corrupt project settings file is ignored (treated as absent, not as
	 * disabling anything), since the profile-level decision already stands on its own.
	 * A relative or missing `projectDir` is ignored; only an absolute path is read.
	 */
	projectDir?: string;
	exists?: (p: string) => boolean;
	readdir?: (p: string) => string[];
	/** Returns file contents, or null when unreadable. */
	readFile?: (p: string) => string | null;
}
/** Result of {@link detectAitc}. */
export interface AitcStatus {
	/** ai-tc is installed (and, for Claude, enabled) for this harness in at least one root. */
	present: boolean;
	harness: Harness;
	/** Plugin directories that established presence, de-duplicated. */
	markers: string[];
	/** ai-tc's shared state (`~/.aka/data/aka.db`) exists. Reported only; never counts as present. */
	sharedState: boolean;
}
/**
 * Detect ai-tc for one harness.
 *
 * - claude: a plugin dir under `<root>/plugins/cache/<marketplace>/<name>` where `<name>` is
 *   `ai-tc` (any marketplace) or `aka` (marketplace `akasecurity` or `ai-tc`), AND the key
 *   `<name>@<marketplace>` is listed in `<root>/plugins/installed_plugins.json` and set to `true`
 *   (not merely present, and not absent, `false`, or any other value) in `<root>/settings.json`
 *   `enabledPlugins`. A cache dir alone does not count. When `opts.projectDir` is given, a key
 *   this otherwise finds enabled is then treated as not enabled if either
 *   `<projectDir>/.claude/settings.json` or `<projectDir>/.claude/settings.local.json` sets it to
 *   `false` — see {@link AitcDetectOptions.projectDir}.
 * - codex: `<root>/plugins/cache/<marketplace>/aka-codex` exists.
 * - antigravity: `<home>/.gemini/config/plugins/aka-antigravity` exists.
 * - grok: always absent.
 *
 * Roots: `opts.roots` when provided (even `[]`), otherwise the harness default under `home`.
 * Non-absolute roots are dropped either way.
 */
export declare function detectAitc(harness: Harness, opts: AitcDetectOptions): AitcStatus;
/**
 * Tools ai-tc's PreToolUse hooks cover, per harness (read from ai-tc's own hooks.json matchers).
 * Where ai-tc hooks a tool the kit defers to it: no secret scan and no rewrite on that tool.
 * `mcp__*` tools are always covered (ai-tc's Claude matcher includes `mcp__.*`). An empty list
 * means ai-tc's matcher is unscoped (e.g. antigravity's '.*') and covers every tool.
 */
export declare const AITC_HOOKED_TOOLS: Record<Harness, string[]>;
/**
 * Tools ai-tc's PostToolUse hooks cover, per harness (read from ai-tc's own hooks.json matchers,
 * cited per harness below). Where ai-tc's PostToolUse hooks a tool, the kit's own output
 * redaction defers to it. Unlike {@link AITC_HOOKED_TOOLS}, `mcp__*` is NOT special-cased as
 * covered here: there is no unconditional "MCP is always covered" clause, so whether an MCP
 * tool's output is deferred depends entirely on the harness's own list below, the same as any
 * other tool. An empty list means ai-tc's PostToolUse matcher is unscoped and covers every tool,
 * MCP included (same convention as `AITC_HOOKED_TOOLS`) — so for claude and codex, whose lists
 * are non-empty and contain no `mcp__` entry, the kit keeps redacting MCP output; for antigravity
 * and grok, whose lists are empty, ai-tc's unscoped matcher covers MCP tools too and the kit
 * defers on them like everything else.
 */
export declare const AITC_POST_HOOKED_TOOLS: Record<Harness, string[]>;
/** What the kit does alongside ai-tc. Per-tool answers take the harness tool name. */
export interface CoexistencePolicy {
	/** Run the kit's secret tiers on this tool. False only where ai-tc hooks the tool. */
	scanSecrets: (tool: string) => boolean;
	redact: boolean;
	auditLog: boolean;
	statusline: boolean;
	/** The kit may return an rtk `rewrite` on this tool. False where ai-tc hooks the tool. */
	allowRewrite: (tool: string) => boolean;
	/**
	 * Redact this tool's output before it leaves the kit. True (kit redacts) unless ai-tc is
	 * present and its PostToolUse hook already covers this exact tool — MCP tools are never
	 * treated as covered here, see {@link AITC_POST_HOOKED_TOOLS}.
	 */
	redactOutput: (tool: string) => boolean;
}
/** ai-tc takes precedence: when present the kit keeps posture only on the tools ai-tc hooks. */
export declare function coexistencePolicy(status: AitcStatus): CoexistencePolicy;
export declare const INJECTION_MARKERS: RegExp[];
export declare function scanPrompt(text: string, opts?: {
	injectionOnly?: boolean;
	patterns?: PatternSet | null;
}): Notice[];
export interface RedactTextResult {
	text: string;
	count: number;
	labels: string[];
}
export interface RedactValueResult<T> {
	value: T;
	count: number;
	labels: string[];
	truncatedScan: boolean;
}
/**
 * Replaces every credential-shape match with `[REDACTED:<label>]`. Finds every credential
 * pattern's matches independently over the original text, extends each over its containing
 * identifier-shaped run, and merges overlapping/touching spans (see the span-union comment
 * above) — one replacement per merged span, labeled with whichever constituent match started
 * earliest. `count` is the number of merged spans; `labels` reports every distinct credential
 * label found by any raw match, even ones whose own span got folded into a differently-labeled
 * merge. The replacement marker text (`[REDACTED:<label>]`) contains no characters outside
 * `[`, `]`, `:`, and its own label prose, none of which extend a token run or match any bundled
 * pattern, so re-running `redactText` on already-redacted output is idempotent (see
 * `tests/redact.test.ts`'s idempotence cases). `patterns: null` is an explicit "don't scan" and
 * returns the input unchanged; the default pulls the bundled `DEFAULT_PATTERNS`.
 */
export declare function redactText(text: string, patterns?: PatternSet | null | undefined): RedactTextResult;
/**
 * Walks plain objects and arrays (including object keys), redacting string leaves with
 * `redactText`. Keeps every non-string value and the overall structure, and returns a new
 * container only where something inside it actually changed — an unchanged subtree keeps its
 * original reference.
 *
 * Bounded the same way `evaluateMcpInput`'s walker is bounded, and for the same reason (hostile
 * input can't be allowed to force unbounded work):
 *  - `onPath` catches a genuine cycle (revisiting a current ancestor); like a depth/char blowout,
 *    that aborts the *entire* scan and returns the original top-level input unchanged, with
 *    `truncatedScan: true`.
 *  - `done` caches the already-computed result for a node reached via a second path (a DAG, not
 *    a cycle), so a shared reference is redacted once and the transformed structure is reused —
 *    keeping cost proportional to distinct nodes and avoiding double-counting matches.
 *  - A non-plain object (Buffer, Map, Set, class instance, typed array, …) is different from
 *    `evaluateMcpInput`'s walker on purpose: this is output redaction, not an input gate, so it
 *    is left unchanged in place (not blocked) and only flips `truncatedScan: true` — the scan
 *    keeps going over the rest of the structure.
 *
 * Known limitation (same shape as `evaluateMcpInput`'s): each string leaf is redacted
 * independently via `redactText`, not joined with any other leaf first, so a credential split
 * across two separate fields (half the token in one key's value, the rest in another) is never
 * reassembled and would not be caught.
 *
 * If two different object keys redact to the same label (two distinct secrets of the same
 * credential type as sibling keys), the second key's redacted name is disambiguated with a
 * `#2`, `#3`, … suffix rather than silently overwriting the first key's entry.
 */
export declare function redactValue<T>(value: T, patterns?: PatternSet | null | undefined, limits?: {
	maxChars?: number;
	maxDepth?: number;
}): RedactValueResult<T>;
/** One `output-injection-marker` warn notice if any `INJECTION_MARKERS` regex matches, else none. */
export declare function injectionMarkers(text: string): Notice[];
/**
 * One audit-log line. `tool`, `rule`, `detail` and `snippet` are optional: not every event has a
 * tool name (e.g. a prompt-scan event) or a rule id (e.g. a bare redact/integrity note).
 */
export interface AuditEvent {
	ts: string;
	kit: string;
	harness: Harness;
	hook: string;
	tool?: string;
	kind: "block" | "alert" | "redact" | "integrity" | "prompt";
	rule?: string;
	detail?: string;
	snippet?: string;
}
/**
 * Formats one audit event as a single JSON line (including the trailing `\n`), with a fixed key
 * order (`ts, kit, harness, hook, tool, kind, rule, detail, snippet`). Any key not in that list is
 * dropped — only own, recognized fields of `event` are ever read. `tool`, `rule`, `detail` and
 * `snippet` are dropped when `undefined`; `ts`, `kit`, `harness` and `kind` always appear, since an
 * invalid or missing value in one of those four is replaced rather than omitted (see below).
 *
 * Every field lands in the output through one of two paths:
 *  - **Allow-listed** (`ts`, `kind`, `kit`, `harness`): validated against a fixed shape and, if it
 *    doesn't match, replaced outright with a known-safe default — `kind` falls back to `'alert'`,
 *    `ts` to `new Date().toISOString()`, `kit`/`harness` to `'unknown'`. There is no partial-value
 *    salvage here (unlike the sanitized fields below): an object or array in one of these fields
 *    is simply not a valid value, so none of its content is coerced into the output at all.
 *  - **Sanitized** (`snippet`, `detail`, `rule`, `tool`, `hook`): coerced to a string via
 *    {@link toStringSafe} — even when the input value isn't already a string, so an object, array
 *    or number smuggled into one of these fields (whether via a bug upstream or a hostile caller)
 *    is never serialized verbatim, unredacted and uncapped — then passed through `redactText`
 *    (using `patterns`, defaulting to the bundled `DEFAULT_PATTERNS`; pass `null` to skip scanning)
 *    and capped (`snippet`/`detail` at 200 characters, `rule`/`tool`/`hook` at 100) without ever
 *    splitting a `[REDACTED:...]` marker in half. `rule`/`tool`/`hook` aren't expected to carry
 *    secrets, but scanning and capping them costs little and closes off a class of surprises.
 *
 * Together, every emitted field is either allow-listed to a fixed shape or redacted-and-capped;
 * none is ever passed through unexamined.
 *
 * Never throws: this feeds an audit log that must never be the reason a hook fails, so malformed
 * or unserializable input (a circular reference, a non-stringifiable value smuggled past the
 * type) falls back to a minimal one-line event instead of propagating an exception.
 */
export declare function formatAuditLine(event: AuditEvent, patterns?: PatternSet | null | undefined): string;
export declare const VERSION: string;

export {};
