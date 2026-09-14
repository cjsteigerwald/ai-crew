#!/usr/bin/env bash
# Overridable so a candidate copy can be tested WITHOUT installing it over the live hook.
GATE="${GATE:-$(dirname "$0")/../hooks/delegation-gate.py}"
TD=$(mktemp -d); pass=0; fail=0
# The Bash bookkeeping exemption is anchored to the real Claude config dir; start from
# the default (~/.claude) so the host environment cannot change any verdict below.
unset CLAUDE_CONFIG_DIR DELEGATION_GATE_DEBUG CLAUDE_DELEGATION_GATE

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
export CLAUDE_CONFIG_DIR=/srv/u/.claude
brun "bash memory path"          0 "$N" /repo 'echo x > /srv/u/.claude/projects/x/memory/foo.md'
brun "bash backups path"         0 "$N" /repo 'echo x > /srv/u/.claude/_backups/b.json'
brun "bash config dir ../ escape" 2 "$N" /repo 'echo x > /srv/u/.claude/projects/../../../repo/src/a.py'
unset CLAUDE_CONFIG_DIR
brun "bash memory, default dir"  0 "$N" /repo "echo x > $HOME/.claude/projects/x/memory/m.md"
brun "bash mixed exempt+repo"    2 "$N" /repo 'echo x > /tmp/a; echo y > src/b.py'
# subagent shell writes are never gated
brun "bash subagent write"       0 "$N" /repo 'echo x > out.txt' '{"agent_id":"a1","agent_type":"claude-crew:claude-implementer-haiku"}'
# (h) malformed input fails open
run  "bash garbage stdin"        0 "not json"
run  "bash non-object payload"   0 "[1,2]"
brun "bash command not a string" 0 "$N" /repo 'x' '{"tool_input":{"command":42}}'
brun "bash tool_input not dict"  0 "$N" /repo 'x' '{"tool_input":"echo x > out.txt"}'
brun "bash write, no transcript" 0 /nope/none.jsonl /repo 'echo x > out.txt'

