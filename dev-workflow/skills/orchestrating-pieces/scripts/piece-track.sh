#!/usr/bin/env bash
# piece-track.sh — an orchestrator's only reader and writer of its piece-tracking file.
#
#   piece-track.sh [--branch <b>] path                       print the tracking-file path
#   piece-track.sh [--branch <b>] register <snapshot.json> [--depth <n>] [--live-cap <n>] [--depth-cap <n>]
#   piece-track.sh [--branch <b>] launchable                 issues to launch now, one per line, ascending
#   piece-track.sh [--branch <b>] launch <issue> <agent> <session-id> <piece-branch> <base-sha>
#   piece-track.sh [--branch <b>] record <report-line>       record one piece agent's report
#   piece-track.sh [--branch <b>] merged <issue>             done -> merged (after the fast-forward)
#   piece-track.sh [--branch <b>] failed <issue>             running, done or stuck -> failed
#   piece-track.sh [--branch <b>] dropped <issue>            any state but merged -> dropped (the user's call)
#   piece-track.sh [--branch <b>] accept <issue>             unverified pending -> merged (only on the user's confirmation)
#   piece-track.sh [--branch <b>] finished                   true or false: every piece merged or dropped
#   piece-track.sh [--branch <b>] summary                    Markdown table for the PR body
#   piece-track.sh [--branch <b>] reconcile --sessions <f> --snapshot <f> --tips <f> --name-prefix <p> [--depth <n>] [--live-cap <n>] [--depth-cap <n>]
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
# launch records agent, session, branch and base: the full 40-hex SHA of the
# commit the piece branch was created from (the orchestrator's head then).
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
#   launch    pending, failed        -> running (a failed piece relaunches: agent,
#                                       session, branch and base are re-recorded; sha,
#                                       needs and reason are cleared; the caps and the
#                                       uniqueness checks apply as for a first launch)
#   STARTED   running, done, stuck   -> unchanged (a late STARTED never regresses)
#   DONE      running, done, stuck   -> done, sha set (a new sha replaces the old:
#                                       the resync re-report); needs, reason cleared
#             merged                 -> unchanged, only for the same branch and sha
#   STUCK     running, done, stuck   -> stuck, needs and reason set, sha kept
#   merged    done                   -> merged;   merged -> unchanged
#   failed    running, done, stuck   -> failed (the session ended unmerged);
#             failed                 -> unchanged
#   dropped   any state but merged   -> dropped;  dropped -> unchanged
#   accept    pending with an unverified fact -> merged (branch and sha from
#             the fact, the fact removed); merged -> unchanged. Run it only
#             after the user confirms the contained tip is the piece's work.
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
# issue, a piece neither pending nor failed, a piece branch equal to the orchestrator's branch,
# a session id or piece branch already recorded on another piece, a blocked
# piece, and a launch at either cap; it does not insist on launchable's
# lowest-first order.
#
# Reconcile (after an orchestrator restart) corrects the file from facts the
# orchestrator gathers and passes as files; the CLI itself never asks claude,
# gh or git (beyond git check-ref-format on --branch).
#   --snapshot  the dependency snapshot, as for register, read from GitHub now.
#   --sessions  the output of `claude agents --json` (Claude Code 2.1.x): an
#               array of rows {"name": "...", "sessionId": "<uuid>", "id":
#               "<short id>", "kind": "background"|"interactive", "status":
#               "busy"|"idle"|"waiting", "state", "pid", "cwd", "startedAt", ...}.
#               A row with a pid is live (an idle row with state "done" and a
#               pid included); a row with none has ended. Seen on 2.1.300:
#               the completed rows `--all` adds lack both pid and status, and
#               every live row, idle ones included, has both; the platform
#               drops pid when the process exits. name is null/absent or
#               non-empty text without control characters; sessionId is
#               required and id optional, each a non-empty string without
#               whitespace; status a string or null/absent; pid an integer
#               >= 1 or null/absent; other fields are ignored.
#   --tips      per piece, the facts about its branch, absent when the branch
#               does not exist: {"35": {"branch": "feat/orch-35", "tip":
#               "<40 lowercase hex>", "contained": true, "advanced": true}}.
#               contained is true when the tip is an ancestor of, or equal to,
#               the orchestrator's branch head (git merge-base --is-ancestor
#               <tip> <head>); advanced is true when the piece's recorded base
#               is an ancestor of, or equal to, the tip (git merge-base
#               --is-ancestor <base> <tip>; false when no base is recorded).
#               Both required booleans. Keys must be issues in the file or the
#               snapshot.
#   --name-prefix <p>  the session-name scheme: a piece's agent is named
#               <p><issue> (e.g. PROJ-12-#35 for --name-prefix PROJ-12-#).
#   --depth/--live-cap/--depth-cap  as for register; given, they replace the
#               stored values, else the file's (or register's defaults) stand.
# Every piece of the snapshot is kept or added (pending); its blockedBy and the
# external states are replaced by the snapshot's. A piece in the file but not
# in the snapshot is kept, with its blockers, and reported on stderr; an old
# external entry that only kept pieces still reference is kept too, reported
# as "external #<x> kept for #<n>". Then, per piece, in order:
#   1. merged and dropped stay as they are. A new piece branch forks at the
#      orchestrator's head, so its tip is contained before any commit: a
#      contained tip makes a piece merged only when the piece has a recorded
#      base, the tip differs from it and the tip is advanced (sha = the tip).
#      Tip equal to the base: no evidence, the rules below decide. A tip not
#      advanced (an older ancestor): not merged, reported on stderr. No
#      recorded base: not merged, reported as "unverified-contained #<n>
#      tip=<sha> branch=<branch>". That happens after a rebuild, for a
#      never-launched pending piece in an existing file whose branch already
#      exists at the fork point, and for a legacy launch record without a
#      base. A pending piece also gets "unverified": {"branch", "tip"} for the
#      user to decide (accept or dropped); launchable skips it and launch
#      refuses it. A launched piece stores no fact: it resolves through DONE
#      and merged. A later reconcile that no longer finds the tip contained
#      removes the fact ("#<n> unverified-contained cleared"). A tip for
#      another branch than the recorded one is reported on stderr and ignored.
#   2. The recorded session live (a live row whose name is the recorded agent
#      and whose sessionId or id is the recorded session): pending and running
#      become running; done and stuck stay; failed stays failed (failing is
#      the orchestrator's decision), reported on stderr.
#   3. The recorded session not live: running and stuck become failed; done
#      stays done (its report survived; the merge is pending). A live row with
#      the recorded id under another name leaves the piece as it is, reported.
#   4. A live row named <p><n>, n any issue number in or out of the set, that
#      no piece recorded is an unknown session (a second orchestrator on this
#      branch, or a launch never recorded): reported, never adopted, no state
#      change (with no file, every such row is unknown).
# stdout, one line each: changed caps and external states, then per issue
# "#<n> added (pending)", "#<n> blocked by <old> -> <new>",
# "#<n> <old> -> <new> (<why>)", "unverified-contained ..."; then
# "unknown-session #<n> session=<sessionId> name=<name>" per unknown session;
# last "reconciled <branch>: pending N, running N, ... ; unknown sessions N".
# Exit 0 even with unknown sessions or unverified tips.
# A missing tracking file, or one that is unreadable, fails the shape check or
# belongs to another branch, is rebuilt from the snapshot as by register (the
# bad file renamed to <file>.corrupt.<UTC time>.<pid>, reported), then
# corrected. Refused (exit 1, nothing written or moved): any input not exactly
# one valid JSON value, a snapshot register would refuse (a cycle included),
# a bad session row or tip entry, a tip for an issue outside the set, and a
# result that fails the snapshot checks once the kept pieces are added (an
# unknown blocker, an issue both a piece and external, a cycle).
# Same inputs again change nothing: the file stays byte-identical. The bad
# file is moved aside before the new one is written, so an I/O failure in
# that write leaves no tracking file (the old bytes kept as .corrupt.*); the
# next reconcile treats it as missing and rebuilds.
#
# Every write goes to a temp file in the tracking directory, is validated, and
# is renamed over the tracking file, so a failed or interrupted write leaves the
# previous file byte-identical. PIECE_TRACK_TEST_ABORT_BEFORE_RENAME=1 (tests
# only) stops a write after the temp file is complete and before the rename.
#
# Lock: every writing command (register, launch, record, merged, failed,
# dropped, reconcile, accept) holds one lock per tracking
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
# always read a whole file. Only register and reconcile create the state directory; a launch
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
# --arg/--argjson, never evaluated; reconcile's inputs are read with
# --slurpfile. Never calls claude or gh. Bash 3.2 compatible.
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
# A full commit SHA: 40 lowercase hex (an explicit digit list, as in record).
is_sha() {
  case "$1" in ''|*[!0123456789abcdef]*) return 1 ;; esac
  [ "${#1}" -eq 40 ]
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
     | select(.value.state == "pending" and .value.unverified == null and (.value | holds($s) | length) == 0)
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

