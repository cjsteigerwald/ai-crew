#!/usr/bin/env bash
# ledger.sh — the coordinator's only writer of partner-session state.
#
#   ledger.sh path <KEY>                                  print the ledger path, create its directory
#   ledger.sh lock <ledger> <own-session-id> <agents.json> take the run lock; prints owner=<sid>:<nonce>
#   ledger.sh unlock <ledger>                             release the run lock
#   ledger.sh init <ledger> <KEY> <ticket-branch> <coord-name> <coord-session-id> <issues.json>
#   ledger.sh get <ledger> [<n>]                          the state (or one issue) as JSON
#   ledger.sh intent <ledger> launch|relaunch <n> <session-name> <worktree> <branch> <base-sha> [<agents.json>]
#   ledger.sh intent <ledger> merge <n> <candidate-sha> <expected-head>   prints intent=<id>
#   ledger.sh event <ledger> <n> <event> [args]           the only way statuses change
#   ledger.sh message <ledger> <raw-frame>                a partner message: bind, dedup, apply
#   ledger.sh session <ledger> <n> <session-name> <session-id>   rebind a woken partner
#   ledger.sh reconcile <ledger> <agents.json>            resume: prints requeue|resend|status lines
#   ledger.sh outbox <ledger>                             <n>\t<gen>\t<to-session>\t<line> per entry
#   ledger.sh slots <ledger>                              live count (frontier.sh --live-count)
#   ledger.sh done <ledger>                               handback | cancel-ticket; exit 1 = not done
#   ledger.sh summary <ledger>                            Markdown table for the PR body
#
# The ledger is <git-common-dir>/partner-sessions/<KEY>/ledger.json; the run lock
# (lock/holder = "<session-id> <nonce>"), the write lock file write.lock and the
# append-only ledger.log are its siblings. Every mutating call (unlock, init,
# intent, event, message, session, reconcile) needs PS_OWNER=<sid>:<nonce>
# matching lock/holder, computes the whole new state with one jq program
# (ledger.jq, beside this script) and writes it with temp file + mv -f.
#
# Write lock: every mutating call, and `lock`, holds an exclusive OS lock on
# write.lock (`lockf -s` on macOS/BSD, `flock -w` on Linux) on this process's
# own fd 9, from before its owner check until it exits. The kernel drops it when
# the process ends, however it ends (SIGKILL included), so there is nothing to
# reap, and no takeover or second writer can land between a writer's owner check
# and its mv. A held lock is waited for PS_WRITE_WAIT seconds (default 10, an
# integer >= 1), then exit 41 with busy=<dir>/write.lock. Read-only subcommands
# take no lock (mv keeps the ledger a whole snapshot).
#
# `message` takes the whole <cross-session-message from="…">…</…> frame as one
# argument and hands it to parse-msg.sh --frame as argv; a frame that fails to
# parse or to bind (from = recorded name exactly, gen = current gen, DONE branch
# = recorded branch) is rejected with exit 20, reason= on stdout and a log line.
#
# Exit: 0 applied (prints the new status or the requested output), 10 idempotent
# no-op, 20 message rejected (prints reason=), 30 illegal transition refused
# (logged), 40 lock held by a live other session or PS_OWNER no longer matches
# (prints holder=), 41 write lock busy (prints busy=), 2 usage or I/O error.
# `done` exits 1 for "not done".
#
# PS_WRITE_TEST_PAUSE=<file> (tests only): a mutating call, holding the write
# lock, pauses after its owner check and before its read until <file> exists
# (about 10 s at most); it first writes its own $$ to <file>.waiting. PS_LOCKF
# (tests only) replaces /usr/bin/lockf. Both are inert unless set.
#
# Never calls claude or gh; free text is passed to jq with --arg, never evaluated.
# Bash 3.2 compatible.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
FRONTIER="$DIR/frontier.sh"
PARSE="$DIR/parse-msg.sh"
LJQ="$DIR/ledger.jq"

