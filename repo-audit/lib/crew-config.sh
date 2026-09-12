#!/usr/bin/env bash
# crew-config.sh — sourceable bash library for reading the crew's shared
# JSON config file. Bash 3.2 compatible (no associative arrays, no mapfile,
# no ${var,,}). Requires `jq` for actual reads; falls back to documented
# defaults (with a stderr warning) when `jq` cannot be found.
#
# Source this file, then call:
#   crew_config_get <key> [default]   — string value of a top-level or
#                                        dotted-path key (e.g. "lanes.scout")
#   crew_config_list <key>            — array elements, one per line
#   crew_config_path                  — resolved config file path
#
# CREW_CONFIG_FILE (env) overrides the config file location. Default:
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/config.json
#
# A missing config file, or a key that is absent/null, silently returns the
# built-in default (or the caller-supplied default, if given). A config file
# that EXISTS but is not valid JSON is an error: crew_config_get and
# crew_config_list print "crew-config: <file> is not valid JSON" to stderr
# and return 3 — this never silently falls back, because a malformed config
# is a authoring mistake the caller needs to see, not a "config absent" state.
#
# jq is required to read a config file that exists — if jq is missing AND
# the file is present, that is also a hard error ("crew-config: jq is
# required to read <file>", return 3): silently ignoring a config the user
# actually wrote would be worse than refusing. jq missing AND the file
# absent is the only case that falls back quietly (with the one-line
# warning) — there is nothing on disk to have silently ignored.
#
# Shape is enforced too: crew_config_get on a key whose value is a JSON
# object or array returns 3 ("<key> is not a scalar"); crew_config_list on a
# key whose value exists but is not an array returns 3 ("<key> is not an
# array"). A key that is absent or null is never a shape error — it is the
# normal "use the default" case for both functions.
#
# Schema (top-level keys, all optional — showing the built-in default):
#
#   research_root         string   ~/Research
#   research_state_dir    string   ~/.claude/tech-research-state
#   audit_output_root     string   ~/repo-audits
#   audit_cache_dir       string   ~/.cache/repo-audit
#   package_output_root   string   ~/ai-readiness
#   delivery_dir          string   ""            (empty = disabled)
#   token_map             string   ~/.claude/plugins/data/crew/token-map
#   org_allowlist         array    []
#   marketplaces          array    [{"name":"cjs-plugins","repo":"~/repos/ai-crew"}]
#   lanes                 object   see below
#
#   lanes.scout               claude-crew:claude-scout
#   lanes.reader               claude-crew:claude-reader
#   lanes.implementer_haiku    claude-crew:claude-implementer-haiku
#   lanes.implementer_sonnet   claude-crew:claude-implementer-sonnet
#   lanes.implementer_opus     claude-crew:claude-implementer-opus
#   lanes.writer                code-writer
#   lanes.verifier               fresh-verifier
#   lanes.adversary               codex-adversary
#
# See lib/crew-config.example.json (sibling of the canonical copy of this
# file) for the full defaults document, machine-readable.
#
# Any leading "~" in a returned string VALUE is expanded to $HOME (paths
# only; this does not apply to non-path values like lane names).

: "${CREW_CONFIG_FILE:=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/config.json}"

crew_config_path() {
  printf '%s\n' "$CREW_CONFIG_FILE"
}

# Internal: default for a given dotted key.
_crew_config_default() {
  case "$1" in
    research_root) printf '%s' '~/Research' ;;
    research_state_dir) printf '%s' '~/.claude/tech-research-state' ;;
    audit_output_root) printf '%s' '~/repo-audits' ;;
    audit_cache_dir) printf '%s' '~/.cache/repo-audit' ;;
    package_output_root) printf '%s' '~/ai-readiness' ;;
    delivery_dir) printf '%s' '' ;;
    token_map) printf '%s' '~/.claude/plugins/data/crew/token-map' ;;
    lanes.scout) printf '%s' 'claude-crew:claude-scout' ;;
    lanes.reader) printf '%s' 'claude-crew:claude-reader' ;;
    lanes.implementer_haiku) printf '%s' 'claude-crew:claude-implementer-haiku' ;;
    lanes.implementer_sonnet) printf '%s' 'claude-crew:claude-implementer-sonnet' ;;
    lanes.implementer_opus) printf '%s' 'claude-crew:claude-implementer-opus' ;;
    lanes.writer) printf '%s' 'code-writer' ;;
    lanes.verifier) printf '%s' 'fresh-verifier' ;;
    lanes.adversary) printf '%s' 'codex-adversary' ;;
    *) printf '%s' '' ;;
  esac
}

