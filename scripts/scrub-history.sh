#!/usr/bin/env bash
# scrub-history.sh — release-time denylist scan over git HISTORY (every ref,
# every diff line), not just the working tree. scrub-check.sh only sees
# what's checked out now; a secret or internal name that was committed and
# later deleted is still sitting in the history that ships when this repo
# is made/kept public. Run this before a release, not on every commit.
#
# Usage: scrub-history.sh [--allow <file>] [--require-private] [path...]
#
# --allow defaults to the concatenation of scripts/scrub-allow.txt (the same
# allowlist scrub-check.sh uses) and the PRIVATE history-only allowlist at
# $SCRUB_ALLOW_HISTORY, default
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/scrub-allow-history.txt
# — entries for content that exists only in already-published commits, not
# in the working tree. That second file is private because excusing such
# content means naming it, and naming it in a committed file re-publishes
# it. Pass --allow <file> to override the default set, loading only that
# file (including --allow /dev/null to run with no allowlist at all).
#
# Patterns come from scripts/scrub-patterns.sh: the GENERIC classes it
# commits plus the PRIVATE denylist at $SCRUB_DENYLIST (default
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/scrub-denylist.txt).
# Without the private file only the generic classes run and a warning is
# printed; --require-private makes a missing private file exit 2. A release
# pass should always use --require-private.
#
# Must be run from inside the git repository being scanned (paths are
# resolved as git pathspecs, which git refuses outside the repo's own
# worktree). With no paths, scans the full history of the whole repo. With
# paths, restricts to commits touching those paths (via
# `git log -- <path>...`), same as `git log` itself would.
#
# Exit codes:
#   0 = clean
#   1 = one or more denylist hits
#   2 = usage error, temp-directory failure, git error, or a
#       missing/malformed private denylist under --require-private
#   4 = SOFT warning only: no denylist hits, but one or more blobs could
#       not be text-scanned (binary / UTF-16 / any blob with a NUL byte in
#       its first 512 bytes). Reported as
#         unscanned-binary: <path> (commit <short-sha>)
#       so a release pass can inspect them by hand. Exit 1 wins over 4.
#
# WHAT THIS SCAN CANNOT SEE — read before trusting a clean result:
#   * Content inside binary or UTF-16 blobs. `git log -p` prints
#     "Binary files ... differ" instead of the content, so a secret inside
#     a .zip, .png, a UTF-16 .txt or any NUL-containing blob is invisible
#     to grep. Those blobs are enumerated and reported as
#     unscanned-binary (exit 4) rather than silently passing; grep them
#     yourself with `git cat-file -p <blob>` piped through `iconv`/`strings`.
#   * Objects that are unreachable from any ref (dangling commits left by
#     an amend/rebase/reset, and anything in the reflog only). `--all`
#     walks refs, not the whole object database. A `git gc` will usually
#     drop those, but a clone/mirror can carry them; use
#     `git rev-list --objects --all --reflog` or `git fsck --lost-found`
#     for a paranoid pass.
#   * The contents of `.git` itself: config, hooks, packed-refs, and the
#     reflog message text are never diffed.
#   * Commit metadata other than the subject line is deliberately ignored
#     (Author:/Date:/committer trailers) — the maintainer's own public git
#     identity appears on every commit and is not a leak.
#   * Nothing, as far as diff-line shape goes: a header is recognised by
#     POSITION (an adjacent "--- "/"+++ " pair between a "diff --git" line
#     and that file's first "@@" hunk header), so no content line can
#     masquerade as one. "++<secret>", "--<secret>", "++ b/x <secret>" and
#     even a "-- a/x" / "++ b/x <secret>" replacement pair inside a hunk
#     are all scanned.
#
# ALLOW FILES ARE SCANNED, FIELD BY FIELD — same rule as scrub-check.sh.
# Skipping them wholesale would make them a laundering channel. A hunk
# touching scripts/scrub-allow.txt (or a path given via --allow) is scanned
# line by line, and ONLY the third (match-regex) field of an entry line is
# exempt, and only during a scan of the pattern that entry names; comments,
# blank lines, and the name and path fields are scanned like any other
# content.
#
# HISTORY-ONLY exceptions do not live in this repository at all. Content
# that exists solely in already-published commits has to be excused by
# naming it, and naming it in a committed file re-publishes it. That list
# is therefore private, alongside the private denylist:
#   $SCRUB_ALLOW_HISTORY, default
#   ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/scrub-allow-history.txt
# scripts/scrub-allow-history.example.txt ships the shape with synthetic
# entries only. Neither scanner reads a scripts/scrub-allow-history.txt
# inside the repository — a file of that name in the tree is ordinary
# content and is scanned like any other, which is what keeps it from
# becoming a place to park identity values unseen.
#
# Uses the SAME pattern table and --allow file format as scrub-check.sh
# (<pattern-name>:<path-regex>[:<match-regex>], matched against the file
# path as it appeared in that revision's diff).
#
# This is a SEPARATE, heavier pass — not part of scrub-check.sh's normal
# working-tree scan, and not wired into harness-skills/tests/run.sh. It
# walks every blob in history twice (once as a patch, once as a raw
# object-id listing), so it is O(history), not O(worktree). Run it by hand
# (or from a release checklist) before publishing history that hasn't been
# scanned before, e.g. before a fork, a mirror push, or making a private
# repo public.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./scrub-patterns.sh
. "$HERE/scrub-patterns.sh"