usage() {
  sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//' >&2
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

# set_paths <ledger> — L, D, LOCK, LOG.
set_paths() {
  L="$1"
  [ -n "$L" ] || usage
  D="$(dirname "$L")"
  LOCK="$D/lock"
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

# ------------------------------------------------------------------ write lock

WLOCKED=0
# take_write_lock — an exclusive OS lock on $D/write.lock, held on this
# process's own fd 9 until it exits (the kernel drops it on any exit, SIGKILL
# included; no lock-tool process outlives the acquisition). Waits
# PS_WRITE_WAIT seconds, then prints busy= and exits 41. Children (jq,
# frontier.sh) inherit fd 9 and exit before this process does.
take_write_lock() {
  [ -d "$D" ] || die "no ledger directory $D (run ledger.sh path first)"
  wait="${PS_WRITE_WAIT:-10}"
  { is_num "$wait" && [ "$wait" -ge 1 ]; } || die "PS_WRITE_WAIT must be an integer >= 1: $wait"
  lf="$D/write.lock"
  exec 9>>"$lf" || die "cannot open $lf"
  rc=0
  if [ -x "${PS_LOCKF:-/usr/bin/lockf}" ]; then   # macOS / BSD
    "${PS_LOCKF:-/usr/bin/lockf}" -s -t "$wait" 9 || rc=$?
    if [ "$rc" -eq 75 ]; then echo "busy=$lf"; exit 41; fi   # EX_TEMPFAIL = timed out
    [ "$rc" -eq 0 ] || die "lockf failed (rc $rc) on $lf"
  elif command -v flock >/dev/null 2>&1; then     # Linux util-linux
    flock -w "$wait" 9 || rc=$?
    if [ "$rc" -eq 1 ]; then echo "busy=$lf"; exit 41; fi     # timed out
    [ "$rc" -eq 0 ] || die "flock failed (rc $rc) on $lf"
  else
    die "a lock tool is required: /usr/bin/lockf (macOS) or flock (util-linux)"
  fi
  WLOCKED=1
}

cmd_lock() {
  [ "$#" -eq 3 ] || usage
  set_paths "$1"; OWN="$2"; AG="$3"
  take_write_lock
  is_word "$OWN" || die "bad session id: $OWN"
  [ -f "$AG" ] && jq -e 'type == "array"' "$AG" >/dev/null 2>&1 || die "agents.json must be a JSON array: $AG"

  # Under the write lock no writer is between its owner check and its mv, so
  # the holder can be judged and replaced in place. The mkdir write mutex and
  # takeover/ of earlier versions are dead weight here: remove them first.
  for x in "$LOCK/write" "$D/takeover"; do
    if [ -e "$x" ]; then
      rm -rf "$x" || die "cannot remove $x"
      logl "legacy-lock-dir-removed $x by=$OWN"
    fi
  done
  fresh=0
  [ -d "$LOCK" ] || fresh=1
  mkdir -p "$LOCK" || die "cannot create $LOCK"
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
  old="$HSID"
  nonce="$(mknonce)"
  [ -n "$nonce" ] || die "no nonce"
  if ! { printf '%s %s\n' "$OWN" "$nonce" >"$LOCK/holder.tmp.$$" && mv -f "$LOCK/holder.tmp.$$" "$LOCK/holder"; }; then
    rm -f "$LOCK/holder.tmp.$$"; die "cannot write $LOCK/holder"
  fi
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

# begin_write — the start of every read-modify-write (and unlock), under the
# write lock: the owner check. Everything the call reads and writes after this
# is fenced against a takeover, which needs the same lock.
begin_write() {
  [ "$WLOCKED" -eq 1 ] || die "internal error: write without the write lock"
  owner_check
  # Test hook: hold the writer, and so the write lock, before its read.
  if [ -n "${PS_WRITE_TEST_PAUSE:-}" ]; then
    printf '%s\n' "$$" >"$PS_WRITE_TEST_PAUSE.waiting.tmp" && mv -f "$PS_WRITE_TEST_PAUSE.waiting.tmp" "$PS_WRITE_TEST_PAUSE.waiting"
    w=0
    while [ ! -e "$PS_WRITE_TEST_PAUSE" ] && [ "$w" -lt 200 ]; do sleep 0.05 9>&-; w=$((w + 1)); done
  fi
}

cmd_unlock() {
  [ "$#" -eq 1 ] || usage
  set_paths "$1"
  take_write_lock
  begin_write
  rm -rf "$LOCK" || die "cannot remove $LOCK"
  logl "unlock holder=$HSID"
  echo "unlocked"
}

# ------------------------------------------------------------------ writes

# write_state <file> — validate, re-check the owner, then mv -f over the ledger.
# The caller holds the write lock, and a takeover needs it too, so the holder
# cannot change between this check and the mv.
write_state() {
  [ "$WLOCKED" -eq 1 ] || die "internal error: write without the write lock"
  LTMP="$L.tmp.$$"
  cat "$1" >"$LTMP" || die "cannot write $LTMP"
  jq -e 'type == "object"' "$LTMP" >/dev/null 2>&1 || die "refusing to write an invalid ledger"
  owner_check
  mv -f "$LTMP" "$L" || die "cannot replace $L"
  LTMP=""
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
  take_write_lock
  key="$2"; tb="$3"; cname="$4"; csid="$5"; issues="$6"
  begin_write
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
      cap: 3, canary: "pending", claimSeq: 0,
      issues: (reduce .[] as $i ({};
        .[($i.n | tostring)] = {
          status: "pending", gen: 0,
          blockers: ($i.blockers // []), external: ($i.external // []),
          branch: $i.branch, testCmd: ($i.testCmd // ""), ac: ($i.ac // []),
          sessionName: null, sessionId: null, sessions: [], worktree: null, startSha: null,
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
# ljqf <state-file> <op> [jq options...] — the same on another state file.
ljqf() {
  in="$1"; op="$2"; shift 2
  jq --arg op "$op" "$@" -f "$LJQ" "$in"
}
ljq() { ljqf "$L" "$@"; }

# live_keys [<state-file>] — JSON array of live issue keys, each judged by
# frontier.sh --live-count (the single definition of "live", ruling F7).
live_keys() {
  tmpdir
  sf="${1:-$L}"
  keys="$(jq -r '.issues | keys[]' "$sf")" || die "cannot read $sf"
  lk="["; sep=""
  for k in $keys; do
    jq --arg k "$k" '{issues: {($k): .issues[$k]}}' "$sf" >"$TMPD/one.json" || die "cannot read $sf"
    c="$("${BASH:-bash}" "$FRONTIER" --live-count "$TMPD/one.json")" || die "frontier.sh --live-count failed"
    if [ "$c" = 1 ]; then lk="$lk$sep\"$k\""; sep=","; fi
  done
  printf '%s]' "$lk"
}

# reject <what> <reason> — a partner message is refused before any state change:
# log it, print reason=, exit 20.
reject() {
  logl "rejected $1: $2"
  printf 'reason=%s\n' "$(printf '%s' "$2" | tr '\t\n\r' '   ')"
  exit 20
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
      out="$(jq -r '(.out // [])[]' "$res")"
      if [ -n "$out" ]; then
        printf '%s\n' "$out"
        logl "noop $what: $(jq -r '.reason' "$res") -> $out"
      fi
      echo "noop: $(jq -r '.reason' "$res")" >&2
      exit 10 ;;
    20)
      reject "$what" "$(jq -r '.reason' "$res")" ;;
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
  take_write_lock
  CMD="intent $kind #$n"
  need_ledger
  begin_write
  is_num "$n" || usage
  jq -e --arg n "$n" '.issues | has($n)' "$L" >/dev/null || die "no issue #$n"
  tmpdir
  case "$kind" in
    launch|relaunch)
      [ "$#" -eq 7 ] || { [ "$#" -eq 8 ] && [ "$kind" = relaunch ]; } || usage
      name="$4"; wt="$5"; br="$6"; base="$7"
      is_word "$name" || die "bad session name: $name"
      [ -n "$wt" ] || die "empty worktree"
      is_branch "$br" || die "bad branch: $br"
      is_sha "$base" || die "bad base sha: $base"
      # Relaunch: the pid of the issue's recorded session now (alive row by
      # sessionId, else by name; null if none), so reconcile never takes that
      # same process for the relaunch (ruling CX2).
      ppid=null
      if [ "$#" -eq 8 ]; then
        AG="$8"
        [ -f "$AG" ] && jq -e 'type == "array"' "$AG" >/dev/null 2>&1 || die "agents.json must be a JSON array: $AG"
        sid0="$(jq -r --arg n "$n" '.issues[$n].sessionId // ""' "$L")" || die "cannot read $L"
        nm0="$(jq -r --arg n "$n" '.issues[$n].sessionName // ""' "$L")" || die "cannot read $L"
        ppid="$(jq -c --arg s "$sid0" --arg m "$nm0" '
          [ .[] | select((.pid // null) != null) ] as $alive
          | [ $alive[] | select($s != "" and .sessionId == $s) ] as $byid
          | (if ($byid | length) > 0 then $byid else [ $alive[] | select($m != "" and .name == $m) ] end)
          | sort_by(.startedAt // 0) | last | .pid // null' "$AG")" || die "cannot read $AG"
      fi
      live="$(live_keys)"
      ljq intent-launch --arg n "$n" --arg kind "$kind" --arg name "$name" --arg wt "$wt" --arg br "$br" \
         --arg base "$base" --argjson ppid "$ppid" --argjson live "$live" >"$TMPD/res.json" || die "internal error"
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
  take_write_lock
  CMD="event #$n $ev"
  need_ledger
  begin_write
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
    edge-remove) [ "$#" -eq 0 ] || { [ "$#" -eq 1 ] && is_num "$a1"; } || usage ;;
    wake-failed|canary-passed|user-merged) [ "$#" -eq 0 ] || usage ;;
    drop|cancel-ticket) [ "$#" -le 1 ] || usage ;;
    json)
      # `json done nopid`: the row has ended (no pid); a bare `done` may be idle and alive.
      [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$a1" = done ] && [ "$a2" = nopid ]; } || usage
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

# ticket_head — the ticket branch tip, read from the ledger's own git dir
# (<git-common-dir>/partner-sessions/<KEY>/); empty if it cannot be read.
ticket_head() {
  gd="$(cd "$D/../.." && pwd -P)" || return 0
  tb="$(jq -r '.ticketBranch' "$L")" || return 0
  git --git-dir="$gd" rev-parse -q --verify "refs/heads/$tb^{commit}" 2>/dev/null || true
}

# ------------------------------------------------------------------ messages

cmd_message() {
  [ "$#" -eq 2 ] || usage
  set_paths "$1"; raw="$2"
  take_write_lock
  CMD="message"
  need_ledger
  begin_write
  tmpdir
  # The frame is one argv argument; parse-msg.sh validates it and extracts from=.
  if ! "${BASH:-bash}" "$PARSE" --frame "$raw" >"$TMPD/msg" 2>"$TMPD/msgerr"; then
    r="$(sed -n 's/^error=//p' "$TMPD/msgerr" | head -n 1)"
    reject "message" "bad frame: ${r:-unparseable}"
  fi
  from=""; mkind=""; n=""; mgen=""; mbranch=""; sha=""; synced=""; needs=""; mreason=""
  while IFS= read -r line; do
    v="${line#*=}"
    case "$line" in
      from=*) from="$v" ;;
      kind=*) mkind="$v" ;;
      issue=*) n="$v" ;;
      gen=*) mgen="$v" ;;
      branch=*) mbranch="$v" ;;
      sha=*) sha="$v" ;;
      synced=*) synced="$v" ;;
      needs=*) needs="$v" ;;
      reason=*) mreason="$v" ;;
    esac
  done <"$TMPD/msg"
  is_num "$n" && is_num "$mgen" && [ -n "$from" ] && [ -n "$mkind" ] || die "parse-msg.sh output incomplete"
  head=""
  [ -n "$needs" ] && head="$(ticket_head)"
  live="$(live_keys)"
  ljq message --arg n "$n" --arg from "$from" --arg mkind "$mkind" --arg mgen "$mgen" \
     --arg mbranch "$mbranch" --arg sha "$sha" --arg synced "$synced" --arg needs "$needs" \
     --arg mreason "$mreason" --arg head "$head" --argjson live "$live" \
     >"$TMPD/res.json" || die "internal error"
  apply "message $mkind #$n from=$from" "$TMPD/res.json"
}

