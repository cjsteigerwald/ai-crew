#!/usr/bin/env bash
# Overridable so a candidate copy can be tested WITHOUT installing it over the live hook.
GATE="${GATE:-$(dirname "$0")/../hooks/delegation-gate.py}"
TD=$(mktemp -d); pass=0; fail=0

# transcript: user turn, then assistant text WITHOUT a token
cat > "$TD/none.jsonl" <<'J'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"please refactor the auth module"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Sure, I'll start editing now."}]}}
J
# transcript WITH a dispatch token
cat > "$TD/dispatch.jsonl" <<'J'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"please refactor the auth module"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"independent/mechanical -> dispatching claude-crew:claude-implementer-haiku for the per-file edits."}]}}
J
# transcript WITH a solo disqualifier
cat > "$TD/solo.jsonl" <<'J'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"fix the typo"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"solo: D2 - shared retry contract changes here."}]}}
J
# token present but BEFORE the last user turn (stale, must NOT count)
cat > "$TD/stale.jsonl" <<'J'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"first task"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"solo: D1 - tiny."}]}}
{"type":"user","isSidechain":false,"message":{"role":"user","content":"now a totally new second task"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"ok, editing."}]}}
J
# corrupt lines mixed in with a valid token
cat > "$TD/corrupt.jsonl" <<'J'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"do it"}}
{not json at all
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"dispatching code-writer"}]}}
J