# ---------------------------------------------------------------------------------
# Respec regressions, grouped by review item. Most of these gave the wrong exit on
# 5143ee0 (a bypass exiting 0, or a read-only command exiting 2); the rest pin the
# neighbouring behaviour that must survive the fix (scratch destinations, read-only
# variants, forms that were already handled). "(guard)" marks some of the latter.
# Check which fail on a given revision with: GATE=<old delegation-gate.py> bash $0
echo "== A1: an unresolved destination is never exempt =="
brun "A1 \$HOME/.claude/projects/../.." 2 "$N" /repo 'echo x > $HOME/.claude/projects/../../repo/src/a.py'
brun "A1 ~/.claude/projects/../.."     2 "$N" /repo 'echo x > ~/.claude/projects/../../repo/src/a.py'
brun "A1 \$X/.claude/projects"         2 "$N" /repo 'echo x > $X/.claude/projects/y'
brun "A1 backtick pwd"                 2 "$N" /repo 'cp src/a.py `pwd`/.claude/projects/../../src/b.py'
echo "== A2: bookkeeping exemption anchored to the Claude config dir =="
brun "A2 repo .claude/projects"        2 "$N" /repo 'echo x > /repo/.claude/projects/pkg/src/a.py'
echo "== A3: heredoc script decoy literal =="
brun "A3 decoy /tmp literal"           2 "$N" /repo 'python3 - <<PY
open("out.txt", "w").write("/tmp/looks-safe")
PY'
brun "A3 no path literal at all"       2 "$N" /tmp 'python3 - <<PY
p = name + ext
open(p, "w").write(data)
PY'
brun "A3 only /tmp literal (guard)"    0 "$N" /repo 'python3 - <<PY
open("/tmp/x.json", "w").write("{}")
PY'
echo "== A4: Edit/Write path exemptions never apply to Bash =="
brun "A4 file_path /tmp on Bash"       2 "$N" /repo 'echo x > src/a.py' '{"tool_input":{"command":"echo x > src/a.py","file_path":"/tmp/x"}}'
echo "== B5: redirect forms =="
brun "B5 unspaced abs"                 2 "$N" /repo 'echo x>/repo/src/a.py'
brun "B5 unspaced rel"                 2 "$N" /repo 'echo x>a'
brun "B5 noclobber >|"                 2 "$N" /repo 'echo x >| src/a.py'
brun "B5 >&file"                       2 "$N" /repo 'echo x >&src/a.py'
brun "B5 &>file"                       2 "$N" /repo 'echo x &>src/a.py'
brun "B5 &>>file"                      2 "$N" /repo 'echo x &>>src/a.py'
brun "B5 <>file"                       2 "$N" /repo 'exec 3<>src/a.py'
brun "B5 input redirect not a dest"    2 "$N" /repo 'cp /tmp/a src/b < /dev/null'
brun "B5 2>&1 (guard)"                 0 "$N" /repo 'ls 2>&1'
brun "B5 >&2 (guard)"                  0 "$N" /repo 'echo x >&2'
brun "B5 1>&- (guard)"                 0 "$N" /repo 'ls 1>&-'
brun "B5 grep quoted > (guard)"        0 "$N" /repo 'grep -rn "a>b" src'
brun "B5 &>/dev/null"                  0 "$N" /repo 'make -n &>/dev/null'
echo "== B6: wrapper options =="
brun "B6 env -i"                       2 "$N" /repo 'env -i cp a src/b'
brun "B6 sudo -u root"                 2 "$N" /repo 'sudo -u root cp a src/b'
brun "B6 nice -n 10"                   2 "$N" /repo 'nice -n 10 cp a src/b'
brun "B6 time -p"                      2 "$N" /repo 'time -p cp a src/b'
brun "B6 env -u VAR"                   2 "$N" /repo 'env -u VAR cp a src/b'
brun "B6 xargs -0 -I{}"                2 "$N" /repo 'find . -print0 | xargs -0 -I{} cp {} src/'
brun "B6 command -v cp (read-only)"    0 "$N" /repo 'command -v cp'
echo "== B7: destination-taking options =="
brun "B7 rsync --log-file"             2 "$N" /repo 'rsync /tmp/src /repo/dest --log-file /tmp/log'
brun "B7 rsync -e ssh"                 2 "$N" /repo 'rsync -e ssh /tmp/src /repo/dest'
brun "B7 cp -t repo"                   2 "$N" /repo 'cp -t src/ /tmp/a /tmp/b'
brun "B7 mv --target-directory="       2 "$N" /repo 'mv --target-directory=src /tmp/a /tmp/b'
brun "B7 cp -t /tmp from repo"         0 "$N" /repo 'cp -t /tmp/d src/a src/b'
brun "B7 rsync -t is --times"          0 "$N" /repo 'rsync -avt src/ /tmp/mirror/'
echo "== B8: additional writers =="
brun "B8 touch repo"                   2 "$N" /repo 'touch src/a.py'
brun "B8 touch tmp"                    0 "$N" /repo 'touch /tmp/x'
brun "B8 truncate repo"                2 "$N" /repo 'truncate -s 0 src/a.py'
brun "B8 truncate tmp"                 0 "$N" /repo 'truncate -s 0 /tmp/x'
brun "B8 patch cwd"                    2 "$N" /repo 'patch -p1 < /tmp/p.diff'
brun "B8 patch -d tmp"                 0 "$N" /repo 'patch -d /tmp/x -p1 < /tmp/p.diff'
brun "B8 patch --dry-run"              0 "$N" /repo 'patch --dry-run -p1 < /tmp/p.diff'
brun "B8 git apply"                    2 "$N" /repo 'git apply /tmp/p.diff'
brun "B8 git -C tmp apply"             0 "$N" /repo 'git -C /tmp/x apply /tmp/p.diff'
brun "B8 git apply --check"            0 "$N" /repo 'git apply --check /tmp/p.diff'
brun "B8 git apply --stat"             0 "$N" /repo 'git apply --stat /tmp/p.diff'
brun "B8 curl -o repo"                 2 "$N" /repo 'curl -o src/a.py https://e.com'
brun "B8 curl -sSLO cwd"               2 "$N" /repo 'curl -sSLO https://e.com/x'
brun "B8 curl --output="               2 "$N" /repo 'curl --output=src/a https://e.com'
brun "B8 curl -o tmp"                  0 "$N" /repo 'curl -o /tmp/x https://e.com'
brun "B8 curl -O --output-dir tmp"     0 "$N" /repo 'curl -O --output-dir /tmp https://e.com/x'
brun "B8 curl stdout"                  0 "$N" /repo 'curl -s https://e.com'
brun "B8 wget -O repo"                 2 "$N" /repo 'wget -O src/a.py https://e.com'
brun "B8 wget --output-document"       2 "$N" /repo 'wget --output-document src/a https://e.com'
brun "B8 wget plain URL writes cwd"    2 "$N" /repo 'wget https://e.com/x'
brun "B8 wget -O tmp"                  0 "$N" /repo 'wget -O /tmp/x https://e.com'
brun "B8 wget -P tmp"                  0 "$N" /repo 'wget -P /tmp https://e.com/x'
brun "B8 wget -qO- stdout"             0 "$N" /repo 'wget -qO- https://e.com'
brun "B8 wget plain URL in tmp cwd"    0 "$N" /tmp  'wget https://e.com/x'
brun "B8 tar -x cwd"                   2 "$N" /repo 'tar -xzf /tmp/a.tgz'
brun "B8 tar xzf -C repo"              2 "$N" /repo 'tar xzf /tmp/a.tgz -C src'
brun "B8 tar -x -C tmp"                0 "$N" /repo 'tar -xzf /tmp/a.tgz -C /tmp/x'
brun "B8 tar -t list"                  0 "$N" /repo 'tar -tzf /tmp/a.tgz'
brun "B8 unzip cwd"                    2 "$N" /repo 'unzip /tmp/a.zip'
brun "B8 unzip -d repo"                2 "$N" /repo 'unzip -o /tmp/a.zip -d src'
brun "B8 unzip -d tmp"                 0 "$N" /repo 'unzip /tmp/a.zip -d /tmp/x'
brun "B8 unzip -l list"                0 "$N" /repo 'unzip -l /tmp/a.zip'
brun "B8 mkdir is not a write (guard)" 0 "$N" /repo 'mkdir -p src/new'
echo "== B9: find -exec and xargs writers =="
brun "B9 find -exec cp"                2 "$N" /repo "find . -name '*.py' -exec cp {} /repo/dest/ \\;"
brun "B9 find -execdir touch +"        2 "$N" /repo "find . -name '*.py' -execdir touch {} +"
brun "B9 xargs sed -i (stdin files)"   2 "$N" /repo "find . -name '*.py' -print0 | xargs -0 sed -i 's/a/b/'"
brun "B9 xargs touch (stdin files)"    2 "$N" /repo 'ls | xargs touch'
brun "B9 find -exec cp into tmp"       0 "$N" /repo "find /tmp -name '*.py' -exec cp {} /tmp/dest/ \\;"
brun "B9 find -exec grep (guard)"      0 "$N" /repo "find . -name '*.py' -exec grep -l x {} \\;"
brun "B9 xargs grep (guard)"           0 "$N" /repo "find . -name '*.py' | xargs grep -l foo"
echo "== C10: comparisons are not redirects =="
brun "C10 [[ z > a ]]"                 0 "$N" /repo '[[ z > a ]]'
brun "C10 [ \\> ]"                     0 "$N" /repo '[ "$a" \> "$b" ]'
brun "C10 (( 3 > 2 ))"                 0 "$N" /repo '(( 3 > 2 ))'
brun "C10 \$(( a > b ))"               0 "$N" /repo 'echo $(( a > b ))'
brun "C10 [[ ]] then real write"       2 "$N" /repo '[[ -f x ]] && echo y > src/a.py'
echo "== C11: dd/tee without a file operand =="
brun "C11 dd without of="              0 "$N" /repo 'dd if=src/a.py bs=1 count=1 | od -x'
brun "C11 tee no operand"              0 "$N" /repo 'printf x | tee'
brun "C11 tee /dev/null"               0 "$N" /repo 'tee /dev/null'
brun "C11 tee >/dev/null"              0 "$N" /repo 'tee >/dev/null'
echo "== C12: in-place flag parsing =="
brun "C12 perl -MFile::Find -ne"       0 "$N" /repo "perl -MFile::Find -ne 'print' src/a.py"
brun "C12 perl -I/lib -ne"             0 "$N" /repo 'perl -I/lib -ne 1 x'
brun "C12 perl -lne (guard)"           0 "$N" /repo "perl -lne 'print' src/a.py"
brun "C12 perl -pi -e (guard)"         2 "$N" /repo "perl -pi -e 's/a/b/' src/a.py"
brun "C12 perl -pie (guard)"           2 "$N" /repo "perl -pie 's/a/b/' src/a.py"
brun "C12 perl -lpi -e"                2 "$N" /repo "perl -lpi -e 's/a/b/' src/a.py"
brun "C12 sed -Ei (guard)"             2 "$N" /repo "sed -Ei 's/a/b/' src/a.py"
brun "C12 sed -ni (guard)"             2 "$N" /repo "sed -ni 's/a/b/p' src/a.py"
brun "C12 sed -i'' (guard)"            2 "$N" /repo "sed -i'' 's/a/b/' src/a.py"
brun "C12 sed --in-place=.bak (guard)" 2 "$N" /repo "sed --in-place=.bak 's/a/b/' src/a.py"
brun "C12 sed -E no -i (guard)"        0 "$N" /repo "sed -E 's/a/b/' src/a.py"
echo "== C13: the sed/perl script is not a destination =="
brun "C13 sed -i.bak into tmp"         0 "$N" /repo "sed -i.bak 's/a/b/' /tmp/x"
brun "C13 perl -pi -e into tmp"        0 "$N" /repo "perl -pi -e 's/a/b/' /tmp/x"
brun "C13 sed -i -e tmp + repo"        2 "$N" /repo "sed -i -e 's/a/b/' /tmp/x src/a.py"
echo "== read-only sweep (guards) =="
brun "RO pipe 2>&1 | tail"             0 "$N" /repo 'npm test 2>&1 | tail -20'
brun "RO for loop echo"                0 "$N" /repo 'for f in *.py; do echo "$f"; done'
brun "RO test && ||"                   0 "$N" /repo 'test -f x && echo ok || echo no'
brun "RO process substitution"         0 "$N" /repo 'diff <(ls a) <(ls b)'
brun "RO curl | jq"                    0 "$N" /repo 'curl -s https://e.com | jq .'
brun "RO python -c"                    0 "$N" /repo "python3 -c 'print(1)'"
brun "RO quoted metachar echo"         0 "$N" /repo 'echo "a > b; c | d"'
brun "RO git log format"               0 "$N" /repo "git log --format='%h > %s' -3"
brun "RO cat heredoc to stdout"        0 "$N" /repo 'cat <<EOF
hello > world
EOF'

