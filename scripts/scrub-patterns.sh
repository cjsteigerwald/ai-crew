#!/usr/bin/env bash
# scrub-patterns.sh — shared denylist pattern table + allowlist matcher for
# scrub-check.sh (working-tree scan) and scrub-history.sh (git-history scan).
# Sourced only — has no side effects and does not parse arguments.
#
# THIS REPOSITORY IS PUBLIC, so this file carries only GENERIC pattern
# classes (shapes that are dangerous for anybody: home paths, RDP share
# paths, UUIDs, credential shapes). Organisation-specific terms — employer
# names, internal hostnames, ticket-key prefixes, system code names,
# personal handles — must NEVER be committed here: a denylist that spells
# out the strings it hides publishes exactly those strings. They live in a
# PRIVATE denylist file outside the repo (see below), which both scanners
# load in addition to the generic classes.
#
# Private denylist
#   Path: $SCRUB_DENYLIST, else
#         ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/scrub-denylist.txt
#   Format: one entry per line, three TAB-separated fields
#       <name><TAB><flags><TAB><POSIX-ERE>
#     flags: "i" = case-insensitive, "-" = case-sensitive (any other
#     characters are ignored; "i" anywhere in the field turns folding on).
#     Blank lines and lines whose first character is "#" are ignored.
#   See scripts/scrub-denylist.example.txt for the shape (synthetic
#   entries only — that file is committed, so it must stay synthetic).
#   If the file is absent the scanners warn once on stderr and continue
#   with the generic classes only, unless --require-private was passed, in
#   which case they exit 2. A file that exists but defines no entries is
#   treated the same way: a warning without --require-private, exit 2 with
#   it — "the file is there" is exactly the false assurance the flag
#   exists to prevent.
#
# Provides:
#   scrub_load_patterns [require_private]
#                         builds the pattern table (generic classes, then
#                         private entries). Pass "1" to make a missing
#                         private denylist an error. Returns 0 on success,
#                         2 on any error (unreadable/malformed private
#                         file, missing file with require_private). Callers
#                         MUST check the return value and exit 2.
#   SCRUB_PAT_N           number of loaded patterns
#   SCRUB_PAT_NAME[i] / SCRUB_PAT_CI[i] / SCRUB_PAT_RE[i]
#                         parallel arrays, in report order: pattern name,
#                         "1"/"0" for case-insensitive matching, and the
#                         POSIX-ERE regex (BSD/GNU grep -E compatible —
#                         word boundaries use \< \>, never the GNU-only \b,
#                         and no -P is used anywhere).
#   PATTERN_NAMES         space-separated pattern names, in the same order
#                         (informational; iterate the arrays by index, a
#                         name can legitimately appear twice when a private
#                         entry extends a generic class).
#   pattern_regex <name> / pattern_ci <name>
#                         first-match lookups by name, kept for callers
#                         that only need one regex.
#   pattern_exists <name> 0 (true) when <name> is a currently loaded pattern.
#   scrub_allow_field_exempt <scan-name> <regex> <ci> <line>
#                         0 (true) when <line> is an allow-file ENTRY line
#                         whose denylist match lives entirely in the third
#                         (match-regex) field. Allow files are scanned like
#                         any other file; only that one field is exempt, and
#                         only when the entry names the pattern CURRENTLY
#                         being scanned (<scan-name>), the field is
#                         non-empty, and the field itself carries no
#                         credential shape beyond the documented public
#                         examples in scrub-public-examples.txt. See the
#                         block above the function for why.
#   scrub_allow_overbroad <pattern-name> <match-regex>
#                         0 (true) when <match-regex> would also excuse a
#                         FRESHLY SYNTHESIZED value of <pattern-name> — a
#                         value the entry's author cannot have seen. The
#                         canaries are derived from the class regex itself,
#                         one set per alternative it spells out, so a third
#                         field narrowed to one credential SHAPE is caught
#                         as well as an outright wildcard. Used by
#                         scrub-check.sh --check-allowlist to reject
#                         wildcard/whole-line third fields.
#   is_allowed <name> <path> [excerpt [regex [ci]]]
#                         0 (true) if ALLOW_FILE permits this hit; see the
#                         allowlist format below. Requires ALLOW_FILE to be
#                         set by the caller (empty/unset is fine — every
#                         hit is then "not allowed"). On a true return it
#                         also sets ALLOW_MATCH_LINE to the 1-based line
#                         number of the entry that allowed the hit, so a
#                         caller can detect allow entries that suppress
#                         nothing (see scrub-check.sh --check-allowlist).
#   normalize_path <path> prints <path> with a leading "./" stripped and,
#                         if it's absolute and under $PWD, made relative to
#                         $PWD. Callers MUST normalize a reported path
#                         before both displaying it and calling is_allowed
#                         with it — allow-file regexes are written
#                         repo-relative, and grep echoes back whatever
#                         prefix the caller's target argument had (".",
#                         "./sub", "sub", or an absolute path all produce
#                         differently-prefixed paths for the same file).
#
# Allowlist format (ALLOW_FILE), one entry per line:
#     <pattern-name>:<path-regex>[:<match-regex>]
#   Split is on the FIRST colon (name) and then the FIRST colon of the
#   remainder (path), so a path-regex may not contain a colon; everything
#   after that second colon is the optional match-regex.
#   Without a match-regex the entry allows every hit of <pattern-name> in a
#   file whose path matches <path-regex> — a blunt instrument, use sparingly.
#   With a match-regex the hit is allowed ONLY if, after deleting every
#   substring of the reported excerpt that matches <match-regex>, the
#   denylist pattern no longer matches what is left. A second, different
#   secret on the same line then still fails — but ONLY to the extent that
#   the match-regex names the value it excuses. Nothing at scan time stops
#   an entry from carrying a wildcard third field ("[A-Z0-9]+", ".*"),
#   which deletes every secret on the line and so excuses all of them; the
#   scan cannot tell a deliberately broad regex from a tight one. That is
#   what `scrub-check.sh --check-allowlist` is for: it canary-tests every
#   third field against freshly synthesized values of the entry's own class
#   — one per credential shape that class matches, in both cases (see
#   scrub_allow_overbroad) — and reports an entry that would also swallow
#   any of THEM as wildcard-allow. Run it — an allowlist that has never
#   been linted carries no value-scoping guarantee.
#   The match-regex is applied CASE-SENSITIVELY even for case-insensitive
#   pattern classes (folding a regex is not safe); write it to match the
#   text as it actually appears. If it cannot be applied (invalid regex,
#   no excerpt on hand — e.g. the dangling-link check) the entry does
#   NOT allow the hit: fail closed.

