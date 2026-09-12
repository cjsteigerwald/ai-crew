#!/usr/bin/env bash
# Fixture tests for scripts/scrub-check.sh. Uses a throwaway mktemp dir;
# never touches the real repo (other than reading scrub-check.sh itself).
#
# THIS FILE IS COMMITTED TO A PUBLIC REPOSITORY. Every fixture below is
# SYNTHETIC — no real employer name, hostname, ticket key, system name or
# personal handle appears here. Organisation-specific patterns live in a
# PRIVATE denylist outside the repo; the tests exercise that path by
# writing their own synthetic private denylist into the temp dir and
# pointing $SCRUB_DENYLIST at it.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/../scrub-check.sh"
TMP="$(mktemp -d)"

cleanup() {
  chmod 0755 "$TMP/ro-tmp" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

assert_exit() {
  desc="$1"
  expected="$2"
  actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc (exit $actual)"
  else
    fail "$desc (expected exit $expected, got $actual)"
  fi
}

# --- synthetic private denylist -------------------------------------------
PRIV="$TMP/private-denylist.txt"
{
  printf '# synthetic private denylist used only by this test\n'
  printf 'employer\ti\t\\<acme\\>|acmecorp\n'
  printf 'employer-host\ti\tacmecorp\\.com\n'
  printf 'ticket-key\ti\t\\<(acme|proj)[-_]?[0-9]+\\>\n'
  printf 'internal-system\ti\t\\<(alpha|bravo)-(prod|test|dev)\\>\n'
  printf 'user-handle\ti\tjdoe@example\\.com|\\<jdoe\\>\n'
} > "$PRIV"
export SCRUB_DENYLIST="$PRIV"

FIXDIR="$TMP/fixtures"
mkdir -p "$FIXDIR"

# One file per pattern class — each must be caught. Generic classes first.
printf '%s\n' '/home/bob/stuff' > "$FIXDIR/home-path.txt"
printf '%s\n' '/mnt/tsclient/share' > "$FIXDIR/rdp-share.txt"
printf '%s\n' 'id 123e4567-e89b-12d3-a456-426614174000' > "$FIXDIR/uuid.txt"
# Case-folded identity class: the SAME uuid upper-cased must also be caught.
printf '%s\n' 'id 123E4567-E89B-12D3-A456-426614174000' > "$FIXDIR/uuid-upper.txt"
printf '%s\n' 'AKIAABCDEFGHIJKLMNOP' > "$FIXDIR/secret-shape.txt"
# ...then the classes that only exist because the private denylist is loaded.
printf '%s\n' 'a trip to acme' > "$FIXDIR/employer.txt"
printf '%s\n' 'https://acmecorp.com/login' > "$FIXDIR/employer-host.txt"
printf '%s\n' 'see ACME-1234 for details' > "$FIXDIR/ticket-key.txt"
printf '%s\n' 'the alpha-prod cluster' > "$FIXDIR/internal-system.txt"
printf '%s\n' 'jdoe@example.com' > "$FIXDIR/user-handle.txt"

# A clean file — must never be flagged.
printf '%s\n' 'nothing interesting here' > "$FIXDIR/clean.txt"

# An allowlisted hit.
printf '%s\n' 'deliberately mentions acme here' > "$FIXDIR/allowed.txt"
ALLOWFILE="$TMP/allow.txt"
printf '%s\n' 'employer:allowed\.txt$' > "$ALLOWFILE"

OUT="$(bash "$SC" --allow "$ALLOWFILE" "$FIXDIR" 2>&1)"
rc=$?
assert_exit "pattern fixtures + allowlist" "1" "$rc"

for name in home-path rdp-share uuid secret-shape employer employer-host ticket-key internal-system user-handle; do
  if echo "$OUT" | grep -q "^${name}: "; then
    pass "pattern class caught: $name"
  else
    fail "pattern class NOT caught: $name (output: $OUT)"
  fi
done

if echo "$OUT" | grep -q 'uuid-upper\.txt'; then
  pass "case-folded uuid caught (upper-case fixture)"
else
  fail "upper-case uuid NOT caught (output: $OUT)"
fi

if echo "$OUT" | grep -q 'clean\.txt'; then
  fail "clean file was flagged"
else
  pass "clean file not flagged"
fi

if echo "$OUT" | grep -q 'allowed\.txt'; then
  fail "allowlisted hit was still reported"
else
  pass "allowlisted hit suppressed"
fi

# --- private denylist plumbing --------------------------------------------
# Absent private file: warn on stderr, keep scanning the generic classes.
GENDIR="$TMP/generic-only"
mkdir -p "$GENDIR"
printf '%s\n' 'a trip to acme' > "$GENDIR/org.txt"
printf '%s\n' '/home/bob/stuff' > "$GENDIR/home.txt"
MISSING="$TMP/no-such-denylist.txt"

OUT_NP="$(SCRUB_DENYLIST="$MISSING" bash "$SC" "$GENDIR" 2>&1)"
rc_np=$?
assert_exit "missing private denylist still scans generic classes" "1" "$rc_np"
if echo "$OUT_NP" | grep -q "^scrub: no private denylist at $MISSING (generic classes only)$"; then
  pass "missing private denylist warning printed"
else
  fail "missing private denylist warning absent (got: $OUT_NP)"
fi
if echo "$OUT_NP" | grep -q '^home-path: '; then
  pass "generic class still enforced without a private denylist"
else
  fail "generic class not enforced without a private denylist (got: $OUT_NP)"
fi
if echo "$OUT_NP" | grep -q '^employer: '; then
  fail "private class somehow enforced with no private denylist (got: $OUT_NP)"
else
  pass "private class absent when the private denylist is missing"
fi

# --require-private turns the same situation into a hard error.
OUT_RP="$(SCRUB_DENYLIST="$MISSING" bash "$SC" --require-private "$GENDIR" 2>&1)"
rc_rp=$?
assert_exit "--require-private with a missing private denylist" "2" "$rc_rp"
if echo "$OUT_RP" | grep -q 'require-private'; then
  pass "--require-private error message present"
else
  fail "--require-private error message missing (got: $OUT_RP)"
fi

# A malformed private denylist is an error, never a silently-smaller scan.
BADPRIV="$TMP/bad-denylist.txt"
printf '%s\n' 'employer i \<acme\>' > "$BADPRIV"
OUT_BAD="$(SCRUB_DENYLIST="$BADPRIV" bash "$SC" "$GENDIR" 2>&1)"
rc_bad=$?
assert_exit "malformed private denylist" "2" "$rc_bad"
if echo "$OUT_BAD" | grep -q 'malformed entry'; then
  pass "malformed private denylist reported"
else
  fail "malformed private denylist not reported (got: $OUT_BAD)"
fi

# --- fail-closed fault injection ------------------------------------------
# Both cases used to exit 0: mktemp failed, every redirection into the
# non-existent temp dir failed, each grep "found nothing", and the scan
# reported the tree clean without having read a single byte of it.
OUT_TMP1="$(TMPDIR=/nonexistent-scrub-tmp bash "$SC" "$FIXDIR" 2>&1)"
rc_tmp1=$?
assert_exit "fault injection: TMPDIR points at a missing directory" "2" "$rc_tmp1"
if [ "$rc_tmp1" -eq 0 ]; then
  fail "FAIL-OPEN: unusable TMPDIR reported a dirty tree as clean"
else
  pass "unusable TMPDIR did not report clean"
fi
if echo "$OUT_TMP1" | grep -q 'temporary directory'; then
  pass "missing-TMPDIR error message present"
else
  fail "missing-TMPDIR error message absent (got: $OUT_TMP1)"
fi

ROTMP="$TMP/ro-tmp"
mkdir -p "$ROTMP"
chmod 0500 "$ROTMP"
OUT_TMP2="$(TMPDIR="$ROTMP" bash "$SC" "$FIXDIR" 2>&1)"
rc_tmp2=$?
chmod 0755 "$ROTMP"
assert_exit "fault injection: TMPDIR is a mode-500 directory" "2" "$rc_tmp2"
if [ "$rc_tmp2" -eq 0 ]; then
  fail "FAIL-OPEN: read-only TMPDIR reported a dirty tree as clean"
else
  pass "read-only TMPDIR did not report clean"
fi

# --- allowlist value scoping ----------------------------------------------
# A file may legitimately contain ONE documented example credential. The
# allowlist's third field pins the exception to that value: a second,
# different secret in the same file (or on the same line) must still fail.
VDIR="$TMP/value-scope"
mkdir -p "$VDIR"
printf '%s\n' 'documented example key AKIAIOSFODNN7EXAMPLE in prose' > "$VDIR/known.txt"
VALLOW="$TMP/value-allow.txt"
printf '%s\n' 'secret-shape:^known\.txt$:AKIAIOSFODNN7EXAMPLE' > "$VALLOW"

OUT_V1="$(cd "$VDIR" && bash "$SC" --allow "$VALLOW" . 2>&1)"
rc_v1=$?
assert_exit "value-scoped allow: known fixture passes" "0" "$rc_v1"
if echo "$OUT_V1" | grep -q 'secret-shape:'; then
  fail "value-scoped allow did not suppress the known value (got: $OUT_V1)"
else
  pass "value-scoped allow suppressed the known value"
fi

printf '%s\n' 'but also AKIAZZZZZZZZZZZZZZZZ which is not the example' >> "$VDIR/known.txt"
OUT_V2="$(cd "$VDIR" && bash "$SC" --allow "$VALLOW" . 2>&1)"
rc_v2=$?
assert_exit "value-scoped allow: second secret in the same file fails" "1" "$rc_v2"
if echo "$OUT_V2" | grep -q 'AKIAZZZZZZZZZZZZZZZZ'; then
  pass "second, different secret still reported"
else
  fail "second, different secret was NOT reported (got: $OUT_V2)"
fi

# Same line, two values: the allowed one is deleted before re-matching, so
# the other one still trips the pattern.
printf '%s\n' 'AKIAIOSFODNN7EXAMPLE and AKIAYYYYYYYYYYYYYYYY together' > "$VDIR/known.txt"
OUT_V3="$(cd "$VDIR" && bash "$SC" --allow "$VALLOW" . 2>&1)"
rc_v3=$?
assert_exit "value-scoped allow: second secret on the SAME line fails" "1" "$rc_v3"
if echo "$OUT_V3" | grep -q 'AKIAYYYYYYYYYYYYYYYY'; then
  pass "same-line second secret still reported"
else
  fail "same-line second secret was NOT reported (got: $OUT_V3)"
fi

# --- allow files are scanned, field by field -------------------------------
# Skipping an allow file wholesale would make it a laundering channel: park
# a credential in a comment and no scanner ever looks at it again. Only the
# third (match-regex) field of an ENTRY line is exempt.
AFDIR="$TMP/allowfile-scan/scripts"
mkdir -p "$AFDIR"
AFSCAN="$AFDIR/scrub-allow.txt"

# (a) the match-regex field may spell a denylisted value -> clean.
{
  printf '# a normal comment\n'
  printf 'secret-shape:^known\\.txt$:AKIAIOSFODNN7EXAMPLE\n'
} > "$AFSCAN"
OUT_AF1="$(cd "$TMP/allowfile-scan" && bash "$SC" --allow "$AFSCAN" . 2>&1)"
rc_af1=$?
assert_exit "allow file: match-regex field is exempt" "0" "$rc_af1"
if echo "$OUT_AF1" | grep -q 'secret-shape:'; then
  fail "match-regex field was flagged (got: $OUT_AF1)"
else
  pass "match-regex field not flagged"
fi

# (b) a secret in a COMMENT line of the allow file is still a hit.
{
  printf '# oops, pasted a key here: AKIAABCDEFGHIJKLMNOP\n'
  printf 'secret-shape:^known\\.txt$:AKIAIOSFODNN7EXAMPLE\n'
} > "$AFSCAN"
OUT_AF2="$(cd "$TMP/allowfile-scan" && bash "$SC" --allow "$AFSCAN" . 2>&1)"
rc_af2=$?
assert_exit "allow file: secret in a comment line" "1" "$rc_af2"
if echo "$OUT_AF2" | grep -q '^secret-shape: scripts/scrub-allow\.txt:1:'; then
  pass "secret in an allow-file comment reported"
else
  fail "secret in an allow-file comment NOT reported (got: $OUT_AF2)"
fi

# (c) a secret smuggled into the PATH field is still a hit.
printf '%s\n' 'secret-shape:^AKIAABCDEFGHIJKLMNOP\.txt$:zzz' > "$AFSCAN"
OUT_AF3="$(cd "$TMP/allowfile-scan" && bash "$SC" --allow "$AFSCAN" . 2>&1)"
rc_af3=$?
assert_exit "allow file: secret in the path field" "1" "$rc_af3"
if echo "$OUT_AF3" | grep -q '^secret-shape: scripts/scrub-allow\.txt:1:'; then
  pass "secret in an allow-file path field reported"
else
  fail "secret in an allow-file path field NOT reported (got: $OUT_AF3)"
fi

# (d) an entry with no third field is scanned in full.
printf '%s\n' 'secret-shape:^AKIAABCDEFGHIJKLMNOP\.txt$' > "$AFSCAN"
OUT_AF4="$(cd "$TMP/allowfile-scan" && bash "$SC" --allow "$AFSCAN" . 2>&1)"
rc_af4=$?
assert_exit "allow file: two-field entry scanned in full" "1" "$rc_af4"

# (e) an UNKNOWN pattern name earns no exemption — inventing a name is the
# cheapest way to manufacture a "third field".
printf '%s\n' 'unknown:unused:AKIAABCDEFGHIJKLMNOP' > "$AFSCAN"
OUT_AF9="$(cd "$TMP/allowfile-scan" && bash "$SC" --allow "$AFSCAN" . 2>&1)"
rc_af9=$?
assert_exit "allow file: unknown pattern name gets no exemption" "1" "$rc_af9"
if echo "$OUT_AF9" | grep -q '^secret-shape: scripts/scrub-allow\.txt:1:'; then
  pass "unknown-name entry scanned in full"
else
  fail "unknown-name entry was exempted (got: $OUT_AF9)"
fi

# (f) a real-shaped credential in the match-regex field is NOT a documented
# public example, so the whole line is scanned.
printf '%s\n' 'secret-shape:^x$:AKIAABCDEFGHIJKLMNOP' > "$AFSCAN"
OUT_AF10="$(cd "$TMP/allowfile-scan" && bash "$SC" --allow "$AFSCAN" . 2>&1)"
rc_af10=$?
assert_exit "allow file: non-example credential in the match-regex field" "1" "$rc_af10"
if echo "$OUT_AF10" | grep -q '^secret-shape: scripts/scrub-allow\.txt:1:'; then
  pass "laundered credential reported at the allow-file line"
else
  fail "laundered credential NOT reported (got: $OUT_AF10)"
fi

# ...while the documented public examples still pass.
{
  printf 'secret-shape:^x$:AKIAIOSFODNN7EXAMPLE\n'
  printf 'secret-shape:^x$:AKIAIOSFODNN7SECRETV\n'
  printf 'secret-shape:^x$:-+BEGIN [A-Z ]+PRIVATE KEY-+\n'
} > "$AFSCAN"
OUT_AF11="$(cd "$TMP/allowfile-scan" && bash "$SC" --allow "$AFSCAN" . 2>&1)"
rc_af11=$?
assert_exit "allow file: documented public examples still exempt" "0" "$rc_af11"

# (g) an EMPTY third field exempts nothing AND allows nothing: the hit in
# the target file still stands.
mkdir -p "$TMP/allowfile-scan/x-dir"
printf '%s\n' 'AKIAEMPTYFIELDTEST01' > "$TMP/allowfile-scan/x.txt"
printf '%s\n' 'secret-shape:^x\\.txt$:' > "$AFSCAN"
OUT_AF12="$(cd "$TMP/allowfile-scan" && bash "$SC" --allow "$AFSCAN" . 2>&1)"
rc_af12=$?
assert_exit "allow file: empty third field allows nothing" "1" "$rc_af12"
if echo "$OUT_AF12" | grep -q '^secret-shape: x\.txt:1:'; then
  pass "empty third field did not suppress the target hit"
else
  fail "empty third field suppressed the target hit (got: $OUT_AF12)"
fi
OUT_AF13="$(cd "$TMP/allowfile-scan" && bash "$SC" --allow "$AFSCAN" --check-allowlist . 2>&1)"
if echo "$OUT_AF13" | grep -q '^unscoped-allow: .*secret-shape:'; then
  pass "empty third field also reported as unscoped-allow"
else
  fail "empty third field NOT reported as unscoped-allow (got: $OUT_AF13)"
fi
rm -f "$TMP/allowfile-scan/x.txt"

# --- --check-allowlist: credential classes must be value-scoped ------------
UNSDIR="$TMP/unscoped"
mkdir -p "$UNSDIR"
printf '%s\n' 'AKIAABCDEFGHIJKLMNOP' > "$UNSDIR/f.txt"
printf '%s\n' '/home/bob/x' > "$UNSDIR/h.txt"
UNSALLOW="$TMP/unscoped-allow.txt"
{
  printf 'secret-shape:^f\\.txt$\n'
  printf 'home-path:^h\\.txt$\n'
} > "$UNSALLOW"
OUT_US="$(cd "$UNSDIR" && bash "$SC" --allow "$UNSALLOW" --check-allowlist . 2>&1)"
rc_us=$?
assert_exit "--check-allowlist rejects an unscoped credential exception" "1" "$rc_us"
for cls in secret-shape home-path; do
  if echo "$OUT_US" | grep -q "^unscoped-allow: .*: ${cls}:"; then
    pass "unscoped-allow reported for $cls"
  else
    fail "unscoped-allow NOT reported for $cls (got: $OUT_US)"
  fi
done

{
  printf 'secret-shape:^f\\.txt$:AKIAABCDEFGHIJKLMNOP\n'
  printf 'home-path:^h\\.txt$:/home/bob/\n'
} > "$UNSALLOW"
OUT_US2="$(cd "$UNSDIR" && bash "$SC" --allow "$UNSALLOW" --check-allowlist . 2>&1)"
rc_us2=$?
assert_exit "--check-allowlist accepts the value-scoped form" "0" "$rc_us2"

# --- --require-private with an EMPTY private denylist ----------------------
# The file exists, so the "is it there?" test passes while nothing at all is
# enforced. That is precisely the false assurance --require-private exists
# to prevent, so it must fail.
EMPTYPRIV="$TMP/empty-denylist.txt"
printf '# only comments, no entries\n\n' > "$EMPTYPRIV"
OUT_EP="$(SCRUB_DENYLIST="$EMPTYPRIV" bash "$SC" --require-private "$GENDIR" 2>&1)"
rc_ep=$?
assert_exit "--require-private with an entry-less private denylist" "2" "$rc_ep"
if echo "$OUT_EP" | grep -q 'has no entries'; then
  pass "entry-less private denylist reported"
else
  fail "entry-less private denylist not reported (got: $OUT_EP)"
fi
OUT_EP2="$(SCRUB_DENYLIST="$EMPTYPRIV" bash "$SC" "$GENDIR" 2>&1)"
rc_ep2=$?
assert_exit "entry-less private denylist without --require-private warns only" "1" "$rc_ep2"

# --- --check-allowlist: dead exceptions must not accumulate ---------------
DEADDIR="$TMP/dead-allow"
mkdir -p "$DEADDIR"
printf '%s\n' '/mnt/tsclient/share' > "$DEADDIR/live.txt"
DEADALLOW="$TMP/dead-allow.txt"
{
  printf '# a live entry and a dead one\n'
  printf 'rdp-share:^live\\.txt$\n'
  printf 'rdp-share:^gone-long-ago\\.txt$\n'
} > "$DEADALLOW"

OUT_CA="$(cd "$DEADDIR" && bash "$SC" --allow "$DEADALLOW" --check-allowlist . 2>&1)"
rc_ca=$?
assert_exit "--check-allowlist flags a dead entry" "1" "$rc_ca"
if echo "$OUT_CA" | grep -q 'unused-allow:.*gone-long-ago'; then
  pass "dead allow entry reported"
else
  fail "dead allow entry not reported (got: $OUT_CA)"
fi
if echo "$OUT_CA" | grep -q 'unused-allow:.*live\\\?\.txt'; then
  fail "live allow entry wrongly reported as unused (got: $OUT_CA)"
else
  pass "live allow entry not reported as unused"
fi

printf '%s\n' 'rdp-share:^live\.txt$' > "$DEADALLOW"
OUT_CA2="$(cd "$DEADDIR" && bash "$SC" --allow "$DEADALLOW" --check-allowlist . 2>&1)"
rc_ca2=$?
assert_exit "--check-allowlist clean when every entry is used" "0" "$rc_ca2"

# --- Missing target -> exit 2. --------------------------------------------
OUT2="$(bash "$SC" "$TMP/does-not-exist-xyz" 2>&1)"
rc2=$?
assert_exit "missing target" "2" "$rc2"
if echo "$OUT2" | grep -q 'missing target'; then
  pass "missing target message present"
else
  fail "missing target message missing (got: $OUT2)"
fi

# Space-in-path case.
SPACEDIR="$TMP/dir with space"
mkdir -p "$SPACEDIR"
printf '%s\n' '/home/carol/notes' > "$SPACEDIR/f.txt"
OUT3="$(bash "$SC" "$SPACEDIR/f.txt" 2>&1)"
rc3=$?
assert_exit "space-in-path hit" "1" "$rc3"
if echo "$OUT3" | grep -q "^home-path: $SPACEDIR/f.txt:1:"; then
  pass "space-in-path file path reported intact"
else
  fail "space-in-path file path mangled (got: $OUT3)"
fi

# Dangling-link case: nothing else hits, so expect exit 4.
PLUGDIR="$TMP/plugin"
mkdir -p "$PLUGDIR/.claude-plugin" "$PLUGDIR/skills/real-skill"
printf '%s\n' '{"name":"fixture-plugin"}' > "$PLUGDIR/.claude-plugin/plugin.json"
printf '%s\n' 'See [[real-skill]] and [[missing-skill]] here.' > "$PLUGDIR/doc.md"
OUT4="$(bash "$SC" "$PLUGDIR" 2>&1)"
rc4=$?
assert_exit "dangling-link only" "4" "$rc4"
if echo "$OUT4" | grep -q 'dangling-link:.*missing-skill'; then
  pass "dangling-link reported for unresolved name"
else
  fail "dangling-link not reported (got: $OUT4)"
fi
if echo "$OUT4" | grep -q 'real-skill.*does not resolve'; then
  fail "resolved link real-skill incorrectly flagged as dangling"
else
  pass "resolved link real-skill not flagged"
fi

# --- path-normalization cases: the same allowlist entry, written
# repo-relative with no leading "./", must suppress the hit regardless of
# how the target path was spelled on the command line — ".", "./sub",
# "sub", or an absolute path all report the same underlying file with a
# different raw prefix, and normalize_path must fold them to the same form
# before is_allowed ever sees them.
PNORM_ROOT="$TMP/pnorm-root"
mkdir -p "$PNORM_ROOT/pnorm"
printf '%s\n' '/home/dave/notes' > "$PNORM_ROOT/pnorm/hit.txt"
PNORM_ALLOW="$PNORM_ROOT/allow.txt"
printf '%s\n' 'home-path:^pnorm/hit\.txt$' > "$PNORM_ALLOW"

OUT_DOT="$(cd "$PNORM_ROOT" && bash "$SC" --allow "$PNORM_ALLOW" . 2>&1)"
rc_dot=$?
assert_exit "path-norm: target '.'" "0" "$rc_dot"
if echo "$OUT_DOT" | grep -q 'home-path:'; then
  fail "path-norm target '.': allowlisted hit still reported (got: $OUT_DOT)"
else
  pass "path-norm target '.': allowlisted hit suppressed"
fi

OUT_DOTSUB="$(cd "$PNORM_ROOT" && bash "$SC" --allow "$PNORM_ALLOW" ./pnorm 2>&1)"
rc_dotsub=$?
assert_exit "path-norm: target './pnorm'" "0" "$rc_dotsub"
if echo "$OUT_DOTSUB" | grep -q 'home-path:'; then
  fail "path-norm target './pnorm': allowlisted hit still reported (got: $OUT_DOTSUB)"
else
  pass "path-norm target './pnorm': allowlisted hit suppressed"
fi

OUT_SUB="$(cd "$PNORM_ROOT" && bash "$SC" --allow "$PNORM_ALLOW" pnorm 2>&1)"
rc_sub=$?
assert_exit "path-norm: target 'sub'" "0" "$rc_sub"
if echo "$OUT_SUB" | grep -q 'home-path:'; then
  fail "path-norm target 'sub': allowlisted hit still reported (got: $OUT_SUB)"
else
  pass "path-norm target 'sub': allowlisted hit suppressed"
fi

OUT_ABS="$(cd "$PNORM_ROOT" && bash "$SC" --allow "$PNORM_ALLOW" "$PNORM_ROOT/pnorm" 2>&1)"
rc_abs=$?
assert_exit "path-norm: absolute target" "0" "$rc_abs"
if echo "$OUT_ABS" | grep -q 'home-path:'; then
  fail "path-norm absolute target: allowlisted hit still reported (got: $OUT_ABS)"
else
  pass "path-norm absolute target: allowlisted hit suppressed"
fi

# Sanity: the same fixture WITHOUT the allowlist still gets caught (proves
# the four cases above are suppressed by the allowlist, not by some
# unrelated breakage).
OUT_NOALLOW="$(cd "$PNORM_ROOT" && bash "$SC" . 2>&1)"
rc_noallow=$?
assert_exit "path-norm sanity: no allowlist still hits" "1" "$rc_noallow"
if echo "$OUT_NOALLOW" | grep -q '^home-path: pnorm/hit\.txt:'; then
  pass "path-norm sanity: hit reported with normalized (no ./) path"
else
  fail "path-norm sanity: hit path not normalized (got: $OUT_NOALLOW)"
fi

# --- allow files: field-level exemption, discovered by default name -------
# The exemption is scoped to the match-regex FIELD, not to the file: a
# default-named allow file discovered under a scanned root gets the same
# treatment as one passed with --allow, and a comment in either is scanned.
AF2DIR="$TMP/allow-file-fields"
mkdir -p "$AF2DIR/scripts"
{
  printf '# allow file documents its own exceptions, e.g.\n'
  printf 'home-path:^scripts/scrub-allow\\.txt$:/home/eve/box\n'
} > "$AF2DIR/scripts/scrub-allow.txt"

OUT_AF5="$(cd "$AF2DIR" && bash "$SC" --require-private --allow scripts/scrub-allow.txt . 2>&1)"
rc_af5=$?
assert_exit "allow file: documented value in the match-regex field" "0" "$rc_af5"
if echo "$OUT_AF5" | grep -q '^home-path:.*scrub-allow\.txt'; then
  fail "allow file flagged for the value in its match-regex field (got: $OUT_AF5)"
else
  pass "allow file not flagged for the value it documents"
fi
if echo "$OUT_AF5" | grep -q 'skipping allow file'; then
  fail "allow file was SKIPPED wholesale — it must be scanned field by field (got: $OUT_AF5)"
else
  pass "allow file not skipped wholesale"
fi

# The same value in a plain (non-allow) file must still be caught: the
# exemption is scoped to one field of one file, never to the value.
printf '%s\n' 'a note about /home/eve/box' > "$AF2DIR/plain.txt"
OUT_AF6="$(cd "$AF2DIR" && bash "$SC" --require-private --allow scripts/scrub-allow.txt . 2>&1)"
rc_af6=$?
assert_exit "allow file: same value in a non-allow file" "1" "$rc_af6"
if echo "$OUT_AF6" | grep -q '^home-path: plain\.txt:'; then
  pass "non-allow file with the same value still caught"
else
  fail "non-allow file with the same value NOT caught (got: $OUT_AF6)"
fi
rm -f "$AF2DIR/plain.txt"

# scripts/scrub-allow-history.txt is NOT an allow file. It used to be
# registered by fixed name, which exempted its third fields — but NO
# scanner ever reads that path (scrub-history.sh loads the history
# allowlist from the PRIVATE $SCRUB_ALLOW_HISTORY), so the exemption
# excused values nothing consumed: follow the documented name, park real
# identity values in it, and `git add -A` commits what this scan just
# agreed not to look at. It is ordinary content now. Reuses the synthetic
# "employer" class (acmecorp) loaded via $SCRUB_DENYLIST at the top.
printf '%s\n' 'employer:^scripts/scrub-allow-history\\.txt$:acmecorp' \
  > "$AF2DIR/scripts/scrub-allow-history.txt"
OUT_AF7="$(cd "$AF2DIR" && bash "$SC" --require-private --allow scripts/scrub-allow.txt . 2>&1)"
rc_af7=$?
assert_exit "scrub-allow-history.txt in-tree gets NO field exemption" "1" "$rc_af7"
if echo "$OUT_AF7" | grep -q '^employer: scripts/scrub-allow-history\.txt:1:'; then
  pass "in-tree scrub-allow-history.txt scanned like any other file"
else
  fail "in-tree scrub-allow-history.txt still exempted (got: $OUT_AF7)"
fi

printf '%s\n' '# note: acmecorp' >> "$AF2DIR/scripts/scrub-allow-history.txt"
OUT_AF8="$(cd "$AF2DIR" && bash "$SC" --require-private --allow scripts/scrub-allow.txt . 2>&1)"
rc_af8=$?
assert_exit "in-tree scrub-allow-history.txt: comment line is scanned too" "1" "$rc_af8"
if echo "$OUT_AF8" | grep -q '^employer: scripts/scrub-allow-history\.txt:2:'; then
  pass "comment in an in-tree scrub-allow-history.txt reported"
else
  fail "comment in an in-tree scrub-allow-history.txt NOT reported (got: $OUT_AF8)"
fi
rm -f "$AF2DIR/scripts/scrub-allow-history.txt"

# --- cross-pattern laundering via the third field --------------------------
# The field exemption is bound to the pattern being SCANNED, not to "some
# loaded pattern". An entry named for pattern X must not excuse its third
# field during a scan for pattern Y — otherwise any value can be parked in
# a plausible-looking exception of an unrelated class and never reported.
XPDIR="$TMP/cross-pattern"
mkdir -p "$XPDIR/scripts"
printf '%s\n' 'uuid:^fixture\\.txt$:acmecorp' > "$XPDIR/scripts/scrub-allow.txt"
OUT_XP1="$(cd "$XPDIR" && bash "$SC" --require-private --allow scripts/scrub-allow.txt . 2>&1)"
rc_xp1=$?
assert_exit "cross-pattern: uuid entry does not excuse an employer value" "1" "$rc_xp1"
if echo "$OUT_XP1" | grep -q '^employer: scripts/scrub-allow\.txt:1:'; then
  pass "value laundered under another class's name reported"
else
  fail "value laundered under another class's name NOT reported (got: $OUT_XP1)"
fi

# ...while the honest form — an entry named for the class its third field
# actually spells out — still works.
printf '%s\n' 'employer:^fixture\\.txt$:acmecorp' > "$XPDIR/scripts/scrub-allow.txt"
OUT_XP2="$(cd "$XPDIR" && bash "$SC" --require-private --allow scripts/scrub-allow.txt . 2>&1)"
rc_xp2=$?
assert_exit "cross-pattern: an entry named for its own class is still exempt" "0" "$rc_xp2"

# --- --check-allowlist: wildcard third fields ------------------------------
# A third field that matches anything ("[A-Z0-9]+", ".*") is deleted from
# the line before the re-scan, so EVERY secret on it disappears — the blunt
# instrument unscoped-allow rejects, wearing the value-scoped syntax. The
# canary test is what tells them apart: a freshly generated value of the
# entry's own class, which a tight third field cannot touch.
WILDDIR="$TMP/wildcard-allow"
mkdir -p "$WILDDIR"
printf '%s\n' 'AKIAABCDEFGHIJKLMNOP' > "$WILDDIR/k.txt"
printf '%s\n' '/home/bob/notes' > "$WILDDIR/h.txt"
WILDALLOW="$TMP/wildcard-allow.txt"

printf '%s\n' 'secret-shape:^k\\.txt$:.*' > "$WILDALLOW"
OUT_W1="$(cd "$WILDDIR" && bash "$SC" --allow "$WILDALLOW" --check-allowlist . 2>&1)"
rc_w1=$?
assert_exit "--check-allowlist rejects a '.*' third field" "1" "$rc_w1"
if echo "$OUT_W1" | grep -q '^wildcard-allow: .*secret-shape:'; then
  pass "'.*' third field reported as wildcard-allow"
else
  fail "'.*' third field NOT reported as wildcard-allow (got: $OUT_W1)"
fi

printf '%s\n' 'secret-shape:^k\\.txt$:[A-Z0-9]+' > "$WILDALLOW"
OUT_W2="$(cd "$WILDDIR" && bash "$SC" --allow "$WILDALLOW" --check-allowlist . 2>&1)"
rc_w2=$?
assert_exit "--check-allowlist rejects a '[A-Z0-9]+' third field" "1" "$rc_w2"
if echo "$OUT_W2" | grep -q '^wildcard-allow: .*secret-shape:'; then
  pass "character-class third field reported as wildcard-allow"
else
  fail "character-class third field NOT reported as wildcard-allow (got: $OUT_W2)"
fi

printf '%s\n' 'home-path:^h\\.txt$:/home/[a-z]+/' > "$WILDALLOW"
OUT_W3="$(cd "$WILDDIR" && bash "$SC" --allow "$WILDALLOW" --check-allowlist . 2>&1)"
rc_w3=$?
assert_exit "--check-allowlist rejects a wildcarded home-path third field" "1" "$rc_w3"
if echo "$OUT_W3" | grep -q '^wildcard-allow: .*home-path:'; then
  pass "wildcarded home-path third field reported as wildcard-allow"
else
  fail "wildcarded home-path third field NOT reported as wildcard-allow (got: $OUT_W3)"
fi

# The legitimate form — an exact value — must keep working, in both classes.
{
  printf 'secret-shape:^k\\.txt$:AKIAABCDEFGHIJKLMNOP\n'
  printf 'home-path:^h\\.txt$:/home/bob/\n'
} > "$WILDALLOW"
OUT_W4="$(cd "$WILDDIR" && bash "$SC" --allow "$WILDALLOW" --check-allowlist . 2>&1)"
rc_w4=$?
assert_exit "--check-allowlist accepts exact-value third fields" "0" "$rc_w4"
if echo "$OUT_W4" | grep -q 'wildcard-allow'; then
  fail "an exact-value third field was called over-broad (got: $OUT_W4)"
else
  pass "exact-value third fields not flagged"
fi

# --- --check-allowlist: both lints fire together, unchanged -----------------
# --check-overbroad below must not have turned --check-allowlist into a
# thinner synonym: a single allow file with one dead entry and one
# over-broad entry must still report BOTH, exactly as before.
BOTHDIR="$TMP/check-allowlist-both"
mkdir -p "$BOTHDIR"
printf '%s\n' 'AKIAABCDEFGHIJKLMNOP' > "$BOTHDIR/k.txt"
BOTHALLOW="$TMP/check-allowlist-both.txt"
{
  printf 'secret-shape:^k\\.txt$:.*\n'
  printf 'secret-shape:^gone\\.txt$:NEVERMATCHESANYTHING1234\n'
} > "$BOTHALLOW"
OUT_BOTH="$(cd "$BOTHDIR" && bash "$SC" --allow "$BOTHALLOW" --check-allowlist . 2>&1)"
rc_both=$?
assert_exit "--check-allowlist still fails when both lints fire" "1" "$rc_both"
if echo "$OUT_BOTH" | grep -q '^wildcard-allow: .*secret-shape:'; then
  pass "--check-allowlist still reports wildcard-allow alongside unused-allow"
else
  fail "--check-allowlist wildcard-allow report missing (got: $OUT_BOTH)"
fi
if echo "$OUT_BOTH" | grep -q '^unused-allow: .*gone\\.txt'; then
  pass "--check-allowlist still reports unused-allow alongside wildcard-allow"
else
  fail "--check-allowlist unused-allow report missing (got: $OUT_BOTH)"
fi

# --- --check-overbroad: the canary lint alone, no private denylist needed --
# This is the fix's whole point: --check-allowlist only runs in the CI step
# guarded by the private-denylist secret, which is unavailable (and the
# step SKIPPED) on fork PRs — exactly the untrusted path an over-broad
# entry like `secret-shape:^README[.]md$:.*` needs to be caught on. Every
# invocation below explicitly points SCRUB_DENYLIST at a path that does not
# exist, overriding the synthetic private denylist exported at the top of
# this file, to prove the lint needs no private denylist at all.
OVERDIR="$TMP/check-overbroad"
mkdir -p "$OVERDIR"
printf '%s\n' 'AKIAABCDEFGHIJKLMNOP' > "$OVERDIR/k.txt"
OVERALLOW="$TMP/check-overbroad.txt"
NOPRIV="$TMP/no-such-private-denylist.txt"

printf 'secret-shape:^k\\.txt$:.*\n' > "$OVERALLOW"
OUT_O1="$(cd "$OVERDIR" && SCRUB_DENYLIST="$NOPRIV" bash "$SC" --allow "$OVERALLOW" --check-overbroad . 2>&1)"
rc_o1=$?
assert_exit "--check-overbroad rejects a '.*' third field with no private denylist" "1" "$rc_o1"
if echo "$OUT_O1" | grep -q '^wildcard-allow: .*secret-shape:'; then
  pass "--check-overbroad reports '.*' as wildcard-allow"
else
  fail "--check-overbroad did NOT report '.*' as wildcard-allow (got: $OUT_O1)"
fi

printf 'secret-shape:^k\\.txt$:[A-Z0-9]+\n' > "$OVERALLOW"
OUT_O2="$(cd "$OVERDIR" && SCRUB_DENYLIST="$NOPRIV" bash "$SC" --allow "$OVERALLOW" --check-overbroad . 2>&1)"
rc_o2=$?
assert_exit "--check-overbroad rejects a '[A-Z0-9]+' third field with no private denylist" "1" "$rc_o2"
if echo "$OUT_O2" | grep -q '^wildcard-allow: .*secret-shape:'; then
  pass "--check-overbroad reports '[A-Z0-9]+' as wildcard-allow"
else
  fail "--check-overbroad did NOT report '[A-Z0-9]+' as wildcard-allow (got: $OUT_O2)"
fi

# The allow file itself must live outside the scanned tree for the exact
# value below to actually suppress the raw hit (mirrors the wildcard-allow
# fixtures above), so --check-overbroad can legitimately exit 0.
printf 'secret-shape:^k\\.txt$:AKIAABCDEFGHIJKLMNOP\n' > "$OVERALLOW"
OUT_O3="$(cd "$OVERDIR" && SCRUB_DENYLIST="$NOPRIV" bash "$SC" --allow "$OVERALLOW" --check-overbroad . 2>&1)"
rc_o3=$?
assert_exit "--check-overbroad accepts an exact-value third field with no private denylist" "0" "$rc_o3"
if echo "$OUT_O3" | grep -q 'wildcard-allow'; then
  fail "--check-overbroad called an exact-value third field over-broad (got: $OUT_O3)"
else
  pass "--check-overbroad: exact-value third field not flagged"
fi

# --check-overbroad must not also run unused-allow: a dead entry alone
# (nothing over-broad, no live hit to suppress or miss) must still pass.
# Scanned in a clean directory — OVERDIR always carries a real secret, and
# an unrelated dead entry would not suppress it, conflating the two lints.
CLEANDIR="$TMP/check-overbroad-clean"
mkdir -p "$CLEANDIR"
printf '%s\n' 'nothing interesting here' > "$CLEANDIR/f.txt"
printf 'secret-shape:^gone\\.txt$:NEVERMATCHESANYTHING1234\n' > "$OVERALLOW"
OUT_O4="$(cd "$CLEANDIR" && SCRUB_DENYLIST="$NOPRIV" bash "$SC" --allow "$OVERALLOW" --check-overbroad . 2>&1)"
rc_o4=$?
assert_exit "--check-overbroad ignores a dead (unused) entry" "0" "$rc_o4"
if echo "$OUT_O4" | grep -q 'unused-allow'; then
  fail "--check-overbroad reported unused-allow, which is --check-allowlist's job (got: $OUT_O4)"
else
  pass "--check-overbroad does not report unused-allow"
fi

# --- canaries are derived from the pattern's own regex ---------------------
# The canary set used to be one hand-written value per class, so a third
# field narrowed to any OTHER shape the class matches sailed through:
# `gh[pousr]_[A-Za-z0-9]{20,}` exempts every GitHub token in the scoped
# file, yet never touches an AKIA-shaped canary. Every alternative of the
# class regex now gets its own canaries, in each character flavour and both
# cases, so narrowing by shape or by case is no longer an escape.
#
# Credential-shaped literals below are ASSEMBLED at run time ("gh"'p_'...):
# spelled out, they would be real hits in this file, and scrub-allow.txt
# scopes its exception for this path to the AKIA values only.
CANDIR="$TMP/canary-shapes"
mkdir -p "$CANDIR"
printf '%s\n' 'nothing interesting here' > "$CANDIR/f.txt"
CANALLOW="$TMP/canary-allow.txt"

# One --check-overbroad verdict on a single allow entry: the scanned tree is
# clean and the allow file lives outside it, so the only thing that can be
# reported is the canary lint. No private denylist, as above.
check_overbroad_entry() {
  printf '%s\n' "$1" > "$CANALLOW"
  ( cd "$CANDIR" && SCRUB_DENYLIST="$NOPRIV" bash "$SC" --allow "$CANALLOW" --check-overbroad . 2>&1 )
}
assert_overbroad() {
  co_out="$(check_overbroad_entry "$2")"
  if echo "$co_out" | grep -q '^wildcard-allow: '; then
    pass "$1"
  else
    fail "$1 (got: ${co_out:-<no output>})"
  fi
}
assert_not_overbroad() {
  co_out="$(check_overbroad_entry "$2")"
  co_rc=$?
  if echo "$co_out" | grep -q 'wildcard-allow'; then
    fail "$1 (got: $co_out)"
  elif [ "$co_rc" -ne 0 ]; then
    fail "$1 (expected exit 0, got $co_rc: $co_out)"
  else
    pass "$1"
  fi
}

# THE REPORTED BYPASS: narrowed to the GitHub-token alternative.
assert_overbroad "canary: GitHub-token-shaped third field is over-broad" \
  'secret-shape:^f\.txt$:gh[pousr]_[A-Za-z0-9]{20,}'
# ...and narrowed further still, to one prefix letter, or to one case.
assert_overbroad "canary: single-prefix GitHub-token third field is over-broad" \
  'secret-shape:^f\.txt$:ghp_[A-Za-z0-9]{20,}'
assert_overbroad "canary: lower-case-only GitHub-token third field is over-broad" \
  'secret-shape:^f\.txt$:gh[pousr]_[a-z0-9]{20,}'

# One per remaining secret-shape alternative: each is a whole credential
# shape the class matches, so a third field scoped to nothing narrower than
# the shape excuses every value of it.
assert_overbroad "canary: fine-grained PAT alternative" \
  'secret-shape:^f\.txt$:github_pat_[A-Za-z0-9_]{20,}'
assert_overbroad "canary: AWS key alternative" \
  'secret-shape:^f\.txt$:AKIA[0-9A-Z]{16}'
assert_overbroad "canary: Slack token alternative" \
  'secret-shape:^f\.txt$:xox[abprs]-'
assert_overbroad "canary: single-prefix Slack token alternative" \
  "secret-shape:^f\.txt\$:xox"'b-'
assert_overbroad "canary: PEM private-key header alternative" \
  'secret-shape:^f\.txt$:BEGIN [A-Z ]*PRIVATE KEY'
assert_overbroad "canary: Dynatrace token alternative" \
  'secret-shape:^f\.txt$:dt0[cs]01\.[A-Z0-9]{24}'

# uuid is matched case-insensitively, so an upper-case-only regex exempts
# every upper-case UUID in the file while dodging a lower-case canary.
assert_overbroad "canary: upper-case-only uuid third field is over-broad" \
  'uuid:^f\.txt$:[0-9A-F-]{36}'
assert_overbroad "canary: lower-case-only uuid third field is over-broad" \
  'uuid:^f\.txt$:[0-9a-f-]{36}'

# Both halves of home-path, and the blunt wildcards, unchanged.
assert_overbroad "canary: wildcarded /home/ third field is over-broad" \
  'home-path:^f\.txt$:/home/[a-z]+/'
assert_overbroad "canary: wildcarded /Users/ third field is over-broad" \
  'home-path:^f\.txt$:/Users/[a-z]+/'
assert_overbroad "canary: '.*' third field is over-broad" \
  'secret-shape:^f\.txt$:.*'
assert_overbroad "canary: '[A-Z0-9]+' third field is over-broad" \
  'secret-shape:^f\.txt$:[A-Z0-9]+'

# The compliant form — a third field pinned to the literal it means — must
# stay accepted for every shape, or the lint is unusable.
LIT_GH="gh"'p_'"ABCDEFGHIJKLMNOP1234"
LIT_PAT="github"'_pat_'"ABCDEFGHIJKLMNOP1234"
LIT_SLACK="xox"'b-'"1234567890-ABCDEF"
LIT_DT="dt0"'c01.'"ABCDEFGHIJKLMNOPQRSTUVWX"
assert_not_overbroad "canary: exact AWS key literal accepted" \
  'secret-shape:^f\.txt$:AKIAIOSFODNN7EXAMPLE'
assert_not_overbroad "canary: exact GitHub token literal accepted" \
  "secret-shape:^f\.txt\$:$LIT_GH"
assert_not_overbroad "canary: exact fine-grained PAT literal accepted" \
  "secret-shape:^f\.txt\$:$LIT_PAT"
assert_not_overbroad "canary: exact Slack token literal accepted" \
  "secret-shape:^f\.txt\$:$LIT_SLACK"
assert_not_overbroad "canary: exact Dynatrace token literal accepted" \
  "secret-shape:^f\.txt\$:$LIT_DT"
# scrub-allow.txt's own PEM entry: a header with the surrounding dashes.
assert_not_overbroad "canary: dash-anchored PEM header literal accepted" \
  'secret-shape:^f\.txt$:-+BEGIN [A-Z ]+PRIVATE KEY-+'
assert_not_overbroad "canary: exact /home/ literal accepted" \
  'home-path:^f\.txt$:/home/bob/'
assert_not_overbroad "canary: exact /Users/ literal accepted" \
  "home-path:^f\.txt\$:/Users/"'runner/'
assert_not_overbroad "canary: exact uuid literal accepted" \
  'uuid:^f\.txt$:123e4567-e89b-12d3-a456-426614174000'

# A class with no canary must report NOTHING: rdp-share's regex is fixed
# literals end to end, so every third field that suppresses anything at all
# is exactly as broad as the class and there is no compliant form to demand.
# "No canary" has to keep meaning "not over-broad" — the lint never invents
# a finding it cannot substantiate.
OUT_NOCAN="$(check_overbroad_entry 'rdp-share:^f\.txt$:/mnt/tsclient')"
rc_nocan=$?
assert_exit "canary: canary-less class reports nothing" "0" "$rc_nocan"
# ...beyond the "no private denylist" warning every invocation here emits.
NOCAN_REST="$(printf '%s' "$OUT_NOCAN" | grep -v '^scrub: ' || true)"
if [ -n "$NOCAN_REST" ]; then
  fail "canary-less class produced a finding (got: $NOCAN_REST)"
else
  pass "canary-less class produced no finding"
fi

# --- REGRESSION: private classes get no derived canary, ever ---------------
# Public classes are canaried per alternative (above); a PRIVATE
# (runtime-loaded) class must not be, or the lint invents a finding its own
# author cannot satisfy. Reproduced with a small bracket-enumeration
# private class — a synthetic vendor name spelled with a leading-letter
# case choice — whose only compliant allow entry IS the exact literal the
# class means: there is no narrower form to demand.
PRIVCAN="$TMP/priv-canary-denylist.txt"
printf 'vendor-name\t-\t[Vv]endorco\n' > "$PRIVCAN"
VENDIR="$TMP/priv-canary"
mkdir -p "$VENDIR"
printf '%s\n' 'nothing interesting here' > "$VENDIR/f.txt"
VENALLOW="$TMP/priv-canary-allow.txt"
printf 'vendor-name:^f\\.txt$:Vendorco\n' > "$VENALLOW"
OUT_PC="$(cd "$VENDIR" && SCRUB_DENYLIST="$PRIVCAN" bash "$SC" --allow "$VENALLOW" --check-overbroad . 2>&1)"
rc_pc=$?
assert_exit "private class: exact-literal third field accepted" "0" "$rc_pc"
if echo "$OUT_PC" | grep -q 'wildcard-allow'; then
  fail "private class exact-literal third field wrongly reported wildcard-allow (got: $OUT_PC)"
else
  pass "private class exact-literal third field not flagged wildcard-allow"
fi

# --- the private denylist inside a scanned target is an ERROR --------------
# It is nothing but denylisted values, so finding it staged is the worst
# thing this scanner can discover. It used to warn, exclude the file, and
# exit 0 — a green run that had just been told the repository was about to
# publish the denylist itself.
INTREE="$TMP/in-tree-denylist"
mkdir -p "$INTREE"
printf '%s\n' 'nothing interesting here' > "$INTREE/f.txt"
INPRIV="$INTREE/scrub-denylist.txt"
printf 'employer\ti\t\\<acme\\>\n' > "$INPRIV"
OUT_IT="$(SCRUB_DENYLIST="$INPRIV" bash "$SC" "$INTREE" 2>&1)"
rc_it=$?
assert_exit "private denylist inside a scanned target" "2" "$rc_it"
if echo "$OUT_IT" | grep -q 'inside the scanned tree'; then
  pass "in-tree private denylist reported"
else
  fail "in-tree private denylist not reported (got: $OUT_IT)"
fi
# The same denylist, with the target narrowed so the denylist is no longer
# INSIDE it, scans normally — the error is about containment, not about the
# denylist existing at that path.
OUT_IT2="$(SCRUB_DENYLIST="$INPRIV" bash "$SC" "$INTREE/f.txt" 2>&1)"
rc_it2=$?
assert_exit "private denylist outside the scanned target still scans" "0" "$rc_it2"

if [ "$FAILED" -ne 0 ]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All tests PASSED"
exit 0
