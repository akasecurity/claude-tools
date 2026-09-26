#!/usr/bin/env bash
# common.sh — shared helpers for the aka-claude-tools installer. Sourced, not run.

# ── output ───────────────────────────────────────────────────────────────────
# Color only on a real terminal AND when NO_COLOR is unset (https://no-color.org).
# Honoring NO_COLOR lets automation/tests (and agents driving the menu with expect)
# get clean, ANSI-free prompts — the colored "[Y/n]" hint otherwise sits between
# escape codes and defeats naive matchers, which can misalign answers and silently
# toggle an addition. Humans on a TTY are unaffected.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_BLU=$'\033[34m'; C_RED=$'\033[31m'; C_RST=$'\033[0m'
else
  C_BOLD=''; C_DIM=''; C_GRN=''; C_YLW=''; C_BLU=''; C_RED=''; C_RST=''
fi
say()  { printf '%s\n' "$*"; }
# interactive-only say: suppressed under CT_NONINTERACTIVE (menus/headers are
# noise when every prompt auto-takes its default).
isay() { [ "${CT_NONINTERACTIVE:-0}" = "1" ] && return 0; say "$@"; }
info() { printf '%s%s%s\n' "$C_BLU" "$*" "$C_RST"; }
ok()   { printf '%s✓ %s%s\n' "$C_GRN" "$*" "$C_RST"; }
warn() { printf '%s! %s%s\n' "$C_YLW" "$*" "$C_RST" >&2; }
die()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RST" >&2; exit 1; }
hr()   { printf '%s────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RST"; }

# sha256_file <path> — print the bare lowercase hex sha256 of a file, portably (BSD +
# GNU). Tries sha256sum (GNU / newer macOS), then shasum -a 256 (Perl — ships on macOS),
# then openssl. Returns 1 (no output) if none is available, so callers treat empty as
# "can't hash" and degrade. sha256 hex is implementation-independent, so this equals
# bun's createHash('sha256').digest('hex') over the same bytes.
sha256_file() {
  if   command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl   >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else return 1; fi
}

# ── prompts (honor CT_NONINTERACTIVE=1 to take all defaults) ──────────────────
# prompt VAR "Question" "default"
prompt() {
  local __var="$1" __q="$2" __def="${3:-}" __ans=""
  if [ "${CT_NONINTERACTIVE:-0}" = "1" ]; then printf -v "$__var" '%s' "$__def"; return; fi
  if [ -n "$__def" ]; then printf '%s %s[%s]%s ' "$__q" "$C_DIM" "$__def" "$C_RST" >&2
  else printf '%s ' "$__q" >&2; fi
  read -r __ans </dev/tty || __ans=""
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# confirm "Question" "Y|N"  → returns 0 for yes, 1 for no. Second arg = default.
confirm() {
  local __q="$1" __def="${2:-N}" __ans=""
  if [ "${CT_NONINTERACTIVE:-0}" = "1" ]; then [ "$__def" = "Y" ]; return; fi
  local __hint="[y/N]"; [ "$__def" = "Y" ] && __hint="[Y/n]"
  printf '%s %s%s%s ' "$__q" "$C_DIM" "$__hint" "$C_RST" >&2
  read -r __ans </dev/tty || __ans=""
  __ans="${__ans:-$__def}"
  [[ "$__ans" =~ ^[Yy] ]]
}

# parse_selection "<input>" <max> → echoes unique, sorted, in-range indices,
# space-separated. Accepts: "all"/"a", space- or comma-separated numbers, and
# ranges like "1-3". Out-of-range and junk tokens are ignored. Empty → nothing.
parse_selection() {
  local input="${1//,/ }" max="$2" out=() tok i
  case "$input" in
    all|a|ALL|A) for ((i=1;i<=max;i++)); do out+=("$i"); done ;;
    *) for tok in $input; do
         if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
           for ((i=BASH_REMATCH[1];i<=BASH_REMATCH[2];i++)); do
             [ "$i" -ge 1 ] && [ "$i" -le "$max" ] && out+=("$i")
           done
         elif [[ "$tok" =~ ^[0-9]+$ ]]; then
           [ "$tok" -ge 1 ] && [ "$tok" -le "$max" ] && out+=("$tok")
         fi
       done ;;
  esac
  [ ${#out[@]} -eq 0 ] && return 0
  printf '%s\n' "${out[@]}" | sort -n -u | tr '\n' ' ' | sed 's/ $//'
}

# is_selected <id> <space-padded-list>  → 0 if " <id> " appears in the list.
# Used to drive the build step from the addition ids the user picked, so the
# menu's single source of truth stays config/additions.json.
is_selected() { case "$2" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# place_file <src> <dst-dir> [+x]
# Copy a payload file into a profile dir WITHOUT writing through an inherited
# symlink at the destination. If migration copied a symlinked hook/command into
# the profile, a bare `cp` onto that path would follow the link and clobber the
# link's TARGET (a file OUTSIDE the profile, e.g. ~/docs/shared/hooks/...). The
# rm -f first guarantees we replace the link itself with a real file. Pass "+x"
# as the third arg to also mark the result executable.
place_file() {
  local src="$1" dst
  dst="$2/$(basename "$1")"
  rm -f "$dst"
  cp "$src" "$dst"
  [ "${3:-}" = "+x" ] && chmod +x "$dst" || true
}
# place_dir <src-dir> <dst-parent> — directory analogue of place_file (skills).
# Replaces the destination so re-installs never leave stale files behind.
place_dir() {
  local src="$1" dst
  dst="$2/$(basename "$1")"
  mkdir -p "$2"
  rm -rf "$dst"
  cp -RL "$src" "$dst"
}

# ── dependency install ───────────────────────────────────────────────────────
# Best install command for a tool given the available package managers, or "".
# bun is intentionally NOT offered via `curl … | bash` (our own command-guard
# blocks pipe-to-shell on principle) — brew/npm only, else manual.
pm_install_cmd() {
  local tool="$1"
  case "$tool" in
    jq|trufflehog)
      if   command -v brew    >/dev/null 2>&1; then echo "brew install $tool"
      elif command -v apt-get >/dev/null 2>&1 && [ "$tool" = jq ]; then echo "sudo apt-get update && sudo apt-get install -y jq"
      elif command -v dnf     >/dev/null 2>&1 && [ "$tool" = jq ]; then echo "sudo dnf install -y jq"
      elif command -v pacman  >/dev/null 2>&1 && [ "$tool" = jq ]; then echo "sudo pacman -S --noconfirm jq"
      fi ;;
    bun)
      if   command -v brew >/dev/null 2>&1; then echo "brew install oven-sh/bun/bun"
      elif command -v npm  >/dev/null 2>&1; then echo "npm install -g bun"
      fi ;;
    rtk)
      # `cargo install rtk` is the WRONG crate — rtk must come from its repo.
      if   command -v brew  >/dev/null 2>&1; then echo "brew install rtk"
      elif command -v cargo >/dev/null 2>&1; then echo "cargo install --git https://github.com/rtk-ai/rtk"
      else echo "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh"
      fi ;;
  esac
}

