#!/usr/bin/env bash
# ledger.sh — the coordinator's only writer of partner-session state.
#
#   ledger.sh path <KEY>                                  print the ledger path, create its directory
#   ledger.sh lock <ledger> <own-session-id> <agents.json> take the run lock; prints owner=<sid>:<nonce>
#   ledger.sh unlock <ledger>                             release the run lock
#   ledger.sh init <ledger> <KEY> <ticket-branch> <coord-name> <coord-session-id> <issues.json>
#   ledger.sh get <ledger> [<n>]                          the state (or one issue) as JSON
#   ledger.sh intent <ledger> launch|relaunch <n> <session-name> <worktree> <branch> <base-sha>
#   ledger.sh intent <ledger> merge <n> <candidate-sha> <expected-head>   prints intent=<id>
#   ledger.sh event <ledger> <n> <event> [args]           the only way statuses change
#   ledger.sh outbox <ledger>                             <n>\t<gen>\t<line> per pending entry
#   ledger.sh slots <ledger>                              live count (frontier.sh --live-count)
#   ledger.sh done <ledger>                               handback | cancel-ticket; exit 1 = not done
#   ledger.sh summary <ledger>                            Markdown table for the PR body
#
# The ledger is <git-common-dir>/partner-sessions/<KEY>/ledger.json; the run lock
# (lock/holder = "<session-id> <nonce>"), the transient takeover/ directory and the
# append-only ledger.log are its siblings. Every mutating call (unlock, init,
# intent, event) needs PS_OWNER=<sid>:<nonce> matching lock/holder, computes the
# whole new state with one jq program (ledger.jq, beside this script) and writes
# it with temp file + mv -f.
#
# Exit: 0 applied (prints the new status or the requested output), 10 idempotent
# no-op, 20 message rejected, 30 illegal transition refused (logged), 40 lock held
# by a live other session or PS_OWNER no longer matches (prints holder=), 2 usage
# or I/O error. `done` exits 1 for "not done".
#
# PS_LOCK_TEST_PAUSE=<file> (tests only): `lock` pauses after its liveness check
# until <file> exists, so a test can finish a rival takeover inside that window.
# PS_WRITE_TEST_PAUSE=<file> (tests only): a ledger write pauses between its
# owner check and its mv until <file> exists. Both hooks are inert unless set.
#
# Never calls claude or gh; free text is passed to jq with --arg, never evaluated.
# Bash 3.2 compatible.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
FRONTIER="$DIR/frontier.sh"
LJQ="$DIR/ledger.jq"

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
die() { echo "ledger.sh: $*" >&2; exit 2; }

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_sha() { [ "${#1}" -eq 40 ] && case "$1" in *[!0-9a-f]*) return 1 ;; *) return 0 ;; esac; }
is_branch() {
  case "$1" in [a-z0-9]*) ;; *) return 1 ;; esac
  case "$1" in *[!a-z0-9._/-]*) return 1 ;; esac
  git check-ref-format --branch "$1" >/dev/null 2>&1
}
# A session ID or name: non-empty, no whitespace, no ':'.
is_word() {
  [ -n "$1" ] || return 1
  case "$1" in *[[:space:]:]*) return 1 ;; esac
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

TMPD=""
cleanup() {
  [ -n "$TMPD" ] && rm -rf "$TMPD"
  [ -n "${LTMP:-}" ] && rm -f "$LTMP"
  return 0
}
trap cleanup EXIT
tmpdir() { [ -n "$TMPD" ] || TMPD="$(mktemp -d "${TMPDIR:-/tmp}/ledger.XXXXXX")" || die "mktemp failed"; }

# set_paths <ledger> — L, D, LOCK, TK, LOG.
set_paths() {
  L="$1"
  [ -n "$L" ] || usage
  D="$(dirname "$L")"
  LOCK="$D/lock"
  TK="$D/takeover"
  LOG="$D/ledger.log"
}

# logl <words...> — one line in ledger.log; tabs and newlines folded to spaces.
logl() {
  printf '%s %s\n' "$(now)" "$(printf '%s' "$*" | tr '\t\n\r' '   ')" >>"$LOG" 2>/dev/null || true
}

