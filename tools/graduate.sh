#!/usr/bin/env bash
# aka-graduate.sh — move private-incubator (dev) work onto the PUBLIC upstream.
#
# Public is the canonical, append-only upstream: every change lands via a PR and
# main is NEVER force-pushed. This helper takes commits you developed privately
# on the dev repo (e.g. an embargoed security fix) and replays them onto a fresh
# branch off public/main as clean NEW commits — then prints the PR URL. It never
# rewrites or force-pushes public history.
#
# Because the one-time identity rewrite gave public a different root than dev,
# you cannot fast-forward between them: we cherry-pick by CONTENT, which works
# regardless of a shared base.
#
# Usage:
#   aka-graduate.sh --branch fix/foo  <dev-commit>...   # cherry-pick named commits
#   aka-graduate.sh --branch fix/foo  dev/main~3..dev/main
#
# Env: AKA_PUBLIC (public clone, default ~/coding/libs/claude-tools)
#      AKA_DEV    (dev clone,    default: the repo this script lives in)
set -euo pipefail

_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC="${AKA_PUBLIC:-$HOME/coding/libs/claude-tools}"
DEV="${AKA_DEV:-$(git -C "$_SELF_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$HOME/coding/libs/aka-claude-tools")}"
BRANCH="" ; FORCE=0 ; commits=()

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m  ✓\033[0m %s\n'    "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2;;
    --public) PUBLIC="$2"; shift 2;;
    --dev)    DEV="$2";    shift 2;;
    --force)  FORCE=1;     shift;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    -*) die "unknown flag: $1";;
    *)  commits+=("$1"); shift;;
  esac
done
[ -n "$BRANCH" ] || die "give a --branch name"
[ "${#commits[@]}" -gt 0 ] || die "name the dev commit(s) or range to graduate"
[ -d "$PUBLIC/.git" ] || die "public clone not found: $PUBLIC (seed it first — see PIPELINE.md)"
[ -d "$DEV/.git" ]    || die "dev clone not found: $DEV"

# Disallowed-identity guard: every commit reaching public must carry a clean
# author AND committer email. akaidentity.io covers collaborators; noreply@github
# covers web merges.
ALLOW_RE='@akasecurity\.io|@akaidentity\.io|noreply@github\.com'
# Trace + secret patterns (generic in-repo; operator-specific via env / local file).
source "$_SELF_DIR/leak-lib.sh"

cd "$PUBLIC"
[[ "$(git remote get-url origin)" == *claude-tools.git ]] || die "origin of $PUBLIC is not the public repo"

# Wire + fetch the dev remote so its commits are resolvable here.
git remote get-url dev >/dev/null 2>&1 || git remote add dev "$DEV"
git fetch -q dev
git fetch -q origin
ok "fetched dev + origin"

git checkout -q -B "$BRANCH" origin/main
ok "branch '$BRANCH' off origin/main"

git cherry-pick "${commits[@]}" || die "cherry-pick failed — resolve in $PUBLIC, then 'git cherry-pick --continue'"
ok "cherry-picked ${#commits[@]} ref(s)"

# Identity guard on the newly added commits only.
bad="$(git log --format='%an <%ae>|%cn <%ce>' origin/main..HEAD | grep -vE "$ALLOW_RE" || true)"
[ -z "$bad" ] || { printf 'disallowed identity on graduated commits:\n%s\n' "$bad" >&2; [ "$FORCE" = 1 ] || die "fix identity before pushing"; }
# Leak guard on the resulting tree diff.
leak="$(git diff origin/main..HEAD | grep -nE -e "$LEAK_RE" || true)"
[ -z "$leak" ] || { printf 'personal-trace in graduated diff:\n%s\n' "$leak" >&2; [ "$FORCE" = 1 ] || die "scrub before pushing"; }
ok "identity + leak guards clean"

echo; echo "review:  git -C $PUBLIC log --oneline origin/main..HEAD"
echo "push:    git -C $PUBLIC push -u origin $BRANCH"
echo "then open a PR:  https://github.com/akasecurity/claude-tools/compare/main...$BRANCH?expand=1"
