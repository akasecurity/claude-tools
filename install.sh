#!/usr/bin/env bash
# aka-claude-tools installer
# ──────────────────────
# Creates an ISOLATED Claude Code config folder, layers on the aka-claude-tools
# additions you select, and wires a launcher so you can start it by name.
#
# Mechanism: Claude Code reads its config dir from $CLAUDE_CONFIG_DIR. Each folder
# is fully independent (own settings, hooks, agents, sessions). The launcher is a
# shell alias that exports that variable before launching `claude`:
#
#     alias claude-aka='CLAUDE_CONFIG_DIR="$HOME/.claude-aka" claude'
#
# plus a PATH-visible executable shim at <config_dir>/bin/<name> (the managed rc
# block also prepends that bin dir to PATH), so non-interactive shells and scripts
# can launch the profile too. The pre-rename launcher name `aka-claude` survives
# one release as a deprecated forwarder (see migrate_deprecated_launcher).
#
# Re-run any time. Idempotent: re-running for the same folder LAYERS in place —
# it never duplicates, and unchecking an addition you previously installed
# UNINSTALLS it (its hook/command/skill files and its settings contributions —
# hook registrations, statusLine, the permission/env rules it shipped — are
# removed). Your own rules, hooks, and files are never touched.
#
# SCOPE — this script owns the DETERMINISTIC, REPEATABLE mechanics and the
# privileged shell-rc write (the alias), nothing more:
#   • addition layering (place files + merge settings) — see apply_additions /
#     the --apply engine mode, which an agent or a CI script can invoke directly;
#   • alias creation/checking — see setup_alias / the --alias mode. install.sh is
#     the SOLE sanctioned writer of your shell rc, so the Claude-driven install
#     invokes it for the alias instead of editing the rc itself, which keeps
#     command-guard strict.
# Migrating a rich EXISTING config (reading it, deciding what to carry over,
# rewriting @-import / MCP paths) and backing-up-and-rebuilding a profile are
# JUDGMENT calls, owned by the Claude-driven install (Path A, agent-install.md) —
# it reads the whole config and reasons about it, then calls this script for the
# mechanics above. Targeting an existing dir here simply layers on top.
#
# Flags:
#   --defaults         non-interactive; accept every default (config ~/.claude-aka,
#                      launcher `claude-aka`, recommended additions, no copy of
#                      existing config).
#   --no-auth-inherit  do NOT seed the new profile's .claude.json from your existing
#                      login (use when the profile is for a DIFFERENT account).
#   --apply            DETERMINISTIC ENGINE mode: layer the additions named in
#                      $CT_ADDITIONS onto $CT_CONFIG_DIR and exit. No prompts, no
#                      new alias, no auth — just the repeatable mechanics (place files,
#                      union settings onto whatever is already in the dir, reconcile
#                      retired perms, register hooks); it may migrate a legacy
#                      `aka-claude` launcher to `claude-aka` if one is recorded for
#                      this profile (see migrate_deprecated_launcher). This is the
#                      entry point Path A (agent-install.md) invokes after it has done
#                      the judgment work (scan + migrate the user's config); also
#                      usable directly for a scripted/CI fresh install. Requires
#                      CT_CONFIG_DIR + CT_ADDITIONS.
#   --alias            Create/check the launcher alias for $CT_ALIAS → $CT_CONFIG_DIR
#                      and exit. install.sh is the SOLE sanctioned writer of your
#                      shell rc, so the agent invokes THIS rather than editing the rc
#                      itself — which keeps command-guard strict.
#                      Reviews the rc + its full source chain; writes an idempotent
#                      managed block (alias + guarded PATH export) and the executable
#                      shim at <CT_CONFIG_DIR>/bin/<CT_ALIAS>, or exits non-zero on an
#                      unresolved name collision — either an existing alias or a name
#                      that is already a command on PATH (the caller picks another
#                      name). Requires CT_CONFIG_DIR + CT_ALIAS; implies non-interactive.
#   --delete-alias     Remove the managed alias block for $CT_ALIAS from the shell rc,
#                      along with the marker-carrying launcher shim at
#                      <profile>/bin/$CT_ALIAS (and the bin/ dir if it empties), then
#                      exit. The ONLY safe way for an agent to delete a launcher
#                      alias — same rc-write gate as --alias. Optional CT_CONFIG_DIR:
#                      if supplied, refuses to delete if the alias resolves to a
#                      DIFFERENT profile (prevents accidental cross-profile clobber).
#                      Exits non-zero if no managed block for the alias is found.
#                      Deleting the profile's current launcher also removes the
#                      deprecated `aka-claude` forwarder to it, if one was migrated.
#                      Requires CT_ALIAS; implies non-interactive.
#   --version, -V      Print the kit version (from the VERSION file) and exit. Runs
#                      before any dependency check, so it works on a bare checkout.

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="$REPO_DIR/config"
# Single source of truth for the kit version — also git-tagged and recorded in
# CHANGELOG.md. Missing file degrades to "unknown" rather than failing.
KIT_VERSION="$(cat "$REPO_DIR/VERSION" 2>/dev/null || printf 'unknown')"
# History of permission rules the kit has retired — drives upgrade reconciliation
# (see reconcile_managed_perms). Missing file degrades to "nothing retired".
RETIRED_PERMS="$(cat "$CONFIG_SRC/managed-permissions.json" 2>/dev/null || printf '{}')"
# shellcheck source=shared/lib/common.sh
source "$REPO_DIR/shared/lib/common.sh"

SEED_AUTH=1
CT_APPLY=0
CT_ALIAS_MODE=0
CT_DELETE_ALIAS=0
CT_ENUMERATE=0
for arg in "$@"; do
  case "$arg" in
    --version|-V)      printf 'aka-claude-tools %s\n' "$KIT_VERSION"; exit 0 ;;
    --defaults)        export CT_NONINTERACTIVE=1 ;;
    --no-auth-inherit) SEED_AUTH=0 ;;
    --apply)           CT_APPLY=1; export CT_NONINTERACTIVE=1 ;;
    --alias)           CT_ALIAS_MODE=1; export CT_NONINTERACTIVE=1 ;;
    --delete-alias)    CT_DELETE_ALIAS=1; export CT_NONINTERACTIVE=1 ;;
    --enumerate)       CT_ENUMERATE=1; export CT_NONINTERACTIVE=1 ;;
  esac
done

# ── preflight ────────────────────────────────────────────────────────────────
# jq drives the whole settings merge — required. Offer to install it via the
# detected package manager; abort if we can't get it.
ensure_dep jq "jq (required)" 1
# The claude-CLI check and the banner are installer chrome — skip them in --apply
# (engine) mode, which is invoked programmatically and only needs jq.
if [ "$CT_APPLY" != "1" ] && [ "$CT_ALIAS_MODE" != "1" ] && [ "$CT_DELETE_ALIAS" != "1" ] && [ "$CT_ENUMERATE" != "1" ]; then
  command -v claude >/dev/null 2>&1 || warn "claude CLI not found on PATH — the alias will still be written, but install Claude Code to use it."
  # bun (the guard hooks) and trufflehog (the secret scans) are checked/offered when those
  # additions are selected — see the build step below.

  say ""
  printf '%s%s aka-claude-tools installer %s\n' "$C_BOLD" "$C_BLU" "$C_RST"
  say "${C_DIM}Isolated Claude config folders + aliases, with the must-have additions.${C_RST}"
fi