# Offer to install Homebrew when no package manager is available — it's the
# universal one (covers jq/bun/trufflehog/rtk). Returns 0 if brew is present or
# was installed. Skipped non-interactively (the official installer needs a TTY
# for its sudo/RETURN prompts). curl|bash is the *only* official brew installer,
# runs in the user's own shell (not a CC hook), and only with explicit consent.
ensure_brew() {
  command -v brew >/dev/null 2>&1 && return 0
  [ "${CT_NONINTERACTIVE:-0}" = "1" ] && return 1
  confirm "  • No package manager found. Install Homebrew now (official installer, brew.sh)?" "Y" || return 1
  info "installing Homebrew (you may be prompted for your password)…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
    [ -x "$b" ] && eval "$("$b" shellenv)" && break
  done
  command -v brew >/dev/null 2>&1 && { ok "Homebrew installed."; return 0; }
  warn "Homebrew didn't complete — see https://brew.sh"; return 1
}

# ensure_dep <tool> <label> <required:0|1>
# If <tool> is missing (or, for bun, present but not runnable), offer to install it via the detected package manager
# (offering to install Homebrew first if there's no package manager at all).
# Returns 0 if present/installed, 1 otherwise. Dies if required.
# Non-interactive runs NEVER install anything: install commands may need sudo
# (would hang with no TTY) or run a vendor installer script — both require a
# human consenting at a prompt. We warn (or die, if required) instead.
# dep_usable <tool> — 0 when <tool> resolves on PATH and, for bun, actually runs.
# A bun that resolves but can't run (npm's blocked-postinstall placeholder passes -x
# and exits 1) counts as absent: hooks registered on it exit 1, not 2, so a guard
# wired to it would never block.
dep_usable() {
  command -v "$1" >/dev/null 2>&1 || return 1
  if [ "$1" = bun ]; then bun --version >/dev/null 2>&1 || return 1; fi
  return 0
}

