#!/usr/bin/env bash
# piece-track.sh — an orchestrator's only reader and writer of its piece-tracking file.
#
#   piece-track.sh [--branch <b>] path                       print the tracking-file path
#   piece-track.sh [--branch <b>] register <snapshot.json> [--depth <n>] [--live-cap <n>] [--depth-cap <n>]
#   piece-track.sh [--branch <b>] launchable                 issues to launch now, one per line, ascending
#   piece-track.sh [--branch <b>] launch <issue> <agent> <session-id> <piece-branch>
#   piece-track.sh [--branch <b>] record <report-line>       record one piece agent's report
#   piece-track.sh [--branch <b>] merged <issue>             done -> merged (after the fast-forward)
#   piece-track.sh [--branch <b>] failed <issue>             running, done or stuck -> failed
#   piece-track.sh [--branch <b>] dropped <issue>            any state but merged -> dropped (the user's call)
#   piece-track.sh [--branch <b>] finished                   true or false: every piece merged or dropped
#   piece-track.sh [--branch <b>] summary                    Markdown table for the PR body
#
# --branch names the orchestrator's own branch (default: the current branch;
# required on a detached HEAD). One tracking file per orchestrator branch:
# <git-common-dir>/piece-tracking/<enc>.json, where <enc> is the branch
# percent-encoded (every UTF-8 byte outside A-Za-z0-9-_.~ becomes %XX, '%'
# included), so the encoding is injective: a/b -> a%2Fb.json, a-b -> a-b.json.
# PIECE_TRACK_DIR=<dir> replaces <git-common-dir>/piece-tracking.
#
# Dependency snapshot (register's input), as read from GitHub:
#   {"pieces": [{"issue": 35, "blocked_by": [34, 12]}, {"issue": 34}],
#    "external": {"12": "closed"}}
# issue and blocked_by entries are integer literals >= 1 (35, not 35.0 or 1e2);
# blocked_by absent or null means [], external absent or null means {}.
# Every blocker is either a piece in the set or a key of external, whose value
# is that issue's GitHub state, "open" or "closed". Rejected, writing nothing:
# invalid JSON, a bad entry, a duplicate issue, an issue both in pieces and in
# external, an unknown blocker, and a dependency cycle (`cycle: #a -> #b -> #a`).
#
# Tracking file (version 1):
#   {"version": 1, "branch": "<orchestrator branch>", "depth": 0, "liveCap": 3,
#    "depthCap": 2, "external": {"12": "closed"},
#    "pieces": {"35": {"state": "pending", "blockedBy": [12, 34],
#                      "agent": null, "session": null, "branch": null}}}
# state is one of pending, running, done, merged, stuck, failed, dropped.
# record adds sha (from DONE) and needs (an issue number or null) and reason
# (from STUCK) to a piece. register sets depth (default 0), liveCap (default 3,
# >= 1) and depthCap (default 2). Re-registering replaces the file only while
# every piece is still pending; after any launch it is refused.
#
# Report lines (record's one argument; one line, fields separated by spaces;
# one trailing CR and trailing spaces are ignored; any other control character,
# tab and newline included, is malformed):
#   STARTED #<issue>                                STARTED #35
#   DONE #<issue> <piece-branch> <sha>              DONE #35 feat/orch-35 <40 lowercase hex>
#   STUCK #<issue> [needs=#<sibling>] <reason>      STUCK #35 needs=#34 waits on #34's schema
#                                                   STUCK #35 cannot reach the test db
# <issue> and <sibling> are integers >= 1 without leading zeros; <sha> is the
# full 40-hex commit SHA; <reason> is the rest of the line, non-empty, stored
# verbatim. Anything else (another keyword, a missing or extra field, the old
# gen=/synced= fields, SCOPE or FAILED) is malformed: exit 1, nothing written.
# The line is data: split by `read`, passed to jq with --arg, never evaluated.
#
# Transitions (anything not listed is refused with exit 1, nothing written;
# a report or mark that changes nothing exits 0 and leaves the file
# byte-identical):
#   launch    pending                -> running
#   STARTED   running, done, stuck   -> unchanged (a late STARTED never regresses)
#   DONE      running, done, stuck   -> done, sha set (a new sha replaces the old:
#                                       the resync re-report); needs, reason cleared
#             merged                 -> unchanged, only for the same branch and sha
#   STUCK     running, done, stuck   -> stuck, needs and reason set, sha kept
#   merged    done                   -> merged;   merged -> unchanged
#   failed    running, done, stuck   -> failed (the session ended unmerged);
#             failed                 -> unchanged
#   dropped   any state but merged   -> dropped;  dropped -> unchanged
# (Repeated marks are no-ops so an orchestrator can retry after a crash.)
# A report is also refused for an unknown issue, a pending piece (never
# launched), a DONE whose branch is not the one recorded at launch, and a
# STUCK whose needed sibling is itself, outside the set, dropped or failed
# (it can never merge), or blocked by the reporting piece, directly or
# through other pieces' blockedBy (needing it would deadlock). pending cannot fail: a
# piece with no session has nothing to fail. A dropped piece is not live and
# does not clear its dependants: they stay blocked.
#
# finished prints true when every piece is merged or dropped (so with zero
# pieces it is true: nothing is left to do) and false otherwise; it is
# read-only. summary adds a Notes column: "needs #N: <reason>" for a stuck
# piece, "not delivered (dropped)" for a dropped one, and "not delivered
# (blocked by dropped #a, #b)" for an unmerged piece behind a dropped one,
# directly or through other unmerged pieces.
#
# Launchable: a pending piece whose in-set blockers are all merged and whose
# external blockers are all closed. Live pieces are running, done or stuck (a
# session not yet ended). At most liveCap - live are listed, lowest issue first,
# and none when depth >= depthCap. launch refuses (writing nothing) an unknown
# issue, a piece not pending, a piece branch equal to the orchestrator's branch,
# a session id or piece branch already recorded on another piece, a blocked
# piece, and a launch at either cap; it does not insist on launchable's
# lowest-first order.
#
# Every write goes to a temp file in the tracking directory, is validated, and
# is renamed over the tracking file, so a failed or interrupted write leaves the
# previous file byte-identical. PIECE_TRACK_TEST_ABORT_BEFORE_RENAME=1 (tests
# only) stops a write after the temp file is complete and before the rename.
#
# Lock: every writing command (register, launch, record, merged, failed,
# dropped) holds one lock per tracking
# file from before it reads the file until it exits, so read, checks, compute
# and rename are one transaction. The lock is flock(2) on the persistent file
# .<enc>.json.lock beside the tracking file (never deleted), taken by a perl
# wrapper (a `perl -MFcntl` preflight runs first; exit 2 without it) that re-execs this
# script with the locked fd open. The kernel keeps it held while this run or
# any child it started lives and frees it on any death, SIGKILL included. A
# busy lock is retried every 0.1 s for PIECE_TRACK_LOCK_TIMEOUT seconds
# (default 10, an integer >= 0), then the command is refused (exit 1) with
# "lock busy (held by pid N)", writing nothing; a lock file that cannot be
# opened is exit 2. PIECE_TRACK_LOCKED is internal: "<pid>:<lock file>" marks
# the re-executed run and counts only when <pid> is that run's own pid. Read-only
# commands (path, launchable, finished, summary) take no lock: the rename means they
# always read a whole file. Only register creates the state directory; a launch
# with no tracking file is refused without creating it, but when the state
# directory exists, that refused launch can leave a persistent lock file for
# the unregistered branch. A relative PIECE_TRACK_DIR is used as ./<dir>.
# PIECE_TRACK_TEST_HOLD_LOCK=<f>, PIECE_TRACK_TEST_LOCK_WAITING=<f> and
# PIECE_TRACK_TEST_LOCK_CHILD=<f> (tests only): once holding the lock, create
# <f>.held and wait until <f> exists; create <f> when first finding the lock
# busy; start a background `sleep 30` inside the lock and write its pid to <f>.
#
# Exit: 0 done, 1 refused (reason on stderr; a malformed report line is a
# refusal), 2 usage or I/O error (a bad <issue> argument is usage). Issue,
# branch, agent, session and report strings are data: validated, passed to jq with
# --arg/--argjson, never evaluated. Never calls claude or gh. Bash 3.2 compatible.
set -u

