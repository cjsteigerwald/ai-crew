# ledger.jq — the jq programs of ledger.sh, loaded with `jq -f` (jq 1.6 and 1.7).
#
# ledger.sh passes `--arg op <program>` plus that program's own --arg/--argjson
# values; the input is the ledger. Every program returns {rc, out: [lines],
# reason, state}. Named arguments are bound from $ARGS.named, so a variable
# that only another program uses is null here.
$ARGS.named as {op: $op, n: $n, live: $live,
                ev: $ev, a1: $a1, a2: $a2, a3: $a3, edge: $edge, anc: $anc, tip: $tip,
                kind: $kind, name: $name, wt: $wt, br: $br, base: $base,
                cand: $cand, exp: $exp,
                from: $from, mkind: $mkind, mgen: $mgen, mbranch: $mbranch, sha: $sha,
                synced: $synced, needs: $needs, mreason: $mreason, head: $head,
                sid: $sid, ag: $ag, ancids: $ancids}
|
def ok($out): {rc: 0, out: $out, state: .};
def noop($r): {rc: 10, reason: $r};
# A no-op that still prints (e.g. ask-user= for a STUCK on a claimed row).
def noop_out($r; $out): {rc: 10, reason: $r, out: $out};
def reject($r): {rc: 20, reason: $r};
def refuse($r): {rc: 30, reason: $r};
def bad($r): {rc: 2, reason: $r};
def has_v($a; $v): ($a | index([$v])) != null;
def terminal($s): $s == "merged" or $s == "cancelled";
def blocked($s): $s | startswith("blocked-on #");
def islive($k): has_v($live; $k);
# live in the transition table sense, minus the claimed rows (done-claimed, verifying)
def active($k): islive($k) and ((.issues[$k].status == "done-claimed" or .issues[$k].status == "verifying") | not);
def intent_at($id): (.intents | map(.id == $id) | index(true));
def close_intent($id; $outcome):
  .intents |= map(if .id == $id then .open = false | .outcome = $outcome else . end);
# Close every open intent of issue $k (drop, cancel-ticket).
def close_issue_intents($k; $outcome):
  .intents |= map(if .open and ((.n | tostring) == $k) then .open = false | .outcome = $outcome else . end);
def one_line: gsub("[\t\r\n]+"; " ");
# Add an outbox entry for issue $k, generation $g, addressed to session name $to;
# it supersedes any older entry for $k.
def outbox_put_to($k; $g; $to; $line):
  .outbox = ([.outbox[] | select(.n != ($k | tonumber))]
             + [{n: ($k | tonumber), gen: $g, to: $to, line: ($line | one_line)}]);
# The usual case: to the issue's recorded session, at its current gen.
def outbox_put($k; $line): outbox_put_to($k; .issues[$k].gen; .issues[$k].sessionName; $line);
# An entry's target: its `to`, else (older entries) the issue's recorded session name.
def entry_to($s): .to // $s.issues[(.n | tostring)].sessionName;
# CANCEL #k to the session of k's open launch/relaunch intent, if any: the
# session may already run (a crash between launch and record). Call it before
# the intent is closed (ruling T6-C2).
def cancel_intent_session($k):
  ([ .intents[] | select(.open and (.n | tostring) == $k and (.kind == "launch" or .kind == "relaunch")) ]
   | first) as $in
  | if $in == null then . else outbox_put_to($k; $in.gen; $in.sessionName; "CANCEL #\($k)") end;
def has_launch_intent($k):
  any(.intents[]; .open and (.n | tostring) == $k and (.kind == "launch" or .kind == "relaunch"));
def outbox_drop_cancel($k):
  .outbox |= map(select((.n == ($k | tonumber) and (.line | startswith("CANCEL #"))) | not));
# Clear issue $k's RESYNC/REWORK entries for gen $g (a valid message arrived).
# A CANCEL entry stays until its session has ended (json event or reconcile).
def outbox_clear_gen($k; $g):
  .outbox |= map(select((.n == ($k | tonumber) and .gen == $g
                         and ((.line | startswith("CANCEL #")) | not)) | not));
