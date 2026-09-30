---
description: End-of-session handoff — summarize, verify, and stage so you can review and commit.
---

# /wrap-up

Leave the working tree clean and ready for **you** to review and commit.
**Prepare; do not commit, merge, or push** unless explicitly asked. Work
top-to-bottom; skip steps that don't apply.

0. **Defer to the repo.** If this project's `CLAUDE.md` / `AGENTS.md` defines a
   session-end or wrap-up process, follow *that* instead of the generic steps below.

1. **Establish context — this repo may not be yours alone.** Note the current
   branch, worktree (`git worktree list` if several), and upstream sync state
   (`git status -sb` ahead/behind). If a rebase / merge / cherry-pick is in
   progress, **stop and report** — never wrap up over someone's in-flight
   operation. If the index already holds staged changes this session didn't
   make, **leave them exactly as they are and say so** — another session or the
   developer may own them.

2. **Survey the session.** Run `git status` and `git diff --stat` (plus `git diff`
   for anything non-trivial). Summarize what changed and why in 2–4 sentences.

3. **Verify.** Run the checks the repo's conventions define, or the obvious
   project tests / linters / build. When the full suite is expensive, scope to
   what this session touched. Report real results — never assert "should work."
   **If something fails, stop and report it** rather than staging a broken
   change (unless the user says to proceed).

4. **Stage intentionally — or just propose.** Stage only the files this session
   changed, by name (never a blind `git add -A`). Before staging, scan the diff
   for **secrets / credentials / `.env`**, build artifacts, large files, and
   anything unrelated; leave those out and flag them. If a file mixes this
   session's work with unrelated or someone else's edits, **don't stage it** —
   list the exact `git add` commands instead and let the developer stage
   selectively.

5. **Draft the commit — don't run it.** Propose a clear, conventional message
   (`fix:` / `feat:` / `docs:` / `refactor:` …) describing the change, not the
   process. If the work is several unrelated changes, propose splitting it into
   atomic commits. If you're on `main`/`master` or a protected branch in a repo
   that works by branches/PRs, **propose a feature-branch name to move the work
   to — don't create it**. Then let the developer review the diff and commit —
   only commit yourself if they explicitly ask.

6. **Docs.** Only if the repo's conventions call for it (or the user asked),
   update the changelog / README. Don't invent ceremony the repo doesn't
   already use.

7. **Surface true loose ends — things we could genuinely lose.** A loose end is
   work that is at risk *right now* because nothing durable holds it: uncommitted
   or unpushed changes, an undocumented decision or finding made this session, a
   half-applied migration, a broken state left mid-flight. Those are the only
   things to flag as loose ends — call them out plainly so they aren't lost.
   - **Do NOT list as loose ends** follow-ups already safely captured somewhere
     durable — backlog tasks, tracked issues, plan checklists, saved memory.
     They aren't at risk; they just await execution.
   - You may still add a brief **"Captured for later"** note pointing to where
     such follow-ups live (e.g. "T5/T6 in the backlog"), but keep it separate
     from loose ends and don't dress it up as unfinished business.
   - If nothing is genuinely at risk, say so — "no loose ends" is a valid result.

8. **Continuation prompt.** If work remains for a later session (open plan
   steps, deferred follow-ups, a handoff), end with a short copy-paste prompt
   for a fresh session in a fenced block: the repo path, the goal, where things
   stand, the next concrete step, and pointers (files, branch, TODO section).
   Keep it minimal; the fresh session reads the repo itself. Skip it when
   nothing remains.

Never merge. Never push.
