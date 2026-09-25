export type Harness = "claude" | "codex" | "antigravity" | "grok";
export type RuleId = "pipe-to-shell" | "startup-write" | "search-exec" | "patterns-unavailable" | "secret-detected" | "org-marker" | "credential-shape";
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
export interface StructuralResult {
	pipeToShell: boolean;
	startupWrite: boolean;
	searchExec: boolean;
	degraded: boolean;
}
/** Quote-aware checks; on tokenizer failure, the conservative raw regexes (over-block, never allow). */
export declare function structuralChecks(command: string): StructuralResult;
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
}
export declare function evaluateBash(command: string, ctx?: EvalContext): Decision;
export declare function evaluateWebQuery(text: string, ctx?: EvalContext): Decision;
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
 *   `<name>@<marketplace>` is listed in `<root>/plugins/installed_plugins.json` and not set to
 *   `false` in `<root>/settings.json` `enabledPlugins`. A cache dir alone does not count.
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
/** What the kit does alongside ai-tc. Per-tool answers take the harness tool name. */
export interface CoexistencePolicy {
	/** Run the kit's secret tiers on this tool. False only where ai-tc hooks the tool. */
	scanSecrets: (tool: string) => boolean;
	redact: boolean;
	auditLog: boolean;
	statusline: boolean;
	/** The kit may return an rtk `rewrite` on this tool. False where ai-tc hooks the tool. */
	allowRewrite: (tool: string) => boolean;
}
/** ai-tc takes precedence: when present the kit keeps posture only on the tools ai-tc hooks. */
export declare function coexistencePolicy(status: AitcStatus): CoexistencePolicy;
export declare const VERSION: string;

export {};