SCRUB_DENYLIST_DEFAULT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/scrub-denylist.txt"

# Directory this file lives in, used to find scrub-public-examples.txt.
_SCRUB_PAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
SCRUB_PUBLIC_EXAMPLES_DEFAULT="${_SCRUB_PAT_DIR}/scrub-public-examples.txt"

# Documented public example credentials (see scrub-public-examples.txt).
SCRUB_PUBEX=()
SCRUB_PUBEX_N=0

SCRUB_PAT_N=0
SCRUB_PAT_NAME=()
SCRUB_PAT_CI=()
SCRUB_PAT_RE=()
PATTERN_NAMES=""

# Set by scrub_load_patterns to the pattern count right after the generic
# classes are loaded, i.e. before the private denylist file is read. A
# pattern's FIRST loaded index below this boundary is a generic (public)
# class; a name that only ever appears at or past it exists solely because
# the private denylist added it. This is the same public/private split the
# loading code already makes by ORDER — generic classes, then private
# entries — surfaced as a number instead of invented as a new per-pattern
# flag.
_SCRUB_GENERIC_PAT_N=0

_scrub_add_pattern() {
  # $1 = name, $2 = ci ("0"/"1"), $3 = POSIX-ERE regex
  SCRUB_PAT_NAME[$SCRUB_PAT_N]="$1"
  SCRUB_PAT_CI[$SCRUB_PAT_N]="$2"
  SCRUB_PAT_RE[$SCRUB_PAT_N]="$3"
  SCRUB_PAT_N=$((SCRUB_PAT_N + 1))
  if [ -z "$PATTERN_NAMES" ]; then
    PATTERN_NAMES="$1"
  else
    PATTERN_NAMES="$PATTERN_NAMES $1"
  fi
}

# --- generic classes -------------------------------------------------------
# uuid is matched case-insensitively: an identity class must not be evadable
# by upper-casing it. secret-shape stays case-sensitive on purpose — the
# token prefixes it looks for (the "ghp" and "AKIA" families, the Slack
# "xox" family) have a fixed case, and folding would turn "akia" in
# ordinary prose into a hit.
_scrub_add_generic_patterns() {
  _scrub_add_pattern home-path 0 '/home/[A-Za-z0-9_.-]+/|/Users/[A-Za-z0-9_.-]+/'
  _scrub_add_pattern rdp-share 0 '/mnt/tsclient|\\\\tsclient'
  _scrub_add_pattern uuid 1 '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
  _scrub_add_pattern secret-shape 0 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-|BEGIN [A-Z ]*PRIVATE KEY|dt0[cs]01\.[A-Z0-9]{24}'
}

scrub_denylist_path() {
  printf '%s' "${SCRUB_DENYLIST:-$SCRUB_DENYLIST_DEFAULT}"
}

