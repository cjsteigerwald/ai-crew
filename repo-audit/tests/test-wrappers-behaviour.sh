#!/usr/bin/env bash
# Behavioral test for the repo-audit read-only wrappers (git-read, gh-read,
# repo-fetch): builds a throwaway git repo and exercises the wrappers'
# read paths and refusal paths against it. Never touches the real
# ~/.claude, ~/.cache, or any network endpoint.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
BIN="$PLUGIN_DIR/bin"

FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=1
}

REPO="$(mktemp -d)"
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$REPO" "$FAKE_HOME"' EXIT

export PATH="$BIN:$PATH"
export HOME="$FAKE_HOME"
export CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude"

# --- Build the fixture repo: 3 commits, 2 files, a branch --------------------

(
  cd "$REPO" || exit 1
  git init -q -b main .
  git config user.email "fixture@example.com"
  git config user.name "Fixture"
  echo "one" >file1.txt
  git add file1.txt
  git commit -q -m "commit 1"
  echo "two" >file2.txt
  git add file2.txt
  git commit -q -m "commit 2"
  echo "one-b" >>file1.txt
  git add file1.txt
  git commit -q -m "commit 3"
  git branch feature
) || { echo "FAIL: could not build fixture repo" >&2; exit 1; }

BEFORE_HEAD="$(git -C "$REPO" rev-parse HEAD)"

# --- (a) git-read log --limit 2 returns a limit-respecting, truncated read --

echo "== git-read log --limit =="

log_out="$(git-read log --limit 2 --in "$REPO")"
log_lines="$(printf '%s\n' "$log_out" | wc -l | tr -d ' ')"
# 2 lines of raw `git log` output (limit), plus the truncation marker line
# git-read appends whenever total output exceeds --limit (17 raw lines for
# 3 commits here).
[ "$log_lines" -eq 3 ] || fail "git-read log --limit 2: expected 3 output lines (2 content + truncation marker), got $log_lines"

printf '%s\n' "$log_out" | sed -n '1p' | grep -qE '^commit [0-9a-f]{40}$' \
  || fail "git-read log --limit 2: first line is not a commit header"

printf '%s\n' "$log_out" | tail -1 | grep -qE '^\(showing 2 of [0-9]+ lines\)$' \
  || fail "git-read log --limit 2: missing/incorrect truncation marker line"

# --- (b) git-read ls-files lists both files ----------------------------------

echo "== git-read ls-files =="

ls_out="$(git-read ls-files --in "$REPO")"
printf '%s\n' "$ls_out" | grep -qx 'file1.txt' || fail "git-read ls-files: file1.txt missing"
printf '%s\n' "$ls_out" | grep -qx 'file2.txt' || fail "git-read ls-files: file2.txt missing"

# --- (c) mutating git-read subcommands are refused, repo left untouched -----

echo "== git-read refuses mutating subcommands =="

for sub_args in "commit -m nope" "push" "checkout main"; do
  # shellcheck disable=SC2086
  out="$(git-read $sub_args --in "$REPO" 2>&1)"
  rc=$?
  sub="${sub_args%% *}"
  [ "$rc" -eq 0 ] || fail "git-read $sub: expected exit 0 (wrapper contract), got $rc"
  printf '%s\n' "$out" | grep -qE "^ERROR: git-read: subcommand not allowed: $sub$" \
    || fail "git-read $sub: expected a 'subcommand not allowed' refusal, got: $out"
done

after_head="$(git -C "$REPO" rev-parse HEAD)"
[ "$after_head" = "$BEFORE_HEAD" ] || fail "git-read mutating attempts changed HEAD ($BEFORE_HEAD -> $after_head)"

status_out="$(git -C "$REPO" status --porcelain)"
[ -z "$status_out" ] || fail "git-read mutating attempts left a dirty working tree: $status_out"

# --- (d) gh-read refuses non-GET usage without touching the network ---------

echo "== gh-read refuses non-GET usage =="