# shq <string> → the value as ONE POSIX-shell-quoted token, with any embedded single
# quote escaped as '\'' — so a path containing spaces, shell metachars, OR a literal
# single quote (e.g. /Users/x/O'Neil/.claude) round-trips through a shell command line
# unchanged. Used to build the hook `command` strings Claude Code re-parses through a
# shell. Pure bash (no subshell); for a quote-free value it yields the same '<value>'
# the installer wrote before, so existing registrations are byte-identical.
shq() { local s=$1; s=${s//\'/\'\\\'\'}; printf "'%s'" "$s"; }

# cfg_token <abs-dir> — shell-safe, host-PORTABLE token for the config dir as it
# appears INSIDE a registered hook `command`. A $HOME-relative dir becomes
#   $HOME'<rest>'   (literal, UNQUOTED $HOME so the running shell expands it per host;
# the remainder shq()-quoted so spaces / metachars / embedded quotes stay safe). So the
# written settings.json carries NO absolute /Users/<who> literal and stays valid on every
# host — a profile that is git-backed/synced no longer breaks when a SIBLING host pulls it
# (the prior absolute form was "foreign" there and tripped the backup hook's heal). A dir
# OUTSIDE $HOME cannot be portablized, so it stays the fully-quoted absolute form shq()
# produced before — byte-identical to the legacy registration, so non-$HOME profiles are
# unaffected. Pure bash; POSIX `${p#…}` (no GNU-isms), so it stays BSD/Linux-portable.
cfg_token() {
  local p=$1
  case "$p" in
    "$HOME")   printf '%s' '$HOME' ;;
    "$HOME"/*) printf '$HOME%s' "$(shq "/${p#"$HOME"/}")" ;;
    *)         shq "$p" ;;
  esac
}

# ── settings merge ───────────────────────────────────────────────────────────
# merge_settings <existing.json|''> <additions.json-string>  -> merged JSON on stdout
# Deep-merges (later wins) but UNIONS permission arrays and hook-event arrays so a
# copied-in existing config never loses its own denies/hooks.
merge_settings() {
  local existing="$1" additions="$2"
  [ -z "$existing" ] && existing='{}'
  [ -z "$additions" ] && additions='{}'
  jq -n --argjson e "$existing" --argjson a "$additions" '
    # Strip maintainer-only "$comment" keys from the KIT additions RECURSIVELY
    # (not just top-level) before merging, so a note nested inside a payload can
    # never leak into the user'"'"'s settings.json. Applied to $a only — the user'"'"'s
    # own settings ($e) are never walked, so a key they legitimately keep stays.
    ($a | walk(if type=="object" then del(.["$comment"]) else . end)) as $a
    | ($e * $a)
    | ( (($e.permissions // {}) * ($a.permissions // {})) as $pbase
        | reduce ("allow","deny","ask") as $k ($pbase;
            ( ((($e.permissions[$k]) // []) + (($a.permissions[$k]) // [])) | unique ) as $m
            | if ($m | length) > 0 then .[$k] = $m else . end)
      ) as $perms
    | (if ($perms | length) > 0 then .permissions = $perms else del(.permissions) end)
    | ( ($e.hooks // {}) as $eh | ($a.hooks // {}) as $ah
        | (($eh | keys) + ($ah | keys) | unique) as $evts
        | reduce $evts[] as $evt ({};
            .[$evt] = ((($eh[$evt] // []) + ($ah[$evt] // []))
              | unique_by(walk(if type=="object" then to_entries|sort_by(.key)|from_entries else . end) | tojson)))
      ) as $hooks
    | (if ($hooks | length) > 0 then .hooks = $hooks else del(.hooks) end)
    | del(.["$comment"])
  '
}

# idxs_to_subarray '<json-array>' "1 3 4"  → JSON array of those 1-based elements
# (empty selection → []). Used to turn a user's pick of line numbers into a set.
idxs_to_subarray() {
  local arr="$1" idxs="$2"
  [ -z "$idxs" ] && { printf '[]'; return; }
  local jqidx; jqidx="$(printf '%s\n' $idxs | jq -s 'map(. - 1)')"
  jq -cn --argjson a "$arr" --argjson i "$jqidx" '[ $i[] as $k | $a[$k] ]'
}

# ── uninstall a deselected addition ──────────────────────────────────────────
# A plain merge only ADDS, so unchecking an addition on a re-run used to leave
# its files and settings behind forever. These helpers remove exactly what an
# addition contributed — driven by config/additions.json (.hook/.command/.skill/
# .settings/.statusLine) so they can't drift from the install logic. All are
# idempotent: pruning something already absent is a no-op.

# Remove every settings hook registration whose command references basename $1,
# then drop any event left empty. Kit hooks are matched by their unique file
# name, so a user's own hooks (different command) are never touched.
# Fully type-robust (mirrors prune_hook_regs_resolving): every shape assumption that
# could abort jq on a malformed settings.json under `set -euo pipefail` is guarded —
#   • the event VALUE may not be an array (a string/object/number) → left as-is, then
#     dropped by the final non-empty-array select (a non-array event isn't a reg list);
#   • the inner .hooks may not be an array → treated as empty;
#   • a .hooks MEMBER may not be an object → short-circuited (never reaches .command);
#   • the .command itself may be a non-string/array (the observed object shape) → cmdstr
#     normalizes it to "" (string-as-is / array argv joined over its string elements / "").
# So `contains($b)` is always string-vs-string and a foreign-shaped reg never crashes the
# pruner (which would blank the settings threaded through the deselect pipeline).
prune_hook_regs() {
  jq --arg b "$1" '
    def cmdstr($c): (if ($c|type)=="array" then ([ $c[] | select(type=="string") ] | join(" ")) elif ($c|type)=="string" then $c else "" end);
    if (.hooks|type)=="object" then
      (.hooks |= ( to_entries
        | map(.value |= ( if type=="array"
              then map(select(((type=="object")
                    and ((if (.hooks|type)=="array" then .hooks else [] end)
                         | any((type=="object") and (cmdstr(.command) | contains($b))))) | not))
              else . end ))
        | map(select((.value|type)=="array" and (.value|length) > 0))
        | from_entries ))
      | (if (.hooks // {}) == {} then del(.hooks) else . end)
    else . end'
}

# prune_hook_regs_resolving <config_dir> <add-json>  (settings on stdin → stdout)
# Remove EXISTING hook registrations that are the same LOGICAL registration as one the
# kit adds this run (<add-json>), differing ONLY in path SPELLING — so the union doesn't
# leave both. "Same logical registration" = same hook EVENT + same MATCHER + a
# BYTE-IDENTICAL command after normalization (expand $HOME / ${HOME} / $CLAUDE_CONFIG_DIR /
# ${CLAUDE_CONFIG_DIR} / ~, strip quotes, collapse whitespace).
#
# Two gates make this surgical, both protecting deliberate user customization the union
# preserves by design (see the install-merge contract):
#   • MATCHER — a user who re-scoped a kit hook's matcher (e.g. leak-guard on "WebFetch"
#     not the kit's "WebSearch|WebFetch") keeps it: different matcher ≠ same logical reg.
#   • FULL-COMMAND EQUALITY (not just same file) — a user who AUGMENTED the kit invocation
#     (e.g. `…/x.sh --extra-flag`, an env prefix, a custom bun path) keeps it: the
#     normalized commands differ, so it is not a spelling-dup and is left untouched.
# Only a pure re-spelling of the IDENTICAL command (a converted foreign profile's
# `$HOME/.claude-x/hooks/harness-pointer.sh` vs the kit's single-quoted absolute form)
# normalizes equal and is collapsed — unique_by(tojson) in the union can't catch it
# because the raw strings differ. A user's own non-kit hook never matches. Idempotent.
# Type-robust: a non-string/array .command yields "" (no crash under set -euo pipefail);
# per-hook (a sibling hook in the same entry object is kept); emptied entries are dropped.
prune_hook_regs_resolving() {
  local cfg="$1" add="$2"
  jq --arg home "$HOME" --arg cfg "$cfg" --argjson add "$add" '
    # ncmd COMMAND → the fully-normalized command string (or "" for a non-string/array,
    # so a malformed object .command never reaches gsub and aborts the run). Array argv
    # is space-joined; $HOME/$CLAUDE_CONFIG_DIR/~ expanded; quotes stripped; whitespace
    # collapsed+trimmed so spelling differences ('"'"'dir'"'"'/x vs $HOME/x) normalize equal
    # while a genuine arg/flag/prefix difference stays distinct.
    def ncmd:
      ( if type=="string" then . elif type=="array" then ([ .[] | select(type=="string") ] | join(" ")) else "" end )
      | gsub("\\$\\{HOME\\}"; $home) | gsub("\\$HOME"; $home)
      | gsub("\\$\\{CLAUDE_CONFIG_DIR\\}"; $cfg) | gsub("\\$CLAUDE_CONFIG_DIR"; $cfg)
      | gsub("~/"; ($home + "/")) | gsub("['"'"'\"]"; "")
      | gsub("[[:space:]]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
    # (event, matcher, normalized-command) tuples the kit registers this run.
    ( [ ($add.hooks // {}) | to_entries[] | .key as $e | .value[]? as $r
        | ($r.hooks // [])[]? | (.command | ncmd) as $c | select($c != "")
        | {e:$e, m:($r.matcher // ""), c:$c} ] ) as $kit
    | if (.hooks|type)=="object" then
        (.hooks |= ( to_entries
          | map( .key as $ev
                 | .value |= ( if type=="array" then
                     # PER-HOOK prune: within each entry object, drop ONLY the individual
                     # hook(s) that normalize byte-equal to a kit reg of the same
                     # event+matcher — a sibling user hook in the SAME object is kept.
                     ( map( if type=="object" then
                              (.matcher // "") as $m
                              # guard a non-array .hooks (a string/object scalar) → []: jq
                              # map() over a non-array aborts ("Cannot iterate over string")
                              # under set -euo pipefail. (.hooks // []) only catches null.
                              | .hooks = ( (if (.hooks|type)=="array" then .hooks else [] end) | map( select(
                                  ( (type=="object")
                                    and ( (.command | ncmd) as $c
                                          | ($kit | any(.e==$ev and .m==$m and .c==$c)) )
                                  ) | not ) ) )
                            else . end )
                       # drop object entries we emptied (all hooks were kit-dups); keep
                       # non-objects and entries that still have hooks.
                       | map( select( (type=="object" and ((.hooks // []) | length == 0)) | not ) ) )
                     else . end ) )
          | map(select((.value|type)=="array" and (.value|length) > 0))
          | from_entries ))
        | (if (.hooks // {}) == {} then del(.hooks) else . end)
      else . end'
}

# prune_statusline <quoted-anchor-stem>  (settings json on stdin → pruned on stdout)
# Drop the kit's .statusLine on deselect — identified by its command END-ANCHORED on the
# kit's EXACT registered tail "<shq(config_dir)>/hooks/statusline" with EITHER extension
# (the caller passes that stem). The kit registers "<shq(bun)> <shq(config_dir)>/hooks/
# statusline.ts" today (and a pre-port profile "<shq(config_dir)>/hooks/statusline.sh"),
# where shq(config_dir) is the SINGLE-QUOTED dir, e.g. '/Users/x/.claude-aka'. So the
# stored command ends with the literal quoted tail '...'/hooks/statusline.{sh,ts}, and we
# match that tail VERBATIM — no quote-stripping. The surrounding quotes are precisely what
# makes the kit's registration distinguishable from a user command that merely passes the
# path as DATA (e.g. `echo '/Users/x/.claude-aka/hooks/statusline.ts'`, whose tail is
# ...statusline.ts' with the closing quote in a DIFFERENT place) — stripping quotes would
# conflate the two and risk deleting that user's statusLine.
# If a user's own prior statusLine was stashed when the addition was installed (see the
# stash step in apply_additions), RESTORE it verbatim instead of leaving none — the
# statusLine is a singleton the merge overwrites, so stash+restore is the only way to
# deselect 'statusline' without losing a value the user had before.
# END-anchored on the QUOTED FULL path (endswith): a user statusLine in a DIFFERENT
# directory (/opt/custom/hooks/statusline.ts), the fully-quoted path-as-data forms above, a
# mid-string mention, or a suffix (.../statusline.ts-wrapper) all FAIL the match and are left
# untouched. Because shq() is deterministic and config_dir is canonicalized identically at
# install and deselect (apply_entry / setup_one_config strip the trailing slash + absolutize),
# the install-time and deselect-time tails are byte-identical — including a config dir that
# contains a space OR an embedded single quote, which now round-trips cleanly. The stash
# guard (apply_additions) builds the SAME manifest-derived quoted stem so stash and restore
# can't disagree.
# IRREDUCIBLE LIMITS (both safe, both documented rather than over-claimed):
#  • A user command whose FINAL token is the path written in the kit's EXACT split-token
#    quoting AND in the kit's EXACT config dir (e.g. `wrapper '<config_dir>'/hooks/statusline.ts`)
#    is byte-indistinguishable from the kit's own registration tail and WILL match. This is a
#    pathological hand-construction (no one quotes a data path that way, in that dir); it is the
#    floor of any string-based ownership test, not a realistic user value.
#  • If Claude Code ever re-serializes .statusLine.command into an ARRAY or a different quoting
#    style, the join loses the literal quotes and the kit's OWN tail stops matching → a deselect
#    leaves the kit statusLine in place. That is a non-destructive false NEGATIVE (a stale entry
#    the user can remove), never a clobber. statusLine.command is a string in CC's schema today.
# prune_statusline <portable-stem> [<legacy-stem>]
# Matches the kit's statusLine by its END-anchored quoted tail. Two stems are accepted so
# the test recognises a profile written by EITHER the portable cfg_token() form
# ($HOME'<dir>'/hooks/statusline) OR a pre-portability absolute form
# (<shq(config_dir)>/hooks/statusline) — so deselect/stash stay correct across the upgrade
# that flipped the registration to $HOME. <legacy-stem> defaults to <portable-stem> when
# omitted (single-form callers unchanged).
prune_statusline() {
  jq --arg stem "$1" --arg legacy "${2:-$1}" '
    if (.statusLine|type)=="object"
       and ((.statusLine.command) as $c
            | (if ($c|type)=="array" then ($c|join(" ")) else ($c // "") end)
            | ( endswith($stem + ".sh")   or endswith($stem + ".ts")
                or endswith($legacy + ".sh") or endswith($legacy + ".ts") ))
    then (if has("_aka_prior_statusLine")
          then .statusLine = ._aka_prior_statusLine | del(._aka_prior_statusLine)
          else del(.statusLine) end)
    else . end'
}

# Subtract an addition's shipped permission arrays + env keys (read from its
# payload file $1) from the settings on stdin. Set-difference on permission
# arrays and key-removal on env — only the exact rules the kit shipped go; any
# the user also keeps elsewhere in their own rules are unaffected (the kit rule
# is a duplicate the union would re-add anyway).
# ACCEPTED EDGE (operator decision): the prune can't distinguish "the kit installed
# this rule" from "the user independently holds an identically-phrased rule." So a
# PARTIAL install that deselects a settings-only addition (e.g. secure-settings) will
# remove a coinciding user rule even if that addition was never installed. This is the
# intended deselect semantics; the trigger (partial install + a user deny phrased
# exactly like a kit deny) is rare, and selecting the addition re-adds it. Documented,
# not "fixed" — a precise fix would need per-rule install provenance.
prune_perms_env() {
  local p; p="$(jq -c '{permissions: (.permissions // {}), env: (.env // {})}' "$1" 2>/dev/null || printf '{}')"
  jq --argjson p "$p" '
    ( if (.permissions|type)=="object" then
        reduce ("allow","deny","ask") as $k (.;
          if (.permissions[$k]?) and ($p.permissions[$k]?) then
            (.permissions[$k] = (.permissions[$k] - $p.permissions[$k]))
            | (if (.permissions[$k]|length) == 0 then del(.permissions[$k]) else . end)
          else . end)
        | (if (.permissions // {}) == {} then del(.permissions) else . end)
      else . end )
    | ( if (.env|type)=="object" then
          (.env |= with_entries(select((.key) as $k | ($p.env | has($k)) | not)))
          | (if (.env // {}) == {} then del(.env) else . end)
        else . end )'
}

# addition_owned_paths <id> <config_dir> → echo the files/dirs the addition owns.
addition_owned_paths() {
  local id="$1" cfg="$2" key rel
  # Keep this key list in sync with the placeable payload keys used by the per-id
  # build blocks (place_file/place_dir): hook, command, statusLine, skill, workflow.
  # A placeable key omitted here orphans that addition's file on deselect.
  for key in hook command statusLine skill workflow; do
    rel="$(jq -r --arg i "$id" --arg k "$key" '.additions[] | select(.id==$i) | .[$k] // ""' "$CONFIG_SRC/additions.json")"
    [ -n "$rel" ] && echo "$cfg/$rel"
  done
}

# prune_addition_from_settings <id> <config_dir>  (settings json on stdin → pruned on stdout)
# Applies the relevant prunes for one addition based on its additions.json entry.
prune_addition_from_settings() {
  local id="$1" config_dir="$2" s hook sline setf
  s="$(cat)"
  hook="$(jq -r --arg i "$id" '.additions[] | select(.id==$i) | .hook // ""'       "$CONFIG_SRC/additions.json")"
  sline="$(jq -r --arg i "$id" '.additions[] | select(.id==$i) | .statusLine // ""' "$CONFIG_SRC/additions.json")"
  setf="$(jq -r --arg i "$id" '.additions[] | select(.id==$i) | .settings // ""'   "$CONFIG_SRC/additions.json")"
  [ -n "$hook" ]  && s="$(printf '%s' "$s" | prune_hook_regs "$(basename "$hook")")"
  # End-anchored on the kit's EXACT registered tail "<dir-token>/hooks/statusline" (either
  # extension), built with the SAME cfg_token() the registration uses — so it matches the
  # kit's own command verbatim while a user statusLine ending in /hooks/statusline.{sh,ts}
  # in some OTHER dir, or one passing the path as data, is never matched (consistent with
  # the stash guard in apply_additions). Both the PORTABLE form ($HOME'<dir>'/…) and the
  # LEGACY absolute form (<shq(config_dir)>/…) are passed, so a profile written before the
  # portability flip still prunes. $sline is the current manifest path (…/statusline.ts);
  # ${sline%.*} drops the extension to a stem and prune_statusline tests both .sh and .ts,
  # so a residual pre-port .sh registration in THIS config dir also prunes.
  [ -n "$sline" ] && s="$(printf '%s' "$s" | prune_statusline "$(cfg_token "$config_dir")/${sline%.*}" "$(shq "$config_dir")/${sline%.*}")"
  # The statusline addition can pin a weather location into .preferences.location at
  # install; prune_statusline only drops the statusLine command, so remove that pinned
  # preference too (it is the only thing the kit writes under .preferences).
  [ "$id" = "statusline" ] && s="$(printf '%s' "$s" | jq 'if (.preferences|type)=="object" then (del(.preferences.location) | (if (.preferences=={}) then del(.preferences) else . end)) else . end')"
  [ -n "$setf" ] && [ -f "$CONFIG_SRC/$setf" ] && s="$(printf '%s' "$s" | prune_perms_env "$CONFIG_SRC/$setf")"
  printf '%s' "$s"
}

# ── managed-permission reconciliation ────────────────────────────────────────
# A plain settings merge UNIONS permission arrays, so a rule the kit used to ship
# but has since dropped can never be removed by re-running the installer — it
# lingers forever in an upgraded profile (and a deny the kit no longer wants stays
# active). This reconciles the kit-managed arrays (deny/allow/ask) before the
# merge, so on an upgrade the engineer SEES the differences and chooses per-rule:
#   • new rules this version adds        → adopted by default (skip individually)
#   • rules this version no longer ships → retired by default (keep individually)
#   • anything the kit never shipped (your own rules) → always left untouched
# "No longer ships" = a string listed in config/managed-permissions.json .retired[]
# that is absent from the current secure-settings / rtk-allowlist payload. Honors
# CT_NONINTERACTIVE (takes the defaults: adopt new, retire dropped) and always
# logs the outcome so an upgrade never changes rules silently.
# Sets globals RECON_EXISTING / RECON_ADD for the caller to merge.
RECON_EXISTING='{}'; RECON_ADD='{}'
reconcile_managed_perms() {
  local existing="$1" add="$2"
  RECON_EXISTING="$existing"; RECON_ADD="$add"
  # Nothing shipped this run, or no prior settings → plain merge already does the
  # right thing (there is nothing to retire and every kit rule is a clean add).
  [ "$(jq -r '(.permissions // {}) | length' <<<"$add")" = "0" ] && return 0
  [ "$(jq -r '(.permissions // {}) | length' <<<"$existing")" = "0" ] && return 0

  local key arr_new arr_exist arr_ret added retired_present n_add n_ret shown=0
  for key in deny allow ask; do
    arr_new="$(jq -c --arg k "$key" '.permissions[$k] // []' <<<"$add")"
    # NOTE: an array the kit ships nothing into this run is still reconciled, because
    # RETIREMENT is independent of what's selected. permissions.allow is supplied only
    # by rtk-allowlist.json, so gating on a non-empty arr_new meant a user who upgraded
    # while DESELECTING rtk-safe kept every retired allow rule forever — exactly the
    # users who most need `Bash(rtk find:*)` (which passes -exec/-delete through) gone.
    # Nothing is invented for an unselected array: `added` below is ([] - existing) = [],
    # so only the retire branch can fire, and it only ever touches strings the kit itself
    # shipped in the past (.retired[]). Rules the kit never shipped stay untouched.
    # The real "nothing to do" test is the n_add/n_ret guard a few lines down.
    arr_exist="$(jq -c --arg k "$key" '.permissions[$k] // []' <<<"$existing")"
    arr_ret="$(jq -c --arg k "$key" '(.retired[$k]) // []' <<<"$RETIRED_PERMS")"

    added="$(jq -cn --argjson n "$arr_new" --argjson e "$arr_exist" '$n - $e')"
    # Retire candidates = existing rules that the kit once shipped (in .retired)
    # AND no longer ships now. Intersection of existing with the retired history.
    retired_present="$(jq -cn --argjson e "$arr_exist" --argjson r "$arr_ret" '$e - ($e - $r)')"
    n_add="$(jq 'length' <<<"$added")"; n_ret="$(jq 'length' <<<"$retired_present")"
    [ "$n_add" = "0" ] && [ "$n_ret" = "0" ] && continue

    if [ "$shown" = "0" ]; then
      isay ""; isay "${C_BOLD}Reconciling permissions with this version${C_RST} ${C_DIM}(your own rules are kept untouched)${C_RST}"
      shown=1
    fi
    isay ""; isay "  ${C_BOLD}permissions.${key}${C_RST}"

    local skip_idxs="" keep_idxs="" i e sel
    if [ "$n_add" != "0" ]; then
      isay "    ${C_GRN}+ ${n_add} new rule(s) in this version:${C_RST}"
      i=1; while IFS= read -r e; do isay "        ${C_DIM}${i})${C_RST} ${e}"; i=$((i+1)); done < <(jq -r '.[]' <<<"$added")
      prompt sel "    skip any? (numbers to SKIP, Enter = adopt all):" ""
      skip_idxs="$(parse_selection "$sel" "$n_add")"
    fi
    if [ "$n_ret" != "0" ]; then
      isay "    ${C_YLW}- ${n_ret} rule(s) this version no longer ships:${C_RST}"
      i=1; while IFS= read -r e; do isay "        ${C_DIM}${i})${C_RST} ${e}"; i=$((i+1)); done < <(jq -r '.[]' <<<"$retired_present")
      prompt sel "    keep any? (numbers to KEEP, Enter = drop all):" ""
      keep_idxs="$(parse_selection "$sel" "$n_ret")"
    fi

    local skip_added keep_retired drop_retired
    skip_added="$(idxs_to_subarray "$added" "$skip_idxs")"
    keep_retired="$(idxs_to_subarray "$retired_present" "$keep_idxs")"
    drop_retired="$(jq -cn --argjson r "$retired_present" --argjson k "$keep_retired" '$r - $k')"

    # Apply: drop skipped additions from the incoming kit set, and drop the
    # retired rules the engineer didn't keep from the existing set. The plain
    # merge then unions what's left — preserving every user rule and kept rule.
    RECON_ADD="$(jq -c --arg k "$key" --argjson skip "$skip_added" \
      '.permissions[$k] = ((.permissions[$k] // []) - $skip)' <<<"$RECON_ADD")"
    RECON_EXISTING="$(jq -c --arg k "$key" --argjson drop "$drop_retired" \
      'if (.permissions[$k]?) then .permissions[$k] = (.permissions[$k] - $drop) else . end' <<<"$RECON_EXISTING")"

    local n_adopted n_retired
    n_adopted="$(jq -n --argjson a "$added" --argjson s "$skip_added" '($a - $s) | length')"
    n_retired="$(jq 'length' <<<"$drop_retired")"
    [ "$n_adopted" != "0" ] && ok "permissions.${key}: adopted ${n_adopted} new rule(s)"
    [ "$n_retired" != "0" ] && ok "permissions.${key}: retired ${n_retired} rule(s) this version no longer ships"
  done
}

# ── auth inheritance ─────────────────────────────────────────────────────────
# Save the engineer from re-authenticating in a new profile. Two parts:
#   1. .claude.json onboarding metadata — without oauthAccount + onboarding flags,
#      the REPL runs /login-onboarding on EVERY launch. Seed it from the engineer's
#      OWN existing .claude.json (their account metadata, no secrets, same machine).
#   2. Credentials — env-var token covers all profiles; .credentials.json is
#      copyable; macOS Keychain is per-profile (one-time /login, or use the token).
# Only account metadata + onboarding/terminal-setup flags — never tokens, projects,
# history, or usage counters.
CLAUDE_JSON_SEED_FILTER='{oauthAccount, hasCompletedOnboarding, lastOnboardingVersion, deepLinkTerminal, optionAsMetaKeyInstalled, appleTerminalSetupInProgress, autoPermissionsNotificationCount} | with_entries(select(.value != null))'

seed_auth() {
  local config_dir="$1" alias_name="$2"
  local target="$config_dir/.claude.json"

  # 1. onboarding metadata
  if [ -f "$target" ] && grep -q '"oauthAccount"' "$target" 2>/dev/null; then
    ok "$(basename "$config_dir")/.claude.json already has oauthAccount — no onboarding needed"
  else
    local src=""
    for c in "$HOME/.claude.json" "$HOME/.claude/.claude.json"; do
      [ -f "$c" ] && grep -q '"oauthAccount"' "$c" 2>/dev/null && { src="$c"; break; }
    done
    if [ -n "$src" ]; then
      local seed existing='{}'
      seed="$(jq "$CLAUDE_JSON_SEED_FILTER" "$src")"
      [ -f "$target" ] && existing="$(cat "$target")"
      jq -s '.[0] * .[1]' <(printf '%s' "$existing") <(printf '%s' "$seed") > "$target.tmp" && mv "$target.tmp" "$target"
      chmod 600 "$target"
      ok "Seeded .claude.json from ${src/#$HOME/~} — skips first-launch onboarding"
    else
      warn "No existing .claude.json with oauthAccount found — first launch will onboard once."
    fi
  fi

  # 2. detect the ACTIVE auth method (Claude Code's precedence order) and inherit
  #    it where that's possible:
  #      env tokens        → cover every CLAUDE_CONFIG_DIR automatically; no copy
  #      .credentials.json → file-based (Linux); copyable
  #      macOS Keychain    → keyed per config dir; CANNOT migrate between configs,
  #                          so the new alias must re-authenticate once.
  local src_creds="$HOME/.claude/.credentials.json"
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ok "Auth detected: ANTHROPIC_API_KEY (env) — covers every profile, no copy needed."
  elif [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    ok "Auth detected: ANTHROPIC_AUTH_TOKEN (env) — covers every profile, no copy needed."
  elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    ok "Auth detected: CLAUDE_CODE_OAUTH_TOKEN (env setup-token) — covers every profile, no re-login."
  elif [ "$(uname)" != "Darwin" ] && [ -f "$src_creds" ]; then
    cp "$src_creds" "$config_dir/.credentials.json"; chmod 600 "$config_dir/.credentials.json"
    ok "Auth detected: credentials.json (file) — copied into the new profile, no re-login."
  else
    warn "You'll need to authenticate once when you first launch '${alias_name}'."
    say  "  ${C_DIM}Keychain/OAuth login can't migrate between Claude configs — Claude Code keys it per config dir.${C_RST}"
    say  "  ${C_DIM}Tip: 'claude setup-token' → export CLAUDE_CODE_OAUTH_TOKEN covers ALL profiles with no per-profile login.${C_RST}"
  fi
}

# ── launcher shim (the PATH-visible twin of the alias) ────────────────────────
# The alias only exists in interactive shells that source the rc. The shim at
# <config_dir>/bin/<name> is a real executable, so scripts and other shells can
# launch the profile too. The managed rc block prepends that bin
# dir to PATH (guarded, so re-sourcing never duplicates the entry). The marker
# comment below identifies kit-written shims so cleanup NEVER deletes a user file
# that merely shares the name.
AKA_SHIM_MARKER='# aka-claude-tools launcher shim — managed by install.sh; safe to delete with the profile.'

# write_launcher_shim <config_dir> <name> — (re)write the executable shim.
# config_dir has already passed assert_safe_config_dir (no quotes/backslashes/$),
# so embedding it in double quotes is safe — the same reasoning as the alias body.
# A shim left behind by a previous launcher name is NOT swept: its managed rc
# block survives a rename too, so removing one without the other would leave the
# old name half-working. --delete-alias and uninstall.sh remove both together.
# Each step reports what failed: this runs BEFORE the rc is touched, so dying
# here leaves the user's shell config untouched rather than half-configured.
write_launcher_shim() {
  local config_dir="$1" name="$2" shim
  mkdir -p "$config_dir/bin" || die "Cannot create ${config_dir}/bin — your shell rc was NOT modified."
  shim="$config_dir/bin/$name"
  printf '#!/usr/bin/env bash\n%s\nCLAUDE_CONFIG_DIR="%s" exec claude "$@"\n' \
    "$AKA_SHIM_MARKER" "$config_dir" > "$shim" \
    || die "Cannot write the launcher shim at ${shim} — your shell rc was NOT modified."
  chmod +x "$shim" || die "Cannot make ${shim} executable — your shell rc was NOT modified."
}

# launcher_path_representable <config_dir> — PATH is colon-delimited, so a config
# dir containing a colon cannot be expressed as a PATH entry: the shell would
# split it into two entries, one of them RELATIVE (a command-hijack foothold).
# Colons are legal in Unix dir names and assert_safe_config_dir allows them (they
# are inert inside the quoted alias body), so the PATH line is gated here instead.
launcher_path_representable() {
  case "$1" in *:*) return 1 ;; *) return 0 ;; esac
}

# launcher_block_content <config_dir> <name> — the managed rc block body: the
# alias line (uninstall.sh + --enumerate key off its literal CLAUDE_CONFIG_DIR="…")
# plus, when the dir is PATH-representable, a guarded PATH export for the shim
# dir. $PATH is emitted LITERALLY (the rc expands it at source time), which is why
# this builds the text with printf formats rather than interpolating in this shell.
launcher_block_content() {
  local config_dir="$1" name="$2"
  printf "alias %s='CLAUDE_CONFIG_DIR=\"%s\" claude'\n" "$name" "$config_dir"
  launcher_path_representable "$config_dir" || return 0
  printf 'case ":$PATH:" in *":%s/bin:"*) ;; *) export PATH="%s/bin:$PATH" ;; esac' \
    "$config_dir" "$config_dir"
}

# launcher_path_conflict <config_dir> <name> — if <name> already resolves to a
# command in the installer's own environment (a PATH executable, builtin, or
# exported function — rc-file aliases are alias_target_elsewhere's job), print
# the resolution and return 0. The profile's OWN shim is not a conflict (that's
# just a re-run). Claiming a name that is already a command would shadow it in
# every shell the managed block reaches — refuse/warn instead.
launcher_path_conflict() {
  local config_dir="$1" name="$2" resolved
  resolved="$(command -v -- "$name" 2>/dev/null || true)"
  [ -z "$resolved" ] && return 1
  [ "$resolved" = "$config_dir/bin/$name" ] && return 1
  printf '%s\n' "$resolved"
  return 0
}

# ── alias management (the SOLE sanctioned shell-rc writer) ────────────────────
# setup_alias <config_dir> <alias_name> [policy: interactive|strict]
# Reviews the rc + every file it sources (alias_target_elsewhere, cycle-safe) and
# writes/updates an IDEMPOTENT managed block: re-running for the same dir+alias
# REPLACES the block (write_managed_block strips any prior same-id block first),
# so repeated installs/upgrades never accumulate duplicate entries. Keeping this
# in install.sh means the agent invokes it instead of hand-writing the rc, so
# command-guard stay strict. On a name collision (the alias is
# already used for a DIFFERENT target):
#   • interactive → offer an alternate name (default <alias>2), or skip;
#   • strict      → report and return 1 so the caller (the agent) picks another.
# The same policy applies when the name is already a COMMAND on PATH
# (launcher_path_conflict) — the rc scan can't see those. Every successful write
# goes through _write_launcher: managed block (alias + guarded PATH export) +
# the PATH shim + the meta record.

# _write_launcher <rc> <config_dir> <name> — the one write path: managed rc block
# (alias + guarded PATH export), the PATH shim, and the meta record. Idempotent.
_write_launcher() {
  local rc="$1" config_dir="$2" name="$3"
  # Shim first: it can fail on a read-only or full disk, and a failure there must
  # not leave an alias block pointing at a launcher that was never created.
  write_launcher_shim "$config_dir" "$name"
  write_managed_block "$rc" "$name" "$(launcher_block_content "$config_dir" "$name")"
  meta_set "$config_dir" alias "$name"
  ok "Aliased ${C_BOLD}${name}${C_RST} → $config_dir  ${C_DIM}(alias + PATH shim, in $rc)${C_RST}"
  if ! launcher_path_representable "$config_dir"; then
    warn "Folder path contains ':' — no PATH entry was added (a colon would split it into a relative PATH entry)."
    say "  ${C_DIM}The alias works; the shim runs by full path:${C_RST}  ${config_dir}/bin/${name}"
  fi
  say "  ${C_DIM}Open a new shell (or: source $rc), then run:${C_RST}  ${C_BOLD}${name}${C_RST}"
}

# ── deprecated launcher name ─────────────────────────────────────────────────
# `aka` and every `aka-*` name belong to ai-tc's CLI. Profiles installed before the
# rename carry the launcher `aka-claude`; it is migrated to `claude-aka` and kept for
# one release as a forwarder that prints a deprecation line to stderr and runs the
# new launcher with the same arguments.
DEFAULT_LAUNCHER="claude-aka"
DEPRECATED_LAUNCHER="aka-claude"
# Tag line inside the forwarder block. It carries the profile dir as
# CLAUDE_CONFIG_DIR="…", which is what uninstall.sh's prune_blocks keys on, and what
# --delete-alias resolves the profile from (the forwarder alias line has no dir).
DEPRECATED_BLOCK_TAG='# deprecated launcher name; forwards to'

deprecation_notice() { printf '%s is deprecated; use %s' "$1" "$2"; }

# write_deprecated_shim <config_dir> <old> <new> — (re)write <config_dir>/bin/<old>
# as a marked forwarder: one deprecation line to stderr, then exec the <new> shim
# by absolute path with all arguments. Names passed assert_safe_alias_name and the
# dir passed assert_safe_config_dir, so embedding them in quotes is safe.
write_deprecated_shim() {
  local config_dir="$1" old="$2" new="$3" shim
  mkdir -p "$config_dir/bin" || die "Cannot create ${config_dir}/bin — your shell rc was NOT modified."
  shim="$config_dir/bin/$old"
  {
    printf '#!/usr/bin/env bash\n%s\n' "$AKA_SHIM_MARKER"
    printf "printf '%%s\\\\n' '%s' >&2\n" "$(deprecation_notice "$old" "$new")"
    printf 'exec "%s/bin/%s" "$@"\n' "$config_dir" "$new"
  } > "$shim" || die "Cannot write the launcher shim at ${shim} — your shell rc was NOT modified."
  chmod +x "$shim" || die "Cannot make ${shim} executable — your shell rc was NOT modified."
}

# deprecated_block_content <config_dir> <old> <new> — the forwarder's managed rc block
# body. No PATH export: the <new> launcher's block carries it.
deprecated_block_content() {
  local config_dir="$1" old="$2" new="$3" q="'"
  printf '%s\n' "alias ${old}=${q}printf \"%s\\n\" \"$(deprecation_notice "$old" "$new")\" >&2; ${new}${q}"
  printf '%s %s (CLAUDE_CONFIG_DIR="%s")' "$DEPRECATED_BLOCK_TAG" "$new" "$config_dir"
}

# migrate_deprecated_launcher <config_dir> <apply|rerun> [prior_alias]
#   apply — the --apply path: if the recorded launcher is `aka-claude`, write the
#           `claude-aka` launcher (through setup_alias, so every collision gate
#           applies), then turn `aka-claude` into the forwarder.
#   rerun — the interactive/--defaults path, called after setup_alias: if the launcher
#           recorded BEFORE this run was `aka-claude` and this run recorded a new one,
#           turn `aka-claude` into a forwarder to it.
# Idempotent: once migrated the recorded launcher is no longer `aka-claude`, so a
# re-run does nothing. A user-owned `aka-claude` (a shim without the kit marker, or
# an alias defined outside our block) is never overwritten: warn and skip.
migrate_deprecated_launcher() {
  local config_dir="$1" mode="$2" old new rc prior
  case "$mode" in
    apply) old="$(meta_get "$config_dir" alias)" ;;
    *)     old="${3:-}" ;;
  esac
  [ "$old" = "$DEPRECATED_LAUNCHER" ] || return 0
  rc="$(detect_shell_rc)"
  new="$(meta_get "$config_dir" alias)"
  if [ "$mode" = "apply" ]; then
    new="$DEFAULT_LAUNCHER"
    if ! setup_alias "$config_dir" "$new" strict; then
      warn "Could not write the '${new}' launcher, so '${old}' was left as it is."
      return 0
    fi
    meta_set "$config_dir" alias "$new"
  fi
  # rerun with the old name kept, or the alias skipped: nothing to forward to.
  [ -n "$new" ] && [ "$new" != "$old" ] || return 0

  local shim="$config_dir/bin/$old"
  if [ -e "$shim" ] && ! grep -qF "$AKA_SHIM_MARKER" "$shim" 2>/dev/null; then
    warn "${shim} is not a kit launcher shim; left it in place and did not add the '${old}' forwarder."
    return 0
  fi
  prior="$(alias_target_elsewhere "$old" "$rc")"
  if [ -n "$prior" ]; then
    warn "'${old}' is defined elsewhere in your shell config; left it in place and did not add the '${old}' forwarder."
    return 0
  fi
  write_deprecated_shim "$config_dir" "$old" "$new"
  write_managed_block "$rc" "$old" "$(deprecated_block_content "$config_dir" "$old" "$new")"
  meta_set "$config_dir" deprecated_alias "$old"
  warn "$(deprecation_notice "$old" "$new"). '${old}' now forwards to '${new}' and will be removed in a later release."
}

# _launcher_alternate_prompt <rc> <config_dir> <taken_name> — interactive-policy
# fallback when <taken_name> is unavailable (rc-alias collision or PATH command):
# offer an alternate (default <name>2), re-gate it, and refuse to claim an
# alternate that is ALSO a command on PATH (bounded — no re-prompt loop).
_launcher_alternate_prompt() {
  local rc="$1" config_dir="$2" taken="$3" newalias="" clash
  prompt newalias "  Use a different alias (blank = skip the alias entirely):" "${taken}2"
  if [ -n "$newalias" ]; then
    assert_safe_alias_name "$newalias"   # the prompted name is user input → re-gate it
    if clash="$(launcher_path_conflict "$config_dir" "$newalias")"; then
      warn "'${newalias}' is also a command on your PATH (${clash}) — not claiming it."
      say "  ${C_DIM}No alias written. Pick a free name and re-run, or launch with:${C_RST}  CLAUDE_CONFIG_DIR=\"${config_dir}\" claude"
      return 0
    fi
    _write_launcher "$rc" "$config_dir" "$newalias"
  else
    say "  ${C_DIM}No alias written. Launch this profile with:${C_RST}  CLAUDE_CONFIG_DIR=\"${config_dir}\" claude"
  fi
}

setup_alias() {
  local config_dir="$1" alias_name="$2" policy="${3:-interactive}"
  # Fail closed BEFORE touching the rc (assert_safe_* live in common.sh).
  assert_safe_alias_name "$alias_name"
  assert_safe_config_dir "$config_dir"
  local rc; rc="$(detect_shell_rc)"
  local prior; prior="$(alias_target_elsewhere "$alias_name" "$rc")"
  if [ "$prior" = "$config_dir" ]; then
    # Already resolves to THIS profile from elsewhere (e.g. a fleet aliases file) →
    # ensure a SINGLE definition: drop any stale managed block of ours, else it's a dup.
    # Still (re)write the shim so an idempotent re-run repairs a deleted one; the
    # PATH line may be absent here (the user hand-manages their own rc definition),
    # which is acceptable — the shim still works by absolute path.
    write_launcher_shim "$config_dir" "$alias_name"
    if remove_managed_block "$rc" "$alias_name"; then
      ok "Alias ${C_BOLD}${alias_name}${C_RST} already resolves to this profile via your shell config — removed our now-redundant block."
    else
      ok "Alias ${C_BOLD}${alias_name}${C_RST} already resolves to this profile — not adding a duplicate."
    fi
    say "  ${C_DIM}Open a new shell (or: source $rc), then run:${C_RST}  ${C_BOLD}${alias_name}${C_RST}"
    return 0
  elif [ -n "$prior" ]; then
    if [ "$prior" = "OTHER" ]; then
      warn "'${alias_name}' is already an alias in your shell (not a Claude-config launcher)."
    else
      warn "Alias '${alias_name}' already exists and points to: ${prior}"
      say  "  ${C_DIM}(from your shell rc or a file it sources — not this profile).${C_RST}"
    fi
    if [ "$policy" = "strict" ]; then
      # The caller (the agent) owns the choice of a new name — don't guess one here.
      say "  ${C_DIM}Pick another alias and re-run, or launch with:${C_RST}  CLAUDE_CONFIG_DIR=\"${config_dir}\" claude"
      return 1
    fi
    _launcher_alternate_prompt "$rc" "$config_dir" "$alias_name"
    return 0
  fi
  # No rc-alias collision — but the name may be a COMMAND on PATH (the rc scan
  # can't see those). Claiming it would shadow that command via both the alias
  # and the PATH shim, so refuse (strict) / offer an alternate (interactive).
  local clash
  if clash="$(launcher_path_conflict "$config_dir" "$alias_name")"; then
    warn "'${alias_name}' is already a command on your PATH (${clash})."
    if [ "$alias_name" = "aka" ]; then
      say "  ${C_DIM}'aka' and every 'aka-*' name belong to the AI Traffic Control CLI. Keep the default 'claude-aka' launcher name instead.${C_RST}"
    fi
    if [ "$policy" = "strict" ]; then
      say "  ${C_DIM}Pick another launcher name and re-run, or launch with:${C_RST}  CLAUDE_CONFIG_DIR=\"${config_dir}\" claude"
      return 1
    fi
    _launcher_alternate_prompt "$rc" "$config_dir" "$alias_name"
    return 0
  fi
  _write_launcher "$rc" "$config_dir" "$alias_name"
  return 0
}

# ── ai-tc offer (the security-depth handoff) ─────────────────────────────────
# claude-tools ships POSTURE: structural command safety (command-guard) and
# credential deny rules (secure-settings), plus a THIN secret-scan fallback
# (leak-guard / command-guard's exfil tier: pattern + trufflehog shapes only). It
# deliberately does NOT do deep content detection: PII, PHI, cardholder data,
# redaction, or an audit trail. That is ai-tc's job, and the two are meant to
# compose: safe defaults here, the detection engine there. Once the profiles are
# built, name that boundary and offer ai-tc with a prompt (opt-in, default yes).
# We can only POINT, not install: ai-tc is a Claude Code marketplace plugin added
# with a slash command inside a session, which a shell script cannot run (and
# command-guard would block a pipe-to-shell bootstrap anyway), so an accept prints
# the commands to run. Under --defaults the confirm takes its default (yes) without
# blocking. Silent when ai-tc is already present, so a re-run does not nag.
# aitc_present [config_dir] — ai-tc installed AND enabled, per guard-core's detectAitc
# (one detection rule shared by the installer here and the hooks' run-time deferral
# in command-guard, leak-guard and rtk-safe). With a config dir, checks that one profile (used by the statusline
# skip and the stash guard, which must agree on the SAME profile being installed).
# Without one, checks the default profile and every ~/.claude-* profile (used by
# offer_aitc, which is a global "don't nag" check, not tied to one target dir).
# Fails safe: no bun, or the core unreadable, counts as absent — a detection outage
# must never block the install or silently swallow the kit's own statusline/offer.
aitc_present() {
  local core="$CONFIG_SRC/hooks/lib/guard-core.js" d
  dep_usable bun || return 1
  if [ -n "${1:-}" ]; then
    [ "$(bun "$REPO_DIR/shared/lib/aitc-status.ts" "$core" "$1" 2>/dev/null)" = present ]; return
  fi
  for d in "$HOME/.claude" "$HOME"/.claude-*; do
    [ -d "$d" ] || continue
    [ "$(bun "$REPO_DIR/shared/lib/aitc-status.ts" "$core" "$d" 2>/dev/null)" = present ] && return 0
  done
  return 1
}

offer_aitc() {
  aitc_present && return 0   # already deep; nothing to offer

  say ""
  hr
  say "${C_BOLD}Security depth.${C_RST} claude-tools installed safe defaults and a shallow"
  say "secret scan. It does not detect PII, PHI, or cardholder data, and it does not"
  say "redact. ${C_GRN}ai-tc${C_RST} is the AKA detection engine that does: 101 rules across secrets,"
  say "PII, PHI, and financial data, with redaction and an audit trail, running locally."

  if confirm "Show how to add ai-tc?" "Y"; then
    say ""
    say "  In Claude Code, run:"
    say "    ${C_GRN}/plugin marketplace add akasecurity/marketplace${C_RST}"
    say "    ${C_GRN}/plugin install ai-tc@akasecurity${C_RST}"
    say "    ${C_GRN}/aka:setup${C_RST}"
    say "  ${C_DIM}Docs: https://akasecurity.github.io/ai-tc-docs/${C_RST}"
  else
    say "  ${C_DIM}Later, in Claude Code: /plugin install ai-tc@akasecurity${C_RST}"
  fi
}

# setup_one_config — the standalone interactive (or --defaults) fresh install:
# pick a dir + additions, layer them (apply_additions), inherit auth, write the
# alias. Migrating a rich existing config and backing-up-and-rebuilding are owned
# by Path A (agent-install.md) — see the file header; targeting an existing dir
# here simply layers on top.
setup_one_config() {
  hr
  # 1. target config dir.
  local config_dir
  isay "${C_DIM}Tip: set CT_CONFIG_DIR + CT_ADDITIONS (or use --apply) to run non-interactively.${C_RST}"
  prompt config_dir "Config folder to create/update:" "${CT_CONFIG_DIR:-$HOME/.claude-aka}"
  config_dir="${config_dir/#\~/$HOME}"
  # Normalize: strip a trailing slash, and make a relative path absolute so the alias
  # + hook command strings bind to a stable location, not the cwd. Leave "/" alone.
  [ "$config_dir" != "/" ] && config_dir="${config_dir%/}"
  case "$config_dir" in /*) ;; *) config_dir="$PWD/$config_dir" ;; esac
  # Reject an unsafe dir HERE, before any profile files are written — setup_alias (step 5)
  # re-checks, but failing early avoids leaving a populated profile dir with no alias.
  assert_safe_config_dir "$config_dir"
  # The default ~/.claude needs no alias (plain `claude` launches it).
  local is_default=0
  [ "$config_dir" = "$HOME/.claude" ] && is_default=1

  # Footgun heads-up: ~/.claude is the LIVE default profile, not an isolated one. The kit
  # is additive/reversible (so this isn't the un-bypassable refusal uninstall uses), but
  # it must never modify the default profile SILENTLY — warn always, and confirm when a
  # human is present. (Mirrors uninstall.sh's default-dir guard on the install side.)
  if [ "$is_default" = "1" ]; then
    warn "~/.claude is your DEFAULT Claude Code config — the kit will layer onto your LIVE default profile (it normally creates an isolated one)."
    if [ "${CT_NONINTERACTIVE:-0}" != "1" ]; then
      confirm "  Modify your default ~/.claude profile?" "N" || die "Aborted — re-run with a different folder for an isolated profile."
    fi
  fi

  # 2. alias name (default derived from folder basename: ~/.claude-work -> work).
  local alias_name=""
  if [ "$is_default" != "1" ]; then
    local base alias_default
    base="$(basename "$config_dir")"
    alias_default="${base#.claude-}"; [ "$alias_default" = "$base" ] && alias_default="aka"
    [ -z "$alias_default" ] && alias_default="aka"
    # Bare `aka` and every `aka-*` name belong to ai-tc's CLI. This kit's launcher for
    # ~/.claude-aka (and the fallback) is `claude-aka`.
    [ "$alias_default" = "aka" ] && alias_default="$DEFAULT_LAUNCHER"
    prompt alias_name "Shell alias to launch it:" "$alias_default"
  fi
  # The launcher this profile had before this run, for migrate_deprecated_launcher.
  local prior_alias=""
  [ "$is_default" != "1" ] && prior_alias="$(meta_get "$config_dir" alias)"

  # 3. layer the additions (the deterministic engine).
  apply_additions "$config_dir"

  # 4. inherit auth so the engineer doesn't re-onboard / re-login. The default
  # profile needs none: its ~/.claude.json lives at $HOME, not in the config dir.
  if [ "$SEED_AUTH" = "1" ] && [ "$is_default" != "1" ]; then
    seed_auth "$config_dir" "$alias_name"
  fi

  # 5. alias to the shell rc (the default dir needs none — plain `claude`).
  if [ "$is_default" = "1" ]; then
    say ""
    ok "Default config ~/.claude ready — plain ${C_BOLD}claude${C_RST} launches it."
    say "  ${C_DIM}Restart claude to load it — a running session keeps the old config in memory.${C_RST}"
  else
    say ""
    setup_alias "$config_dir" "$alias_name" interactive
    migrate_deprecated_launcher "$config_dir" rerun "$prior_alias"
  fi
}

# compile_org_sidecar <config_dir> — compile the user's CT_EGRESS_PATTERNS from the
# shell config into the inert JSON sidecar that BOTH egress guards read at runtime,
# so no hook ever sources arbitrary shell. install.sh is the one-shot installer and
# may safely evaluate the user's own config; the runtime hooks may not. Validated +
# atomically published.
compile_org_sidecar() {
  local config_dir="$1"
  local cfg="$config_dir/aka-claude-tools.config"
  local sidecar="$config_dir/hooks/lib/org-egress.json"
  [ -f "$cfg" ] || return 0                 # no config → no sidecar (org tier inactive)
  [ -d "$config_dir/hooks/lib" ] || return 0 # lib not placed (no egress guard) — defensive

  # Extract CT_EGRESS_PATTERNS by sourcing the config in a SUBSHELL (set +eu so the
  # user's file can't trip our strict mode). The value never re-enters install's env.
  local pat="" _src_rc=0
  pat="$( set +eu; . "$cfg" >/dev/null 2>&1; _rc=$?; printf '%s' "${CT_EGRESS_PATTERNS:-}"; exit "$_rc" )" || _src_rc=$?
  if [ "$_src_rc" -ne 0 ]; then
    # Sourcing the config failed. Never silently disable the org tier, but tell the truth
    # about what actually happened — the message differs by whether a pattern survived:
    if [ -z "$pat" ]; then
      # Nothing compiled (e.g. a syntax error before any assignment) — the tier is OFF.
      warn "aka-claude-tools.config could not be sourced (exit $_src_rc) — org-egress patterns NOT compiled; the org-marker tier is INACTIVE until you fix the config and re-run ./install.sh."
    else
      # A pattern WAS set before the failure — the tier compiles with it, but part of the
      # config did not run. Surface it (never hide a real source error) without the
      # misleading "inactive" claim.
      warn "aka-claude-tools.config sourced with an error (exit $_src_rc) — a pattern was set and compiled, but part of the config did not run. Review the config and re-run ./install.sh."
    fi
  fi

  if [ -n "$pat" ]; then
    case "$pat" in
      *$'\n'*) die "CT_EGRESS_PATTERNS in $cfg must be a single line (multiline patterns are rejected)." ;;
    esac
    # STRICT portable-subset validator. Both runtime consumers are now JS RegExp
    # (leak-guard.ts for web egress, command-guard.ts for Bash), so the pattern no longer
    # crosses a grep-vs-JS engine boundary at runtime. The portable-subset check is kept as
    # a conservative input contract: the installer ALSO compiles the pattern as a POSIX ERE
    # via grep -E (below) as a defense-in-depth syntax check, and the subset is exactly where
    # grep -E and JS RegExp agree — so rejecting the known divergent classes keeps a pattern
    # that passes the grep compile check from behaving differently in the JS guards (and
    # matches the co-validity caveat secret-patterns.json documents: use [0-9A-Za-z],
    # not \d/\s):
    #   \\[0-9A-Za-z]  backslash shorthand/backref — \d \w \s \b … and \1 backrefs
    #   \<  \>         GNU word boundaries (live in grep, not JS)
    #   [[:            POSIX classes ([[:alpha:]] …)
    #   (?             lookaround / non-capturing groups
    # \. \( \| etc. (backslash + a non-alphanumeric, non-angle metachar) are fine.
    if printf '%s' "$pat" | grep -qE '\\[0-9A-Za-z<>]|\[\[:|\(\?'; then
      die "CT_EGRESS_PATTERNS in $cfg uses a non-portable regex construct (a \\d/\\w/\\s/\\b shorthand or \\N backref, a \\<\\> word boundary, a POSIX class [[:…:]], or lookaround/(?…)). The installer compiles the pattern as a POSIX ERE (grep -E) as a syntax check; these constructs behave differently in grep -E vs JavaScript (the engine the guards run), so they're rejected to keep the input in the subset where both agree. Use the portable subset — e.g. [0-9] not \\d, [A-Za-z] not \\w. Fix it, then re-run."
    fi
    # Defense-in-depth: must still actually COMPILE as a POSIX ERE (catch unbalanced
    # parens etc.). grep -E exits 2 on a bad pattern; capture it (set -e safe).
    local _v=0; printf '' | grep -qE -- "$pat" 2>/dev/null || _v=$?
    [ "$_v" -gt 1 ] && die "CT_EGRESS_PATTERNS in $cfg is not a valid POSIX ERE (grep -E rejects it). Fix it, then re-run."
    # And as a JS RegExp, when bun is present (the JS consumer). The portable subset is
    # JS-valid by construction, so this only catches malformed patterns.
    if dep_usable bun; then
      bun -e 'try{new RegExp(process.argv[1])}catch(e){console.error(String(e));process.exit(1)}' "$pat" 2>/dev/null \
        || die "CT_EGRESS_PATTERNS in $cfg is not a valid JavaScript RegExp (command-guard could not compile it). Fix it, then re-run."
    fi
  fi

  # sourceHash lets BOTH guards warn when the config drifts post-install. Hash the RAW
  # config FILE BYTES — the byte domain both guards re-hash via bun's createHash (NOT the
  # shell-expanded value). Computed here with a PORTABLE sha256 (the installer is bash, so
  # it never shells out to bun for this); sha256 hex is implementation-independent, so this
  # equals the guards' bun createHash over the same bytes.
  local hash=""
  hash="$(sha256_file "$cfg" 2>/dev/null || true)"

  # Atomic publish: temp + rename, so a concurrent hook never reads a partial file.
  local tmp="$sidecar.tmp.$$"
  jq -n --arg p "$pat" --arg h "$hash" '{pattern:$p, sourceHash:$h}' > "$tmp" && mv -f "$tmp" "$sidecar"
  if [ -n "$pat" ]; then ok "Compiled org-egress sidecar (CT_EGRESS_PATTERNS active)";
  else ok "Compiled org-egress sidecar (no org patterns set — tier inactive)"; fi
}

# _mcp_server_name_to_json <key> <cfg> <name> — validate ONE MCP server name against
# the portable identifier subset (^[A-Za-z0-9_-]+$) for compile_mcp_policy_sidecar.
# die()s naming <key> (never a bare "invalid input") on anything else, including a
# blank entry from a stray/leading/trailing comma. Prints the name back on success —
# call sites build the JSON array with jq -R/-s so no shell-side quoting is needed.
_mcp_server_name_to_json() {
  local key="$1" cfg="$2" name="$3"
  case "$name" in
    ''|*[!A-Za-z0-9_-]*) die "$key in $cfg has an invalid server name \"$name\" (must match ^[A-Za-z0-9_-]+\$)." ;;
  esac
  printf '%s\n' "$name"
}

# compile_mcp_policy_sidecar <config_dir> — compile CT_MCP_ALLOW / CT_MCP_DENY (each a
# comma-separated list of MCP server names) into hooks/lib/mcp-policy.json, the sidecar
# mcp-guard reads at runtime. Owned by mcp-guard alone: compiled only when mcp-guard is
# selected and removed when it is deselected; see the call site and cleanup below.
# Modeled exactly on compile_org_sidecar: subshell-source, validate, atomic publish.
compile_mcp_policy_sidecar() {
  local config_dir="$1"
  local cfg="$config_dir/aka-claude-tools.config"
  local sidecar="$config_dir/hooks/lib/mcp-policy.json"
  [ -f "$cfg" ] || return 0
  [ -d "$config_dir/hooks/lib" ] || return 0

  # Source the config in a SUBSHELL (set +eu) exactly like compile_org_sidecar, and
  # smuggle BOTH values out over one command substitution using \x1f (a byte that
  # can never survive the name validation below, so it's a safe internal separator).
  local raw="" _src_rc=0
  raw="$( set +eu; . "$cfg" >/dev/null 2>&1; _rc=$?; printf '%s\x1f%s' "${CT_MCP_ALLOW:-}" "${CT_MCP_DENY:-}"; exit "$_rc" )" || _src_rc=$?
  local allow_raw="${raw%%$'\x1f'*}" deny_raw="${raw#*$'\x1f'}"
  # Mirror compile_org_sidecar's two-branch warning EXACTLY: warn on every source
  # failure, not just one where a value happened to already be captured — a config
  # that errors before CT_MCP_ALLOW/CT_MCP_DENY are ever reached must not compile a
  # silently-empty (fail-open) sidecar with no signal.
  if [ "$_src_rc" -ne 0 ]; then
    if [ -z "$allow_raw" ] && [ -z "$deny_raw" ]; then
      warn "aka-claude-tools.config could not be sourced (exit $_src_rc) — CT_MCP_ALLOW/CT_MCP_DENY NOT compiled; the MCP policy tier is INACTIVE until you fix the config and re-run ./install.sh."
    else
      warn "aka-claude-tools.config sourced with an error (exit $_src_rc) — a CT_MCP_ALLOW/CT_MCP_DENY value was set and compiled, but part of the config did not run. Review the config and re-run ./install.sh."
    fi
  fi
  case "$allow_raw" in *$'\n'*) die "CT_MCP_ALLOW in $cfg must be a single line (multiline values are rejected)." ;; esac
  case "$deny_raw"  in *$'\n'*) die "CT_MCP_DENY in $cfg must be a single line (multiline values are rejected)." ;; esac

  local allow_json="[]" deny_json="[]"
  if [ -n "$allow_raw" ]; then
    # A leading/trailing/doubled comma splits to an EMPTY array element under most
    # IFS splits, but bash's word splitting drops a *trailing* empty field outright
    # (matching plain IFS-whitespace behavior) — so a trailing comma would silently
    # vanish instead of reaching _mcp_server_name_to_json's blank-entry check below.
    # Catch all three shapes here, in the raw string, before that field loss can happen.
    case "$allow_raw" in
      ,*|*,|*,,*) die "CT_MCP_ALLOW in $cfg has an empty entry (a leading, trailing, or doubled comma)." ;;
    esac
    local IFS=,; set -f; local -a _names=($allow_raw); set +f; unset IFS
    local n; local -a _out=()
    for n in "${_names[@]}"; do _out+=("$(_mcp_server_name_to_json "CT_MCP_ALLOW" "$cfg" "$n")"); done
    allow_json="$(printf '%s\n' "${_out[@]}" | jq -R . | jq -s -c .)"
  fi
  if [ -n "$deny_raw" ]; then
    case "$deny_raw" in
      ,*|*,|*,,*) die "CT_MCP_DENY in $cfg has an empty entry (a leading, trailing, or doubled comma)." ;;
    esac
    local IFS=,; set -f; local -a _names=($deny_raw); set +f; unset IFS
    local n; local -a _out=()
    for n in "${_names[@]}"; do _out+=("$(_mcp_server_name_to_json "CT_MCP_DENY" "$cfg" "$n")"); done
    deny_json="$(printf '%s\n' "${_out[@]}" | jq -R . | jq -s -c .)"
  fi

  # sourceHash: same portable sha256-over-raw-bytes as compile_org_sidecar, so
  # mcp-guard can re-derive it with bun's createHash over the identical bytes.
  local hash=""
  hash="$(sha256_file "$cfg" 2>/dev/null || true)"

  local tmp="$sidecar.tmp.$$"
  jq -n --argjson a "$allow_json" --argjson d "$deny_json" --arg h "$hash" \
    '{allow:$a, deny:$d, sourceHash:$h}' > "$tmp" && mv -f "$tmp" "$sidecar"
  if [ -n "$allow_raw$deny_raw" ]; then ok "Compiled MCP policy sidecar (CT_MCP_ALLOW/CT_MCP_DENY active)";
  else ok "Compiled MCP policy sidecar (no MCP policy set — inactive)"; fi
}

# _bootstrap_url_to_rule <key> <cfg> <url> — validate ONE trusted-bootstrap URL for
# compile_bootstrap_sidecar and print back "<lowercased-host>\t<path>" on success.
# die()s naming <key>, never a bare "invalid input", on any violation:
#   - must be https://, with a non-empty host and a path
#   - path must end in / (a prefix, not a specific file)
#   - no userinfo (@) and no port (:) in the authority
#   - none of ?#{}[]\ or any whitespace anywhere in the URL
#   - host limited to the portable hostname subset ([A-Za-z0-9.-]+), lowercased for
#     the sidecar since hostnames are case-insensitive
_bootstrap_url_to_rule() {
  local key="$1" cfg="$2" url="$3"
  case "$url" in
    *[\?\#\{\}\[\]\\]*|*[[:space:]]*)
      die "$key in $cfg has an invalid URL \"$url\" (must not contain ?, #, {, }, [, ], \\, or whitespace)." ;;
  esac
  case "$url" in
    https://?*) ;;
    *) die "$key in $cfg has an invalid URL \"$url\" (must start with https:// and name a host)." ;;
  esac
  local rest="${url#https://}"
  case "$rest" in
    */*) ;;
    *) die "$key in $cfg has an invalid URL \"$url\" (missing a path — must end in /)." ;;
  esac
  case "$url" in
    */) ;;
    *) die "$key in $cfg has an invalid URL \"$url\" (path must end in /)." ;;
  esac
  local authority="${rest%%/*}" path="/${rest#*/}"
  case "$authority" in
    *@*) die "$key in $cfg has an invalid URL \"$url\" (userinfo (@) in the host is not allowed)." ;;
  esac
  case "$authority" in
    *:*) die "$key in $cfg has an invalid URL \"$url\" (a port in the host is not allowed)." ;;
  esac
  case "$authority" in
    ''|*[!A-Za-z0-9.-]*) die "$key in $cfg has an invalid URL \"$url\" (host has invalid characters)." ;;
  esac
  local host_lc
  host_lc="$(printf '%s' "$authority" | tr 'A-Z' 'a-z')"
  printf '%s\t%s' "$host_lc" "$path"
}

