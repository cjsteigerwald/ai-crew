#!/usr/bin/env bash
# ai-crew.sh — mechanical steps of the ai-crew-update skill (see SKILL.md).
#
# Every subcommand FAILS CLOSED: any check it cannot perform (missing file,
# unparseable JSON, wrong shape) is an error with a nonzero exit, never a
# silent pass. A gate that prints success after checking nothing is the defect
# this script exists to prevent.
#
# Portability: bash 3.2 (stock macOS) — no associative arrays, no mapfile, no
# ${var,,}. Parallel arrays carry every per-marketplace and per-target record.
# sha256sum falls back to `shasum -a 256`, flock to a `mkdir` lock directory.
#
# Shape notes (why the jq is written the way it is):
#   - installed_plugins.json keys entries under `.plugins`, and each value is an
#     ARRAY (one element per scope), not a bare object — hence `.plugins[$k][0]`.
#   - A wrong jq path prints `null` and exits 0 unless `-e` is used, so every
#     read here either uses `-e` or validates the type explicitly.
#   - A missing installed key means NOT INSTALLED; an unreadable/invalid
#     installed_plugins.json or a missing manifest is an ERROR. The two are
#     never conflated.
#   - Plugin keys are built from the MARKETPLACE entry name, not plugin.json.
#
# Marketplaces (multi):
#   Every subcommand iterates a LIST of marketplaces, each a {name, repo} pair.
#   The list comes from, in order: $AI_CREW_MARKETPLACES ("n=path;n=path"), the
#   crew config file's `.marketplaces` array, else the single default
#   `cjs-plugins=$AI_CREW_REPO`. Clone/receipt/snapshot paths for the DEFAULT
#   marketplace name are exactly the historical single-marketplace files, so the
#   default configuration behaves as it always has; every other marketplace gets
#   sibling files keyed by name (`gate-receipt.<name>.json`,
#   `pre-update.<name>.json`, `<marketplaces-dir>/<name>`).
#   known_marketplaces.json is cross-checked when present: a configured
#   marketplace missing from it is a WARNING (the catalogue may simply not have
#   been added yet), never a failure.
#   The vendor `codex@openai-codex` is enumerated ONCE — with the first
#   marketplace in the list — because it lives outside every crew marketplace.
#
# Selective-install contract (a marketplace lists more than a user installs):
#   - gate and bind cover EVERY plugin in each marketplace.json. That is release
#     validation: an untested plugin in the catalogue is still a defect.
#   - snapshot, update, verify and reconcile cover only the plugins actually
#     present in installed_plugins.json. A catalogue plugin that is not
#     installed is INFO (`skip: <key> not installed`), never a failure — there
#     is nothing to update, nothing to roll back, and nothing to verify.
#   - status lists both sets.
#
# Chain of custody (gate -> bind -> update -> reconcile -> verify):
#   - gate writes a receipt {repoHead, marketplaceSha256, ...} per marketplace
#     only when every suite passed on a clean tree; any gate run first deletes
#     every old receipt.
#   - update (under one exclusive lock) requires bind to pass, each receipt to
#     match its bound HEAD and its clone's marketplace.json, records the bound
#     HEADs in each snapshot under the reserved key "_bound", and aborts if a
#     clone HEAD moves or its tree gets dirty before any individual
#     `claude plugin update` (each run with the lock fd closed).
#   - gate refuses the receipt if HEAD moved while the suites ran.
#   - reconcile repairs the user's own config against the INSTALLED plugins:
#     plugins register their hooks through their own `hooks/hooks.json` (the
#     harness resolves ${CLAUDE_PLUGIN_ROOT}), so a copy of the same script in
#     settings.json is a LEGACY DOUBLE REGISTRATION — the hook fires twice, or
#     runs the old code. reconcile removes exactly those entries — and only
#     where the registered path is PROVABLY the plugin's own file (it resolves
#     inside the plugin's install directory, or its content hashes equal to the
#     shipped hook, or the user recorded it with --record-migrated) — sets
#     fragment-declared env vars that are absent, and maintains the plugin's
#     CLAUDE.md marker block. It never touches a hook whose script basename no
#     plugin declares, and it keeps and reports every basename collision it
#     cannot prove: a user's own hook of the same name is not ours to delete.
#   - verify fails if a clone moved or is dirty after bind, if `_bound` is
#     absent, if a plugin's hooks.json is missing or unparseable, if any legacy
#     settings.json entry for a plugin-owned hook script survives, or if a
#     fragment-declared env var is unset.
#
# Fixture suite: test-ai-crew.sh (same directory). It must pass after any edit.
set -euo pipefail

MARKETPLACE=cjs-plugins
VENDOR_KEY=codex@openai-codex
VENDOR_MARKETPLACE=openai-codex
VENDOR_NAME=codex
BOUND_KEY=_bound
SETTINGS_FRAGMENT=settings.fragment.json
CLAUDE_MD_FRAGMENT=claude-md.fragment.md
HOOKS_MANIFEST=hooks/hooks.json

# ONE config root for every default. Honouring CLAUDE_CONFIG_DIR for some paths
# and $HOME/.claude for the rest would read installed_plugins.json from one tree
# and write settings.json into another — a split brain that looks like success.
AI_CREW_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}

AI_CREW_REPO=${AI_CREW_REPO:-$HOME/repos/ai-crew}
AI_CREW_CLONE=${AI_CREW_CLONE:-$AI_CREW_CONFIG_DIR/plugins/marketplaces/$MARKETPLACE}
AI_CREW_INSTALLED=${AI_CREW_INSTALLED:-$AI_CREW_CONFIG_DIR/plugins/installed_plugins.json}
AI_CREW_CACHE=${AI_CREW_CACHE:-$AI_CREW_CONFIG_DIR/plugins/cache}
AI_CREW_VENDOR_CLONE=${AI_CREW_VENDOR_CLONE:-$AI_CREW_CONFIG_DIR/plugins/marketplaces/$VENDOR_MARKETPLACE}
AI_CREW_VENDOR_MANIFEST=${AI_CREW_VENDOR_MANIFEST:-$AI_CREW_VENDOR_CLONE/plugins/$VENDOR_NAME/.claude-plugin/plugin.json}
AI_CREW_SNAPSHOT=${AI_CREW_SNAPSHOT:-$AI_CREW_CONFIG_DIR/plugins/data/ai-crew-update/pre-update.json}
AI_CREW_RECEIPT=${AI_CREW_RECEIPT:-$(dirname "$AI_CREW_SNAPSHOT")/gate-receipt.json}
AI_CREW_CREW_CONFIG=${AI_CREW_CREW_CONFIG:-$AI_CREW_CONFIG_DIR/plugins/data/crew/config.json}
AI_CREW_KNOWN=${AI_CREW_KNOWN:-$AI_CREW_CONFIG_DIR/plugins/known_marketplaces.json}
AI_CREW_DATA_DIR=${AI_CREW_DATA_DIR:-$(dirname "$AI_CREW_SNAPSHOT")}
AI_CREW_AMBIGUOUS_ACK=${AI_CREW_AMBIGUOUS_ACK:-$AI_CREW_DATA_DIR/ambiguous-ack.json}
AI_CREW_MIGRATED=${AI_CREW_MIGRATED:-$AI_CREW_DATA_DIR/migrated-hooks.json}
AI_CREW_SETTINGS=${AI_CREW_SETTINGS:-$AI_CREW_CONFIG_DIR/settings.json}
AI_CREW_CLAUDE_MD=${AI_CREW_CLAUDE_MD:-$AI_CREW_CONFIG_DIR/CLAUDE.md}
CLAUDE_BIN=${CLAUDE_BIN:-claude}

TMPD=""
LOCKDIR=""
LOCKTOKEN=""
cleanup() {
  [ -n "$TMPD" ] && rm -rf "$TMPD"
  [ -n "$LOCKDIR" ] && lock_drop "$LOCKDIR"
  return 0
}
trap cleanup EXIT

die() { echo "ai-crew: ERROR: $*" >&2; exit 1; }
warn() { echo "ai-crew: WARNING: $*" >&2; }

usage() {
  cat >&2 <<'EOF'
usage: ai-crew.sh <status|gate|bind|snapshot|update|reconcile|verify> [--dry-run]
  status     read-only installed-vs-available table (+ reconcile state)
  gate       run every local plugin test suite; on success write the gate receipts
  bind       prove each marketplace clone == the tested local repo
  snapshot   record pre-update version/sha/installPath of every INSTALLED plugin
  update     lock + bind + receipts + snapshots, then `claude plugin update` each
  reconcile  repair settings.json / CLAUDE.md for the installed plugins
             (--dry-run, --record-migrated <path>, or
              --accept-ambiguous <event>/<base>=<command>
              [--args JSON] [--matcher STRING])
  verify     prove the final install matches the bound manifests, then reconcile
EOF
  exit 2
}

# tmpd: create the per-run work dir once, in $TMPD. It sets the variable rather
# than printing it, because `d=$(tmpd)` would run in a subshell — the assignment
# would not survive, every call would create a NEW directory, and the EXIT trap
# would clean up none of them.
tmpd() {
  [ -n "$TMPD" ] && return 0
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/ai-crew.XXXXXX") || die "cannot create a temp dir"
  # The work dir stages the merged settings.json, so it must never be group- or
  # world-readable: a shared /tmp would otherwise expose whatever the user keeps
  # in there. mktemp -d creates 0700, but that is a documented default rather
  # than something worth assuming on every platform — say it explicitly.
  chmod 700 "$TMPD" || die "cannot restrict permissions on $TMPD"
}

# ---------------------------------------------------------------- marketplaces

# expand_tilde <path>: leading ~ or ~/ -> $HOME. Only the leading form; a ~
# elsewhere in a path is a legitimate character and is left alone.
expand_tilde() {
  # shellcheck disable=SC2088  # a literal ~ is the PATTERN matched here, not a path
  case $1 in
    "~") echo "$HOME" ;;
    "~/"*) echo "$HOME/${1#\~/}" ;;
    *) echo "$1" ;;
  esac
}

# mkt_add <name> <repo>: append one marketplace, deriving its clone, receipt and
# snapshot paths. The default marketplace keeps the historical paths, so nothing
# about a single-marketplace install changes.
mkt_add() {
  local name=$1 repo=$2 existing
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid marketplace name '$name'"
  [ -n "$repo" ] || die "marketplace '$name' has an empty repo path"
  for existing in ${MKT_NAMES[@]+"${MKT_NAMES[@]}"}; do
    [ "$existing" = "$name" ] && die "marketplace '$name' listed twice"
  done
  MKT_NAMES+=("$name")
  MKT_REPOS+=("$(expand_tilde "$repo")")
  if [ "$name" = "$MARKETPLACE" ]; then
    MKT_CLONES+=("$AI_CREW_CLONE")
    MKT_RECEIPTS+=("$AI_CREW_RECEIPT")
    MKT_SNAPSHOTS+=("$AI_CREW_SNAPSHOT")
  else
    MKT_CLONES+=("$(dirname "$AI_CREW_CLONE")/$name")
    MKT_RECEIPTS+=("$(dirname "$AI_CREW_RECEIPT")/gate-receipt.$name.json")
    MKT_SNAPSHOTS+=("$(dirname "$AI_CREW_SNAPSHOT")/pre-update.$name.json")
  fi
}

# known_names: marketplace names from known_marketplaces.json, if it exists.
# The file's exact shape is not contractual here, so several plausible shapes
# are accepted; an unreadable file yields nothing (the cross-check is advisory).
known_names() {
  [ -f "$AI_CREW_KNOWN" ] || return 0
  jq -r 'def nm: if type == "object" then (.name // empty) else . end;
    if type == "object" and (.marketplaces | type) == "object" then (.marketplaces | keys[])
    elif type == "object" and (.marketplaces | type) == "array" then (.marketplaces[] | nm)
    elif type == "object" then keys[]
    elif type == "array" then (.[] | nm)
    else empty end' "$AI_CREW_KNOWN" 2>/dev/null || true
}