usage() {
  echo "usage: $(basename "$0") [--allow <file>] [--require-private] [path...]" >&2
  exit 2
}

ALLOW_FILE=""
EXPLICIT_ALLOW=0
REQUIRE_PRIVATE=0
PATHSPECS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --allow)
      [ $# -ge 2 ] || usage
      ALLOW_FILE="$2"
      EXPLICIT_ALLOW=1
      shift 2
      ;;
    --require-private)
      REQUIRE_PRIVATE=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

while [ $# -gt 0 ]; do
  PATHSPECS+=("$1")
  shift
done

if ! command -v git >/dev/null 2>&1; then
  echo "scrub-history: git not found" >&2
  exit 2
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "scrub-history: not inside a git repository" >&2
  exit 2
fi

scrub_load_patterns "$REQUIRE_PRIVATE" || exit 2
if [ "$SCRUB_PAT_N" -lt 1 ]; then
  echo "scrub-history: no denylist patterns loaded" >&2
  exit 2
fi

TMPDIR_SH="$(mktemp -d 2>/dev/null)" || TMPDIR_SH=""
if [ -z "$TMPDIR_SH" ] || [ ! -d "$TMPDIR_SH" ]; then
  echo "scrub-history: failed to create a temporary directory (TMPDIR=${TMPDIR:-/tmp})" >&2
  exit 2
fi
cleanup() {
  rm -rf "$TMPDIR_SH"
}
trap cleanup EXIT
if ! : >"$TMPDIR_SH/.probe" 2>/dev/null; then
  echo "scrub-history: temporary directory is not writable: $TMPDIR_SH" >&2
  exit 2
fi
rm -f "$TMPDIR_SH/.probe"

ALLOW_HISTORY_PATH="${SCRUB_ALLOW_HISTORY:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/scrub-allow-history.txt}"

if [ -z "$ALLOW_FILE" ]; then
  # No explicit --allow given: combine the repo's allow file with the
  # PRIVATE history-only allow file, if either exists.
  if [ -f "$HERE/scrub-allow.txt" ] || [ -f "$ALLOW_HISTORY_PATH" ]; then
    ALLOW_FILE="$TMPDIR_SH/combined-allow.txt"
    : >"$ALLOW_FILE"
    # A trailing newline after each cat guards against a source file that
    # doesn't end in one — without it, that file's last line and the next
    # file's first line would merge into one corrupted allow entry.
    if [ -f "$HERE/scrub-allow.txt" ]; then
      cat "$HERE/scrub-allow.txt" >>"$ALLOW_FILE"
      printf '\n' >>"$ALLOW_FILE"
    fi
    if [ -f "$ALLOW_HISTORY_PATH" ]; then
      cat "$ALLOW_HISTORY_PATH" >>"$ALLOW_FILE"
      printf '\n' >>"$ALLOW_FILE"
    else
      echo "scrub: no private history allowlist at $ALLOW_HISTORY_PATH" >&2
    fi
  fi
fi

if [ -n "$ALLOW_FILE" ] && { [ ! -r "$ALLOW_FILE" ] || [ -d "$ALLOW_FILE" ]; }; then
  echo "scrub-history: allowlist file not readable: $ALLOW_FILE" >&2
  exit 2
fi

# --- allow files: field-level exemption, never a whole-file skip -----------
# Recorded by repo-root-relative path, regardless of whether the file exists
# in the working tree — this is a HISTORY scan.
ALLOW_PATHS=()
note_allow_path() {
  _nap_p="$1"
  [ -n "$_nap_p" ] || return 0
  _nap_norm="$(normalize_path "$_nap_p")"
  if [ "${#ALLOW_PATHS[@]}" -gt 0 ]; then
    for _nap_existing in "${ALLOW_PATHS[@]}"; do
      [ "$_nap_existing" = "$_nap_norm" ] && return 0
    done
  fi
  ALLOW_PATHS+=("$_nap_norm")
}
is_allow_ctx_path() {
  [ "${#ALLOW_PATHS[@]}" -gt 0 ] || return 1
  for _iac_s in "${ALLOW_PATHS[@]}"; do
    [ "$1" = "$_iac_s" ] && return 0
  done
  return 1
}

note_allow_path "scripts/scrub-allow.txt"
# scripts/scrub-allow-history.txt is NOT registered: no scanner reads that
# path (the history allowlist is private, at $SCRUB_ALLOW_HISTORY), so a
# file of that name in the tree is ordinary content and gets no exemption.
if [ "$EXPLICIT_ALLOW" -eq 1 ] && [ -n "$ALLOW_FILE" ]; then
  note_allow_path "$ALLOW_FILE"
fi

LOGFILE="$TMPDIR_SH/log.txt"
RAWFILE="$TMPDIR_SH/raw.txt"

# -m: show a diff against EVERY parent of a merge commit. Without it git
# prints no patch at all for merges, so anything introduced by a conflict
# resolution (i.e. text that exists in the merge result but in neither
# parent) is never scanned.
if [ "${#PATHSPECS[@]}" -gt 0 ]; then
  git log --all -p -m -- "${PATHSPECS[@]}" > "$LOGFILE" 2>"$TMPDIR_SH/git.err"
else
  git log --all -p -m > "$LOGFILE" 2>"$TMPDIR_SH/git.err"
fi
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "scrub-history: git log failed (exit $rc)" >&2
  cat "$TMPDIR_SH/git.err" >&2
  exit 2
fi
if [ ! -f "$LOGFILE" ]; then
  echo "scrub-history: could not write the history log into $TMPDIR_SH" >&2
  exit 2
fi

# Transitions: "<lineno>\tC\t<commit>" or "<lineno>\tF\t<file>", in
# ascending line-number order (the same order the log was written).
TRANSITIONS="$TMPDIR_SH/transitions.txt"
awk '
  /^commit / { print NR"\tC\t"$2; next }
  /^diff --git / {
    line = $0
    sub(/^diff --git a\/.* b\//, "", line)
    print NR"\tF\t"line
    next
  }
' "$LOGFILE" > "$TRANSITIONS"

# Real patch file headers, by LINE NUMBER. Neither the "+++ "/"--- "
# prefix NOR the full "+++ b/<path>" shape identifies a header: a committed
# line beginning "++" renders as "+++...", one beginning "--" renders as
# "---...", and a commit that replaces a line reading "-- a/x" with one
# reading "++ b/x <secret>" produces an ADJACENT "--- a/x" / "+++ b/x
# <secret>" pair inside a hunk — byte-for-byte the shape of a real header
# pair.
#
# What a header pair cannot fake is its POSITION. git emits the two file
# headers between "diff --git" and the first "@@" hunk header of that file,
# and every diff line thereafter belongs to a hunk. So the scan is stateful:
# a "--- " / "+++ " pair counts as a header only while in the file-header
# region (after "diff --git", before the first "@@"). Anything else
# beginning with + or - is content.
HDRFILE="$TMPDIR_SH/headers.txt"
awk '
  /^diff --git / { in_header = 1; prev = $0; next }
  /^@@ /         { in_header = 0; prev = $0; next }
  /^commit /     { in_header = 0; prev = $0; next }
  {
    if (in_header && NR > 1 &&
        prev ~ /^--- (a\/.*|\/dev\/null)$/ &&
        $0  ~ /^\+\+\+ (b\/.*|\/dev\/null)$/) {
      print NR - 1
      print NR
    }
    prev = $0
  }
' "$LOGFILE" > "$HDRFILE"

HDR_LINE=()
while IFS= read -r hl; do
  [ -n "$hl" ] || continue
  HDR_LINE+=("$hl")
done < "$HDRFILE"
N_HDR="${#HDR_LINE[@]}"

# is_patch_header <lineno>: forward-cursor lookup, ascending input only.
HDR_I=0
is_patch_header() {
  while [ "$HDR_I" -lt "$N_HDR" ] && [ "${HDR_LINE[$HDR_I]}" -lt "$1" ]; do
    HDR_I=$((HDR_I + 1))
  done
  [ "$HDR_I" -lt "$N_HDR" ] && [ "${HDR_LINE[$HDR_I]}" -eq "$1" ]
}

TR_LINE=()
TR_TYPE=()
TR_VAL=()
while IFS=$'\t' read -r ln ty val; do
  [ -n "$ln" ] || continue
  TR_LINE+=("$ln")
  TR_TYPE+=("$ty")
  TR_VAL+=("$val")
done < "$TRANSITIONS"
N_TR="${#TR_LINE[@]}"

# find_context <lineno> -> sets CTX_COMMIT and CTX_FILE to the most recent
# commit/file transition at or before <lineno>. Transitions and hit line
# numbers are both processed in ascending order per pattern, so this walks
# forward with a single cursor rather than re-scanning from the start.
# Callers MUST reset CTX_TI/CTX_COMMIT/CTX_FILE before each ascending pass.
CTX_TI=0
CTX_COMMIT="(unknown)"
CTX_FILE="(unknown)"
find_context() {
  target="$1"
  while [ "$CTX_TI" -lt "$N_TR" ] && [ "${TR_LINE[$CTX_TI]}" -le "$target" ]; do
    if [ "${TR_TYPE[$CTX_TI]}" = "C" ]; then
      CTX_COMMIT="${TR_VAL[$CTX_TI]}"
    else
      CTX_FILE="${TR_VAL[$CTX_TI]}"
    fi
    CTX_TI=$((CTX_TI + 1))
  done
}

reset_context() {
  CTX_TI=0
  CTX_COMMIT="(unknown)"
  CTX_FILE="(unknown)"
  HDR_I=0
}

HITS=0
BINWARN=0
OUT_FILE="$TMPDIR_SH/out"
ERR_FILE="$TMPDIR_SH/err"

PAT_I=0
while [ "$PAT_I" -lt "$SCRUB_PAT_N" ]; do
  name="${SCRUB_PAT_NAME[$PAT_I]}"
  regex="${SCRUB_PAT_RE[$PAT_I]}"
  ci="${SCRUB_PAT_CI[$PAT_I]}"
  PAT_I=$((PAT_I + 1))

  rm -f "$OUT_FILE" "$ERR_FILE"

  if [ "$ci" = "1" ]; then
    grep -nE -i -- "$regex" "$LOGFILE" >"$OUT_FILE" 2>"$ERR_FILE"
  else
    grep -nE -- "$regex" "$LOGFILE" >"$OUT_FILE" 2>"$ERR_FILE"
  fi
  rc=$?

  if [ ! -f "$OUT_FILE" ]; then
    echo "scrub-history: could not write scan output for pattern '$name' (exit $rc) — temp dir $TMPDIR_SH" >&2
    exit 2
  fi
  if [ "$rc" -eq 1 ]; then
    continue
  elif [ "$rc" -ne 0 ]; then
    echo "scrub-history: grep failed (exit $rc) scanning for pattern '$name'" >&2
    [ -f "$ERR_FILE" ] && cat "$ERR_FILE" >&2
    exit 2
  fi

  reset_context

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    lineno="${line%%:*}"
    excerpt="${line#*:}"
    # Only flag actual diff content (added/removed lines), never commit
    # metadata (Author:/Date:/commit headers) and never the file-header
    # lines of the diff itself.
    #
    # Headers are identified by LINE NUMBER (the adjacent --- / +++ pair
    # found in the file-header region above), never by prefix or shape. A
    # blanket "+++*|---*) continue" — which is what this used to do — threw
    # away real content: "++<secret>" renders as "+++<secret>",
    # "--<secret>" as "---<secret>", and "++ b/x <secret>" as
    # "+++ b/x <secret>", which even a shape test would discard.
    if is_patch_header "$lineno"; then
      continue
    fi
    case "$excerpt" in
      +*|-*) : ;;
      *) continue ;;
    esac
    find_context "$lineno"
    ctx_file_norm="$(normalize_path "$CTX_FILE")"
    if is_allow_ctx_path "$ctx_file_norm"; then
      # Strip the single leading +/- to recover the committed line, then
      # apply the same field-level exemption the working-tree scan uses.
      if scrub_allow_field_exempt "$name" "$regex" "$ci" "${excerpt#?}"; then
        continue
      fi
    fi
    if is_allowed "$name" "$ctx_file_norm" "$excerpt" "$regex" "$ci"; then
      continue
    fi
    trimmed="$(printf '%s' "$excerpt" | cut -c1-120)"
    commit_short="${CTX_COMMIT:0:12}"
    echo "${name}: ${ctx_file_norm} (commit ${commit_short}): ${trimmed}"
    HITS=1
  done < "$OUT_FILE"