# gh-read has no --method flag at all; passing one is refused by its
# argument parser (the "unsupported argument" branch in bin/gh-read) before
# any gh/network call is made — that IS the GET-only guard.
gh_out="$(gh-read repos/example-org/example-repo --method POST 2>&1)"
gh_rc=$?
[ "$gh_rc" -eq 0 ] || fail "gh-read --method POST: expected exit 0 (wrapper contract), got $gh_rc"
printf '%s\n' "$gh_out" | grep -qE '^ERROR: gh-read: unsupported argument: --method$' \
  || fail "gh-read --method POST: expected an 'unsupported argument' refusal, got: $gh_out"

# --- (e) repo-fetch on a local path reports SOURCE=local, no mutation -------

echo "== repo-fetch local path =="

find "$REPO" -type f | sort >"$FAKE_HOME/before-files"
fetch_out="$(repo-fetch "$REPO" 2>&1)"
fetch_rc=$?
find "$REPO" -type f | sort >"$FAKE_HOME/after-files"

[ "$fetch_rc" -eq 0 ] || fail "repo-fetch: expected exit 0, got $fetch_rc"
printf '%s\n' "$fetch_out" | grep -qE '^SOURCE=local$' \
  || fail "repo-fetch on a local path did not report SOURCE=local: $fetch_out"
diff -q "$FAKE_HOME/before-files" "$FAKE_HOME/after-files" >/dev/null 2>&1 \
  || fail "repo-fetch modified the local repo's file list"

after_head2="$(git -C "$REPO" rev-parse HEAD)"
[ "$after_head2" = "$BEFORE_HEAD" ] || fail "repo-fetch changed HEAD ($BEFORE_HEAD -> $after_head2)"

# --- (f) a non-default audit_output_root is honoured by repo-fetch AND -----
# --- ai-readiness-package identically, from the same config file -----------

echo "== non-default audit_output_root: repo-fetch and ai-readiness-package agree =="

CUSTOM_ROOT="$FAKE_HOME/custom-audits"
mkdir -p "$FAKE_HOME/.claude/plugins/data/crew"
cat >"$FAKE_HOME/.claude/plugins/data/crew/config.json" <<EOF
{"audit_output_root": "$CUSTOM_ROOT"}
EOF

fetch2_out="$(repo-fetch "$REPO" 2>&1)"
fetch2_rc=$?
[ "$fetch2_rc" -eq 0 ] || fail "repo-fetch (custom audit_output_root): expected exit 0, got $fetch2_rc"
printf '%s\n' "$fetch2_out" | grep -qxF "AUDIT_OUTPUT_ROOT=$CUSTOM_ROOT" \
  || fail "repo-fetch did not report the configured audit_output_root: $fetch2_out"

# A report from that same repo-fetch call would land under
# $CUSTOM_ROOT/<id>/<date>/. Put fixture roll-up files there directly (no
# need to run a real audit) and confirm ai-readiness-package — which resolves
# audit_output_root independently — finds them at the SAME path rather than
# looking under the default ~/repo-audits.
PKG_ID="example-org-example-repo"
PKG_DATE="2024-01-01"
mkdir -p "$CUSTOM_ROOT/$PKG_ID/$PKG_DATE"
echo "# executive summary fixture" >"$CUSTOM_ROOT/$PKG_ID/$PKG_DATE/executive-summary.md"
echo "# agentic readiness fixture" >"$CUSTOM_ROOT/$PKG_ID/$PKG_DATE/agentic-readiness.md"

pkg_out="$(ai-readiness-package "$PKG_ID" "$PKG_DATE" 2>&1)"
pkg_rc=$?
[ "$pkg_rc" -eq 0 ] || fail "ai-readiness-package (custom audit_output_root): expected exit 0, got $pkg_rc"
printf '%s\n' "$pkg_out" | grep -qE '^ERROR: ' \
  && fail "ai-readiness-package could not find the fixture under the configured audit_output_root: $pkg_out"
printf '%s\n' "$pkg_out" | grep -qE '^PACKAGE=' \
  || fail "ai-readiness-package did not report a PACKAGE= path: $pkg_out"

echo "== Result =="
if [ "$FAIL" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
exit 0