# compile_bootstrap_sidecar <config_dir> — compile CT_TRUSTED_BOOTSTRAP_URLS (a
# space-separated allowlist of installer-script URLs) into
# hooks/lib/trusted-bootstrap.json, the sidecar command-guard reads at runtime.
# Modeled exactly on compile_org_sidecar: subshell-source, validate, atomic publish.
# Owned by command-guard alone (unlike the shared egress libs above) — placed and
# removed with command-guard specifically; see the call site and cleanup below.
compile_bootstrap_sidecar() {
  local config_dir="$1"
  local cfg="$config_dir/aka-claude-tools.config"
  local sidecar="$config_dir/hooks/lib/trusted-bootstrap.json"
  [ -f "$cfg" ] || return 0
  [ -d "$config_dir/hooks/lib" ] || return 0

  local raw="" _src_rc=0
  raw="$( set +eu; . "$cfg" >/dev/null 2>&1; _rc=$?; printf '%s' "${CT_TRUSTED_BOOTSTRAP_URLS:-}"; exit "$_rc" )" || _src_rc=$?
  # Mirror compile_org_sidecar's two-branch warning EXACTLY: warn on every source
  # failure, not just one where a value happened to already be captured — a config
  # that errors before CT_TRUSTED_BOOTSTRAP_URLS is ever reached must not compile a
  # silently-empty (fail-open) sidecar with no signal.
  if [ "$_src_rc" -ne 0 ]; then
    if [ -z "$raw" ]; then
      warn "aka-claude-tools.config could not be sourced (exit $_src_rc) — CT_TRUSTED_BOOTSTRAP_URLS NOT compiled; the trusted-bootstrap tier is INACTIVE until you fix the config and re-run ./install.sh."
    else
      warn "aka-claude-tools.config sourced with an error (exit $_src_rc) — CT_TRUSTED_BOOTSTRAP_URLS was set and compiled, but part of the config did not run. Review the config and re-run ./install.sh."
    fi
  fi
  case "$raw" in *$'\n'*) die "CT_TRUSTED_BOOTSTRAP_URLS in $cfg must be a single line (multiline values are rejected)." ;; esac

  local rules_json="[]"
  if [ -n "$raw" ]; then
    set -f; local -a _urls=($raw); set +f   # default IFS: space/tab; no globbing
    local u pair host path
    local -a _entries=()
    for u in "${_urls[@]}"; do
      pair="$(_bootstrap_url_to_rule "CT_TRUSTED_BOOTSTRAP_URLS" "$cfg" "$u")"
      host="${pair%%$'\t'*}"; path="${pair#*$'\t'}"
      _entries+=("$(jq -nc --arg h "$host" --arg p "$path" '{host:$h, pathPrefix:$p}')")
    done
    [ "${#_entries[@]}" -gt 0 ] && rules_json="$(printf '%s\n' "${_entries[@]}" | jq -s -c .)"
  fi

  local hash=""
  hash="$(sha256_file "$cfg" 2>/dev/null || true)"

  local tmp="$sidecar.tmp.$$"
  jq -n --argjson r "$rules_json" --arg h "$hash" '{rules:$r, sourceHash:$h}' > "$tmp" && mv -f "$tmp" "$sidecar"
  if [ -n "$raw" ]; then ok "Compiled trusted-bootstrap sidecar (CT_TRUSTED_BOOTSTRAP_URLS active)";
  else ok "Compiled trusted-bootstrap sidecar (no trusted bootstrap URLs set — inactive)"; fi
}

