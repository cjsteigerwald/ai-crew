#!/usr/bin/env bash
# ff-merge.sh — fast-forward-only integration of a partner branch into the
# ticket branch. Run with cwd = the worktree that has the ticket branch checked out.
#
#   ff-merge.sh --check <ticket-branch> <sha>
#       exit 0 (no output) if the ticket head is an ancestor of <sha>;
#       exit 10 printing head=<sha> otherwise. Never changes a ref and never
#       inspects the worktree.
#   ff-merge.sh <ticket-branch> <sha> <pinned-head>
#       fast-forwards only if the ticket head equals <pinned-head> and is an
#       ancestor of <sha>; exit 0 printing head=<sha>, else exit 10 printing the
#       current head=. Exit 3: branch not checked out here, or worktree dirty.
#
# Exit 2: argument errors, malformed or nonexistent SHA.
# Only ever runs `git merge --ff-only`; never stashes, resets or rebases.
#
# Bash 3.2 compatible.
set -u

usage() { echo "usage: ff-merge.sh --check <branch> <sha> | <branch> <sha> <pinned-head>" >&2; exit 2; }

is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

CHECK=0
if [ "${1:-}" = "--check" ]; then
  CHECK=1
  shift
  [ "$#" -eq 2 ] || usage
else
  [ "$#" -eq 3 ] || usage
fi

BRANCH="$1"
SHA="$2"
PIN="${3:-}"

[ -n "$BRANCH" ] || usage
is_sha "$SHA" || { echo "ff-merge: malformed sha: $SHA" >&2; exit 2; }
if [ "$CHECK" -eq 0 ]; then
  is_sha "$PIN" || { echo "ff-merge: malformed pinned head: $PIN" >&2; exit 2; }
fi

git rev-parse --verify --quiet "$SHA^{commit}" >/dev/null \
  || { echo "ff-merge: no such commit: $SHA" >&2; exit 2; }

HEAD_SHA="$(git rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}")" \
  || { echo "ff-merge: no such branch: $BRANCH" >&2; exit 2; }

if [ "$CHECK" -eq 1 ]; then
  if git merge-base --is-ancestor "$HEAD_SHA" "$SHA"; then
    exit 0
  fi
  echo "head=$HEAD_SHA"
  exit 10
fi

CUR="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
if [ "$CUR" != "$BRANCH" ]; then
  echo "ff-merge: $BRANCH is not checked out here (on '${CUR:-detached}')" >&2
  exit 3
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "ff-merge: worktree is dirty" >&2
  exit 3
fi

if [ "$HEAD_SHA" != "$PIN" ] || ! git merge-base --is-ancestor "$HEAD_SHA" "$SHA"; then
  echo "head=$HEAD_SHA"
  exit 10
fi

git merge --ff-only --quiet "$SHA" >/dev/null 2>&1 \
  || { echo "ff-merge: git merge --ff-only failed" >&2; exit 1; }
echo "head=$(git rev-parse HEAD)"
exit 0