# init_marketplaces: fills MKT_NAMES[]/MKT_REPOS[]/MKT_CLONES[]/MKT_RECEIPTS[]/
# MKT_SNAPSHOTS[]. Dies on an unusable source rather than silently falling back:
# a config file that exists but is malformed is an ERROR, not "use the default".
init_marketplaces() {
  local spec pair name repo out known m found k
  MKT_NAMES=(); MKT_REPOS=(); MKT_CLONES=(); MKT_RECEIPTS=(); MKT_SNAPSHOTS=()
  spec=${AI_CREW_MARKETPLACES:-}
  if [ -n "$spec" ]; then
    while IFS= read -r pair; do
      [ -n "$pair" ] || continue
      case $pair in
        *=*) name=${pair%%=*}; repo=${pair#*=} ;;
        *) die "AI_CREW_MARKETPLACES entry '$pair' is not name=repo-path" ;;
      esac
      mkt_add "$name" "$repo"
    done <<<"$(printf '%s' "$spec" | tr ';' '\n')"
  elif [ -f "$AI_CREW_CREW_CONFIG" ]; then
    jq -e '(type == "object") and (.marketplaces | type == "array") and (.marketplaces | length > 0)' \
      "$AI_CREW_CREW_CONFIG" >/dev/null 2>&1 \
      || die "$AI_CREW_CREW_CONFIG: unparseable, or .marketplaces is not a non-empty array"
    out=$(jq -r 'def f($w): if type != "string" then "<non-string \($w)>" elif . == "" then "<empty \($w)>" else . end;
      .marketplaces[] | [ (.name | f("name")), (.repo | f("repo")) ] | @tsv' "$AI_CREW_CREW_CONFIG") \
      || die "$AI_CREW_CREW_CONFIG: could not enumerate .marketplaces"
    while IFS=$'\t' read -r name repo; do
      [ -n "$name" ] || continue
      case $repo in
        "<"*">") die "$AI_CREW_CREW_CONFIG: marketplace '$name' has an invalid repo '$repo'" ;;
      esac
      mkt_add "$name" "$repo"
    done <<<"$out"
  else
    mkt_add "$MARKETPLACE" "$AI_CREW_REPO"
  fi
  [ "${#MKT_NAMES[@]}" -gt 0 ] || die "no marketplaces configured"
  if [ -f "$AI_CREW_KNOWN" ]; then
    known=$(known_names)
    for m in "${!MKT_NAMES[@]}"; do
      found=0
      while IFS= read -r k; do
        [ "$k" = "${MKT_NAMES[$m]}" ] && found=1
      done <<<"$known"
      [ "$found" -eq 1 ] || warn "marketplace ${MKT_NAMES[$m]} is configured but absent from $AI_CREW_KNOWN — add it with 'claude plugin marketplace add'"
    done
  fi
}

# mkt_header <idx>: one banner line per marketplace so multi-marketplace output
# is attributable. Printed for the single-marketplace case too, so the output
# format never depends on how many are configured.
mkt_header() { echo "== marketplace ${MKT_NAMES[$1]} (${MKT_REPOS[$1]})"; }

# ---------------------------------------------------------------- enumeration