done

# --- blobs the text scan could not read ------------------------------------
# Two independent sources, because neither alone is complete:
#   (a) git's own "Binary files ... differ" lines in the patch — covers
#       whatever git's binary heuristic caught (NUL in the first 8000
#       bytes, which is how UTF-16 text lands here too);
#   (b) a direct NUL probe of the first 512 bytes of every blob reachable
#       from --all — covers blobs a .gitattributes `diff` override forced
#       git to render as text, and blobs whose NUL sits past git's window.
BINFILE="$TMPDIR_SH/binary.txt"
: >"$BINFILE"

rm -f "$OUT_FILE"
grep -n '^Binary files .* differ$' "$LOGFILE" >"$OUT_FILE" 2>/dev/null
rc=$?
if [ ! -f "$OUT_FILE" ]; then
  echo "scrub-history: could not write the binary-blob scan output into $TMPDIR_SH" >&2
  exit 2
fi
if [ "$rc" -gt 1 ]; then
  echo "scrub-history: grep failed (exit $rc) scanning for binary blobs" >&2
  exit 2
fi
if [ "$rc" -eq 0 ]; then
  reset_context
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    lineno="${line%%:*}"
    find_context "$lineno"
    printf '%s\t%s\n' "$(normalize_path "$CTX_FILE")" "${CTX_COMMIT:0:12}" >>"$BINFILE"
  done < "$OUT_FILE"