need_ledger() { [ -f "$L" ] && jq -e 'type == "object"' "$L" >/dev/null 2>&1 || die "no readable ledger at $L"; }

# ------------------------------------------------------------------ run lock

HSID=""
HNONCE=""
read_holder() {
  HSID=""; HNONCE=""
  [ -f "$LOCK/holder" ] || return 0
  read -r HSID HNONCE <"$LOCK/holder" || true
  return 0
}

mknonce() {
  od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

# is_live <session-id> — own session, or listed in $AG with a live process
# (`kill -0 <pid>`), or listed without a pid and a state other than
# stopped/failed/done (Task 1: a row with no pid and state done has ended).
is_live() {
  [ -n "$1" ] || return 1
  [ "$1" = "$OWN" ] && return 0
  rows="$(jq -r --arg s "$1" '.[] | select(.sessionId == $s)
           | if (.pid // null) != null then "pid \(.pid)" else "state \(.state // "")" end' "$AG")" || return 1
  [ -n "$rows" ] || return 1
  live=1
  while read -r kind val; do
    case "$kind" in
      pid) is_num "$val" && kill -0 "$val" 2>/dev/null && live=0 ;;
      state) case "$val" in stopped|failed|done) ;; *) live=0 ;; esac ;;
    esac
  done <<EOF
$rows
EOF
  return "$live"
}

# takeover_stale — the existing takeover/ was left by a crash: its owner is not
# live (or is this session, from an earlier interrupted attempt), or it has no
# owner and is older than 60 s.
takeover_stale() {
  o=""
  [ -f "$TK/owner" ] && read -r o <"$TK/owner"
  if [ -n "$o" ]; then
    [ "$o" = "$OWN" ] && return 0
    is_live "$o" && return 1
    return 0
  fi
  [ -n "$(find "$TK" -maxdepth 0 -mmin +1 2>/dev/null)" ]
}

# take_mutex — mkdir takeover/ (the exclusive step), then write its owner.
take_mutex() {
  if ! mkdir "$TK" 2>/dev/null; then
    takeover_stale || return 1
    rm -rf "$TK"
    logl "takeover-stale-removed by=$OWN"
    mkdir "$TK" 2>/dev/null || return 1
  fi
  printf '%s\n' "$OWN" >"$TK/owner.tmp.$$" && mv -f "$TK/owner.tmp.$$" "$TK/owner"
}

cmd_lock() {
  [ "$#" -eq 3 ] || usage
  set_paths "$1"; OWN="$2"; AG="$3"
  is_word "$OWN" || die "bad session id: $OWN"
  [ -f "$AG" ] && jq -e 'type == "array"' "$AG" >/dev/null 2>&1 || die "agents.json must be a JSON array: $AG"
  [ -d "$D" ] || die "no ledger directory $D (run ledger.sh path first)"

  fresh=0
  mkdir "$LOCK" 2>/dev/null && fresh=1
  read_holder
  if [ "$fresh" -eq 0 ] && [ -n "$HSID" ] && [ "$HSID" = "$OWN" ] && [ -n "$HNONCE" ]; then
    echo "owner=$OWN:$HNONCE"
    exit 0
  fi
  if [ "$fresh" -eq 0 ] && [ "$HSID" != "$OWN" ] && is_live "$HSID"; then
    logl "refused lock by=$OWN holder=$HSID"
    echo "holder=$HSID"
    exit 40
  fi
  # Test hook: hold a contender between its liveness check and the takeover.
  if [ -n "${PS_LOCK_TEST_PAUSE:-}" ]; then
    : >"$PS_LOCK_TEST_PAUSE.waiting"
    w=0
    while [ ! -e "$PS_LOCK_TEST_PAUSE" ] && [ "$w" -lt 200 ]; do sleep 0.05; w=$((w + 1)); done
  fi
  if ! take_mutex; then
    o=""; [ -f "$TK/owner" ] && read -r o <"$TK/owner"
    logl "refused lock by=$OWN takeover-in-progress owner=${o:-none}"
    echo "holder=$HSID"
    exit 40
  fi
  # Under takeover/: re-check, write a fresh holder, confirm it.
  old="$HSID"
  read_holder
  if [ -n "$HSID" ] && [ "$HSID" != "$old" ] && is_live "$HSID"; then
    rm -rf "$TK"
    logl "refused lock by=$OWN holder=$HSID"
    echo "holder=$HSID"
    exit 40
  fi
  old="$HSID"
  nonce="$(mknonce)"
  [ -n "$nonce" ] || { rm -rf "$TK"; die "no nonce"; }
  mkdir -p "$LOCK" || { rm -rf "$TK"; die "cannot create $LOCK"; }
  if ! { printf '%s %s\n' "$OWN" "$nonce" >"$LOCK/holder.tmp.$$" && mv -f "$LOCK/holder.tmp.$$" "$LOCK/holder"; }; then
    rm -f "$LOCK/holder.tmp.$$"; rm -rf "$TK"; die "cannot write $LOCK/holder"
  fi
  read_holder
  if [ "$HSID" != "$OWN" ] || [ "$HNONCE" != "$nonce" ]; then
    rm -rf "$TK"
    logl "refused lock by=$OWN lost-race holder=$HSID"
    echo "holder=$HSID"
    exit 40
  fi
  rm -rf "$TK"
  if [ "$fresh" -eq 1 ]; then
    logl "lock-acquired holder=$OWN"
  else
    logl "lock-takeover old=${old:-none} new=$OWN"
  fi
  echo "owner=$OWN:$nonce"
}

