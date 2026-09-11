#!/usr/bin/env bash
# scrub-check.sh — denylist scanner for public-repo hygiene.
#
# Usage: scrub-check.sh [--allow <file>] [--require-private]
#                       [--check-allowlist] [--check-overbroad] <path>...
#
# Exit codes:
#   0 = clean
#   1 = one or more denylist hits, or (with --check-allowlist or
#       --check-overbroad) one or more allowlist entries that suppressed
#       nothing (--check-allowlist only) or are too broad to be
#       value-scoped (either flag) — hard failure
#   2 = usage error, a missing target path, a temp-directory failure, a
#       missing/malformed private denylist (with --require-private), the
#       private denylist living inside a scanned target, or an unexpected
#       grep failure
#   4 = SOFT warning only: no denylist hits, but one or more dangling
#       [[wikilink]] references in *.md files did not resolve. Callers that
#       want to treat this as advisory rather than blocking can check for
#       exit 4 specifically.
#
# Patterns come from scripts/scrub-patterns.sh: the GENERIC classes it
# commits, plus a PRIVATE denylist loaded from $SCRUB_DENYLIST (default
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/scrub-denylist.txt).
# Organisation-specific terms live only in that private file — see the
# header of scrub-patterns.sh and scripts/scrub-denylist.example.txt. If
# the private file is absent the scan warns once on stderr and proceeds
# with the generic classes only; --require-private turns that into exit 2,
# which is what a local pre-push / release gate should use.
#
# This scanner is FAIL CLOSED:
#   - A target path that does not exist is an error (exit 2), not a silent
#     no-op scan.
#   - The temp directory is created and probed for writability up front. A
#     failure there (unset/bogus $TMPDIR, a read-only $TMPDIR, a full disk)
#     aborts with exit 2. Historically this was the worst failure mode:
#     mktemp failed, every subsequent `>"$TMPDIR/out"` redirection failed,
#     each grep "found nothing", and the scan exited 0 having scanned
#     nothing at all.
#   - grep exit 1 is only treated as "no hits" when the output file it was
#     supposed to write actually exists; anything else (grep >= 2, a failed
#     redirection) aborts with exit 2 — never swallowed.
#   - Nothing is excluded by filename pattern (e.g. no blanket *.fixture
#     skip); every real file is scanned, and deliberate exceptions go
#     through --allow only. Only .git (directory or the worktree pointer
#     file of the same name), __pycache__, and node_modules are skipped —
#     these are tooling/VCS internals, not content.
#
# ALLOW FILES ARE SCANNED, FIELD BY FIELD. Skipping them wholesale would
# turn them into a laundering channel: park a credential in
# scrub-allow.txt, in a comment or in a path-regex, and no scanner ever
# looks at it again. An allow file — any file loaded via --allow, plus
# scripts/scrub-allow.txt by fixed name relative to each scanned root — is
# scanned line by line, and ONLY the third (match-regex) field of an entry
# line is exempt, because that field necessarily spells out the value it
# excuses. Comments, blank lines, entries with no third field, and the name
# and path fields of every entry are scanned exactly like any other file's
# content.
#
# The exemption is bound to the pattern being scanned: an entry named for
# pattern X excuses its third field only during X's own scan. Otherwise any
# value could be laundered under a harmless-looking name of another class.
#
# scripts/scrub-allow-history.txt is deliberately NOT in that list. No
# scanner reads it (scrub-history.sh loads the private history allowlist
# from $SCRUB_ALLOW_HISTORY, outside the repo), so registering it here gave
# a file that lives in the working tree a field-level exemption nothing
# ever consumed — the exact shape of a leak: real identity values in its
# third fields, exempted from this scan, committed by `git add -A`.
#
# The private denylist ($SCRUB_DENYLIST) is a different thing: it is not an
# allow file and it must never live inside the scanned tree. If it does the
# scan EXITS 2 — it is nothing but denylisted values, so finding it staged
# is the worst outcome this scanner can discover, not a warning to print on
# the way to exit 0.
#
# Recurses into every given path with grep -rnE (or -rniE for
# case-insensitive patterns) and reports each hit as:
#   <pattern-name>: <file>:<line>: <excerpt trimmed to 120 chars>
#
# An optional --allow file holds deliberate exceptions, one per line:
#   <pattern-name>:<path-regex>[:<match-regex>]
# The optional third field scopes the exception to a VALUE, not a whole
# file (see scrub-patterns.sh for the exact semantics). Blank lines and
# lines starting with # are ignored. The same file also allowlists
# dangling-link warnings, keyed under the pattern name "dangling-link".
#
# --check-allowlist additionally reports, and fails on:
#   unused-allow:   <allow-file>:<line>: <entry>   suppressed nothing
#   unscoped-allow: <allow-file>:<line>: <entry>   a secret-shape or
#       home-path exception with no third field — a bare path there
#       whitelists every present AND future credential in that file.
#   wildcard-allow: <allow-file>:<line>: <entry>   a third field broad
#       enough to delete a value the author never saw (".*", "[A-Z0-9]+",
#       "/home/[a-z]+/"), which excuses every secret of that class on the
#       line instead of the one named. Detected by canary: a fresh value of
#       the entry's own class is synthesized and the third field is applied
#       to it (see scrub_allow_overbroad in scrub-patterns.sh).
# unused-allow is only meaningful on a FULL-repo scan with the private
# denylist loaded; unscoped-allow and wildcard-allow are pure lints on the
# file and are always sound.
#
# --check-overbroad runs the wildcard-allow lint ALONE — no unused-allow,
# no unscoped-allow, and no private denylist required. It exists because
# --check-allowlist only runs in the CI step guarded by the private
# denylist secret, which is unavailable (and the step is skipped) on fork
# PRs — exactly the untrusted-contribution path where an over-broad entry
# like `secret-shape:^README[.]md$:.*` needs to be caught before merge, not
# after. Same finding format as --check-allowlist's wildcard-allow line;
# same fail-closed rule (a class with no canary, or a pattern that never
# loaded, is reported as NOT over-broad, never guessed at).
#
# Requires only POSIX/BSD-compatible grep -E; no GNU-only -P or \b is used
# (word boundaries use \< \>, supported by both GNU and BSD grep).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./scrub-patterns.sh
. "$HERE/scrub-patterns.sh"