cmd_session() {
  [ "$#" -eq 4 ] || usage
  set_paths "$1"; n="$2"; name="$3"; sid="$4"
  take_write_lock
  CMD="session #$n"
  need_ledger
  begin_write
  is_num "$n" || usage
  is_word "$name" || die "bad session name: $name"
  is_word "$sid" || die "bad session id: $sid"
  jq -e --arg n "$n" '.issues | has($n)' "$L" >/dev/null || die "no issue #$n"
  tmpdir
  ljq session --arg n "$n" --arg name "$name" --arg sid "$sid" >"$TMPD/res.json" || die "internal error"
  apply "session #$n $name $sid" "$TMPD/res.json"
}

# ------------------------------------------------------------------ reconcile

cmd_reconcile() {
  [ "$#" -eq 2 ] || usage
  set_paths "$1"; AG="$2"
  take_write_lock
  CMD="reconcile"
  need_ledger
  begin_write
  [ -f "$AG" ] && jq -e 'type == "array"' "$AG" >/dev/null 2>&1 || die "agents.json must be a JSON array: $AG"
  tmpdir
  # pid is kept: a row is alive only while it has one (ruling T6-C1).
  ag="$(jq -c '[.[] | {sessionId: (.sessionId // null), name: (.name // null), pid: (.pid // null),
                        state: (.state // null), startedAt: (.startedAt // 0)}]' "$AG")" \
    || die "cannot read $AG"
  # Open merge intents whose candidate is already an ancestor of the ticket head.
  jq -r '.intents[] | select(.open and .kind == "merge") | "\(.id) \(.candidateSha)"' "$L" >"$TMPD/mi" \
    || die "cannot read $L"
  : >"$TMPD/anc"
  if [ -s "$TMPD/mi" ]; then
    th="$(ticket_head)"
    [ -n "$th" ] || die "cannot read the ticket head"
    gd="$(cd "$D/../.." && pwd -P)" || die "cannot resolve the git dir"
    while read -r id cand; do
      is_sha "$cand" || continue
      git --git-dir="$gd" merge-base --is-ancestor "$cand" "$th" 2>/dev/null && printf '%s\n' "$id" >>"$TMPD/anc"
    done <"$TMPD/mi"
  fi
  anc="$(jq -R . "$TMPD/anc" | jq -cs .)" || die "internal error"
  ljq reconcile --argjson ag "$ag" --argjson ancids "$anc" >"$TMPD/res.json" || die "internal error"
  [ "$(jq -r '.rc' "$TMPD/res.json")" = 0 ] || die "reconcile: $(jq -r '.reason' "$TMPD/res.json")"
  jq '.state' "$TMPD/res.json" >"$TMPD/new.json" || die "internal error"
  live="$(live_keys "$TMPD/new.json")"
  ljqf "$TMPD/new.json" reconcile-actions --argjson live "$live" >"$TMPD/acts.json" || die "internal error"
  # A second run finds nothing to change and leaves the ledger's bytes alone.
  if ! jq -e --slurpfile a "$TMPD/new.json" '. == $a[0]' "$L" >/dev/null; then
    write_state "$TMPD/new.json"
  fi
  jq -r '.purged[] | "outbox-stale-purged n=\(.n) gen=\(.gen)"' "$TMPD/res.json" |
    while IFS= read -r pl; do logl "$pl"; done
  jq -r '.out[]' "$TMPD/acts.json"
  logl "reconcile -> $(jq -r '.out | join("; ")' "$TMPD/acts.json")"
}

# ------------------------------------------------------------------ read-only reports

cmd_outbox() {
  [ "$#" -eq 1 ] || usage
  set_paths "$1"; need_ledger
  jq -r '. as $s | .outbox[]
         | "\(.n)\t\(.gen)\t\(.to // $s.issues[(.n | tostring)].sessionName // "-")\t\(.line)"' "$L"
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
  message) cmd_message "$@" ;;
  session) cmd_session "$@" ;;
  reconcile) cmd_reconcile "$@" ;;
  outbox) cmd_outbox "$@" ;;
  slots) cmd_slots "$@" ;;
  done) cmd_done "$@" ;;
  summary) cmd_summary "$@" ;;
  *) usage ;;
esac