# jq definitions for reconcile's session listing and tips.
INDEFS='
def ctl: explode | any(.[]; . < 32 or (. >= 127 and . < 160));
def word: type == "string" and length > 0 and (explode | any(.[]; . <= 32 or (. >= 127 and . < 160)) | not);
def text: type == "string" and length > 0 and (ctl | not);
def optstr: . == null or type == "string";
def badrow: (type != "object") or ((.name == null or (.name | text)) | not) or (.sessionId | word | not)
  or ((.id == null or (.id | word)) | not) or (.status | optstr | not)
  or ((.pid == null or (.pid | type == "number" and . >= 1 and . == floor)) | not);
def badtip: (.key | test("^[1-9][0-9]{0,8}$") | not) or (.value | type != "object")
  or (.value.branch | text | not)
  or (.value.tip | (type == "string" and test("^[0-9a-f]{40}$")) | not)
  or (.value.contained | type != "boolean") or (.value.advanced | type != "boolean");
'
SESSCHECK='if type != "array" then "session listing is not a JSON array"
elif any(.[]; badrow) then "bad session entry: " + ([.[] | select(badrow)][0] | tojson)
else empty end'
TIPCHECK='if type != "object" then "tips are not a JSON object"
elif any(to_entries[]; badtip)
  then "bad tip entry: " + ([to_entries[] | select(badtip)][0] | "\(.key | tojson): \(.value | tojson)")