ensure_dep() {
  local tool="$1" label="${2:-$1}" required="${3:-0}" cmd
  dep_usable "$tool" && return 0
  cmd="$(pm_install_cmd "$tool")"
  if [ "${CT_NONINTERACTIVE:-0}" = "1" ]; then
    if [ "$required" = "1" ]; then
      die "${label} not found. Install it first${cmd:+ (e.g.: ${cmd})}, then re-run."
    fi
    warn "${label} not found — skipping install in non-interactive mode${cmd:+ (install manually: ${cmd})}."
    return 1
  fi
  # No package manager can install this tool → offer to bootstrap Homebrew, retry.
  if [ -z "$cmd" ] && ensure_brew; then cmd="$(pm_install_cmd "$tool")"; fi
  if [ -n "$cmd" ]; then
    if confirm "  • ${label} not found — install via: ${cmd} ?" "Y"; then
      info "installing ${tool}…"
      if eval "$cmd" && { hash -r; dep_usable "$tool"; }; then ok "${tool} installed."; return 0; fi
      warn "${tool} install failed — install it manually: ${cmd}"
    fi
  elif [ "$tool" = bun ]; then
    warn "${label} not found and no brew/npm — install bun manually: https://bun.sh/install"
  elif [ "$tool" = jq ]; then
    warn "${label} not found and no supported package manager — install jq manually: https://jqlang.github.io/jq/download/"
  else
    warn "${label} not found and no supported package manager — install it manually."
  fi
  [ "$required" = "1" ] && die "${tool} is required. Aborting."
  return 1
}

# ── shell rc detection ────────────────────────────────────────────────────────
# Echoes the path to the interactive-shell rc file for the user's login shell.
detect_shell_rc() {
  local sh; sh="$(basename "${SHELL:-/bin/bash}")"
  case "$sh" in
    zsh)  printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [ -f "$HOME/.bashrc" ]; then printf '%s\n' "$HOME/.bashrc"; else printf '%s\n' "$HOME/.bash_profile"; fi ;;
    *)    printf '%s\n' "$HOME/.profile" ;;
  esac
}

# ── rc-write input guards (the SOLE sanctioned writer must fail closed) ───────
# assert_safe_alias_name NAME / assert_safe_config_dir DIR — die before any rc write if
# the value can't be safely embedded in the launcher block
#   alias NAME='CLAUDE_CONFIG_DIR="DIR" claude'
# An unsanitized value can break out of that quoting and inject code at rc-source or
# alias-expansion time: NAME sits unquoted before '=' (must be an identifier-safe token,
# no leading '-' or it parses as `alias` flags); DIR sits inside "…" inside '…' (a single
# quote breaks the outer '…', a double quote breaks the inner "DIR", a control char splits
# the line). Spaces are fine. Kit-created paths / chosen aliases never legitimately carry
# such characters, so REJECT rather than attempt escaping (which _alias_resolve_target
# would also have to reverse). Every setup_alias write path gates through these.
# The name charset also excludes '.' because the collision/enumerate paths
# (alias_target_elsewhere, enumerate_entry) interpolate the name into a grep ERE where '.'
# would be a wildcard — over-matching a sibling alias and driving a wrong dedupe/removal
# decision. Dropping it leaves no ERE metacharacter in an accepted name ('-' is ERE-literal).
assert_safe_alias_name() {
  local LC_ALL=C   # pin ASCII semantics: the [A-Za-z0-9] range is locale-collation-sensitive
  case "$1" in
    ''|-*|*[!A-Za-z0-9_-]*)
      die "Refusing to write an unsafe alias name to your shell rc — use letters, digits, '_', '-' (not leading '-') only: $1" ;;
  esac
}
assert_safe_config_dir() {
  local LC_ALL=C   # byte-wise: ASCII control bytes caught, UTF-8 path bytes (0x80+) accepted
  # The dir is reparsed inside "…" when the alias is INVOKED, so rc-source quoting is not
  # enough — `$` and backtick trigger command/parameter substitution at expansion time
  # (proven), and a trailing `\` can escape the closing quote. Reject those plus the quote
  # breakouts and line-splitting control chars. Spaces / ordinary punctuation / UTF-8 are
  # inert inside "…" once these are gone, so they stay allowed. The installer $HOME-expands
  # the path well before here, so a legitimate dir never carries a literal $, `, \, or quote.
  case "$1" in
    *"'"*|*'"'*|*'$'*|*'`'*|*'\'*|*[[:cntrl:]]*)
      die "Refusing to write an alias for an unsafe config dir (contains a quote, \$, \`, \\, or control character): $1" ;;
  esac
}

