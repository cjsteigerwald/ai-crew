#!/usr/bin/env bash
# Behavioral test for coordinating-partner-sessions/scripts/ff-merge.sh:
# fast-forward-only integration of a partner branch into the ticket branch.
# Runnable standalone.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FFM="$ROOT/skills/coordinating-partner-sessions/scripts/ff-merge.sh"

FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=1
}

[ -f "$FFM" ] || { echo "FAIL: $FFM not found (ff-merge.sh not found)" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

OUT=""
ERR=""
RC=0
# run <args...> — runs in $R; sets OUT, ERR, RC.
run() {
  OUT="$(cd "$R" && "$BASH" "$FFM" "$@" 2>"$T/err")"
  RC=$?
  ERR="$(cat "$T/err")"
}

g() { git -C "$R" "$@"; }

# mkrepo <name> — fresh repo in $R, ticket branch checked out with one commit.
mkrepo() {
  R="$T/$1"
  mkdir -p "$R"
  git init -q "$R"
  g config user.name "Test"
  g config user.email "test@example.invalid"
  g checkout -q -b ticket
  echo base >"$R/f"
  g add f
  g commit -q -m base
}

# commit_on <branch> <file> — adds one commit on <branch>, returns to ticket.
commit_on() {
  g checkout -q "$1"
  echo "$2" >"$R/$2"
  g add "$2"
  g commit -q -m "$2"
  g checkout -q ticket
}

# cand — candidate branch from the current ticket head plus one commit.
cand() {
  g branch cand
  commit_on cand c1
  CAND="$(g rev-parse cand)"
}

expect() { # <name> <want-rc>
  [ "$RC" -eq "$2" ] || fail "$1: expected rc $2, got $RC ($ERR)"
}

# check current
mkrepo check-current
cand; HEAD0="$(g rev-parse ticket)"
run --check ticket "$CAND"
expect "check current" 0
[ -z "$OUT" ] || fail "check current: expected no output, got '$OUT'"
[ "$(g rev-parse ticket)" = "$HEAD0" ] || fail "check current: ticket moved"
echo "ok: check current"

# check stale
mkrepo check-stale
cand
commit_on ticket t1; NEW="$(g rev-parse ticket)"
run --check ticket "$CAND"
expect "check stale" 10
[ "$OUT" = "head=$NEW" ] || fail "check stale: expected 'head=$NEW', got '$OUT'"
[ "$(g rev-parse ticket)" = "$NEW" ] || fail "check stale: ticket moved"
[ "$(g rev-parse cand)" = "$CAND" ] || fail "check stale: cand moved"
echo "ok: check stale"

# clean ff
mkrepo clean-ff
cand; HEAD0="$(g rev-parse ticket)"
run ticket "$CAND" "$HEAD0"
expect "clean ff" 0
[ "$OUT" = "head=$CAND" ] || fail "clean ff: expected 'head=$CAND', got '$OUT'"
[ "$(g rev-parse ticket)" = "$CAND" ] || fail "clean ff: ticket not at candidate"
echo "ok: clean ff"

# head moved after pin
mkrepo moved
cand; HEAD0="$(g rev-parse ticket)"
commit_on ticket t1; NEW="$(g rev-parse ticket)"
run ticket "$CAND" "$HEAD0"
expect "head moved after pin" 10
[ "$OUT" = "head=$NEW" ] || fail "head moved: expected 'head=$NEW', got '$OUT'"
[ "$(g rev-parse ticket)" = "$NEW" ] || fail "head moved: ticket changed"
echo "ok: head moved after pin"

# stale pin, candidate contains the new head: only the pin comparison can reject
mkrepo stale-pin
HEAD0="$(g rev-parse ticket)"
commit_on ticket t1; NEW="$(g rev-parse ticket)"
g branch cand
commit_on cand c1; CAND="$(g rev-parse cand)"
run ticket "$CAND" "$HEAD0"
expect "stale pin" 10
[ "$OUT" = "head=$NEW" ] || fail "stale pin: expected 'head=$NEW', got '$OUT'"
[ "$(g rev-parse ticket)" = "$NEW" ] || fail "stale pin: ticket changed"
echo "ok: stale pin"

# diverged: pin is current but the candidate does not contain the head
mkrepo diverged
g branch cand
commit_on cand c1; CAND="$(g rev-parse cand)"
commit_on ticket t1; NEW="$(g rev-parse ticket)"
run ticket "$CAND" "$NEW"
expect "diverged" 10
[ "$(g rev-parse ticket)" = "$NEW" ] || fail "diverged: ticket changed"
echo "ok: diverged"

# nonexistent sha
mkrepo nosha
HEAD0="$(g rev-parse ticket)"
run ticket 0123456789abcdef0123456789abcdef01234567 "$HEAD0"
expect "nonexistent sha" 2
[ "$(g rev-parse ticket)" = "$HEAD0" ] || fail "nonexistent sha: ticket changed"
run --check ticket 0123456789abcdef0123456789abcdef01234567
expect "nonexistent sha (check)" 2
echo "ok: nonexistent sha"

# malformed sha
mkrepo badsha
HEAD0="$(g rev-parse ticket)"
run ticket abc "$HEAD0"
expect "malformed sha" 2
run --check ticket abc
expect "malformed sha (check)" 2
run ticket "$HEAD0" abc
expect "malformed pin" 2
run ticket
expect "missing args" 2
echo "ok: malformed sha"

# dirty worktree: only tracked changes count (ruling FV1)
mkrepo dirty
cand; HEAD0="$(g rev-parse ticket)"
echo x >"$R/f"
run ticket "$CAND" "$HEAD0"
expect "dirty worktree" 3
[ "$(cat "$R/f")" = x ] || fail "dirty worktree: tracked modification lost"
[ "$(g rev-parse ticket)" = "$HEAD0" ] || fail "dirty worktree: ticket changed"
run --check ticket "$CAND"
expect "dirty worktree (check ignores worktree)" 0
echo "ok: dirty worktree"

# an untracked file alone does not block the merge
mkrepo untracked
cand; HEAD0="$(g rev-parse ticket)"
echo x >"$R/untracked"
run ticket "$CAND" "$HEAD0"
expect "untracked file" 0
[ -f "$R/untracked" ] || fail "untracked file: removed"
[ "$(g rev-parse ticket)" = "$CAND" ] || fail "untracked file: ticket not at candidate"
echo "ok: untracked file"

# partner worktrees under .claude/worktrees/ do not block the merge
mkrepo nested-wt
cand; HEAD0="$(g rev-parse ticket)"
g branch partner-x
g worktree add -q "$R/.claude/worktrees/x" partner-x
run ticket "$CAND" "$HEAD0"
expect "nested worktree" 0
[ "$(g rev-parse ticket)" = "$CAND" ] || fail "nested worktree: ticket not at candidate"
echo "ok: nested worktree"

# wrong branch checked out
mkrepo wrongbranch
cand; HEAD0="$(g rev-parse ticket)"
g checkout -q -b main
run ticket "$CAND" "$HEAD0"
expect "wrong branch" 3
[ "$(g rev-parse ticket)" = "$HEAD0" ] || fail "wrong branch: ticket changed"
echo "ok: wrong branch"

# state in the git dir does not make the worktree dirty
mkrepo gitdir-state
cand; HEAD0="$(g rev-parse ticket)"
COMMON="$(cd "$R" && git rev-parse --git-common-dir)"
case "$COMMON" in /*) ;; *) COMMON="$R/$COMMON" ;; esac
mkdir -p "$COMMON/partner-sessions/K"
echo '{}' >"$COMMON/partner-sessions/K/ledger.json"
run ticket "$CAND" "$HEAD0"
expect "state in git dir" 0
[ "$(g rev-parse ticket)" = "$CAND" ] || fail "state in git dir: ticket not at candidate"
echo "ok: state in git dir is clean"

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "all ff-merge tests passed"
