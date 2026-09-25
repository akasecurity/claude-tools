#!/usr/bin/env bash
# Scenario T12 (scn_install_alias_collision): INSTALL/edge — the derived alias
# name already exists in the user's shell config, pointing somewhere ELSE.
#
# A non-default config dir ($HOME/.claude-aka) derives the alias `aka-claude`. If the
# user's rc (or a file it sources) ALREADY defines `alias aka-claude=...` for some other
# purpose, the installer MUST NOT silently clobber it. install.sh step 5 detects
# this via alias_target_elsewhere (common.sh) and, on a real collision, prompts
# for an alternate name (or skip). Under --defaults (CT_NONINTERACTIVE) the
# alternate-name prompt auto-takes its default `${alias}2` (= `aka-claude2`), so the
# non-interactive run is the sandbox-faithful proof of "never silently clobber":
# the user's `aka-claude` survives untouched and our launcher lands on a DIFFERENT name.
#
# Three collision shapes, each its own sandbox:
#   A) `aka-claude` is a NON-launcher alias (e.g. a fleet shortcut) → "OTHER" branch:
#      warn it's already an alias, write `aka-claude2`, leave the user's `aka-claude` intact.
#   B) `aka-claude` is a launcher for a DIFFERENT Claude profile → "points to:" branch:
#      warn with the resolved target, write `aka-claude2`, leave the user's `aka-claude` intact.
#   C) the colliding `aka-claude` lives in a fleet aliases file SOURCED from the rc, not
#      the rc itself → the source-chain walk still detects it; same no-clobber.
#
# Invariants across all shapes:
#   • the user's pre-existing `alias aka-claude=` line is byte-for-byte preserved,
#   • NO managed block keyed on `aka-claude` is ever written (we never wrap/own `aka-claude`),
#   • a managed block for the alternate `aka-claude2` IS written, pointing at THIS profile,
#   • the install still completes (exit 0) and reports the collision to the user.
#
# Sandbox limitation: prompt() reads from /dev/tty, so the true interactive
# "blank = skip the alias entirely" path needs a pty and is not faithfully
# reproducible here. The non-interactive default (alternate name `aka-claude2`) is the
# load-bearing guarantee — it proves the user's alias is never overwritten — and
# is what this probe pins. See summary.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit. Never touches a
# real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_alias_collision:"

# Common selection: a small deterministic set that needs no optional runtime, so
# the install completes the same way in CI regardless of bun/trufflehog presence.
SEL="secure-settings leak-guard wrap-up"
# Hermetic PATH: keeps an operator's real `aka-claude` PATH command from turning
# the rc-collision scenario into a PATH-conflict rename.
IPATH="$(install_path)"

# ── shape A: user's `aka-claude` is a NON-launcher alias (the "OTHER" branch) ────────
SB_A="$(sandbox)"
RC_A="$SB_A/.bashrc"
USER_ALIAS_A="alias aka-claude='cd ~/work/aka-repo && git status'"
printf '# user fleet shortcut, nothing to do with Claude\n%s\n' "$USER_ALIAS_A" > "$RC_A"
PROFILE_A="$SB_A/.claude-aka"

PATH="$IPATH" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_A" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB_A/log" 2>&1
rc=$?

assert_eq   "A: install exits 0 despite the collision" "0" "$rc"
assert_file "A: profile dir created" "$PROFILE_A"
# The user's own alias line is preserved verbatim — never clobbered/rewritten.
assert_lit  "A: user's own 'aka-claude' alias preserved verbatim" "$USER_ALIAS_A" "$RC_A"
# We must NOT have written a managed block that owns `aka-claude`.
assert_nlit "A: no managed block keyed on 'aka-claude' written" \
  ">>> aka-claude-tools managed: aka-claude >>>" "$RC_A"
# Our launcher landed on the alternate name aka-claude2 instead, pointing at THIS profile.
assert_lit  "A: managed block for alternate 'aka-claude2' written" \
  ">>> aka-claude-tools managed: aka-claude2 >>>" "$RC_A"
