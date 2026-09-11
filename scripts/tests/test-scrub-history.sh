#!/usr/bin/env bash
# Fixture tests for scripts/scrub-history.sh. Builds disposable throwaway
# git repos under mktemp; never touches the real repo's history.
#
# THIS FILE IS COMMITTED TO A PUBLIC REPOSITORY — every fixture is
# SYNTHETIC. Organisation-specific patterns come from a PRIVATE denylist
# outside the repo; these tests write their own synthetic one into the
# temp dir and point $SCRUB_DENYLIST at it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$HERE/../scrub-history.sh"
TMP="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

assert_exit() {
  desc="$1"; expected="$2"; actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc (exit $actual)"
  else
    fail "$desc (expected exit $expected, got $actual)"
  fi
}

PRIV="$TMP/private-denylist.txt"
{
  printf '# synthetic private denylist used only by this test\n'
  printf 'employer\ti\t\\<acme\\>|acmecorp\n'
} > "$PRIV"
export SCRUB_DENYLIST="$PRIV"

git_init() {
  git init -q "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
  git -C "$1" config commit.gpgsign false
}

# --- repo 1: a secret added then deleted, plus a private-class term -------
REPO="$TMP/repo"
git_init "$REPO"
(
  cd "$REPO"
  printf '%s\n' 'hello' > a.txt
  git add a.txt
  git commit -q -m "init"
  printf '%s\n' 'AKIAABCDEFGHIJKLMNOP leaked here' > secret.txt
  printf '%s\n' 'built for acmecorp internal use' > vendor.txt
  git add secret.txt vendor.txt
  git commit -q -m "oops leaked a secret"
  git rm -q secret.txt vendor.txt
  git commit -q -m "remove leaked files"
)

OUT1="$(cd "$REPO" && bash "$SH" --allow /dev/null 2>&1)"
rc1=$?
assert_exit "unallowlisted historical hit" "1" "$rc1"
if echo "$OUT1" | grep -q '^secret-shape: secret\.txt '; then
  pass "historical hit reported with normalized (no leading prefix) path"
else
  fail "historical hit not reported as expected (got: $OUT1)"
fi
if echo "$OUT1" | grep -q '^employer: vendor\.txt '; then
  pass "private-denylist class caught in history"
else
  fail "private-denylist class NOT caught in history (got: $OUT1)"
fi

# --- case: an allowlisted historical hit is suppressed --------------------
ALLOWFILE="$TMP/allow.txt"
{
  printf '%s\n' 'secret-shape:^secret\.txt$'
  printf '%s\n' 'employer:^vendor\.txt$'
} > "$ALLOWFILE"
OUT2="$(cd "$REPO" && bash "$SH" --allow "$ALLOWFILE" 2>&1)"
rc2=$?
assert_exit "allowlisted historical hit" "0" "$rc2"
if echo "$OUT2" | grep -q 'secret-shape:'; then
  fail "allowlisted historical hit was still reported (got: $OUT2)"
else
  pass "allowlisted historical hit suppressed"
fi

# --- case: --require-private with no private denylist -> exit 2 -----------
OUT_RP="$(cd "$REPO" && SCRUB_DENYLIST="$TMP/no-such-file.txt" bash "$SH" --require-private --allow /dev/null 2>&1)"
rc_rp=$?
assert_exit "--require-private with a missing private denylist" "2" "$rc_rp"

# --- repo 2: content lines that LOOK like diff headers --------------------
# A committed line whose own text starts with "++" renders as "+++..." in
# the patch, and one starting with "--" renders as "---...". The old filter
# dropped both as if they were the patch's "+++ b/<path>" / "--- a/<path>"
# headers, so a secret hiding behind that prefix was invisible.
REPO2="$TMP/repo-plusplus"
git_init "$REPO2"
(
  cd "$REPO2"
  printf '%s\n' '++AKIAPLUSPLUSAAAAAAAA' > plus.txt
  git add plus.txt
  git commit -q -m "added line beginning with ++"
  printf '%s\n' '--AKIAMINUSMINUSAAAAAA' > minus.txt
  git add minus.txt
  git commit -q -m "line beginning with --, to be removed next"
  git rm -q minus.txt
  git commit -q -m "remove it, so the patch renders ---AKIA..."
)

OUT3="$(cd "$REPO2" && bash "$SH" --allow /dev/null 2>&1)"
rc3=$?
assert_exit "content lines shaped like diff headers" "1" "$rc3"
if echo "$OUT3" | grep -q 'AKIAPLUSPLUSAAAAAAAA'; then
  pass "added content line starting with ++ is scanned"
