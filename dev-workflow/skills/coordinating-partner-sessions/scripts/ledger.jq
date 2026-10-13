# ledger.jq — the jq programs of ledger.sh, loaded with `jq -f` (jq 1.6 and 1.7).
#
# ledger.sh passes `--arg op <program>` plus that program's own --arg/--argjson
# values; the input is the ledger. Every program returns {rc, out: [lines],
# reason, state}. Named arguments are bound from $ARGS.named, so a variable
# that only another program uses is null here.
$ARGS.named as {op: $op, n: $n, live: $live,
                ev: $ev, a1: $a1, a2: $a2, a3: $a3, edge: $edge, anc: $anc, tip: $tip,
                kind: $kind, name: $name, wt: $wt, br: $br, base: $base,
                cand: $cand, exp: $exp}
|
def ok($out): {rc: 0, out: $out, state: .};
def noop($r): {rc: 10, reason: $r};
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
def one_line: gsub("[\t\r\n]+"; " ");
# Add an outbox entry for issue $k at its current gen; it supersedes any older entry for $k.
def outbox_put($k; $line):
  (.issues[$k].gen) as $g
  | .outbox = ([.outbox[] | select(.n != ($k | tonumber))] + [{n: ($k | tonumber), gen: $g, line: ($line | one_line)}]);
def outbox_drop_cancel($k):
  .outbox |= map(select((.n == ($k | tonumber) and (.line | startswith("CANCEL #"))) | not));
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
      else
        .issues[$n] |= (.status = "launched" | .gen = $in.gen | .sessionName = $in.sessionName
                        | .sessionId = $a2 | .worktree = $in.worktree | .branch = $in.branch
                        | .startSha = $in.baseSha | .claim = null
                        | if $ev == "relaunch" then .rework = 0 | .reason = null else . end)
        | close_intent($a1; "launched")
        | ok(["launched"])
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

  elif $ev == "edge-remove" then
    if (blocked($st) | not) then refuse("edge-remove needs #\($n) blocked-on, it is \($st)")
    else
      ($st | ltrimstr("blocked-on #") | tonumber) as $m
      | .issues[$n].status = "pending"
      | .issues[$n].blockers |= map(select(. != $m))
      | ok(["pending"])
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
      | ok(["cancelled", "dependents=\($deps)"])
    end

  elif $ev == "json" then
    if $a1 == "failed" and active($n) then
      .issues[$n].status = "failed" | .issues[$n].reason = "session failed" | ok(["failed"])
    elif ($a1 == "failed" or $a1 == "stopped" or $a1 == "done")
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
          (if islive($k) then outbox_put($k; "CANCEL #\($k)") else . end)
          | .issues[$k].status = "cancelled"
          | .issues[$k].reason = (if $a1 == "" then null else $a1 end))
        | ok(["cancelled"])
      end

  elif $ev == "canary-passed" then
    if .canary == "passed" then noop("canary already passed")
    else .canary = "passed" | ok(["passed"])
    end

  else bad("unknown event \($ev)")
  end
)

else bad("unknown program \($op)")
end
