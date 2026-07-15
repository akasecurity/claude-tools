# Changelog

All notable changes to **aka-claude-tools** are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Pre-1.0: minor versions may carry breaking changes; they are called out below.

## [Unreleased]

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