usage() {
  echo "usage: $(basename "$0") [--allow <file>] [--require-private] [--check-allowlist] [--check-overbroad] <path>..." >&2
  exit 2
}

ALLOW_FILE=""
REQUIRE_PRIVATE=0
CHECK_ALLOWLIST=0
CHECK_OVERBROAD=0
TARGETS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --allow)
      [ $# -ge 2 ] || usage
      ALLOW_FILE="$2"
      shift 2
      ;;
    --require-private)
      REQUIRE_PRIVATE=1
      shift
      ;;
    --check-allowlist)
      CHECK_ALLOWLIST=1
      shift
      ;;
    --check-overbroad)
      CHECK_OVERBROAD=1
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
  TARGETS+=("$1")
  shift
done
[ "${#TARGETS[@]}" -ge 1 ] || usage

if [ -n "$ALLOW_FILE" ] && { [ ! -r "$ALLOW_FILE" ] || [ -d "$ALLOW_FILE" ]; }; then
  echo "scrub-check: allowlist file not readable: $ALLOW_FILE" >&2
  exit 2
fi
if [ "$CHECK_ALLOWLIST" -eq 1 ] && [ -z "$ALLOW_FILE" ]; then
  echo "scrub-check: --check-allowlist requires --allow <file>" >&2
  exit 2
fi
if [ "$CHECK_OVERBROAD" -eq 1 ] && [ -z "$ALLOW_FILE" ]; then
  echo "scrub-check: --check-overbroad requires --allow <file>" >&2
  exit 2
fi

for t in "${TARGETS[@]}"; do
  if [ ! -e "$t" ]; then
    echo "scrub-check: missing target $t" >&2
    exit 2
  fi
done

scrub_load_patterns "$REQUIRE_PRIVATE" || exit 2
if [ "$SCRUB_PAT_N" -lt 1 ]; then
  echo "scrub-check: no denylist patterns loaded" >&2
  exit 2
fi