# owner_check — PS_OWNER must equal lock/holder; else print holder= and exit 40.
owner_check() {
  read_holder
  want="${PS_OWNER:-}"
  if [ -z "$want" ] || [ -z "$HSID" ] || [ "$want" != "$HSID:$HNONCE" ]; then
    logl "refused ${CMD:-write}: PS_OWNER does not hold the lock (holder=${HSID:-none})"
    echo "holder=$HSID"
    exit 40
  fi
}

cmd_unlock() {
  [ "$#" -eq 1 ] || usage
  set_paths "$1"
  owner_check
  rm -rf "$LOCK" || die "cannot remove $LOCK"
  logl "unlock holder=$HSID"
  echo "unlocked"
}

# ------------------------------------------------------------------ writes

# write_state <file> — validate, re-check the owner, then mv -f over the ledger.
# The check and the mv are not atomic, so the holder is read again after the
# mv: a takeover that landed in between means this coordinator has lost the
# lock and wrote once more; it logs that and exits 40 so it stops.
write_state() {
  LTMP="$L.tmp.$$"
  cat "$1" >"$LTMP" || die "cannot write $LTMP"
  jq -e 'type == "object"' "$LTMP" >/dev/null 2>&1 || die "refusing to write an invalid ledger"
  owner_check
  # Test hook: hold the writer between its owner check and the mv.
  if [ -n "${PS_WRITE_TEST_PAUSE:-}" ]; then
    : >"$PS_WRITE_TEST_PAUSE.waiting"
    w=0
    while [ ! -e "$PS_WRITE_TEST_PAUSE" ] && [ "$w" -lt 200 ]; do sleep 0.05; w=$((w + 1)); done
  fi
  mv -f "$LTMP" "$L" || die "cannot replace $L"
  LTMP=""
  read_holder
  if [ "${PS_OWNER:-}" != "$HSID:$HNONCE" ]; then
    logl "write-after-takeover by ${PS_OWNER%%:*} (${CMD:-write}) holder=${HSID:-none}"
    echo "holder=$HSID"
    exit 40
  fi
}

# ------------------------------------------------------------------ path / init / get

cmd_path() {
  [ "$#" -eq 1 ] || usage
  case "$1" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) die "bad key: $1" ;; esac
  gd="$(git rev-parse --git-common-dir 2>/dev/null)" || die "not in a git repository"
  gd="$(cd "$gd" && pwd -P)" || die "cannot resolve $gd"
  mkdir -p "$gd/partner-sessions/$1" || die "cannot create $gd/partner-sessions/$1"
  echo "$gd/partner-sessions/$1/ledger.json"
}

