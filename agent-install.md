# Install an aka-claude-tools profile: driven by your Claude Code instance

**You (Claude) are setting up a new isolated Claude Code config profile for the
user, from inside their already-authenticated session.** You **own the judgment**:
read the whole existing config, reason about dependencies, and migrate cleanly
where a static script would miss rough edges. You **delegate the deterministic
mechanics to `install.sh`**, the repeatable engine: `./install.sh --apply` layers
the additions, `./install.sh --alias` creates the launcher alias. The user is
already authenticated, so there is no token/login dance.

**Do not write the user's shell rc yourself.** Creating the alias means editing
`~/.zshrc` / `~/.bashrc`, which the `command-guard` addition blocks (an agent writing
to startup files is a persistence vector). Always
create the alias by invoking `./install.sh --alias`. install.sh is the sole
sanctioned rc writer. Never use an `echo >> ~/.zshrc` or an Edit of the rc.

Work through the steps below. **Confirm the plan before executing, and verify
after.** Never touch the user's default `~/.claude` config.

---

## 1. Gather preferences: ask the user; use the defaults only as fallback

**First, enumerate what already exists on the host. Don't trust a shallow grep.**
Claude profiles and their launcher aliases are frequently defined in a file the rc
*sources* (e.g. `~/.zshrc` containing `source ~/…/aliases.sh`), so a `grep ~/.zshrc`
alone misses most of them and you'll under-count.

**Run the engine. Don't hand-roll the walk:**

```
./install.sh --enumerate
```

It emits the full picture as JSON: every `~/.claude*/` profile, whether each is
kit-managed, and the launcher aliases that resolve to it through the rc's **entire**
`source`/`.` chain (cycle-safe; `$VAR`/`${VAR}` and `~`/`$HOME` expanded):

```json
{ "rc": "/…/.zshrc",
  "profiles": [ { "dir": "/…/.claude-aka", "managed": true, "aliases": ["aka"] }, … ],
  "unresolved_aliases": [ { "name": "old", "target": "/…/.claude-gone" } ] }
```

`managed` is true when the profile carries `.aka-claude-tools-meta` **or** registers a
kit hook: the same Step-1 signal below. `unresolved_aliases` are launchers whose target
isn't an existing profile (dangling, or a var path that didn't resolve), worth a look.

> **Why the engine, not an inline script:** the resolution helpers in
> `shared/lib/common.sh` are bash-only. Sourced into a tool shell that runs zsh they
> return **empty** and you'll silently under-count and miss an alias collision.
> `install.sh` runs under bash, so `--enumerate` is reliable regardless of your shell.
> (If you must go manual, run it under `bash`: `alias_target_elsewhere <name>
> "$(detect_shell_rc)"` resolves one name; `rc_source_chain "$(detect_shell_rc)"` lists
> every file in the source graph to grep for `alias …CLAUDE_CONFIG_DIR…`.)

Present the user the full profile↔alias map you found, so the next choices are informed.

Always let the user choose the folder and alias. Only apply a default if they
don't specify one:

- **Config folder name**: default `~/.claude-aka`
- **Alias**: default `claude-aka` (if the user picks a custom folder, suggest the
  basename minus `.claude-`, e.g. `~/.claude-work` → `work`). Bare `aka` and every
  `aka-*` name are **reserved** for the ai-tc AI Traffic Control CLI; never suggest
  one. `install.sh --alias` refuses a name that is already a command on PATH. A
  profile still on the previous default `aka-claude` is migrated by `--apply`: it
  gets `claude-aka`, and `aka-claude` forwards to it with a deprecation notice for
  one release.
- **If the folder you'd target already exists as an aka-managed profile, this is an
  UPGRADE, but say so and offer the alternative. Never silently default to
  upgrade-in-place.** A profile is aka-managed if it carries a
  `.aka-claude-tools-meta` file or its `settings.json` registers kit hooks (e.g. a
  `command` ending in `/hooks/command-guard.ts` or `/hooks/leak-guard.ts`). When you
  detect one, tell the user plainly, e.g. "`~/.claude-aka` already exists (an older
  aka-claude-tools version); I can **upgrade it in place**, or set up a **new isolated
  profile** in a different folder with its own alias", and let them pick. Upgrading
  re-runs `--apply` to layer the current additions onto the existing dir (idempotent;
  reconciles retired permissions, re-registers renamed hooks). A new profile is a fresh
  folder + a new alias (suggest a basename-derived alias that isn't already taken; use
  the enumeration above to avoid a collision).