else
  fail "added content line starting with ++ was SKIPPED (got: $OUT3)"
fi
if echo "$OUT3" | grep -q 'AKIAMINUSMINUSAAAAAA'; then
  pass "content line starting with -- is scanned (added form)"
else
  fail "content line starting with -- was SKIPPED entirely (got: $OUT3)"
fi
if echo "$OUT3" | grep -qE '^(secret-shape): (plus|minus)\.txt \(commit [0-9a-f]{7,}\)'; then
  pass "diff-header-shaped hits carry file and commit context"
else
  fail "diff-header-shaped hits lack context (got: $OUT3)"
fi
# Real patch headers must still never be reported as content.
if echo "$OUT3" | grep -qE ':[[:space:]]*(\+\+\+ b/|--- a/)'; then
  fail "a real +++ b/ or --- a/ patch header was reported as content (got: $OUT3)"
else
  pass "real patch headers still ignored"
fi

# --- repo 3: a blob the text scan cannot read -----------------------------
REPO3="$TMP/repo-binary"
git_init "$REPO3"
(
  cd "$REPO3"
  printf 'plain\n' > ok.txt
  printf 'PK\003\004\000\000binary\000payload\000' > blob.bin
  # UTF-16LE text: every other byte is NUL, so git treats it as binary too.
  printf 'A\000K\000I\000A\000\000\000' > utf16.txt
  git add ok.txt blob.bin utf16.txt
  git commit -q -m "add binary blobs"
)

OUT4="$(cd "$REPO3" && bash "$SH" --allow /dev/null 2>&1)"
rc4=$?
assert_exit "unscannable blobs warn with exit 4" "4" "$rc4"
if echo "$OUT4" | grep -qE '^unscanned-binary: blob\.bin \(commit [0-9a-f]{7,}\)$'; then
  pass "binary blob reported as unscanned-binary with commit context"
else
  fail "binary blob not reported (got: $OUT4)"
fi
if echo "$OUT4" | grep -q '^unscanned-binary: utf16\.txt '; then
  pass "UTF-16 blob reported as unscanned-binary"
else
  fail "UTF-16 blob not reported (got: $OUT4)"
fi
if echo "$OUT4" | grep -q '^unscanned-binary: ok\.txt'; then
  fail "plain text blob wrongly reported as unscanned-binary (got: $OUT4)"
else
  pass "plain text blob not reported as unscanned-binary"
fi

# A real denylist hit outranks the soft binary warning.
(
  cd "$REPO3"
  printf '%s\n' 'AKIABINARYNEIGHBORAA' > leak.txt
  git add leak.txt
  git commit -q -m "leak next to the binaries"
)
OUT5="$(cd "$REPO3" && bash "$SH" --allow /dev/null 2>&1)"
rc5=$?
assert_exit "hit outranks the unscanned-binary warning" "1" "$rc5"
if echo "$OUT5" | grep -q '^unscanned-binary: blob\.bin '; then
  pass "unscanned-binary still reported alongside a hard hit"
else
  fail "unscanned-binary lost when a hard hit is present (got: $OUT5)"
fi

# --- repo 4: text that exists only in a merge resolution ------------------
# Without `git log -m` git prints no patch at all for a merge commit, so a
# secret introduced while resolving a conflict is never scanned.
REPO4="$TMP/repo-merge"
git_init "$REPO4"
(
  cd "$REPO4"
  printf '%s\n' 'base' > f.txt
  git add f.txt
  git commit -q -m "base"
  git checkout -q -b side
  printf '%s\n' 'side change' > f.txt
  git commit -q -am "side"
  git checkout -q -
  printf '%s\n' 'main change' > f.txt
  git commit -q -am "main"
  git merge -q side >/dev/null 2>&1 || true
  # Resolve with text present in NEITHER parent.
  printf '%s\n' 'AKIAMERGERESOLUTION1' > f.txt
  git add f.txt
  git commit -q --no-edit -m "merge side" >/dev/null 2>&1
)
OUT6="$(cd "$REPO4" && bash "$SH" --allow /dev/null 2>&1)"
rc6=$?
assert_exit "merge-only content is scanned" "1" "$rc6"
if echo "$OUT6" | grep -q 'AKIAMERGERESOLUTION1'; then
  pass "text introduced by a merge resolution is scanned"
else
  fail "merge-resolution-only text was NOT scanned (got: $OUT6)"
fi