cmd_init() {
  [ "$#" -eq 6 ] || usage
  set_paths "$1"
  key="$2"; tb="$3"; cname="$4"; csid="$5"; issues="$6"
  owner_check
  [ ! -e "$L" ] || die "ledger already exists: $L"
  is_branch "$tb" || die "bad ticket branch: $tb"
  is_word "$cname" || die "bad coordinator name: $cname"
  is_word "$csid" || die "bad coordinator session id: $csid"
  [ -f "$issues" ] || die "no issues file: $issues"
  jq -e 'type == "array" and length > 0 and all(.[];
           (.n | type == "number" and . >= 1 and . == floor)
           and ((.blockers // []) | type == "array" and all(.[]; type == "number"))
           and ((.external // []) | type == "array"
                and all(.[]; (.n | type == "number") and (.closed | type == "boolean")))
           and (.branch | type == "string") and ((.testCmd // "") | type == "string")
           and ((.ac // []) | type == "array"))
         and ((map(.n) | unique | length) == length)' "$issues" >/dev/null 2>&1 \
    || die "issues.json must be a non-empty array of {n, blockers, external, branch, testCmd, ac}"
  # Every in-ticket blocker must be an issue of the set (external blockers are separate).
  jq -e 'map(.n) as $ns | all(.[]; all((.blockers // [])[]; . as $b | $ns | index([$b]) != null))' \
    "$issues" >/dev/null 2>&1 || die "issues.json: a blocker is not an issue of this ticket (use external)"
  tmpdir
  jq --arg key "$key" --arg tb "$tb" --arg cname "$cname" --arg csid "$csid" '
    { key: $key, ticketBranch: $tb,
      coordinator: { name: $cname, sessionId: $csid },
      cap: 3, canary: "pending",
      issues: (reduce .[] as $i ({};
        .[($i.n | tostring)] = {
          status: "pending", gen: 0,
          blockers: ($i.blockers // []), external: ($i.external // []),
          branch: $i.branch, testCmd: ($i.testCmd // ""), ac: ($i.ac // []),
          sessionName: null, sessionId: null, worktree: null, startSha: null,
          claim: null, rework: 0, resyncs: 0, mergeSha: null,
          gateResults: [], reason: null })),
      intents: [], outbox: [] }' "$issues" >"$TMPD/new.json" || die "cannot build ledger"
  write_state "$TMPD/new.json"
  logl "init key=$key issues=$(jq -c '[.[].n]' "$issues")"
  echo "pending"
}

cmd_get() {
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
  set_paths "$1"
  need_ledger
  if [ "$#" -eq 2 ]; then
    is_num "$2" || usage
    jq -e --arg n "$2" '.issues[$n] // empty' "$L" || die "no issue #$2"
  else
    jq . "$L"
  fi
}

# ------------------------------------------------------------------ shared jq

# ljq <op> [jq options...] — run program <op> of ledger.jq on the ledger
# (`jq -f`); every program returns {rc, out: [lines], reason, state}.
ljq() {
  op="$1"; shift
  jq --arg op "$op" "$@" -f "$LJQ" "$L"
}

# live_keys — JSON array of live issue keys, each judged by frontier.sh --live-count
# (the single definition of "live", ruling F7).
live_keys() {
  tmpdir
  keys="$(jq -r '.issues | keys[]' "$L")" || die "cannot read $L"
  lk="["; sep=""
  for k in $keys; do
    jq --arg k "$k" '{issues: {($k): .issues[$k]}}' "$L" >"$TMPD/one.json" || die "cannot read $L"
    c="$("${BASH:-bash}" "$FRONTIER" --live-count "$TMPD/one.json")" || die "frontier.sh --live-count failed"
    if [ "$c" = 1 ]; then lk="$lk$sep\"$k\""; sep=","; fi
  done
  printf '%s]' "$lk"
}

# apply <what> <result.json> — act on a jq result: write, print, log, exit.
apply() {
  what="$1"; res="$2"
  rc="$(jq -r '.rc' "$res")" || die "internal error"
  case "$rc" in
    0)
      jq '.state' "$res" >"$TMPD/state.json" || die "internal error"
      write_state "$TMPD/state.json"
      jq -r '.out[]' "$res"
      logl "applied $what -> $(jq -r '.out | join(" ")' "$res")"
      exit 0 ;;
    10)
      echo "noop: $(jq -r '.reason' "$res")" >&2
      exit 10 ;;
    30)
      reason="$(jq -r '.reason' "$res")"
      logl "refused $what: $reason"
      case "$reason" in cycle:*) echo "$reason" ;; esac
      echo "refused: $reason" >&2
      exit 30 ;;
    *)
      die "$what: $(jq -r '.reason' "$res")" ;;
  esac
}

# ------------------------------------------------------------------ intents

cmd_intent() {
  [ "$#" -ge 3 ] || usage
  set_paths "$1"; kind="$2"; n="$3"
  CMD="intent $kind #$n"
  need_ledger
  owner_check
  is_num "$n" || usage
  jq -e --arg n "$n" '.issues | has($n)' "$L" >/dev/null || die "no issue #$n"
  tmpdir
  case "$kind" in
    launch|relaunch)
      [ "$#" -eq 7 ] || usage
      name="$4"; wt="$5"; br="$6"; base="$7"
      is_word "$name" || die "bad session name: $name"
      [ -n "$wt" ] || die "empty worktree"
      is_branch "$br" || die "bad branch: $br"
      is_sha "$base" || die "bad base sha: $base"
      live="$(live_keys)"
      ljq intent-launch --arg n "$n" --arg kind "$kind" --arg name "$name" --arg wt "$wt" --arg br "$br" \
         --arg base "$base" --argjson live "$live" >"$TMPD/res.json" || die "internal error"
      ;;
    merge)
      [ "$#" -eq 5 ] || usage
      cand="$4"; exp="$5"
      is_sha "$cand" || die "bad candidate sha: $cand"
      is_sha "$exp" || die "bad expected head: $exp"
      ljq intent-merge --arg n "$n" --arg cand "$cand" --arg exp "$exp" --argjson live '[]' \
        >"$TMPD/res.json" || die "internal error"
      ;;
    *) usage ;;
  esac
  apply "intent $kind #$n" "$TMPD/res.json"
}

# ------------------------------------------------------------------ events

cmd_event() {
  [ "$#" -ge 3 ] || usage
  set_paths "$1"; n="$2"; ev="$3"; shift 3
  CMD="event #$n $ev"
  need_ledger
  owner_check
  is_num "$n" || usage
  a1="${1-}"; a2="${2-}"; a3="${3-}"
  edge="ok"; anc="no"; tip=""
  case "$ev" in
    launch|relaunch) [ "$#" -eq 2 ] && [ -n "$a1" ] && is_word "$a2" || usage ;;
    launch-failed) [ "$#" -eq 1 ] && [ -n "$a1" ] || usage ;;
    queue-check)
      case "$a1" in
        stale) [ "$#" -eq 2 ] && is_sha "$a2" || die "queue-check stale needs a 40-hex head" ;;
        ok) [ "$#" -eq 1 ] || usage ;;
        *) usage ;;
      esac ;;
    gate)
      case "$a1" in
        merged) [ "$#" -ge 2 ] && [ "$#" -le 3 ] && [ -n "$a2" ] || usage ;;
        resync) [ "$#" -ge 2 ] && [ "$#" -le 3 ] && is_sha "$a2" || die "gate resync needs a 40-hex head" ;;
        fail) [ "$#" -le 2 ] || usage ;;
        *) usage ;;
      esac ;;
    stuck-accept)
      [ "$#" -eq 1 ] && is_num "$a1" || usage
      tmpdir
      if ! "${BASH:-bash}" "$FRONTIER" --check-edge "$L" "$n" "$a1" >/dev/null 2>"$TMPD/edge"; then
        edge="$(grep '^cycle:' "$TMPD/edge" | head -n 1)"
        [ -n "$edge" ] || die "frontier.sh --check-edge failed: $(cat "$TMPD/edge")"
      fi ;;
    edge-remove|wake-failed|canary-passed|user-merged) [ "$#" -eq 0 ] || usage ;;
    drop|cancel-ticket) [ "$#" -le 1 ] || usage ;;
    json)
      [ "$#" -eq 1 ] || usage
      case "$a1" in failed|stopped|blocked|done|working) ;; *) usage ;; esac ;;
    *) die "unknown event: $ev" ;;
  esac
  if [ "$ev" != "cancel-ticket" ]; then
    jq -e --arg n "$n" '.issues | has($n)' "$L" >/dev/null || die "no issue #$n"
  fi
  if [ "$ev" = "user-merged" ]; then
    # The ledger lives in <git-common-dir>/partner-sessions/<KEY>/.
    gd="$(cd "$D/../.." && pwd -P)" || die "cannot resolve the git dir"
    br="$(jq -r --arg n "$n" '.issues[$n].branch' "$L")"
    tb="$(jq -r '.ticketBranch' "$L")"
    tip="$(git --git-dir="$gd" rev-parse -q --verify "refs/heads/$br^{commit}" 2>/dev/null)" || tip=""
    if [ -n "$tip" ] && git --git-dir="$gd" merge-base --is-ancestor "$tip" "refs/heads/$tb" 2>/dev/null; then
      anc="yes"
    fi
  fi
  live="$(live_keys)"
  tmpdir
  ljq event --arg n "$n" --arg ev "$ev" --arg a1 "$a1" --arg a2 "$a2" --arg a3 "$a3" \
     --arg edge "$edge" --arg anc "$anc" --arg tip "$tip" --argjson live "$live" \
     >"$TMPD/res.json" || die "internal error"
  apply "event #$n $ev" "$TMPD/res.json"
}