TMPDIR_SC="$(mktemp -d 2>/dev/null)" || TMPDIR_SC=""
if [ -z "$TMPDIR_SC" ] || [ ! -d "$TMPDIR_SC" ]; then
  echo "scrub-check: failed to create a temporary directory (TMPDIR=${TMPDIR:-/tmp})" >&2
  exit 2
fi
cleanup() {
  rm -rf "$TMPDIR_SC"
}
trap cleanup EXIT
if ! : >"$TMPDIR_SC/.probe" 2>/dev/null; then
  echo "scrub-check: temporary directory is not writable: $TMPDIR_SC" >&2
  exit 2
fi
rm -f "$TMPDIR_SC/.probe"

# --- allow files and the private denylist ----------------------------------
# Allow files are NOT skipped (see the header note above) — they are
# recorded here so a hit inside one can get the field-level exemption.
# abs_path resolves a file that is known to exist to an absolute path for
# reliable comparison against however grep happened to echo the same file
# back (".", "./sub", an absolute target, ...).
abs_path() {
  _ap_p="$1"
  if [ -d "$_ap_p" ]; then
    (cd "$_ap_p" 2>/dev/null && pwd)
    return
  fi
  _ap_d="$(dirname "$_ap_p")"
  _ap_b="$(basename "$_ap_p")"
  (cd "$_ap_d" 2>/dev/null && printf '%s/%s' "$(pwd)" "$_ap_b")
}

ALLOW_ABS=()
note_allow_file() {
  _naf_f="$1"
  [ -n "$_naf_f" ] || return 0
  [ -f "$_naf_f" ] || return 0
  _naf_abs="$(abs_path "$_naf_f")"
  [ -n "$_naf_abs" ] || return 0
  if [ "${#ALLOW_ABS[@]}" -gt 0 ]; then
    for _naf_existing in "${ALLOW_ABS[@]}"; do
      [ "$_naf_existing" = "$_naf_abs" ] && return 0
    done
  fi
  ALLOW_ABS+=("$_naf_abs")
}

is_allow_file_abs() {
  [ "${#ALLOW_ABS[@]}" -gt 0 ] || return 1
  for _iaf_s in "${ALLOW_ABS[@]}"; do
    [ "$1" = "$_iaf_s" ] && return 0
  done
  return 1
}

[ -n "$ALLOW_FILE" ] && note_allow_file "$ALLOW_FILE"
for t in "${TARGETS[@]}"; do
  note_allow_file "$t/scripts/scrub-allow.txt"
done