# Internal: default for a given array key (one element per line).
_crew_config_default_list() {
  case "$1" in
    org_allowlist) printf '' ;;
    marketplaces) printf '%s\n' '{"name":"cjs-plugins","repo":"~/repos/ai-crew"}' ;;
    *) printf '' ;;
  esac
}

# Internal: expand a leading ~ to $HOME.
_crew_config_expand_tilde() {
  case "$1" in
    '~'|'~/'*) printf '%s' "$HOME${1#\~}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Internal: convert a dotted key ("lanes.scout") into a jq path expression
# (.lanes.scout). Keys are restricted to [A-Za-z0-9_.] by convention; no
# escaping is attempted beyond the simple dot-split.
_crew_config_jq_path() {
  printf '.%s' "$1"
}

crew_config_get() {
  key="$1"
  caller_default="${2:-}"
  have_default=0
  [ $# -ge 2 ] && have_default=1

  if [ "$have_default" -eq 1 ]; then
    default="$caller_default"
  else
    default="$(_crew_config_default "$key")"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    if [ -f "$CREW_CONFIG_FILE" ]; then
      echo "crew-config: jq is required to read $CREW_CONFIG_FILE" >&2
      return 3
    fi
    echo "crew-config: jq not found; using defaults" >&2
    _crew_config_expand_tilde "$default"
    printf '\n'
    return 0
  fi

  if [ ! -f "$CREW_CONFIG_FILE" ]; then
    _crew_config_expand_tilde "$default"
    printf '\n'
    return 0
  fi

  if ! jq -e . >/dev/null 2>&1 <"$CREW_CONFIG_FILE"; then
    echo "crew-config: $CREW_CONFIG_FILE is not valid JSON" >&2
    return 3
  fi

  jqpath="$(_crew_config_jq_path "$key")"
  vtype="$(jq -r "${jqpath} | type" "$CREW_CONFIG_FILE" 2>/dev/null || echo null)"

  case "$vtype" in
    object|array)
      echo "crew-config: $key is not a scalar" >&2
      return 3
      ;;
    null)
      _crew_config_expand_tilde "$default"
      printf '\n'
      return 0
      ;;
  esac

  value="$(jq -r "$jqpath" "$CREW_CONFIG_FILE" 2>/dev/null)"

  if [ -z "$value" ]; then
    _crew_config_expand_tilde "$default"
    printf '\n'
    return 0
  fi

  _crew_config_expand_tilde "$value"
  printf '\n'
}

crew_config_list() {
  key="$1"

  if ! command -v jq >/dev/null 2>&1; then
    if [ -f "$CREW_CONFIG_FILE" ]; then
      echo "crew-config: jq is required to read $CREW_CONFIG_FILE" >&2
      return 3
    fi
    echo "crew-config: jq not found; using defaults" >&2
    _crew_config_default_list "$key"
    return 0
  fi

  if [ ! -f "$CREW_CONFIG_FILE" ]; then
    _crew_config_default_list "$key"
    return 0
  fi

  if ! jq -e . >/dev/null 2>&1 <"$CREW_CONFIG_FILE"; then
    echo "crew-config: $CREW_CONFIG_FILE is not valid JSON" >&2
    return 3
  fi

  jqpath="$(_crew_config_jq_path "$key")"
  vtype="$(jq -r "${jqpath} | type" "$CREW_CONFIG_FILE" 2>/dev/null || echo null)"

  case "$vtype" in
    null)
      _crew_config_default_list "$key"
      return 0
      ;;
    array)
      ;;
    *)
      echo "crew-config: $key is not an array" >&2
      return 3
      ;;
  esac

  count="$(jq -r "${jqpath} | length" "$CREW_CONFIG_FILE" 2>/dev/null || echo 0)"

  if [ "$count" = "0" ] || [ -z "$count" ]; then
    _crew_config_default_list "$key"
    return 0
  fi

  jq -r "${jqpath}[]" "$CREW_CONFIG_FILE" 2>/dev/null
}