# --- repo 5: history allow file suppresses a historical hit ---
# The history allow file is loaded by scrub-history.sh but NOT by
# scrub-check.sh, so entries in it won't be flagged as dead by
# --check-allowlist.
REPO5="$TMP/repo-history-allow"
git_init "$REPO5"
(
  cd "$REPO5"
  printf '%s\n' 'initial' > f.txt
  git add f.txt
  git commit -q -m "init"
  # This would normally be caught as a secret-shape hit if not allowlisted
  printf '%s\n' 'AKIAHISTORYALLOWTEST' > h.txt
  git add h.txt
  git commit -q -m "commit with secret"
  # Delete it so it only exists in history, never in the working tree
  git rm -q h.txt
  git commit -q -m "remove secret file"
)

# Without the allow file, the hit should be reported
OUT7="$(cd "$REPO5" && bash "$SH" --allow /dev/null 2>&1)"
rc7=$?
assert_exit "historical hit in repo5" "1" "$rc7"
if echo "$OUT7" | grep -q 'AKIAHISTORYALLOWTEST'; then
  pass "historical-only secret caught"
else
  fail "historical-only secret NOT caught (got: $OUT7)"
fi

# The history-only allowlist is PRIVATE: it lives outside the repository,
# at $SCRUB_ALLOW_HISTORY (default under $CLAUDE_CONFIG_DIR), because
# excusing content that exists only in a published commit means naming it,
# and naming it in a committed file re-publishes it.
HISTORY_ALLOW="$TMP/private-scrub-allow-history.txt"
printf '%s\n' 'secret-shape:^h\.txt$:AKIAHISTORYALLOWTEST' > "$HISTORY_ALLOW"

OUT8="$(cd "$REPO5" && SCRUB_ALLOW_HISTORY="$HISTORY_ALLOW" bash "$SH" 2>&1)"
rc8=$?
assert_exit "private history allowlist suppresses a historical hit" "0" "$rc8"
if echo "$OUT8" | grep -q 'AKIAHISTORYALLOWTEST'; then
  fail "historical hit NOT suppressed by the private history allowlist (got: $OUT8)"
else
  pass "historical hit suppressed by the private history allowlist"
fi

MISSING_HIST="$TMP/no-such-history-allow.txt"
OUT8B="$(cd "$REPO5" && SCRUB_ALLOW_HISTORY="$MISSING_HIST" bash "$SH" 2>&1)"
rc8b=$?
assert_exit "missing private history allowlist does not suppress" "1" "$rc8b"
if echo "$OUT8B" | grep -q "^scrub: no private history allowlist at $MISSING_HIST$"; then
  pass "missing private history allowlist warning printed"
else
  fail "missing private history allowlist warning absent (got: $OUT8B)"
fi

# --- repo 6: allow files are SCANNED in history, field by field -----------
# Only the match-regex field of an entry line is exempt. A denylisted value
# in a COMMENT of the same file, or in another file, is still a hit.
REPO6="$TMP/repo-allow-file-fields"
git_init "$REPO6"
(
  cd "$REPO6"
  printf '%s\n' 'initial' > f.txt
  git add f.txt
  git commit -q -m "init"
  mkdir -p scripts
  # The third field carries a DOCUMENTED PUBLIC EXAMPLE (scrub-public-
  # examples.txt), which is the only credential shape allowed to sit
  # there, and is scoped to a path that does not exist in this repo so it
  # suppresses nothing else.
  printf '%s\n' 'secret-shape:^nowhere\.txt$:AKIAIOSFODNN7EXAMPLE' > scripts/scrub-allow.txt
  git add scripts/scrub-allow.txt
  git commit -q -m "add scrub-allow.txt documenting an exception"
)

OUT9="$(cd "$REPO6" && bash "$SH" --allow /dev/null 2>&1)"
rc9=$?
assert_exit "commit adding an allow file: match-regex field exempt" "0" "$rc9"
if echo "$OUT9" | grep -q 'AKIAIOSFODNN7EXAMPLE'; then
  fail "the allow file's match-regex field was flagged (got: $OUT9)"
else
  pass "allow file's match-regex field not flagged"
fi
if echo "$OUT9" | grep -q 'skipping allow file'; then
  fail "the allow file was SKIPPED wholesale in history (got: $OUT9)"
else
  pass "allow file not skipped wholesale in history"
fi