# ------------------------------------------------------------------ read-only reports

cmd_outbox() {
  [ "$#" -eq 1 ] || usage
  set_paths "$1"; need_ledger
  jq -r '.outbox[] | "\(.n)\t\(.gen)\t\(.line)"' "$L"
}

cmd_slots() {
  [ "$#" -eq 1 ] || usage
  set_paths "$1"; need_ledger
  "${BASH:-bash}" "$FRONTIER" --live-count "$L"
}

cmd_done() {
  [ "$#" -eq 1 ] || usage
  set_paths "$1"; need_ledger
  r="$(jq -r '[.issues[].status] as $s
    | if ($s | length) > 0 and all($s[]; . == "cancelled") then "cancel-ticket"
      elif all($s[]; . == "merged" or . == "cancelled") and any($s[]; . == "merged") then "handback"
      else "" end' "$L")" || die "cannot read $L"
  [ -n "$r" ] || exit 1
  echo "$r"
}

cmd_summary() {
  [ "$#" -eq 1 ] || usage
  set_paths "$1"; need_ledger
  echo "| Issue | Status | Branch | Merge SHA | Rework | Resyncs | Gate results | Reason |"
  echo "|---|---|---|---|---|---|---|---|"
  jq -r '
    def cell: tostring | gsub("[\t\r\n]+"; " ") | gsub("\\|"; "\\|");
    .issues | to_entries | sort_by(.key | tonumber)[]
    | .value as $v
    | ([ ($v.gateResults // [])[]
         | .result + (if (.text // "") == "" then "" else ": " + .text end) ] | join("; ")) as $g
    | "| #\(.key) | \($v.status | cell) | \($v.branch // "" | cell) | \($v.mergeSha // "" | cell) | \($v.rework // 0) | \($v.resyncs // 0) | \($g | cell) | \($v.reason // "" | cell) |"' "$L"
}

# ------------------------------------------------------------------ main

cmd="${1:-}"
[ "$#" -gt 0 ] && shift
case "$cmd" in
  path) cmd_path "$@" ;;
  lock) cmd_lock "$@" ;;
  unlock) CMD=unlock; cmd_unlock "$@" ;;
  init) CMD=init; cmd_init "$@" ;;
  get) cmd_get "$@" ;;
  intent) cmd_intent "$@" ;;
  event) cmd_event "$@" ;;
  outbox) cmd_outbox "$@" ;;
  slots) cmd_slots "$@" ;;
  done) cmd_done "$@" ;;
  summary) cmd_summary "$@" ;;
  *) usage ;;
esac