# The private denylist is not an allow file and must never live inside the
# scanned tree: it is nothing but denylisted values, so a copy inside the
# tree is the leak the scanner exists to prevent. This used to warn,
# exclude the file from the scan, and exit 0 — a green run that had just
# been told the worst possible file is staged. It is an ERROR.
DENYLIST_PATH="$(scrub_denylist_path)"
if [ -f "$DENYLIST_PATH" ]; then
  DENYLIST_ABS="$(abs_path "$DENYLIST_PATH")"
  for t in "${TARGETS[@]}"; do
    TARGET_ABS="$(abs_path "$t")"
    case "$DENYLIST_ABS" in
      "$TARGET_ABS"|"$TARGET_ABS"/*)
        echo "scrub-check: private denylist $DENYLIST_ABS is inside the scanned tree ($t) — move it out; it must never be committed" >&2
        exit 2
        ;;
    esac
  done
fi

HITS=0
DANGLE=0
OUT_FILE="$TMPDIR_SC/out"
ERR_FILE="$TMPDIR_SC/err"
USED_FILE="$TMPDIR_SC/allow-used"
: >"$USED_FILE" 2>/dev/null || {
  echo "scrub-check: cannot write into temporary directory: $TMPDIR_SC" >&2
  exit 2
}

note_allow_use() {
  [ -n "${ALLOW_MATCH_LINE:-}" ] || return 0
  printf '%s\n' "$ALLOW_MATCH_LINE" >>"$USED_FILE"
}

PAT_I=0
while [ "$PAT_I" -lt "$SCRUB_PAT_N" ]; do
  name="${SCRUB_PAT_NAME[$PAT_I]}"
  regex="${SCRUB_PAT_RE[$PAT_I]}"
  ci="${SCRUB_PAT_CI[$PAT_I]}"
  PAT_I=$((PAT_I + 1))

  rm -f "$OUT_FILE" "$ERR_FILE"

  if [ "$ci" = "1" ]; then
    grep -rniEH \
      --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=node_modules \
      --exclude=.git \
      -- "$regex" "${TARGETS[@]}" >"$OUT_FILE" 2>"$ERR_FILE"
  else
    grep -rnEH \
      --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=node_modules \
      --exclude=.git \
      -- "$regex" "${TARGETS[@]}" >"$OUT_FILE" 2>"$ERR_FILE"
  fi
  rc=$?

  # A failed redirection (unwritable temp dir) also surfaces as rc 1 with
  # no output file — that is NOT "no hits". Only trust rc 1 when grep
  # actually produced the file it was told to write.
  if [ ! -f "$OUT_FILE" ]; then
    echo "scrub-check: could not write scan output for pattern '$name' (exit $rc) — temp dir $TMPDIR_SC" >&2
    exit 2
  fi
  if [ "$rc" -eq 1 ]; then
    continue
  elif [ "$rc" -ne 0 ]; then
    echo "scrub-check: grep failed (exit $rc) scanning for pattern '$name'" >&2
    [ -f "$ERR_FILE" ] && cat "$ERR_FILE" >&2
    exit 2
  fi
  # rc == 0: at least one match.

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    fpath="${line%%:*}"
    rest="${line#*:}"
    lineno="${rest%%:*}"
    excerpt="${rest#*:}"
    hit_abs="$(abs_path "$fpath" 2>/dev/null)"
    # Field-level exemption inside an allow file: only the match-regex
    # field of an entry line is excused, never a comment or the name/path
    # fields, and only for a scan of the pattern that entry itself names.
    if [ -n "$hit_abs" ] && is_allow_file_abs "$hit_abs" \
       && scrub_allow_field_exempt "$name" "$regex" "$ci" "$excerpt"; then
      continue
    fi
    fpath="$(normalize_path "$fpath")"
    if is_allowed "$name" "$fpath" "$excerpt" "$regex" "$ci"; then
      note_allow_use
      continue
    fi
    trimmed="$(printf '%s' "$excerpt" | cut -c1-120)"
    echo "${name}: ${fpath}:${lineno}: ${trimmed}"
    HITS=1
  done < "$OUT_FILE"
done

# --- dangling-link (soft) check: every [[name]] in *.md under a target must
# resolve to skills/<name>/ or agents/<name>.md under that file's plugin
# root (nearest ancestor directory containing .claude-plugin/). Files with
# no discoverable plugin root are skipped — the check only makes sense
# inside a plugin tree.

find_plugin_root() {
  d="$1"
  while :; do
    if [ -d "$d/.claude-plugin" ]; then
      printf '%s' "$d"
      return 0
    fi
    [ "$d" = "/" ] && return 1
    parent="$(dirname "$d")"
    [ "$parent" = "$d" ] && return 1
    d="$parent"
  done
}

MD_FILES="$(find "${TARGETS[@]}" -type f -name '*.md' \
  -not -path '*/.git/*' -not -path '*/__pycache__/*' -not -path '*/node_modules/*' \
  2>/dev/null || true)"

if [ -n "$MD_FILES" ]; then
  while IFS= read -r mdfile; do
    [ -n "$mdfile" ] || continue
    broot="$(find_plugin_root "$(cd "$(dirname "$mdfile")" && pwd)")" || continue
    matches="$(grep -noE '\[\[[A-Za-z0-9_-]+\]\]' "$mdfile" 2>/dev/null || true)"
    [ -z "$matches" ] && continue
    mdfile_norm="$(normalize_path "$mdfile")"
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      lineno="${m%%:*}"
      tok="${m#*:}"
      name="${tok#\[\[}"
      name="${name%\]\]}"
      if [ -d "$broot/skills/$name" ] || [ -f "$broot/agents/$name.md" ]; then
        continue
      fi
      if is_allowed "dangling-link" "$mdfile_norm"; then
        note_allow_use
        continue
      fi
      echo "dangling-link: ${mdfile_norm}:${lineno}: [[${name}]] does not resolve under ${broot}"
      DANGLE=1
    done <<EOF
$matches
EOF
  done <<EOF
$MD_FILES
EOF
fi

# --- dead-allow-entry check (opt-in): an exception that suppresses nothing
# is either stale or was never right; either way it widens the allowlist
# for free. Only sound on a full-repo scan, hence opt-in.
DEAD_ALLOW=0
if [ "$CHECK_ALLOWLIST" -eq 1 ]; then
  USED_SORTED="$TMPDIR_SC/allow-used.sorted"
  sort -u "$USED_FILE" >"$USED_SORTED" 2>/dev/null || : >"$USED_SORTED"
  aline=0
  while IFS= read -r entry || [ -n "$entry" ]; do
    aline=$((aline + 1))
    case "$entry" in
      ''|'#'*) continue ;;
    esac
    # A bare path exception for a credential-shaped class whitelists EVERY
    # present and future secret in that file. Those classes must name the
    # value they are excusing.
    # "?*" after the second colon: a third field that is present but EMPTY
    # is not a value scope, it is a typo that silently widens the entry.
    case "$entry" in
      secret-shape:*:?*|home-path:*:?*) : ;;
      secret-shape:*|home-path:*)
        echo "unscoped-allow: ${ALLOW_FILE}:${aline}: ${entry}"
        echo "  (a $(printf '%s' "$entry" | cut -d: -f1) exception needs a non-empty third field pinning it to a value)"
        DEAD_ALLOW=1
        continue
        ;;
    esac
    # A third field that is present but WILDCARD is worse than a missing
    # one, because it looks value-scoped. "secret-shape:^x$:[A-Z0-9]+" or
    # ":.*" deletes every credential on the line before the rescan, so the
    # rescan finds nothing and the hit disappears — the same blanket
    # exemption unscoped-allow rejects, wearing the careful syntax. The
    # canary test is the only way to tell the two apart from the entry
    # alone; see scrub_allow_overbroad.
    case "$entry" in
      *:*:?*)
        aname="${entry%%:*}"
        arest="${entry#*:}"
        aval="${arest#*:}"
        if scrub_allow_overbroad "$aname" "$aval"; then
          echo "wildcard-allow: ${ALLOW_FILE}:${aline}: ${entry}"
          echo "  (its third field also excuses a freshly generated ${aname} value — scope it to the literal it means)"
          DEAD_ALLOW=1
          continue
        fi
        ;;
    esac
    if grep -qx -- "$aline" "$USED_SORTED" 2>/dev/null; then
      continue
    fi
    echo "unused-allow: ${ALLOW_FILE}:${aline}: ${entry}"
    DEAD_ALLOW=1
  done < "$ALLOW_FILE"
fi

# --- overbroad-allow-entry check (opt-in, canary-only): the wildcard-allow
# half of --check-allowlist above, on its own. Needs neither unused-allow's
# repo-wide USED_FILE tracking nor a private denylist — only the entry
# itself and whatever generic-class canary scrub_allow_overbroad can
# synthesize — so it is safe to run on every PR, fork or not. Skipped when
# --check-allowlist already ran the same lint, to avoid a duplicate report.
if [ "$CHECK_OVERBROAD" -eq 1 ] && [ "$CHECK_ALLOWLIST" -eq 0 ]; then
  aline=0
  while IFS= read -r entry || [ -n "$entry" ]; do
    aline=$((aline + 1))
    case "$entry" in
      ''|'#'*) continue ;;
    esac
    case "$entry" in
      *:*:?*)
        aname="${entry%%:*}"
        arest="${entry#*:}"
        aval="${arest#*:}"
        if scrub_allow_overbroad "$aname" "$aval"; then
          echo "wildcard-allow: ${ALLOW_FILE}:${aline}: ${entry}"
          echo "  (its third field also excuses a freshly generated ${aname} value — scope it to the literal it means)"
          DEAD_ALLOW=1
        fi
        ;;
    esac
  done < "$ALLOW_FILE"
fi

if [ "$HITS" -ne 0 ] || [ "$DEAD_ALLOW" -ne 0 ]; then
  exit 1
fi
if [ "$DANGLE" -ne 0 ]; then
  exit 4
fi
exit 0