# Record launch/relaunch intent $in as launched with session $sid, closing it.
# Shared by `event launch|relaunch` and `reconcile`: gen+1, the session joins the
# issue's session history, any new generation resets the rework count.
def record_launch($k; $in; $sid):
  .issues[$k] |= (.status = "launched" | .gen = $in.gen | .sessionName = $in.sessionName
                  | .sessionId = $sid | .worktree = $in.worktree | .branch = $in.branch
                  | .startSha = $in.baseSha | .claim = null
                  | .sessions = ((.sessions // []) + [{gen: $in.gen, name: $in.sessionName, sessionId: $sid}])
                  | .rework = 0
                  | if $in.kind == "relaunch" then .reason = null else . end)
  | close_intent($in.id; "launched");
# The one transition to merged: in the same write, every `blocked-on #k` issue becomes pending.
def to_merged($k; $sha):
  ("blocked-on #" + $k) as $b
  | .issues[$k].status = "merged"
  | .issues[$k].mergeSha = $sha
  | .issues |= with_entries(if .value.status == $b then .value.status = "pending" else . end);

# ------------------------------------------------------------------ intent launch|relaunch
if $op == "intent-launch" then
  . as $s | .issues[$n] as $i
  | (if $kind == "launch" then "pending" else "failed" end) as $from
  | [ .intents[] | select(.open and (.kind == "launch" or .kind == "relaunch")) ] as $openl
  | ($live | length) as $nlive
  | ([ $openl[] | select((.n | tostring) != $n) ] | length) as $pending_launches
  | [ ($i.blockers // [])[] | tostring | select(($s.issues[.].status // "") != "merged") ] as $unmerged
  | [ ($i.external // [])[] | select(.closed != true) | .n | tostring ] as $open_ext
  | [ .issues | to_entries[] | select(.key != $n) | .key as $k
      | select(.value.gen > 0 or any($openl[]; (.n | tostring) == $k)) ] as $others
  | if $i.status != $from then refuse("intent \($kind) needs #\($n) \($from), it is \($i.status)")
    elif any(.intents[]; .open and (.n | tostring) == $n) then refuse("#\($n) already has an open intent")
    elif ($unmerged | length) > 0 then refuse("blocker #\($unmerged[0]) of #\($n) is not merged")
    elif ($open_ext | length) > 0 then refuse("external blocker #\($open_ext[0]) of #\($n) is open")
    elif ($nlive + $pending_launches) >= (.cap // 3) then refuse("no free slot (\($nlive) live, cap \(.cap // 3))")
    elif .canary != "passed" and ($others | length) > 0 then refuse("canary not passed and #\($others[0].key) already launched")
    else
      ("i" + ((.intents | length) + 1 | tostring)) as $id
      | .intents += [{ id: $id, kind: $kind, n: ($n | tonumber), gen: ($i.gen + 1),
                       prior: $i.status, sessionName: $name, worktree: $wt,
                       branch: $br, baseSha: $base, open: true }]
      | ok(["intent=\($id)"])
    end

# ------------------------------------------------------------------ intent merge
elif $op == "intent-merge" then
  .issues[$n] as $i
  | if $i.status != "verifying" then refuse("intent merge needs #\($n) verifying, it is \($i.status)")
    elif any(.intents[]; .open and (.n | tostring) == $n) then refuse("#\($n) already has an open intent")
    else
      ("i" + ((.intents | length) + 1 | tostring)) as $id
      | .intents += [{ id: $id, kind: "merge", n: ($n | tonumber), gen: $i.gen,
                       candidateSha: $cand, expectedHead: $exp, open: true }]
      | ok(["intent=\($id)"])
    end

# ------------------------------------------------------------------ events
elif $op == "event" then (
.issues[$n] as $i | $i.status as $st
| if $ev == "launch" or $ev == "relaunch" then
    intent_at($a1) as $x
    | (if $x == null then null else .intents[$x] end) as $in
    | (if $ev == "launch" then "pending" else "failed" end) as $from
    | if $in == null or $in.kind != $ev or ($in.n | tostring) != $n then refuse("no \($ev) intent \($a1) for #\($n)")
      elif ($in.open | not) then
        (if $i.sessionId == $a2 and $i.gen == $in.gen then noop("intent \($a1) already recorded")
         else refuse("intent \($a1) is closed") end)
      elif $st != $from then refuse("\($ev) needs #\($n) \($from), it is \($st)")
      else record_launch($n; $in; $a2) | ok(["launched"])
      end

  elif $ev == "launch-failed" then
    intent_at($a1) as $x
    | (if $x == null then null else .intents[$x] end) as $in
    | if $in == null or (($in.kind == "launch" or $in.kind == "relaunch") | not) or ($in.n | tostring) != $n
      then refuse("no launch intent \($a1) for #\($n)")
      elif ($in.open | not) then noop("intent \($a1) is already closed")
      else
        (if terminal($st) then . else .issues[$n].status = $in.prior end)
        | close_intent($a1; "launch-failed")
        | ok([.issues[$n].status])
      end

  elif $ev == "queue-check" then
    if $st != "done-claimed" then refuse("queue-check needs #\($n) done-claimed, it is \($st)")
    elif $a1 == "stale" then
      .issues[$n].status = "resync-requested" | .issues[$n].resyncs += 1
      | outbox_put($n; "RESYNC #\($n) \($a2)")
      | ok(["resync-requested"])
    else .issues[$n].status = "verifying" | ok(["verifying"])
    end

  elif $ev == "gate" then
    if $a1 == "merged" then
      intent_at($a2) as $x
      | (if $x == null then null else .intents[$x] end) as $in
      | if $st == "merged" and $in != null and ($in.open | not) and ($in.n | tostring) == $n
        then noop("#\($n) already merged")
        elif $st != "verifying" then refuse("gate merged needs #\($n) verifying, it is \($st)")
        elif $in == null or $in.kind != "merge" or ($in.n | tostring) != $n or ($in.open | not)
        then refuse("no open merge intent \($a2) for #\($n)")
        else
          .issues[$n].gateResults += [{gen: $i.gen, result: "pass", text: $a3}]
          | to_merged($n; $in.candidateSha)
          | close_intent($a2; "merged")
          | ok(["merged"])
        end
    elif $st != "verifying" then refuse("gate \($a1) needs #\($n) verifying, it is \($st)")
    elif $a1 == "resync" then
      (if $a3 == "" then null else intent_at($a3) end) as $x
      | (if $x == null then null else .intents[$x] end) as $in
      | if $a3 != "" and ($in == null or $in.kind != "merge" or ($in.n | tostring) != $n or ($in.open | not))
        then refuse("no open merge intent \($a3) for #\($n)")
        else
          .issues[$n].status = "resync-requested" | .issues[$n].resyncs += 1
          | outbox_put($n; "RESYNC #\($n) \($a2)")
          | (if $a3 == "" then . else close_intent($a3; "resync") end)
          | ok(["resync-requested"])
        end
    else
      ($i.rework + 1) as $k
      | .issues[$n].gateResults += [{gen: $i.gen, result: "fail", text: $a2}]
      | .issues[$n].rework = $k
      | if $k >= 3 then
          .issues[$n].status = "failed" | .issues[$n].reason = "rework budget" | ok(["failed"])
        else
          .issues[$n].status = "rework-\($k)/3"
          | outbox_put($n; "REWORK #\($n) \($a2)" | sub(" $"; ""))
          | ok(["rework-\($k)/3"])
        end
    end

  elif $ev == "stuck-accept" then
    if (active($n) | not) then refuse("stuck-accept needs #\($n) launched, started, rework or resync-requested, it is \($st)")
    elif (.issues | has($a1) | not) then refuse("#\($a1) is not an issue of this ticket")
    elif .issues[$a1].status == "merged" then refuse("#\($a1) is already merged; resync instead")
    elif $edge != "ok" then refuse($edge)
    else
      .issues[$n].status = "blocked-on #\($a1)"
      | .issues[$n].blockers |= (if index([($a1 | tonumber)]) then . else . + [($a1 | tonumber)] end)
      | outbox_put($n; "CANCEL #\($n)")
      | ok([.issues[$n].status])
    end

  # blocked-on #m: optional <m> must be m; back to pending. pending: <m> names
  # the edge to remove (e.g. its blocker was dropped); the status stays pending.
  elif $ev == "edge-remove" then
    if blocked($st) then
      ($st | ltrimstr("blocked-on #") | tonumber) as $m
      | if $a1 != "" and ($a1 | tonumber) != $m then refuse("edge-remove #\($a1): #\($n) is blocked on #\($m)")
        else
          .issues[$n].status = "pending"
          | .issues[$n].blockers |= map(select(. != $m))
          | ok(["pending"])
        end
    elif $st == "pending" then
      if $a1 == "" then refuse("edge-remove on pending #\($n) needs the blocker <m>")
      elif ((.issues[$n].blockers // []) | index([($a1 | tonumber)])) == null then
        noop("#\($n) has no edge to #\($a1)")
      else
        .issues[$n].blockers |= map(select(. != ($a1 | tonumber)))
        | ok(["pending"])
      end
    else refuse("edge-remove needs #\($n) blocked-on or pending, it is \($st)")
    end

  elif $ev == "drop" then
    if $st == "cancelled" then noop("#\($n) already cancelled")
    elif ($st == "pending" or blocked($st) or $st == "failed") | not then
      refuse("drop needs #\($n) pending, blocked-on or failed, it is \($st)")
    else
      (($n | tonumber) as $num
       | [ .issues | to_entries[]
           | select((terminal(.value.status) | not) and .key != $n
                    and has_v(.value.blockers // []; $num))
           | .key | tonumber ] | sort | map(tostring) | join(",")) as $deps
      | .issues[$n].status = "cancelled"
      | .issues[$n].reason = (if $a1 == "" then null else $a1 end)
      | cancel_intent_session($n)
      | close_issue_intents($n; "cancelled")
      | ok(["cancelled", "dependents=\($deps)"])
    end

  elif $ev == "json" then
    if $a1 == "failed" and active($n) then
      .issues[$n].status = "failed" | .issues[$n].reason = "session failed" | ok(["failed"])
    # Ended = no pid (ruling T6-C1): `done` with a pid is an idle live session,
    # so `done` drops the CANCEL only when the coordinator passes `nopid`.
    elif ($a1 == "failed" or $a1 == "stopped" or ($a1 == "done" and $a2 == "nopid"))
         and (blocked($st) or $st == "cancelled")
         and any(.outbox[]; .n == ($n | tonumber) and (.line | startswith("CANCEL #"))) then
      outbox_drop_cancel($n) | ok([$st])
    else noop("observation \($a1) on #\($n) \($st)")
    end

  elif $ev == "wake-failed" then
    if active($n) then .issues[$n].status = "failed" | .issues[$n].reason = "wake failed" | ok(["failed"])
    elif $st == "failed" then noop("#\($n) already failed")
    else refuse("wake-failed needs #\($n) launched, started, rework or resync-requested, it is \($st)")
    end

  elif $ev == "user-merged" then
    if $st == "merged" then noop("#\($n) already merged")
    elif $st != "failed" then refuse("user-merged needs #\($n) failed, it is \($st)")
    elif $anc != "yes" then refuse("branch \($i.branch) of #\($n) is not an ancestor of \(.ticketBranch)")
    else to_merged($n; $tip) | ok(["merged"])
    end

  elif $ev == "cancel-ticket" then
    [ .issues | to_entries[] | select(terminal(.value.status) | not) | .key ] as $todo
    | if ($todo | length) == 0 then noop("no issue left to cancel")
      else
        reduce $todo[] as $k (.;
          (if has_launch_intent($k) then cancel_intent_session($k)
           elif islive($k) then outbox_put($k; "CANCEL #\($k)")
           else . end)
          | .issues[$k].status = "cancelled"
          | .issues[$k].reason = (if $a1 == "" then null else $a1 end)
          | close_issue_intents($k; "cancelled"))
        | ok(["cancelled"])
      end

  elif $ev == "canary-passed" then
    if .canary == "passed" then noop("canary already passed")
    else .canary = "passed" | ok(["passed"])
    end

  else bad("unknown event \($ev)")
  end
)

# ------------------------------------------------------------------ message
# A parsed partner message ($from, $mkind, $n, $mgen, …). Sender binding comes
# first and rejects (20) before anything else is looked at; then DONE dedup
# (10); then, in one write, this gen's RESYNC/REWORK outbox entries are cleared
# and the transition applied.
elif $op == "message" then (
  .issues[$n] as $i
  | ($i.status // "") as $st
  | if $i == null then reject("unknown issue #\($n)")
    elif ($i.sessionName // null) == null or $from != $i.sessionName
    then reject("from \($from) is not the session of #\($n) (\($i.sessionName // "none"))")
    elif $mgen != ($i.gen | tostring) then reject("gen \($mgen) is not the current gen \($i.gen) of #\($n)")
    elif $mkind == "DONE" and $mbranch != $i.branch then reject("branch \($mbranch) is not the branch of #\($n)")
    elif $mkind == "DONE" and $i.claim != null and $i.claim.gen == $i.gen and $i.claim.sha == $sha
    then noop("DONE #\($n) gen \($mgen) \($sha) already claimed")
    else
      outbox_clear_gen($n; $i.gen) as $cl
      | ($cl.outbox != .outbox) as $cleared
      | ($st == "done-claimed" or $st == "verifying") as $claimed
      | if $mkind == "STARTED" then
          if $st == "launched" then $cl | .issues[$n].status = "started" | ok(["started"])
          elif $st == "started" then noop("#\($n) already started")
          elif active($n) then
            (if $cleared then $cl | ok([$st]) else noop("STARTED on #\($n) \($st)") end)
          else refuse("STARTED on #\($n) \($st)")
          end
        elif $mkind == "DONE" then
          if active($n) then
            ((.claimSeq // 0) + 1) as $q
            | $cl
            | .claimSeq = $q
            | .issues[$n].claim = {gen: $i.gen, branch: $mbranch, sha: $sha, synced: $synced, claimSeq: $q}
            | .issues[$n].status = "done-claimed"
            | ok(["done-claimed", "queue=\($n)"])
          else refuse("DONE on #\($n) \($st)")
          end
        elif $mkind == "FAILED" then
          if active($n) or $claimed then
            $cl | .issues[$n].status = "failed" | .issues[$n].reason = ("FAILED: " + $mreason) | ok(["failed"])
          elif $st == "failed" then noop("#\($n) already failed")
          else refuse("FAILED on #\($n) \($st)")
          end
        else
          # STUCK or SCOPE.
          (if $mkind == "SCOPE" then "ask-user=scope \($n) \($mreason)"
           elif $needs != "" then "ask-user=stuck \($n) needs=#\($needs) \($mreason)"
           else "ask-user=stuck \($n) \($mreason)" end) as $ask
          | if active($n) then
              if $mkind == "STUCK" and $needs != "" and (.issues[$needs].status // "") == "merged" then
                if $head == "" then bad("cannot read the ticket head for RESYNC #\($n)")
                else
                  $cl | .issues[$n].status = "resync-requested" | .issues[$n].resyncs += 1
                  | outbox_put($n; "RESYNC #\($n) \($head)")
                  | ok(["resync-requested"])
                end
              elif $mkind == "STUCK" and $needs != "" then $cl | ok([$st, "ask-user=edge \($n) \($needs)"])
              else $cl | ok([$st, $ask])
              end
            elif $claimed then noop_out("\($mkind) on #\($n) \($st): the claim proceeds"; [$ask])
            else refuse("\($mkind) on #\($n) \($st)")
            end
        end
    end)

# ------------------------------------------------------------------ session
# A woken partner's (possibly new) name and sessionId; gen and status unchanged.
elif $op == "session" then (
  .issues[$n] as $i
  | if $i.gen == 0 then refuse("#\($n) has no session to rebind (never launched)")
    elif any(.issues | to_entries[]; .key != $n and .value.sessionName == $name)
    then refuse("session name \($name) is recorded for another issue")
    elif $i.sessionName == $name and $i.sessionId == $sid then noop("#\($n) already bound to \($name) \($sid)")
    else
      . as $s0
      # Entries addressed to the old session now go to the woken one.
      | .outbox |= map(if .n == ($n | tonumber) and entry_to($s0) == $i.sessionName then .to = $name else . end)
      | .issues[$n].sessionName = $name | .issues[$n].sessionId = $sid
      | .issues[$n].sessions = (($i.sessions // []) + [{gen: $i.gen, name: $name, sessionId: $sid}])
      | ok([$i.status])
    end)

# ------------------------------------------------------------------ reconcile
# One write: open intents of non-terminal issues against git ($ancids: open
# merge intents whose candidate is an ancestor of the ticket head) and $ag (the
# rows of `claude agents --json --all`), every verifying back to done-claimed,
# CANCEL entries of ended sessions dropped. Closed intents are never touched.
elif $op == "reconcile" then (
  # A row is alive only while it has a pid (Task 1 spike; ruling T6-C1).
  def alive: (.pid // null) != null;
  reduce (.intents[] | select(.open)) as $in (.;
    ($in.n | tostring) as $k | .issues[$k] as $i
    | if $i == null or terminal($i.status) then .
      elif $in.kind == "merge" then
        if has_v($ancids; $in.id) then
          .issues[$k].gateResults += [{gen: $in.gen, result: "pass", text: "merged before a restart (reconciled)"}]
          | to_merged($k; $in.candidateSha)
          | close_intent($in.id; "merged")
        else
          (if $i.status == "verifying" then .issues[$k].status = "done-claimed" else . end)
          | close_intent($in.id; "interrupted")
        end
      else
        # A pid-less row of an earlier generation (or an earlier wake) of this
        # issue is never this launch. A relaunch resumes with `--resume <id>`,
        # which keeps the sessionId, so for a relaunch an alive row with an
        # earlier ID is the relaunch (ruling T6-R3). Alive rows win, then the latest.
        ([$i.sessionId] + [($i.sessions // [])[].sessionId] | map(select(. != null))) as $old
        | ([ $ag[] | select(.name == $in.sessionName and (.sessionId | type == "string")
                            and (.sessionId | test("^[^\\s:]+$"))
                            and ((has_v($old; .sessionId) | not)
                                 or ($in.kind == "relaunch" and alive))) ]
           | sort_by([(alive | if . then 1 else 0 end), (.startedAt // 0)]) | last) as $row
        | if $row != null and $i.status == $in.prior then record_launch($k; $in; $row.sessionId)
          else close_intent($in.id; "launch-failed")
          end
      end)
  | .issues |= with_entries(if .value.status == "verifying" then .value.status = "done-claimed" else . end)
  | . as $s
  | .outbox |= map(select(
      if (.line | startswith("CANCEL #")) then
        # Kept while its target session (by name) has an alive row.
        entry_to($s) as $to
        | $to != null and any($ag[]; .name == $to and alive)
      else true end))
  | ok([]))

# Read-only, on the reconciled state: requeue (claimSeq order), resend <n>
# <to-session> <line> (every outbox entry, verbatim), status (every other live
# issue, by number).
elif $op == "reconcile-actions" then (
  ([ .issues | to_entries[] | select(.value.status == "done-claimed")
     | {k: .key, q: (.value.claim.claimSeq // 0)} ]
   | sort_by([.q, (.k | tonumber)]) | map(.k)) as $rq
  | . as $s
  | { rc: 0,
      out: ([ $rq[] | "requeue \(.)" ]
            + [ .outbox[] | "resend \(.n) \(entry_to($s) // "-") \(.line)" ]
            + [ .issues | keys | map(tonumber) | sort[] | tostring
                | select(islive(.) and (has_v($rq; .) | not)) | "status \(.)" ]) })

else bad("unknown program \($op)")
end
