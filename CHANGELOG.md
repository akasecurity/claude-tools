# Changelog

All notable changes to **aka-claude-tools** are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Pre-1.0: minor versions may carry breaking changes; they are called out below.

## [Unreleased]

### Removed
- **`secure-research`** moved to `akasecurity/preflight-skills`, where it runs in every harness that
  preflight supports. It can now spread its researchers across the `claude`, `codex`, `agy` and
  `grok` CLIs and a self-hosted SearXNG. In Claude Code it is `/preflight:secure-research`. The
  installer no longer places `workflows/secure-research.js`. An existing copy in a profile's
  `workflows/` keeps working but gets no updates, so delete it once preflight is installed.
  `secure-deep-research` stays here. **Breaking for scripted installs:** `CT_ADDITIONS` rejects
  unknown ids, so drop `secure-research` from any saved `CT_ADDITIONS` list.

### Added
- Status line **sidecar** (opt-in): set `CLAUDE_TOOLS_STATUS_SIDECAR_DIR` and the status line
  writes `<dir>/<session_id>.json` with the session's context-window usage, model and cwd — the
  fields Claude Code only exposes to the status line — so local tools can read them. Written
  atomically, only on change; unset means no file and no behavior change. `CLAUDE_TOOLS_STATUS_SIDECAR_DIR`
  must be an absolute path (or `~/…`, expanded against `$HOME`) — anything else writes nothing.