# list_plugins <root>: fills NAMES[] / SOURCES[] from <root>'s marketplace.json.
# Dies on a missing/unparseable file, a non-array or empty `.plugins`, or any
# entry whose name/source fails validation.
list_plugins() {
  local root=$1 file out name src
  file="$root/.claude-plugin/marketplace.json"
  [ -f "$file" ] || die "marketplace file not found: $file"
  jq -e '(.plugins | type == "array") and (.plugins | length > 0)' "$file" >/dev/null 2>&1 \
    || die "$file: unparseable, or .plugins is not a non-empty array"
  # Non-string and empty fields are mapped to sentinels that fail the regexes
  # below. (An object source would otherwise make @tsv itself error out, and an
  # empty leading field would be swallowed by `read`, shifting source into name.)
  out=$(jq -r 'def f($what): if type != "string" then "<non-string \($what): \(type)>"
                             elif . == "" then "<empty \($what)>" else . end;
    .plugins[] | [ (.name | f("name")), (.source | f("source")) ] | @tsv' "$file") \
    || die "$file: could not enumerate .plugins"
  NAMES=(); SOURCES=()
  while IFS=$'\t' read -r name src; do
    [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "$file: invalid plugin name '$name'"
    if ! [[ $src =~ ^\./[A-Za-z0-9._-]+$ ]] || [[ $src == ./. || $src == ./.. ]]; then
      die "$file: plugin '$name' has invalid source '$src' (must be ./<dir>)"
    fi
    NAMES+=("$name"); SOURCES+=("$src")
  done <<<"$out"
  [ "${#NAMES[@]}" -gt 0 ] || die "$file: no plugins enumerated"
}

# manifest_version <plugin.json>: prints .version or dies.
manifest_version() {
  [ -f "$1" ] || die "manifest not found: $1"
  jq -e -r '.version | select(type == "string" and length > 0)' "$1" 2>/dev/null \
    || die "$1: missing or non-string .version"
}

# sha256_of <file>: GNU coreutils sha256sum, else BSD/macOS `shasum -a 256`.
sha256_of() {
  local s
  if command -v sha256sum >/dev/null 2>&1; then
    s=$(sha256sum -- "$1" 2>/dev/null) || die "cannot sha256 $1"
  elif command -v shasum >/dev/null 2>&1; then
    s=$(shasum -a 256 -- "$1" 2>/dev/null) || die "cannot sha256 $1"
  else
    die "neither sha256sum nor shasum is installed — cannot hash $1"
  fi
  echo "${s%% *}"
}

# sha256_try <file>: the hash, or THE EMPTY STRING if the file cannot be
# hashed — absent, not a regular file, unreadable, or no hash tool installed.
# Unlike sha256_of this never dies, because "I could not hash it" is a normal
# answer when the thing being hashed is a path out of a user's settings.json.
# Every caller treats the empty string as NOT PROVEN: a hash that could not be
# taken must never compare equal to anything.
sha256_try() {
  local s
  [ -f "$1" ] && [ -r "$1" ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    s=$(sha256sum -- "$1" 2>/dev/null) || return 0
  elif command -v shasum >/dev/null 2>&1; then
    s=$(shasum -a 256 -- "$1" 2>/dev/null) || return 0
  else
    return 0
  fi
  echo "${s%% *}"
}

# canon_path <path>: the path with every symlink resolved, on stdout, exit 0 —
# or NOTHING and exit 1 when it cannot be resolved (no realpath/readlink -f on
# this box, or a component of the path does not exist).
#
# The failure is signalled by the EXIT STATUS, never by falling back to the
# literal path. An earlier version returned the input unchanged on failure,
# which made "resolved" and "could not resolve" indistinguishable to the caller
# — and the only caller decides whether a file may be REMOVED from the user's
# settings, where the two must lead to opposite answers.
canon_path() {
  local r
  if command -v realpath >/dev/null 2>&1 && r=$(realpath -- "$1" 2>/dev/null) && [ -n "$r" ]; then
    printf '%s\n' "$r"
    return 0
  fi
  # Stock macOS before 12.3 has neither; both are then absent and the caller
  # loses the proof that needs them, which is the safe direction.
  if command -v readlink >/dev/null 2>&1 && r=$(readlink -f -- "$1" 2>/dev/null) && [ -n "$r" ]; then
    printf '%s\n' "$r"
    return 0
  fi
  return 1
}

head_of() { git -C "$1" rev-parse HEAD 2>/dev/null || die "cannot read git HEAD of $1"; }

# tree_clean <dir>: true iff `git status --porcelain -uall` succeeds AND is
# empty. The porcelain output (or git's error) is left in PORC for reporting.
tree_clean() { PORC=$(git -C "$1" status --porcelain -uall 2>&1) && [ -z "$PORC" ]; }

require_installed() {
  [ -f "$AI_CREW_INSTALLED" ] || die "installed plugins file not found: $AI_CREW_INSTALLED"
  jq -e '(type == "object") and (.plugins | type == "object")' "$AI_CREW_INSTALLED" >/dev/null 2>&1 \
    || die "$AI_CREW_INSTALLED: unparseable, or .plugins is not an object"
}

# inst_state <key>: prints absent|present; dies if the entry is malformed.
inst_state() {
  local s
  s=$(jq -r --arg k "$1" '.plugins[$k]
    | if . == null then "absent"
      elif type == "array" and length > 0 and (.[0] | type == "object") then "present"
      else "malformed" end' "$AI_CREW_INSTALLED") || die "$AI_CREW_INSTALLED: read failed for $1"
  [ "$s" = malformed ] && die "$AI_CREW_INSTALLED: entry $1 is not a non-empty array of objects"
  echo "$s"
}

# inst_field <key> <field>: prints a string field of entry [0]; returns 1 if missing.
inst_field() {
  jq -e -r --arg k "$1" --arg f "$2" '.plugins[$k][0][$f] | select(type == "string")' \
    "$AI_CREW_INSTALLED" 2>/dev/null
}

# all_targets: fills KEYS[] / TNAMES[] / TMKTS[] / MANIFESTS[] / HEADCLONES[] /
# TIDX[] (index into MKT_*) / TINST[] (1 = present in installed_plugins.json)
# for every plugin of every marketplace, plus the vendor once, attached to the
# FIRST marketplace. Requires require_installed to have passed.
all_targets() {
  local i m st
  KEYS=(); TNAMES=(); TMKTS=(); MANIFESTS=(); HEADCLONES=(); TIDX=(); TINST=()
  for m in "${!MKT_NAMES[@]}"; do
    list_plugins "${MKT_CLONES[$m]}"
    for i in "${!NAMES[@]}"; do
      KEYS+=("${NAMES[$i]}@${MKT_NAMES[$m]}"); TNAMES+=("${NAMES[$i]}"); TMKTS+=("${MKT_NAMES[$m]}")
      MANIFESTS+=("${MKT_CLONES[$m]}/${SOURCES[$i]#./}/.claude-plugin/plugin.json")
      HEADCLONES+=("${MKT_CLONES[$m]}"); TIDX+=("$m")
    done
    if [ "$m" -eq 0 ]; then
      KEYS+=("$VENDOR_KEY"); TNAMES+=("$VENDOR_NAME"); TMKTS+=("$VENDOR_MARKETPLACE")
      MANIFESTS+=("$AI_CREW_VENDOR_MANIFEST"); HEADCLONES+=("$AI_CREW_VENDOR_CLONE"); TIDX+=("$m")
    fi
  done
  for i in "${!KEYS[@]}"; do
    st=$(inst_state "${KEYS[$i]}") || exit 1
    if [ "$st" = present ]; then TINST+=(1); else TINST+=(0); fi
  done
}

# validate_snapshot <file>: top-level object; the one reserved key "_bound" is
# {boundHead, vendorHead} strings; every other value is null or an object with
# string version, gitCommitSha and installPath. Dies with a clear message.
validate_snapshot() {
  jq -e --arg b "$BOUND_KEY" 'type == "object" and all(to_entries[];
      if .key == $b then
        (.value | type == "object" and (.boundHead | type == "string") and (.vendorHead | type == "string"))
      else
        (.value == null or (.value | type == "object"
          and (.version | type == "string") and (.gitCommitSha | type == "string")
          and (.installPath | type == "string")))
      end)' "$1" >/dev/null 2>&1 \
    || die "$1: invalid snapshot — must be an object whose entries are null or {version, gitCommitSha, installPath} strings (plus optional \"$BOUND_KEY\": {boundHead, vendorHead})"
}

# require_snapshot <file>
require_snapshot() {
  [ -f "$1" ] \
    || die "no pre-update snapshot at $1 — run 'ai-crew.sh snapshot' first"
  validate_snapshot "$1"
}

# ---------------------------------------------------------- fragments & hooks

# jq helpers shared by the reconcile merge and the reconcile scan.
#   cmdbases — the basenames of EVERY whitespace-separated token of a command,
#     which is what lets one script basename match a legacy registration no
#     matter how it was written: `/abs/.claude/hooks/x.py`,
#     `python3 ~/.claude/hooks/x.py`, or an older plugin version's path.
#   scriptbases — the basenames that look like a script (.py/.sh/.mjs/.js).
#     Those are the identity keys a plugin owns.
# A hook whose tokens carry none of the owned basenames is never matched, and so
# is never touched: an unrelated user hook survives byte for byte.
jq_defs() {
  cat <<'EOF'
def unq: ltrimstr("\"") | rtrimstr("\"") | ltrimstr("'") | rtrimstr("'");
def norm: (. // "") | gsub("\\\\"; "/");
def bname: norm | sub(".*/"; "");
def toks: (. // "") | [splits("\\s+")] | map(select(length > 0)) | map(unq);
def entrytoks: (((.command // "") | toks)
  + ((.args // []) | map(select(type == "string")) | map(unq)));
def dispcmd: ((.command // "")
  + (if ((.args // []) | length) > 0
     then " " + (((.args // []) | map(tostring)) | join(" ")) else "" end));
# shq — POSIX single-quoting for a value printed inside a remedy the user is
# told to paste. Every legacy hook form this tool matches (`python3 <path>`)
# contains a space, so an unquoted spec word-splits and the paste fails; worse,
# it used to fail AFTER the first mangled spec had been recorded. The embedded
# quote idiom is the standard one: end the quote, escape a literal ', reopen.
def shq: tostring | gsub("'"; "'\\''") | "'" + . + "'";
def scriptbases: entrytoks | map(bname) | map(select(test("\\.(py|sh|mjs|js)$")));
def haspath: test("[/\\\\]");
# PROVENANCE — what makes a settings entry a duplicate of a PLUGIN hook rather
# than a hook of the user's own. A basename collision is not proof, and neither
# is the directory the path sits in: /srv/project/.claude/hooks/read-budget-gate.py
# is a different file, in a different project, doing a different job, and
# deleting its registration because some installed plugin ships that basename
# destroys a gate nobody asked us to touch.
# $P[0] is the map built by build_prov, keyed by the settings token exactly as
# it is written. A token maps to one of three proofs:
#   "plugin-root"      the path resolves inside the installed plugin's OWN
#                      directory (its recorded installPath) — the ordinary case
#                      for a registration an older version of this tool wrote;
#   "content-hash"     the file is byte-identical to the plugin-shipped hook of
#                      that basename, so the duplicate registration provably
#                      runs the same code, wherever it was copied to;
#   "migration-record" the user recorded that exact path, by hand, as one this
#                      tool registered and may remove.
# A token with NO entry is UNPROVEN — including every "cannot hash" case, which
# is an absence of evidence and never evidence of sameness. Unproven is KEPT.
def provenance: ($P[0] // {})[.] // "";
def proven: (provenance | length) > 0;
def refs($owned): [ entrytoks[] | select(haspath)
  | select(bname as $b | ($owned | index($b)) != null) ];
def refbase($owned): refs($owned) | if length > 0 then (.[0] | bname) else null end;
# A path that walks back out of its directory is not owned by the directory it
# appears to be in: /x/plugins/cache/../../custom/h.py is NOT a plugin path.
def nodotdot: norm | (test("(^|/)\\.\\.(/|$)") | not);
# Removal is only safe for a STANDALONE legacy invocation: an optional
# interpreter plus exactly one script token and nothing else. Anything that
# composes (&&, ;, |, a redirection) or carries extra arguments is a command
# whose meaning we would be changing, not a duplicate registration we are
# deleting — those are reported and kept.
# Anything that can make the shell do more than "run this script" disqualifies
# an entry from removal: command substitution, expansion, globbing, grouping,
# sequencing, redirection, or a line break. We are not parsing shell here — we
# are refusing to touch anything that needs parsing.
def shellish: test("[\n\r\t$`(){}\\[\\]*?!;&|<>]");
# `~` is only a home reference at the start of a token; anywhere else it is a
# character we did not expect. A backslash is only acceptable in a Windows path
# (drive-letter or UNC), never as an escape.
def oktilde: (test("~") | not) or startswith("~");
def okbackslash: (test("\\\\") | not) or test("^[A-Za-z]:[\\\\/]") or startswith("\\\\\\\\");
def standalone($owned): entrytoks as $t | refs($owned) as $r
  | ((((.command // "") | shellish) | not)
     and (((.args // []) | map(tostring) | map(shellish) | any) | not)
     and ($t | map(oktilde and okbackslash) | all)
     and (($r | length) == 1)
     and ((($t | length) == 1)
          or (($t | length) == 2
              and (["python3", "python", "bash", "sh", "node"] | index($t[0] | bname)) != null))
     and ($t[-1] == $r[0]));
def removable($owned): refs($owned) as $r
  | (($r | length) > 0) and ($r | map(nodotdot) | all)
    and ($r | map(proven) | all) and standalone($owned);
# Why an entry naming a plugin-owned script was NOT removed. A bare "AMBIGUOUS"
# reads like a formality and invites a reflexive acknowledgement; the reason is
# what tells a user whether the entry is their own hook or a stale one of ours.
def whykept($owned): refs($owned) as $r
  | if (($r | map(nodotdot) | all) | not)
    then "a path walks out of its own directory with `..`, so the directory it appears to sit in does not own it"
    elif (standalone($owned) | not)
    then "not a standalone `[interpreter] script` invocation — extra arguments, a second owned script, an unknown interpreter or shell syntax, so removing it would change what the command does"
    else "basename matches a plugin hook but provenance is unproven — the path is not inside the installed plugin's own directory, its content does not match the shipped hook (or could not be read), and no migration record claims it"
    end;
# The remedy for the UNPROVEN-PROVENANCE case, and for that case only. The two
# remedies mean opposite things and the message must not blur them:
# --accept-ambiguous KEEPS the registration and silences it, which is right for
# a hook of the user's own, and wrong for a stale `plugins/cache/<old>/` path —
# that one becomes a hook that cannot run the day old cache versions are pruned,
# and only --record-migrated lets reconcile REMOVE it. The other whykept
# branches get nothing: a `..` path and a compound command are not registrations
# this tool ever wrote, so naming --record-migrated there would be false advice.
# Skipped as well for a path --record-migrated would refuse (a Windows path, or
# any spelling that is neither absolute nor `~/`).
def keptfix($owned): refs($owned) as $r
  | if (($r | map(nodotdot) | all) | not) or (standalone($owned) | not) then ""
    elif ((($r[0] | startswith("/")) or ($r[0] | startswith("~/"))) | not) then ""
    else " If THIS tool registered that hook — a stale `plugins/cache/<old-version>/` path, or a shipped hook edited since — run `reconcile --record-migrated "
         + ($r[0] | shq)
         + "` and reconcile will REMOVE the registration; acknowledging only silences it and keeps it."
    end;
EOF
}

# frag_plugins: fills FP_KEYS[] / FP_NAMES[] / FP_ROOTS[] with every installed
# plugin (any marketplace, installed order) whose installPath carries a settings
# fragment, a CLAUDE.md fragment, or a hooks manifest. Plugins that ship none of
# those are not candidates at all — reconcile only ever acts on what an
# installed plugin declares.
frag_plugins() {
  local out key path
  require_installed
  FP_KEYS=(); FP_NAMES=(); FP_ROOTS=()
  out=$(jq -r '.plugins | to_entries[]
    | select(.value | type == "array" and length > 0 and (.[0] | type == "object"))
    | [ .key, (.value[0].installPath // "") ] | @tsv' "$AI_CREW_INSTALLED") \
    || die "$AI_CREW_INSTALLED: could not enumerate .plugins"
  while IFS=$'\t' read -r key path; do
    [ -n "$key" ] || continue
    [ -n "$path" ] || continue
    if [ -f "$path/$SETTINGS_FRAGMENT" ] || [ -f "$path/$CLAUDE_MD_FRAGMENT" ] || [ -f "$path/$HOOKS_MANIFEST" ]; then
      FP_KEYS+=("$key"); FP_NAMES+=("${key%%@*}"); FP_ROOTS+=("$path")
    fi
  done <<<"$out"
}

# build_frags <outfile>: a JSON array [{plugin, root, env}] of every settings
# fragment, in installed order. The fragment carries ENV ONLY; hooks are owned
# by the plugin's hooks/hooks.json and are never copied into settings.json.
build_frags() {
  local out=$1 i f d
  tmpd; d=$TMPD
  : >"$d/frags.jsonl"
  for i in ${FP_KEYS[@]+"${!FP_KEYS[@]}"}; do
    f="${FP_ROOTS[$i]}/$SETTINGS_FRAGMENT"
    [ -f "$f" ] || continue
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 \
      || die "$f: unparseable, or not a JSON object"
    jq -n --arg p "${FP_NAMES[$i]}" --arg r "${FP_ROOTS[$i]}" --slurpfile g "$f" \
      '{plugin: $p, root: $r, env: ($g[0].env // {})}' >>"$d/frags.jsonl" \
      || die "$f: could not be read"
  done
  jq -s '.' "$d/frags.jsonl" >"$out" || die "could not assemble the fragment list"
}

# build_hookbases <outfile>: a JSON array
# [{plugin, root, file, ok, bases, files}] of the script basenames each
# installed plugin owns, read from its hooks manifest, plus the manifest's own
# spelling of the path to each of them (${CLAUDE_PLUGIN_ROOT} unsubstituted —
# build_prov resolves it against the plugin root). `files` is what makes the
# content-hash proof possible: it names the shipped file to compare against,
# instead of guessing at one from a basename.
# `ok:false` records a manifest that does not parse — the caller decides whether
# that is a die (reconcile: we cannot know what to remove) or a verify failure.
build_hookbases() {
  local out=$1 i f d
  tmpd; d=$TMPD
  : >"$d/hookbases.jsonl"
  for i in ${FP_KEYS[@]+"${!FP_KEYS[@]}"}; do
    f="${FP_ROOTS[$i]}/$HOOKS_MANIFEST"
    [ -f "$f" ] || continue
    if jq -e 'type == "object" or type == "array"' "$f" >/dev/null 2>&1; then
      { jq_defs; cat <<'EOF'
{ plugin: $p, root: $r, file: $fp, ok: true,
  bases: ([ .. | objects | select(has("command")) | scriptbases ] | flatten | unique),
  files: ([ .. | objects | select(has("command")) | entrytoks[]
            | select(haspath) | select(bname | test("\\.(py|sh|mjs|js)$")) ]
          | unique | map({base: bname, path: .})) }
EOF
      } >"$d/hb.jq"
      jq --arg p "${FP_NAMES[$i]}" --arg r "${FP_ROOTS[$i]}" --arg fp "$f" \
        --slurpfile P "$(prov_empty)" -f "$d/hb.jq" "$f" \
        >>"$d/hookbases.jsonl" || die "$f: could not be read"
    else
      jq -n --arg p "${FP_NAMES[$i]}" --arg r "${FP_ROOTS[$i]}" --arg fp "$f" \
        '{plugin: $p, root: $r, file: $fp, ok: false, bases: [], files: []}' >>"$d/hookbases.jsonl"
    fi
  done
  jq -s '.' "$d/hookbases.jsonl" >"$out" || die "could not assemble the hook manifest list"
}

# prov_empty: a path to an empty provenance map. Every jq program that includes
# jq_defs must bind $P, used or not — jq resolves variable references when it
# compiles — and build_hookbases runs BEFORE any provenance can be computed
# (computing it needs the very index that program builds).
prov_empty() {
  tmpd
  [ -f "$TMPD/prov-empty.json" ] || echo '{}' >"$TMPD/prov-empty.json"
  echo "$TMPD/prov-empty.json"
}

# The migration record: a JSON array of paths the user states were registered in
# settings.json BY THIS TOOL and may be removed. It is the last resort of the
# three proofs, and the weakest — nothing about the file itself corroborates it
# — so it is never written by a run, only by an explicit
# `reconcile --record-migrated <path>`, exactly as an acknowledgement is.
# Like ack_read this creates nothing: verify, status and --dry-run make no
# persistent write, so a missing list is staged empty in the per-run temp dir.
migrated_read() {
  local d
  if [ -f "$AI_CREW_MIGRATED" ]; then
    jq -e 'type == "array" and all(.[]; type == "string")' "$AI_CREW_MIGRATED" >/dev/null 2>&1 \
      || die "$AI_CREW_MIGRATED: not a JSON array of path strings — fix or delete it"
    echo "$AI_CREW_MIGRATED"
    return 0
  fi
  tmpd; d=$TMPD
  [ -f "$d/migrated-empty.json" ] || echo '[]' >"$d/migrated-empty.json"
  echo "$d/migrated-empty.json"
}

migrated_write_file() {
  if [ ! -f "$AI_CREW_MIGRATED" ]; then
    mkdir -p "$(dirname "$AI_CREW_MIGRATED")" \
      || die "cannot create $(dirname "$AI_CREW_MIGRATED")"
    echo '[]' >"$AI_CREW_MIGRATED" || die "cannot create $AI_CREW_MIGRATED"
  fi
  jq -e 'type == "array" and all(.[]; type == "string")' "$AI_CREW_MIGRATED" >/dev/null 2>&1 \
    || die "$AI_CREW_MIGRATED: not a JSON array of path strings — fix or delete it"
  echo "$AI_CREW_MIGRATED"
}

# cmd_record_migrated <path>...: record that this tool registered <path>, so a
# later reconcile may remove its settings.json entry. The path is stored as
# given (a `~/` spelling stays a `~/` spelling) and matched after expansion, so
# either spelling in settings.json is covered by either spelling here.
cmd_record_migrated() {
  local pth f tmp new lines=""
  command -v jq >/dev/null 2>&1 || die "jq not installed"
  # Validate the WHOLE argument list before the list file is created or
  # touched: a refusal on the second path must leave the record byte-identical
  # to what it was — and must not leave an empty list behind where there was no
  # file at all. (migrated_write_file creates one.)
  new='[]'
  for pth in "$@"; do
    # shellcheck disable=SC2088  # a literal ~ is the PATTERN matched here, not a path
    case $pth in
      /*) ;;
      "~/"*) ;;
      *) die "not a path this tool can have registered: '$pth' (want an absolute path, or one starting with ~/)" ;;
    esac
    new=$(jq -c --argjson acc "$new" --arg p "$pth" -n '$acc + [$p]') \
      || die "cannot encode the migration record"
    lines="${lines}migrated: recorded $pth — reconcile may now remove its settings.json registration
"
  done
  f=$(migrated_write_file) || exit 1
  tmp="$f.tmp.$$"
  jq --argjson new "$new" 'reduce $new[] as $p (.; if any(.[]; . == $p) then . else . + [$p] end)' "$f" >"$tmp" \
    || { rm -f "$tmp"; die "cannot record the migration"; }
  mv "$tmp" "$f"
  printf '%s' "$lines"
  echo "migrated: recorded in $f — rerun reconcile"
}

# prov_of <token> <shipped-tsv> <migrated-list>: the proof that <token> names a
# hook THIS PLUGIN SYSTEM installed, or nothing at all. The three proofs are
# tried in descending strength; the first that holds wins.
prov_of() {
  local tok=$1 tsv=$2 mig=$3 base abs canon croot h sbase sroot spath shash rec
  abs=$(expand_tilde "$tok")
  base=${abs##*/}; base=${base##*\\}
  # 1. inside the plugin's OWN installed directory, decided on the SYMLINK-
  #    RESOLVED spelling of both sides and on nothing else.
  #
  #    The literal spelling is NOT an independent proof. A registration written
  #    under the plugin root can still pass through a symlinked component and
  #    land on a file the user owns, outside the plugin entirely; treating the
  #    spelling as proof would remove that unrelated hook's registration. So
  #    both the token and the install root are resolved, and containment is
  #    judged after resolution.
  #
  #    When either side cannot be resolved — no realpath/readlink -f, or a
  #    component that does not exist — this proof is not available AT ALL and
  #    the entry falls through to the content hash and the migration record.
  #    Unproven means kept, so losing the proof can only keep entries the tool
  #    would otherwise have removed.
  #
  #    `..` is rejected separately, in jq, so a prefix test cannot be walked out
  #    of here either.
  if canon=$(canon_path "$abs"); then
    while IFS=$'\t' read -r sbase sroot spath shash; do
      [ "$sbase" = "$base" ] || continue
      croot=$(canon_path "$sroot") || continue
      case $canon in "$croot"/*) echo plugin-root; return 0 ;; esac
    done <"$tsv"
  fi
  # 2. byte-identical to the shipped hook of that basename — the same code,
  #    moved or copied. A file we cannot hash yields the empty string, which is
  #    never equal to a shipped hash (those are non-empty or skipped).
  h=$(sha256_try "$abs")
  if [ -n "$h" ]; then
    while IFS=$'\t' read -r sbase sroot spath shash; do
      [ "$sbase" = "$base" ] || continue
      [ -n "$shash" ] || continue
      [ "$shash" = "$h" ] || continue
      echo content-hash; return 0
    done <"$tsv"
  fi
  # 3. the user recorded this exact path as ours.
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    [ "$(expand_tilde "$rec")" = "$abs" ] || continue
    echo migration-record; return 0
  done <"$mig"
  return 0
}

# build_prov <settings-file> <hooks-index> <outfile>: the provenance map the jq
# programs read as $P[0] — every settings token naming a script an installed
# plugin owns, mapped to its proof. A token that earns no proof is simply
# absent, which is how "unproven" reaches jq.
#
# Only tokens are hashed, never rewritten: this reads the user's settings and
# the files it names, and writes nothing outside the per-run temp dir.
build_prov() {
  local sfile=$1 hooks=$2 out=$3 d tok verdict sbase sroot spath mig
  tmpd; d=$TMPD
  # The migration record, one path per line. A recorded path carrying a newline
  # or a carriage return is dropped: it cannot survive this line-oriented form,
  # and a record that cannot be matched simply proves nothing.
  mig=$(migrated_read) || exit 1
  jq -r '.[] | select(test("[\n\r]") | not)' "$mig" >"$d/migrated.txt" \
    || die "$mig: could not be read"
  # The plugin-shipped file behind every owned basename, with its hash.
  # ${CLAUDE_PLUGIN_ROOT} is what the harness substitutes at run time; we
  # substitute the same plugin's recorded installPath.
  : >"$d/shipped.tsv"
  while IFS=$'\t' read -r sbase sroot spath; do
    [ -n "$sbase" ] || continue
    spath=${spath//\$\{CLAUDE_PLUGIN_ROOT\}/$sroot}
    spath=${spath//\$CLAUDE_PLUGIN_ROOT/$sroot}
    printf '%s\t%s\t%s\t%s\n' "$sbase" "$sroot" "$spath" "$(sha256_try "$spath")" \
      >>"$d/shipped.tsv"
  done <<<"$(jq -r '.[] | .root as $r | (.files // [])[] | [.base, $r, .path] | @tsv' "$hooks")"
  # Every candidate token in settings.json. A token carrying a newline, a tab or
  # a carriage return is skipped outright: it cannot be carried through this
  # line-oriented loop, and such an entry is refused for removal by `shellish`
  # anyway — skipping it leaves it unproven, which is the safe direction.
  { jq_defs; cat <<'EOF'
([ $H[0][] | .bases[] ] | unique) as $OWNED
| [ ((($S[0] // {}).hooks // {}) | .[]?) | .[]? | (.hooks // [])[]?
    | entrytoks[] | select(haspath)
    | select(bname as $b | ($OWNED | index($b)) != null) ]
  | unique | .[] | select(test("[\n\r\t]") | not)
EOF
  } >"$d/prov-toks.jq"
  : >"$d/prov.jsonl"
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    verdict=$(prov_of "$tok" "$d/shipped.tsv" "$d/migrated.txt")
    [ -n "$verdict" ] || continue
    jq -n --arg t "$tok" --arg v "$verdict" '{key: $t, value: $v}' >>"$d/prov.jsonl" \
      || die "could not record the provenance of $tok"
  done <<<"$(jq -r -n --slurpfile S "$sfile" --slurpfile H "$hooks" \
      --slurpfile P "$(prov_empty)" -f "$d/prov-toks.jq")"
  jq -s 'from_entries' "$d/prov.jsonl" >"$out" || die "could not assemble the provenance map"
}

settings_json_ok() {
  [ -f "$AI_CREW_SETTINGS" ] || return 0
  jq -e 'type == "object"' "$AI_CREW_SETTINGS" >/dev/null 2>&1
}

md_end_newline() {
  if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then printf '\n' >>"$1"; fi
}

# md_render <mdfile> <fragfile> <plugin> <outfile>: writes the reconciled
# CLAUDE.md to <outfile> and sets MD_ACTION to appended|replaced. The fragment
# must carry both marker lines; CLAUDE.md must carry both or neither, exactly
# once each, and in the right ORDER (a file with one of the two, or with them
# reversed, is ambiguous and is an error, never a guess).
md_render() {
  local md=$1 frag=$2 plug=$3 out=$4 smark emark hs he ls le
  smark="<!-- $plug:start -->"; emark="<!-- $plug:end -->"
  grep -Fxq -- "$smark" "$frag" || die "$frag: missing marker line '$smark'"
  grep -Fxq -- "$emark" "$frag" || die "$frag: missing marker line '$emark'"
  if [ ! -f "$md" ]; then
    cat "$frag" >"$out"; md_end_newline "$out"; MD_ACTION=appended; return 0
  fi
  hs=$(grep -Fxc -- "$smark" "$md" || true)
  he=$(grep -Fxc -- "$emark" "$md" || true)
  if [ "$hs" = 0 ] && [ "$he" = 0 ]; then
    cp "$md" "$out"
    if [ -s "$out" ] && [ -n "$(tail -c 1 "$out")" ]; then printf '\n' >>"$out"; fi
    [ -s "$out" ] && printf '\n' >>"$out"
    cat "$frag" >>"$out"; md_end_newline "$out"; MD_ACTION=appended; return 0
  fi
  [ "$hs" = 1 ] && [ "$he" = 1 ] \
    || die "$md: expected exactly one '$smark' and one '$emark' (found $hs and $he) — fix the file by hand"
  # Counts alone are not enough: an end marker BEFORE its start would make the
  # awk below swallow the file from the start marker to EOF. Order is checked
  # here so nothing is written at all.
  ls=$(grep -Fxn -- "$smark" "$md" | cut -d: -f1)
  le=$(grep -Fxn -- "$emark" "$md" | cut -d: -f1)
  [ "$ls" -lt "$le" ] \
    || die "$md: '$emark' (line $le) comes before '$smark' (line $ls) — fix the file by hand"
  awk -v s="$smark" -v e="$emark" -v frag="$frag" '
    $0 == s { st = 1; while ((getline l < frag) > 0) print l; close(frag); next }
    st == 1 { if ($0 == e) st = 0; next }
    { print }' "$md" >"$out" || die "$md: could not rewrite the $plug block"
  md_end_newline "$out"; MD_ACTION=replaced
}

backup_of() { echo "$1.bak.$(date -u +%Y%m%dT%H%M%SZ)"; }

# resolve_link <path>: follow a symlink chain to the final referent. Bounded at
# 16 hops, with explicit cycle detection so a -> b -> a reports what it found
# rather than an exhausted-hops guess. Prints the resolved path.
resolve_link() {
  local t=$1 hops=0 link visited="|"
  while [ -L "$t" ]; do
    case $visited in
      *"|$t|"*) die "symlink cycle at $t — resolve it by hand; nothing written" ;;
    esac
    visited="$visited$t|"
    hops=$((hops + 1))
    [ "$hops" -le 16 ] || die "more than 16 symlink hops from $1 — resolve it by hand; nothing written"
    link=$(readlink "$t") || die "cannot read the symlink $t"
    case $link in
      /*) t=$link ;;
      *) t="$(dirname "$t")/$link" ;;
    esac
  done
  echo "$t"
}

# The acknowledgement list. Each entry is {event, base, command, args, matcher}
# and matches ONE exact invocation: acknowledging "this hook is mine" must not
# carry over to a different command that happens to reuse the basename, so
# editing the command — or changing the args array, or the matcher of the group
# the entry sits in — invalidates it. The matcher is part of the identity
# because two groups under the same event may carry the same command and args
# and still be two different registrations; without it, acknowledging the one
# you reviewed would silently acknowledge the one you did not.
#
# An entry with NO `matcher` key is therefore never matched at all. Such an
# entry predates the matcher becoming part of the identity, so its matcher is
# unknown — not known-to-be-absent — and a matcher-less group is precisely the
# broadest one, firing on every tool call. A stale acknowledgement expiring
# (verify fails again, and prints the exact remedy to re-record it) is the safe
# direction; one silently covering a group nobody reviewed is not.
#
# ack_read prints a path to the list without creating anything in the data dir:
# verify, status and --dry-run make no persistent or configuration write, and a
# read that created the list would fail outright when the data directory is
# absent or unwritable. The fallback empty list is staged in the per-run temp
# dir instead. Only --accept-ambiguous creates the real file.
ack_read() {
  local d
  if [ -f "$AI_CREW_AMBIGUOUS_ACK" ]; then
    jq -e 'type == "array"' "$AI_CREW_AMBIGUOUS_ACK" >/dev/null 2>&1 \
      || die "$AI_CREW_AMBIGUOUS_ACK: not a JSON array — fix or delete it"
    echo "$AI_CREW_AMBIGUOUS_ACK"
    return 0
  fi
  tmpd; d=$TMPD
  [ -f "$d/ack-empty.json" ] || echo '[]' >"$d/ack-empty.json"
  echo "$d/ack-empty.json"
}

ack_write_file() {
  if [ ! -f "$AI_CREW_AMBIGUOUS_ACK" ]; then
    mkdir -p "$(dirname "$AI_CREW_AMBIGUOUS_ACK")" \
      || die "cannot create $(dirname "$AI_CREW_AMBIGUOUS_ACK")"
    echo '[]' >"$AI_CREW_AMBIGUOUS_ACK" || die "cannot create $AI_CREW_AMBIGUOUS_ACK"
  fi
  jq -e 'type == "array"' "$AI_CREW_AMBIGUOUS_ACK" >/dev/null 2>&1 \
    || die "$AI_CREW_AMBIGUOUS_ACK: not a JSON array — fix or delete it"
  echo "$AI_CREW_AMBIGUOUS_ACK"
}

# cmd_accept_ambiguous: record "<event>/<basename>=<command>" acknowledgements,
# each optionally followed by `--args '<json array>'` for an exec-form hook and
# `--matcher '<matcher>'` for the matcher of the group it sits in. Both are
# stored STRUCTURALLY, so two entries that differ only in their args, or only in
# their matcher, cannot share one acknowledgement — which a space-joined display
# string would have let them do. An omitted --matcher records JSON null, which
# matches a group with no matcher key and nothing else; a group whose matcher is
# the empty string needs --matcher '' and is a distinct identity from both.
cmd_accept_ambiguous() {
  local spec key cmd event base argsjson matcherjson f tmp new lines=""
  command -v jq >/dev/null 2>&1 || die "jq not installed"
  # Parse and validate the WHOLE argument list before the file is created or
  # touched. The remedy this tool prints is meant to be pasted verbatim, and a
  # paste that dies partway through used to leave the specs before the failure
  # recorded — a mangled, and far BROADER, acknowledgement than anything the
  # user reviewed. Either every spec on the command line lands, or none does.
  new='[]'
  while [ $# -gt 0 ]; do
    spec=$1; shift
    argsjson=null; matcherjson=null
    # The options may come in either order, and each belongs to the spec it
    # follows: a second spec on the same command line starts fresh.
    while [ $# -gt 0 ]; do
      case ${1:-} in
        --args)
          [ $# -ge 2 ] || die "--args needs a JSON array"
          argsjson=$2; shift 2
          jq -e 'type == "array"' >/dev/null 2>&1 <<<"$argsjson" \
            || die "--args must be a JSON array, got: $argsjson" ;;
        --matcher)
          [ $# -ge 2 ] || die "--matcher needs a value"
          matcherjson=$(jq -n --arg m "$2" '$m') || die "cannot encode the matcher"
          shift 2 ;;
        *) break ;;
      esac
    done
    case $spec in
      *=*) key=${spec%%=*}; cmd=${spec#*=} ;;
      *) die "not an acknowledgement: '$spec' (want <event>/<basename>=<command>)" ;;
    esac
    case $key in
      */*) event=${key%%/*}; base=${key#*/} ;;
      *) die "not an acknowledgement key: '$key' (want <event>/<basename>)" ;;
    esac
    [ -n "$event" ] && [ -n "$base" ] && [ -n "$cmd" ] \
      || die "acknowledgement needs a non-empty event, basename and command: '$spec'"
    new=$(jq -c --argjson acc "$new" --arg e "$event" --arg b "$base" --arg c "$cmd" \
      --argjson a "$argsjson" --argjson m "$matcherjson" -n \
      '$acc + [{event: $e, base: $b, command: $c, args: $a, matcher: $m}]') \
      || die "cannot encode the acknowledgement"
    lines="${lines}ambiguous: acknowledged $event/$base ($cmd) [matcher $(jq -r 'if . == null then "<none>" else "\"" + . + "\"" end' <<<"$matcherjson")]
"
  done
  f=$(ack_write_file) || exit 1
  tmp="$f.tmp.$$"
  jq --argjson new "$new" \
    'reduce $new[] as $r (.;
       if any(.[]; .event == $r.event and .base == $r.base and .command == $r.command
                   and (.args // null) == $r.args and has("matcher") and .matcher == $r.matcher)
       then . else . + [$r] end)' \
    "$f" >"$tmp" || { rm -f "$tmp"; die "cannot record the acknowledgement"; }
  mv "$tmp" "$f"
  printf '%s' "$lines"
  echo "ambiguous: recorded in $f — rerun verify"
}

# fingerprint <file>: a value that changes whenever the file's content does.
# "absent" is itself a fingerprint — a file appearing under us matters as much
# as one being edited.
fingerprint() {
  [ -e "$1" ] || { echo absent; return 0; }
  sha256_of "$1"
}

# atomic_install <src> <target>: put the finished content at <target> by a
# rename WITHIN the target's own directory. `mv` from the mktemp work dir is a
# cross-filesystem copy+unlink, not an atomic rename (the work dir is usually
# /tmp), so a crash mid-copy would leave a truncated settings.json — the file
# that gates every session. Staging beside the target makes the final step a
# same-filesystem rename, which is atomic: readers see the old file or the new
# one, never a partial one. The target's directory already exists here (the
# callers mkdir -p before backing up).
atomic_install() {
  local src=$1 target=$2 stage mode
  # A symlinked settings.json (dotfiles repos do this) must keep its link: stage
  # beside, and rename onto, the final REFERENT — never replace a link with a
  # regular file. The whole chain is followed; a cycle or an absurd depth is an
  # error, not something to guess at.
  target=$(resolve_link "$target") || exit 1
  stage=$(mktemp "$(dirname "$target")/.ai-crew.XXXXXX") || die "cannot create a temp file beside $target"
  cat "$src" >"$stage" || { rm -f "$stage"; die "cannot stage $target"; }
  # mktemp creates 0600, so the target's own mode has to be restored explicitly
  # or a settings.json the user deliberately keeps at 600 would silently become
  # world-readable (or vice versa). `chmod --reference` is GNU-only; read the
  # mode portably instead — GNU stat, then BSD/macOS stat, then the usual mode
  # for a file that does not exist yet.
  mode=$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target" 2>/dev/null || echo 644)
  chmod "$mode" "$stage" 2>/dev/null || true
  mv "$stage" "$target" || { rm -f "$stage"; die "cannot write $target"; }
}

# ---------------------------------------------------------------- reconcile

# merge_program: the whole settings repair in ONE jq pass, emitting both the new
# settings and the per-action report.
#   env   — set a fragment key only if it is absent from the ORIGINAL settings,
#           so a user's explicit value is never overwritten. A later fragment
#           may still overwrite a value an earlier fragment introduced.
#   hooks — REMOVAL ONLY, and only with PROVENANCE. Plugins register their own
#           hooks through hooks/hooks.json, so a settings.json entry naming a
#           script the plugin owns is a legacy double registration — but only
#           if that entry is PROVABLY the plugin's own file (see `provenance`
#           in jq_defs). A basename collision alone is a user hook of the same
#           name, and is kept and reported. A matcher group left with no hooks
#           is dropped; an event left with no groups is dropped. Entries naming
#           any other script are untouched.
merge_program() {
  jq_defs
  cat <<'EOF'
. as $orig
| (($orig.env // {}) | keys) as $userenv
| ([ $H[0][] | .bases[] ] | unique) as $OWNED
| reduce $F[0][] as $f ({s: $orig, rep: []};
    reduce (($f.env // {}) | to_entries[]) as $kv (.;
      if ($userenv | index($kv.key)) != null
      then .rep += ["settings: env \($kv.key) kept"]
      else .s.env[$kv.key] = $kv.value | .rep += ["settings: env \($kv.key) set"] end))
| .s as $s0
| .rep += [ ($s0.hooks // {}) | to_entries[] as $ev
            | ($ev.value // [])[] as $grp
            | (($grp.hooks // [])[]) as $h
            | ($h | refbase($OWNED)) as $b
            | select($b != null)
            | ($h | dispcmd) as $c
            | if ($h | removable($OWNED))
              then "settings: removed legacy hook \($ev.key)/\($b) (\($c))"
              elif (($ACK[0] // []) | map(select(.event == $ev.key and .base == $b
                    and .command == ($h.command // "") and (.args // null) == ($h.args // null)
                    and has("matcher") and .matcher == ($grp.matcher // null))) | length) > 0
              then "settings: ambiguous (acknowledged) \($ev.key)/\($b) (\($c))"
              else "settings: AMBIGUOUS legacy hook \($ev.key)/\($b) (\($c)) (kept; \($h | whykept($OWNED)); remove by hand, or acknowledge it)"
                   + ($h | keptfix($OWNED))
              end ]
| (if ($s0.hooks | type) == "object"
   then .s.hooks = ( $s0.hooks
       | with_entries(.value = ([ (.value // [])[]
             | .hooks = ((.hooks // []) | map(select(removable($OWNED) | not)))
             | select((.hooks | length) > 0) ]))
       | with_entries(select((.value | length) > 0)) )
   else . end)
| {settings: .s, report: .rep}
EOF
}

# scan_program: read-only counterpart of the merge. "hook:" lines are hard
# failures (verify fails); "soft:" lines are advisory (status reports them).
scan_program() {
  jq_defs
  cat <<'EOF'
($S[0] // {}) as $s
| ([ $H[0][] | .bases[] ] | unique) as $OWNED
| ([ $H[0][] | select(.ok | not) | "hook: \(.file) does not parse — reinstall \(.plugin), then run reconcile" ]
 + [ ($s.hooks // {}) | to_entries[] as $ev
     | ($ev.value // [])[] as $grp
     | (($grp.hooks // [])[]) as $h
     | ($h | refbase($OWNED)) as $b
     | select($b != null)
     | ($h | dispcmd) as $c
     | if ($h | removable($OWNED))
       then "hook: legacy hook entries present — \($ev.key)/\($b) is registered in settings (\($c)) — run reconcile"
       elif (($ACK[0] // []) | map(select(.event == $ev.key and .base == $b
             and .command == ($h.command // "") and (.args // null) == ($h.args // null)
             and has("matcher") and .matcher == ($grp.matcher // null))) | length) > 0
       then "warn: ambiguous (acknowledged) \($ev.key)/\($b) (\($c))"
       else "hook: AMBIGUOUS legacy hook \($ev.key)/\($b) (\($c)) — \($h | whykept($OWNED)); remove by hand, or acknowledge with `reconcile --accept-ambiguous "
            + (("\($ev.key)/\($b)=" + ($h.command // "")) | shq)
            + (if ($h.args // null) == null then "" else " --args " + (($h.args | tojson) | shq) end)
            + (if ($grp.matcher // null) == null then "" else " --matcher " + (($grp.matcher) | shq) end) + "`"
            + ($h | keptfix($OWNED))
       end ]
 + [ $F[0][] as $f | (($f.env // {}) | keys[]) as $k
     | if (($s.env // {}) | has($k)) then empty
       else "hook: env \($k) is not set in settings — run reconcile" end ])[]
EOF
}

# cmd_reconcile <dry>: repair settings.json and CLAUDE.md for the INSTALLED
# plugins. Idempotent: a run whose result is byte-identical to what is on disk
# writes nothing and takes no backup. A dry run writes nothing at all — no
# backup, no target file.
cmd_reconcile() {
  local dry=$1 d frags hooks prov merged new i mdfrag prev cur bak bad sin
  local fp_settings fp_md md_final="" md_any=0 lock took_lock=0
  command -v jq >/dev/null 2>&1 || die "jq not installed — cannot reconcile"
  tmpd; d=$TMPD
  frag_plugins
  if [ "${#FP_KEYS[@]}" -eq 0 ]; then
    echo "reconcile: no installed plugin declares a hooks manifest or a fragment"
    if [ "$dry" -eq 1 ]; then echo "reconcile: DRY RUN"; else echo "reconcile: ok"; fi
    return 0
  fi
  # Serialise against `update` and against another reconcile: read -> merge ->
  # write is not atomic, and two of them interleaved would lose one's work.
  # update already holds the lock when it calls us, and re-taking it would
  # deadlock the mkdir path, so take it only if we do not already hold it.
  if [ "$dry" -eq 0 ] && [ -z "$LOCKDIR" ] && [ "${LOCK_HELD:-0}" -eq 0 ]; then
    lock="$(dirname "$AI_CREW_SNAPSHOT")/update.lock"
    take_lock "$lock" || die "another update or reconcile is in progress (lock $lock held)"
    took_lock=1
  fi
  settings_json_ok || die "$AI_CREW_SETTINGS: not valid JSON (or not an object) — nothing written"

  # Everything below is computed from THIS state of the two files; the
  # fingerprints are re-checked before anything is installed.
  fp_settings=$(fingerprint "$AI_CREW_SETTINGS")
  fp_md=$(fingerprint "$AI_CREW_CLAUDE_MD")

  frags="$d/frags.json"; hooks="$d/hooks.json"
  build_frags "$frags"
  build_hookbases "$hooks"
  bad=$(jq -r '[ .[] | select(.ok | not) | .file ] | join(", ")' "$hooks")
  [ -z "$bad" ] || die "hook manifest does not parse: $bad — cannot tell which hooks to remove; nothing written"

  merge_program >"$d/merge.jq"
  # jq reads the real settings.json directly. Copying it into the work dir first
  # bought nothing — the merge never mutates its input, and the fingerprint
  # below is what guards against the file moving under us — while putting a
  # second copy of the user's settings in /tmp for a SIGKILL to strand there.
  if [ -f "$AI_CREW_SETTINGS" ]; then sin=$AI_CREW_SETTINGS; else sin="$d/settings.in"; echo '{}' >"$sin"; fi
  # Provenance is computed from the SAME file the merge reads, and the
  # fingerprint check below covers both: a settings.json that moved under us
  # invalidates the proofs as surely as it invalidates the merge.
  prov="$d/prov.json"
  build_prov "$sin" "$hooks" "$prov"
  merged="$d/merged.json"
  jq --slurpfile F "$frags" --slurpfile H "$hooks" --slurpfile ACK "$(ack_read)" \
    --slurpfile P "$prov" -f "$d/merge.jq" "$sin" >"$merged" \
    || die "$AI_CREW_SETTINGS: merge failed — nothing written"
  jq -r '.report[]' "$merged"
  new="$d/settings.out"
  jq '.settings' "$merged" >"$new" || die "$AI_CREW_SETTINGS: could not serialise the merged settings"

  # CLAUDE.md is rendered for EVERY plugin before anything is written, chaining
  # each plugin's block onto the previous plugin's result. Two reasons: a later
  # fragment with a broken marker pair must abort the whole run (nothing written
  # to either file), and the file gets one backup and one write however many
  # plugins contribute a block.
  prev="$AI_CREW_CLAUDE_MD"
  for i in ${FP_KEYS[@]+"${!FP_KEYS[@]}"}; do
    mdfrag="${FP_ROOTS[$i]}/$CLAUDE_MD_FRAGMENT"
    [ -f "$mdfrag" ] || continue
    md_any=1
    cur="$d/claude-md.$i"
    md_render "$prev" "$mdfrag" "${FP_NAMES[$i]}" "$cur"
    if [ -f "$prev" ] && cmp -s "$cur" "$prev"; then
      echo "claude-md: block ${FP_NAMES[$i]} unchanged"
    elif [ "$dry" -eq 1 ]; then
      echo "claude-md: block ${FP_NAMES[$i]} would be $MD_ACTION"
    else
      echo "claude-md: block ${FP_NAMES[$i]} $MD_ACTION"
    fi
    prev="$cur"; md_final="$cur"
  done

  # Nothing has been written yet. If either file moved under us, everything
  # computed above describes a state that no longer exists.
  if [ "$dry" -eq 0 ]; then
    [ "$(fingerprint "$AI_CREW_SETTINGS")" = "$fp_settings" ] \
      || die "settings: changed underneath us — rerun"
    [ "$(fingerprint "$AI_CREW_CLAUDE_MD")" = "$fp_md" ] \
      || die "claude-md: changed underneath us — rerun"
    # Resolve both chains now: atomic_install would otherwise discover a cycle
    # after the backup had already been written.
    resolve_link "$AI_CREW_SETTINGS" >/dev/null || exit 1
    resolve_link "$AI_CREW_CLAUDE_MD" >/dev/null || exit 1
  fi

  if [ -f "$AI_CREW_SETTINGS" ] && cmp -s "$new" "$AI_CREW_SETTINGS"; then
    echo "settings: unchanged"
  elif [ "$dry" -eq 1 ]; then
    echo "settings: would write $AI_CREW_SETTINGS"
  else
    mkdir -p "$(dirname "$AI_CREW_SETTINGS")"
    if [ -f "$AI_CREW_SETTINGS" ]; then
      bak=$(backup_of "$AI_CREW_SETTINGS")
      cp "$AI_CREW_SETTINGS" "$bak" || die "cannot back up $AI_CREW_SETTINGS"
      echo "settings: backup $bak"
    fi
    atomic_install "$new" "$AI_CREW_SETTINGS"
    echo "settings: wrote $AI_CREW_SETTINGS"
  fi

  if [ "$md_any" -eq 1 ] && [ "$dry" -eq 0 ]; then
    if [ -f "$AI_CREW_CLAUDE_MD" ] && cmp -s "$md_final" "$AI_CREW_CLAUDE_MD"; then
      :
    else
      mkdir -p "$(dirname "$AI_CREW_CLAUDE_MD")"
      if [ -f "$AI_CREW_CLAUDE_MD" ]; then
        bak=$(backup_of "$AI_CREW_CLAUDE_MD")
        cp "$AI_CREW_CLAUDE_MD" "$bak" || die "cannot back up $AI_CREW_CLAUDE_MD"
        echo "claude-md: backup $bak"
      fi
      atomic_install "$md_final" "$AI_CREW_CLAUDE_MD"
      echo "claude-md: wrote $AI_CREW_CLAUDE_MD"
    fi
  fi

  [ "$took_lock" -eq 1 ] && release_lock
  if [ "$dry" -eq 1 ]; then echo "reconcile: DRY RUN"; else echo "reconcile: ok"; fi
}

# recon_scan: fills RECON_HOOK[] (hard failures — verify must fail),
# RECON_WARN[] (ambiguous legacy entries reconcile deliberately will NOT touch,
# so they must never fail verify — there would be no remedy) and RECON_SOFT[]
# (env / CLAUDE.md drift — status reports it).
#
# It makes no persistent or configuration write — nothing outside the per-run
# temp dir is created or touched — but it is not write-free: the jq programs,
# the fragment/hook indexes and the rendered CLAUDE.md candidates are staged in
# $TMPD, so it needs a writable TMPDIR like every other subcommand.
recon_scan() {
  local d frags hooks prov out line i mdfrag mdout sfile
  RECON_HOOK=(); RECON_WARN=(); RECON_SOFT=()
  command -v jq >/dev/null 2>&1 || die "jq not installed — cannot check reconcile state"
  frag_plugins
  [ "${#FP_KEYS[@]}" -gt 0 ] || return 0
  if ! settings_json_ok; then
    RECON_HOOK+=("hook: $AI_CREW_SETTINGS is not valid JSON — fix it by hand, then run reconcile")
    return 0
  fi
  tmpd; d=$TMPD
  frags="$d/scan-frags.json"; hooks="$d/scan-hooks.json"
  build_frags "$frags"
  build_hookbases "$hooks"
  # Slurped straight from the real file: the scan only reads it, so staging a
  # copy of the user's settings in /tmp would add exposure and nothing else.
  if [ -f "$AI_CREW_SETTINGS" ]; then sfile=$AI_CREW_SETTINGS; else sfile="$d/scan-settings.json"; echo '{}' >"$sfile"; fi
  scan_program >"$d/scan.jq"
  prov="$d/scan-prov.json"
  build_prov "$sfile" "$hooks" "$prov"
  out=$(jq -r -n --slurpfile S "$sfile" --slurpfile F "$frags" --slurpfile H "$hooks" \
    --slurpfile ACK "$(ack_read)" --slurpfile P "$prov" -f "$d/scan.jq") \
    || die "$AI_CREW_SETTINGS: reconcile check failed"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in
      hook:*) RECON_HOOK+=("$line") ;;
      warn:*) RECON_WARN+=("$line") ;;
      *) RECON_SOFT+=("$line") ;;
    esac
  done <<<"$out"
  for i in ${FP_KEYS[@]+"${!FP_KEYS[@]}"}; do
    mdfrag="${FP_ROOTS[$i]}/$CLAUDE_MD_FRAGMENT"
    [ -f "$mdfrag" ] || continue
    mdout="$d/scan-md.$i"
    md_render "$AI_CREW_CLAUDE_MD" "$mdfrag" "${FP_NAMES[$i]}" "$mdout"
    if [ ! -f "$AI_CREW_CLAUDE_MD" ] || ! cmp -s "$mdout" "$AI_CREW_CLAUDE_MD"; then
      RECON_SOFT+=("soft: claude-md block ${FP_NAMES[$i]} is out of date — run reconcile")
    fi
  done
}

# ---------------------------------------------------------------- subcommands

# unconfigured_marketplaces: marketplace names that appear in
# installed_plugins.json but in no configured marketplace (and are not the
# vendor). Informational: this script cannot gate what it was never told about.
unconfigured_marketplaces() {
  local out mkt m known
  out=$(jq -r '.plugins | keys[] | select(contains("@")) | sub("^[^@]*@"; "")' "$AI_CREW_INSTALLED" | sort -u)
  while IFS= read -r mkt; do
    [ -n "$mkt" ] || continue
    [ "$mkt" = "$VENDOR_MARKETPLACE" ] && continue
    known=0
    for m in "${!MKT_NAMES[@]}"; do
      [ "${MKT_NAMES[$m]}" = "$mkt" ] && known=1
    done
    [ "$known" -eq 1 ] || echo "$mkt"
  done <<<"$out"
}

cmd_status() {
  local i key avail inst label st prev reason mkt skipped=0
  require_installed
  all_targets
  prev=-1
  for i in "${!KEYS[@]}"; do
    if [ "${TIDX[$i]}" -ne "$prev" ]; then mkt_header "${TIDX[$i]}"; prev=${TIDX[$i]}; fi
    key=${KEYS[$i]}
    avail=$(manifest_version "${MANIFESTS[$i]}") || exit 1
    if [ "${TINST[$i]}" -eq 0 ]; then
      inst="NOT INSTALLED"; skipped=$((skipped + 1))
    else
      inst=$(inst_field "$key" version) || die "$AI_CREW_INSTALLED: $key has no string .version"
    fi
    label=${TNAMES[$i]}
    [ "$key" = "$VENDOR_KEY" ] && label="vendor $VENDOR_KEY"
    echo "$label  installed=$inst  available=$avail"
  done
  for i in "${!KEYS[@]}"; do
    [ "${TINST[$i]}" -eq 0 ] && echo "skip: ${KEYS[$i]} not installed"
  done
  echo "status: ${#KEYS[@]} catalogued, $((${#KEYS[@]} - skipped)) installed, $skipped not installed"
  while IFS= read -r mkt; do
    [ -n "$mkt" ] && echo "unconfigured marketplace: $mkt (installed, but in no configured marketplace)"
  done <<<"$(unconfigured_marketplaces)"
  recon_scan
  if [ "${#RECON_HOOK[@]}" -gt 0 ] || [ "${#RECON_SOFT[@]}" -gt 0 ]; then
    echo "reconcile: needed"
    for reason in ${RECON_HOOK[@]+"${RECON_HOOK[@]}"} ${RECON_SOFT[@]+"${RECON_SOFT[@]}"}; do
      echo "    $reason"
    done
  else
    echo "reconcile: clean"
  fi
  # Ambiguous entries are NOT part of "needed": reconcile will not touch them,
  # so reporting them as actionable-by-reconcile would be a lie that never
  # clears. They need a human.
  for reason in ${RECON_WARN[@]+"${RECON_WARN[@]}"}; do
    echo "attention: ${reason#warn: }"
  done
}

# gate_one <idx>: gate a single marketplace — EVERY catalogued plugin, installed
# or not. Returns 1 on any failure; the receipt is written only by a fully
# passing run on a clean tree at one HEAD.
gate_one() {
  local m=$1 i name src suite n=0 ran=0 ungated=0 failed=0 rhead now msha tmp start
  local repo sc allow scrub=absent rc=0 senv=() sargs=()
  start=$PWD
  cd "${MKT_REPOS[$m]}" 2>/dev/null || die "cannot cd to repo: ${MKT_REPOS[$m]}"
  list_plugins .
  # HEAD is captured BEFORE the suites run; the receipt certifies this commit,
  # and a HEAD that moves during the run voids it (checked after the loop).
  rhead=$(head_of .) || exit 1
  for i in "${!NAMES[@]}"; do
    name=${NAMES[$i]}; src=${SOURCES[$i]}; suite="$src/tests/run.sh"
    n=$((n + 1))
    if [ ! -d "$src" ]; then
      echo "== $name: FAIL — plugin directory $src does not exist"
      failed=$((failed + 1))
    elif [ ! -e "$suite" ] && [ ! -L "$suite" ]; then
      echo "== $name: NO TEST SUITE — installs UNGATED"
      ungated=$((ungated + 1))
    elif [ ! -f "$suite" ] || [ ! -x "$suite" ]; then
      echo "== $name: FAIL — $suite exists but is not a regular executable file"
      failed=$((failed + 1))
    else
      echo "== $name: running $suite"
      ran=$((ran + 1))
      if "$suite" </dev/null; then
        echo "== $name: PASS"
      else
        echo "== $name: FAIL — suite exited nonzero"
        failed=$((failed + 1))
      fi
    fi
  done
  echo "gate: plugins=$n suites_run=$ran ungated=$ungated failed=$failed"
  if [ "$failed" -ne 0 ] || [ $((ran + ungated)) -ne "$n" ]; then cd "$start"; return 1; fi
  # Secret scrub. A repo that publishes its own scrub-check.sh gates on it here:
  # a leak reaching a public marketplace is not recoverable by a later commit.
  # 0 = pass, 4 = warning (reported, not fatal), anything else — including the
  # 1/2 the checker uses for findings — fails the gate, so an unknown exit code
  # can never read as success.
  repo=${MKT_REPOS[$m]}
  sc="$repo/scripts/scrub-check.sh"
  if [ ! -f "$sc" ]; then
    echo "scrub: $repo has no scripts/scrub-check.sh (skipped)"
  else
    allow="$repo/scripts/scrub-allow.txt"
    sargs=(--require-private)
    [ -f "$allow" ] && sargs+=(--allow "$allow")
    sargs+=("$repo")
    [ -n "${SCRUB_DENYLIST:-}" ] && senv=(env "SCRUB_DENYLIST=$SCRUB_DENYLIST")
    rc=0
    ${senv[@]+"${senv[@]}"} bash "$sc" ${sargs[@]+"${sargs[@]}"} || rc=$?
    if [ "$rc" -eq 0 ]; then
      scrub=pass
      echo "scrub: PASS ($sc)"
    elif [ "$rc" -eq 4 ]; then
      scrub=warn
      echo "scrub: WARNING (exit 4) — reported, not fatal ($sc)"
    else
      echo "scrub: FAIL — $sc exited $rc; a secret must not reach a published marketplace — no receipt written"
      cd "$start"; return 1
    fi
  fi
  # The receipt certifies HEAD, so the tested tree must BE HEAD: a dirty tree
  # means the suites ran against code no commit (and no install) contains.
  if ! tree_clean .; then
    echo "gate: FAIL — suites passed but ${MKT_REPOS[$m]} is dirty; tested code != HEAD — no receipt written"
    printf '%s\n' "$PORC" | sed 's/^/    /'
    cd "$start"; return 1
  fi
  now=$(head_of .) || exit 1
  if [ "$now" != "$rhead" ]; then
    echo "gate: FAIL — HEAD moved during the run ($rhead -> $now); the suites did not test one commit — no receipt written"
    cd "$start"; return 1
  fi
  msha=$(sha256_of .claude-plugin/marketplace.json) || exit 1
  mkdir -p "$(dirname "${MKT_RECEIPTS[$m]}")"
  tmp="${MKT_RECEIPTS[$m]}.tmp.$$"
  jq -n --arg h "$rhead" --arg m "$msha" --arg mk "${MKT_NAMES[$m]}" --argjson r "$ran" --argjson u "$ungated" \
    --arg sb "$scrub" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{repoHead: $h, marketplaceSha256: $m, marketplace: $mk, targets: $ARGS.positional, suitesRun: $r, ungated: $u, scrub: $sb, ts: $ts}' \
    --args "${NAMES[@]}" >"$tmp" || { rm -f "$tmp"; die "receipt write failed"; }
  mv "$tmp" "${MKT_RECEIPTS[$m]}"
  echo "gate: receipt written: ${MKT_RECEIPTS[$m]} (repoHead $rhead)"
  cd "$start"
}

cmd_gate() {
  local m bad=0
  # Any gate run invalidates every previous receipt first, so a failing (or
  # dying) run can never leave an old receipt standing.
  for m in "${!MKT_NAMES[@]}"; do
    rm -f "${MKT_RECEIPTS[$m]}" || die "cannot remove old receipt ${MKT_RECEIPTS[$m]}"
  done
  for m in "${!MKT_NAMES[@]}"; do
    mkt_header "$m"
    gate_one "$m" || bad=1
  done
  [ "$bad" -eq 0 ] || return 1
}

# bind_one <idx>: repo and clone clean, HEADs equal, marketplace.json identical.
bind_one() {
  local m=$1 bad=0 d rh ch
  for d in "${MKT_REPOS[$m]}" "${MKT_CLONES[$m]}"; do
    if tree_clean "$d"; then
      echo "bind: clean $d: PASS"
    else
      echo "bind: clean $d: FAIL"; [ -n "$PORC" ] && printf '%s\n' "$PORC" | sed 's/^/    /'
      bad=1
    fi
  done
  rh=$(git -C "${MKT_REPOS[$m]}" rev-parse HEAD 2>/dev/null) || rh=""
  ch=$(git -C "${MKT_CLONES[$m]}" rev-parse HEAD 2>/dev/null) || ch=""
  if [ -n "$rh" ] && [ "$rh" = "$ch" ]; then
    echo "bind: HEAD equal ($rh): PASS"
  else
    echo "bind: HEAD equal: FAIL (repo=${rh:-<none>} clone=${ch:-<none>})"; bad=1
  fi
  if cmp -s "${MKT_REPOS[$m]}/.claude-plugin/marketplace.json" "${MKT_CLONES[$m]}/.claude-plugin/marketplace.json"; then
    echo "bind: marketplace.json identical: PASS"
  else
    echo "bind: marketplace.json identical: FAIL"; bad=1
  fi
  [ "$bad" -eq 0 ]
}

cmd_bind() {
  local m bad=0
  for m in "${!MKT_NAMES[@]}"; do
    mkt_header "$m"
    bind_one "$m" || bad=1
  done
  if [ "$bad" -ne 0 ]; then
    echo "bind: FAIL — re-sync (step 0), re-run the gate (step 1), refresh (step 2)"
    return 1
  fi
  echo "bind: PASS"
}

cmd_snapshot() {
  local m i tmp mkeys
  require_installed
  all_targets
  for i in "${!KEYS[@]}"; do
    [ "${TINST[$i]}" -eq 0 ] && echo "skip: ${KEYS[$i]} not installed"
  done
  for m in "${!MKT_NAMES[@]}"; do
    mkeys=()
    for i in "${!KEYS[@]}"; do
      if [ "${TIDX[$i]}" -eq "$m" ] && [ "${TINST[$i]}" -eq 1 ]; then mkeys+=("${KEYS[$i]}"); fi
    done
    mkdir -p "$(dirname "${MKT_SNAPSHOTS[$m]}")"
    tmp="${MKT_SNAPSHOTS[$m]}.tmp.$$"
    jq '. as $r | reduce $ARGS.positional[] as $k ({};
          .[$k] = ($r.plugins[$k] | if . == null then null
                   else .[0] | {version, gitCommitSha, installPath} end))' \
      "$AI_CREW_INSTALLED" --args ${mkeys[@]+"${mkeys[@]}"} >"$tmp" || { rm -f "$tmp"; die "snapshot write failed"; }
    # An installed entry lacking version/gitCommitSha/installPath cannot serve as
    # a baseline; refuse to write it rather than record nulls.
    ( validate_snapshot "$tmp" ) || { rm -f "$tmp"; die "installed entries lack version/gitCommitSha/installPath — snapshot not written"; }
    mv "$tmp" "${MKT_SNAPSHOTS[$m]}"
    echo "snapshot written: ${MKT_SNAPSHOTS[$m]}"
    cat "${MKT_SNAPSHOTS[$m]}"
  done
}

# lock_claim <lockdir>: finish a claim whose `mkdir` has already succeeded.
#
# A pathname is not an identity. `$lock.d` can be OUR lock now and somebody
# else's a moment later — a displaced contender renames ours away, fails to put
# it back, a third process finds the name free and creates its own — and a
# release that goes by name alone would then delete a live lock belonging to a
# process that never heard of us. So every claim writes an ownership token that
# cannot recur (pid, two $RANDOM draws, and the time) and release compares it.
#
# Ordering, and why it is safe:
#   1. `mkdir` — the atomic claim. Until it succeeds nothing is ours, and while
#      it holds nobody else can create the same name, so the window before the
#      token lands is a window only WE can be in.
#   2. the token file — on disk before any global is set, so the EXIT trap can
#      never be armed against a directory whose ownership it cannot prove. A
#      crash in this window leaks a tokenless directory, which the stale-lock
#      path reclaims by age; it can never delete somebody else's lock.
#   3. the pid file — written after the token, so a contender that sees a pid
#      is guaranteed to be looking at a fully formed lock.
#   4. the globals last, and only once the disk state is complete.
# The token write is the only step that can fail here; a lock we cannot prove we
# own is not a lock, so the directory is removed again (nobody else can hold it,
# we created it) and the claim is an error rather than a silent half-claim.
lock_claim() {
  local d=$1 tok
  tok="$$.$RANDOM.$RANDOM.$(date +%s 2>/dev/null || echo 0)"
  printf '%s\n' "$tok" >"$d/token" 2>/dev/null \
    || { rm -rf "$d"; die "lock: cannot write the ownership token in $d"; }
  echo $$ >"$d/pid"
  LOCKDIR="$d"; LOCKTOKEN="$tok"; LOCK_HELD=1
}

# lock_drop <lockdir>: remove <lockdir>, but ONLY while it still carries the
# token this process wrote. A mismatch means the directory at that name is no
# longer the one we took — another process owns it — and deleting it would be
# the very harm the token exists to prevent. Leaking a directory is recoverable;
# destroying a live lock is not, so a mismatch removes nothing and says so.
lock_drop() {
  local d=$1 cur
  cur=$(cat "$d/token" 2>/dev/null) || cur=""
  if [ -n "$LOCKTOKEN" ] && [ "$cur" = "$LOCKTOKEN" ]; then
    rm -rf "$d"
    return 0
  fi
  warn "lock: $d no longer carries this process's ownership token — another process holds it now; leaving it in place. Nothing was removed."
  return 0
}

# take_lock <lockfile>: exclusive, non-blocking. flock when available; otherwise
# a `mkdir` lock directory, which is atomic on every POSIX filesystem. The
# directory is removed by the EXIT trap, and only while it still carries this
# process's ownership token. Returns 1 if the lock is held.
take_lock() {
  local lock=$1 pid stale tries graveyard gpid stray same
  LOCK_HELD=${LOCK_HELD:-0}
  mkdir -p "$(dirname "$lock")"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock" || die "cannot open lock file $lock"
    flock -n 9 || return 1
    LOCK_HELD=1
    return 0
  fi
  if mkdir "$lock.d" 2>/dev/null; then
    lock_claim "$lock.d"
    return 0
  fi
  # Contention. Unlike flock, a mkdir lock outlives a hard-killed holder, so a
  # crash would wedge every future update — but reclaiming a LIVE holder's lock
  # would be far worse, so the bar for reclaiming is positive evidence that the
  # holder is gone.
  #
  # A missing pid file is NOT that evidence: the winner of the mkdir race writes
  # it a moment after creating the directory, so "no pid file" is the normal
  # look of a lock taken microseconds ago. Wait for it to appear before judging.
  tries=0
  while [ ! -f "$lock.d/pid" ] && [ "$tries" -lt 10 ]; do
    sleep 0.2
    tries=$((tries + 1))
    # The holder may have finished and removed the directory while we waited.
    if [ ! -d "$lock.d" ] && mkdir "$lock.d" 2>/dev/null; then
      lock_claim "$lock.d"
      return 0
    fi
  done
  pid=$(cat "$lock.d/pid" 2>/dev/null) || pid=""
  stale=0
  if [ -n "$pid" ] && [[ $pid =~ ^[0-9]+$ ]]; then
    # A live holder is NEVER displaced, at any age. A long update is not a dead
    # one, and the age heuristic cannot tell the difference.
    if kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    stale=1
  else
    # Still no pid after the backoff: either a holder that died between mkdir
    # and writing its pid, or a directory left by an older version. Only the
    # age check can distinguish that from a lock taken two seconds ago.
    pid="unknown"
    [ -n "$(find "$lock.d" -maxdepth 0 -mmin +30 2>/dev/null)" ] && stale=1
  fi
  if [ "$stale" -eq 1 ]; then
    # Reclaiming has to be atomic. `rm -rf` then `mkdir` is not: two contenders
    # that both read the same dead pid would both delete and both create, and
    # the second would be deleting the FIRST's live lock. A rename is atomic, so
    # at most one contender can move any ONE directory away — but winning the
    # rename is not the same as having renamed the directory we judged. Staleness
    # was decided back at `kill -0`, and in the interval since then another
    # contender may have reclaimed, recreated the name and started working: our
    # mv would then succeed on its LIVE lock, and destroying it here is exactly
    # the disaster the rename was supposed to prevent.
    #
    # So the captured directory is re-identified before anything is destroyed.
    # Its pid file must still name the dead pid we judged (or still be absent,
    # when no pid could be read at all). Anything else is somebody else's live
    # lock and goes straight back where it came from, untouched.
    #
    # A kill between the rename and the rm leaves the graveyard behind. Nothing
    # collects it, and nothing has to: the lock is `$lock.d` exactly, and no
    # code path ever looks at `$lock.d.stale.*`, so the debris is inert — cheap
    # to delete by hand, and never mistaken for a held lock.
    graveyard="$lock.d.stale.$$.$RANDOM"
    if mv "$lock.d" "$graveyard" 2>/dev/null; then
      gpid=$(cat "$graveyard/pid" 2>/dev/null) || gpid=""
      same=0
      if [ "$pid" = unknown ]; then
        # Nothing to compare a pid against here, so the age does the same job —
        # and it has to, because "no pid file" is ALSO what another reclaimer's
        # brand-new lock looks like in the instant between its `mkdir` and its
        # `echo $$ >pid`. The directory we judged was over 30 minutes old; one
        # created moments ago cannot be, and `mv` does not touch mtime.
        [ -z "$gpid" ] && [ -n "$(find "$graveyard" -maxdepth 0 -mmin +30 2>/dev/null)" ] && same=1
      elif [ "$gpid" = "$pid" ]; then
        same=1
      fi
      if [ "$same" -eq 1 ]; then
        rm -rf "$graveyard"
        if mkdir "$lock.d" 2>/dev/null; then
          echo "lock: recovered stale lock (pid $pid)"
          lock_claim "$lock.d"
          return 0
        fi
        # Someone took the freed name first; theirs is live, so we wait our turn.
        return 1
      fi
      # Not the directory we judged: a contender reclaimed between our `kill -0`
      # and our mv, and what we are holding is its live lock. Put it back. `mv`
      # onto an existing name would NEST it inside the other directory instead
      # of restoring it, so the name has to be free first — and because a third
      # contender could take that name in between, the result is checked rather
      # than assumed. Losing somebody's live lock in silence is worse than
      # stopping, so a failed restore is fatal and names where the directory is.
      stray=$graveyard
      if [ ! -e "$lock.d" ] && mv "$graveyard" "$lock.d" 2>/dev/null; then
        if [ -d "$lock.d/${graveyard##*/}" ]; then stray="$lock.d/${graveyard##*/}"; else stray=""; fi
      fi
      [ -z "$stray" ] && return 1
      die "lock: captured a live lock (pid ${gpid:-unknown}) while reclaiming a stale one and could not give it back — it is now at $stray; with no update running, move it back to $lock.d by hand. Nothing else was changed."
    fi
    # The mv failed: another contender reclaimed first — crucially, WITHOUT us
    # having removed anything. Its lock is live unless it has already finished,
    # so try the freed name once and otherwise refuse.
    if mkdir "$lock.d" 2>/dev/null; then
      echo "lock: recovered stale lock (pid $pid)"
      lock_claim "$lock.d"
      return 0
    fi
  fi
  return 1
}
# release_lock: drop a lock taken by take_lock. Only the taker calls it, so a
# nested reconcile inside update never releases update's lock.
release_lock() {
  if [ -n "$LOCKDIR" ]; then lock_drop "$LOCKDIR"; LOCKDIR=""; LOCKTOKEN=""; else exec 9>&-; fi
  LOCK_HELD=0
}

cmd_update() {
  local m i key lock vhead rh rs cur tmp reason ok=0 done_keys=() failed=() BOUNDS=()
  require_installed
  lock="$(dirname "$AI_CREW_SNAPSHOT")/update.lock"
  take_lock "$lock" || die "another update in progress (lock $lock held)"

  cmd_bind || die "bind failed — refusing to update"
  vhead=$(head_of "$AI_CREW_VENDOR_CLONE") || exit 1

  for m in "${!MKT_NAMES[@]}"; do
    cur=$(head_of "${MKT_CLONES[$m]}") || exit 1
    BOUNDS+=("$cur")
    require_snapshot "${MKT_SNAPSHOTS[$m]}"
    [ -f "${MKT_RECEIPTS[$m]}" ] \
      || die "no gate receipt at ${MKT_RECEIPTS[$m]} — run 'ai-crew.sh gate' first"
    rh=$(jq -e -r '.repoHead | select(type == "string")' "${MKT_RECEIPTS[$m]}" 2>/dev/null) \
      || die "${MKT_RECEIPTS[$m]}: unparseable or missing repoHead"
    rs=$(jq -e -r '.marketplaceSha256 | select(type == "string")' "${MKT_RECEIPTS[$m]}" 2>/dev/null) \
      || die "${MKT_RECEIPTS[$m]}: unparseable or missing marketplaceSha256"
    [ "$rh" = "$cur" ] \
      || die "gate receipt repoHead $rh != bound HEAD $cur — the gate did not test this commit; re-run gate"
    [ "$rs" = "$(sha256_of "${MKT_CLONES[$m]}/.claude-plugin/marketplace.json")" ] \
      || die "gate receipt marketplaceSha256 != clone marketplace.json — re-run gate"
    echo "update: gate receipt matches bound HEAD $cur: PASS"
    tmp="${MKT_SNAPSHOTS[$m]}.tmp.$$"
    jq --arg b "$BOUND_KEY" --arg h "$cur" --arg v "$vhead" '.[$b] = {boundHead: $h, vendorHead: $v}' \
      "${MKT_SNAPSHOTS[$m]}" >"$tmp" || { rm -f "$tmp"; die "cannot record $BOUND_KEY in snapshot"; }
    mv "$tmp" "${MKT_SNAPSHOTS[$m]}"
  done

  all_targets
  for i in "${!KEYS[@]}"; do
    key=${KEYS[$i]}; m=${TIDX[$i]}
    if [ "${TINST[$i]}" -eq 0 ]; then
      echo "skip: $key not installed"
      continue
    fi
    cur=$(head_of "${MKT_CLONES[$m]}") || exit 1
    if [ "$cur" != "${BOUNDS[$m]}" ]; then
      echo "update: ABORT — clone moved after bind (${BOUNDS[$m]} -> $cur); gate proved nothing about what would install"
      echo "update: already attempted: ${done_keys[*]:-<none>}; failed: ${failed[*]:-<none>} — install may be MIXED"
      return 1
    fi
    if ! tree_clean "${MKT_CLONES[$m]}"; then
      echo "update: ABORT — clone modified after bind (tree dirty); gate proved nothing about what would install:"
      printf '%s\n' "$PORC" | sed 's/^/    /'
      echo "update: already attempted: ${done_keys[*]:-<none>}; failed: ${failed[*]:-<none>} — install may be MIXED"
      return 1
    fi
    echo "== $CLAUDE_BIN plugin update $key"
    # 9>&-: the child must not inherit the lock fd, or a lingering descendant
    # would keep the lock held after this update exits.
    if "$CLAUDE_BIN" plugin update "$key" 9>&-; then
      echo "== $key: command succeeded (not yet verified — run verify)"
      ok=$((ok + 1))
    else
      echo "== $key: FAIL — plugin update exited nonzero"
      failed+=("$key")
    fi
    done_keys+=("$key")
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "update: FAILED for: ${failed[*]} — install may be MIXED; re-run those and verify"
    return 1
  fi
  echo "update: all $ok update commands succeeded"
  # The install is in place; now prove it, then repair the user's config to
  # match it. verify's own reconcile checks are suppressed for this pass (they
  # describe exactly what reconcile is about to fix) and re-run once after.
  # NB: a `VAR=x func` prefix persists after the call in bash, so set and reset
  # it explicitly rather than relying on the prefix form.
  VERIFY_RECON_CHECK=0
  cmd_verify || { VERIFY_RECON_CHECK=1; echo "update: verify FAILED after updating — fix that before reconciling"; return 1; }
  VERIFY_RECON_CHECK=1
  cmd_reconcile 0 || return 1
  recon_scan
  if [ "${#RECON_HOOK[@]}" -gt 0 ]; then
    for reason in "${RECON_HOOK[@]}"; do echo "update: FAIL — ${reason#hook: }"; done
    echo "update: reconcile ran but the configuration is still inconsistent"
    return 1
  fi
  echo "update: reconcile clean — run verify to re-check, and RESTART"
}

cmd_verify() {
  local i m key want ver path sha head snapver snapsha expect pm pv bh cur snap reason bad=0 gfail=0 n=0 fails=()
  require_installed
  all_targets
  for m in "${!MKT_NAMES[@]}"; do
    require_snapshot "${MKT_SNAPSHOTS[$m]}"
    bh=$(jq -r --arg b "$BOUND_KEY" '.[$b].boundHead // ""' "${MKT_SNAPSHOTS[$m]}")
    if [ -z "$bh" ]; then
      echo "verify: FAIL — snapshot has no $BOUND_KEY: update was never run for this snapshot"
      gfail=1
    else
      cur=$(git -C "${MKT_CLONES[$m]}" rev-parse HEAD 2>/dev/null) || cur=""
      if [ "$cur" != "$bh" ]; then
        echo "verify: FAIL — clone moved after bind; gate proved nothing about the installed code (bound $bh, now ${cur:-<unreadable>})"
        gfail=1
      fi
    fi
    if ! tree_clean "${MKT_CLONES[$m]}"; then
      echo "verify: FAIL — clone modified after bind (tree dirty); gate proved nothing about the installed code"
      printf '%s\n' "$PORC" | sed 's/^/    /'
      gfail=1
    fi
  done
  for i in "${!KEYS[@]}"; do
    key=${KEYS[$i]}; bad=0; snap=${MKT_SNAPSHOTS[${TIDX[$i]}]}
    want=$(manifest_version "${MANIFESTS[$i]}") || exit 1
    if [ "${TINST[$i]}" -eq 0 ]; then
      echo "skip: $key not installed"; continue
    fi
    n=$((n + 1))
    ver=$(inst_field "$key" version) || ver=""
    path=$(inst_field "$key" installPath) || path=""
    sha=$(inst_field "$key" gitCommitSha) || sha=""
    if [ -z "$sha" ]; then
      echo "$key: FAIL — installed entry has no gitCommitSha"; bad=1
    fi
    if [ "$ver" != "$want" ]; then
      echo "$key: FAIL — installed version '${ver:-<none>}' != manifest version '$want'"; bad=1
    fi
    expect="$AI_CREW_CACHE/${TMKTS[$i]}/${TNAMES[$i]}/$want"
    if [ "$path" != "$expect" ]; then
      echo "$key: FAIL — installPath '${path:-<none>}' != '$expect'"; bad=1
    elif [ ! -d "$path" ]; then
      echo "$key: FAIL — installPath $path does not exist"; bad=1
    else
      pm="$path/.claude-plugin/plugin.json"
      if [ ! -f "$pm" ]; then
        echo "$key: FAIL — payload manifest $pm missing (empty or partial install)"; bad=1
      else
        pv=$(jq -e -r '.version | select(type == "string")' "$pm" 2>/dev/null) || pv=""
        if [ "$pv" != "$want" ]; then
          echo "$key: FAIL — payload manifest version '${pv:-<none>}' != '$want'"; bad=1
        fi
      fi
    fi
    if ! jq -e --arg k "$key" 'has($k)' "$snap" >/dev/null; then
      echo "$key: FAIL — no entry in snapshot $snap (stale snapshot?)"; bad=1
    elif [ "$bad" -eq 0 ]; then
      snapver=$(jq -r --arg k "$key" '.[$k].version // ""' "$snap")
      snapsha=$(jq -r --arg k "$key" '.[$k].gitCommitSha // ""' "$snap")
      if [ "$snapver" = "$ver" ]; then
        if [ "$sha" = "$snapsha" ]; then
          echo "$key: PASS $ver — no-op (version unchanged)"
        else
          echo "$key: FAIL — sha changed without a version change ($snapsha -> $sha)"; bad=1
        fi
      else
        # Only a version change should move gitCommitSha. Compared against
        # the marketplace CLONE's HEAD (never the local repo). Strict for the
        # vendor too: its installed sha matched its clone HEAD when written
        # (2026-09-10), so the unchanged install satisfies the strict rule.
        head=$(git -C "${HEADCLONES[$i]}" rev-parse HEAD 2>/dev/null) || head=""
        if [ -n "$head" ] && [ "$sha" = "$head" ]; then
          echo "$key: PASS ${snapver:-<not installed>} -> $ver (gitCommitSha $sha)"
        else
          echo "$key: FAIL — version changed ${snapver:-<not installed>} -> $ver but gitCommitSha '${sha:-<none>}' != clone HEAD '${head:-<unreadable>}' (${HEADCLONES[$i]})"
          bad=1
        fi
      fi
    fi
    [ "$bad" -eq 0 ] || fails+=("$key")
  done
  # A plugin-owned hook still registered in settings.json FIRES TWICE (the
  # plugin's own hooks.json registers it as well), or runs the old code from a
  # previous installPath. An unset fragment env var silently changes behaviour.
  # Both are invisible at runtime, so they are verify failures, not warnings.
  # verify itself NEVER writes: the remedy is to run reconcile and verify again.
  # $VERIFY_RECON_CHECK=0 is used by update for its own pre-reconcile pass,
  # where these checks are expected to fail and are re-run after reconcile.
  if [ "${VERIFY_RECON_CHECK:-1}" -eq 1 ]; then recon_scan; else RECON_HOOK=(); fi
  if [ "${#RECON_HOOK[@]}" -gt 0 ]; then
    for reason in "${RECON_HOOK[@]}"; do echo "verify: FAIL — ${reason#hook: }"; done
    gfail=1
  fi
  if [ "${#fails[@]}" -gt 0 ] || [ "$gfail" -ne 0 ]; then
    echo "verify: FAILED${fails[*]:+ for: ${fails[*]}}"
    return 1
  fi
  echo "verify: PASS ($n entries)"
  echo "REMINDER: run /reload-plugins to pick up hook and MCP changes, or open a NEW session; env changes (and anything this session already read) need a full restart."
}

[ $# -ge 1 ] || usage
sub=$1; shift
case $sub in
  status) [ $# -eq 0 ] || usage; init_marketplaces; cmd_status ;;
  gate) [ $# -eq 0 ] || usage; init_marketplaces; cmd_gate ;;
  bind) [ $# -eq 0 ] || usage; init_marketplaces; cmd_bind ;;
  snapshot) [ $# -eq 0 ] || usage; init_marketplaces; cmd_snapshot ;;
  update) [ $# -eq 0 ] || usage; init_marketplaces; cmd_update ;;
  verify) [ $# -eq 0 ] || usage; init_marketplaces; cmd_verify ;;
  reconcile)
    case ${1:-} in
      "") [ $# -eq 0 ] || usage; cmd_reconcile 0 ;;
      --dry-run) [ $# -eq 1 ] || usage; cmd_reconcile 1 ;;
      --accept-ambiguous) shift; [ $# -ge 1 ] || usage; cmd_accept_ambiguous "$@" ;;
      --record-migrated) shift; [ $# -ge 1 ] || usage; cmd_record_migrated "$@" ;;
      *) usage ;;
    esac ;;
  *) usage ;;
esac
