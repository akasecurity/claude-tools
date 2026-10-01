# aka-claude-tools

<p align="center"><img src="media/banner.svg" alt="aka-claude-tools: clean context, locked doors, guarded exits for Claude Code. MIT · needs jq + bun." width="100%"></p>

![version](https://img.shields.io/github/v/tag/akasecurity/claude-tools?label=version&color=blue)
![license](https://img.shields.io/badge/license-MIT-green)

**Make Claude Code safer to use.** Clean context, locked-down credentials, guarded
egress. The security defaults Claude Code doesn't ship with, layered onto a profile
of its own in a few minutes.

New to this? Hand the repo to Claude and it sets you up. Comfortable in a terminal?
Read every hook first. It's all plain shell and TypeScript, MIT, and the guards scan
locally: nothing is uploaded to run them.

> Also known as `aka-claude-tools` (the npm package, Homebrew formula, and CLI name). Repo: `akasecurity/claude-tools`. The guard-hooks plugin installs as `claude-tools@akasecurity`.

From [akasecurity](https://akasecurity.io) · MIT · needs `jq` + `bun`.

---

## What it guards against

A coding agent runs shell commands and reaches the network on your behalf. This kit
adds the guardrails for the obvious foot-guns:

- **Reading your credentials** (SSH keys, cloud tokens, `.env` files, keychains) → denied.
- **`curl … | bash`** and friends (piping a web script straight into your shell) → blocked.
- **Editing your shell startup files** (a common way things quietly persist) → blocked.
- **Secrets leaving in a web request** → matched on your machine and blocked.
- **Secrets already in the model's context** (a file it read, a page it fetched, a search
  result, an MCP response) → redacted before the model sees them; fetched or MCP content
  carrying a prompt-injection phrase like "ignore previous instructions" is flagged too.
- **Context filling with noise** (chatty command output) → summarized before it reaches the model.
- **A kit file quietly edited, or a security setting reverted** → flagged at the next
  session start, with `--audit` to see exactly what changed.

Eighteen small pieces, eleven on by default and seven opt-in. Each stands alone. Take what you want.

**claude-tools is safe defaults for the harness; [ai-tc](https://github.com/akasecurity/ai-tc) is the detection engine.** The secret scan here is a shallow fallback — pattern and key-shape matching on egress. It does not detect PII, PHI, or cardholder data, and it does not redact. When you need deep content detection with an audit trail, add ai-tc; the installer offers it. The two compose: posture from claude-tools, detection from ai-tc.

## Quick start

Two ways in, same result: a hardened profile launched by its own name (default
`claude-aka` — a shell alias plus a PATH shim). Bare `aka` and every `aka-*` name are
left to the [AI Traffic Control](https://github.com/akasecurity) CLI. The previous
default, `aka-claude`, still works for one release: re-running the installer on such a
profile adds `claude-aka` and turns `aka-claude` into a forwarder that prints a
deprecation notice.

**Hand it to Claude.** In a logged-in Claude Code session, say:

> Set up aka-claude-tools from github.com/akasecurity/claude-tools.
> Read its agent-install.md and set up a hardened profile for me.

It reads the guide, checks what you already have, migrates it cleanly, and runs the
installer. Nothing to type.

**Or install via a package manager:**

```bash
# npm / npx (macOS + Linux)
npx @akasecurity/claude-tools

# Homebrew (macOS + Linux)
brew tap akasecurity/tap
brew install akasecurity/tap/aka-claude-tools
aka-claude-tools
```

The npm package brings its own `bun` as a dependency, so command-guard/leak-guard/mcp-guard/statusline/rtk-safe
work even with no system `bun` on PATH. That bundled `bun` needs its postinstall script, which
npm 12 blocks by default (`npm i -g` prints an install-scripts warning); allow it with
`npm i -g --allow-scripts=bun @akasecurity/claude-tools`. When the bundled `bun` can't run, the
installer ignores it and treats `bun` as missing: it offers to install `bun` interactively, and
under `--apply` or a non-interactive run it aborts before registering any hook that needs `bun`.
**If your hooks ended up registered with that bundled bun** (the
installer warns you when this happens), run this kit's uninstall before removing or upgrading the
`@akasecurity/claude-tools` package, or install a system `bun` and re-run the installer first —
otherwise `npm uninstall -g` / `npm update -g` can leave the hooks pointing at a path that no longer
exists.

**Or clone and run:**

```bash
git clone git@github.com:akasecurity/claude-tools.git
cd claude-tools
./install.sh             # interactive
./install.sh --defaults  # accept the recommended ten
```

Nothing runs on clone. Read the code first if you like. The installer asks where to put
the profile, what to name the launcher, and which pieces to enable, and migrates your
current config in (paths rewritten), so the new profile is a working copy of your setup,
not a bare sandbox. Prefer a walkthrough? See the [safe-setup carousel](media/decks/safe-setup.pdf).

### Install as a Claude Code plugin (guards into your active profile)

`claude plugin marketplace add akasecurity/marketplace` then `claude plugin install claude-tools@akasecurity` installs the guard hooks (command-guard, leak-guard, mcp-guard) into your **active** profile.

- **Requires `bun`.** The guards run under bun. They **fail open** — if bun is missing they never
  block your work; instead you get one clear "guards INACTIVE" notice at session start. Install bun
  (https://bun.sh) to activate them.
- **Plugin ≠ the full kit.** A plugin can't ship the credential-read denies, the `rtk-safe` output
  rewriter (it needs a `permissions.allow` settings merge a plugin manifest can't apply), or the
  status line. For the fully hardened, isolated profile, install the full kit — see
  [Quick start](#quick-start) (npm, Homebrew, or `./install.sh`).

## See it actually block something

A guard you haven't watched fire is one you're only assuming works. Launch the profile
(`claude-aka`) and try:

- ask it to read `~/.ssh/id_rsa` → it **refuses**
- check the status bar → context and rate-limit gauges show
- run `curl … | bash` → **blocked**

<p align="center">
  <img src="media/control-ssh-refused.svg" alt="secure-settings refusing to read ~/.ssh/id_rsa" width="100%"><br>
  <img src="media/control-statusline.svg" alt="status line showing live context fill and rate-limit gauges" width="100%"><br>
  <img src="media/control-curl-bash-blocked.svg" alt="command-guard blocking curl piped into bash" width="100%">
</p>

## What's inside

<p align="center"><img src="media/whats-inside.svg" alt="What's inside: additions grouped by what they do (graphic not yet refreshed for this release's count)." width="100%"></p>

Eighteen additions; the menu is driven entirely by
[`config/additions.json`](config/additions.json), the single source both install paths read.
Prefer a visual tour? See the [what's-inside carousel](media/decks/whats-inside.pdf).

| Addition | What it does | Default |
|---|---|---|
| `secure-settings` | Denies reads of SSH keys, cloud creds, `.env`, keychains; blocks writes to shell startup files; no auto-loaded MCP servers. | ● on |
| `sandbox` | Enables Claude Code's native OS-level sandbox, so Bash and every other tool run confined, not just the Read tool. Claude Code's own sandbox already merges `secure-settings`'s Read-deny credential paths into its filesystem restrictions at runtime, so this addition doesn't duplicate that list itself. While selected it owns `sandbox.enabled` (a manual edit back to `false` is warned about and set back to `true` on the next apply — deselect the addition to actually turn the sandbox off). Changes Bash behaviour in every session; needs `bwrap` and `socat` on PATH on Linux (macOS always supported; skipped elsewhere with a notice). | ○ opt-in |
| `leak-guard` | Scans what the agent sends to the web and blocks anything shaped like a secret. Scanned locally, nothing uploaded to check it. | ● on |
| `command-guard` | Blocks `curl…\|bash`, edits to your shell startup files, and credentials being shipped out. An opt-in `CT_TRUSTED_BOOTSTRAP_URLS` allowlist can exempt specific installer-script URLs from the `curl\|bash` block (see [Configuring the opt-in env keys](#configuring-the-opt-in-env-keys) below). | ● on |
| `mcp-guard` | Applies your MCP server allow/deny lists (`CT_MCP_ALLOW` / `CT_MCP_DENY`) and blocks MCP tool inputs carrying anything shaped like a secret. It runs on every MCP call, so it checks key shapes and your org markers only; trufflehog stays on the Bash and web egress guards, for latency. The plugin install scans only; the lists come with the full kit. | ● on |
| `post-guard` | Redacts anything shaped like a secret from what a file read, a web fetch, a web search, or an MCP tool call returns, rewriting the output before the model sees it — a PostToolUse hook, so it rewrites rather than blocks. Also warns, via Claude Code's `systemMessage` channel and to the model itself as additional context (never blocks), when fetched, searched, or MCP-returned content carries a prompt-injection phrase like "ignore previous instructions". An MCP resource block's own text is scanned like any other text; only image data and a resource's binary blob field are never scanned. | ● on |
| `prompt-guard` | Scans what YOU just typed, not a tool call: prompt-injection phrasing, a credential paired with a send/upload instruction, and encoded blobs that decode to a shell command. Warns only — never blocks, never edits your prompt, never adds anything to the model's context. | ○ opt-in |
| `rtk-safe` | Compresses supported standalone commands, including `grep`/`rg` — native flags, exit codes and regex dialect are preserved, but long result sets are **summarised**: you get the first ~25 matches plus an exact count of what was hidden and a `rtk recall` handle to retrieve it. Requires stable [`rtk`](https://github.com/rtk-ai/rtk) ≥ 0.49.0; otherwise leaves commands unchanged. Leaves `head`, `-h`/`--help`, and anything with a shell operator or substitution untouched, and preserves project scripts and interpreter selection. `rg`'s auto-approval requires `command-guard`. | ● on |
| `statusline` | A status bar with live context-fill and rate-limit gauges. | ● on |
| `shell-audit` | On-demand, read-only scan of your shell startup for hardcoded creds, risky hooks, and stale aliases. | ● on |
| `wrap-up` | A `/wrap-up` command that summarizes, verifies, and stages a commit for review. Never commits on its own. | ○ opt-in |
| `secure-deep-research` | Privacy-aware web research with per-claim adversarial verification before a cited synthesis. Sensitive topics are gated and routed through your own search instance. | ○ opt-in |
| `harness-pointer` | A small nudge pointing the agent at the right CLI for your environment. Ships empty. | ○ opt-in |
| `error-reporting-off` | Sets `DISABLE_ERROR_REPORTING` to opt out of Sentry error reporting. | ● on |
| `feedback-off` | Sets `DISABLE_FEEDBACK_COMMAND` to disable the `/feedback` command. | ● on |
| `feedback-survey-off` | Sets `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY` to disable session quality surveys. | ● on |
| `telemetry-off` | Sets `DISABLE_TELEMETRY`. Opt-in because it disables Remote Control (driving the CLI from a claude.ai session). | ○ opt-in |
| `autoupdater-off` | Sets `DISABLE_AUTOUPDATER` to stop background updates; `claude update` still works. | ○ opt-in |

`statusline` also has its own opt-in **sidecar**: set `CLAUDE_TOOLS_STATUS_SIDECAR_DIR` and it
writes `<dir>/<session_id>.json` with the session's context-window usage, model, and cwd — plus Claude Code's rate-limit windows (`rate_limits`: five-hour and seven-day usage and reset time) when it supplies them — fields
Claude Code hands only to the status line — so a local tool can read them without scraping the
rendered bar. Written atomically and only when a value actually changes; leaving the variable
unset means no file and no change in behavior. Example, in `settings.json`:

```json
{ "env": { "CLAUDE_TOOLS_STATUS_SIDECAR_DIR": "~/.cache/claude-status" } }
```

### Configuring the opt-in env keys

Four of the additions above read per-environment policy from
[`shared/aka-claude-tools.config.example`](shared/aka-claude-tools.config.example) (copied to
`aka-claude-tools.config` in your profile on first install): `leak-guard` and `command-guard`
(`CT_EGRESS_PATTERNS`), `harness-pointer` (`CT_BLOCKED_CMDS`), `mcp-guard` (`CT_MCP_ALLOW` /
`CT_MCP_DENY`), and `command-guard`'s bootstrap allowlist (`CT_TRUSTED_BOOTSTRAP_URLS`). Every
key ships empty, so those policy tiers are inactive until you set one. The guards' built-in
checks run regardless: `mcp-guard`'s secret scan of every MCP tool input is always on, as are
the credential scans and structural blocks in `leak-guard` and `command-guard`. Edit the file,
then re-run `./install.sh` to compile it into the sidecars the hooks read at runtime.

- **`CT_MCP_ALLOW` / `CT_MCP_DENY`** (mcp-guard) — comma-separated MCP **server** names (the
  segment after `mcp__` in a tool name, e.g. `mcp__searxng__web_search` → `searxng`), matched
  case-insensitively. `CT_MCP_DENY` always blocks a listed server; a non-empty `CT_MCP_ALLOW`
  also blocks every server not on it.
- **`CT_TRUSTED_BOOTSTRAP_URLS`** (command-guard) — space-separated `https://host/path/` prefixes
  (trailing slash required; the host needs at least two labels, and path segments use only
  `A-Z a-z 0-9 . _ ~ -`, never `.` or `..`). The **only** exempted shape is `curl <-f/-s/-S in
  any combination, or --fail/--silent/--show-error, plus --tlsv1.2 and --proto '=https'> <an
  https URL under one of these prefixes> | bash` (or `| sh`) — one pipe, nothing else on the
  line. `--proto` takes its value as a separate word (`--proto '=https'`); the joined
  `--proto=https` form is not accepted. The URL in the command must have at least one path
  segment under the prefix, so a bare host root such as `https://sh.rustup.rs` is never
  exempted; allowlist installers served from a real path. For example, with
  `CT_TRUSTED_BOOTSTRAP_URLS="https://get.example.dev/install/"`, this exact command is
  allowed:

  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://get.example.dev/install/setup.sh | sh
  ```

  Anything wider, including a plain `-L`/`--location` redirect-follow, still blocks. Residual risks worth
  knowing: curl still reads `~/.curlrc` by default, which can inject flags (including
  `--location`) invisibly to this allowlist; the sidecar's staleness check only detects that
  `aka-claude-tools.config` changed since compile, not that the sidecar's rules still match what
  that config would produce; and a `pathPrefix` of exactly `/` allowlists the **entire host**, not
  just an install-script directory, so scope it as narrowly as the installer's real URL layout
  allows.

Full format details and worked examples for all three keys live as comments directly in
[`shared/aka-claude-tools.config.example`](shared/aka-claude-tools.config.example) — read it before
setting any of them.

## Local security-event audit log

`command-guard`, `leak-guard`, `mcp-guard`, and `prompt-guard` each write one line
per block, alert, or prompt-injection notice to a local, append-only log:
`<profile>/logs/security-<YYYY-MM>.jsonl` (one file per UTC month, created at mode
`0700`, each file at `0600`). Read it with:

```bash
./install.sh --audit-log [--month YYYY-MM] [PROFILE_DIR]
```

which prints a count of any unparseable lines skipped, counts by kind and rule, then
the last 20 events. Profile resolution matches the other read-only modes: the
positional `PROFILE_DIR`, else `CT_CONFIG_DIR`, else the default profile
(`~/.claude`).

**Privacy.** A line never carries a full prompt, command, or tool output, only a
redacted snippet capped at 200 characters, run through the same secret-pattern scan
the guards use on egress. `--audit-log` re-renders every event through that same
redaction pass again on read, so a hand-edited or corrupted line already on disk
can't hand a raw value back to you either. Writing the log never changes a guard's
decision: a write failure (a read-only profile, a symlinked `logs/`) is swallowed
silently, the same as any other logging failure.

**Off with ai-tc.** When [ai-tc](https://github.com/akasecurity/ai-tc) is present
and enabled for the profile, this log turns off entirely. ai-tc keeps its own audit
trail, so claude-tools steps aside instead of double-logging the same decision.

## Integrity check

The installer writes an integrity manifest, `<profile>/.aka-integrity.json`: a
sha256 of every kit-managed hook, library file, and launcher shim, plus a hash of
the kit-managed slice of `settings.json` (its own hook registrations, the deny
rules it shipped, `sandbox.enabled`, and `statusLine` — never your own hooks,
allow/ask rules, or env keys). An internal `SessionStart` hook, not a selectable
addition (it rides alongside any other bun-based hook, the way the plugin's own
preflight check does), re-checks the profile against that manifest on every
launch, resume, clear, compact, and fork. When something has drifted, it prints
one line to stderr:

```
claude-tools: N kit file(s) changed or missing, settings drift; run aka-claude-tools --audit
```

For the detail, run:

```bash
./install.sh --audit [PROFILE_DIR]
```

which lists exactly what changed, went missing, or turned up unexpected under
`hooks/lib/`, names any kit-managed setting that drifted (a missing deny rule, a
hook registration, `statusLine`, or `sandbox.enabled`), and warns separately when
`disableAllHooks` or `permissions.defaultMode: "bypassPermissions"` is set — both
turn the kit's guards off without changing anything the manifest hashes. Exits 0
clean, 1 on drift or a missing manifest.

This is **detection, not a boundary**: anything able to rewrite a kit file can
rewrite the manifest alongside it, so it catches careless edits and accidental
drift, not a determined attacker. Like the audit log, it never blocks — a
`SessionStart` hook can only print, and the check fails silent on its own
internal error — and it runs regardless of ai-tc; only the audit log defers to
ai-tc's own trail.

## Profiles

A profile is its own `CLAUDE_CONFIG_DIR`: its own settings, hooks, and history, launched
by name. Run several side by side: `claude` your everyday basics, `claude-aka` fully
hardened, `work` work-only tools, `play` planning experiments. One Claude Code binary.
The launcher is both a shell alias and an executable PATH shim at
`<profile>/bin/<name>` (the managed rc block adds that bin dir to `PATH`), so scripts
and other shells can exec it too.

- **Pick per profile.** Choose pieces from the menu, or set `CT_ADDITIONS` to the ids you want for a scripted run.
- **Upgrade in place.** As the kit updates, re-run. It finds the kit-managed profiles and **layers the current additions in place**: retired rules reconciled, renamed hooks re-registered, your own settings left intact.
- **Remove cleanly.** Drop one piece by re-running without it (deselecting uninstalls it). Don't like any of it? Delete the profile. Your real setup never changed.
- **Installed via npm and the hooks are wired to its bundled `bun`?** (The installer warns at apply time when this is the case.) Run this kit's uninstall *before* `npm uninstall -g` / `npm update -g` moves or removes that binary — otherwise the hooks point at a missing path, exit silently (127), and stop guarding without telling you.

<p align="center"><img src="media/isolated-profile.svg" alt="A config dir is a whole Claude Code in a folder: try the kit in a fresh ~/.claude-aka or harden your real ~/.claude, and run several profiles side by side, each its own launcher." width="100%"></p>

## What stays on your machine

The guards run **locally**: secrets are matched on your machine, nothing is uploaded to
check them. By default the kit silences the nonessential traffic that doesn't touch Remote
Control: `error-reporting-off`, `feedback-off`, and `feedback-survey-off` are on.
`telemetry-off` and `autoupdater-off` stay opt-in, so **Remote Control and auto-update
keep working**. Flip any of them to taste. (The optional status line fetches weather and
your usage; deselect it to opt out.)

They're **defense-in-depth, not a sandbox**: they raise the cost of a mistake, they don't
make exfiltration impossible. They don't see `ssh` / `git push`, a runtime's own requests,
or a `$VAR`-referenced (non-literal) secret. The real boundary is the credential deny-list,
no auto-loaded MCP servers, and not running with `bypassPermissions`. The guards **fail
closed** if their pattern file is missing or corrupt.

Found a security issue? Please report it privately, see [`SECURITY.md`](SECURITY.md).

## Installing via your agent?

If you're a coding agent reading this to set up a profile, don't improvise. Follow
[`agent-install.md`](agent-install.md). It's the deterministic spec: enumerate existing
profiles with `./install.sh --enumerate`, migrate cleanly, then drive `./install.sh --apply`
and `./install.sh --alias` (install.sh is the only sanctioned shell-rc writer). Use
`--no-auth-inherit` when the profile is for a different account. A machine-readable
map of the repo lives at [`llms.txt`](llms.txt).

## Beyond Claude Code

This is the Claude Code kit. A Codex counterpart is in the works, plus an agent
**harness** that drives a disciplined, probe-gated engineering loop inside a profile.

## Requirements

`jq` and `bun` (the guards and status line run on bun). Optional:
[`trufflehog`](https://github.com/trufflesecurity/trufflehog) for stronger secret detection,
[`rtk`](https://github.com/rtk-ai/rtk) for the rewrite addition. The installer checks each
and offers to install it (with your consent) via your package manager. macOS or Linux.

## Acknowledgments

- [PAI (Personal AI Infrastructure)](https://github.com/danielmiessler/PAI) by Daniel
  Miessler: early inspiration for the egress-guard and command-rewriting concepts.
- [trailofbits/claude-code-config](https://github.com/trailofbits/claude-code-config):
  reference for the secure permission defaults and the maintainer-self-PR workflow.

The implementations here are our own. Built for
[Claude Code](https://docs.claude.com/en/docs/claude-code).

## License

[MIT](LICENSE).