usage() {
  grep '^#   piece-track\.sh ' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
die() { echo "piece-track.sh: $*" >&2; exit 2; }
refuse() { echo "piece-track.sh: $*" >&2; exit 1; }

# An issue number: a positive integer without leading zeros.
is_issue() {
  case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 9 ]
}
# A count: a non-negative integer without leading zeros.
is_count() {
  case "$1" in 0) return 0 ;; ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 6 ]
}
# A branch git accepts; @{ is refused so git never expands @{-n}.
is_branch() {
  case "$1" in ''|*[[:cntrl:]]*|*@\{*) return 1 ;; esac
  git check-ref-format --branch "$1" >/dev/null 2>&1
}
# Free text (an agent name): non-empty, one line, no control characters.
is_text() {
  case "$1" in ''|*[[:cntrl:]]*) return 1 ;; esac
}
# A session id: non-empty, no whitespace or control characters.
is_word() {
  case "$1" in ''|*[[:space:][:cntrl:]]*) return 1 ;; esac
}

WTMP=""
cleanup() {
  [ -n "$WTMP" ] && rm -f "$WTMP"
  return 0
}
trap cleanup EXIT
# A signal ends the run through exit, so the EXIT trap still removes the temp file.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# The shape every tracking file must have before it is read or written: exactly
# one JSON value (jq -e alone would judge only the last value of a stream),
# an object, every piece in a known state. STATES is the one list of states.
STATES='"pending", "running", "done", "merged", "stuck", "failed", "dropped"'
VALID='length == 1 and (.[0]
  | type == "object" and .version == 1 and (.branch | type) == "string"
  and (.depth | type) == "number" and (.liveCap | type) == "number"
  and (.depthCap | type) == "number" and (.external | type) == "object"
  and (.pieces | type) == "object"
  and all(.pieces[]; . as $p | any('"$STATES"'; . == $p.state) and (.blockedBy | type) == "array"))'