scrub_load_patterns() {
  # $1 = "1" to require the private denylist. Returns 0 ok / 2 error.
  _slp_require="${1:-0}"
  _slp_tab="$(printf '\t')"

  SCRUB_PAT_N=0
  SCRUB_PAT_NAME=()
  SCRUB_PAT_CI=()
  SCRUB_PAT_RE=()
  PATTERN_NAMES=""
  _scrub_add_generic_patterns
  _SCRUB_GENERIC_PAT_N=$SCRUB_PAT_N
  _scrub_load_public_examples

  _slp_path="$(scrub_denylist_path)"
  if [ ! -f "$_slp_path" ]; then
    if [ "$_slp_require" = "1" ]; then
      echo "scrub: --require-private given but no private denylist at $_slp_path" >&2
      return 2
    fi
    echo "scrub: no private denylist at $_slp_path (generic classes only)" >&2
    return 0
  fi
  if [ ! -r "$_slp_path" ]; then
    echo "scrub: private denylist not readable: $_slp_path" >&2
    return 2
  fi

  _slp_no=0
  _slp_added=0
  while IFS= read -r _slp_line || [ -n "$_slp_line" ]; do
    _slp_no=$((_slp_no + 1))
    _slp_line="${_slp_line%$'\r'}"
    case "$_slp_line" in
      ''|'#'*) continue ;;
    esac
    case "$_slp_line" in
      *"$_slp_tab"*) : ;;
      *)
        echo "scrub: $_slp_path:$_slp_no: malformed entry (expected name<TAB>flags<TAB>regex)" >&2
        return 2
        ;;
    esac
    _slp_name="${_slp_line%%$_slp_tab*}"
    _slp_rest="${_slp_line#*$_slp_tab}"
    case "$_slp_rest" in
      *"$_slp_tab"*) : ;;
      *)
        echo "scrub: $_slp_path:$_slp_no: malformed entry (expected name<TAB>flags<TAB>regex)" >&2
        return 2
        ;;
    esac
    _slp_flags="${_slp_rest%%$_slp_tab*}"
    _slp_re="${_slp_rest#*$_slp_tab}"

    case "$_slp_name" in
      *[!A-Za-z0-9_-]*|'')
        echo "scrub: $_slp_path:$_slp_no: invalid pattern name '$_slp_name' (allowed: A-Z a-z 0-9 _ -)" >&2
        return 2
        ;;
    esac
    if [ -z "$_slp_re" ]; then
      echo "scrub: $_slp_path:$_slp_no: empty regex for pattern '$_slp_name'" >&2
      return 2
    fi
    # Reject a regex grep cannot compile now, rather than mid-scan where it
    # would look like a scan failure (or, worse, get swallowed).
    printf 'x' | grep -Eq -- "$_slp_re" >/dev/null 2>&1
    if [ $? -gt 1 ]; then
      echo "scrub: $_slp_path:$_slp_no: invalid POSIX-ERE for pattern '$_slp_name'" >&2
      return 2
    fi

    _slp_ci=0
    case "$_slp_flags" in
      *i*) _slp_ci=1 ;;
    esac
    _slp_added=$((${_slp_added:-0} + 1))
    _scrub_add_pattern "$_slp_name" "$_slp_ci" "$_slp_re"
  done < "$_slp_path"

  # An existing but entry-less private denylist protects nothing. Under
  # --require-private that is a FAILURE, not a warning: "the file is there"
  # is precisely the false assurance --require-private exists to prevent.
  if [ "${_slp_added:-0}" -eq 0 ]; then
    if [ "$_slp_require" = "1" ]; then
      echo "scrub: private denylist has no entries: $_slp_path" >&2
      return 2
    fi
    echo "scrub: private denylist $_slp_path has no entries (generic classes only)" >&2
  fi

  return 0
}

pattern_regex() {
  _pr_i=0
  while [ "$_pr_i" -lt "$SCRUB_PAT_N" ]; do
    if [ "${SCRUB_PAT_NAME[$_pr_i]}" = "$1" ]; then
      printf '%s' "${SCRUB_PAT_RE[$_pr_i]}"
      return 0
    fi
    _pr_i=$((_pr_i + 1))
  done
  return 1
}

# _scrub_pattern_is_public <name>: 0 (true) when <name>'s first loaded
# definition is one of the generic classes (index below
# _SCRUB_GENERIC_PAT_N), 1 when it exists only because the private
# denylist added it.
_scrub_pattern_is_public() {
  _spp_i=0
  while [ "$_spp_i" -lt "$SCRUB_PAT_N" ]; do
    if [ "${SCRUB_PAT_NAME[$_spp_i]}" = "$1" ]; then
      [ "$_spp_i" -lt "$_SCRUB_GENERIC_PAT_N" ]
      return $?
    fi
    _spp_i=$((_spp_i + 1))
  done
  return 1
}

pattern_ci() {
  _pc_i=0
  while [ "$_pc_i" -lt "$SCRUB_PAT_N" ]; do
    if [ "${SCRUB_PAT_NAME[$_pc_i]}" = "$1" ]; then
      printf '%s' "${SCRUB_PAT_CI[$_pc_i]}"
      return 0
    fi
    _pc_i=$((_pc_i + 1))
  done
  printf '0'
  return 1
}