else empty end'

# reconcile, over (checked) inputs: $sf snapshot, $lf session listing, $tf
# tips, $of the old tracking file ([] when rebuilding), $b branch, $pfx name
# prefix, $d/$lc/$dc caps (null: keep or default). Yields {refusal} or
# {state, changed, out: [stdout lines], err: [stderr notes]}.
RECON='
# A listing row is the session recorded on piece $p: name and id both match
# (the id is the row'"'"'s sessionId or its short id).
def has_id($p): $p.session != null and (.sessionId == $p.session or .id == $p.session);
def is_rec($p): has_id($p) and .name == $p.agent;
def nums: map(tonumber) | sort;
def bl: if length == 0 then "none" else map("#\(.)") | join(", ") end;
# Rules 1-3 for piece $p ($k its key, $t its tip fact or null): {to, why},
# and optionally {note}, {tipnote} and {unverified: true}, or {}.
def decide($k; $p; $t; $live):
  if $p.state == "merged" or $p.state == "dropped" then {}
  else
    # A branch forks at the orchestrator'"'"'s head, so a contained tip proves a
    # merge only when it moved off the recorded base.
    (if $t == null or ($t.contained | not) or ($p.branch != null and $p.branch != $t.branch) then "no"
     elif $p.base == null then "unverified"
     elif $t.tip == $p.base then "no"
     elif $t.advanced | not then "behind"
     else "merged" end) as $m
    | if $m == "merged" then {to: "merged", why: "branch tip contained"}
      else (if $m == "unverified" then {unverified: true}
            elif $m == "behind"
              then {tipnote: "#\($k) tip \($t.tip) is contained but not ahead of base \($p.base): not merged"}
            else {} end)
        + (if $p.session == null then {}
           elif any($live[]; is_rec($p))
             then (if $p.state == "pending" or $p.state == "running" then {to: "running", why: "session live"}
                   elif $p.state == "failed" then {note: "#\($k) is failed but its session \($p.session) is live: left failed"}
                   else {} end)
           elif any($live[]; has_id($p))
             then {note: "#\($k) session \($p.session) is live under the name \([$live[] | select(has_id($p)) | .name][0]), not \($p.agent): left \($p.state)"}
           elif $p.state == "running" or $p.state == "stuck" then {to: "failed", why: "session ended"}
           else {} end)
      end
  end;