# ---------------------------------------------------------------------------------
# Final-round regressions (parity with the global gate, false blocks, and stalls). Each
# non-guard case gave the wrong exit, or exceeded its time limit, on 9c193a6.
echo "== R1: rsync secondary output files =="
brun "R1 rsync --log-file into repo"    2 "$N" /repo 'rsync /tmp/src /tmp/dest --log-file /repo/rsync.log'
brun "R1 rsync --temp-dir abs repo"     2 "$N" /repo 'rsync -a /tmp/src/ /tmp/m/ --temp-dir=/repo/t'
brun "R1 rsync all in tmp (guard)"      0 "$N" /repo 'rsync /tmp/a /tmp/b --log-file /tmp/l'
echo "== R2: command substitutions inside [[ ]] / (( )) / \$(( )) =="
brun "R2 [[ -n \$(echo x > f) ]]"       2 "$N" /repo '[[ -n $(echo x > src/a.py) ]]'
brun "R2 (( \$(touch f; echo 1) > 0 ))" 2 "$N" /repo '(( $(touch src/a.py; echo 1) > 0 ))'
brun "R2 [[ -n backtick cp ]]"          2 "$N" /repo '[[ -n `cp a src/b` ]]'
brun "R2 \$(( \$(touch f) ))"           2 "$N" /repo 'echo $(( $(touch src/a.py) ))'
brun "R2 [[ -n \$(ls) ]] (guard)"       0 "$N" /repo '[[ -n $(ls) ]]'
brun "R2 [[ \$(wc -l < f) ]] (guard)"   0 "$N" /repo '[[ $(wc -l < f) -gt 3 ]]'
echo "== R3/R4: no quadratic stall (each under 2.0s through the real hook) =="
# The command is built by a python expression so the 10-50KB inputs never pass through
# bash quoting; the helper times the hook subprocess itself.
ptime(){ # gate transcript python-expression -> "rc elapsed"
  python3 - "$1" "$2" "$3" <<'PY'
import json,subprocess,sys,time
gate,tr,expr=sys.argv[1:4]
p=json.dumps({"tool_name":"Bash","transcript_path":tr,"cwd":"/repo","tool_input":{"command":eval(expr)}})
t=time.perf_counter()
r=subprocess.run([sys.executable,gate],input=p.encode(),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
print("%d %.3f" % (r.returncode, time.perf_counter()-t))
PY
}
prun(){ # name expected_exit python-expression
  _r=$(ptime "$GATE" "$N" "$3"); rc=${_r%% *}; el=${_r#* }
  if [ "$rc" = "$2" ] && python3 -c 'import sys; sys.exit(not float(sys.argv[1]) < 2.0)' "$el" 2>/dev/null; then
    echo "  PASS  $1 (exit $rc, ${el}s)"; pass=$((pass+1))
  else echo "  FAIL  $1 (exit ${rc:-?}, ${el:-?}s; expected exit $2 under 2.0s)"; fail=$((fail+1)); fi
}
prun "R3 echo + 10000 digits"           0 '"echo " + "1" * 10000'
prun "R4 (( x10000 unclosed"            0 '"((" * 10000'
prun "R4 [[ a x8000 unclosed"           0 '"[[ a " * 8000'
prun "R4 \$(( a x8000 unclosed"         0 '"$(( a " * 8000'
prun "R4 50KB benign words/quotes/\\"   0 '("grep -rn '"'"'foo bar'"'"' \"baz qux\" a\\\\b src/ word \\'"'"' " * 2000)[:50000]'
prun "R4 heredoc body open( x40000"     0 '"python3 - <<PY\n" + "open(" * 40000 + "\nPY"'
brun "R3 10>file (guard)"               2 "$N" /repo 'exec 10>src/a.py'
echo "== P1: a herestring does not open a heredoc =="
brun "P1 <<< foo then write"            2 "$N" /repo 'grep x <<< foo
echo y > src/a.py'
brun "P1 <<< quoted then write"         2 "$N" /repo "grep x <<< 'foo'
echo y > src/a.py"
brun "P1 cat <<EOF > file (guard)"      2 "$N" /repo 'cat <<EOF > src/a
x
EOF'
echo "== P2: options that write a side file =="
brun "P2 time -o repo"                  2 "$N" /repo 'time -o /repo/time.log ls'
brun "P2 curl -D repo"                  2 "$N" /repo 'curl -D /repo/h https://e.com'
brun "P2 curl -c repo"                  2 "$N" /repo 'curl -c /repo/c https://e.com'
brun "P2 wget --save-cookies repo"      2 "$N" /repo 'wget -qO- --save-cookies /repo/c https://e.com'
brun "P2 curl -sD - (stdout)"           0 "$N" /repo 'curl -sD - https://e.com'
brun "P2 time -o tmp"                   0 "$N" /repo 'time -o /tmp/t ls'
echo "== F1: unquoted # comments are not commands =="
brun "F1 ls # note > f"                 0 "$N" /repo 'ls -la # note > src/a.py'
brun "F1 git log # see > 3"             0 "$N" /repo 'git log -3 # see > 3 commits'
brun "F1 git status # then; cp"         0 "$N" /repo 'git status # then; cp a b'
brun "F1 write then comment (guard)"    2 "$N" /repo 'echo x > src/a.py # comment'
brun "F1 quoted \"#123\" (guard)"       2 "$N" /repo 'git log --grep "#123" > out.txt'
brun "F1 \"\"# is a word (guard)"       2 "$N" /repo 'echo x ""# > src/a.py'
echo "== F2: heredoc terminators match bash exactly =="
brun "F2 ' EOF ' does not end <<EOF"    0 "$N" /repo $'cat <<EOF\n EOF \necho x > src/a.py\nEOF'
brun "F2 tab-EOF ends <<-EOF"           2 "$N" /repo $'cat <<-EOF\n\tbody\n\tEOF\necho x > src/a.py'

echo "== D14: fail open on BaseException; a decided deny stays 2 =="
# Fault injection runs the REAL hook via runpy as __main__, so its actual top-level
# handler executes (a direct main() call would bypass the contract).
cat > "$TD/f_sysexit.py" <<'PY'
import runpy, sys
class S:
    def read(self, *a, **k): raise SystemExit(7)
sys.stdin = S()
runpy.run_path(sys.argv[1], run_name="__main__")
PY
cat > "$TD/f_kbint.py" <<'PY'
import runpy, sys
class S:
    def read(self, *a, **k): raise KeyboardInterrupt()
sys.stdin = S()
runpy.run_path(sys.argv[1], run_name="__main__")
PY
# stderr whose every write/flush raises: the deny message cannot be delivered, but the
# verdict must still be 2 (on 5143ee0 the KeyboardInterrupt escaped print()).
cat > "$TD/f_stderr_kbint.py" <<'PY'
import runpy, sys
class E:
    def write(self, *a): raise KeyboardInterrupt()
    def flush(self): raise KeyboardInterrupt()
sys.stderr = E()
runpy.run_path(sys.argv[1], run_name="__main__")
PY
# broken stderr on an ALLOW with debug logging on must not change exit 0.
cat > "$TD/f_stderr_oserror.py" <<'PY'
import os, runpy, sys
class E:
    def write(self, *a): raise OSError(32, "broken pipe")
    def flush(self): raise OSError(32, "broken pipe")
os.environ["DELEGATION_GATE_DEBUG"] = "1"
sys.stderr = E()
runpy.run_path(sys.argv[1], run_name="__main__")
PY
frun(){ # name expected_exit shim payload
  printf '%s' "$4" | python3 "$TD/$3" "$GATE" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "$2" ]; then echo "  PASS  $1 (exit $rc)"; pass=$((pass+1));
  else echo "  FAIL  $1 (exit $rc, expected $2)"; fail=$((fail+1)); fi
}
WRITE_PAYLOAD=$(bpay "$N" /repo 'echo x > src/a.py')
READ_PAYLOAD=$(bpay "$N" /repo 'ls -la')
frun "D14 SystemExit(7) from stdin.read"      0 f_sysexit.py "$WRITE_PAYLOAD"
frun "D14 KeyboardInterrupt from stdin.read"  0 f_kbint.py "$WRITE_PAYLOAD"
frun "D14 deny latched despite raising stderr" 2 f_stderr_kbint.py "$WRITE_PAYLOAD"
frun "D14 allow survives broken stderr"       0 f_stderr_oserror.py "$READ_PAYLOAD"

# Executed-case count: removing or skipping fixtures must not keep the suite green.
EXPECTED_CASES=226
executed=$((pass+fail))
echo; echo "EXECUTED: $executed cases (expected $EXPECTED_CASES)"
if [ "$executed" != "$EXPECTED_CASES" ]; then
  echo "  FAIL  executed-case count $executed != expected $EXPECTED_CASES"; fail=$((fail+1))
fi
echo "RESULT: $pass passed, $fail failed"; rm -rf "$TD"; [ "$fail" = 0 ]
