#!/usr/bin/env bash
# Overridable so a candidate copy can be tested WITHOUT installing it over the live hook.
GATE="${GATE:-$(dirname "$0")/../hooks/read-budget-gate.py}"
TD=$(mktemp -d); pass=0; fail=0
unset CLAUDE_READ_BUDGET CLAUDE_READ_BUDGET_CALLS CLAUDE_READ_BUDGET_BYTES
# Never touch the real ~/.claude/state ledger from tests.
export CLAUDE_READ_BUDGET_STATE_DIR="$TD/state-default"

# Real files for size-based cases.
head -c 10000 /dev/zero | tr '\0' 'x' > "$TD/big.txt"
head -c 30000 /dev/zero | tr '\0' 'x' > "$TD/huge.txt"
printf 'tiny\n' > "$TD/small.txt"
mkdir -p "$TD/.claude/projects/p/memory"; cp "$TD/huge.txt" "$TD/.claude/projects/p/memory/huge.md"
BIG="$TD/big.txt"; HUGE="$TD/huge.txt"

run(){ # name expected_exit json [env assignments...] -- fresh ledger dir per call
  local name=$1 want=$2 json=$3; shift 3
  out=$(printf '%s' "$json" | env CLAUDE_READ_BUDGET_STATE_DIR="$(mktemp -d -p "$TD")" "$@" python3 "$GATE" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then echo "  PASS  $name (exit $rc)"; pass=$((pass+1));
  else echo "  FAIL  $name (exit $rc, expected $want)"; echo "$out" | head -3; fail=$((fail+1)); fi
}

# Fixture builder: mk_fx <name> <json-array-of-records> -- one record per line.
mk_fx(){ python3 - "$TD" "$1" "$2" <<'PY'
import json,sys
td,n,recs=sys.argv[1],sys.argv[2],json.loads(sys.argv[3])
open(f"{td}/{n}.jsonl","w").write("".join(json.dumps(r)+"\n" for r in recs))
PY
}
U='{"type":"user","isSidechain":false,"promptSource":"typed","message":{"role":"user","content":"investigate the retry path"}}'
N='{"type":"user","isSidechain":false,"promptSource":"system","message":{"role":"user","content":"<task-notification>\n<task-id>a1</task-id>\n</task-notification>"}}'
use(){ # id name input-json
  printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"%s","name":"%s","input":%s}]}}' "$1" "$2" "$3"; }
# Default result is 2000 chars: ABOVE SMALL_RESULT_CHARS (1500), so the call counts.
res(){ # id is_error [content-length]
  python3 -c 'import json,sys; print(json.dumps({"type":"user","isSidechain":False,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":sys.argv[1],"content":"y"*int(sys.argv[3]),"is_error":sys.argv[2]=="true"}]}}))' "$1" "$2" "${3:-2000}"; }
res_txt(){ # id text [is_error] -- a result with literal content
  python3 -c 'import json,sys; print(json.dumps({"type":"user","isSidechain":False,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":sys.argv[1],"content":sys.argv[2],"is_error":sys.argv[3]=="true"}]}}))' "$1" "$2" "${3:-false}"; }
txt(){ printf '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}' "$1"; }
rd(){ use "$1" Read "{\"file_path\":\"$BIG\"}"; }          # a counted Read
reads(){ # n -> comma-joined read+result pairs r1..rn
  local s="" k; for k in $(seq 1 "$1"); do s="$s,$(rd r$k),$(res r$k false)"; done; printf '%s' "${s#,}"; }
p(){ # fixture tool_name input-json  -> hook payload
  printf '{"tool_name":"%s","transcript_path":"%s/%s.jsonl","tool_input":%s}' "$2" "$TD" "$1" "$3"; }