(
  cd "$REPO6"
  printf '%s\n' 'AKIAALLOWFILETESTVAL' > other.txt
  git add other.txt
  git commit -q -m "same value, but in a real file this time"
)
OUT10="$(cd "$REPO6" && bash "$SH" --allow /dev/null 2>&1)"
rc10=$?
assert_exit "same value added to a non-allow file in another commit" "1" "$rc10"
if echo "$OUT10" | grep -q '^secret-shape: other\.txt '; then
  pass "non-allow file with the same value still caught"
else
  fail "non-allow file with the same value NOT caught (got: $OUT10)"
fi

# A credential that is NOT a documented public example cannot be laundered
# through the match-regex field: the field is itself scanned, so the whole
# line is reported.
(
  cd "$REPO6"
  printf '%s\n' 'secret-shape:^nowhere\.txt$:AKIALAUNDEREDVIAFIELD' >> scripts/scrub-allow.txt
  git add scripts/scrub-allow.txt
  git commit -q -m "non-example credential in a match-regex field"
)
OUT10B="$(cd "$REPO6" && bash "$SH" --allow /dev/null 2>&1)"
rc10b=$?
assert_exit "non-example credential in a match-regex field" "1" "$rc10b"
if echo "$OUT10B" | grep -q '^secret-shape: scripts/scrub-allow\.txt .*AKIALAUNDEREDVIAFIELD'; then
  pass "non-example credential in a match-regex field reported"
else
  fail "non-example credential in a match-regex field NOT reported (got: $OUT10B)"
fi

# A commit that puts a secret in a COMMENT of the allow file is a hit —
# the exemption is field-level, not file-level, so an allow file cannot be
# used to launder a credential into history.
(
  cd "$REPO6"
  printf '%s\n' '# pasted by mistake: AKIACOMMENTLAUNDERED1' >> scripts/scrub-allow.txt
  git add scripts/scrub-allow.txt
  git commit -q -m "comment in the allow file"
)
OUT11="$(cd "$REPO6" && bash "$SH" --allow /dev/null 2>&1)"
rc11=$?
assert_exit "secret in an allow-file comment, in history" "1" "$rc11"
if echo "$OUT11" | grep -q '^secret-shape: scripts/scrub-allow\.txt .*AKIACOMMENTLAUNDERED1'; then
  pass "secret in an allow-file comment caught in history"
else
  fail "secret in an allow-file comment NOT caught in history (got: $OUT11)"
fi

# --- repo 7: a content line that reproduces a header's exact shape --------
# "++ b/x <secret>" renders as "+++ b/x <secret>" in the patch. A filter
# that tests for the "+++ b/" shape — not just the "+++" prefix — still
# discards it. Headers are only headers as an adjacent --- / +++ pair.
REPO7="$TMP/repo-header-shape"
git_init "$REPO7"
(
  cd "$REPO7"
  printf '%s\n' '++ b/x AKIAIOSFODNN7SECRETV' > shaped.txt
  printf '%s\n' '++ /dev/null AKIADEVNULLSHAPED012' >> shaped.txt
  git add shaped.txt
  git commit -q -m "content lines shaped exactly like patch headers"
)
OUT12="$(cd "$REPO7" && bash "$SH" --allow /dev/null 2>&1)"
rc12=$?
assert_exit "header-shaped content lines are scanned" "1" "$rc12"
if echo "$OUT12" | grep -q 'AKIAIOSFODNN7SECRETV'; then
  pass "'++ b/...' content line is scanned"
else
  fail "'++ b/...' content line was SKIPPED (got: $OUT12)"
fi
if echo "$OUT12" | grep -q 'AKIADEVNULLSHAPED012'; then
  pass "'++ /dev/null ...' content line is scanned"
else
  fail "'++ /dev/null ...' content line was SKIPPED (got: $OUT12)"
fi
# The real headers of that same commit must still not be reported.
if echo "$OUT12" | grep -qE ': \+\+\+ b/shaped\.txt$|: --- /dev/null$'; then
  fail "a real patch header was reported as content (got: $OUT12)"
else
  pass "real patch headers still ignored"
fi

