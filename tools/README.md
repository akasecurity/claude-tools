# tools/ — maintainer flow scripts

Maintainer-only helpers for moving work between the live profile, this repo, and
the public upstream. **Not shipped to users** (install.sh deploys `config/` only)
and not part of a public release — they live here so the whole team can run,
review, and test them.

## The pipeline

```
  ~/.claude-aka            this repo (private dev)         public upstream
  (live profile)   ──┐     claude-tools-dev          ┌──   claude-tools
  author + test      │     branch + PR + review      │     append-only, all PRs
                     ▼                                ▼
              promote.sh  ───────────────────▶  graduate.sh ───▶ public PR
```

- **`promote.sh`** — carry a live profile edit back into the repo. Manifest-driven
  (reads `config/additions.json`), path-remapped (`profile/<X>` → `config/<X>`),
  and leak-scanned (refuses to stage your name/email/host/home-path). Won't stage
  onto `main`.
  ```bash
  tools/promote.sh --list                     # addition ids
  tools/promote.sh --branch feat/x conductor  # stage conductor onto a branch
  tools/promote.sh --kind skill newthing       # a NEW artifact (then add to additions.json)
  ```
- **`graduate.sh`** — replay private dev commits onto a fresh branch off the
  public upstream (cherry-pick by content; never force-pushes public), guarded for
  identity + leaks. For embargoed work that was developed privately.
  ```bash
  tools/graduate.sh --branch fix/cve <dev-commit>...
  ```

- **`audit-history.sh`** — pre-seed gate. Scans an entire git history (every blob
  at every commit + commit messages + author/committer identity + pathnames) for
  secrets and operator-specific identifiers before it's published. Run it on the
  public seed right before pushing.
  ```bash
  tools/audit-history.sh --repo ../claude-tools --ref main
  ```

- **`leak-scan-diff.sh`** — PRE-MERGE gate (CI `leak-gate` job on every PR). Scans
  only what a branch ADDS vs a base (added lines + new commit messages/identities +
  new paths), so a leak is caught *before* it merges — which is what avoids a later
  history-rewrite + fleet re-clone. Diff-scoped; the `audit-history` full scan is the
  backstop. Also usable as a pre-commit hook.
  ```bash
  tools/leak-scan-diff.sh origin/main      # PR-style; or `--staged` as a pre-commit hook
  ```

- **`sync-public.sh`** — gated `dev → public` mirror once both repos share history.
  Fast-forward-ONLY (aborts on divergence; never forces) and runs the `audit-history`
  leak gate over the exact history before pushing `main` + tags. The protocol lives
  here so every trigger applies the same rails; the `.github/workflows/sync-public.yml`
  workflow runs it **manually** (`workflow_dispatch`) with a scoped GitHub App token,
  keeping a human on the irreversible public push.
  ```bash
  DRY_RUN=1 PUB_URL=git@github.com:akasecurity/claude-tools.git tools/sync-public.sh
  ```

Both default the repo to the clone they live in and are fully overridable by env
(`AKA_REPO`, `CLAUDE_CONFIG_DIR`, `AKA_PUBLIC`, `AKA_DEV`).

- **[`public-export-runbook.md`](public-export-runbook.md)** — example/template for the
  **one-time** seed of the public upstream as *filtered git history* (scrub every
  operator identifier + must-not-ship blob across all of history, gated by
  `audit-history.sh`). Placeholders only; real values stay in `leak-patterns.local`
  + a private note. The ongoing flow above (`graduate.sh` → public PR) is separate.

**Leak patterns.** The committed patterns ([`leak-lib.sh`](leak-lib.sh)) are generic
and name no specific person/host/namespace. Your own identifiers (name, tailnet,
private namespaces) stay out of the repo — put them in a gitignored
`tools/leak-patterns.local` (see `leak-patterns.local.example`) or `$AKA_LEAK_EXTRA`.
promote / graduate / audit-history all pick them up.

## Tests

`tests/run.sh` exercises this flow end-to-end in sandboxes (fake `$HOME`, throwaway
clones — never touches a real profile). Run it before opening a PR; CI runs it too.