# ── idempotent managed-block writer ──────────────────────────────────────────
# write_managed_block FILE ID CONTENT
# Inserts/replaces a block delimited by markers keyed on ID. Re-running with the
# same ID replaces the prior block instead of appending a duplicate.
write_managed_block() {
  local file="$1" id="$2" content="$3"
  local begin="# >>> aka-claude-tools managed: ${id} >>>"
  local end="# <<< aka-claude-tools managed: ${id} <<<"
  touch "$file"
  local tmp; tmp="$(mktemp)"
  # Strip any prior block for this exact id, but EOF-safely: buffer the candidate and
  # drop it only when its end marker appears; an unterminated (corrupt) block is
  # flushed at EOF, never truncated — same guard as remove_managed_block.
  awk -v b="$begin" -v e="$end" '
    $0==b { if (skip) { for (i=0;i<n;i++) print buf[i] } skip=1; n=0; buf[n++]=$0; next }
    skip && $0==e { skip=0; n=0; next }
    skip { buf[n++]=$0; next }
    { print }
    END { if (skip) for (i=0;i<n;i++) print buf[i] }
  ' "$file" > "$tmp"
  printf '%s\n%s\n%s\n' "$begin" "$content" "$end" >> "$tmp"
  mv "$tmp" "$file"
}

