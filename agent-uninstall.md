# Remove an aka-claude-tools profile — driven by your Claude Code instance

**You (Claude) are removing an isolated aka-claude-tools config profile for the
user.** This is the teardown counterpart to [`agent-install.md`](agent-install.md),
and it is deliberately **not** a mirror of it. Removal is destructive and
mechanical, so your job is **not** to re-implement it — it is to (1) reason about
what would be lost and offer to preserve it, then (2) **delegate the destruction
to `./uninstall.sh`**, which carries the safety guards. Never hand-roll the
`rm -rf` yourself.

> ⚠️ **The one rule that matters most: never remove the profile THIS session is
> running inside.** You are running in a Claude Code session whose
> `$CLAUDE_CONFIG_DIR` points at some profile. If that is the profile being
> removed, deleting it wipes the config out from under your own running session
> (this exact mistake has happened). `uninstall.sh` refuses this case outright; do
> not try to work around it — tell the user to run the removal from a **plain
> shell** (or a different profile's session). Likewise never remove the default
> `~/.claude`: the agent path does not support that — have the user do it
> deliberately by hand.

Work through the steps below. **Confirm before executing, and verify after.**

> If `aka-claude-tools` was installed via **npm** and the profile's hooks are
> registered with that package's bundled `bun` (the installer's apply-time warning
> says so, and it is baked into the `command`/`statusLine.command` paths in
> `settings.json`), run this profile removal **before** `npm uninstall -g` or
> `npm update -g @akasecurity/claude-tools` — otherwise the hooks are left pointing
> at a `bun` binary that no longer exists and silently stop guarding (exit 127,
> which Claude Code does not treat as a block).

---

## 1. Identify the target profile

Establish exactly which profile dir is being removed — never guess:

- If the user named one (e.g. `~/.claude-work`), use it.
- Otherwise, discover the installed profiles the same way `uninstall.sh` does:
  read the shell rc *and every file it sources* and collect the
  `CLAUDE_CONFIG_DIR="…"` out of each `# >>> aka-claude-tools managed: … >>>`
  block. Present the list and let the user pick. (You can also just run
  `./uninstall.sh` with no argument, which performs this discovery and prompts.)
- Resolve it to an absolute path. Compare it to `$CLAUDE_CONFIG_DIR`: if they are
  the same, **stop** — this is the active-session profile (see the rule above).
  Exclude it from any pick-list.

## 2. Audit what will be lost — this is where you add value

`uninstall.sh` removes the whole profile dir; it does **not** back anything up.
Before anything is deleted, inspect the target dir and tell the user what is
about to go, separating **kit-managed** from **their own**:

- **Kit-managed (safe to lose — re-created by a re-install):** hooks carrying the
  `aka-claude-tools:managed-hook` marker, and the skills/commands/workflows that
  come from this repo's `config/additions.json`.
- **The user's own (irreplaceable):** `agents/`, `skills/`, `commands/`, `hooks/`
  that are **not** kit-managed; `CLAUDE.md` and any `@`-imports; `.mcp.json` / MCP
  config; `settings.json` customisations; and session history (`projects/`,
  `history.jsonl`, `todos/`, `sessions/`).
- **Auth:** `.credentials.json` (file-based logins) is removed with the dir.

Offer to **back the profile up first** — copy it to a timestamped sibling
(`cp -R "<dir>" "<dir>.backup-$(date +%Y%m%d-%H%M%S)"`) outside the dir so it
survives the teardown. Do this only if the user wants it; mention the backup will
contain `.credentials.json` and other secret-prone caches, so it is local-only.

## 3. Confirm the plan

Summarize: the exact target dir, the managed alias block(s) that will be removed
from which rc file(s), what user-owned content is inside, and whether a backup was
taken. Wait for the user's explicit go-ahead.

## 4. Execute — delegate to `uninstall.sh`

Run the hardened script with the explicit target (your own confirmation in step 3
stands in for its prompt):

```sh
./uninstall.sh "<dir>" --yes
```

Do **not** reimplement this with `rm -rf` + hand-edited rc files. The script:

- removes the profile dir **and** every managed alias block that points at it
  (matched by our markers + the embedded `CLAUDE_CONFIG_DIR`, so it is
  alias-name-independent and never touches other profiles' blocks or anything
  outside the markers);
- refuses if the target is the active session's profile, and never reads the
  ambient `$CLAUDE_CONFIG_DIR` as the thing to delete.

If the script refuses (active-session profile, or the default `~/.claude`), do not
override it — relay its message and have the user run the removal from a plain
shell.

## 5. Verify, then report

- The profile dir is gone (or report it was already absent).
- The managed alias block(s) for that dir are gone from the rc; **other profiles'
  blocks and the user's own aliases are untouched**.
- Any backup you took exists and is readable.
- Summarize: what was removed, which rc file(s) changed, what user-owned content
  went (and where the backup is, if any), and remind the user to open a new shell
  (or re-source their rc) to drop the alias from the current session.

## Never

- **Never remove the profile this session is running inside** (`$CLAUDE_CONFIG_DIR`),
  or the default `~/.claude`. Delegate to `uninstall.sh` and respect its refusals.
- **Never hand-roll the deletion** — no direct `rm -rf` of the profile, no manual
  rc surgery. The safety lives in `uninstall.sh`; route through it.
- **Never delete without first showing the user their irreplaceable content** and
  offering a backup.
