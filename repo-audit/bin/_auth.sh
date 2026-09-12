# shellcheck shell=bash
# _auth.sh — choose the GitHub token for an audit target's org. Sourced, not run.
#
# Requires crew_config_get to already be defined (source lib/crew-config.sh
# before this file). Map file: config key `token_map`, default
# ~/.claude/plugins/data/crew/token-map — lines of "<org> <ENV_VAR_NAME>". If the
# target's org is mapped and that variable is set, gh uses it (GH_TOKEN) and
# GITHUB_TOKEN is dropped. Unmapped orgs use gh's normal authentication.

# Print the owner parsed from a directory's origin remote. Never prints the URL.
audit_owner_of_dir() {
  local url
  url=$(git -C "${1:-.}" -c core.fsmonitor=false config --get remote.origin.url 2>/dev/null) || return 1
  url=${url%.git}
  url=${url#*github.com[:/]}
  printf '%s\n' "${url%%/*}"
}

# Apply the mapped token for an owner. Sets AUDIT_TOKEN_NOTE for error hints.
audit_apply_token() {
  local owner=${1:-} map var=''
  map="$(crew_config_get token_map)"
  AUDIT_TOKEN_NOTE=''
  [ -n "$owner" ] && [ -f "$map" ] || return 0
  var=$(awk -v o="$owner" '$1 == o { print $2; exit }' "$map")
  [ -n "$var" ] || return 0
  if [ -n "${!var:-}" ]; then
    export GH_TOKEN="${!var}"
    unset GITHUB_TOKEN
    AUDIT_TOKEN_NOTE="token from \$$var"
  else
    AUDIT_TOKEN_NOTE="mapped token variable \$$var is not set"
  fi
  # Some orgs reject classic PATs older than a max age with HTTP 404 rather
  # than 403 — a caller seeing an unexplained 404 should suspect this before
  # assuming the resource is missing. Only append when there is already a
  # note to hang it on (an error/hint case): a routine successful token
  # application should not carry this caveat on every call.
  [ -z "$AUDIT_TOKEN_NOTE" ] || AUDIT_TOKEN_NOTE+="; some orgs reject expired classic PATs with HTTP 404, not 403"
}