fi

# (b) raw object listing: ":<srcmode> <dstmode> <srcsha> <dstsha> <status>\t<path>"
if [ "${#PATHSPECS[@]}" -gt 0 ]; then
  git log --all -m --raw --no-abbrev --format='commit %H' -- "${PATHSPECS[@]}" >"$RAWFILE" 2>"$TMPDIR_SH/git.err"
else
  git log --all -m --raw --no-abbrev --format='commit %H' >"$RAWFILE" 2>"$TMPDIR_SH/git.err"
fi
rc=$?
if [ "$rc" -ne 0 ] || [ ! -f "$RAWFILE" ]; then
  echo "scrub-history: git log --raw failed (exit $rc)" >&2
  [ -f "$TMPDIR_SH/git.err" ] && cat "$TMPDIR_SH/git.err" >&2
  exit 2
fi

BLOBS="$TMPDIR_SH/blobs.txt"
awk -F'\t' '
  /^commit / { c = substr($0, 8); next }
  /^:/ {
    n = split($1, f, " ")
    dst = f[n - 1]
    if (dst ~ /^0+$/) next
    if (NF < 2) next
    print dst "\t" c "\t" $2
  }
' "$RAWFILE" | sort -u -k1,1 >"$BLOBS"

while IFS=$'\t' read -r blob commit bpath; do
  [ -n "$blob" ] || continue
  if git cat-file -p "$blob" 2>/dev/null | head -c 512 | od -An -v -tx1 2>/dev/null \
      | grep -qE '(^|[[:space:]])00([[:space:]]|$)'; then
    printf '%s\t%s\n' "$(normalize_path "$bpath")" "${commit:0:12}" >>"$BINFILE"
  fi
done < "$BLOBS"

if [ -s "$BINFILE" ]; then
  while IFS=$'\t' read -r bpath bcommit; do
    [ -n "$bpath" ] || continue
    echo "unscanned-binary: ${bpath} (commit ${bcommit})"
    BINWARN=1
  done < <(sort -u "$BINFILE")
fi

if [ "$HITS" -ne 0 ]; then
  exit 1
fi
if [ "$BINWARN" -ne 0 ]; then
  exit 4
fi
exit 0