normalize_path() {
  p="$1"
  case "$p" in
    ./*)
      p="${p#./}"
      ;;
  esac
  case "$p" in
    /*)
      case "$p" in
        "$PWD"/*)
          p="${p#"$PWD"/}"
          ;;
        "$PWD")
          p="."
          ;;
      esac
      ;;
  esac
  printf '%s' "$p"
}

# _scrub_value_allowed <match-regex> <excerpt> <pattern-regex> <ci>
# True when deleting every <match-regex> occurrence from <excerpt> leaves
# nothing the denylist pattern still matches. Fail closed on any problem.
_scrub_value_allowed() {
  _va_m="$1"
  _va_ex="$2"
  _va_pat="$3"
  _va_ci="${4:-0}"
  [ -n "$_va_ex" ] || return 1
  [ -n "$_va_pat" ] || return 1
  _va_d="$(printf '\a')"
  _va_rest="$(printf '%s' "$_va_ex" | sed -E "s${_va_d}${_va_m}${_va_d} ${_va_d}g" 2>/dev/null)" || return 1
  if [ "$_va_ci" = "1" ]; then
    printf '%s' "$_va_rest" | grep -qiE -- "$_va_pat" 2>/dev/null && return 1
  else
    printf '%s' "$_va_rest" | grep -qE -- "$_va_pat" 2>/dev/null && return 1
  fi
  return 0
}

# --- over-broad allow entries (canary test) --------------------------------
# _scrub_value_allowed cannot tell a spelled-out literal (the documented
# example key in scrub-public-examples.txt, say) from "[A-Z0-9]+": both
# delete the reported secret and both leave a line the pattern no longer
# matches. The second one also deletes every OTHER secret on that
# line, present and future, which is exactly the guarantee the third field
# is supposed to provide. Nothing in the excerpt distinguishes them.
#
# A value the entry's author could not have seen does distinguish them: a
# freshly generated secret of the same class. A tight third field deletes
# nothing from it (so the class still matches, and the entry would NOT
# excuse it); an over-broad one deletes it too. The canary is generated per
# call, so it cannot be enumerated into an allow entry.
#
# The canary set is DERIVED FROM THE PATTERN'S OWN REGEX, never from a list
# maintained beside it: _scrub_alt_split cuts the class regex into its
# top-level alternatives and _scrub_sample_alt reverses each one into
# sample values, so a credential shape added to a pattern is canaried the
# moment it is added, with no second place to update. A hand-written canary
# table is exactly what let `gh[pousr]_[A-Za-z0-9]{20,}` — a third field
# that exempts every GitHub token in the scoped file — pass a lint whose
# only secret-shape canary was AKIA-shaped.
#
# Several samples come out of each alternative, because a third field only
# has to be narrower than the CLASS to be over-broad while still excusing
# every value of one shape:
#   * one per character flavour (full / lower / upper / digits) of each
#     variable run, so `/home/[a-z]+/` and `[0-9A-F-]{36}` are caught the
#     same way `.*` is;
#   * the upper- and lower-cased form of every sample, kept when it still
#     matches the class — that is what catches an upper-case-only UUID
#     regex in the case-folded uuid class;
#   * one sample per member of a short enumerable choice (`gh[pousr]_`,
#     `xox[abprs]-`, `dt0[cs]01`), cycled rather than sampled so the lint
#     cannot flip its verdict between runs.
# Every candidate is verified against the class regex before it is used, so
# a construct the generator reverses WRONGLY yields no canary instead of a
# bogus one.
#
# Three cases yield no canary, and all three mean NOT over-broad — this is
# a lint, and it never invents a finding it cannot substantiate:
#   * an alternative with no variable element at all. rdp-share is the
#     whole class: `/mnt/tsclient` and `\\tsclient` are fixed literals, so
#     every third field that suppresses anything is exactly as broad as the
#     alternative and there is no compliant form to demand. That decision
#     falls out of the regex instead of being asserted by name.
#   * an alternative the generator cannot reverse: a group `(...)`, a
#     negated or POSIX-named bracket (`[^x]`, `[[:alpha:]]`), a GNU
#     shorthand (`\w`, `\d`).
#   * a private (runtime-loaded, non-public) class, skipped by name before
#     its regex is even parsed. Private regexes are authored by the user
#     at runtime, not reviewed public source, and a derived canary can
#     land a finding the user has no way to satisfy — the third field
#     already IS the literal the class means, and there is nothing
#     narrower to demand. Public classes are unaffected: their regexes are
#     still parsed per alternative exactly as described above.
_SCRUB_ALNUM='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

# Sample built by _scrub_sample_alt, plus what it learned about the
# alternative: whether it has a variable element, and the size of the
# largest short enumerable choice in it (how many samples are needed to
# cover every member).
_SA_OUT=""
_SA_VARIABLE=0
_SA_MAXSET=0

_scrub_rand() {
  # $1 = length, $2 = character set. Appends to _SA_OUT rather than
  # printing: $RANDOM in a command substitution is not guaranteed to differ
  # from the parent's next value, and two identical runs inside one canary
  # would quietly halve its entropy.
  _sr_n="$1"
  _sr_set="$2"
  _sr_len=${#_sr_set}
  _sr_i=0
  while [ "$_sr_i" -lt "$_sr_n" ]; do
    _SA_OUT="$_SA_OUT${_sr_set:$((RANDOM % _sr_len)):1}"
    _sr_i=$((_sr_i + 1))
  done
}

# Printable ASCII in code order. Character ranges inside a bracket
# expression are expanded by slicing this string, and case folding walks
# the alphabets below — a canary set costs hundreds of characters, and a
# printf/tr fork per character is what made the lint the slowest part of a
# scan.
_SCRUB_ASCII=' !"#$%&'"'"'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~'
_SCRUB_LOWERS='abcdefghijklmnopqrstuvwxyz'
_SCRUB_UPPERS='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
_SCRUB_DIGITS='0123456789'

# _scrub_case_map <text> <upper|lower> -> _CM_OUT
_scrub_case_map() {
  case "$2" in
    upper) _cm_from="$_SCRUB_LOWERS"; _cm_to="$_SCRUB_UPPERS" ;;
    *)     _cm_from="$_SCRUB_UPPERS"; _cm_to="$_SCRUB_LOWERS" ;;
  esac
  _CM_OUT=""
  _cm_i=0
  _cm_n=${#1}
  while [ "$_cm_i" -lt "$_cm_n" ]; do
    _cm_c="${1:$_cm_i:1}"
    case "$_cm_from" in
      *"$_cm_c"*)
        _cm_pre="${_cm_from%%"$_cm_c"*}"
        _CM_OUT="$_CM_OUT${_cm_to:${#_cm_pre}:1}"
        ;;
      *) _CM_OUT="$_CM_OUT$_cm_c" ;;
    esac
    _cm_i=$((_cm_i + 1))
  done
}

# _scrub_class_end <regex> <index-of-open-bracket> -> _CE_OUT
# Index of the ']' that closes the bracket expression, honouring the POSIX
# rule that a ']' first in the expression (after an optional '^') is a
# literal. Returns 1 when the expression is unterminated.
_scrub_class_end() {
  _ce_re="$1"
  _ce_n=${#_ce_re}
  _ce_i=$(($2 + 1))
  if [ "${_ce_re:$_ce_i:1}" = "^" ]; then _ce_i=$((_ce_i + 1)); fi
  if [ "${_ce_re:$_ce_i:1}" = "]" ]; then _ce_i=$((_ce_i + 1)); fi
  while [ "$_ce_i" -lt "$_ce_n" ]; do
    if [ "${_ce_re:$_ce_i:1}" = "]" ]; then
      _CE_OUT="$_ce_i"
      return 0
    fi
    _ce_i=$((_ce_i + 1))
  done
  return 1
}

# _scrub_alt_split <regex>: the regex's top-level alternatives, one per
# line. A '|' inside a bracket expression, inside a group, or backslash-
# escaped does not split.
_scrub_alt_split() {
  _as_re="$1"
  _as_n=${#_as_re}
  _as_i=0
  _as_depth=0
  _as_cur=""
  while [ "$_as_i" -lt "$_as_n" ]; do
    _as_c="${_as_re:$_as_i:1}"
    case "$_as_c" in
      '\')
        _as_cur="$_as_cur${_as_re:$_as_i:2}"
        _as_i=$((_as_i + 2))
        continue
        ;;
      '[')
        _scrub_class_end "$_as_re" "$_as_i" || _CE_OUT=$((_as_n - 1))
        _as_cur="$_as_cur${_as_re:$_as_i:$((_CE_OUT - _as_i + 1))}"
        _as_i=$((_CE_OUT + 1))
        continue
        ;;
      '(') _as_depth=$((_as_depth + 1)) ;;
      ')') _as_depth=$((_as_depth - 1)) ;;
      '|')
        if [ "$_as_depth" -le 0 ]; then
          printf '%s\n' "$_as_cur"
          _as_cur=""
          _as_i=$((_as_i + 1))
          continue
        fi
        ;;
    esac
    _as_cur="$_as_cur$_as_c"
    _as_i=$((_as_i + 1))
  done
  printf '%s\n' "$_as_cur"
}

# _scrub_expand_class <bracket-body> -> _EC_OUT
# Every character the bracket matches. Returns 1 for a body no value can be
# safely drawn from (negated, or a POSIX named class).
_scrub_expand_class() {
  _ec_b="$1"
  case "$_ec_b" in
    ''|'^'*) return 1 ;;
    *'[:'*) return 1 ;;
  esac
  _ec_n=${#_ec_b}
  _ec_i=0
  _EC_OUT=""
  while [ "$_ec_i" -lt "$_ec_n" ]; do
    _ec_c="${_ec_b:$_ec_i:1}"
    if [ "${_ec_b:$((_ec_i + 1)):1}" = "-" ] && [ "$((_ec_i + 2))" -lt "$_ec_n" ]; then
      _ec_hi="${_ec_b:$((_ec_i + 2)):1}"
      case "$_SCRUB_ASCII" in *"$_ec_c"*) : ;; *) return 1 ;; esac
      case "$_SCRUB_ASCII" in *"$_ec_hi"*) : ;; *) return 1 ;; esac
      _ec_pre="${_SCRUB_ASCII%%"$_ec_c"*}"
      _ec_lo_n=${#_ec_pre}
      _ec_pre="${_SCRUB_ASCII%%"$_ec_hi"*}"
      _ec_hi_n=${#_ec_pre}
      [ "$_ec_lo_n" -le "$_ec_hi_n" ] || return 1
      _EC_OUT="$_EC_OUT${_SCRUB_ASCII:$_ec_lo_n:$((_ec_hi_n - _ec_lo_n + 1))}"
      _ec_i=$((_ec_i + 3))
      continue
    fi
    _EC_OUT="$_EC_OUT$_ec_c"
    _ec_i=$((_ec_i + 1))
  done
  [ -n "$_EC_OUT" ] || return 1
  return 0
}

# _scrub_flavor_set <set> <flavor> -> _FS_OUT
# <set> narrowed to one character flavour, falling back to the whole set
# when the narrowing is empty (so `dt0[cs]01` still yields a value under
# the "digit" flavour instead of losing the alternative).
_scrub_flavor_set() {
  case "$2" in
    lower) _fs_keep="$_SCRUB_LOWERS" ;;
    upper) _fs_keep="$_SCRUB_UPPERS" ;;
    digit) _fs_keep="$_SCRUB_DIGITS" ;;
    *)     _FS_OUT="$1"; return 0 ;;
  esac
  _FS_OUT=""
  _fs_i=0
  _fs_n=${#1}
  while [ "$_fs_i" -lt "$_fs_n" ]; do
    _fs_c="${1:$_fs_i:1}"
    case "$_fs_keep" in
      *"$_fs_c"*) _FS_OUT="$_FS_OUT$_fs_c" ;;
    esac
    _fs_i=$((_fs_i + 1))
  done
  [ -n "$_FS_OUT" ] || _FS_OUT="$1"
  return 0
}

# _scrub_sample_alt <alternative> <index> <flavor>
# Reverses ONE alternative of a class regex into a sample value in _SA_OUT,
# drawing variable runs from <flavor> and stepping short enumerable choices
# by <index> so a sweep of indexes covers every member. Also sets
# _SA_VARIABLE (0 when the alternative is a fixed literal) and _SA_MAXSET
# (the largest such choice). Returns 1 for anything it cannot reverse.
_scrub_sample_alt() {
  _sa_re="$1"
  _sa_idx="$2"
  _sa_fl="$3"
  _SA_OUT=""
  _SA_VARIABLE=0
  _SA_MAXSET=0
  _sa_n=${#_sa_re}
  _sa_i=0
  while [ "$_sa_i" -lt "$_sa_n" ]; do
    _sa_c="${_sa_re:$_sa_i:1}"
    _sa_set=""
    _sa_var=0
    case "$_sa_c" in
      '\')
        _sa_e="${_sa_re:$((_sa_i + 1)):1}"
        [ -n "$_sa_e" ] || return 1
        _sa_i=$((_sa_i + 2))
        case "$_sa_e" in
          '<'|'>'|'b'|'B') continue ;;
          w|W|s|S|d|D) return 1 ;;
          *) _sa_set="$_sa_e" ;;
        esac
        ;;
      '[')
        _scrub_class_end "$_sa_re" "$_sa_i" || return 1
        _sa_e="$_CE_OUT"
        _scrub_expand_class "${_sa_re:$((_sa_i + 1)):$((_sa_e - _sa_i - 1))}" || return 1
        _sa_set="$_EC_OUT"
        _sa_var=1
        _sa_i=$((_sa_e + 1))
        ;;
      '.')
        _sa_set="$_SCRUB_ALNUM"
        _sa_var=1
        _sa_i=$((_sa_i + 1))
        ;;
      '^'|'$')
        _sa_i=$((_sa_i + 1))
        continue
        ;;
      '('|')'|'|'|'*'|'+'|'?'|'{')
        return 1
        ;;
      *)
        _sa_set="$_sa_c"
        _sa_i=$((_sa_i + 1))
        ;;
    esac

    # Quantifier, if any. -1 max means unbounded.
    _sa_min=1
    _sa_max=1
    case "${_sa_re:$_sa_i:1}" in
      '*') _sa_min=0; _sa_max=-1; _sa_i=$((_sa_i + 1)) ;;
      '+') _sa_min=1; _sa_max=-1; _sa_i=$((_sa_i + 1)) ;;
      '?') _sa_min=0; _sa_max=1;  _sa_i=$((_sa_i + 1)) ;;
      '{')
        _sa_e="$_sa_i"
        while [ "$_sa_e" -lt "$_sa_n" ] && [ "${_sa_re:$_sa_e:1}" != "}" ]; do
          _sa_e=$((_sa_e + 1))
        done
        [ "$_sa_e" -lt "$_sa_n" ] || return 1
        _sa_q="${_sa_re:$((_sa_i + 1)):$((_sa_e - _sa_i - 1))}"
        case "$_sa_q" in
          *,*)
            _sa_min="${_sa_q%%,*}"
            _sa_max="${_sa_q#*,}"
            # `{,N}` (a GNU extension) leaves the min half empty; treat it
            # as 0 rather than let a later `-lt`/`-gt` on an empty string
            # print "integer expression expected" to stderr on every use.
            [ -n "$_sa_min" ] || _sa_min=0
            [ -n "$_sa_max" ] || _sa_max=-1
            ;;
          *) _sa_min="$_sa_q"; _sa_max="$_sa_q" ;;
        esac
        case "$_sa_min$_sa_max" in
          ''|*[!0-9-]*) return 1 ;;
        esac
        _sa_i=$((_sa_e + 1))
        ;;
    esac
    if [ "$_sa_max" != "$_sa_min" ]; then _sa_var=1; fi
    if [ "$_sa_var" -eq 1 ]; then _SA_VARIABLE=1; fi

    # How many characters to emit: the minimum the quantifier demands, but
    # enough of an unbounded run over a wide character set that the sample
    # cannot be guessed.
    _sa_cnt="$_sa_min"
    _sa_size=${#_sa_set}
    if [ "$_sa_max" -lt 0 ] && [ "$_sa_cnt" -lt 8 ] && [ "$_sa_size" -ge 10 ]; then
      _sa_cnt=8
    fi
    [ "$_sa_cnt" -gt 0 ] || continue
    if [ "$_sa_size" -eq 1 ]; then
      _sa_r=0
      while [ "$_sa_r" -lt "$_sa_cnt" ]; do
        _SA_OUT="$_SA_OUT$_sa_set"
        _sa_r=$((_sa_r + 1))
      done
    elif [ "$_sa_cnt" -eq 1 ] && [ "$_sa_size" -le 12 ]; then
      # A short one-of-N choice — the shape selector in `gh[pousr]_` or
      # `xox[abprs]-`. Stepped by index over the FULL set (not the
      # flavoured one) so a sweep covers every member exactly once: a
      # random pick here would flag `ghp_...` only four times in five.
      if [ "$_sa_size" -gt "$_SA_MAXSET" ]; then _SA_MAXSET="$_sa_size"; fi
      _SA_OUT="$_SA_OUT${_sa_set:$((_sa_idx % _sa_size)):1}"
    else
      _scrub_flavor_set "$_sa_set" "$_sa_fl"
      _scrub_rand "$_sa_cnt" "$_FS_OUT"
    fi
  done
  return 0
}

# The canary set is regenerated on every call, so it cannot be enumerated
# into an allow entry.
_SCRUB_CAN_FLAVORS="full lower upper digit"

# _scrub_canaries <pattern-name>: freshly generated values of that class,
# one per line, derived from the class's own regex. Empty output means "no
# canary for this class" — treated as NOT over-broad by every caller.
_scrub_canaries() {
  _sc_name="$1"

  _sc_cand=""
  _sc_pat="$(pattern_regex "$_sc_name")"
  _sc_ci="$(pattern_ci "$_sc_name")"
  if [ -n "$_sc_pat" ] && _scrub_pattern_is_public "$_sc_name"; then
    while IFS= read -r _sc_alt; do
      [ -n "$_sc_alt" ] || continue
      # Probe pass: is this alternative reversible at all, is it more than
      # a fixed literal, and how many samples cover its enumerable choices?
      _scrub_sample_alt "$_sc_alt" 0 full || continue
      [ "$_SA_VARIABLE" -eq 1 ] || continue
      _sc_reps=4
      [ "$_SA_MAXSET" -gt "$_sc_reps" ] && _sc_reps="$_SA_MAXSET"
      _sc_k=0
      while [ "$_sc_k" -lt "$_sc_reps" ]; do
        set -- $_SCRUB_CAN_FLAVORS
        shift $((_sc_k % 4))
        _scrub_sample_alt "$_sc_alt" "$_sc_k" "$1" || break
        _sc_v="$_SA_OUT"
        if [ -n "$_sc_v" ]; then
          _scrub_case_map "$_sc_v" upper
          _sc_up="$_CM_OUT"
          _scrub_case_map "$_sc_v" lower
          _sc_cand="$_sc_cand$_sc_v
$_sc_up
$_CM_OUT
"
        fi
        _sc_k=$((_sc_k + 1))
      done
    done <<EOF
$(_scrub_alt_split "$_sc_pat")
EOF
  fi

  # Keep only candidates the class actually matches: a construct reversed
  # wrongly must cost a canary, never produce a false one. Then de-dup, so
  # the case variants of an all-digit sample do not triple the work.
  _sc_out=""
  if [ -n "$_sc_cand" ]; then
    if [ "$_sc_ci" = "1" ]; then
      _sc_ok="$(printf '%s' "$_sc_cand" | grep -E -i -- "$_sc_pat" 2>/dev/null)"
    else
      _sc_ok="$(printf '%s' "$_sc_cand" | grep -E -- "$_sc_pat" 2>/dev/null)"
    fi
    while IFS= read -r _sc_v; do
      [ -n "$_sc_v" ] || continue
      case "
$_sc_out" in
        *"
$_sc_v
"*) continue ;;
      esac
      _sc_out="$_sc_out$_sc_v
"
    done <<EOF
$_sc_ok
EOF
  fi

  printf '%s' "$_sc_out"
}

# scrub_allow_overbroad <pattern-name> <match-regex>
# 0 (true) when the third field would ALSO excuse a value nobody has seen
# yet. False (1) when it would not, when the class has no canary, and when
# the pattern is not loaded — this is a lint, and it never invents a
# finding it cannot substantiate.
scrub_allow_overbroad() {
  _ao_name="$1"
  _ao_m="$2"
  [ -n "$_ao_m" ] || return 1
  # First loaded regex of that name is enough: a private entry extending a
  # generic class does not change the shape the canary is built from.
  _ao_pat="$(pattern_regex "$_ao_name")" || return 1
  [ -n "$_ao_pat" ] || return 1
  _ao_ci="$(pattern_ci "$_ao_name")"
  _ao_list="$(_scrub_canaries "$_ao_name")"
  [ -n "$_ao_list" ] || return 1
  # The whole canary set is tested in ONE pass: sed applies the third field
  # line by line, exactly as _scrub_value_allowed applies it to a single
  # excerpt, so a canary the entry would excuse is a line the class no
  # longer matches. Same verdict as one _scrub_value_allowed call per
  # canary, minus two processes per canary — a derived canary set is dozens
  # of values, and this runs once per allow entry on every scan.
  _ao_d="$(printf '\a')"
  _ao_rest="$(printf '%s\n' "$_ao_list" | sed -E "s${_ao_d}${_ao_m}${_ao_d} ${_ao_d}g" 2>/dev/null)" || return 1
  # Fail closed the way _scrub_value_allowed does: an unusable third field
  # excuses nothing, so it is not over-broad either.
  if [ "$_ao_ci" = "1" ]; then
    printf '%s\n' "$_ao_rest" | grep -qvE -i -- "$_ao_pat" 2>/dev/null && return 0
  else
    printf '%s\n' "$_ao_rest" | grep -qvE -- "$_ao_pat" 2>/dev/null && return 0
  fi
  return 1
}

_scrub_load_public_examples() {
  SCRUB_PUBEX=()
  SCRUB_PUBEX_N=0
  _lpe_path="${SCRUB_PUBLIC_EXAMPLES:-$SCRUB_PUBLIC_EXAMPLES_DEFAULT}"
  [ -f "$_lpe_path" ] || return 0
  while IFS= read -r _lpe_line || [ -n "$_lpe_line" ]; do
    _lpe_line="${_lpe_line%$'\r'}"
    case "$_lpe_line" in
      ''|'#'*) continue ;;
    esac
    SCRUB_PUBEX[$SCRUB_PUBEX_N]="$_lpe_line"
    SCRUB_PUBEX_N=$((SCRUB_PUBEX_N + 1))
  done < "$_lpe_path"
  return 0
}

# pattern_exists <name>: 0 when <name> is a CURRENTLY LOADED pattern.
pattern_exists() {
  _pe_i=0
  while [ "$_pe_i" -lt "$SCRUB_PAT_N" ]; do
    if [ "${SCRUB_PAT_NAME[$_pe_i]}" = "$1" ]; then
      return 0
    fi
    _pe_i=$((_pe_i + 1))
  done
  return 1
}

# _scrub_public_examples_ok <text>: 0 when <text> contains nothing
# credential-shaped, or everything credential-shaped in it is a documented
# public example. Fail closed: an unreadable/absent examples list means any
# credential shape at all fails this test.
_scrub_public_examples_ok() {
  _pxo_t="$1"
  _pxo_secret="$(pattern_regex secret-shape)"
  [ -n "$_pxo_secret" ] || return 1
  printf '%s' "$_pxo_t" | grep -qE -- "$_pxo_secret" 2>/dev/null || return 0
  _pxo_d="$(printf '\a')"
  _pxo_rest="$_pxo_t"
  _pxo_i=0
  while [ "$_pxo_i" -lt "$SCRUB_PUBEX_N" ]; do
    _pxo_rest="$(printf '%s' "$_pxo_rest" | sed -E "s${_pxo_d}${SCRUB_PUBEX[$_pxo_i]}${_pxo_d} ${_pxo_d}g" 2>/dev/null)" || return 1
    _pxo_i=$((_pxo_i + 1))
  done
  printf '%s' "$_pxo_rest" | grep -qE -- "$_pxo_secret" 2>/dev/null && return 1
  return 0
}

# --- allow-file field-level exemption ---------------------------------------
# An allow file is itself scanned like every other file — skipping it
# wholesale would make it a laundering channel: park a credential in
# scrub-allow.txt and no scanner ever looks at it again. But its ENTRY
# lines legitimately have to spell out the value an exception is scoped to,
# in the THIRD field. So the exemption is field-level, not file-level:
#
#   * comment lines and blank lines            -> scanned in full
#   * an entry with no match-regex             -> scanned in full
#   * an entry "name:path:match"               -> only "name:path" is
#                                                 scanned; the match-regex
#                                                 field is exempt
#
# A secret in a comment, or smuggled into the name or path field, is still
# a hit. Callers set ALLOW_FILE_REL to the normalized path of the allow
# file so a hit can be attributed to it.
ALLOW_FILE_REL=""

# scrub_allow_field_exempt <scan-name> <regex> <ci> <content-line>
# 0 (true) when <content-line> is an allow-file entry line whose denylist
# match lives entirely in the match-regex field, for a scan of the pattern
# the entry itself names.
scrub_allow_field_exempt() {
  _ae_scan_name="$1"
  _ae_re="$2"
  _ae_ci="$3"
  _ae_line="$4"
  case "$_ae_line" in
    ''|'#'*) return 1 ;;
  esac
  # Three fields means a match-regex is present (a path-regex may not
  # contain a colon, so the second colon always starts the third field).
  case "$_ae_line" in
    *:*:*) : ;;
    *) return 1 ;;
  esac
  _ae_name="${_ae_line%%:*}"
  _ae_rest="${_ae_line#*:}"
  _ae_path="${_ae_rest%%:*}"
  _ae_val="${_ae_rest#*:}"
  # An unknown pattern name is not an allow entry this scanner recognises —
  # it is just a line of text that happens to contain colons, and inventing
  # a name is the cheapest way to get a third field. Scan the whole line.
  pattern_exists "$_ae_name" || return 1
  # The exemption is bound to the pattern being scanned RIGHT NOW, not to
  # "some loaded pattern". Accepting any loaded name laundered values
  # across classes: an entry "uuid:^fixture$:<employer name>" is a
  # perfectly ordinary-looking uuid exception, and while it excuses nothing
  # during the uuid scan, a name-agnostic test also excused its third field
  # during the employer scan — so the employer name sat in a committed file
  # that no scanner would report.
  [ "$_ae_name" = "$_ae_scan_name" ] || return 1
  # An empty third field exempts nothing.
  [ -n "$_ae_val" ] || return 1
  # The third field is itself scanned for credential shapes: without this,
  # "only the third field is exempt" still lets a real key be laundered in
  # by parking it there. Documented public examples are the only pass.
  _scrub_public_examples_ok "$_ae_val" || return 1
  _ae_scan="$_ae_name:$_ae_path"
  if [ "$_ae_ci" = "1" ]; then
    printf '%s' "$_ae_scan" | grep -qiE -- "$_ae_re" 2>/dev/null && return 1
  else
    printf '%s' "$_ae_scan" | grep -qE -- "$_ae_re" 2>/dev/null && return 1
  fi
  return 0
}

is_allowed() {
  # $1 pattern name, $2 file path, $3 excerpt (opt), $4 pattern regex (opt),
  # $5 ci (opt). Reads $ALLOW_FILE (may be unset/empty). Sets
  # ALLOW_MATCH_LINE on success.
  ALLOW_MATCH_LINE=""
  [ -n "${ALLOW_FILE:-}" ] || return 1
  _ia_name="$1"
  _ia_file="$2"
  _ia_ex="${3-}"
  _ia_re="${4-}"
  _ia_ci="${5-0}"
  _ia_no=0
  while IFS= read -r _ia_line || [ -n "$_ia_line" ]; do
    _ia_no=$((_ia_no + 1))
    case "$_ia_line" in
      ''|'#'*) continue ;;
    esac
    _ia_aname="${_ia_line%%:*}"
    [ "$_ia_aname" = "$_ia_name" ] || continue
    _ia_arest="${_ia_line#*:}"
    case "$_ia_arest" in
      *:*)
        _ia_apath="${_ia_arest%%:*}"
        _ia_aval="${_ia_arest#*:}"
        _ia_hasval=1
        ;;
      *)
        _ia_apath="$_ia_arest"
        _ia_aval=""
        _ia_hasval=0
        ;;
    esac
    printf '%s' "$_ia_file" | grep -Eq -- "$_ia_apath" 2>/dev/null || continue
    # An entry written WITH a third field that is empty allows nothing: the
    # author meant to scope it to a value and left the value out. Falling
    # back to "allow the whole file" there would silently turn the most
    # careful form of the syntax into the least careful one.
    if [ "$_ia_hasval" -eq 1 ] && [ -z "$_ia_aval" ]; then
      continue
    fi
    if [ "$_ia_hasval" -eq 0 ]; then
      ALLOW_MATCH_LINE="$_ia_no"
      return 0
    fi
    if _scrub_value_allowed "$_ia_aval" "$_ia_ex" "$_ia_re" "$_ia_ci"; then
      ALLOW_MATCH_LINE="$_ia_no"
      return 0
    fi
  done < "$ALLOW_FILE"
  return 1
}