# remove_managed_block FILE ID — delete our marker-delimited block if present.
# Returns 0 if it removed one, 1 if there was none. Used to drop a now-redundant
# alias block when the same alias is already provided elsewhere.
remove_managed_block() {
  local file="$1" id="$2"
  [ -f "$file" ] || return 1
  # Match the managed block for <id> AND its collision-renamed variants <id><N>:
  # on an alias-name collision the installer appends a numeric suffix (aka -> aka2),
  # and the documented uninstall only knows the default name. Removing the whole
  # <id>-family lets `remove_managed_block <rc> aka` also clear a leftover `aka2`
  # block. Scoped by an exact-then-digits match, so a DIFFERENT profile's block (a
  # different base name) is never touched. (Limitation: a profile deliberately named
  # `<id><N>` shares the family — rare, documented.)
  # Regex-escape the id before it goes into an ERE — an id with a metachar (e.g. a
  # dotted folder basename) must match literally, not over-match.
  local id_esc; id_esc="$(printf '%s' "$id" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  local pat="^# (>>>|<<<) aka-claude-tools managed: ${id_esc}[0-9]* (>>>|<<<)$"
  grep -qE "$pat" "$file" || return 1
  local tmp; tmp="$(mktemp)"
  # Buffer a candidate block and DROP it only once its end marker is seen; if a begin
  # marker has no matching end before EOF (a corrupt/tampered block), FLUSH the buffer
  # rather than let `skip` run to EOF and truncate the rest of the user's rc.
  awk -v p="$pat" '
    $0 ~ p && />>>$/ { if (skip) { for (i=0;i<n;i++) print buf[i] } skip=1; n=0; buf[n++]=$0; next }
    skip && $0 ~ p && /<<<$/ { skip=0; n=0; next }
    skip { buf[n++]=$0; next }
    { print }
    END { if (skip) for (i=0;i<n;i++) print buf[i] }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# sourced_paths FILE — print the existing files FILE `source`s / `.`-includes
# (one hop), with ~ / $HOME / $ZDOTDIR expanded and surrounding quotes removed
# (so `source "$HOME/x.sh"` is detected, not just the bare form). Best-effort, no
# eval; relative or var-built paths that don't expand here are skipped.
sourced_paths() {
  local src="$1" f
  [ -f "$src" ] || return 0
  while IFS= read -r f; do
    f="${f%%#*}"; f="${f%"${f##*[![:space:]]}"}"
    # Strip ONE layer of surrounding single/double quotes — `source "file"` and
    # `. 'file'` are common, and the unquoted-only match used to miss them.
    case "$f" in
      \"*\") f="${f#\"}"; f="${f%\"}" ;;
      \'*\') f="${f#\'}"; f="${f%\'}" ;;
    esac
    f="${f/#\~/$HOME}"; f="${f//\$HOME/$HOME}"; f="${f//\$\{HOME\}/$HOME}"
    f="${f//\$ZDOTDIR/${ZDOTDIR:-$HOME}}"; f="${f//\$\{ZDOTDIR\}/${ZDOTDIR:-$HOME}}"
    [ -n "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"
  done < <(grep -hE '^[[:space:]]*(source|\.)[[:space:]]+' "$src" 2>/dev/null | sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+//')
}

# _rc_unquote VALUE — strip ONE layer of surrounding single/double quotes, or, for
# an unquoted token, cut at the first whitespace. Used for both an alias body and a
# variable assignment's RHS.
_rc_unquote() {
  local v="$1"
  case "$v" in
    \"*) v="${v#\"}"; v="${v%%\"*}" ;;
    \'*) v="${v#\'}"; v="${v%%\'*}" ;;
    *)   v="${v%%[[:space:]]*}" ;;
  esac
  printf '%s' "$v"
}

# _lookup_rc_var NAME RC CHILD... — best-effort resolve a shell variable's value from
# assignments in the rc source graph, WITHOUT eval. Precedence:
#   1. a direct assignment (`export VAR=…` / `VAR=…`) in the TOP-LEVEL rc ($2) — the
#      user's own file is authoritative, so it wins regardless of where a `source`
#      sits relative to it (we can't model true cross-file execution order from a flat
#      grep, and the parent rc is where a user overrides a sourced default);
#   2. else a direct assignment anywhere in the source graph (last in file order);
#   3. else a `: "${VAR:=default}"` conditional default.
# Empty if the variable isn't assigned anywhere we can see. NOTE: this is a best-effort
# parser, not a shell — a var re-assigned by a sourced CHILD after the parent (rare)
# is not modeled beyond rule 1; the detector errs safe (a mis-resolved target only
# changes dedup-vs-alternate-name, never overwrites a user's alias).
_lookup_rc_var() {
  local name="$1"; shift
  local rc="$1"
  local direct val=""
  direct="$(grep -hE "^[[:space:]]*(export[[:space:]]+)?${name}=" "$rc" 2>/dev/null | tail -1)"
  [ -z "$direct" ] && direct="$(grep -hE "^[[:space:]]*(export[[:space:]]+)?${name}=" "$@" 2>/dev/null | tail -1)"
  if [ -n "$direct" ]; then
    val="${direct#*${name}=}"
    val="$(_rc_unquote "$val")"
  else
    local defln
    defln="$(grep -hE ":[[:space:]]+[\"']?\\\$\{${name}:=" "$@" 2>/dev/null | tail -1)"
    [ -n "$defln" ] && val="$(printf '%s' "$defln" | sed -n "s/.*\${${name}:=\\([^}]*\\)}.*/\\1/p")"
  fi
  printf '%s' "$val"
}

# _expand_rc_vars STRING FILE... — substitute $VAR / ${VAR} references in STRING with
# their values resolved from the rc source graph (best-effort, no eval). HOME/ZDOTDIR
# are left for the caller's dedicated expansion. A few passes resolve simple nesting
# (e.g. CC_FLEET_DIR="$HOME/.claude-clean"); unresolved references are left intact.
_expand_rc_vars() {
  local s="$1"; shift
  local pass name names changed
  for pass in 1 2 3; do
    case "$s" in *'$'*) ;; *) break ;; esac
    # Longest name first: the bare `$VAR` form is a substring replace, so a name that
    # is a prefix of another ($CC vs $CC_FLEET_DIR) must be substituted AFTER the
    # longer one or it would clobber its prefix. awk/sort/cut are all BSD+GNU-portable.
    names="$(printf '%s' "$s" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*' | sed -E 's/[$ {}]//g' | sort -u | awk '{ print length($0), $0 }' | sort -k1,1nr | awk '{ print $2 }')"
    changed=0
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      case "$name" in HOME|ZDOTDIR) continue ;; esac
      local val; val="$(_lookup_rc_var "$name" "$@")"
      [ -z "$val" ] && continue
      s="${s//\$\{$name\}/$val}"; s="${s//\$$name/$val}"; changed=1
    done <<EOF
$names
EOF
    [ "$changed" = "0" ] && break
  done
  printf '%s' "$s"
}

# alias_target_elsewhere NAME RC — if alias NAME is already defined OUTSIDE our
# own managed block — in RC or ANY file reachable through its `source` chain
# (fully recursive) — print the CLAUDE_CONFIG_DIR it resolves to (expanded), or
# "OTHER" if it's an alias of that name that isn't a Claude-config launcher.
# Empty = not defined in that scope. Lets the installer avoid duplicating or
# shadowing an alias the user already has (e.g. one a fleet-wide aliases file
# provides). Walks the WHOLE source graph with a visited-set, so a source cycle
# (A sources B sources A, or self-source) can't loop and each file is scanned
# once — cost is O(distinct files), a handful in any real rc.
alias_target_elsewhere() {
  local name="$1" rc="$2"
  [ -f "$rc" ] || return 0
  local begin="# >>> aka-claude-tools managed: ${name} >>>"
  local end="# <<< aka-claude-tools managed: ${name} <<<"
  local stripped; stripped="$(mktemp)"
  # RC with our own block removed, so we only see OTHER definitions.
  awk -v b="$begin" -v e="$end" '$0==b {skip=1} $0==e {skip=0; next} skip!=1 {print}' "$rc" > "$stripped"
  # Breadth-first over the source graph. queue = files to expand; seen = files
  # already expanded (cycle/repeat guard, space-delimited); files = what to grep
  # (rc represented by its stripped copy). Index walk — no array slicing, so it's
  # safe under set -u on old bash.
  local files=("$stripped") queue=("$rc") seen=" " cur kid i=0
  while [ "$i" -lt "${#queue[@]}" ]; do
    cur="${queue[$i]}"; i=$((i + 1))
    case "$seen" in *" $cur "*) continue ;; esac
    seen="$seen$cur "
    while IFS= read -r kid; do
      case "$seen" in *" $kid "*) continue ;; esac
      files+=("$kid"); queue+=("$kid")
    done < <(sourced_paths "$cur")
  done
  local def; def="$(grep -hE "^[[:space:]]*alias[[:space:]]+${name}=" "${files[@]}" 2>/dev/null | tail -1)"
  if [ -z "$def" ]; then rm -f "$stripped"; return 0; fi
  # files[] still includes $stripped here, so resolve (var expansion reads the graph)
  # BEFORE removing the temp. _alias_resolve_target is the SHARED parser — also used
  # by enumerate_entry's whole-surface scan — so the two can never disagree on how an
  # alias body resolves to a profile dir.
  local out; out="$(_alias_resolve_target "$def" "${files[@]}")"
  rm -f "$stripped"
  printf '%s\n' "$out"
}

