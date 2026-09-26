# Changelog

All notable changes to **aka-claude-tools** are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Pre-1.0: minor versions may carry breaking changes; they are called out below.

## [Unreleased]

### Added
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
  rc block. Scripts, non-interactive shells, and the ai-tc `aka` CLI's git-style external
  subcommand dispatch (`aka claude` → execs `claude-aka` from PATH) can launch the profile.
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
  (pipe-to-shell, startup-file write, ripgrep exec) still apply regardless.

### Changed
- **Default launcher name is `claude-aka`** (was `aka`) for `~/.claude-aka` and the fallback
  derivation. Bare `aka` and every `aka-*` name belong to the ai-tc AI Traffic Control CLI, so
  `aka claude` dispatches to this launcher. Basename-derived names (`~/.claude-work` → `work`)
  are unchanged. A profile whose recorded launcher is `aka-claude` is migrated by `--apply` or
  an installer re-run: it gets a `claude-aka` launcher, and `aka-claude` becomes a forwarder for
  one release that prints `aka-claude is deprecated; use claude-aka` to stderr and runs
  `claude-aka` with the same arguments. A user-owned `aka-claude` (no kit marker) is left alone.
  `--delete-alias claude-aka` and `uninstall.sh` remove the forwarder too; `--delete-alias
  aka-claude` removes only the forwarder.
- The guards (`command-guard`, `leak-guard`, `rtk-safe`) now run on the vendored guard-core
  library, with output unchanged from the previous standalone implementation (pinned by golden
  tests against `tests/fixtures/guard-core-conformance.json`).
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