- The user may instead target their **default `~/.claude`** to rebuild it clean:
  move it to a timestamped backup (`~/.claude.backup-…`), recreate it with the
  selected additions, and migrate their picks from the backup. Skip the alias
  (plain `claude` launches it) and the auth/onboarding seed (`~/.claude.json`
  lives at `$HOME` and Keychain auth is keyed to the unchanged dir path; just
  copy a file-based `.credentials.json` back from the backup, plus any
  `aka-claude-tools.config`). Warn first: a running Claude Code session keeps
  working (it's loaded in memory) but may show hook errors while files are
  changed underneath it. That's normal, doesn't affect the install, and the next
  `claude` launch loads the rebuilt config.
- Which **additions** to layer on (read `config/additions.json` in this repo for
  the catalog + recommended defaults): secure base settings, leak-guard,
  command-guard (needs `bun`; also blocks writes to shell startup files),
  mcp-guard (needs `bun`; MCP server allow/deny lists plus a secret scan of MCP inputs),
  rtk-safe (inert until stable `rtk` >= 0.49.0 is installed), responsive status line, shell-audit,
  the recommended nonessential-traffic toggles that don't touch Remote Control
  (error-reporting-off, feedback-off, feedback-survey-off), the opt-out `/wrap-up`
  command, the opt-out secure-research and secure-deep-research workflows, the opt-out
  harness-pointer, the opt-out prompt-guard (needs `bun`; warns, never blocks, on
  prompt-injection phrasing, a credential paired with a send/upload instruction, and
  encoded shell blobs in what the user typed), the two opt-out traffic toggles telemetry-off (off by default
  because it turns off Remote Control) and autoupdater-off, and the opt-in sandbox
  addition (changes Bash behaviour in every session: enables Claude Code's native
  OS-level sandbox, which already merges secure-settings's credential Read-denies into
  its own filesystem restrictions at runtime — this addition doesn't duplicate that
  list; needs `bwrap` and `socat` on PATH on Linux, always available on macOS). Additions with a
  `skill` field are **directory copies**: copy the whole directory into
  `<dir>/skills/` (replace any existing copy so re-installs don't leave stale
  files). Additions with a `workflow` field are **file copies** into
  `<dir>/workflows/`: a `.js` there auto-registers as both the named workflow and
  its matching slash-command skill (Claude Code scans `<dir>/workflows/`).

## 2. Scan the existing config thoroughly

Start with a quick scale read: count hook registrations, skills, agents,
commands, and MCP servers in the existing config. This takes seconds and
determines whether a full migration or a clean start is the better path.

**If the existing setup looks notably layered** (multiple hooks registered from
outside this kit, a large skills or agents library, a permissions list that
stretches past a quick read, or a `CLAUDE.md` with deep import chains), offer a
clean start before cataloguing everything. Summarise what you see and explain the
trade-off: carrying it forward vs. a minimal, hardened, secure-by-default profile
they can layer third-party tools back onto at their own pace. Make clear that
claude.ai conversation history (server-side) is not affected by this choice, and
neither is anything stored outside the config dir (project CLAUDE.md files, the
auto-memory system). Content inside the existing config dir (hooks, skills,
CLAUDE.md imports, permissions) will not be auto-migrated. They'd need to copy
what they want to keep before proceeding.

If they choose **clean start**: skip the inventory below but **still run the
Shell-startup security pass** (the read-only section just below the inventory),
then go directly to Step 3 (confirm additions + plan) then Step 4 (execute).
Auth and onboarding seeding still apply. Third-party tools can be re-added
manually at their pace.

If they choose **migrate** (or the existing config isn't notably complex): do
the full inventory below. **This is where you beat the script**:

Inspect the user's current default config (`~/.claude`, or `$CLAUDE_CONFIG_DIR`
if set) and inventory what's migratable:

- `settings.json`: permissions (allow/deny/ask), env, hooks, statusLine, model,
  and any **absolute paths** that will break under a new config dir.
- `.mcp.json` / MCP servers in settings: note any that reference local paths,
  binaries, or need their own auth.
- `agents/`, `skills/`, `commands/`, `output-styles/`, `hooks/`, `workflows/`: list items.
- `CLAUDE.md` **and any `@`-imports it references**: an import pointing outside
  the migrated set will dangle.
- `keybindings.json`, `plugins/` + `enabledPlugins`.

Present a clear inventory and let the user pick per category (individual items or
all). Flag cross-dependencies you notice (e.g. a skill that calls a hook, an
agent referenced in settings, an MCP server a command relies on).

### Shell-startup security pass (run it BEFORE any write)

Before you write anything (the alias to the rc, the seeded auth, any placed file),
run the bundled read-only auditor over the user's shell startup chain as a
pre-write security pass:

```
bash config/skills/shell-audit/audit.sh            # picks the rc from $SHELL
# or pass an explicit rc:  bash config/skills/shell-audit/audit.sh ~/.zshrc
```

It walks the rc and every file it sources (cycle-safe) and reports four classes
(**credentials**, **persistence patterns**, **alias hygiene**, **git drift**) with
secret values redacted. It is strictly read-only, fast (~0.2 s for a typical
config, ~1 s for a large multi-file dotfiles tree), and independent of the rest of
the scan, so you can run it concurrently with the inventory above.

Why **before** any write, specifically:
- The installer is about to **add an alias to the rc and seed auth** onto this
  machine. Surface a hardcoded credential, a `curl … | sh` persistence pattern,
  or an unexpected git-drift/tamper on the startup files *first*, so the user
  decides knowingly before a security profile is layered on top.
- Run pre-write so the **git-drift** section reflects the user's *pre-existing* rc,
  not the managed block the installer is about to add (which would otherwise read
  as drift and mask a real one).

Present the findings and **offer** fixes. Never auto-apply them: dotfiles are
Edit/Write-denied by design, so hand any fix to the user via a `! <cmd>` prompt
(see the shell-audit skill's own guidance). Credentials are highest severity
(recommend moving to a keychain + **rotating** anything exposed). If the output
says **"COVERAGE IS PARTIAL"**, a variable-built `source` couldn't be resolved and
that file was NOT audited: tell the user and offer to re-run pointed at the
resolved path. State the scope limit: this covers the *shell-startup slice only*
(not launchd/cron/login-items/ssh/git-hooks). This is a **detective tripwire, not a
blocker**. A finding informs the user. It does not by itself abort the install.

## 3. Propose a migration plan, get approval

Summarize: target dir, alias, items to migrate, additions to add, and anything
that needs special handling (path rewrites, MCP auth, dangling imports). Wait for
the user's go-ahead.

## 4. Execute

> Confirm the pre-write **shell-startup security pass** (section 2) has already run
> and its findings were surfaced. Everything below writes to disk or the rc.

- `mkdir -p` the target dir.
- Copy the **selected** items into the matching subdirs. Make migrated hooks
  executable.
- **Rewrite paths**: anywhere the migrated `settings.json` (or a copied file)
  references the OLD config dir (hook `command`s, `statusLine.command`, absolute
  globs), rewrite `<old config dir>` → `<new config dir>`. Don't miss non-hook
  absolute paths.
- **Stage the migrated settings** (don't hand-merge the additions): if you're
  migrating the user's `settings.json`, copy it into `<dir>` first (with the
  OLD→NEW path rewrites above). The engine layers the additions onto it next.
  - **Dangerous modes are the user's call**: if the migrated settings enable
    `permissions.defaultMode: bypassPermissions` or the skip-prompt flags
    (`skipDangerousModePermissionPrompt`, `skipAutoPermissionPrompt`), do NOT
    strip them. Tell the user these are on (Claude runs without permission prompts
    by default) and offer to turn them off. Keep their setting unless they say so.
    This kit's own template never adds these.
- **Session history (opt-in):** ask the user whether to also migrate their
  session history: `history.jsonl`, `projects/`, `sessions/`, and `todos/`/`tasks/`
  (past conversations, input history, todo state). **Off by default**. Copy these
  (merging into any existing dirs) only if they say yes. Even then, NEVER copy the
  secret-prone state: `.credentials.json`, `shell-snapshots/`, `session-env/`,
  `paste-cache/`, `file-history/`, `telemetry/`. Those can capture exported tokens
  or pasted/edited secrets.
- **Layer the additions with the engine. Do NOT hand-roll the settings merge or
  hook registrations.** Run:
  ```
  CT_CONFIG_DIR="<dir>" CT_ADDITIONS="<space-separated addition ids>" ./install.sh --apply
  ```
  This is the deterministic, idempotent, re-runnable mechanics. It places every
  selected addition's files and **unions their settings onto the `settings.json`
  already in `<dir>`** (the one you migrated), then handles every detail you'd
  otherwise get wrong by hand: strips `"$comment"`; reconciles retired permissions
  against `config/managed-permissions.json` (adopt new / retire dropped / keep the
  user's own); registers leak-guard **once** (`WebSearch|WebFetch|mcp__searxng__`,
  web-egress tools incl. the SearXNG MCP surface; Bash egress is owned by
  command-guard); registers command-guard with bun's **absolute**
  path (`bun` is a **hard dependency**: selecting command-guard without `bun` aborts
  the install, exit non-zero, rather than soft-skipping a default-on security hook);
  registers mcp-guard on `mcp__.*` the same way and compiles its `mcp-policy.json`
  sidecar from `CT_MCP_ALLOW` / `CT_MCP_DENY`;
  merges the read-only `rtk-allowlist.json` for rtk-safe (never a
  blanket `Bash(rtk:*)`); copies the shell-audit
  skill and chmods its `audit.sh`; and seeds `aka-claude-tools.config` when a
  config-driven hook is selected. **You own the judgment** (which additions, what to
  migrate); the **engine owns the mechanics**.
- **Statusline location (if the statusline is enabled):** offer to pin an exact
  location for weather (default: auto-detect by IP, city-level). Make clear that
  nothing is saved or collected: if they give a city/address, geocode it once
  (e.g. OpenStreetMap Nominatim or open-meteo geocoding) and store **only** the
  resulting coordinates as `preferences.location: {latitude, longitude, countryCode,
  regionCode}` in the profile's `settings.json` (`regionCode` is the abbreviated
  state/region the statusline displays, e.g. `CA`). Don't keep the address text.
  Otherwise leave it to IP.
- **Onboarding**: seed `<dir>/.claude.json` with `oauthAccount`,
  `hasCompletedOnboarding`, `lastOnboardingVersion`, and related
  onboarding/terminal-setup flags copied from the user's own `~/.claude.json`
  (account metadata, no secrets, never tokens, projects, or history) so the new
  profile skips the first-launch onboarding prompt. `chmod 600` the result.
- **Auth** (you're already authenticated; just make the new profile inherit it):
  - `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` in
    env → already covers every profile; nothing to copy.
  - `~/.claude/.credentials.json` present (Linux/file-based) → copy it in.
  - macOS Keychain → can't migrate (keyed per config dir); tell the user they'll
    `/login` once on first launch, or `claude setup-token` to cover all profiles.
- **Alias: create/update/delete via the engine, NEVER by editing the rc yourself.**
  install.sh is the sole sanctioned rc writer (see the top of this file): it
  reviews the rc *and every file it sources, recursively* (cycle-safe) and writes
  idempotent managed blocks. Re-running never duplicates.

  **Create or update** (idempotent, safe to re-run):
  ```
  CT_CONFIG_DIR="<dir>" CT_ALIAS="<alias>" ./install.sh --alias
  ```
  - **exit 0**: alias is set (or already resolves to this dir, deduped). Done.
  - **non-zero exit**: `<alias>` is already taken by a **different** target.
    install.sh left it untouched. Pick another name and re-invoke, or skip the
    alias and give the user `CLAUDE_CONFIG_DIR="<dir>" claude`.

  **Delete** an alias (remove its managed block from the rc):
  ```
  CT_CONFIG_DIR="<dir>" CT_ALIAS="<alias>" ./install.sh --delete-alias
  ```
  Passing `CT_CONFIG_DIR` is optional but recommended: if the alias points to a
  **different** profile, the guard refuses the delete rather than clobbering.
  - **exit 0**: alias removed from rc.
  - **non-zero exit**: no managed block found, or the alias points to a different
    profile (run `--enumerate` to inspect and confirm).

  **Rename** an alias (two steps; both use the same engine gate):
  ```
  CT_CONFIG_DIR="<dir>" CT_ALIAS="<oldname>" ./install.sh --delete-alias
  CT_CONFIG_DIR="<dir>" CT_ALIAS="<newname>" ./install.sh --alias
  ```

  Do **not** write or delete aliases with `echo >> ~/.zshrc`, `sed`, or the Edit
  tool: the `command-guard` addition blocks an agent writing to startup files by
  design (and the secure-settings Edit/Write deny blocks the Edit tool path).
  Routing through `--alias` / `--delete-alias` is the **only** safe path.

## 5. Verify, then report

- `settings.json` parses as a **single** valid object, with **no `"$comment"`**
  key and **none of the `config/managed-permissions.json` `.retired[]` rules** the
  user agreed to drop.
- Every hook path resolves inside the new dir and is executable; run each hook
  once with a sample tool-call JSON and confirm sensible exit codes.
- The alias is present in the rc; `.claude.json` has `oauthAccount`.
- The launcher shim exists and is executable at `<cfg>/bin/<name>`, and the
  managed rc block carries the guarded `PATH` export for `<cfg>/bin` — unless the
  profile path contains a `:`, which cannot be expressed as a `PATH` entry; the
  installer then writes the alias and shim only, and says so.
- Summarize what was migrated, what was added, the auth outcome, and any
  edge cases you handled or flagged. Tell the user to open a new shell and run
  the alias.

## Do not migrate

- **Secrets, always:** `.credentials.json` (except the auth step above),
  `telemetry/`, and the secret-prone session caches `shell-snapshots/`,
  `session-env/`, `paste-cache/`, `file-history/`. Never copy these, even when the
  user opts into session-history migration (they can hold exported tokens or
  pasted/edited secrets).
- **Session/history, unless the user opts in:** `history.jsonl`, `projects/`,
  `sessions/`, `todos/`/`tasks/`, `.last-cleanup` default to *not migrated*. Copy
  them only on the explicit opt-in described in the Execute step.
