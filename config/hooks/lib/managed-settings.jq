# managed-settings.jq — the kit-managed subset of a profile's settings.json.
#
# The single definition of "which settings belong to the kit", shared by
# install.sh (when it writes <profile>/.aka-integrity.json) and by
# hooks/integrity-check.ts (when it re-checks that manifest at session start).
# Both run it as:
#
#   jq -S -c --argjson m <manifest> --arg home <HOME> --argjson roots <dirs> \
#      -f managed-settings.jq  < settings.json
#
# and hash the output bytes, so the two sides agree byte-for-byte as long as the
# settings haven't changed.
#
#   $m      the integrity manifest (only .files and .kit are read). The kit's own
#           hook files are the manifest's top-level "hooks/<name>" entries.
#   $home   $HOME, used to expand the $HOME'<dir>' form the installer writes into
#           hook commands.
#   $roots  the profile directory, in every spelling the caller knows (as given,
#           and symlink-resolved).
#
# The subset is:
#   hooks       every hook registration whose command references one of the
#               kit's hook files under <profile>/hooks/
#   deny        the permissions.deny entries the kit shipped ($m.kit.deny)
#   sandbox     sandbox.enabled, only when the kit installed the sandbox addition
#   statusLine  the statusLine, only when the kit installed its status line
#
# Anything else (the user's own hooks, allow/ask rules, env keys, other deny
# rules) is outside the subset, so editing it is never reported as drift.

def cmdstr:
  if type == "string" then .
  elif type == "array" then ([ .[] | select(type == "string") ] | join(" "))
  else "" end;

def norm:
  cmdstr
  | gsub("\\$\\{HOME\\}"; $home) | gsub("\\$HOME"; $home)
  | gsub("~/"; $home + "/")
  | gsub("['\"]"; "");

def arr: if type == "array" then .[] else empty end;

( [ ($m.files // {}) | keys[] | select(test("^hooks/[^/]+$")) ] ) as $rels
| ( [ $roots[] as $r | $rels[] | $r + "/" + . ] ) as $needles
| (if type == "object" then . else {} end) as $s
| ( ($m.kit // {}) ) as $kit
| {
    hooks: [
      ($s.hooks | if type == "object" then to_entries[] else empty end)
      | .key as $event
      | (.value | arr) | select(type == "object") as $reg
      | ($reg.hooks | arr) | select(type == "object")
      | select((.command | norm) as $c | any($needles[]; . as $n | $c | contains($n)))
      | { event: $event, matcher: ($reg.matcher // ""), type: (.type // ""), command: .command }
    ] | unique,
    deny: [
      ($s.permissions | if type == "object" then .deny else null end | arr)
      | select(type == "string")
      | . as $d | select(any(($kit.deny // []) | arr; . == $d))
    ] | unique
  }
| if $kit.sandbox == true
  then .sandbox = ($s.sandbox | if type == "object" then .enabled else null end)
  else . end
| if $kit.statusLine == true then .statusLine = $s.statusLine else . end