readbig(){ p "$1" Read "{\"file_path\":\"$BIG\"}"; }
# bash 3.2 (macOS /bin/bash) leaks the enclosing double-quote state into a $(...) body,
# so a nested "..." argument's own quotes CANCEL the outer quoting and the braces and
# commas inside it become unquoted -- the whole word is then brace-expanded into several
# words. Never write "$( cmd "{\"a\":1,\"b\":2}" )": build such payloads in a helper
# defined out here (function bodies are parsed outside any quotes) and pass only
# single-quoted, brace-free arguments at the call site. tests/run.sh enforces this.
readhuge(){ # fixture [extra fields, e.g. ',"limit":100'] -> a Read payload for $HUGE
  p "$1" Read "{\"file_path\":\"$HUGE\"${2:-}}"; }
bashp(){ p "$1" Bash "$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$2")"; }

mk_fx r0 "[$U]"
mk_fx r2 "[$U,$(reads 2)]"
mk_fx r3 "[$U,$(reads 3)]"

echo "== fail-open / off-switch / subagents =="
run "off-switch allows over budget"      0 "$(readbig r3)" CLAUDE_READ_BUDGET=off
run "subagent agent_id+agent_type"       0 "{\"tool_name\":\"Read\",\"transcript_path\":\"$TD/r3.jsonl\",\"tool_input\":{\"file_path\":\"$BIG\"},\"agent_id\":\"a1\",\"agent_type\":\"claude-crew:claude-scout\"}"
# DELIBERATE divergence from delegation-gate: EITHER key alone means subagent here --
# blocking a lane's reads is worse than missing one main-loop read.
run "agent_id alone is a subagent"       0 "{\"tool_name\":\"Read\",\"transcript_path\":\"$TD/r3.jsonl\",\"tool_input\":{\"file_path\":\"$BIG\"},\"agent_id\":\"a1\"}"
run "agent_type alone is a subagent"     0 "{\"tool_name\":\"Read\",\"transcript_path\":\"$TD/r3.jsonl\",\"tool_input\":{\"file_path\":\"$BIG\"},\"agent_type\":\"claude-crew:claude-scout\"}"
run "empty agent_id/agent_type still gated" 2 "{\"tool_name\":\"Read\",\"transcript_path\":\"$TD/r3.jsonl\",\"tool_input\":{\"file_path\":\"$BIG\"},\"agent_id\":\"\",\"agent_type\":\"\"}"
mkdir -p "$TD/subagents"; cp "$TD/r3.jsonl" "$TD/subagents/x.jsonl"
run "subagent via /subagents/ path"      0 "{\"tool_name\":\"Read\",\"transcript_path\":\"$TD/subagents/x.jsonl\",\"tool_input\":{\"file_path\":\"$BIG\"}}"
run "malformed stdin"                    0 "not json"
run "empty stdin"                        0 ""

echo "== transcript present-but-bad is VISIBLE (exit 1); absent is silent =="
# Round 2 changed this expectation: was exit 0 (silent allow).
run "missing transcript -> exit 1"       1 "{\"tool_name\":\"Read\",\"transcript_path\":\"/nope.jsonl\",\"tool_input\":{\"file_path\":\"$BIG\"}}"
printf 'garbage\nnull\n42\n' > "$TD/norecs.jsonl"
run "zero parseable records -> exit 1"   1 "{\"tool_name\":\"Read\",\"transcript_path\":\"$TD/norecs.jsonl\",\"tool_input\":{\"file_path\":\"$BIG\"}}"
run "transcript_path absent -> silent 0" 0 "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$BIG\"}}"
run "missing transcript, non-read tool -> 0" 0 "{\"tool_name\":\"Bash\",\"transcript_path\":\"/nope.jsonl\",\"tool_input\":{\"command\":\"make\"}}"