run(){ # name expected_exit json
  out=$(printf '%s' "$3" | python3 "$GATE" 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then echo "  PASS  $1 (exit $rc)"; pass=$((pass+1));
  else echo "  FAIL  $1 (exit $rc, expected $2)"; echo "$out" | head -3; fail=$((fail+1)); fi
}

echo "== P2 blocks unclassified =="
run "P2 no-token"      2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
echo "== P3/P4 allows classified =="
run "P3 dispatching"   0 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/dispatch.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
run "P4 solo:D2"       0 "{\"tool_name\":\"Write\",\"transcript_path\":\"$TD/solo.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
echo "== stale token must not satisfy a new task =="
run "P2b stale-token"  2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/stale.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
echo "== P5 subagents exempt =="
mkdir -p "$TD/subagents"; cp "$TD/none.jsonl" "$TD/subagents/x.jsonl"
run "P5 subagent"      0 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/subagents/x.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
# The harness sends the PARENT transcript_path to subagent hook invocations, so the path
# above did not occur on the captured payloads; agent_id+agent_type are the discriminator.
# BOTH keys are required, each a non-empty string. The captured subagent payload carried
# both; the captured main-session payload carried neither. A single key is NOT evidence of
# a subagent, and accepting one alone would silently disable the gate for the main session
# if a main payload ever gains an unrelated agent_type.
run "subagent via agent_id alone (insufficient)"   2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"},\"agent_id\":\"a2189cd7fc5a7bd06\"}"
run "subagent via agent_type alone (insufficient)" 2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"},\"agent_type\":\"claude-crew:claude-implementer-haiku\"}"
run "subagent both fields"                         0 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"},\"agent_id\":\"a2189cd7fc5a7bd06\",\"agent_type\":\"claude-crew:claude-implementer-haiku\"}"
run "subagent fields must be strings"              2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"},\"agent_id\":1,\"agent_type\":1}"
# The critical guard: same payload with NEITHER key must still be gated. If this ever
# allows, the fix above has disabled the gate for the main session.
run "main session still gated" 2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"

echo "== task-notification: provenance comes from promptSource, not from content =="
# Fixture builder for every task-notification case: genuine user turn -> classification ->
# a record whose CONTENT is a <task-notification> block. Only promptSource varies (empty
# string = the key is ABSENT), and promptSource is what decides whether it is skipped.
# Content alone cannot establish provenance: the user can type or paste anything.
mk_notify(){ # name promptSource-or-empty
  python3 - "$TD" "$1" "$2" <<'PY'
import json,sys
td,name,src=sys.argv[1],sys.argv[2],sys.argv[3]
notif={"type":"user","isSidechain":False,"message":{"role":"user",
       "content":"<task-notification>\n<task-id>a2189cd7fc5a7bd06</task-id>\n<tool-use-id>toolu_x</tool-use-id>\n</task-notification>"}}
if src: notif["promptSource"]=src
open(f"{td}/{name}.jsonl","w").write(
 json.dumps({"type":"user","isSidechain":False,"promptSource":"typed",
             "message":{"role":"user","content":"refactor the retry path"}})+"\n"+
 json.dumps({"type":"assistant","isSidechain":False,"message":{"role":"assistant",
             "content":[{"type":"text","text":"solo: D1 - single file, ~20 lines."}]}})+"\n"+
 json.dumps(notif)+"\n")
PY
}
# defect-2 regression: a returning subagent's notification (promptSource=system, which is
# what the harness actually sends) must NOT reset the window and discard the classification.
mk_notify tasknotify system
run "task-notification does not reset the window" 0 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/tasknotify.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
# adversary finding 1: a GENUINE user turn that merely begins with the harness marker is a
# real turn and MUST invalidate the stale classification. Content is not provenance.
mk_notify notify_typed typed
run "user-typed task-notification is a genuine turn" 2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/notify_typed.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
mk_notify notify_system system
run "harness task-notification with promptSource=system is skipped" 0 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/notify_system.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
# fail-closed by design: promptSource absent (older harness, resumed session, unknown mode)
# => NOT skipped => window resets => block. A false block beats a silent allow.
mk_notify notify_nosrc ""
run "task-notification with promptSource ABSENT is not skipped" 2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/notify_nosrc.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
echo "== P6 fail-open =="
run "P6 empty"         0 ""
run "P6 garbage"       0 "not json"
run "P6 missing-file"  0 "{\"tool_name\":\"Edit\",\"transcript_path\":\"/nope/none.jsonl\",\"tool_input\":{}}"
run "P6 no-transcript" 0 "{\"tool_name\":\"Edit\",\"tool_input\":{}}"
echo "== exempt paths =="
run "exempt memory"    0 "{\"tool_name\":\"Write\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/srv/u/.claude/projects/x/memory/foo.md\"}}"
echo "== corrupt lines tolerated, token still found =="
run "corrupt-tolerant" 0 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/corrupt.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
echo "== false positives from cold review (must all BLOCK) =="
for pair in "queue|the event dispatch queue is full, so I am editing" \
            "redispatch|I removed the redispatch logic from the worker" \
            "policyquote|per policy, full-tier review requires dispatching fresh-verifier" \
            "userquote|The user said: 'try dispatching a scout' but I will edit instead"; do
  n="${pair%%|*}"; t="${pair#*|}"
  python3 - "$TD" "$n" "$t" <<'PY'
import json,sys
td,n,t=sys.argv[1],sys.argv[2],sys.argv[3]
open(f"{td}/{n}.jsonl","w").write(
 json.dumps({"type":"user","isSidechain":False,"message":{"role":"user","content":"do the task"}})+"\n"+
 json.dumps({"type":"assistant","isSidechain":False,"message":{"role":"assistant","content":[{"type":"text","text":t}]}})+"\n")
PY
  run "FP $n" 2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/$n.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
done
echo "== lane must be NAMED, not a count or filler (must BLOCK) =="
for pair in "lanethe|Dispatching the files now" \
            "lanecount|independent/mechanical -> dispatching 2 scout lanes" \
            "lanevague|mechanical -> dispatching a worker for this"; do
  n="${pair%%|*}"; t="${pair#*|}"
  python3 - "$TD" "$n" "$t" <<'PY'
import json,sys
td,n,t=sys.argv[1],sys.argv[2],sys.argv[3]
open(f"{td}/{n}.jsonl","w").write(
 json.dumps({"type":"user","isSidechain":False,"message":{"role":"user","content":"go"}})+"\n"+
 json.dumps({"type":"assistant","isSidechain":False,"message":{"role":"assistant","content":[{"type":"text","text":t}]}})+"\n")
PY
  run "LANE $n" 2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/$n.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
done
echo "== real lane names must ALLOW =="
for pair in "lanecolon|independent/mechanical -> dispatching claude-crew:claude-scout" \
            "lanehyphen|dispatching code-writer for the migration" \
            "laneexplore|read-shaped -> dispatching Explore"; do
  n="${pair%%|*}"; t="${pair#*|}"
  python3 - "$TD" "$n" "$t" <<'PY'
import json,sys
td,n,t=sys.argv[1],sys.argv[2],sys.argv[3]
open(f"{td}/{n}.jsonl","w").write(
 json.dumps({"type":"user","isSidechain":False,"message":{"role":"user","content":"go"}})+"\n"+
 json.dumps({"type":"assistant","isSidechain":False,"message":{"role":"assistant","content":[{"type":"text","text":t}]}})+"\n")
PY
  run "LANE $n" 0 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/$n.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
done
echo "== thinking-block token must NOT satisfy the gate =="
python3 - "$TD" <<'PY'
import json,sys
td=sys.argv[1]
open(f"{td}/think.jsonl","w").write(
 json.dumps({"type":"user","isSidechain":False,"message":{"role":"user","content":"go"}})+"\n"+
 json.dumps({"type":"assistant","isSidechain":False,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"solo: D1 tiny edit"}]}})+"\n")
PY
run "thinking-only" 2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/think.jsonl\",\"tool_input\":{\"file_path\":\"/repo/a.py\"}}"
echo "== memory exemption must NOT cover repo src/memory =="
run "src-memory" 2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/repo/src/memory/allocator.c\"}}"
run "claude-memory" 0 "{\"tool_name\":\"Write\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/srv/u/.claude/projects/x/memory/foo.md\"}}"

echo "== scratch exemption must be path-ANCHORED, not substring (cold-review F6) =="
run "repo-tmp"     2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/repo/tmp/thing.py\"}}"
run "real-tmp"     0 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/tmp/scratch.py\"}}"
run "repo-backups" 2 "{\"tool_name\":\"Edit\",\"transcript_path\":\"$TD/none.jsonl\",\"tool_input\":{\"file_path\":\"/repo/src/_backups/x.py\"}}"

echo; echo "RESULT: $pass passed, $fail failed"; rm -rf "$TD"; [ "$fail" = 0 ]