- **`post-guard`**: a new PostToolUse guard on `Read`, `WebFetch`, `WebSearch`, and every
  MCP tool's output (`mcp__*`), on by default. Redacts anything shaped like a secret from
  a file read, a fetched page, a search result, or an MCP tool's returned content,
  rewriting the tool's output before the model ever sees it — a PostToolUse hook can't
  block a call that already ran, so this only rewrites or passes through unchanged, never
  denies. Also warns, via Claude Code's `systemMessage` channel, never a block, when
  fetched, searched, or MCP-returned content carries a prompt-injection phrase ("ignore
  previous instructions", …), since that's content the agent didn't author and should
  treat as untrusted data; the same warning is also passed to the model itself as
  additional context. An MCP resource block's own text is scanned and redacted like any
  other text content; only image data and a resource's binary blob field are never
  scanned. Requires `bun`, a hard
  dependency like the other bun-based guards. Defers to ai-tc for `Read` and `WebFetch`
  when ai-tc already covers those tools in the profile; `WebSearch`, `mcp__*`, and the
  injection-marker warning always run regardless.
- **Local security-event audit log**: `command-guard`, `leak-guard`, `mcp-guard`, and
  `prompt-guard` now each write one redacted, capped JSON line per block, alert, or
  prompt-injection notice to `<profile>/logs/security-<YYYY-MM>.jsonl` (one file per UTC
  month, `logs/` at mode `0700`, each file at `0600`). A new read-only
  `./install.sh --audit-log [--month YYYY-MM] [PROFILE_DIR]` mode prints counts by kind
  and rule, then the last 20 events, re-rendered through the same redaction pass on read.
  Writing the log never changes a guard's decision; a write failure is swallowed silently.
  Off entirely when ai-tc is present for the profile — ai-tc keeps its own audit trail.
- **Integrity manifest, a `SessionStart` drift check, and `--audit`**: the installer now
  writes `<profile>/.aka-integrity.json` (a sha256 of every kit-managed hook, library
  file, and launcher shim, plus a hash of the kit-managed slice of `settings.json`) at
  the end of every apply. An internal `SessionStart` hook — not a selectable addition, it
  rides alongside any other bun-based hook — re-checks the profile against that manifest
  on every launch, resume, clear, compact, and fork, and prints one stderr line naming
  how many kit files changed or went missing and whether settings drifted, pointing at
  `aka-claude-tools --audit` for detail. The new read-only `./install.sh --audit
  [PROFILE_DIR]` mode lists exactly what changed, went missing, or turned up unexpected,
  names the specific kit-managed setting that drifted, and warns separately when
  `disableAllHooks` or `permissions.defaultMode: "bypassPermissions"` is set. Detection,
  not a boundary: anything able to rewrite a kit file can rewrite the manifest alongside
  it. Never blocks; fails silent on its own internal error; runs regardless of ai-tc.
- **`mcp-guard`**: a new PreToolUse guard on every MCP tool call (`mcp__*`), on by default.
  Applies an MCP server allow/deny policy first (`CT_MCP_DENY` blocks named servers; a
  non-empty `CT_MCP_ALLOW` blocks every server not on it, both case-insensitive, compiled
  into an install-time `mcp-policy.json` sidecar), then scans the whole tool input, keys
  and values at any depth, for token/SSH-key shapes and configured org markers. Regex tiers
  only (no trufflehog, for per-call latency); input too large or too deeply nested to scan
  is blocked rather than passed. Defers to ai-tc for content detection where ai-tc covers
  MCP tools in the profile, while the server policy still applies.
- **Trusted bootstrap allowlist** for `command-guard`: an opt-in `CT_TRUSTED_BOOTSTRAP_URLS`
  (space-separated `https://host/path/` prefixes) that exempts a narrow `curl <-f/-s/-S
  flags only> <an allowed https URL> | bash`/`| sh` shape from the pipe-to-shell block, for
  legitimate installer scripts. Off by default; anything outside that exact shape (an extra
  flag, an unlisted host or path) still blocks. Compiled into an install-time
  `trusted-bootstrap.json` sidecar; a stale sidecar (config changed since compile) still
  applies with a warning rather than silently disabling.
- **`prompt-guard`**: a new opt-in `UserPromptSubmit` hook that warns, never blocks, on
  content in what you typed: prompt-injection phrasing, a credential value paired with a
  send/post/upload verb, and base64/hex blobs that decode to a shell command. Surfaces via
  Claude Code's `systemMessage` channel; never edits the prompt or adds anything to the
  model's context. Narrows to the injection-marker check alone when ai-tc is installed and
  covers prompt content for the profile.
- **`sandbox`**: a new opt-in addition that sets `sandbox.enabled`, turning on Claude Code's
  native OS-level sandbox (`sandbox-exec` on macOS, `bwrap` plus `socat` on Linux) so Bash and every other
  tool run confined at the OS level, not just the Read tool's own deny rules. Deliberately
  does not also write `sandbox.filesystem.denyRead` — Claude Code's own sandbox already
  merges `secure-settings`'s `Read(...)` credential-deny rules into its effective filesystem
  denylist at runtime with correct glob resolution, so a kit-written copy would be
  re-resolved under the sandbox's own narrower path rules and silently protect nothing. A
  pre-existing `sandbox.enabled` value is stashed and restored if the addition is later
  deselected; deselecting re-disables it (a manual edit back to `false` while selected is
  warned about and reverted on the next apply).
- Vendored **guard-core 0.3.1**, the shared decision-logic library `command-guard`,
  `leak-guard`, `rtk-safe`, and now `mcp-guard` run on.
- `command-guard` blocks ripgrep's arbitrary-execution vectors: `--pre`,
  `--hostname-bin`, and `RIPGREP_CONFIG_PATH` (which points `rg` at a file of flags,
  injecting `--pre` without either flag appearing in the command text). All three are
  confirmed live. The detector resolves the effective command first, so the vectors are
  caught behind `env`/`command`/`nice`/`nohup` wrappers, behind `export`/`declare -x`
  in the same call, behind rtk's own pre-subcommand options (`rtk -v rg …`), and inside
  brace groups. Ordinary searches are unaffected, including `rg -- --pre`, `--preview`
  and `--pretty=`. `--search-zip` is intentionally not blocked — it spawns only rg's
  built-in decompressors, so the caller chooses no binary.
- **PATH-visible launcher shim**: alongside the shell alias, the installer now writes an
  executable shim at `<profile>/bin/<name>` and adds a guarded `PATH` export to the managed
  rc block, so scripts, non-interactive shells, and the ai-tc `aka` CLI's git-style external
  subcommand dispatch can launch the profile.
  `--delete-alias` removes the shim with the block (marker-gated — a user file that merely
  shares the name is never deleted), and `uninstall.sh`'s profile removal covers it for free.
- **PATH-conflict check**: `--alias` refuses (strict) or offers an alternate name
  (interactive) before claiming a launcher name that is already a command on PATH.
  A profile path containing a `:` gets the alias and shim but no `PATH` entry — a
  colon would split it into a relative `PATH` entry — and the installer says so.
- **Deferral to ai-tc** when it is installed and enabled for the profile: the kit skips
  secret scanning on tools ai-tc's own hooks, never rewrites those tools, and does not
  install its status line, so a profile running both never double-scans a secret, never
  rewrites the same tool call twice, and never shows two status lines. Structural blocks
  (pipe-to-shell, startup-file write, ripgrep exec) still apply regardless. A project that sets
  `"ai-tc@akasecurity": false` under `enabledPlugins` in its `.claude/settings.json` or
  `.claude/settings.local.json` turns the deferral off for sessions in that project.

### Changed
- **Upgrade: `mcp-guard` turns on for existing installs.** It is a recommended addition, so an
  interactive installer re-run defaults it to Y and `--defaults` selects it; an explicit
  `CT_ADDITIONS` list installs it only if the list names it. Plugin users get it with the
  plugin update. What changes once it is on:
  - It fails closed: if the guard itself errors (guard-core missing or incompatible,
    unparseable hook input, an unexpected exception), the MCP call is blocked.
  - It blocks MCP tool inputs it cannot fully scan: more than 1,000,000 characters of string
    content (about 1 MB), more than 200,000 values, or nesting deeper than 32 levels.
  - Every MCP tool call starts one `bun` process for the hook.
- **Default launcher name is `claude-aka`** (was `aka`) for `~/.claude-aka` and the fallback
  derivation. Bare `aka` and every `aka-*` name belong to the ai-tc AI Traffic Control CLI.
  ai-tc's `aka claude` still runs `aka-claude`, so it keeps working on a profile migrated from
  `aka-claude` (through the forwarder below); a fresh `claude-aka` install is not reached by
  `aka claude` until ai-tc's dispatcher targets `claude-aka`. Basename-derived names
  (`~/.claude-work` → `work`) are unchanged. A profile whose recorded launcher is `aka-claude` is migrated by `--apply` or
  an installer re-run: it gets a `claude-aka` launcher, and `aka-claude` becomes a forwarder for
  one release that prints `aka-claude is deprecated; use claude-aka` to stderr and runs
  `claude-aka` with the same arguments. A user-owned `aka-claude` (no kit marker) is left alone.
  `--delete-alias claude-aka` and `uninstall.sh` remove the forwarder too; `--delete-alias
  aka-claude` removes only the forwarder.
- The guards (`command-guard`, `leak-guard`, `rtk-safe`) now run on the vendored guard-core
  library, with output unchanged from the previous standalone implementation (pinned by the
  golden output in `tests/golden/guard-output.json`; guard-core's own conformance fixtures run
  as a separate suite).
- The npm package now brings `bun` in as a dependency (pinned to 1.4.2), and the installer uses
  it when no system `bun` is on `PATH` and the bundled one actually runs. Under npm 12's default
  script policy its postinstall is blocked (allow it with `--allow-scripts=bun`) and the
  placeholder left behind is ignored: the installer treats `bun` as missing, so it offers an
  install interactively and aborts under `--apply` rather than registering a hook that can't
  block. If that bundled `bun` is later moved or removed (an `npm
  uninstall -g` or an `npm update -g` that relocates the package), the hooks registered against
  its absolute path stop resolving and exit 127 without blocking; `install.sh` now warns once per
  run when a hook is registered against a bundled `bun` so this doesn't fail silently. The plugin
  (git-subdir source) can't declare npm dependencies, so its launcher stays fail-open and
  unchanged: without `bun` it still fails open with the `INACTIVE` notice.

### Fixed
- `rtk-safe` restores standalone `grep`/`rg` rewriting on stable RTK >= 0.49.0, with
  native flags, exit codes, and regex dialect preserved. Older, missing, prerelease,
  or unresponsive binaries leave commands unchanged. Shell operators, substitutions,
  and command-local `PATH` overrides are skipped so compressed output cannot corrupt
  pipelines or files. Both forms are auto-approved so this adds no prompt friction.
  Long result sets are summarised rather than returned whole: roughly the first 25
  matches, plus an exact count of what was hidden and a `rtk recall` handle for the
  remainder. That is deliberate and is the difference from the `head -N` rule removed
  below — the count is accurate and the rest is retrievable, where `rtk read --max-lines`
  silently rendered about half the requested window.
- A standalone `-h`/`--help` now suppresses the rewrite. `rtk`'s own argument parser
  claims those before they reach the underlying tool, so `grep -h pat a b` (and
  `ls -h`, `wc -h`, `diff -h`, `git -h …`) printed `rtk` usage and exited 0 — a silent
  empty result. Bundled forms (`-lh`, `-rh`, `-nh`) are unaffected.
- `head -N` is no longer rewritten. `rtk read --max-lines N` is not a `head`
  equivalent: it renders about half the requested lines (`head -1` returned none), so
  the model silently received a smaller window than it asked for.
- Preserve `npm run` script semantics and stop substituting tools for project
  scripts, package-manager runners, and explicit Python/uv invocations.
- New auto-approvals `Bash(rtk grep:*)` and `Bash(rtk rg:*)`, so the restored search
  rewriting doesn't cost a prompt on the most frequent command class. `rtk grep` is
  safe standalone (it dispatches to the system `grep`, which cannot exec or write).
  `Bash(rtk rg:*)` is safe **only because command-guard blocks ripgrep's exec flags**,
  so the two are coupled in both directions: a fresh install without `command-guard`
  withholds that one approval, and an upgrade that **deselects** `command-guard` now
  removes an approval already in the profile rather than leaving it live with nothing
  behind it. Either way the `rg` compression is kept — it just prompts — and the
  installer says which happened.
- Retire broad `rtk find` and `rtk git branch` approvals on upgrade: these commands
  can execute/delete files or mutate branches. Retirement now also applies when the
  addition contributing a permission array is **deselected** — previously the profiles
  that turned `rtk-safe` off were the only ones that kept `Bash(rtk find:*)`.
- Added hook-protocol, real-RTK equivalence, and permission-migration regressions;
  CI pins RTK 0.49.0 and verifies its checksum.

## [0.4.1] plugin distribution + a dead permission-rule fix

### Added
- `claude-tools` Claude Code **plugin** form: the guard hooks (command-guard, leak-guard)
  installable via `claude plugin install` into your active profile. Generated from
  `config/additions.json` by `tools/build-plugin.sh`. Guards fail open with a loud SessionStart
  notice when bun is missing. `rtk-safe` (like `secure-settings` and the status line) stays
  installer-only — it needs a `permissions.allow` settings merge a plugin manifest can't apply.
  The isolated-profile installer is unchanged.

### Fixed
- `secure-settings` no longer ships the six `Write(~/.bash_profile)`-style deny rules.
  Claude Code's startup permission-check validation now rejects them: `Edit(path)` rules
  already cover every file-editing tool (including Write), so the separate `Write(...)`
  entries were always redundant and now surface as a startup error for anyone with
  `secure-settings` installed. The `Edit(...)` rules for the same paths are unchanged.

## [0.4.0] telemetry opt-in toggles and a lighter research workflow

Makes Claude Code's nonessential-traffic opt-outs individual toggles so Remote
Control works by default, adds a second research workflow, and refreshes the
visual assets.

### Added
- Individual nonessential-traffic toggles, replacing the bundled telemetry
  opt-out in `secure-settings`. `error-reporting-off`, `feedback-off`, and
  `feedback-survey-off` ship on by default; `telemetry-off` and `autoupdater-off`
  are opt-in. `secure-settings` no longer sets `DISABLE_TELEMETRY`, so Remote
  Control (driving the CLI from a claude.ai session) works out of the box.
- `secure-research` workflow: an everyday privacy-aware multi-source research
  path (parallel researchers into a grounded, cited report), lighter than
  `secure-deep-research`.

### Changed
- Both research workflows tier their models: search and fetch on Haiku, the
  adversarial verify on Sonnet, scope and synthesis inherit the session model.
- Refreshed the what's-inside graphic and deck for the fifteen additions.

## [0.3.0] — guard hardening + agent-driven alias & migration

Closes several command-guard bypasses surfaced in review, adds agent-driven alias
removal and a clean-start migration path, and makes hook registrations host-portable.

### Added
- `install.sh --delete-alias` — the sole sanctioned way for an agent to remove a
  managed launcher-alias block from the shell rc, mirroring `--alias`'s rc-write gate.
  An optional `CT_CONFIG_DIR` refuses a cross-profile clobber, and it fails closed on
  an unparsable managed block (#112, #116).
- agent-install (Path A) offers a **clean-start** path when an existing config is
  notably layered — a minimal, hardened, secure-by-default profile instead of a full
  migration — while still running the shell-startup security pass and auth seeding (#107).

### Security
- command-guard: hardened pipe-to-shell and startup-file-write detection. A named
  script that ignores stdin (`… | bash ./script.sh`) is no longer false-flagged as a
  `curl | bash` pipe-to-shell (#94), while forms that previously slipped through are
  blocked again — inline code (`… | bash -c '<code>'`, including `-ic`/`-lc` and
  `sh`/`zsh -c`), a value-less option mistaken for a script arg (`… | bash -O && ls`),
  env-assignment-prefixed pipes and writes (`IFS=x curl | bash`, `FOO=bar tee ~/.zshrc`),
  and absolute-path startup writes (`/usr/bin/tee ~/.zshrc`) (#110, #111, #104, #114, #115).

### Fixed
- Registered hook/statusLine commands now use a host-portable `$HOME'<dir>'/hooks/…`
  form instead of an absolute `/Users/<user>/…` path when the config dir is under
  `$HOME`. A profile that is backed up / synced across machines no longer breaks when a
  sibling host pulls it; deselect/stash matching recognises both the new portable form
  and the legacy absolute form, so upgrades are seamless, and non-`$HOME` config dirs
  keep the absolute form unchanged (#118).
- rtk-safe strips the `uv pip` subcommand prefix with a regex rather than a fixed-width
  slice, so irregular whitespace (`uv  pip …`, tab-separated) rewrites correctly (#37, #108).

### Documentation
- Optimised the repo for agentic discovery — `llms.txt`, an Open Graph card, and
  canonicalisation (#106).
- Clean-slate tagline and brand-asset refresh (#113).
- `settings.base.json`: corrected the stale maintainer note — Bash-redirection writes
  to startup files *are* covered by command-guard (#98, #109).
- `wrap-up` command: only flag genuinely at-risk work as loose ends; durably-captured
  follow-ups go under a separate note (#105).

## [0.2.0] — public-ready prep

First public-ready release: the kit is scrubbed of internal traces, the docs are
rewritten for a public audience, and the legacy upgrade path is dropped.

### Added
- `install.sh --version` (and `-V`) prints the kit version from the new top-level
  `VERSION` file. Runs before any dependency check, so it works on a bare checkout.
- This `CHANGELOG.md`.

### Changed
- Lean README rewrite for public release — benefit-led, grouped by what each piece
  does, with the deeper mechanics linked out rather than inlined (#74).

### Removed
- Legacy pre-marker hook migration. The public kit has no pre-rename installs, so the
  one-time migration shim and its helpers are gone (#73). **Breaking** only for a
  profile first installed before the hook-rename marker existed (not applicable to
  any public install).

### Fixed
- command-guard no longer treats a `case` statement's pattern-list alternations
  (`case "$ext" in py|sh|bash|zsh)`) as a pipe-to-shell — a false positive — while
  still blocking real pipes to a shell near or inside a `case` (#75, #77).

### Security / hygiene
- Test fixtures genericized: removed a real fleet host and a `myframework/` path from the
  fixtures (#76), and scrubbed the last environment hints — the planted-leak fixture
  now uses a synthetic RFC1918 address and the auth-inherit fixture a neutral terminal
  name (#78). The only remaining external-project reference is the README acknowledgment.
- `setup_alias` (the sole shell-rc writer) now rejects an alias name or config dir that
  can't be safely embedded in the launcher block instead of writing it verbatim. An
  unsafe name (a shell metacharacter or leading `-`) or dir (a quote, `$`, backtick,
  backslash, or control character) could otherwise break out of the
  `alias NAME='CLAUDE_CONFIG_DIR="DIR" claude'` quoting and inject code — at rc-source
  time or, because the `"DIR"` is reparsed inside live double quotes when the alias is
  invoked, at alias-expansion time (`$()` / backtick / `${}`). It now fails closed with
  a clear message at every write path. The accepted alias-name charset also excludes `.`
  so an accepted name carries no regex metacharacter for the collision/enumerate greps (#90).

## [0.1.1] — pre-public-prep checkpoint

Hot-path hooks ported from bash to TypeScript (bun), behavior-preserving. Marks the
state before the v0.2.0 public-ready prep.

### Changed
- `rtk-safe.sh` → `rtk-safe.ts` (#70) — ~2.8× faster, byte-identical rewrites.
- command-guard egress-alert table restructured (#71) — deny semantics unchanged.
- `leak-guard.sh` → `leak-guard.ts` (#72) — verified against the prior bash version
  with 196-case differential parity.

### Removed
- The bun-less soft-skip hedge in leak-guard. **Breaking:** leak-guard now requires
  bun (already a hard dependency of command-guard).

## [0.1.0] — initial internal deployment

Initial internal deployment of the isolated-profile installer, the secure-defaults
base, and the guard hooks.

[Unreleased]: https://github.com/akasecurity/claude-tools/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/akasecurity/claude-tools/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/akasecurity/claude-tools/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/akasecurity/claude-tools/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/akasecurity/claude-tools/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/akasecurity/claude-tools/releases/tag/v0.1.0