echo "== call budget (default 3) =="
run "1st Read allowed"                   0 "$(readbig r0)"
run "3rd Read allowed"                   0 "$(readbig r2)"
run "4th Read denied"                    2 "$(readbig r3)"
run "env CLAUDE_READ_BUDGET_CALLS=5"     0 "$(readbig r3)" CLAUDE_READ_BUDGET_CALLS=5
run "Grep counted (4th)"                 2 "$(p r3 Grep '{"pattern":"x"}')"
run "Glob counted (4th)"                 2 "$(p r3 Glob '{"pattern":"**/*.py"}')"
mk_fx gg "[$U,$(use g1 Grep '{"pattern":"x"}'),$(res g1 false),$(use g2 Glob '{"pattern":"*"}'),$(res g2 false),$(rd r1),$(res r1 false)]"
run "prior Grep+Glob+Read count to 3"    2 "$(readbig gg)"
mk_fx errd "[$U,$(reads 2),$(rd e1),$(res e1 true)]"
run "errored/denied prior call not counted" 0 "$(readbig errd)"

echo "== exemptions =="
run "small-file Read exempt"             0 "$(p r3 Read "{\"file_path\":\"$TD/small.txt\"}")"
run "missing-file Read exempt"           0 "$(p r3 Read "{\"file_path\":\"$TD/nope.txt\"}")"
run "memory-path Read exempt (huge file, no limit)" 0 "$(p r3 Read "{\"file_path\":\"$TD/.claude/projects/p/memory/huge.md\"}")"
EDIT_BIG=$(use w1 Edit "{\"file_path\":\"$BIG\",\"old_string\":\"a\",\"new_string\":\"b\"}")
mk_fx ed "[$U,$(reads 3),$EDIT_BIG,$(res w1 false)]"
run "re-read after successful edit exempt" 0 "$(readbig ed)"
mk_fx edfail "[$U,$(reads 3),$EDIT_BIG,$(res_txt w1 'String not found' true)]"
run "re-read after FAILED edit counted"  2 "$(readbig edfail)"
mk_fx ednores "[$U,$(reads 3),$EDIT_BIG]"
run "re-read after unanswered edit counted" 2 "$(readbig ednores)"
cp "$BIG" "$TD/other.txt"
WRITE_OTHER=$(use w1 Write "{\"file_path\":\"$TD/other.txt\",\"content\":\"b\"}")
READ_OTHER=$(use o1 Read "{\"file_path\":\"$TD/other.txt\"}")
mk_fx ed2 "[$U,$(reads 3),$WRITE_OTHER,$(res w1 false),$READ_OTHER,$(res o1 false)]"
run "re-read-after-edit calls not counted, others still are" 2 "$(readbig ed2)"
mk_fx small3 "[$U,$(use s1 Read "{\"file_path\":\"$TD/small.txt\"}"),$(res s1 false),$(use s2 Read "{\"file_path\":\"$TD/small.txt\"}"),$(res s2 false),$(use s3 Read "{\"file_path\":\"$TD/small.txt\"}"),$(res s3 false),$(reads 2)]"
run "prior exempt reads not counted as calls" 0 "$(readbig small3)"

echo "== Bash classification =="
run "Bash cat counted (4th)"             2 "$(bashp r3 "cat $BIG")"
run "Bash kubectl get not counted"       0 "$(bashp r3 'kubectl get pods -n x')"
run "Bash az not counted"                0 "$(bashp r3 'az account show')"
run "':' marker not counted"             0 "$(bashp r3 ':')"
run "Bash git show counted"              2 "$(bashp r3 'git show HEAD:foo')"
run "Bash git -C dir log counted"        2 "$(bashp r3 'git -C /repo --no-pager log -5')"
run "Bash git commit not counted"        0 "$(bashp r3 "git commit -m 'x'")"
run "cd x && grep counted"               2 "$(bashp r3 'cd /repo && grep -rn foo .')"
run "cd x; cat big counted"              2 "$(bashp r3 "cd /repo; cat $BIG")"
run "git diff main...HEAD never gated"   0 "$(bashp r3 'git diff main...HEAD')"
run "git -C x status never gated"        0 "$(bashp r3 'git -C /repo status')"
run "env VAR=x sudo tail counted"        2 "$(bashp r3 'env LC_ALL=C sudo -E tail -f /var/log/x')"
run "sed -n counted"                     2 "$(bashp r3 "sed -n '1,40p' $BIG")"
run "sed -i not counted"                 0 "$(bashp r3 "sed -i 's/a/b/' $BIG")"
run "python3 not counted (known gap)"    0 "$(bashp r3 'python3 x.py')"
mk_fx bcat "[$U,$(use b1 Bash "{\"command\":\"cat $BIG\"}"),$(res b1 false),$(use b2 Bash '{"command":"kubectl get pods"}'),$(res b2 false),$(use b3 Bash '{"command":"ls"}'),$(res b3 false),$(rd r1),$(res r1 false)]"
run "prior Bash cat+ls counted, kubectl not" 2 "$(readbig bcat)"

echo "== Bash chains: ANY segment read-shaped counts =="
run "true && cat f counted"              2 "$(bashp r3 "true && cat $BIG")"
run "set -o pipefail; cat f counted"     2 "$(bashp r3 "set -o pipefail; cat $BIG")"
run "echo x || cat f counted"            2 "$(bashp r3 "echo x || cat $BIG")"
run "newline-separated cat counted"      2 "$(bashp r3 "echo start
cat $BIG")"
run "bash -c 'cat f' counted (recursion)" 2 "$(bashp r3 "bash -c 'cat $BIG'")"
run "sh -lc \"grep x f\" counted"        2 "$(bashp r3 "sh -lc \"grep x $BIG\"")"
run "sudo -u x cat f counted"            2 "$(bashp r3 "sudo -u root cat $BIG")"
run "env -i PATH=/bin cat f counted"     2 "$(bashp r3 "env -i PATH=/bin cat $BIG")"
run "time/nohup/command/exec prefixes counted" 2 "$(bashp r3 "time nohup command cat $BIG")"
# Round 3 flipped this (was 2): a stdin-only consumer inherits its producer (cloud read).
run "kubectl | grep: consumer inherits cloud, not counted" 0 "$(bashp r3 'kubectl get po | grep api')"
run "kubectl ; grep x file (separate command) counted" 2 "$(bashp r3 "kubectl get po; grep x $BIG")"
run "\$(cat f) substitution counted"     2 "$(bashp r3 "echo \$(cat $BIG)")"
run "echo x && kubectl get po not counted" 0 "$(bashp r3 'echo x && kubectl get po')"
run "quoted '&& cat' is not a segment"   0 "$(bashp r3 "echo 'a && cat b'")"
run "command -v cat not counted"         0 "$(bashp r3 'command -v cat')"
run "cat > f heredoc (write) not counted" 0 "$(bashp r3 "cat > $TD/out.txt <<'EOF'
grep secret file
EOF")"
run "heredoc body lines are not commands" 0 "$(bashp r3 "python3 - <<'PY'
cat big
PY")"
# Round 3 flipped this (was 2): `grep foo` reads stdin only, so it inherits git diff.
run "git diff | grep foo: not counted"   0 "$(bashp r3 'git diff | grep foo')"

echo "== pipeline consumers inherit the producer (after 3 large reads) =="
run "git diff main...HEAD | head -200"   0 "$(bashp r3 'git diff main...HEAD | head -200')"
run "git diff main...HEAD --stat | cat"  0 "$(bashp r3 'git diff main...HEAD --stat | cat')"
run "git diff main...HEAD | wc -l"       0 "$(bashp r3 'git diff main...HEAD | wc -l')"
run "git log --oneline main..HEAD"       0 "$(bashp r3 'git log --oneline main..HEAD')"
run "git log --format=%s | head -n 20"   0 "$(bashp r3 "git log --format=%s main..HEAD | head -n 20")"
run "git diff 2>&1 | head (redirect kept)" 0 "$(bashp r3 'git diff 2>&1 | head -50')"
run "git diff | grep -e foo -A 3"        0 "$(bashp r3 'git diff | grep -e foo -A 3')"
run "git status | cat"                   0 "$(bashp r3 'git -C /repo status --short | cat')"
run "git log -p counted"                 2 "$(bashp r3 'git log -p -3')"
run "git log --oneline -p counted"       2 "$(bashp r3 'git log --oneline -p -3')"
run "cat big | head still counted"       2 "$(bashp r3 "cat $BIG | head")"
run "git diff | grep foo FILE counted (file operand)" 2 "$(bashp r3 "git diff | grep foo $BIG")"
run "git diff | awk prog FILE counted"   2 "$(bashp r3 "git diff | awk '{print}' $BIG")"
run "git diff | ls counted (ls never reads stdin)" 2 "$(bashp r3 'git diff | ls /repo')"
run "echo x | head -n 5 not counted"     0 "$(bashp r3 'echo x | head -n 5')"

echo "== solo raises, dispatching does not =="
mk_fx solo3 "[$U,$(txt 'solo: D2 - shared retry contract'),$(reads 3)]"
run "solo text: 4th allowed"             0 "$(readbig solo3)"
mk_fx solo10 "[$U,$(txt 'solo: D2 - shared retry contract'),$(reads 10)]"
run "solo text: 11th denied"             2 "$(readbig solo10)"
mk_fx solom "[$U,$(use m1 Bash '{"command":":","description":"solo: D1"}'),$(res m1 false),$(reads 3)]"
run "solo via Bash ':' marker raises"    0 "$(readbig solom)"
mk_fx solome "[$U,$(use m1 Bash '{"command":":","description":"solo: D1"}'),$(res m1 true),$(reads 3)]"
run "errored marker does not raise"      2 "$(readbig solome)"
mk_fx solopr "[$U,$(txt 'I might go solo: D1 later'),$(reads 3)]"
run "unanchored solo prose does not raise" 2 "$(readbig solopr)"
mk_fx disp "[$U,$(txt 'dispatching claude-crew:claude-scout'),$(use m1 Bash '{"command":":","description":"dispatching claude-crew:claude-reader"}'),$(res m1 false),$(reads 3)]"
run "dispatching token does NOT raise"   2 "$(readbig disp)"

echo "== byte cap =="
mk_fx bytes "[$U,$(rd r1),$(res r1 false 25000)]"
run "byte cap trips under call count"    2 "$(readbig bytes)"
run "env CLAUDE_READ_BUDGET_BYTES=30000" 0 "$(readbig bytes)" CLAUDE_READ_BUDGET_BYTES=30000
mk_fx bytes_eq "[$U,$(rd r1),$(res r1 false 20000)]"
run "prior total == cap denies (>=)"     2 "$(readbig bytes_eq)"
mk_fx bytes_under "[$U,$(rd r1),$(res r1 false 19999)]"
run "prior total cap-1 allows"           0 "$(readbig bytes_under)"
mk_fx bytes_solo "[$U,$(txt 'solo: D1'),$(rd r1),$(res r1 false 25000)]"
run "solo byte tier 80000 allows 25000"  0 "$(readbig bytes_solo)"
# Round 2 changed this: exempt reads' bytes now COUNT (the old combined test expected 0).
mk_fx bytes_ex "[$U,$(use s1 Read "{\"file_path\":\"$TD/small.txt\"}"),$(res s1 false 25000)]"
run "exempt small-file read bytes count" 2 "$(readbig bytes_ex)"
mk_fx bytes_mem "[$U,$(use s1 Read "{\"file_path\":\"$TD/.claude/projects/p/memory/huge.md\"}"),$(res s1 false 25000)]"
run "memory read bytes count"            2 "$(readbig bytes_mem)"
mk_fx bytes_k "[$U,$(use k1 Bash '{"command":"kubectl logs x"}'),$(res k1 false 25000)]"
run "non-read (kubectl) bytes not counted" 0 "$(readbig bytes_k)"
mk_fx bytes_err "[$U,$(rd r1),$(res r1 true 25000)]"
run "is_error result bytes count"        2 "$(readbig bytes_err)"
DENY_TXT="PreToolUse:Read hook error: BLOCKED by read-budget-gate: this would be read call 4 of 3 $(head -c 25000 /dev/zero | tr '\0' 'z')"
mk_fx bytes_deny "[$U,$(rd r1),$(res_txt r1 "$DENY_TXT" true)]"
run "own denial result bytes NOT counted" 0 "$(readbig bytes_deny)"
DG_TXT="BLOCKED by delegation-gate: no routing $(head -c 25000 /dev/zero | tr '\0' 'z')"
mk_fx bytes_dg "[$U,$(rd r1),$(res_txt r1 "$DG_TXT" true)]"
run "delegation-gate denial bytes NOT counted" 0 "$(readbig bytes_dg)"

echo "== byte bound BEFORE execution (Read of a file over the cap) =="
run "huge Read, no limit -> denied (1st call)" 2 "$(readhuge r0)"
run "huge Read, limit=100 (~12000) allowed"    0 "$(readhuge r0 ',"limit":100')"
run "huge Read, limit=1000 (~120000) denied"   2 "$(readhuge r0 ',"limit":1000')"
run "huge Read, offset=240 (~1200 left) allowed" 0 "$(readhuge r0 ',"offset":240')"
run "huge Read, offset=10 (~28800 left) denied"  2 "$(readhuge r0 ',"offset":10')"
run "huge Read, limit=0 treated as no limit"     2 "$(readhuge r0 ',"limit":0')"
run "huge Read, offset=100 limit=100 allowed"    0 "$(readhuge r0 ',"offset":100,"limit":100')"
mk_fx solo0 "[$U,$(txt 'solo: D1')]"
run "huge Read (30000) under solo 80000 allowed" 0 "$(readhuge solo0)"
msg=$(printf '%s' "$(readhuge r0)" | CLAUDE_READ_BUDGET_STATE_DIR="$(mktemp -d -p "$TD")" python3 "$GATE" 2>&1 >/dev/null)
if printf '%s' "$msg" | grep -qF 'offset/limit' && printf '%s' "$msg" | grep -qF 'claude-crew:claude-reader'; then
  echo "  PASS  oversize deny message names offset/limit + reader"; pass=$((pass+1));
else echo "  FAIL  oversize deny message: $msg"; fail=$((fail+1)); fi

echo "== window =="
mk_fx notify "[$U,$(reads 3),$N]"
run "task-notification does not reset"   2 "$(readbig notify)"
mk_fx reset "[$U,$(reads 3),$U]"
run "genuine user message resets"        0 "$(readbig reset)"
mk_fx stale_solo "[$U,$(txt 'solo: D1'),$U,$(reads 3)]"
run "solo before last user turn is stale" 2 "$(readbig stale_solo)"
mk_fx sidechain "[$U,$(reads 2),{\"type\":\"assistant\",\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"sc\",\"name\":\"Read\",\"input\":{\"file_path\":\"$BIG\"}}]}}]"
run "sidechain reads not counted"        0 "$(readbig sidechain)"
mk_fx junk "[$U,null,42,\"s\",[],$(reads 3)]"
run "junk records beside 3 reads still deny" 2 "$(readbig junk)"

echo "== parallel calls: reservation ledger =="
# Calls in one assistant message are not on disk at PreToolUse time: 5 invocations
# against the SAME transcript, distinct tool_use_ids, shared ledger.
pp(){ # fixture id state-dir -> exit code
  printf '{"session_id":"s1","tool_use_id":"%s","tool_name":"Read","transcript_path":"%s/%s.jsonl","tool_input":{"file_path":"%s"}}' "$2" "$TD" "$1" "$BIG" \
    | CLAUDE_READ_BUDGET_STATE_DIR="$3" python3 "$GATE" >/dev/null 2>&1; echo $?; }
L1="$TD/ledger1"; got=""
for k in 1 2 3 4 5; do got="$got$(pp r0 p$k "$L1") "; done
if [ "$got" = "0 0 0 2 2 " ]; then echo "  PASS  5 parallel reads: first 3 allowed, 4th+5th denied ($got)"; pass=$((pass+1));
else echo "  FAIL  5 parallel reads: got $got"; fail=$((fail+1)); fi
got="$(pp r0 p2 "$L1")"
if [ "$got" = 0 ]; then echo "  PASS  hook re-fired for an already-reserved id is not double-counted"; pass=$((pass+1));
else echo "  FAIL  re-fired reserved id (exit $got)"; fail=$((fail+1)); fi
# Once the reserved calls land in the transcript with small results, they stop counting.
mk_fx landed "[$U,$(rd p1),$(res_txt p1 1),$(rd p2),$(res_txt p2 1),$(rd p3),$(res_txt p3 1)]"
got="$(pp landed p6 "$L1")"
if [ "$got" = 0 ]; then echo "  PASS  landed reservations: transcript is authoritative"; pass=$((pass+1));
else echo "  FAIL  landed reservations (exit $got)"; fail=$((fail+1)); fi
# A new window prunes the old reservations.
L2="$TD/ledger2"
W1='{"type":"user","isSidechain":false,"promptSource":"typed","uuid":"w1","message":{"role":"user","content":"task one"}}'
W2='{"type":"user","isSidechain":false,"promptSource":"typed","uuid":"w2","message":{"role":"user","content":"task two"}}'
mk_fx win1 "[$W1]"; mk_fx win2 "[$W1,$W2]"
for k in 1 2 3; do pp win1 q$k "$L2" >/dev/null; done
a=$(pp win1 q4 "$L2"); b=$(pp win2 q5 "$L2")
if [ "$a" = 2 ] && [ "$b" = 0 ]; then echo "  PASS  new window prunes old reservations"; pass=$((pass+1));
else echo "  FAIL  window prune (old $a, new $b)"; fail=$((fail+1)); fi
# TTL: reservations older than 600 s are released (time injected via READ_BUDGET_NOW).
pt(){ # fixture id state-dir now -> exit code
  printf '{"session_id":"s1","tool_use_id":"%s","tool_name":"Read","transcript_path":"%s/%s.jsonl","tool_input":{"file_path":"%s"}}' "$2" "$TD" "$1" "$BIG" \
    | CLAUDE_READ_BUDGET_STATE_DIR="$3" READ_BUDGET_NOW="$4" python3 "$GATE" >/dev/null 2>&1; echo $?; }
L3="$TD/ledger-ttl"
for k in 1 2 3; do pt r0 t$k "$L3" 1000 >/dev/null; done
a=$(pt r0 t4 "$L3" 1599); b=$(pt r0 t5 "$L3" 1601)
if [ "$a" = 2 ] && [ "$b" = 0 ]; then echo "  PASS  TTL: held at 599 s, released after 600 s"; pass=$((pass+1));
else echo "  FAIL  TTL (599s $a, 601s $b)"; fail=$((fail+1)); fi
# Generated id (payload has NO tool_use_id): released once a matching (name, input)
# tool_use lands in the transcript; a non-matching one does not release it.
pg(){ # fixture state-dir -> exit code
  printf '{"session_id":"s1","tool_name":"Read","transcript_path":"%s/%s.jsonl","tool_input":{"file_path":"%s"}}' "$TD" "$1" "$BIG" \
    | CLAUDE_READ_BUDGET_STATE_DIR="$2" python3 "$GATE" >/dev/null 2>&1; echo $?; }
L4="$TD/ledger-gen"
g=""; for k in 1 2 3 4; do g="$g$(pg r0 "$L4") "; done
mk_fx gen_other "[$U,$(use x1 Read "{\"file_path\":\"$TD/other.txt\"}"),$(res_txt x1 1)]"
c=$(pg gen_other "$L4")
mk_fx gen_match "[$U,$(rd x1),$(res_txt x1 1)]"
d=$(pg gen_match "$L4")
if [ "$g" = "0 0 0 2 " ] && [ "$c" = 2 ] && [ "$d" = 0 ]; then
  echo "  PASS  generated ids: reserved ($g), kept on mismatch, released on matching landed call"; pass=$((pass+1));
else echo "  FAIL  generated ids (reserve '$g', mismatch $c, match $d)"; fail=$((fail+1)); fi
: > "$TD/notadir"
run "ledger I/O failure -> exit 1"       1 "$(readbig r0)" CLAUDE_READ_BUDGET_STATE_DIR="$TD/notadir/sub"

echo "== small results do not count as calls (bulk-output budget) =="
run "3 large (>1500) reads then 4th denies" 2 "$(readbig r3)"
mk_fx smallres "[$U,$(rd r1),$(res r1 false 1500),$(rd r2),$(res r2 false 1500),$(rd r3),$(res r3 false 1500)]"
run "3 reads at exactly 1500 chars: 4th allowed" 0 "$(readbig smallres)"
# Replay ai-readiness Step 2+3: repo-fetch, 4 Agent lanes, 8x grep -c, then ls, as the
# harness would: each call carries its tool_use_id and ONE ledger persists across calls.
steps=()
steps+=("f1|$(use f1 Bash '{"command":"repo-fetch org/repo"}')|$(res f1 false 3000)|Bash|{\"command\":\"repo-fetch org/repo\"}")
for k in 1 2 3 4; do
  steps+=("a$k|$(use a$k Agent '{"description":"audit","prompt":"run audit"}')|$(res a$k false 5000)|Agent|{\"description\":\"audit\",\"prompt\":\"run audit\"}")
done
G="grep -c '^## Ceiling signals' $HOME/repo-audits/x/2026-09-11/a.md"
GJ=$(python3 -c 'import json,sys; print(json.dumps({"command":sys.argv[1]}))' "$G")
for k in 1 2 3 4 5 6 7 8; do steps+=("c$k|$(use c$k Bash "$GJ")|$(res_txt c$k 1)|Bash|$GJ"); done
steps+=("l1|$(use l1 Bash '{"command":"ls ~/repo-audits/x/2026-09-11"}')|$(res_txt l1 'a.md b.md c.md d.md')|Bash|{\"command\":\"ls ~/repo-audits/x/2026-09-11\"}")
prior="$U"; ok=1; n=0; LR="$TD/ledger-replay"
for s in "${steps[@]}"; do
  IFS='|' read -r id u r name inp <<<"$s"
  mk_fx replay "[$prior]"
  out=$(printf '{"session_id":"sr","tool_use_id":"%s","tool_name":"%s","transcript_path":"%s/replay.jsonl","tool_input":%s}' "$id" "$name" "$TD" "$inp" \
        | CLAUDE_READ_BUDGET_STATE_DIR="$LR" python3 "$GATE" 2>&1); rc=$?
  n=$((n+1)); [ "$rc" = 0 ] || { ok=0; echo "    step $n ($name) exit $rc: $(echo "$out" | head -1)"; }
  prior="$prior,$u,$r"
done
if [ "$ok" = 1 ]; then echo "  PASS  ai-readiness replay: all $n calls allowed"; pass=$((pass+1));
else echo "  FAIL  ai-readiness replay"; fail=$((fail+1)); fi

echo "== internal error is surfaced (exit 1), not silent =="
mkdir -p "$TD/lone"; cp "$GATE" "$TD/lone/read-budget-gate.py"
err=$(printf '%s' "$(readbig r3)" | python3 "$TD/lone/read-budget-gate.py" 2>&1 >/dev/null); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$err" | grep -qF 'read-budget-gate: internal error, gate inactive:'; then
  echo "  PASS  sibling missing -> exit 1 with stderr"; pass=$((pass+1));
else echo "  FAIL  sibling missing (exit $rc): $err"; fail=$((fail+1)); fi
GATE="$TD/lone/read-budget-gate.py" run "sibling missing + malformed stdin stays silent 0" 0 "not json"

echo "== deny message content =="
msg=$(printf '%s' "$(readbig r3)" | CLAUDE_READ_BUDGET_STATE_DIR="$(mktemp -d -p "$TD")" python3 "$GATE" 2>&1 >/dev/null)
if printf '%s' "$msg" | grep -qF 'read call 4 of 3' && printf '%s' "$msg" | grep -qF 'claude-crew:claude-reader' \
   && printf '%s' "$msg" | grep -qF 'relaunch with CLAUDE_READ_BUDGET=off'; then echo "  PASS  deny message"; pass=$((pass+1));
else echo "  FAIL  deny message"; echo "$msg"; fail=$((fail+1)); fi

[ ! -e "$HOME/.claude/state/read-budget/sr.json" ] && [ ! -e "$HOME/.claude/state/read-budget/s1.json" ] \
  && { echo "  PASS  tests never wrote the real ledger dir"; pass=$((pass+1)); } \
  || { echo "  FAIL  tests wrote to ~/.claude/state/read-budget"; fail=$((fail+1)); }

echo; echo "RESULT: $pass passed, $fail failed"; rm -rf "$TD"; [ "$fail" = 0 ]
