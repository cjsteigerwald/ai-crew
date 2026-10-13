#!/usr/bin/env bash
# Behavioral test for coordinating-partner-sessions/scripts/parse-msg.sh:
# valid and invalid partner messages, shell-metacharacter safety, and the
# --frame mode. Runnable standalone.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PARSE="$ROOT/skills/coordinating-partner-sessions/scripts/parse-msg.sh"

FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=1
}

[ -f "$PARSE" ] || { echo "FAIL: $PARSE not found (parse-msg.sh not found)" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

SHA="0123456789abcdef0123456789abcdef01234567"
SHA39="${SHA%?}"
SYNC="fedcba9876543210fedcba9876543210fedcba98"

OUT=""
ERR=""
RC=0
# run <args...> — sets OUT, ERR, RC
run() {
  OUT="$("$BASH" "$PARSE" "$@" 2>"$T/err")"
  RC=$?
  ERR="$(cat "$T/err")"
}

has_line() { printf '%s\n' "$OUT" | grep -Fxq -- "$1"; }

# expect_ok <name> <arg> [expected-line...]
expect_ok() {
  name="$1"; arg="$2"; shift 2
  run "$arg"
  if [ "$RC" -ne 0 ]; then fail "$name: expected rc 0, got $RC ($ERR)"; return; fi
  for l in "$@"; do
    has_line "$l" || fail "$name: stdout missing line '$l' (got: $OUT)"
  done
  echo "ok: $name"
}

# expect_bad <name> <arg>
expect_bad() {
  name="$1"; arg="$2"
  run "$arg"
  if [ "$RC" -ne 1 ]; then fail "$name: expected rc 1, got $RC"; return; fi
  [ -z "$OUT" ] || fail "$name: stdout not empty on rejection: $OUT"
  case "$ERR" in error=*) ;; *) fail "$name: stderr lacks error=: $ERR" ;; esac
  echo "ok: $name"
}

expect_ok "valid STARTED" "STARTED #12 gen=1" kind=STARTED issue=12 gen=1
expect_ok "valid DONE" "DONE #12 gen=2 abc-x-12 $SHA synced=$SYNC" \
  kind=DONE issue=12 gen=2 branch=abc-x-12 "sha=$SHA" "synced=$SYNC"
expect_ok "STUCK with needs" "STUCK #12 gen=1 needs=#9 waits on schema" \
  kind=STUCK needs=9 "reason=waits on schema"
expect_ok "STUCK without needs" "STUCK #12 gen=1 cannot reach the test db" \
  kind=STUCK "reason=cannot reach the test db"
if printf '%s\n' "$OUT" | grep -q '^needs='; then
  fail "STUCK without needs: unexpected needs= line"
fi
expect_ok "valid SCOPE" "SCOPE #12 gen=1 needs three PRs" kind=SCOPE "reason=needs three PRs"
expect_ok "valid FAILED" "FAILED #12 gen=3 user cancelled" kind=FAILED gen=3 "reason=user cancelled"

expect_bad "missing gen" "STARTED #12"
expect_bad "bad gen" "STARTED #12 gen=x"
expect_bad "short sha" "DONE #12 gen=2 abc-x-12 $SHA39 synced=$SYNC"
expect_bad "uppercase sha" "DONE #12 gen=2 abc-x-12 ABCDEF0123456789ABCDEF0123456789ABCDEF01 synced=$SYNC"
expect_bad "bad branch leading dash" "DONE #12 gen=2 -x $SHA synced=$SYNC"
expect_bad "bad branch double dot" "DONE #12 gen=2 a..b $SHA synced=$SYNC"
expect_bad "trailing prose on DONE" "DONE #12 gen=2 abc-x-12 $SHA synced=$SYNC extra"
expect_bad "unknown kind" "MERGED #12 gen=1"
expect_bad "empty reason" "FAILED #12 gen=1"

# Metacharacters must be inert.
expect_ok "metachar reason" "FAILED #12 gen=1 \$(touch $T/pwned); \`touch $T/pwned2\`" \
  "reason=\$(touch $T/pwned); \`touch $T/pwned2\`"
{ [ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ]; } || fail "metachar reason: command executed"
expect_bad "metachar branch" "DONE #12 gen=2 x;touch $T/p $SHA synced=$SYNC"
[ ! -e "$T/p" ] || fail "metachar branch: command executed"

# Whitespace and newlines.
expect_ok "CRLF and trailing space" "$(printf 'STARTED #12 gen=1  \r')" kind=STARTED issue=12 gen=1
expect_bad "embedded newline" "$(printf 'STARTED #12 gen=1\nDONE #12 gen=1 b %s synced=%s' "$SHA" "$SYNC")"
expect_bad "embedded CR" "$(printf 'STARTED #12\r gen=1')"
expect_bad "newline then text" "$(printf 'STARTED #12 gen=1\nx')"

# --frame mode.
F='<cross-session-message from="ABC-12">STARTED #12 gen=1</cross-session-message>'
run --frame "$F"
if [ "$RC" -ne 0 ]; then fail "frame ok: rc $RC ($ERR)"; else
  [ "$(printf '%s\n' "$OUT" | sed -n 1p)" = "from=ABC-12" ] || fail "frame ok: first line not from=ABC-12: $OUT"
  has_line kind=STARTED || fail "frame ok: missing kind=STARTED"
  echo "ok: frame ok"
fi
run --frame '<agent-message from="ABC-12">STARTED #12 gen=1</agent-message>'
{ [ "$RC" -eq 1 ] && [ -z "$OUT" ]; } || fail "frame wrong kind: rc=$RC out=$OUT"
run --frame "$F$F"
{ [ "$RC" -eq 1 ] && [ -z "$OUT" ]; } || fail "frame two messages: rc=$RC out=$OUT"
run --frame "<cross-session-message from=\"a\$(touch $T/f)\">STARTED #12 gen=1</cross-session-message>"
{ [ "$RC" -eq 1 ] && [ -z "$OUT" ]; } || fail "frame metachar from: rc=$RC out=$OUT"
[ ! -e "$T/f" ] || fail "frame metachar from: command executed"
run --frame '<cross-session-message from="ABC-12">STARTED #12</cross-session-message>'
{ [ "$RC" -eq 1 ] && [ -z "$OUT" ]; } || fail "frame bad body: rc=$RC out=$OUT"
echo "ok: frame rejections"

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "all parse-msg tests passed"
