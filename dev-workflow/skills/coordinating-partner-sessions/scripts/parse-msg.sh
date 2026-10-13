#!/usr/bin/env bash
# parse-msg.sh — validate one partner->coordinator message (trust boundary).
#
#   parse-msg.sh <line>            validate a message line
#   parse-msg.sh --frame <raw>     validate a whole <cross-session-message> frame
#
# Exit 0: key=value lines on stdout. Exit 1: error=<reason> on stderr, nothing
# on stdout. Message text is only ever held in variables: no eval, never
# interpolated into a command.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
set -u

die() {
  printf 'error=%s\n' "$1" >&2
  exit 1
}

NL=$'\n'
CR=$'\r'

RE_ISSUE='^#([0-9]+)$'
RE_GEN='^gen=([0-9]+)$'
RE_SHA='^[0-9a-f]{40}$'
RE_SYNCED='^synced=([0-9a-f]{40})$'
RE_BRANCH='^[a-z0-9][a-z0-9._/-]*$'
RE_NEEDS='^needs=#([0-9]+)$'
RE_FROM='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# parse_line <line> — prints key=value lines; exits 1 on any violation.
parse_line() {
  local line="$1" rest

  # Reject embedded newlines and any CR other than one trailing, before any
  # splitting (a bare `read -r` would silently drop everything after the first
  # newline).
  case "$line" in *"$NL"*) die "embedded newline" ;; esac
  if [[ "$line" == *"$CR" ]]; then line="${line%"$CR"}"; fi
  case "$line" in *"$CR"*) die "embedded carriage return" ;; esac
  while [[ "$line" == *" " ]]; do line="${line% }"; done

  local kind issue_tok gen_tok
  read -r kind issue_tok gen_tok rest <<<"$line"
  [ -n "${gen_tok:-}" ] || die "missing fields"

  [[ "$issue_tok" =~ $RE_ISSUE ]] || die "bad issue"
  local issue="${BASH_REMATCH[1]}"
  [[ "$gen_tok" =~ $RE_GEN ]] || die "bad gen"
  local gen="${BASH_REMATCH[1]}"

  case "$kind" in
    STARTED)
      [ -z "$rest" ] || die "unexpected trailing text"
      printf 'kind=%s\nissue=%s\ngen=%s\n' "$kind" "$issue" "$gen"
      ;;
    DONE)
      local branch sha synced extra
      read -r branch sha synced extra <<<"$rest"
      [ -n "${synced:-}" ] || die "missing DONE fields"
      [ -z "${extra:-}" ] || die "unexpected trailing text"
      [[ "$branch" =~ $RE_BRANCH ]] || die "bad branch"
      git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "bad branch"
      [[ "$sha" =~ $RE_SHA ]] || die "bad sha"
      [[ "$synced" =~ $RE_SYNCED ]] || die "bad synced"
      printf 'kind=%s\nissue=%s\ngen=%s\nbranch=%s\nsha=%s\nsynced=%s\n' \
        "$kind" "$issue" "$gen" "$branch" "$sha" "${BASH_REMATCH[1]}"
      ;;
    STUCK)
      local needs=""
      local first="${rest%% *}"
      if [[ "$first" =~ $RE_NEEDS ]]; then
        needs="${BASH_REMATCH[1]}"
        if [[ "$rest" == *" "* ]]; then rest="${rest#* }"; else rest=""; fi
      fi
      [ -n "$rest" ] || die "missing reason"
      printf 'kind=%s\nissue=%s\ngen=%s\n' "$kind" "$issue" "$gen"
      [ -z "$needs" ] || printf 'needs=%s\n' "$needs"
      printf 'reason=%s\n' "$rest"
      ;;
    SCOPE|FAILED)
      [ -n "$rest" ] || die "missing reason"
      printf 'kind=%s\nissue=%s\ngen=%s\nreason=%s\n' "$kind" "$issue" "$gen" "$rest"
      ;;
    *) die "unknown kind" ;;
  esac
}

[ $# -ge 1 ] || die "usage: parse-msg.sh [--frame] <text>"

if [ "$1" = "--frame" ]; then
  [ $# -eq 2 ] || die "usage: parse-msg.sh --frame <raw>"
  raw="$2"
  OPEN_RE='^<cross-session-message from="([^"]*)">'
  CLOSE='</cross-session-message>'
  [[ "$raw" =~ $OPEN_RE ]] || die "not a cross-session-message frame"
  from="${BASH_REMATCH[1]}"; open="${BASH_REMATCH[0]}"
  [[ "$from" =~ $RE_FROM ]] || die "bad from"
  body="${raw#"$open"}"
  [[ "$body" == *"$CLOSE" ]] || die "frame not closed"
  body="${body%"$CLOSE"}"
  case "$body" in
    *"<cross-session-message"*|*"$CLOSE"*) die "more than one frame" ;;
  esac
  # Validate fully before printing anything, so failure leaves stdout empty.
  parsed="$(parse_line "$body")" || exit 1
  printf 'from=%s\n%s\n' "$from" "$parsed"
else
  [ $# -eq 1 ] || die "usage: parse-msg.sh <line>"
  parsed="$(parse_line "$1")" || exit 1
  printf '%s\n' "$parsed"
fi