# meta_set <config_dir> <key> <value>  — upsert key=value into
# <config_dir>/.aka-claude-tools-meta, creating the file if absent and preserving
# any other key lines. This file MARKS a profile as aka-claude-tools-managed
# (the agent-install Step-1 detection signal). Stamped by --apply (managed=…) so
# EVERY kit-installed profile is detectable, even a minimal selection that registers
# none of the recognizable kit hooks; updated by --alias (alias=…). set -e safe.
meta_set() {
  local dir="$1" key="$2" val="$3"
  local f="$dir/.aka-claude-tools-meta" tmp
  # Already recorded with this value: leave the file byte-identical.
  [ -f "$f" ] && [ "$(grep -E "^${key}=" "$f" 2>/dev/null | tail -1)" = "${key}=${val}" ] && return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/aka-meta.XXXXXX" 2>/dev/null)" || return 0
  if [ -f "$f" ]; then grep -vE "^${key}=" "$f" 2>/dev/null > "$tmp" || true; fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
}

# meta_get <config_dir> <key> — print the recorded value for <key> from
# <config_dir>/.aka-claude-tools-meta (last line wins), or nothing. set -e safe.
meta_get() {
  local f="$1/.aka-claude-tools-meta"
  [ -f "$f" ] || return 0
  { grep -E "^${2}=" "$f" 2>/dev/null || true; } | tail -1 | cut -d= -f2-
}