# --- repo 8: a header-shaped PAIR inside a hunk ---------------------------
# Replacing a line reading "-- a/x" with one reading "++ b/x <secret>"
# renders as an adjacent "--- a/x" / "+++ b/x <secret>" pair — byte-for-
# byte the shape of a real file-header pair, but sitting inside a hunk.
# Headers are only headers between "diff --git" and the first "@@", so
# this must be scanned.
REPO8="$TMP/repo-header-pair-in-hunk"
git_init "$REPO8"
(
  cd "$REPO8"
  printf '%s\n' 'context line' > pair.txt
  printf '%s\n' '-- a/x' >> pair.txt
  printf '%s\n' 'trailing context' >> pair.txt
  git add pair.txt
  git commit -q -m "harmless line that looks like half a header"
  printf '%s\n' 'context line' > pair.txt
  printf '%s\n' '++ b/x AKIAIOSFODNN7SECRETV' >> pair.txt
  printf '%s\n' 'trailing context' >> pair.txt
  git add pair.txt
  git commit -q -m "replace it, producing an adjacent ---/+++ pair in a hunk"
)
OUT13="$(cd "$REPO8" && bash "$SH" --allow /dev/null 2>&1)"
rc13=$?
assert_exit "header-shaped pair inside a hunk is scanned" "1" "$rc13"
if echo "$OUT13" | grep -q 'AKIAIOSFODNN7SECRETV'; then
  pass "'++ b/x <secret>' adjacent to '-- a/x' inside a hunk is caught"
else
  fail "header-shaped PAIR inside a hunk was SKIPPED (got: $OUT13)"
fi
# The real file headers of those same commits must still be ignored.
if echo "$OUT13" | grep -qE ': \+\+\+ b/pair\.txt$|: --- a/pair\.txt$|: --- /dev/null$'; then
  fail "a real patch header was reported as content (got: $OUT13)"
else
  pass "real patch headers still ignored"
fi

# --- repo 9: what the field exemption must NOT cover ----------------------
# (a) scripts/scrub-allow-history.txt is not an allow file. scrub-history.sh
#     loads the history allowlist from the PRIVATE $SCRUB_ALLOW_HISTORY,
#     outside the repo; a file of that name committed INSIDE the repo is
#     read by nothing, so registering it as an allow path only exempted
#     values from the scan that were nonetheless published.
# (b) the exemption is bound to the pattern being SCANNED: an entry named
#     for uuid must not excuse its third field during the employer scan.
REPO9="$TMP/repo-exemption-limits"
git_init "$REPO9"
(
  cd "$REPO9"
  printf '%s\n' 'initial' > f.txt
  git add f.txt
  git commit -q -m "init"
  mkdir -p scripts
  printf '%s\n' 'employer:^nowhere\\.txt$:acmecorp' > scripts/scrub-allow-history.txt
  git add scripts/scrub-allow-history.txt
  git commit -q -m "history allowlist committed into the repo"
)
OUT14="$(cd "$REPO9" && bash "$SH" --allow /dev/null 2>&1)"
rc14=$?
assert_exit "in-tree scrub-allow-history.txt gets no field exemption" "1" "$rc14"
if echo "$OUT14" | grep -q '^employer: scripts/scrub-allow-history\.txt .*acmecorp'; then
  pass "committed scrub-allow-history.txt scanned like any other file"
else
  fail "committed scrub-allow-history.txt still exempted (got: $OUT14)"
fi

REPO10="$TMP/repo-cross-pattern"
git_init "$REPO10"
(
  cd "$REPO10"
  printf '%s\n' 'initial' > f.txt
  git add f.txt
  git commit -q -m "init"
  mkdir -p scripts
  printf '%s\n' 'uuid:^nowhere\\.txt$:acmecorp' > scripts/scrub-allow.txt
  git add scripts/scrub-allow.txt
  git commit -q -m "uuid exception whose third field names something else"
)
OUT15="$(cd "$REPO10" && bash "$SH" --allow /dev/null 2>&1)"
rc15=$?
assert_exit "cross-pattern laundering in history" "1" "$rc15"
if echo "$OUT15" | grep -q '^employer: scripts/scrub-allow\.txt .*acmecorp'; then
  pass "value laundered under another class's name caught in history"
else
  fail "value laundered under another class's name NOT caught (got: $OUT15)"
fi

# The honest form still gets its exemption.
REPO11="$TMP/repo-cross-pattern-ok"
git_init "$REPO11"
(
  cd "$REPO11"
  printf '%s\n' 'initial' > f.txt
  git add f.txt
  git commit -q -m "init"
  mkdir -p scripts
  printf '%s\n' 'employer:^nowhere\\.txt$:acmecorp' > scripts/scrub-allow.txt
  git add scripts/scrub-allow.txt
  git commit -q -m "employer exception naming the value it excuses"
)
OUT16="$(cd "$REPO11" && bash "$SH" --allow /dev/null 2>&1)"
rc16=$?
assert_exit "entry named for its own class is still exempt in history" "0" "$rc16"

if [ "$FAILED" -ne 0 ]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All tests PASSED"
exit 0
