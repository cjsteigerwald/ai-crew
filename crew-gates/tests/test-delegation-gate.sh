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

echo "== Bash: only file-writing commands consult the classification =="
# Payloads are built in python so commands carrying quotes/newlines stay valid JSON, and
# assigned to a variable so no quoted "..." sits inside $(...) within double quotes.
bpay(){ # transcript cwd command [extra-json-object]
  python3 - "$@" <<'PY'
import json,sys
p={"tool_name":"Bash","transcript_path":sys.argv[1],"tool_input":{"command":sys.argv[3]}}
if sys.argv[2]: p["cwd"]=sys.argv[2]
if len(sys.argv)>4 and sys.argv[4]: p.update(json.loads(sys.argv[4]))
print(json.dumps(p))
PY
}
brun(){ # name expected_exit transcript cwd command [extra]
  _p=$(bpay "$3" "$4" "$5" "${6:-}")
  # An empty payload fails open (exit 0) and would silently pass every allow case.
  if [ -z "$_p" ]; then echo "  FAIL  $1 (payload builder produced nothing)"; fail=$((fail+1)); return; fi
  run "$1" "$2" "$_p"
}
# marker transcript: Bash ":" with a token description, answered by a non-error result
python3 - "$TD" <<'PY'
import json,sys
td=sys.argv[1]
open(f"{td}/marker.jsonl","w").write(
 json.dumps({"type":"user","isSidechain":False,"message":{"role":"user","content":"go"}})+"\n"+
 json.dumps({"type":"assistant","isSidechain":False,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_m1","name":"Bash","input":{"command":":","description":"solo: D1"}}]}})+"\n"+
 json.dumps({"type":"user","isSidechain":False,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_m1","content":"","is_error":False}]}})+"\n")
PY
cat > "$TD/solo1.jsonl" <<'J'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"write the file"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"solo: D1 - single file, ~10 lines."}]}}
J
N="$TD/none.jsonl"
HD='cat > f.txt <<EOF
hello
EOF'
# (a) read-only commands never need a token
brun "bash ls"                   0 "$N" /repo 'ls -la'
brun "bash git status"           0 "$N" /repo 'git status'
brun "bash cat file"             0 "$N" /repo 'cat src/a.py'
brun "bash 2>&1 / dev-null"      0 "$N" /repo 'grep -rn foo src 2>&1 | head; ls > /dev/null 2>&1'
brun "bash cp in argument"       0 "$N" /repo 'grep -rn cp src/'
brun "bash sed -n (not -i)"      0 "$N" /repo "sed -n '1,20p' a.py"
brun "bash awk quoted >"         0 "$N" /repo "awk '\$1 > 5' data.txt"
brun "bash heredoc read-only"    0 "$N" /repo 'python3 - <<PY
print(open("a.py").read())
PY'
# (b)(c)(d) writes with no token block
brun "bash heredoc write"        2 "$N" /repo "$HD"
brun "bash redirect write"       2 "$N" /repo 'echo x > out.txt'
brun "bash append write"         2 "$N" /repo 'echo x >> /repo/log.txt'
brun "bash sed -i"               2 "$N" /repo "sed -i '' 's/a/b/' src/a.py"
brun "bash perl -pi"             2 "$N" /repo "perl -pi -e 's/a/b/' src/a.py"
brun "bash tee"                  2 "$N" /repo 'echo x | tee src/a.py'
brun "bash cp"                   2 "$N" /repo 'cp /tmp/x.py src/a.py'
brun "bash mv"                   2 "$N" /repo 'mv a.py b.py'
brun "bash ln"                   2 "$N" /repo 'ln -s a.py b.py'
brun "bash dd of="               2 "$N" /repo 'dd if=/dev/zero of=disk.img bs=1 count=1'
brun "bash sudo-wrapped cp"      2 "$N" /repo 'sudo cp a b'
brun "bash script write"         2 "$N" /repo 'python3 - <<PY
open("src/a.py", "w").write("x")
PY'
brun "bash tmp ../ escape"       2 "$N" /repo 'echo x > /tmp/../repo/src/a.py'
brun "bash relative, no cwd"     2 "$N" ""    'echo x > out.txt'
brun "bash variable dest"        2 "$N" /repo 'echo x > $OUT'
brun "bash marker then write"    2 "$N" /repo ':; echo x > out.txt'
brun "bash stale token"          2 "$TD/stale.jsonl" /repo 'echo x > out.txt'
# (e) same writes with a valid classification allow
brun "bash heredoc + solo:D1"    0 "$TD/solo1.jsonl" /repo "$HD"
brun "bash redirect + solo:D1"   0 "$TD/solo1.jsonl" /repo 'echo x > out.txt'
brun "bash sed -i + dispatching" 0 "$TD/dispatch.jsonl" /repo "sed -i '' 's/a/b/' src/a.py"
brun "bash redirect + marker"    0 "$TD/marker.jsonl" /repo 'echo x > out.txt'
# (f) the marker itself must never require classification
brun "bash marker :"             0 "$N" /repo ':'
brun "bash marker padded"        0 "$N" /repo '  :  '
# (g) exempt destinations
brun "bash write /tmp"           0 "$N" /repo 'echo x > /tmp/out.txt'
brun "bash write scratchpad"     0 "$N" /repo 'cat > /private/tmp/claude-1/sess/scratchpad/n.md <<EOF
x
EOF'
brun "bash relative in tmp cwd"  0 "$N" /private/tmp/claude-1/sess/scratchpad 'echo x > ./out.txt'
brun "bash tee /dev/stderr"      0 "$N" /repo 'echo x | tee /dev/stderr'
brun "bash memory path"          0 "$N" /repo 'echo x > /srv/u/.claude/projects/x/memory/foo.md'
brun "bash mixed exempt+repo"    2 "$N" /repo 'echo x > /tmp/a; echo y > src/b.py'
# subagent shell writes are never gated
brun "bash subagent write"       0 "$N" /repo 'echo x > out.txt' '{"agent_id":"a1","agent_type":"claude-crew:claude-implementer-haiku"}'
# (h) malformed input fails open
run  "bash garbage stdin"        0 "not json"
run  "bash non-object payload"   0 "[1,2]"
brun "bash command not a string" 0 "$N" /repo 'x' '{"tool_input":{"command":42}}'
brun "bash tool_input not dict"  0 "$N" /repo 'x' '{"tool_input":"echo x > out.txt"}'
brun "bash write, no transcript" 0 /nope/none.jsonl /repo 'echo x > out.txt'

echo; echo "RESULT: $pass passed, $fail failed"; rm -rf "$TD"; [ "$fail" = 0 ]