assert_lit  "A: aka-claude2 launcher points at this profile" \
  "alias aka-claude2='CLAUDE_CONFIG_DIR=\"$PROFILE_A\" claude'" "$RC_A"
# Exactly one managed block (only aka-claude2) — no stray aka block snuck in.
n_block_a=$(grep -c '>>> aka-claude-tools managed' "$RC_A")
assert_eq   "A: exactly one managed block (aka-claude2 only)" "1" "$n_block_a"
# The user was told about the collision (detected, not silent).
assert_grep "A: collision reported to user (already an alias)" \
  "already an alias" "$SB_A/log"

# ── shape B: user's `aka-claude` launches a DIFFERENT Claude profile ────────────────
SB_B="$(sandbox)"
RC_B="$SB_B/.bashrc"
# Pre-existing launcher for some OTHER profile; alias_target_elsewhere should
# resolve and report the target rather than treating it as OTHER.
USER_ALIAS_B="alias aka-claude='CLAUDE_CONFIG_DIR=\"\$HOME/.claude-other\" claude'"
printf '%s\n' "$USER_ALIAS_B" > "$RC_B"
PROFILE_B="$SB_B/.claude-aka"

PATH="$IPATH" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_B" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB_B/log" 2>&1
rc=$?

assert_eq   "B: install exits 0 despite the collision" "0" "$rc"
assert_lit  "B: user's own 'aka-claude' launcher preserved verbatim" "$USER_ALIAS_B" "$RC_B"
assert_nlit "B: no managed block keyed on 'aka-claude' written" \
  ">>> aka-claude-tools managed: aka-claude >>>" "$RC_B"
assert_lit  "B: managed block for alternate 'aka-claude2' written" \
  ">>> aka-claude-tools managed: aka-claude2 >>>" "$RC_B"
assert_lit  "B: aka-claude2 launcher points at this profile" \
  "alias aka-claude2='CLAUDE_CONFIG_DIR=\"$PROFILE_B\" claude'" "$RC_B"
# Collision message resolves and names the OTHER profile's target dir.
assert_grep "B: collision reported with resolved target" \
  "already exists and points to" "$SB_B/log"
assert_lit  "B: reported target is the user's other profile" \
  "$SB_B/.claude-other" "$SB_B/log"

# ── shape C: colliding alias lives in a SOURCED fleet file, not the rc ────────
# Proves the source-chain detection: a fleet aliases file the rc `source`s must
# still be scanned, so the collision isn't missed just because it's one hop away.
SB_C="$(sandbox)"
RC_C="$SB_C/.bashrc"
FLEET_C="$SB_C/.aliases"
USER_ALIAS_C="alias aka-claude='echo fleet-aka'"
printf '%s\n' "$USER_ALIAS_C" > "$FLEET_C"
printf 'source %s\n' "$FLEET_C" > "$RC_C"
PROFILE_C="$SB_C/.claude-aka"

PATH="$IPATH" CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_C" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB_C/log" 2>&1
rc=$?

assert_eq   "C: install exits 0 despite the sourced-file collision" "0" "$rc"
# The sourced fleet file is untouched — our writes go to the rc, never the
# user's sourced files.
assert_lit  "C: sourced fleet 'aka-claude' alias preserved verbatim" "$USER_ALIAS_C" "$FLEET_C"
assert_nlit "C: no managed block written into the sourced fleet file" \
  ">>> aka-claude-tools managed" "$FLEET_C"
# The collision (one hop away) WAS detected → we did not write an `aka-claude` block to
# the rc; we wrote the alternate aka-claude2 instead.
assert_nlit "C: no managed block keyed on 'aka-claude' in rc" \
  ">>> aka-claude-tools managed: aka-claude >>>" "$RC_C"
assert_lit  "C: managed block for alternate 'aka-claude2' in rc" \
  ">>> aka-claude-tools managed: aka-claude2 >>>" "$RC_C"
assert_lit  "C: aka-claude2 launcher points at this profile" \
  "alias aka-claude2='CLAUDE_CONFIG_DIR=\"$PROFILE_C\" claude'" "$RC_C"
assert_grep "C: sourced-file collision reported to user" \
  "already an alias" "$SB_C/log"

t_summary