# _alias_resolve_target ALIAS_LINE FILE... — given a matched `alias NAME=…` line and
# the rc source-graph files (for $VAR resolution), print the CLAUDE_CONFIG_DIR it
# launches (expanded), or "OTHER" if the body carries no CLAUDE_CONFIG_DIR. Empty if
# the line is empty. Extracted verbatim from alias_target_elsewhere so both the
# single-name resolver and the --enumerate whole-surface scan share one code path.
_alias_resolve_target() {
  local def="$1"; shift
  [ -z "$def" ] && return 0
  # Everything after the first CLAUDE_CONFIG_DIR= in the alias body. If there is no
  # such assignment the alias exists but isn't a Claude-config launcher → OTHER.
  local raw; raw="${def#*CLAUDE_CONFIG_DIR=}"
  if [ "$raw" = "$def" ]; then printf 'OTHER\n'; return 0; fi
  # Unescape backslash-escaped quotes/$ from a double-quoted alias body, e.g.
  #   alias x="… CLAUDE_CONFIG_DIR=\"\$HOME/.claude-x\" …"
  # whose extracted RHS arrives as \"\$HOME/.claude-x\" and otherwise mis-parses.
  raw="$(printf '%s' "$raw" | sed -e 's/\\\(["'"'"'$]\)/\1/g')"
  local t; t="$(_rc_unquote "$raw")"
  if [ -z "$t" ]; then printf 'OTHER\n'; return 0; fi
  # Resolve $VAR/${VAR} from the rc source graph, then HOME/ZDOTDIR.
  t="$(_expand_rc_vars "$t" "$@")"
  t="${t/#\~/$HOME}"; t="${t//\$HOME/$HOME}"; t="${t//\$\{HOME\}/$HOME}"
  t="${t//\$ZDOTDIR/${ZDOTDIR:-$HOME}}"; t="${t//\$\{ZDOTDIR\}/${ZDOTDIR:-$HOME}}"
  printf '%s\n' "$t"
}