# ── deterministic engine: layer additions onto a config dir ──────────────────
# apply_additions <config_dir>  — place the selected additions (CT_ADDITIONS) and
# merge their settings onto whatever already lives in <config_dir> (incl. a
# settings.json the agent migrated in first). No prompts, no migration, no alias,
# no auth: Path A (the agent) owns that judgment and calls this for the repeatable
# mechanics; the standalone installer calls it after its interactive preamble.
# Honors CT_NONINTERACTIVE (reconcile + statusline-location take their
# non-interactive defaults). Reusable entry point for the --apply mode.
apply_additions() {
  local config_dir="$1"
  # 4. select additions — the menu (which additions exist, their order, prompt
  # text, and default) is driven ENTIRELY by config/additions.json so Path B
  # (this script) and Path A (agent-install.md) can't drift. Each addition's
  # bespoke build logic below is keyed on its id via is_selected.
  local _sel_ids=" " _aid _arec _aprompt _adef
  if [ -n "${CT_ADDITIONS+x}" ]; then
    # Non-interactive explicit selection. $CT_ADDITIONS is a space-separated list of
    # addition ids; install EXACTLY those (an empty value selects none) and skip the
    # menu. Each id is validated against the manifest so a typo fails loudly instead
    # of silently dropping an addition. Used by scriptable installs and the test
    # suite (the menu reads /dev/tty, so answers can't be piped in).
    local _known _i _want=()
    _known="$(jq -r '.additions[].id' "$CONFIG_SRC/additions.json")"
    read -ra _want <<<"$CT_ADDITIONS"
    for ((_i=0; _i<${#_want[@]}; _i++)); do
      _aid="${_want[$_i]}"
      [ -z "$_aid" ] && continue
      printf '%s\n' "$_known" | grep -qxF -- "$_aid" || die "CT_ADDITIONS: unknown addition id: $_aid"
      _sel_ids="${_sel_ids}${_aid} "
    done
    isay "  ${C_DIM}Additions from \$CT_ADDITIONS:${C_RST}${_sel_ids}"
  else
    isay ""
    isay "Additions to layer on ${C_DIM}(Enter = default):${C_RST}"
    while IFS=$'\t' read -r _aid _arec _aprompt; do
      [ -z "$_aid" ] && continue
      if [ "$_arec" = "true" ]; then _adef="Y"; else _adef="N"; fi
      if confirm "  • ${_aprompt}" "$_adef"; then _sel_ids="${_sel_ids}${_aid} "; fi
    done < <(jq -r '.additions[] | [.id, (.recommended|tostring), (.prompt // .name)] | @tsv' "$CONFIG_SRC/additions.json")
  fi

  # ── egress coupling check (runs BEFORE any write) ──
  # leak-guard guards WEB egress only; Bash egress is command-guard's surface. The id
  # 'leak-guard' USED to also cover Bash. The critical case (cross-check) is the UPGRADE
  # TRANSITION: an existing profile whose leak-guard was registered on the Bash matcher,
  # re-installed WITHOUT command-guard, would SILENTLY lose Bash egress coverage. Detect
  # exactly that transition and ABORT (unless CT_ALLOW_UNGUARDED_BASH=1 acks web-only).
  # A FRESH web-only install (no prior leak-guard-on-Bash) is a legitimate intentional
  # choice — WARN, don't die. So the loud-fail targets the silent COVERAGE CHANGE, not
  # every standalone-leak-guard selection.
  if is_selected leak-guard "$_sel_ids" && ! is_selected command-guard "$_sel_ids" \
     && [ "${CT_ALLOW_UNGUARDED_BASH:-0}" != "1" ]; then
    if [ -f "$config_dir/settings.json" ] && jq -e '
          [ .hooks.PreToolUse[]? | select(.matcher=="Bash")
            | .hooks[]?.command // empty | select(endswith("/leak-guard.sh")) ] | length > 0
        ' "$config_dir/settings.json" >/dev/null 2>&1; then
      die "Upgrade would SILENTLY drop Bash egress coverage: this profile's leak-guard previously guarded Bash, but leak-guard is now WEB-only and command-guard (Bash egress) is not in your selection. Add command-guard, or set CT_ALLOW_UNGUARDED_BASH=1 to accept web-only."
    fi
    warn "⚠ leak-guard guards WEB egress only; command-guard (Bash egress) is not selected — your Bash egress is UNGUARDED. Add command-guard to guard outbound Bash commands."
  fi

  # ── hard-dependency gate ──
  # Runs AFTER selection is known but BEFORE any dir/payload/rc write, so a missing
  # required runtime aborts cleanly with no partial apply (in interactive mode the
  # profile dir isn't created until the build mkdir below; --apply pre-creates an
  # empty dir at apply_entry, which is benign — no settings/payload/rc are written).
  # command-guard, leak-guard and mcp-guard are default-on SECURITY hooks whose runtime
  # is bun; shipping one silently disabled is not an option, so a missing bun ABORTS rather
  # than soft-skips. The statusline, rtk-safe and prompt-guard are .ts hooks that also
  # cannot run without bun (they can't degrade like the old bash versions), so bun is
  # required when ANY of the six is selected — a selection with none still installs.
  # prompt-guard is opt-in and warn-only at RUNTIME, but at INSTALL time it needs the same
  # gate as the others: the registration below embeds bun's resolved absolute path, and
  # there is no such path to embed without bun present. ensure_dep offers to install bun
  # first (interactive); it die()s only on decline / non-interactive-absent, so a partial
  # apply is impossible.
  if is_selected command-guard "$_sel_ids" || is_selected leak-guard "$_sel_ids" \
     || is_selected mcp-guard "$_sel_ids" || is_selected prompt-guard "$_sel_ids" \
     || is_selected statusline "$_sel_ids" || is_selected rtk-safe "$_sel_ids"; then
    ensure_dep bun "bun — required runtime for command-guard, leak-guard, mcp-guard, prompt-guard, statusline, and/or rtk-safe" 1
    # Warn ONCE per run (not once per hook below) when the bun about to be baked into
    # every selected hook's absolute path is the one npm installed alongside THIS
    # package (its own node_modules, or the hoisted ../../.bin one level up), not a
    # system bun. That absolute path stops resolving the moment the npm package is
    # removed or moved (`npm uninstall -g` / `npm update -g`): the hook then exits 127,
    # which Claude Code treats as "hook errored", not "guard blocked" — command-guard
    # silently stops guarding rather than failing loudly. See uninstall.sh docs.
    local _bun_bin; _bun_bin="$(command -v bun)"
    case "$_bun_bin" in
      "$REPO_DIR"/node_modules/*|"$REPO_DIR"/../../.bin/*)
        warn "hooks will run on the bun bundled with this npm package ($_bun_bin), not a system bun. Before removing or moving @akasecurity/claude-tools, run this kit's uninstall first — or install a system bun and re-run the installer — otherwise the hooks silently stop guarding." ;;
    esac
  fi

  # ── build ──
  mkdir -p "$config_dir/hooks" "$config_dir/commands" "$config_dir/workflows"

  # 4b. assemble additions object
  local add='{}'
  # Claude Code runs a hook's `command` through a shell, so a config dir containing
  # spaces or shell metachars would word-split / mis-parse the registered path.
  # cfg_token() yields the DIRECTORY portion (cqd) shell-safely AND host-portably: a
  # $HOME-relative dir becomes  $HOME'<rest>'  (unquoted $HOME so each host's shell
  # expands it, remainder quoted), so the written command carries no absolute /Users
  # literal; a non-$HOME dir stays the fully-quoted absolute form. Either way the
  # `/hooks/<file>` suffix stays outside the quotes, so the command still ends with the
  # literal "/hooks/<file>" the prune/registration checks anchor on (… endswith "/x.ts").
  # config_dir is already absolute + $HOME-expanded here.
  local cqd; cqd="$(cfg_token "$config_dir")"
  is_selected secure-settings "$_sel_ids" && add="$(jq -s '.[0] * .[1]' <(printf '%s' "$add") "$CONFIG_SRC/settings.base.json")"
  # Opt-in nonessential-traffic opt-outs, each an independent env toggle. Kept OUT of
  # the secure base because DISABLE_TELEMETRY=1 disables Claude Code's Remote Control;
  # a user picks whichever they want. Deep merge (`*`) unions each .env onto the rest.
  is_selected telemetry-off        "$_sel_ids" && add="$(jq -s '.[0] * .[1]' <(printf '%s' "$add") "$CONFIG_SRC/settings.telemetry-off.json")"
  is_selected error-reporting-off  "$_sel_ids" && add="$(jq -s '.[0] * .[1]' <(printf '%s' "$add") "$CONFIG_SRC/settings.error-reporting-off.json")"
  is_selected feedback-off         "$_sel_ids" && add="$(jq -s '.[0] * .[1]' <(printf '%s' "$add") "$CONFIG_SRC/settings.feedback-off.json")"
  is_selected autoupdater-off      "$_sel_ids" && add="$(jq -s '.[0] * .[1]' <(printf '%s' "$add") "$CONFIG_SRC/settings.autoupdater-off.json")"
  is_selected feedback-survey-off  "$_sel_ids" && add="$(jq -s '.[0] * .[1]' <(printf '%s' "$add") "$CONFIG_SRC/settings.feedback-survey-off.json")"

  # Shared library the egress guards read (single source of truth for the
  # secret/outbound patterns) and the vendored guard-core (every bun guard hook).
  # Placed whenever any consumer is selected, so bash and TS both resolve
  # config/hooks/lib/{secret-patterns.json,guard-core.js} relative to themselves.
  # prompt-guard reads the same secret-patterns.json (for its credential-pairing tier)
  # and guard-core.js (scanPrompt, detectAitc), so it's a consumer too — its own missing-
  # patterns/missing-core paths just degrade silently rather than failing closed.
  if is_selected leak-guard "$_sel_ids" || is_selected command-guard "$_sel_ids" \
    || is_selected mcp-guard "$_sel_ids" || is_selected rtk-safe "$_sel_ids" \
    || is_selected prompt-guard "$_sel_ids"; then
    place_dir "$CONFIG_SRC/hooks/lib" "$config_dir/hooks"
  fi

  if is_selected leak-guard "$_sel_ids"; then
    # bun is guaranteed present here — the hard-dependency gate above aborts the install
    # if leak-guard is selected without bun (the .ts can't degrade-run like the old .sh).
    local bun_bin; bun_bin="$(command -v bun)"
    place_file "$CONFIG_SRC/hooks/leak-guard.ts" "$config_dir/hooks" +x
    # Registered on WEB-egress tools only — Bash egress is command-guard's surface now
    # (one PreToolUse process per tool surface; no double-spawn on Bash). Includes the
    # SearXNG MCP tools so secure-deep-research's sensitive-topic path (which routes
    # through self-hosted SearXNG for privacy) is egress-scanned too; harmless no-op when
    # no SearXNG server is configured. leak-guard.ts's tool-name gate admits the same set.
    # Register with bun's ABSOLUTE path (same two-token quoted shape as command-guard/
    # statusline/rtk-safe): both tokens shq()-quoted so spaces/metachars/quotes don't split.
    add="$(jq --arg cmd "$(shq "$bun_bin") $cqd/hooks/leak-guard.ts" \
      '.hooks.PreToolUse += [{matcher:"WebSearch|WebFetch|mcp__searxng__",hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
    # Optional: stronger secret detection. Degrades to regex tiers without it.
    ensure_dep trufflehog "trufflehog (leak-guard secret detection)" 0 || true
  fi
  if is_selected harness-pointer "$_sel_ids"; then
    place_file "$CONFIG_SRC/hooks/harness-pointer.sh" "$config_dir/hooks" +x
    add="$(jq --arg cmd "$cqd/hooks/harness-pointer.sh" \
      '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
  fi
  if is_selected command-guard "$_sel_ids"; then
    # bun is guaranteed present here — the hard-dependency gate above aborts the
    # install if command-guard is selected without bun (no soft-skip: a default-on
    # security guard silently disabled is worse than a failed install).
    local bun_bin; bun_bin="$(command -v bun)"
    place_file "$CONFIG_SRC/hooks/command-guard.ts" "$config_dir/hooks" +x
    # Register with bun's ABSOLUTE path. Claude Code runs hooks in a shell that
    # may not have bun on PATH (non-interactive subshells); a bare shebang would
    # silently fail to launch and the guard would be a no-op. Both tokens are
    # shq()-quoted (bun path + the script's dir) so spaces/metachars/quotes don't split.
    add="$(jq --arg cmd "$(shq "$bun_bin") $cqd/hooks/command-guard.ts" \
      '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
    ok "command-guard enabled (bun: $bun_bin)"
    # Optional: stronger Bash secret detection (command-guard runs trufflehog on
    # outbound commands, like leak-guard does for web). Degrades to regex tiers without it.
    ensure_dep trufflehog "trufflehog (command-guard secret detection)" 0 || true
  fi
  if is_selected mcp-guard "$_sel_ids"; then
    # bun is guaranteed present here — the hard-dependency gate above aborts the install
    # if mcp-guard is selected without bun (a default-on security guard is never shipped
    # silently disabled).
    local bun_bin; bun_bin="$(command -v bun)"
    place_file "$CONFIG_SRC/hooks/mcp-guard.ts" "$config_dir/hooks" +x
    # Registered on every MCP tool. Overlaps leak-guard on mcp__searxng__* by design:
    # leak-guard scans those as web egress, mcp-guard applies the server policy to them.
    # Register with bun's ABSOLUTE path (same two-token quoted shape as command-guard/
    # leak-guard): both tokens shq()-quoted so spaces/metachars/quotes don't split.
    add="$(jq --arg cmd "$(shq "$bun_bin") $cqd/hooks/mcp-guard.ts" \
      '.hooks.PreToolUse += [{matcher:"mcp__.*",hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
    ok "mcp-guard enabled (bun: $bun_bin)"
    # No trufflehog offer here: mcp-guard runs the regex tiers only (it fires on every
    # MCP call, so trufflehog's per-call cost stays on the Bash and web egress guards).
  fi
  if is_selected prompt-guard "$_sel_ids"; then
    # bun is guaranteed present here — the hard-dependency gate above aborts the install
    # if prompt-guard is selected without bun (the .ts can't degrade-run, same as the
    # other bun hooks). Opt-in and warn-only: no trufflehog offer (it never scans for
    # verified secrets, only key shapes), and no dangerous-flag heads-up (it never blocks).
    local bun_bin; bun_bin="$(command -v bun)"
    place_file "$CONFIG_SRC/hooks/prompt-guard.ts" "$config_dir/hooks" +x
    # UserPromptSubmit has no matcher (it fires on every submitted prompt, not a tool
    # call). Register with bun's ABSOLUTE path (same two-token quoted shape as the other
    # bun hooks): both tokens shq()-quoted so spaces/metachars/quotes don't split.
    add="$(jq --arg cmd "$(shq "$bun_bin") $cqd/hooks/prompt-guard.ts" \
      '.hooks.UserPromptSubmit += [{hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
    ok "prompt-guard enabled (bun: $bun_bin)"
  fi
  if is_selected rtk-safe "$_sel_ids"; then
    # bun is guaranteed present here — the hard-dependency gate above aborts the install
    # if rtk-safe is selected without bun (the .ts can't degrade-run like the old .sh).
    local bun_bin; bun_bin="$(command -v bun)"
    ensure_dep rtk "rtk (RTK rewriting)" 0 || true
    # rtk-safe self-skips at runtime if rtk is absent, so it's safe to register unconditionally.
    place_file "$CONFIG_SRC/hooks/rtk-safe.ts" "$config_dir/hooks" +x
    # Register with bun's ABSOLUTE path (same two-token quoted shape as command-guard/
    # statusline): both tokens shq()-quoted so spaces/metachars/quotes don't split.
    add="$(jq --arg cmd "$(shq "$bun_bin") $cqd/hooks/rtk-safe.ts" \
      '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
    # Read-only rtk allowlist: the rewrite changes the command string, so the
    # user's existing allow rules (e.g. Bash(git status:*)) no longer match the
    # rewritten form. Allow ONLY the strictly read-only rtk forms to keep prompt
    # friction where it was; mutating/egress forms (rtk curl, rtk aws, rtk git
    # push, …) keep prompting. Deliberately NOT a blanket Bash(rtk:*) — rtk
    # fronts curl/aws/psql/docker, so that would amount to a general Bash allow.
    add="$(jq -s '.[0] * .[1]' <(printf '%s' "$add") "$CONFIG_SRC/rtk-allowlist.json")"
    command -v rtk >/dev/null 2>&1 || warn "RTK rewriting registered but inert until 'rtk' is installed."
  fi
  if is_selected statusline "$_sel_ids" && aitc_present "$config_dir"; then
    # ai-tc provides its own statusline (coexistencePolicy().statusline is false when
    # present) — installing the kit's on top would fight it for the slot. Silent here:
    # whether there's anything to say (a still-installed kit statusLine from BEFORE
    # ai-tc showed up needs relinquishing, vs. nothing to do) depends on the ON-DISK
    # settings.json, which isn't read until 4d-pre1d below — that section owns both
    # the message and the relinquish action, reusing this same aitc_present check.
    :
  elif is_selected statusline "$_sel_ids"; then
    # bun is guaranteed present here — the hard-dependency gate above aborts the install
    # if statusline is selected without bun (the .ts can't degrade-run like the old .sh).
    local bun_bin; bun_bin="$(command -v bun)"
    place_file "$CONFIG_SRC/hooks/statusline.ts" "$config_dir/hooks" +x
    # Register with bun's ABSOLUTE path (same two-token quoted shape as command-guard):
    # both tokens shq()-quoted so spaces/metachars/quotes in the bun path or config dir
    # don't split, and the command still ends with the literal "/hooks/statusline.ts"
    # the prune/stash matchers anchor on (after quote-normalization).
    add="$(jq --arg cmd "$(shq "$bun_bin") $cqd/hooks/statusline.ts" \
      '.statusLine = {type:"command",command:$cmd,refreshInterval:2}' <<<"$add")"
    # Optional location pin for accurate weather (default: auto-detect by IP).
    isay ""
    isay "  ${C_DIM}Statusline weather uses your location — default is auto-detect by IP (city-level).${C_RST}"
    isay "  ${C_DIM}You can pin an exact spot instead. Nothing is saved or collected by aka-claude-tools:${C_RST}"
    isay "  ${C_DIM}your entry is geocoded once via OpenStreetMap, only the resulting coordinates are${C_RST}"
    isay "  ${C_DIM}stored — locally, in this profile's settings.json — and the text itself is not kept.${C_RST}"
    local _loc_in; prompt _loc_in "  Pin a location? city or address (Enter = auto/IP):" ""
    if [ -n "$_loc_in" ]; then
      local _q _geo _plat _plon _pcc _prc _pdisp
      _q=$(jq -rn --arg q "$_loc_in" '$q|@uri')
      _geo=$(curl -s --max-time 8 -H "User-Agent: aka-claude-tools-installer" \
        "https://nominatim.openstreetmap.org/search?q=${_q}&format=jsonv2&limit=1&addressdetails=1" 2>/dev/null)
      _plat=$(printf '%s' "$_geo" | jq -r '.[0].lat // empty' 2>/dev/null)
      _plon=$(printf '%s' "$_geo" | jq -r '.[0].lon // empty' 2>/dev/null)
      _pcc=$(printf '%s' "$_geo" | jq -r '(.[0].address.country_code // "") | ascii_upcase' 2>/dev/null)
      # Abbreviated state/region (ISO3166-2 "US-CA" → "CA") — the statusline shows
      # this instead of a city name.
      _prc=$(printf '%s' "$_geo" | jq -r '(.[0].address["ISO3166-2-lvl4"] // "" | split("-") | last) // empty' 2>/dev/null)
      _pdisp=$(printf '%s' "$_geo" | jq -r '.[0].display_name // empty' 2>/dev/null)
      # Validate before --argjson: a malformed geocoder response must not abort
      # the installer under set -e.
      [[ "$_plat" =~ ^-?[0-9]+(\.[0-9]+)?$ && "$_plon" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || { _plat=""; _plon=""; }
      if [ -n "$_plat" ] && [ -n "$_plon" ]; then
        if confirm "  Pin \"${_pdisp}\" (${_plat}, ${_plon})?" "Y"; then
          add="$(jq --argjson la "$_plat" --argjson lo "$_plon" --arg cc "$_pcc" --arg rc "$_prc" \
            '.preferences.location = {latitude:$la, longitude:$lo, countryCode:$cc, regionCode:$rc}' <<<"$add")"
          ok "Pinned location → this profile (coordinates only)."
        fi
      else
        warn "Couldn't geocode \"${_loc_in}\" — using IP auto-detect instead."
      fi
    fi
  fi
  if is_selected wrap-up "$_sel_ids"; then
    place_file "$CONFIG_SRC/commands/wrap-up.md" "$config_dir/commands"
  fi
  if is_selected shell-audit "$_sel_ids"; then
    place_dir "$CONFIG_SRC/skills/shell-audit" "$config_dir/skills"
    chmod +x "$config_dir/skills/shell-audit/audit.sh" 2>/dev/null || true
    ok "Placed shell-audit skill"
  fi
  if is_selected secure-deep-research "$_sel_ids"; then
    # A .js dropped in <config>/workflows/ auto-registers as BOTH the named
    # workflow and the /secure-deep-research skill (Claude Code scans this dir).
    place_file "$CONFIG_SRC/workflows/secure-deep-research.js" "$config_dir/workflows"
    ok "Placed secure-deep-research workflow ${C_DIM}(invoke: /secure-deep-research)${C_RST}"
  fi
  if is_selected secure-research "$_sel_ids"; then
    # Same mechanism: a .js in <config>/workflows/ auto-registers as the named
    # workflow and the /secure-research skill.
    place_file "$CONFIG_SRC/workflows/secure-research.js" "$config_dir/workflows"
    ok "Placed secure-research workflow ${C_DIM}(invoke: /secure-research)${C_RST}"
  fi

  # 4c. opt-in config template if any config-driven hook was selected. command-guard
  # is in the trigger now: it reads CT_EGRESS_PATTERNS (via the compiled sidecar
  # below), so a command-guard-only install must still get the config — else the
  # org-marker tier silently vanishes for that install.
  # `-e` (not `-f`): a DANGLING symlink — e.g. a config symlinked to a path that moved
  # away — is false under -e, so we (re)place the template. The rm -f first clears that
  # broken link, otherwise `cp` would follow it to the missing target and abort the whole
  # install under set -e. A valid symlink to a real config is true under -e → left alone.
  if { is_selected leak-guard "$_sel_ids" || is_selected command-guard "$_sel_ids" \
       || is_selected mcp-guard "$_sel_ids" || is_selected harness-pointer "$_sel_ids"; } \
     && [ ! -e "$config_dir/aka-claude-tools.config" ]; then
    rm -f "$config_dir/aka-claude-tools.config"
    cp "$REPO_DIR/shared/aka-claude-tools.config.example" "$config_dir/aka-claude-tools.config"
    ok "Placed aka-claude-tools.config (opt-in, empty by default)"
  fi
  # Compile the org-egress sidecar that every egress guard (leak-guard, command-guard,
  # mcp-guard) reads at runtime, so none ever sources the shell config (a bun process
  # can't safely evaluate arbitrary shell). Validated + atomically published. Whenever
  # an egress guard is selected.
  if is_selected leak-guard "$_sel_ids" || is_selected command-guard "$_sel_ids" \
    || is_selected mcp-guard "$_sel_ids"; then
    compile_org_sidecar "$config_dir"
  fi
  # mcp-policy.json is owned by mcp-guard alone (the MCP server allow/deny lists), so
  # it's compiled only when mcp-guard itself is selected.
  if is_selected mcp-guard "$_sel_ids"; then
    compile_mcp_policy_sidecar "$config_dir"
  fi
  # trusted-bootstrap.json is owned by command-guard alone (it validates bootstrap
  # script URLs before letting a curl|sh-style command through), so it's compiled
  # only when command-guard itself is selected — not on a leak-guard-only install.
  if is_selected command-guard "$_sel_ids"; then
    compile_bootstrap_sidecar "$config_dir"
  fi

  # 4d. merge settings (existing-in-dir ∪ additions) and write
  local existing='{}'
  if [ -f "$config_dir/settings.json" ]; then
    # Validate before the merge consumes it. A corrupt/truncated settings.json
    # otherwise floods the user with raw `jq: parse error` lines and aborts with no
    # actionable framing (the parse failure surfaces from deep inside merge_settings
    # / the prune helpers). Fail with a named, recoverable message instead.
    if [ -s "$config_dir/settings.json" ] && ! jq -e . "$config_dir/settings.json" >/dev/null 2>&1; then
      die "$config_dir/settings.json is not valid JSON (corrupt or truncated). Fix it, or move it aside (e.g. mv settings.json settings.json.bak), then re-run."
    fi
    existing="$(cat "$config_dir/settings.json")"
    # Coerce wrong-TYPED (but valid-JSON) kit-managed fields to safe shapes so the
    # merge/prune jq can't crash on them — e.g. permissions.deny as a string, which
    # Claude Code itself simply ignores. Refusing here would leave the user
    # UNPROTECTED over a field CC already ignores; coercing lets the secure baseline
    # still land. Well-typed settings pass through unchanged.
    existing="$(printf '%s' "$existing" | jq '
      if type!="object" then {} else
        (if has("permissions") and ((.permissions|type)!="object") then .permissions={} else . end)
        | (if (.permissions|type)=="object" then
             reduce ("allow","deny","ask") as $k (.;
               if (.permissions|has($k)) and ((.permissions[$k]|type)!="array")
               then .permissions[$k]=[] else . end)
           else . end)
        | (if has("hooks") and ((.hooks|type)!="object") then .hooks={} else . end)
        | (if (.hooks|type)=="object" then
             .hooks |= with_entries(.value = (if (.value|type)=="array" then .value else [] end))
           else . end)
        | (if has("env") and ((.env|type)!="object") then .env={} else . end)
      end')"
  fi

  # 4d-pre. Uninstall deselected additions. Unchecking an addition you had
  # before now REMOVES it: its hook/command/skill files are deleted and its
  # settings contributions (hook registrations, statusLine, shipped permission/
  # env rules) are pruned from `existing` before the merge re-adds the selected
  # ones. Driven by config/additions.json; idempotent (no-op for anything not
  # actually present), so it's safe to run for every unselected id.
  local _uid _p _changed
  for _uid in $(jq -r '.additions[].id' "$CONFIG_SRC/additions.json"); do
    is_selected "$_uid" "$_sel_ids" && continue
    _changed=0
    while IFS= read -r _p; do
      [ -n "$_p" ] && [ -e "$_p" ] && { rm -rf "$_p"; _changed=1; }
    done < <(addition_owned_paths "$_uid" "$config_dir")
    if [ "$existing" != "{}" ]; then
      local _pruned; _pruned="$(printf '%s' "$existing" | prune_addition_from_settings "$_uid" "$config_dir")"
      [ -n "$_pruned" ] && [ "$_pruned" != "$existing" ] && { existing="$_pruned"; _changed=1; }
    fi
    [ "$_changed" = "1" ] && ok "Uninstalled '${_uid}' — removed its files and settings entries"
  done

  # 4d-pre1d. Reconcile the statusLine slot with the current ai-tc state, now that
  # $existing (the on-disk settings.json) is loaded — the 4b build step above can't do
  # this itself, since it runs BEFORE $existing is read.
  #
  # Two things share this section because they both hinge on the SAME question — does
  # $existing's .statusLine belong to the kit? — decided by the SAME anchor
  # prune_statusline uses (command ends with the quoted "<config_dir>/hooks/
  # statusline.{sh,ts}" tail, portable $HOME form or legacy absolute form):
  #
  #   1. FRESH install (ai-tc absent): preserve a user's existing statusLine before the
  #      merge overwrites it. The kit's statusLine is a singleton object the merge
  #      OVERWRITES (no safe union), so a plain install would silently lose a
  #      statusLine the user already had. Stash a NON-kit prior value once —
  #      prune_statusline restores it verbatim if the addition is later deselected (or,
  #      per #2, if ai-tc shows up). Idempotency guard: only stash when nothing is
  #      stashed yet, so a re-apply never overwrites the saved original with the kit
  #      value.
  #   2. UPGRADE path (ai-tc now present, and $existing.statusLine is STILL the kit's
  #      own from a run before ai-tc was added): relinquish it exactly as deselecting
  #      'statusline' would — remove the placed hook file via the SAME
  #      addition_owned_paths list the deselect loop (4d-pre, above) uses, then hand
  #      the settings prune to prune_addition_from_settings (which calls
  #      prune_statusline, and already knows restore-a-stash vs. just-delete) — no
  #      restore-vs-remove logic is duplicated here. If $existing.statusLine is
  #      ALREADY not the kit's own (absent, or the user's real one that was never
  #      overwritten), there's nothing to relinquish — just say so.
  #
  # The stem is derived from the SAME manifest statusLine path that
  # prune_addition_from_settings uses, so the manifest stays the single source of truth
  # and stash/relinquish/prune can't disagree even if that path is later moved.
  local _slrel; _slrel="$(jq -r '.additions[] | select(.id=="statusline") | .statusLine // "hooks/statusline.ts"' "$CONFIG_SRC/additions.json")"
  # PORTABLE form ($HOME'<dir>'/…) the registration now writes, plus the LEGACY absolute
  # form (<shq(config_dir)>/…) a pre-portability profile carries — match EITHER so the
  # kit's own statusLine is never misclassified as the user's during the upgrade that
  # flipped the registration to $HOME (which would wrongly stash it as _aka_prior).
  local _slstem;   _slstem="$(cfg_token "$config_dir")/${_slrel%.*}"
  local _sllegacy; _sllegacy="$(shq "$config_dir")/${_slrel%.*}"
  if is_selected statusline "$_sel_ids"; then
    # Classify $existing.statusLine ONCE: present at all, whether it's the kit's own,
    # and whether a prior-value stash already exists — every branch below reads these
    # instead of re-deriving the same jq predicate three different ways.
    local _sl_present=0 _sl_is_kit=0 _sl_has_stash=0
    if [ "$existing" != "{}" ]; then
      printf '%s' "$existing" | jq -e '(.statusLine|type)=="object"' >/dev/null 2>&1 && _sl_present=1
      if [ "$_sl_present" = "1" ]; then
        printf '%s' "$existing" | jq -e --arg stem "$_slstem" --arg legacy "$_sllegacy" '
              (.statusLine.command) as $c
              | (if ($c|type)=="array" then ($c|join(" ")) else ($c // "") end)
              | ( endswith($stem + ".sh")   or endswith($stem + ".ts")
                  or endswith($legacy + ".sh") or endswith($legacy + ".ts") )' >/dev/null 2>&1 && _sl_is_kit=1
      fi
      printf '%s' "$existing" | jq -e 'has("_aka_prior_statusLine")' >/dev/null 2>&1 && _sl_has_stash=1
    fi
    if aitc_present "$config_dir"; then
      if [ "$_sl_is_kit" = "1" ]; then
        local _p
        while IFS= read -r _p; do
          [ -n "$_p" ] && [ -e "$_p" ] && rm -rf "$_p"
        done < <(addition_owned_paths statusline "$config_dir")
        existing="$(printf '%s' "$existing" | prune_addition_from_settings statusline "$config_dir")"
        if [ "$_sl_has_stash" = "1" ]; then
          ok "ai-tc detected; removed the kit status line (restored your previous one)"
        else
          ok "ai-tc detected; removed the kit status line (no previous one to restore)"
        fi
      else
        ok "ai-tc detected; skipping the kit status line (ai-tc provides its own)"
      fi
    elif [ "$_sl_present" = "1" ] && [ "$_sl_is_kit" = "0" ] && [ "$_sl_has_stash" = "0" ]; then
      warn "Replacing your existing statusLine with the kit's — your previous one is saved and restored if you later deselect 'statusline'."
      existing="$(printf '%s' "$existing" | jq '._aka_prior_statusLine = .statusLine')"
    fi
  fi

  # 4d-pre1a. The shared egress-guard libs (hooks/lib/secret-patterns.json and the
  # compiled hooks/lib/org-egress.json sidecar) are owned by NO single addition — they're
  # placed/compiled whenever any egress guard (leak-guard, command-guard, mcp-guard) or
  # prompt-guard (its credential-pairing tier reads secret-patterns.json too) is
  # selected. The per-addition deselect loop above can't remove them (no guard's
  # owned-paths list includes them), so deselecting every guard would orphan them.
  # Remove both only when NO consumer remains. The vendored guard-core has a wider
  # consumer set still (every bun guard hook, including rtk-safe), so it's cleaned up
  # separately below — only once NO consumer remains does the now-empty hooks/lib dir
  # come down.
  if ! is_selected leak-guard "$_sel_ids" && ! is_selected command-guard "$_sel_ids" \
    && ! is_selected mcp-guard "$_sel_ids" && ! is_selected prompt-guard "$_sel_ids"; then
    _egress_lib_removed=
    for _lib in secret-patterns.json org-egress.json; do
      if [ -e "$config_dir/hooks/lib/$_lib" ]; then
        rm -f "$config_dir/hooks/lib/$_lib"
        _egress_lib_removed=1
      fi
    done
    [ -n "$_egress_lib_removed" ] && ok "Removed shared egress-guard lib (no guard selected)"
  fi
  # trusted-bootstrap.json is owned by command-guard alone (see the compile call
  # site above) — remove it whenever command-guard itself is deselected, regardless
  # of leak-guard's state.
  if ! is_selected command-guard "$_sel_ids" \
    && [ -e "$config_dir/hooks/lib/trusted-bootstrap.json" ]; then
    rm -f "$config_dir/hooks/lib/trusted-bootstrap.json"
    ok "Removed trusted-bootstrap sidecar (command-guard not selected)"
  fi
  # mcp-policy.json is owned by mcp-guard alone (see the compile call site above) —
  # remove it whenever mcp-guard itself is deselected, regardless of the other guards.
  if ! is_selected mcp-guard "$_sel_ids" \
    && [ -e "$config_dir/hooks/lib/mcp-policy.json" ]; then
    rm -f "$config_dir/hooks/lib/mcp-policy.json"
    ok "Removed MCP policy sidecar (mcp-guard not selected)"
  fi
  if ! is_selected leak-guard "$_sel_ids" && ! is_selected command-guard "$_sel_ids" \
    && ! is_selected mcp-guard "$_sel_ids" && ! is_selected rtk-safe "$_sel_ids" \
    && ! is_selected prompt-guard "$_sel_ids"; then
    rm -f "$config_dir/hooks/lib/guard-core.js" "$config_dir/hooks/lib/guard-core.d.ts" \
      "$config_dir/hooks/lib/guard-core.lock.json"
    rmdir "$config_dir/hooks/lib" 2>/dev/null || true
  fi

  # 4d-pre1b. Clean RETIRED additions — whole additions the kit shipped before and
  # has since dropped from additions.json. The loop above only iterates ids STILL
  # in the manifest, so a fully-removed addition's files would orphan in an existing
  # profile; config/managed-permissions.json (.retiredAdditions[].paths) tombstones
  # their owned paths. Skills/commands only (idempotent rm); retired HOOKS self-clean
  # via the managed marker in 4d-pre2 below.
  while IFS= read -r _rp; do
    [ -n "$_rp" ] || continue
    [ -e "$config_dir/$_rp" ] && { rm -rf "$config_dir/$_rp"; ok "Removed retired addition file: ${_rp}"; }
  done < <(jq -r '.retiredAdditions // [] | .[] | .paths[]?' "$CONFIG_SRC/managed-permissions.json" 2>/dev/null)

  # 4d-pre2. Self-clean stale kit hooks. Every shipped hook carries a managed
  # marker (aka-claude-tools:managed-hook). Any marked hook in the profile that
  # the kit NO LONGER ships — i.e. one it renamed or retired — is removed and its
  # registration pruned. Marker-based, so it needs no maintained list and never
  # touches the user's own (unmarked) hooks. This is the generic file-rename
  # self-clean (it handles e.g. leak-guard.sh → leak-guard.ts).
  if [ -d "$config_dir/hooks" ]; then
    local _hf _hb
    for _hf in "$config_dir"/hooks/*; do
      [ -f "$_hf" ] || continue                                                # regular files only — skips the lib/ subdir
      grep -q 'aka-claude-tools:managed-hook' "$_hf" 2>/dev/null || continue   # not ours → leave it
      _hb="$(basename "$_hf")"
      [ -e "$CONFIG_SRC/hooks/$_hb" ] && continue                              # still shipped → keep
      rm -f "$_hf"
      [ "$existing" != "{}" ] && existing="$(printf '%s' "$existing" | prune_hook_regs "$_hb")"
      ok "Removed renamed/retired kit hook '$_hb' (managed-marker)"
    done
  fi

  # 4d-pre3. Superseded kit-MATCHER migration. When the kit BROADENS a hook's matcher
  # across versions (leak-guard "WebSearch|WebFetch" → "…|mcp__searxng__", #59), the hook
  # FILE is unchanged (so 4d-pre2 doesn't apply) and the matcher-gated dedup below
  # reads the stale OLD-matcher reg as a user tweak and keeps it — leaving the guard under
  # BOTH matchers (double-firing). Build a SYNTHETIC add that carries the kit's current
  # command(s) under the SUPERSEDED matcher(s) and run it through the SAME resolved-target
  # pruner used below — so the stale reg is removed with the proven full-normalization,
  # full-command-equality logic (an augmented user invocation, a different matcher, or a
  # same-named hook elsewhere is preserved), then the merge re-adds the current reg.
  # Security-safe: the kit only ever broadens, so the re-added reg can only ADD coverage
  # (see the AKA_SUPERSEDED_MATCHERS invariant). No-op on a fresh install (existing == {}).
  if [ "$existing" != "{}" ] && [ "$add" != "{}" ]; then
    local _superseded_add; _superseded_add="$(build_superseded_add "$add")"
    [ "$_superseded_add" != "{}" ] && \
      existing="$(printf '%s' "$existing" | prune_hook_regs_resolving "$config_dir" "$_superseded_add")"
  fi

  # 4d-pre4. De-dup kit hook registrations by RESOLVED TARGET. The union (merge_settings)
  # dedups by exact command string, so an existing reg pointing at a kit hook with a
  # different path SPELLING than the canonical one the kit adds in `add` (e.g. a converted
  # foreign profile holding `$HOME/.claude-x/hooks/harness-pointer.sh` vs the kit's
  # single-quoted absolute form) survives ALONGSIDE the canonical reg and the hook
  # double-fires. Pass `add` (data-driven — exactly what was registered this run) and prune
  # any existing reg that is the same LOGICAL registration (event + matcher + resolved hook
  # file); the union then re-adds the single canonical one. Matcher-gated, so a user's
  # deliberate matcher tweak on a kit hook is preserved (see the helper).
  if [ "$existing" != "{}" ] && [ "$add" != "{}" ]; then
    existing="$(printf '%s' "$existing" | prune_hook_regs_resolving "$config_dir" "$add")"
  fi

  # Reconcile kit-managed permission rules first: a plain merge only UNIONS, so it
  # can add new denies/allows but never drop ones the kit has retired. This shows
  # the engineer the per-rule diff and lets them choose (default: adopt this
  # version's set), without ever touching rules they added themselves.
  reconcile_managed_perms "$existing" "$add"
  existing="$RECON_EXISTING"; add="$RECON_ADD"

  # ── rtk rg ⟷ command-guard coupling (enforced on BOTH sides of the merge) ──
  # `Bash(rtk rg:*)` is the one allow rule that is not safe standalone: ripgrep's
  # --pre/--hostname-bin execute an arbitrary binary and RIPGREP_CONFIG_PATH injects flags
  # from a file, and a PREFIX rule approves every suffix. command-guard's detectSearchExec
  # is what makes it safe, so the two must never be separated.
  #
  # Filtering only the incoming `add` was not enough: merge_settings UNIONS, command-guard
  # contributes no permissions payload for prune_addition_from_settings to strip, and the
  # rule is not in .retired[] (it is current, not retired), so an upgrade that DESELECTED
  # command-guard left a live approval with no guard behind it — the one state the design
  # says must never ship. Strip it from the EXISTING profile too, every run, whenever the
  # guard is not selected. rg is still REWRITTEN (the token saving is kept); it just
  # prompts, exactly as with no approval.
  if ! is_selected command-guard "$_sel_ids"; then
    local _rgrule='Bash(rtk rg:*)' _had_rg=0
    jq -e --arg r "$_rgrule" '((.permissions.allow // []) | index($r)) != null' <<<"$existing" >/dev/null 2>&1 && _had_rg=1
    local _strip='(.permissions.allow) |= (if type=="array" then map(select(. != $r)) else . end)'
    existing="$(jq -c --arg r "$_rgrule" "$_strip" <<<"$existing")"
    add="$(jq -c --arg r "$_rgrule" "$_strip" <<<"$add")"
    if [ "$_had_rg" = "1" ]; then
      warn "Removed the existing 'Bash(rtk rg:*)' approval: it requires command-guard, which is not selected. rg stays compressed; it will prompt."
    else
      warn "rtk rg auto-approval withheld: it requires command-guard (which blocks ripgrep's --pre/--hostname-bin/RIPGREP_CONFIG_PATH exec vectors). rg is still compressed; it will prompt."
    fi
  fi
  # Write when there's something to write OR a settings.json already exists — the
  # latter so deselecting the LAST settings-contributing addition (merge result
  # back to {}) actually persists; otherwise the empty merge is skipped and the
  # just-"uninstalled" registrations survive on disk. Still no empty file is
  # created on a fresh install that selected nothing.
  if [ "$add" != "{}" ] || [ "$existing" != "{}" ] || [ -f "$config_dir/settings.json" ]; then
    merge_settings "$existing" "$add" > "$config_dir/settings.json.tmp"
    mv "$config_dir/settings.json.tmp" "$config_dir/settings.json"
    ok "Wrote $config_dir/settings.json"
  fi

  # Dangerous-flag heads-up — shown on EVERY path (incl. --defaults/non-interactive),
  # never suppressed. Decision: the kit never STRIPS these (they're the user's call),
  # but it must never let them sit SILENTLY: bypassPermissions / the skip-prompt flags
  # make the kit's deny rules inert. (The migrate path additionally offers an
  # interactive strip; this is the always-on safety net for the in-place + rebuild paths.)
  if [ -f "$config_dir/settings.json" ] && jq -e '(.permissions.defaultMode == "bypassPermissions") or (.skipDangerousModePermissionPrompt == true) or (.skipAutoPermissionPrompt == true)' "$config_dir/settings.json" >/dev/null 2>&1; then
    warn "This profile's settings.json enables bypassPermissions and/or the skip-prompt flags —"
    warn "Claude runs without permission prompts, so the kit's deny rules are NOT enforced while they are set."
  fi

  # Mark this profile as aka-claude-tools-managed so agent-install Step-1 detection
  # recognizes it even when the selection registered none of the named kit hooks
  # (e.g. secure-settings + statusline only). Preserves any alias= line --alias wrote.
  meta_set "$config_dir" managed aka-claude-tools

  # tidy empty dirs
  rmdir "$config_dir/hooks" "$config_dir/commands" "$config_dir/workflows" 2>/dev/null || true
}

# ── main loop ────────────────────────────────────────────────────────────────
ct_main() {
  setup_one_config
  while confirm "Set up another config folder?" "N"; do
    setup_one_config
  done

  # Point at the detection engine once, after every profile is built (posture is
  # placed by the guards above; deep detection lives in ai-tc).
  offer_aitc

  say ""
  hr
  ok "Done. ${C_DIM}Re-run ./install.sh any time to add or update a config.${C_RST}"
}

# ── --apply entry: the deterministic engine, invoked by Path A or a script ─────
# Layer the additions named in $CT_ADDITIONS onto $CT_CONFIG_DIR and exit. The
# heavy lifting is apply_additions (the same code the interactive installer runs);
# this only validates inputs and normalizes the dir, then hands off. No prompts,
# alias, migration, or auth — the caller (the agent, or CI) owns those.
apply_entry() {
  [ -n "${CT_CONFIG_DIR:-}" ] || die "--apply requires CT_CONFIG_DIR (the target profile dir)."
  # CT_ADDITIONS must be SET (an empty value is valid — it selects no additions and
  # prunes any the dir already had). Distinguish unset from empty so a missing var
  # fails loudly instead of silently installing nothing.
  [ -n "${CT_ADDITIONS+x}" ] || die "--apply requires CT_ADDITIONS (space-separated addition ids; empty selects none)."
  local config_dir="${CT_CONFIG_DIR/#\~/$HOME}"
  # Same normalization as setup_one_config: strip a trailing slash, make relative
  # absolute, so hook/command paths bind to a stable location.
  [ "$config_dir" != "/" ] && config_dir="${config_dir%/}"
  case "$config_dir" in /*) ;; *) config_dir="$PWD/$config_dir" ;; esac
  # Footgun heads-up (engine mode is non-interactive, so warn — never silently modify the
  # live default profile). The caller (Path A / CI) owns the decision to target it.
  [ "$config_dir" = "$HOME/.claude" ] && warn "Targeting your DEFAULT Claude Code config (~/.claude) — layering the kit onto your live default profile, not an isolated one."
  mkdir -p "$config_dir"
  apply_additions "$config_dir"
  ok "Applied additions to ${config_dir/#$HOME/~}"
  migrate_deprecated_launcher "$config_dir" apply
}

# ── --alias entry: create/check the launcher alias, the sole sanctioned rc write ─
# install.sh owns shell-rc writes so the agent never edits the rc itself (which
# would force loosening command-guard). The agent invokes this
# after --apply; on an unresolved name collision it exits non-zero so the agent
# picks another name and re-invokes. Idempotent: re-running for the same dir+alias
# replaces the managed block rather than adding a duplicate.
alias_entry() {
  [ -n "${CT_CONFIG_DIR:-}" ] || die "--alias requires CT_CONFIG_DIR (the target profile dir)."
  [ -n "${CT_ALIAS:-}" ]      || die "--alias requires CT_ALIAS (the alias name)."
  local config_dir="${CT_CONFIG_DIR/#\~/$HOME}"
  [ "$config_dir" != "/" ] && config_dir="${config_dir%/}"
  case "$config_dir" in /*) ;; *) config_dir="$PWD/$config_dir" ;; esac
  setup_alias "$config_dir" "$CT_ALIAS" strict
}

# ── --delete-alias entry: remove a managed alias block from the shell rc ─────────
# The ONLY safe way for an agent to delete a launcher alias. Mirrors the --alias
# gate: validates the name, then removes the marker-delimited managed block. If
# CT_CONFIG_DIR is provided it also verifies the alias resolves to that profile —
# refusing to delete if it points somewhere else (prevents cross-profile clobber).
# Exits non-zero (with a message) if no managed block is found or a safety check
# fails; exits 0 on success.
# _block_body <rc> <name> — the lines inside our managed block for <name>, matched
# by exact marker equality (never the <name>[0-9]* family).
_block_body() {
  local begin="# >>> aka-claude-tools managed: ${2} >>>" end="# <<< aka-claude-tools managed: ${2} <<<"
  [ -f "$1" ] || return 0
  awk -v b="$begin" -v e="$end" '$0==b{in_b=1;next} $0==e{in_b=0;next} in_b{print}' "$1"
}

# _remove_block_exact <rc> <name> — delete exactly <name>'s managed block (string
# equality on the markers, so `aka` never removes `aka2`). EOF-safe like
# remove_managed_block: a begin with no matching end is flushed back, not dropped.
_remove_block_exact() {
  local rc="$1" begin="# >>> aka-claude-tools managed: ${2} >>>" end="# <<< aka-claude-tools managed: ${2} <<<" tmp
  [ -f "$rc" ] && grep -qF "$begin" "$rc" || return 1
  tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '
    $0==b { if (skip) for (i=0;i<n;i++) print buf[i]; skip=1; n=0; next }
    skip && $0==e { skip=0; n=0; next }
    skip { buf[n++]=$0; next }
    { print }
    END { if (skip) for (i=0;i<n;i++) print buf[i] }
  ' "$rc" > "$tmp"
  mv "$tmp" "$rc"
}

# _remove_marked_shim <dir> <name> — remove <dir>/bin/<name> ONLY if it carries the
# kit's shim marker (never a user file that shares the name), then the bin/ dir if
# it empties. An unreadable file is reported rather than skipped silently.
_remove_marked_shim() {
  local dir="$1" name="$2"
  [ -n "$dir" ] && [ -f "$dir/bin/$name" ] || return 0
  if [ ! -r "$dir/bin/$name" ]; then
    warn "Couldn't read ${dir}/bin/${name} to check whether it's ours — left in place. Remove it by hand if it's a stale launcher shim."
  elif grep -qF "$AKA_SHIM_MARKER" "$dir/bin/$name"; then
    rm -f "$dir/bin/$name"
    rmdir "$dir/bin" 2>/dev/null || true
    ok "Removed launcher shim ${dir}/bin/${name}"
  fi
}

delete_alias_entry() {
  [ -n "${CT_ALIAS:-}" ] || die "--delete-alias requires CT_ALIAS (the alias name to remove)."
  assert_safe_alias_name "$CT_ALIAS"

  local rc; rc="$(detect_shell_rc)"

  # Exact marker strings for this alias — used for both inspection and deletion.
  # Using exact string equality instead of remove_managed_block's family pattern
  # (id[0-9]*) so that --delete-alias aka never accidentally removes aka2, which may
  # belong to a different profile created via collision-renaming.
  local begin
  begin="# >>> aka-claude-tools managed: ${CT_ALIAS} >>>"

  # Extract the alias line from inside our managed block. The resolved target
  # drives BOTH the profile guard below and the shim cleanup after deletion (the
  # shim lives at <target>/bin/<alias>). A deprecated forwarder's alias line has no
  # CLAUDE_CONFIG_DIR, so its profile comes from the block's tag line instead.
  local body mb_line mb_target="" config_dir=""
  body="$(_block_body "$rc" "$CT_ALIAS")"
  mb_line="$(printf '%s\n' "$body" | grep -m1 "^alias[[:space:]]*${CT_ALIAS}=" || true)"
  [ -n "$mb_line" ] && mb_target="$(_alias_resolve_target "$mb_line")"
  if [ "$mb_target" = "OTHER" ]; then
    local tag; tag="$(printf '%s\n' "$body" | grep -m1 -F "$DEPRECATED_BLOCK_TAG" || true)"
    [ -n "$tag" ] && mb_target="$(_alias_resolve_target "$tag")"
  fi

  # Optional profile guard: if CT_CONFIG_DIR is set, refuse if the managed block's
  # actual alias target points to a DIFFERENT profile. We read the managed block
  # directly (not alias_target_elsewhere, which strips our block to find
  # OTHER-scope definitions) so the check covers aliases that only live in our block.
  if [ -n "${CT_CONFIG_DIR:-}" ]; then
    config_dir="${CT_CONFIG_DIR/#\~/$HOME}"
    [ "$config_dir" != "/" ] && config_dir="${config_dir%/}"
    case "$config_dir" in /*) ;; *) config_dir="$PWD/$config_dir" ;; esac
    assert_safe_config_dir "$config_dir"
    # Fail closed: if the block exists but can't be parsed (no alias line), refuse rather
    # than proceeding blindly — an unparsable block may belong to another profile (issue #116).
    if [ -z "$mb_target" ] && [ -f "$rc" ] && grep -qF "$begin" "$rc"; then
      die "Alias '${CT_ALIAS}' managed block found in ${rc} but could not be parsed (no alias line). Refusing to delete when CT_CONFIG_DIR is set — inspect the block manually."
    fi
    if [ -n "$mb_target" ] && [ "$mb_target" != "OTHER" ] && [ "$mb_target" != "$config_dir" ]; then
      die "Alias '${CT_ALIAS}' is managed for profile '${mb_target}', not '${config_dir}' — refusing to remove it to avoid a cross-profile clobber. Check with --enumerate first."
    fi
  fi

  # The profile the shim and meta live in: CT_CONFIG_DIR when given, else the
  # deleted block's own resolved target.
  local prof_dir="$config_dir"
  [ -z "$prof_dir" ] && [ -n "$mb_target" ] && [ "$mb_target" != "OTHER" ] && prof_dir="$mb_target"
  local cur_alias="" dep_alias=""
  if [ -n "$prof_dir" ]; then
    cur_alias="$(meta_get "$prof_dir" alias)"
    dep_alias="$(meta_get "$prof_dir" deprecated_alias)"
  fi

  if _remove_block_exact "$rc" "$CT_ALIAS"; then
    ok "Removed alias '${CT_ALIAS}' from ${rc}"
    if [ -n "$prof_dir" ]; then
      if [ -n "$dep_alias" ] && [ "$CT_ALIAS" = "$dep_alias" ]; then
        # Deleting the deprecated forwarder only: the current launcher stays.
        meta_set "$prof_dir" deprecated_alias ""
      elif [ -n "${CT_CONFIG_DIR:-}" ]; then
        meta_set "$prof_dir" alias ""
      fi
    fi
    _remove_marked_shim "$prof_dir" "$CT_ALIAS"
    # Deleting the current launcher also removes the deprecated forwarder to it, which
    # would otherwise forward to a launcher that no longer exists.
    if [ -n "$dep_alias" ] && [ "$CT_ALIAS" != "$dep_alias" ] && [ "$CT_ALIAS" = "$cur_alias" ]; then
      if _block_body "$rc" "$dep_alias" | grep -qF "$DEPRECATED_BLOCK_TAG"; then
        _remove_block_exact "$rc" "$dep_alias" && ok "Removed deprecated alias '${dep_alias}' from ${rc}"
      fi
      _remove_marked_shim "$prof_dir" "$dep_alias"
      meta_set "$prof_dir" deprecated_alias ""
    fi
    say "  ${C_DIM}Open a new shell (or: source ${rc}) for the change to take effect.${C_RST}"
  else
    warn "No aka-claude-tools-managed alias block found for '${CT_ALIAS}' in ${rc}."
    return 1
  fi
}

# ── --enumerate entry: the host's profile↔alias map as JSON, for Path A ─────────
# agent-install Step 1 needs the FULL picture before choosing a target: every
# ~/.claude*/ profile, whether each is kit-managed, and which launcher aliases
# resolve to it — resolved through the rc's ENTIRE source/. chain (a fleet aliases
# file the rc sources is where most launchers live, so a shallow `grep ~/.zshrc`
# under-counts). This runs that walk deterministically under bash (the helpers are
# bash-only; sourcing common.sh into the agent's zsh tool returns empty and silently
# under-counts), and emits machine-readable JSON the agent parses instead of
# re-implementing the graph walk in prose. Read-only: inspects files, writes nothing.
enumerate_entry() {
  local rc; rc="$(detect_shell_rc)"
  local -a files=()
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(rc_source_chain "$rc")

  # Discover launcher alias NAMES across the whole chain — alias lines whose body
  # carries CLAUDE_CONFIG_DIR (a commented `# alias …` can't match: ^[:space:]*alias).
  # `|| true`: grep exits 1 on no match → under set -e + pipefail a bare command-sub
  # would abort the whole enumerate on an rc with zero launcher aliases (a legit case).
  local names=""
  if [ "${#files[@]}" -gt 0 ]; then
    names="$(grep -hE '^[[:space:]]*alias[[:space:]]+[A-Za-z0-9_.-]+=.*CLAUDE_CONFIG_DIR' "${files[@]}" 2>/dev/null \
      | sed -E 's/^[[:space:]]*alias[[:space:]]+([A-Za-z0-9_.-]+)=.*/\1/' | sort -u || true)"
  fi

  # Resolve each name to its target dir via the SHARED parser (last definition in
  # chain order wins, mirroring runtime). Build [{name,target}].
  local alias_json="[]" name def target
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    def="$(grep -hE "^[[:space:]]*alias[[:space:]]+${name}=" "${files[@]}" 2>/dev/null | tail -1 || true)"
    target="$(_alias_resolve_target "$def" "${files[@]}")"
    alias_json="$(jq -c --arg n "$name" --arg t "$target" '. + [{name:$n,target:$t}]' <<<"$alias_json")"
  done <<EOF
$names
EOF

  # Enumerate existing ~/.claude*/ profiles + kit-managed status (the SAME two signals
  # agent-install Step 1 documents: the marker file OR a recognized kit hook).
  local prof_json="[]" d managed
  for d in "$HOME"/.claude*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    managed=false
    if [ -f "$d/.aka-claude-tools-meta" ]; then managed=true
    elif [ -f "$d/settings.json" ] && grep -qE 'command-guard\.ts|leak-guard\.(ts|sh)' "$d/settings.json" 2>/dev/null; then managed=true; fi
    prof_json="$(jq -c --arg d "$d" --argjson m "$managed" '. + [{dir:$d,managed:$m}]' <<<"$prof_json")"
  done

  # Join: each profile carries the aliases resolving to it; launcher aliases whose
  # target is no existing profile (dangling, or an external/var path) are surfaced
  # separately so the agent sees them too.
  jq -n --arg rc "$rc" --argjson aliases "$alias_json" --argjson profiles "$prof_json" '
    ($profiles | map(.dir)) as $pdirs
    | { rc: $rc,
        profiles: [ $profiles[] as $p | $p + { aliases: [ $aliases[] | select(.target == $p.dir) | .name ] } ],
        unresolved_aliases: [ $aliases[] | select(.target as $t | ($pdirs | index($t)) | not) ] }'
}

# Run the installer only when EXECUTED, not when SOURCED. Sourcing the script (with
# its top-level definitions) lets the test suite reach the pure helpers above
# (merge_settings, prune_hook_regs, setup_alias, …) without performing an install.
# Tests source inside a subshell so the top-level `set -euo` stays contained. A
# normal `./install.sh` is unaffected.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if   [ "$CT_APPLY" = "1" ];         then apply_entry
  elif [ "$CT_ALIAS_MODE" = "1" ];    then alias_entry
  elif [ "$CT_DELETE_ALIAS" = "1" ];  then delete_alias_entry
  elif [ "$CT_ENUMERATE" = "1" ];     then enumerate_entry
  else ct_main; fi
fi