$sf[0] as $snap | [$lf[0][] | select(.pid != null)] as $live | $tf[0] as $tips
| ($of[0] // null) as $old
| ($snap | reduce .pieces[] as $p ({}; .[$p.issue | tostring] = ($p | blockers | unique))) as $blk
| (if $old == null then {version: 1, branch: $b, depth: 0, liveCap: 3, depthCap: 2, external: {}, pieces: {}}
   else $old end) as $o
| [$tips | keys[] | select(. as $k | ($blk | has($k)) or ($o.pieces | has($k)) | not)] as $stray
| if ($stray | length) > 0
  then {refusal: ("tips for issues not in the set: " + ($stray | nums | map("#\(.)") | join(", ")))}
  else
  # An old external entry that only kept pieces still reference stays.
  [$o.pieces | to_entries[] | .key as $k | select($blk | has($k) | not)
   | .value.blockedBy[] | tostring
   | select(. as $x | ($snap | ext | has($x) | not) and ($blk | has($x) | not)
                     and ($o.pieces | has($x) | not) and ($o.external | has($x)))
   | {x: ., k: $k}] as $keepx
  | ($o | .depth = ($d // .depth) | .liveCap = ($lc // .liveCap) | .depthCap = ($dc // .depthCap)
      | .external = (($snap | ext) + ($keepx | map({key: .x, value: $o.external[.x]}) | from_entries))) as $base
  | (if $old == null then []
     else [("depth", "liveCap", "depthCap") as $c | select($o[$c] != $base[$c]) | "\($c) \($o[$c]) -> \($base[$c])"] end
     + [($o.external + $base.external) | keys | nums[] | tostring as $x
        | if ($o.external | has($x) | not) then "external #\($x) added (\($base.external[$x]))"
          elif ($base.external | has($x) | not) then "external #\($x) removed"
          elif $o.external[$x] != $base.external[$x] then "external #\($x) \($o.external[$x]) -> \($base.external[$x])"
          else empty end]) as $head
  | (reduce ([($base.pieces | keys[]), ($blk | keys[])] | unique | nums[] | tostring) as $k
      ({s: $base, out: [], err: []};
       .s.pieces[$k] as $p0 | $tips[$k] as $t
       | (if $p0 == null then {state: "pending", blockedBy: [], agent: null, session: null, branch: null} else $p0 end
          | if $blk | has($k) then .blockedBy = $blk[$k] else . end) as $p
       | decide($k; $p; $t; $live) as $r
       | ($p | if $r.to == "merged" then .state = "merged" | .branch = (.branch // $t.branch) | .sha = $t.tip
               elif $r.to != null then .state = $r.to else . end
               # The unverified fact holds only while this reconcile finds it.
               # Only a pending piece holds it: accept takes nothing else, and a
               # launched piece resolves through DONE and merged.
               | if $r.unverified and .state == "pending" then .unverified = {branch: $t.branch, tip: $t.tip}
                 else del(.unverified) end) as $new
       | .s.pieces[$k] = $new
       | .out += (if $p0 == null then ["#\($k) added (pending)"] else [] end)
       | .out += (if $p0 != null and $p0.blockedBy != $p.blockedBy
                  then ["#\($k) blocked by \($p0.blockedBy | bl) -> \($p.blockedBy | bl)"] else [] end)
       | .out += (if $new.state != $p.state then ["#\($k) \($p.state) -> \($new.state) (\($r.why))"] else [] end)
       | .out += (if $r.unverified then ["unverified-contained #\($k) tip=\($t.tip) branch=\($t.branch)"]
                  elif $p.unverified != null then ["#\($k) unverified-contained cleared"] else [] end)
       | .err += (if $blk | has($k) then [] else ["#\($k) is not in the snapshot; kept as \($new.state)"] end)
       | .err += (if $t != null and $p.branch != null and $p.branch != $t.branch
                     and $p.state != "merged" and $p.state != "dropped"
                  then ["#\($k) tip fact is for branch \($t.branch), recorded \($p.branch): ignored"] else [] end)
       | .err += [$r.tipnote // empty, $r.note // empty])) as $acc
  | ($acc.s | .pieces |= (to_entries | sort_by(.key | tonumber) | from_entries)) as $new
  # Rule 4: a live session named <prefix><issue>, for any issue number, that
  # no piece recorded is unknown (another orchestrator, or a lost launch):
  # reported, never adopted.
  | [$live[] | . as $row | (.name // "") as $nm
     | select($nm | startswith($pfx)) | ($nm | ltrimstr($pfx)) as $i
     | select($i | test("^[1-9][0-9]{0,8}$"))
     | select(any($new.pieces[]; . as $p | $row | is_rec($p)) | not)
     | {i: ($i | tonumber), sid: .sessionId, nm: $nm}] | sort_by(.i, .sid) as $unk
  | {state: $new, changed: ($new != $old),
     err: ($acc.err + [$keepx | group_by(.x | tonumber)[]
                       | "external #\(.[0].x) kept for \(map(.k) | nums | map("#\(.)") | join(", "))"]),
     out: ($head + $acc.out
           + [$unk[] | "unknown-session #\(.i) session=\(.sid) name=\(.nm)"]
           + ["reconciled \($b): "
              + (['"$STATES"'] | map(. as $st | "\($st) \([$new.pieces[] | select(.state == $st)] | length)") | join(", "))
              + "; unknown sessions \($unk | length)"])}
  end
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
  [ "$#" -eq 5 ] || usage
  issue="$1"; agent="$2"; sid="$3"; pbr="$4"; base="$5"
  is_issue "$issue" || die "bad issue: $issue"
  is_text "$agent" || die "bad agent name"
  is_word "$sid" || die "bad session id"
  is_branch "$pbr" || die "bad branch: $pbr"
  is_sha "$base" || die "bad base sha: $base"
  need_state
  reason="$(jq -r --arg i "$issue" --arg sid "$sid" --arg pb "$pbr" "$SDEFS"'
    . as $s | .pieces[$i] as $p
    # the first other piece already recorded with session $sid / branch $pb, or null
    | ([.pieces | to_entries | sort_by(.key | tonumber)[]
        | select(.key != $i and .value.session == $sid) | .key][0]) as $dsid
    | ([.pieces | to_entries | sort_by(.key | tonumber)[]
        | select(.key != $i and .value.branch == $pb) | .key][0]) as $dpb
    | if $p == null then "unknown issue #\($i)"
      elif $p.state != "pending" and $p.state != "failed" then "#\($i) is \($p.state), not pending or failed"
      elif $p.unverified != null
        then "#\($i) has an unverified contained tip \($p.unverified.tip) on \($p.unverified.branch): accept or drop it"
      elif $pb == .branch then "piece branch \($pb) is the orchestrator'"'"'s branch"
      elif $dsid != null then "session id \($sid) is already recorded on #\($dsid)"
      elif $dpb != null then "piece branch \($pb) is already recorded on #\($dpb)"
      elif ($p | holds($s) | length) > 0
        then "#\($i) is blocked by " + ([$p | holds($s)[] | "#\(.) (\(blocker_state($s)))"] | join(", "))
      elif .depth >= .depthCap then "depth cap reached (depth \(.depth), cap \(.depthCap))"
      elif livecount >= .liveCap then "live cap reached (\(livecount) live, cap \(.liveCap))"
      else empty end' "$FILE")" || die "cannot read $FILE"
  [ -z "$reason" ] || refuse "$reason"
  write_state --arg i "$issue" --arg a "$agent" --arg sid "$sid" --arg pb "$pbr" --arg bs "$base" \
    '.pieces[$i] |= (del(.sha, .needs, .reason) + {state: "running", agent: $a, session: $sid, branch: $pb, base: $bs})' "$FILE"
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

# cmd_accept <issue> — the user's call on an unverified contained tip: the
# pending piece becomes merged with the branch and tip reconcile recorded.
cmd_accept() {
  [ "$#" -eq 1 ] || usage
  issue="$1"
  is_issue "$issue" || die "bad issue: $issue"
  need_state
  why="$(jq -r --arg i "$issue" '.pieces[$i] as $p
    | if $p == null then "unknown issue #\($i)"
      elif $p.state == "merged" then empty
      elif $p.state != "pending" then "#\($i) is \($p.state), not pending"
      elif $p.unverified == null then "#\($i) has no unverified contained tip to accept"
      else empty end' "$FILE")" || die "cannot read $FILE"
  [ -z "$why" ] || refuse "$why"
  if ! jq -e --arg i "$issue" '.pieces[$i].state == "merged"' "$FILE" >/dev/null 2>&1; then
    write_state --arg i "$issue" \
      '.pieces[$i] |= (.state = "merged" | .branch = .unverified.branch | .sha = .unverified.tip | del(.unverified))' "$FILE"
  fi
  echo "#$issue merged"
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

# one_json <file> <what> — refuses unless <file> holds exactly one JSON value.
one_json() {
  n="$(jq -s 'length' "$1" 2>/dev/null)" || refuse "$2 not valid JSON: $1"
  [ "$n" = "1" ] || refuse "$2 not valid JSON (expected one value): $1"
}

cmd_reconcile() {
  sess=""; snap=""; tips=""; pfx=""; depth=null; lcap=null; dcap=null
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sessions) [ "$#" -ge 2 ] || usage; sess="$2"; shift 2 ;;
      --snapshot) [ "$#" -ge 2 ] || usage; snap="$2"; shift 2 ;;
      --tips) [ "$#" -ge 2 ] || usage; tips="$2"; shift 2 ;;
      --name-prefix)
        { [ "$#" -ge 2 ] && is_text "$2"; } || die "--name-prefix needs a non-empty name without control characters"
        pfx="$2"; shift 2 ;;
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
  { [ -n "$sess" ] && [ -n "$snap" ] && [ -n "$tips" ] && [ -n "$pfx" ]; } \
    || die "reconcile needs --sessions, --snapshot, --tips and --name-prefix"
  for f in "$sess" "$snap" "$tips"; do
    { [ -f "$f" ] && [ -r "$f" ]; } || die "cannot read $f"
  done
  one_json "$sess" "session listing is"
  one_json "$snap" "snapshot is"
  one_json "$tips" "tips are"
  reason="$(jq -r "$SNAPDEFS$CHECK" "$snap")" || die "cannot check snapshot: $snap"
  [ -z "$reason" ] || refuse "$reason"
  reason="$(jq -r "$INDEFS$SESSCHECK" "$sess")" || die "cannot check session listing: $sess"
  [ -z "$reason" ] || refuse "$reason"
  reason="$(jq -r "$INDEFS$TIPCHECK" "$tips")" || die "cannot check tips: $tips"
  [ -z "$reason" ] || refuse "$reason"
  # A missing, unreadable or foreign file is rebuilt from the snapshot; it is
  # read with neither need_state nor VALID, so a bad file cannot stop reconcile.
  why=""
  if [ -e "$FILE" ] || [ -L "$FILE" ]; then
    [ -f "$FILE" ] || die "not a regular file: $FILE"
    if ! valid_file "$FILE"; then why="unreadable"
    elif ! jq -e --arg b "$BR" '.branch == $b' "$FILE" >/dev/null 2>&1; then why="foreign"
    fi
  else
    why="missing"
  fi
  old="$FILE"
  [ -z "$why" ] || old=/dev/null
  res="$(jq -nc --slurpfile sf "$snap" --slurpfile lf "$sess" --slurpfile tf "$tips" --slurpfile of "$old" \
           --arg b "$BR" --arg pfx "$pfx" --argjson d "$depth" --argjson lc "$lcap" --argjson dc "$dcap" \
           "$SNAPDEFS$RECON")" || die "cannot reconcile $FILE"
  reason="$(printf '%s' "$res" | jq -r '.refusal // empty')" || die "cannot reconcile $FILE"
  [ -z "$reason" ] || refuse "$reason"
  # Kept pieces keep their old blockers, so the snapshot's checks run again on
  # the combined result: unknown blockers, an issue both a piece and external,
  # and cycles through kept pieces.
  # Two guarded steps, not a pipe: a failed first jq must not pass as "no reason".
  graph="$(printf '%s' "$res" \
    | jq -c '.state | {pieces: [.pieces | to_entries[] | {issue: (.key | tonumber), blocked_by: .value.blockedBy}],
                       external}')" || die "cannot check the reconciled pieces"
  [ -n "$graph" ] || die "cannot check the reconciled pieces"
  reason="$(printf '%s' "$graph" | jq -r "$SNAPDEFS$CHECK")" || die "cannot check the reconciled pieces"
  [ -z "$reason" ] || refuse "with the kept pieces: $reason"
  aside=""
  case "$why" in
    unreadable|foreign)
      # Renamed aside, never deleted: the old bytes stay for the user to inspect.
      aside="$FILE.corrupt.$(date -u +%Y%m%dT%H%M%SZ).$$"
      mv "$FILE" "$aside" || die "cannot move $FILE aside"
      ;;
  esac
  # Same inputs, same file: a reconcile that changes nothing writes nothing.
  if [ "$(printf '%s' "$res" | jq -r '.changed')" = "true" ]; then
    write_state -n --argjson r "$res" '$r.state'
  fi
  case "$why" in
    missing) echo "piece-track.sh: no tracking file for $BR: rebuilt from the snapshot" >&2 ;;
    unreadable) echo "piece-track.sh: unreadable tracking file kept as $aside: rebuilt from the snapshot" >&2 ;;
    foreign) echo "piece-track.sh: tracking file of another branch kept as $aside: rebuilt from the snapshot" >&2 ;;
  esac
  printf '%s' "$res" | jq -r '.err[] | "piece-track.sh: " + .' >&2
  printf '%s' "$res" | jq -r '.out[]' || die "cannot print the reconcile report"
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
  path|register|launchable|launch|record|merged|failed|dropped|finished|summary|reconcile|accept) ;;
  *) usage ;;
esac
set_paths
# Every command that writes takes the lock here and keeps it until it exits.
case "$CMD" in
  register|reconcile) with_lock --create ;;
  launch|record|merged|failed|dropped|accept) with_lock ;;
esac
case "$CMD" in
  path) cmd_path "$@" ;;
  register) cmd_register "$@" ;;
  launchable) cmd_launchable "$@" ;;
  launch) cmd_launch "$@" ;;
  record) cmd_record "$@" ;;
  merged|failed|dropped) cmd_mark "$CMD" "$@" ;;
  accept) cmd_accept "$@" ;;
  finished) cmd_finished "$@" ;;
  summary) cmd_summary "$@" ;;
  reconcile) cmd_reconcile "$@" ;;
esac