# rc_source_chain RC — print RC and every file reachable through its source/. chain
# (transitive, cycle-safe), one per line. The whole-surface analogue of the BFS that
# alias_target_elsewhere walks for a single name: enumerate_entry greps these files
# for every launcher alias. Index walk, set -u safe.
rc_source_chain() {
  local rc="$1"
  [ -f "$rc" ] || return 0
  local queue=("$rc") seen=" " cur kid i=0
  while [ "$i" -lt "${#queue[@]}" ]; do
    cur="${queue[$i]}"; i=$((i + 1))
    case "$seen" in *" $cur "*) continue ;; esac
    seen="$seen$cur "
    printf '%s\n' "$cur"
    while IFS= read -r kid; do
      case "$seen" in *" $kid "*) continue ;; esac
      queue+=("$kid")
    done < <(sourced_paths "$cur")
  done
}

# Shared jq predicate used by the superseded kit-MATCHER migration below. A registration
# "belongs to THIS profile" iff its command, after normalizing $HOME / ${HOME} / a leading
# ~ to the real home and stripping the single-quotes the installer wraps the dir in,
# resolves to <cfg>/hooks/<name>. The normalization is LITERAL split/join inside jq (NOT a
# regex, NOT shell `eval` of the stored command), so quoting/escapes in the command can't
# misfire — and it stays anchored to this profile's hooks dir (the owner-stamp), so a
# same-named hook under a DIFFERENT path is never mistaken for the kit's.
_AKA_HOOK_JQ_DEFS='
  def _repl($a;$b): if $a=="" then . else split($a)|join($b) end;
  def _norm($home): _repl("${HOME}";$home)|_repl("$HOME";$home)
    | (if startswith("~/") then $home + .[1:] else . end)
    | _repl("\u0027";"") | sub("[[:space:]]+$";"");
  def _cmd_str: (.command // "")
    | (if type=="array" then (map(strings)|join(" ")) elif type=="string" then . else "" end);
  def _reg_cmds: [ (.hooks // {}) | to_entries[] | .value[]? | (.hooks // [])[]? | _cmd_str ];
  def _is_kit_reg($home;$cfg;$name):
    _reg_cmds | any(.[]; _norm($home) | endswith($cfg + "/hooks/" + $name));
'

# ── superseded kit-MATCHER migration ──────────────────────────────────────────
# AKA_SUPERSEDED_MATCHERS — kit hooks whose MATCHER (not file name) changed across kit
# versions. When the kit BROADENS a hook's matcher (e.g. leak-guard gained the SearXNG MCP
# surface: "WebSearch|WebFetch" → "WebSearch|WebFetch|mcp__searxng__", #59), the hook FILE is
# unchanged — so the marker-based file-rename self-clean (install.sh 4d-pre2) doesn't apply —
# and the matcher-gated
# dedup (prune_hook_regs_resolving) reads the OLD-matcher reg as a deliberate user tweak and
# keeps it, leaving the guard registered under BOTH matchers (double-firing on the web tools).
# Listing the SUPERSEDED matcher here lets an upgrade prune that stale KIT reg before the merge
# re-adds the current one. A genuine USER matcher tweak — any matcher NOT in this list — is
# left untouched (so re-scoping leak-guard to just "WebFetch" still survives).
#
# INVARIANT (security-safe): only list a prior matcher when the current kit matcher is a
# SUPERSET of it (a broadening). Then pruning the stale reg can only ADD matched tools on the
# re-added current reg, never REDUCE a guard's coverage — so even in the one ambiguous case (a
# user who independently typed the EXACT old kit default, indistinguishable from a stale kit
# reg) the upgrade gives strictly more egress scanning, never less. The invariant is ENFORCED
# by test_scn_upgrade_matcher_migration.sh (every entry must be subsumed by the live
# additions.json matcher for its hook). Format: JSON array of {hook (basename), matcher
# (the superseded string)}.
#
# CURRENTLY EMPTY. The one historical entry was leak-guard's SearXNG matcher broadening
# ("WebSearch|WebFetch" → "WebSearch|WebFetch|mcp__searxng__"). That entry keyed on the OLD
# FILE NAME leak-guard.sh; once leak-guard was ported to leak-guard.ts the file ALSO changed,
# so a pre-port profile's stale "WebSearch|WebFetch" reg now points at leak-guard.sh — a file
# the kit no longer ships. The marker-based self-clean (install.sh 4d-pre2) removes that file
# AND prunes its registration by basename (matcher-AGNOSTIC), so ANY old leak-guard.sh reg
# (any matcher) is cleaned and the merge re-adds the single current-matcher leak-guard.ts reg.
# The file-rename path therefore SUBSUMES the matcher-broadening case here, and a leak-guard.sh
# entry would now FAIL the SUBSET INVARIANT (no live additions.json hook ends in leak-guard.sh).
# The build_superseded_add machinery below remains for a FUTURE matcher-only broadening (a hook
# whose FILE NAME is unchanged across the broadening); add an entry then.
AKA_SUPERSEDED_MATCHERS='[]'

# build_superseded_add <add-json> → a SYNTHETIC add (JSON on stdout, or {} if none apply)
# Maps the kit's real registrations (<add-json> — exactly what is registered THIS run) onto
# the SUPERSEDED matcher(s): for each kit hook whose matcher changed, emit a clone of its add
# group carrying the OLD matcher + the SAME command the kit writes. Feeding this synthetic add
# to prune_hook_regs_resolving prunes the stale OLD-matcher reg using that pruner's strong,
# proven logic — full $HOME / $CLAUDE_CONFIG_DIR / ~ / both-quote-form normalization, FULL-
# command equality (so an AUGMENTED user invocation like `bash …/leak-guard.sh` under the old
# matcher is NOT a match and survives), per-hook, matcher-gated. Reusing that pruner (rather
# than a parallel weaker owner-stamp) is why a stale reg spelled with $CLAUDE_CONFIG_DIR or
# double quotes is still caught, and why only the kit's exact canonical command is pruned.
# A kit hook's command is unchanged across the matcher broadening, so the synthetic command
# matches the stale reg after normalization. Hooks are identified by the add command containing
# /hooks/<hook> (the add is the kit's own freshly-built, canonical registration).
# CONSERVATIVE BOUNDARY: because the prune is full-command-equality against the kit's CURRENT
# command, this migrates a MATCHER-only change. If a future version changed BOTH the matcher AND
# the command/file name, the stale reg keeps its old command, equality fails, and it is NOT
# pruned here — that is the marker-based file-rename self-clean's job (install.sh 4d-pre2).
build_superseded_add() {
  local add="$1"
  jq -nc --argjson add "$add" --argjson sup "$AKA_SUPERSEDED_MATCHERS" \
    "$_AKA_HOOK_JQ_DEFS"'
    # (event, superseded-matcher, kit-hooks-array) for each add group matching a superseded hook
    [ ($add.hooks // {}) | to_entries[] | .key as $e | (.value // [])[]?
      | select(type=="object" and ((.hooks|type)=="array"))
      | . as $grp
      | $sup[] as $s
      # contains (not endswith): the add command may carry an interpreter prefix and/or
      # trailing args (`bun .../x.ts --flag`), so match on the hook path appearing anywhere.
      # This is only a SELECTOR — the full-command equality in prune_hook_regs_resolving is
      # the actual gate, so a loose selection can only MISS, never over-prune a USER reg: the
      # synthetic add is cloned from $add (the kit OWN registration this run), so it carries
      # only KIT commands — a user reg, never present in $add, can never be synthesized/pruned.
      | select( ($grp.hooks // []) | any( (type=="object") and (_cmd_str | contains("/hooks/" + $s.hook)) ) )
      | { e:$e, m:$s.matcher, hooks:$grp.hooks } ]
    | reduce .[] as $x ({}; .[$x.e] += [ { matcher:$x.m, hooks:$x.hooks } ])
    | if (length==0) then {} else { hooks: . } end'
}