# valid_file <file> — the file holds exactly one well-formed tracking object.
valid_file() { jq -se "$VALID" "$1" >/dev/null 2>&1; }

# jq definitions over a tracking file.
SDEFS='
def live: .state == "running" or .state == "done" or .state == "stuck";
def livecount: [.pieces[] | select(live)] | length;
# A blocker (an issue number) is cleared when merged in the set or closed outside it.
def blocker_state($s): tostring as $k
  | if $s.pieces | has($k) then $s.pieces[$k].state else ($s.external[$k] // "unknown") end;
def cleared($s): tostring as $k
  | if $s.pieces | has($k) then $s.pieces[$k].state == "merged" else $s.external[$k] == "closed" end;
def holds($s): [.blockedBy[] | select(cleared($s) | not)];
def slots: if .depth >= .depthCap then 0 else ([.liveCap - livecount, 0] | max) end;
def launchable: . as $s
  | [.pieces | to_entries[]
     | select(.value.state == "pending" and (.value | holds($s) | length) == 0)
     | .key | tonumber]
  | sort | .[0:($s | slots)];
'

# Absent or null blocked_by / external mean none; any other non-array or
# non-object value is rejected by CHECK, not defaulted.
SNAPDEFS='
def blockers: if .blocked_by == null then [] else .blocked_by end;
def ext: if .external == null then {} else .external end;
'

# jq definitions over a snapshot: validation and the cycle check.
CHECK='
def posint: type == "number" and (tostring | test("^[1-9][0-9]{0,8}$"));
def badpiece: (type != "object") or ((.issue | posint) | not)
  or (blockers | (type == "array" and all(.[]; posint)) | not);
def badext: (.key | test("^[1-9][0-9]{0,8}$") | not) or (.value != "open" and .value != "closed");

# Kahn: repeatedly drop nodes with no remaining blocker; the rest are cyclic.
def leftover($g):
  {rem: ($g | keys), done: false}
  | until(.done;
      .rem as $r
      | [ $r[] | select(any($g[.][]; . as $b | any($r[]; . == $b))) ] as $n
      | if ($n | length) == ($r | length) then .done = true else .rem = $n end)
  | .rem;

# A concrete cycle among the leftover nodes (each has a leftover blocker).
def cycle_of($g; $rem):
  ($rem | map(tonumber) | min | tostring) as $start
  | {path: [$start], hit: null}
  | until(.hit != null;
      .path[-1] as $cur
      | ([ $g[$cur][] | select(. as $b | any($rem[]; . == $b)) ] | .[0]) as $nx
      | if any(.path[]; . == $nx) then .hit = $nx else .path += [$nx] end)
  | .hit as $h | .path
  | (index($h)) as $i | .[$i:] + [$h]
  | map("#" + tostring) | join(" -> ");

if type != "object" then "snapshot is not a JSON object"
elif (.pieces | type) != "array" then "snapshot has no pieces array"
elif (ext | type) != "object" then "snapshot external is not an object"
elif any(.pieces[]; badpiece) then "bad piece entry: " + ([.pieces[] | select(badpiece)][0] | tojson)
elif any(ext | to_entries[]; badext)
  then "bad external entry: " + ([ext | to_entries[] | select(badext)][0] | "\(.key | tojson): \(.value | tojson)")
else
  ext as $ext
  | [.pieces[].issue | tostring] as $ids
  | [$ids | group_by(.)[] | select(length > 1) | .[0] | tonumber] as $dup
  | [$ids[] | select(. as $i | $ext | has($i)) | tonumber] as $both
  | [.pieces[] | (.issue | tostring) as $i | blockers[] | tostring
     | select(. as $b | (any($ids[]; . == $b) or ($ext | has($b))) | not)
     | "#\($i) is blocked by unknown #\(.)"] as $unk
  | if ($dup | length) > 0 then "duplicate issue: " + ($dup | sort | map("#\(.)") | join(", "))
    elif ($both | length) > 0 then "issue in both pieces and external: " + ($both | sort | map("#\(.)") | join(", "))
    elif ($unk | length) > 0 then "unknown blocker: " + ($unk | join("; "))
    else
      (reduce .pieces[] as $p ({};
         .[$p.issue | tostring] = ([($p | blockers)[] | tostring
                                     | select(. as $b | any($ids[]; . == $b))] | unique))) as $g
      | leftover($g) as $rem
      | if ($rem | length) == 0 then empty else "cycle: " + cycle_of($g; $rem) end
    end
end
'

# The tracking file built from a (checked) snapshot.
BUILD='
{version: 1, branch: $b, depth: $d, liveCap: $lc, depthCap: $dc,
 external: ext,
 pieces: (reduce (.pieces | sort_by(.issue))[] as $p ({};
   .[$p.issue | tostring] = {state: "pending", blockedBy: (($p | blockers) | unique),
                             agent: null, session: null, branch: null}))}
'

# ------------------------------------------------------------------ location

BR=""
SDIR=""
ENC=""
FILE=""

# set_paths — BR (the orchestrator branch), SDIR, ENC and FILE.
set_paths() {
  if [ -z "$BR" ]; then
    git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git repository: pass --branch"
    BR="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || die "detached HEAD: pass --branch"
  fi
  is_branch "$BR" || die "bad branch: $BR"
  if [ -n "${PIECE_TRACK_DIR:-}" ]; then
    SDIR="$PIECE_TRACK_DIR"
    # A relative dir gets ./ so no tool reads a leading - as an option.
    case "$SDIR" in /*) ;; *) SDIR="./$SDIR" ;; esac
  else
    gd="$(git rev-parse --git-common-dir 2>/dev/null)" || die "not in a git repository: set PIECE_TRACK_DIR"
    gd="$(cd "$gd" && pwd -P)" || die "cannot resolve $gd"
    SDIR="$gd/piece-tracking"
  fi
  # jq 1.6's @uri leaves !'() unencoded and 1.7's does not; encode them here
  # so the file name does not depend on the jq version.
  ENC="$(jq -rn --arg b "$BR" --arg q "'" '$b | @uri | gsub("!"; "%21") | gsub($q; "%27")
                                | gsub("\\("; "%28") | gsub("\\)"; "%29")')" || die "cannot encode branch $BR"
  [ "${#ENC}" -le 200 ] || die "branch name too long to key a tracking file: $BR"
  FILE="$SDIR/$ENC.json"
}

# need_state — the tracking file exists, is well formed, and is this branch's.
need_state() {
  [ -f "$FILE" ] || refuse "no tracking file for $BR (run register first): $FILE"
  valid_file "$FILE" || refuse "unreadable tracking file: $FILE"
  jq -e --arg b "$BR" '.branch == $b' "$FILE" >/dev/null 2>&1 \
    || refuse "tracking file $FILE belongs to $(jq -r '.branch' "$FILE"), not $BR"
}

# write_state <jq args...> — runs jq with the args into a temp file beside the
# tracking file, validates it, then renames it over the tracking file.
write_state() {
  mkdir -p "$SDIR" 2>/dev/null || die "cannot create $SDIR"
  WTMP="$(mktemp "$SDIR/.$ENC.json.tmp.XXXXXX" 2>/dev/null)" || { WTMP=""; die "cannot write a temp file in $SDIR"; }
  jq "$@" >"$WTMP" || die "cannot compute the new state"
  valid_file "$WTMP" || die "refusing to write an invalid tracking file"
  [ -z "${PIECE_TRACK_TEST_ABORT_BEFORE_RENAME:-}" ] || die "test hook: aborting before rename"
  mv -f "$WTMP" "$FILE" || die "cannot replace $FILE"
  WTMP=""
}

# ------------------------------------------------------------------ lock
#
# The lock is flock(2) on the persistent file .<enc>.json.lock, taken by a perl
# wrapper that then execs this script again with the locked fd left open. The
# kernel holds the lock while any process with that fd lives (this bash and
# every jq, mv or rm it starts) and frees it when the last one ends, however it
# ends (SIGKILL included): no stale locks to break, no pid checks. The lock
# file is never deleted (deleting a flock file lets two holders lock different
# inodes).

# Takes the lock (retrying every 0.1 s up to the timeout), writes its pid into
# the lock file for refusal messages, then execs ARGV[2..] with the fd open.
# ARGV: <lock file> <timeout seconds> <command...>; arguments are never parsed
# as code.
LOCKPL='
my ($lock, $timeout, @cmd) = @ARGV;
my $fh;
unless (open($fh, ">>", $lock)) {
  print STDERR "piece-track.sh: cannot write lock $lock: $!\n";
  exit 2;
}
my ($tries, $told) = (0, 0);
until (flock($fh, LOCK_EX | LOCK_NB)) {
  my $w = $ENV{PIECE_TRACK_TEST_LOCK_WAITING} // "";
  if (!$told && $w ne "") { open(my $t, ">", $w) and close($t); $told = 1; }
  if ($tries >= $timeout * 10) {
    my $holder = "";
    if (open(my $r, "<", $lock)) { $holder = <$r> // ""; chomp $holder; }
    print STDERR "piece-track.sh: lock busy"
      . ($holder =~ /^[0-9]+$/ ? " (held by pid $holder)" : "") . ": $lock\n";
    exit 1;
  }
  select(undef, undef, undef, 0.1);
  $tries++;
}
truncate($fh, 0);
syswrite($fh, "$$\n");
my $flags = fcntl($fh, F_GETFD, 0);
fcntl($fh, F_SETFD, $flags & ~FD_CLOEXEC) or do {
  print STDERR "piece-track.sh: cannot keep the lock open across exec: $!\n";
  exit 2;
};
$ENV{PIECE_TRACK_LOCKED} = $$ . ":" . $lock;
exec { $cmd[0] } @cmd;
print STDERR "piece-track.sh: cannot exec $cmd[0]: $!\n";
exit 2;
'

# with_lock [--create] — makes this run hold the tracking file's lock. The
# first call re-execs this script under the perl wrapper (and does not
# return); the re-executed run finds PIECE_TRACK_LOCKED = "<its own pid>:<the
# lock this run needs>" (exec keeps the pid) and returns. Any other value (a
# preset or inherited marker, or a different lock) is ignored and the lock is
# taken normally. Without --create a missing state directory is refused as a
# missing tracking file, so a refused command creates nothing.
with_lock() {
  lockf="$SDIR/.$ENC.json.lock"
  if [ "${PIECE_TRACK_LOCKED:-}" = "$$:$lockf" ]; then
    unset PIECE_TRACK_LOCKED
    if [ -n "${PIECE_TRACK_TEST_LOCK_CHILD:-}" ]; then
      sleep 30 &
      printf '%s\n' "$!" >"$PIECE_TRACK_TEST_LOCK_CHILD"
    fi
    if [ -n "${PIECE_TRACK_TEST_HOLD_LOCK:-}" ]; then
      : >"$PIECE_TRACK_TEST_HOLD_LOCK.held"
      w=0
      while [ ! -e "$PIECE_TRACK_TEST_HOLD_LOCK" ] && [ "$w" -lt 200 ]; do sleep 0.05; w=$((w + 1)); done
    fi
    return 0
  fi
  lt="${PIECE_TRACK_LOCK_TIMEOUT:-10}"
  is_count "$lt" || die "PIECE_TRACK_LOCK_TIMEOUT must be an integer >= 0: $lt"
  if [ ! -d "$SDIR" ]; then
    [ "${1:-}" = "--create" ] || need_state
    mkdir -p "$SDIR" 2>/dev/null || die "cannot create $SDIR"
  fi
  perl -MFcntl -e 1 >/dev/null 2>&1 || die "perl with Fcntl is required to lock $lockf"
  exec perl -MFcntl=:flock,F_GETFD,F_SETFD,FD_CLOEXEC -e "$LOCKPL" -- \
    "$lockf" "$lt" "$BASH" "$0" "${ARGS[@]}"
}

# ------------------------------------------------------------------ commands

cmd_path() {
  [ "$#" -eq 0 ] || usage
  echo "$FILE"
}

cmd_register() {
  [ "$#" -ge 1 ] || usage
  snap="$1"; shift
  depth=0; lcap=3; dcap=2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --depth)
        { [ "$#" -ge 2 ] && is_count "$2"; } || die "--depth needs an integer >= 0"
        depth="$2"; shift 2 ;;
      --live-cap)
        { [ "$#" -ge 2 ] && is_count "$2" && [ "$2" -ge 1 ]; } || die "--live-cap needs an integer >= 1"
        lcap="$2"; shift 2 ;;
      --depth-cap)
        { [ "$#" -ge 2 ] && is_count "$2"; } || die "--depth-cap needs an integer >= 0"
        dcap="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  { [ -f "$snap" ] && [ -r "$snap" ]; } || die "cannot read snapshot: $snap"
  n="$(jq -s 'length' "$snap" 2>/dev/null)" || refuse "snapshot is not valid JSON: $snap"
  [ "$n" = "1" ] || refuse "snapshot is not valid JSON (expected one value): $snap"
  reason="$(jq -r "$SNAPDEFS$CHECK" "$snap")" || die "cannot check snapshot: $snap"
  [ -z "$reason" ] || refuse "$reason"
  if [ -e "$FILE" ]; then
    need_state
    launched="$(jq -r '[.pieces | to_entries | sort_by(.key | tonumber)[]
                        | select(.value.state != "pending") | "#\(.key) is \(.value.state)"] | join(", ")' "$FILE")" \
      || die "cannot read $FILE"
    [ -z "$launched" ] || refuse "already launched ($launched); re-register only while every piece is pending"
  fi
  write_state --arg b "$BR" --argjson d "$depth" --argjson lc "$lcap" --argjson dc "$dcap" "$SNAPDEFS$BUILD" "$snap"
  echo "registered $(jq '.pieces | length' "$FILE") pieces for $BR"
}

cmd_launchable() {
  [ "$#" -eq 0 ] || usage
  need_state
  jq -r "$SDEFS"'launchable[]' "$FILE" || die "cannot read $FILE"
}

cmd_launch() {
  [ "$#" -eq 4 ] || usage
  issue="$1"; agent="$2"; sid="$3"; pbr="$4"
  is_issue "$issue" || die "bad issue: $issue"
  is_text "$agent" || die "bad agent name"
  is_word "$sid" || die "bad session id"
  is_branch "$pbr" || die "bad branch: $pbr"
  need_state
  reason="$(jq -r --arg i "$issue" --arg sid "$sid" --arg pb "$pbr" "$SDEFS"'
    . as $s | .pieces[$i] as $p
    # the first other piece already recorded with session $sid / branch $pb, or null
    | ([.pieces | to_entries | sort_by(.key | tonumber)[]
        | select(.key != $i and .value.session == $sid) | .key][0]) as $dsid
    | ([.pieces | to_entries | sort_by(.key | tonumber)[]
        | select(.key != $i and .value.branch == $pb) | .key][0]) as $dpb
    | if $p == null then "unknown issue #\($i)"
      elif $p.state != "pending" then "#\($i) is \($p.state), not pending"
      elif $pb == .branch then "piece branch \($pb) is the orchestrator'"'"'s branch"
      elif $dsid != null then "session id \($sid) is already recorded on #\($dsid)"
      elif $dpb != null then "piece branch \($pb) is already recorded on #\($dpb)"
      elif ($p | holds($s) | length) > 0
        then "#\($i) is blocked by " + ([$p | holds($s)[] | "#\(.) (\(blocker_state($s)))"] | join(", "))
      elif .depth >= .depthCap then "depth cap reached (depth \(.depth), cap \(.depthCap))"
      elif livecount >= .liveCap then "live cap reached (\(livecount) live, cap \(.liveCap))"
      else empty end' "$FILE")" || die "cannot read $FILE"
  [ -z "$reason" ] || refuse "$reason"
  write_state --arg i "$issue" --arg a "$agent" --arg sid "$sid" --arg pb "$pbr" \
    '.pieces[$i] += {state: "running", agent: $a, session: $sid, branch: $pb}' "$FILE"
  echo "#$issue running"
}

# jq definitions for record, over a tracking file, with $k (STARTED, DONE or
# STUCK), $i (issue), $pb (DONE's branch), $sha, $n (STUCK's needs, "" for
# none) and $r (STUCK's reason).
RDEFS='
def terminal: .state == "merged" or .state == "failed" or .state == "dropped";
# Whether piece $a waits, directly or through other pieces, on piece $b:
# a walk of blockedBy within the set (keys as strings; cycle-safe).
def blocked_by_within($a; $b): . as $s
  | {seen: [], todo: [$a]}
  | until(.todo == [];
      .todo[0] as $c | .todo |= .[1:]
      | if any(.seen[]; . == $c) then .
        else .seen += [$c]
          | .todo += [$s.pieces[$c].blockedBy[] | tostring | select(. as $x | $s.pieces | has($x))] end)
  | any(.seen[1:][]; . == $b);
# The refusal for this report, or empty.
def rec_refusal: .pieces[$i] as $p
  | if $p == null then "unknown issue #\($i)"
    elif $p.state == "pending" then "#\($i) is pending (never launched)"
    elif $p.state == "merged" and $k == "DONE" and $pb == $p.branch and $sha == $p.sha then empty
    elif ($p | terminal) then "#\($i) is \($p.state)"
    elif $k == "DONE" and $pb != $p.branch then "#\($i) reported branch \($pb), launched on \($p.branch)"
    elif $k == "STUCK" and $n == $i then "#\($i) cannot need itself"
    elif $k == "STUCK" and $n != "" and (.pieces | has($n) | not) then "#\($i) needs unknown issue #\($n)"
    elif $k == "STUCK" and $n != "" and (.pieces[$n].state == "dropped" or .pieces[$n].state == "failed")
      then "#\($i) needs #\($n), which is \(.pieces[$n].state) and cannot merge"
    elif $k == "STUCK" and $n != "" and blocked_by_within($n; $i)
      then "#\($n) is blocked by #\($i): needing it would deadlock"
    else empty end;
# The tracking file with this (accepted) report applied.
def rec_update: .pieces[$i] |=
  if .state == "merged" or $k == "STARTED" then .
  elif $k == "DONE" then .state = "done" | .sha = $sha | del(.needs, .reason)
  else .state = "stuck" | .needs = (if $n == "" then null else ($n | tonumber) end) | .reason = $r end;
'

# bad_report <why> — refuses a malformed report line.
bad_report() { refuse "bad report: $*"; }

cmd_record() {
  [ "$#" -eq 1 ] || usage
  line="$1"
  # One trailing CR (a CRLF line end) and trailing spaces are not part of it.
  case "$line" in *$'\r') line="${line%$'\r'}" ;; esac
  case "$line" in *[[:cntrl:]]*) bad_report "control character in the line" ;; esac
  while [[ "$line" == *" " ]]; do line="${line% }"; done
  kind=""; itok=""; rest=""
  read -r kind itok rest <<<"$line"
  [ -n "$itok" ] || bad_report "missing fields"
  case "$kind" in STARTED|DONE|STUCK) ;; *) bad_report "unknown report keyword" ;; esac
  case "$itok" in '#'*) issue="${itok#\#}" ;; *) issue="" ;; esac
  is_issue "$issue" || bad_report "bad issue"
  pb=""; sha=""; needs=""; reason=""
  case "$kind" in
    STARTED)
      [ -z "$rest" ] || bad_report "unexpected trailing text"
      ;;
    DONE)
      extra=""
      read -r pb sha extra <<<"$rest"
      [ -n "$sha" ] || bad_report "missing DONE fields"
      [ -z "$extra" ] || bad_report "unexpected trailing text"
      is_branch "$pb" || bad_report "bad branch"
      # An explicit digit list: a range like a-f can match capitals in some locales.
      case "$sha" in *[!0123456789abcdef]*) bad_report "bad sha" ;; esac
      [ "${#sha}" -eq 40 ] || bad_report "bad sha"
      ;;
    STUCK)
      first="${rest%% *}"
      case "$first" in
        needs=*)
          needs="${first#needs=}"
          case "$needs" in '#'*) needs="${needs#\#}" ;; *) needs="" ;; esac
          is_issue "$needs" || bad_report "bad needs"
          case "$rest" in *" "*) rest="${rest#* }" ;; *) rest="" ;; esac
          rest="${rest#"${rest%%[! ]*}"}"
          ;;
      esac
      [ -n "$rest" ] || bad_report "missing reason"
      reason="$rest"
      ;;
  esac
  need_state
  set -- --arg k "$kind" --arg i "$issue" --arg pb "$pb" --arg sha "$sha" --arg n "$needs" --arg r "$reason"
  why="$(jq -r "$@" "$RDEFS"'rec_refusal' "$FILE")" || die "cannot read $FILE"
  [ -z "$why" ] || refuse "$why"
  # A report that changes nothing writes nothing, so the file stays byte-identical.
  if ! jq -e "$@" "$RDEFS"'rec_update == .' "$FILE" >/dev/null 2>&1; then
    write_state "$@" "$RDEFS"'rec_update' "$FILE"
  fi
  echo "#$issue $(jq -r --arg i "$issue" '.pieces[$i].state' "$FILE")"
}

# cmd_mark <to> <issue> — the orchestrator's own transitions: merged, failed
# and dropped.
cmd_mark() {
  to="$1"; shift
  [ "$#" -eq 1 ] || usage
  issue="$1"
  is_issue "$issue" || die "bad issue: $issue"
  need_state
  why="$(jq -r --arg i "$issue" --arg to "$to" '.pieces[$i] as $p
    | if $p == null then "unknown issue #\($i)"
      elif $p.state == $to then empty
      elif $to == "merged" and $p.state != "done" then "#\($i) is \($p.state), not done"
      elif $to == "failed" and (any("running", "done", "stuck"; . == $p.state) | not)
        then "#\($i) is \($p.state), not running, done or stuck"
      elif $to == "dropped" and $p.state == "merged" then "#\($i) is merged"
      else empty end' "$FILE")" || die "cannot read $FILE"
  [ -z "$why" ] || refuse "$why"
  if ! jq -e --arg i "$issue" --arg to "$to" '.pieces[$i].state == $to' "$FILE" >/dev/null 2>&1; then
    write_state --arg i "$issue" --arg to "$to" '.pieces[$i].state = $to' "$FILE"
  fi
  echo "#$issue $to"
}

cmd_finished() {
  [ "$#" -eq 0 ] || usage
  need_state
  jq -r '[.pieces[] | .state == "merged" or .state == "dropped"] | all' "$FILE" || die "cannot read $FILE"
}

cmd_summary() {
  [ "$#" -eq 0 ] || usage
  need_state
  echo "| Issue | State | Branch | Agent | Blocked by | Notes |"
  echo "|---|---|---|---|---|---|"
  jq -r '
    def cell: tostring | gsub("[\t\r\n]+"; " ") | gsub("\\|"; "\\|");
    # Per piece, the dropped issues it waits behind: a dropped in-set blocker,
    # or one reached through unmerged blockers. One round per piece reaches
    # the end of any chain.
    def dropped_roots: . as $s
      | reduce range(0; .pieces | length) as $_ (.pieces | map_values([]);
          . as $d
          | with_entries(.key as $k | .value = ([$s.pieces[$k].blockedBy[] | tostring
              | select(. as $b | $s.pieces | has($b))
              | if $s.pieces[.].state == "dropped" then [tonumber]
                elif $s.pieces[.].state == "merged" then []
                else $d[.] end] | add // [] | unique)));
    dropped_roots as $dr
    | .pieces | to_entries | sort_by(.key | tonumber)[]
    | .value as $v
    | (if $v.state == "dropped" then "not delivered (dropped)"
       elif $v.state != "merged" and ($dr[.key] | length) > 0
         then "not delivered (blocked by dropped \($dr[.key] | map("#\(.)") | join(", ")))"
       elif $v.state == "stuck"
         then (if $v.needs == null then "" else "needs #\($v.needs): " end) + ($v.reason // "")
       else "" end) as $note
    | "| #\(.key) | \($v.state | cell) | \($v.branch // "" | cell) | \($v.agent // "" | cell) | \([$v.blockedBy[] | "#\(.)"] | join(", ") | cell) | \($note | cell) |"' "$FILE" \
    || die "cannot read $FILE"
}

# ------------------------------------------------------------------ main

ARGS=("$@")  # re-passed verbatim when a writing command re-execs under the lock
while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch) [ "$#" -ge 2 ] || usage; BR="$2"; [ -n "$BR" ] || usage; shift 2 ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ "$#" -ge 1 ] || usage
CMD="$1"; shift
case "$CMD" in
  path|register|launchable|launch|record|merged|failed|dropped|finished|summary) ;;
  *) usage ;;
esac
set_paths
# Every command that writes takes the lock here and keeps it until it exits.
case "$CMD" in
  register) with_lock --create ;;
  launch|record|merged|failed|dropped) with_lock ;;
esac
case "$CMD" in
  path) cmd_path "$@" ;;
  register) cmd_register "$@" ;;
  launchable) cmd_launchable "$@" ;;
  launch) cmd_launch "$@" ;;
  record) cmd_record "$@" ;;
  merged|failed|dropped) cmd_mark "$CMD" "$@" ;;
  finished) cmd_finished "$@" ;;
  summary) cmd_summary "$@" ;;
esac
