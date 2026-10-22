#!/usr/bin/env bash
# Behavioral test for hooks/codex-cap-gate.py: PreToolUse payloads piped to the
# hook as a subprocess, against temp repos (one path has spaces). Covers allow
# at counts 0-2 and ask at 3, the three denials (plus detached HEAD without
# plan:), plan: on the default branch and detached HEAD, generated ids when
# tool_use_id is absent, two concurrent calls at count 2, non-Codex agents
# passing silently, and corrupt ledger / failed lock answering ask with a
# "ledger error" reason. Runnable standalone.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
# shellcheck disable=SC2015  # `cond && pass || fail`: pass only echoes, so it cannot fall through
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/hooks/codex-cap-gate.py"
RL="$ROOT/scripts/review-ledger.sh"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=1; }

[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$T/repo with spaces"
FEAT="$T/feat wt"
NOREPO="$T/plain dir"
mkdir -p "$REPO" "$NOREPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b feat/cap "$FEAT"
LDIR="$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd)/review-ledger"
export REVIEW_LEDGER_LOCK_TIMEOUT=2
unset CLAUDE_CODEX_CAP_GATE

OUT=""; ERR=""; RC=0; DEC=""; REASON=""
# payload <agent> <prompt> [<tool_use_id>|-] [<cwd>] — a PreToolUse payload on stdout.
payload() {
  python3 - "$@" <<'PY'
import json, sys
agent, prompt = sys.argv[1], sys.argv[2]
tid = sys.argv[3] if len(sys.argv) > 3 else "-"
cwd = sys.argv[4] if len(sys.argv) > 4 else "/"
p = {"session_id": "sess-1", "hook_event_name": "PreToolUse", "tool_name": "Agent",
     "cwd": cwd, "tool_input": {"subagent_type": agent, "description": "review", "prompt": prompt}}
if tid != "-":
    p["tool_use_id"] = tid
print(json.dumps(p))
PY
}

# hook <payload-file> [env assignments...] — runs the hook; sets OUT, ERR, RC,
# DEC (permissionDecision or "none" for no output) and REASON.
hook() {
  local f="$1"; shift
  env "$@" python3 "$HOOK" <"$f" >"$T/out" 2>"$T/err"
  RC=$?
  OUT="$(cat "$T/out")"
  ERR="$(cat "$T/err")"
  parse
}
parse() {
  if [ -z "$OUT" ]; then DEC="none"; REASON=""; return; fi
  DEC="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null || echo "badjson")"
  REASON="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])' 2>/dev/null)"
}

# expect <name> <decision> [<reason substring>]
expect() {
  if [ "$RC" -ne 0 ]; then fail "$1: rc $RC (err: $ERR)"; return; fi
  if [ "$DEC" != "$2" ]; then fail "$1: expected $2, got $DEC ($REASON) (err: $ERR)"; return; fi
  if [ -n "${3:-}" ]; then
    case "$REASON" in *"$3"*) ;; *) fail "$1: reason lacks '$3': $REASON"; return ;; esac
  fi
  pass "$1"
}

# dispatch <name> <decision> <agent> <prompt> <tool_use_id|-> [<reason substring>] [<cwd>]
dispatch() {
  payload "$3" "$4" "$5" "${7:-/}" >"$T/p.json"
  hook "$T/p.json"
  expect "$1" "$2" "${6:-}"
}

count_is() {
  local n
  n="$(bash "$RL" -C "$2" count "$3" 2>&1)"
  [ "$n" = "$4" ] && pass "$1" || fail "$1: expected count $4, got '$n'"
}

FEAT_LINE="Review the diff.
ledger: $FEAT
Findings only."

# --- non-Codex agents pass silently, even without a ledger line -------------
dispatch "general-purpose agent passes silently" none general-purpose "no ledger line" t0
dispatch "fresh-verifier passes silently" none fresh-verifier "no ledger line" t0
dispatch "codex-adversary-like name is not matched" none my:codex-adversary "no ledger line" t0
python3 -c 'import json; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls"}}))' >"$T/p.json"
hook "$T/p.json"; expect "non-Agent tool passes silently" none
[ ! -d "$LDIR" ] && pass "nothing recorded for non-Codex calls" || fail "nothing recorded for non-Codex calls: $(ls -a "$LDIR")"

# --- allow at 0-2, ask at 3 (path with spaces) ------------------------------
dispatch "round 1 (count 0) allowed" none codex-adversary "$FEAT_LINE" t1
dispatch "round 2 (count 1) allowed" none dev-workflow:codex-adversary "$FEAT_LINE" t2
dispatch "round 3 (count 2) allowed" none codex-crew:codex-reviewer "$FEAT_LINE" t3
count_is "three rounds counted under branch:feat/cap" "$REPO" branch:feat/cap 3
dispatch "round 4 (count 3) asks, recommending stop" ask codex-adversary "$FEAT_LINE" t4 "Recommended: stop"
case "$REASON" in *"void t4"*) pass "ask reason carries the void command" ;; *) fail "ask reason lacks void command: $REASON" ;; esac
bash "$RL" -C "$REPO" show branch:feat/cap >"$T/show" 2>&1
grep -q "ask    codex-adversary  t4 (payload)" "$T/show" && pass "round 4 recorded with decision ask" || fail "round 4 row: $(cat "$T/show")"
bash "$RL" -C "$REPO" void t4 "declined at cap" >/dev/null
count_is "declined round voided" "$REPO" branch:feat/cap 3

# --- relative path, resolved against the payload cwd ------------------------
dispatch "relative ledger path resolves against cwd" ask codex-adversary "ledger: feat wt" t5 "round 4 for branch:feat/cap" "$T"
bash "$RL" -C "$REPO" void t5 "test" >/dev/null

# --- denials ----------------------------------------------------------------
dispatch "missing ledger line is denied" deny codex-adversary "Review the diff." t6 "no \`ledger:\` line" "$FEAT"
case "$REASON" in *"key: branch:feat/cap"*"count: 3"*) pass "missing-line denial shows the cwd's existing key" ;; *) fail "missing-line denial show: $REASON" ;; esac
dispatch "non-repo path is denied" deny codex-adversary "ledger: $NOREPO" t7 "is not inside a git repository"
dispatch "nonexistent path is denied" deny codex-adversary "ledger: $T/nope" t7 "is not inside a git repository"
dispatch "plan: on a feature branch is denied" deny codex-adversary "ledger: $FEAT | plan:PROJ-9" t8 "drop \`| plan:PROJ-9\`"
case "$REASON" in *"key: branch:feat/cap"*) pass "plan-denial shows the branch key" ;; *) fail "plan-denial show: $REASON" ;; esac
count_is "denials record nothing" "$REPO" branch:feat/cap 3
count_is "denied plan key not created" "$REPO" plan:PROJ-9 0

# --- plan: keys on the default branch and detached HEAD ---------------------
dispatch "plan: on the default branch is allowed" none codex-adversary "ledger: $REPO | plan:PROJ-9" p1
count_is "plan round counted under plan:PROJ-9" "$REPO" plan:PROJ-9 1
DET="$T/detached wt"
git -C "$REPO" worktree add -q --detach "$DET"
dispatch "plan: on a detached HEAD is allowed" none codex-adversary "ledger: $DET | plan:PROJ-9" p2
count_is "detached plan round counted" "$REPO" plan:PROJ-9 2
dispatch "detached HEAD without plan: is denied" deny codex-adversary "ledger: $DET" p3 "detached HEAD"
git -C "$REPO" update-ref refs/remotes/origin/trunk HEAD
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
dispatch "origin/HEAD decides the default branch (main is then a feature branch)" deny codex-adversary "ledger: $REPO | plan:PROJ-9" p4 "feature branch 'main'"
git -C "$REPO" symbolic-ref --delete refs/remotes/origin/HEAD

# --- the plan rounds + one branch round, linked, reach the cap --------------
git -C "$REPO" branch feat/plan-cap
PC="$T/plan cap"
git -C "$REPO" worktree add -q "$PC" feat/plan-cap
dispatch "branch round 1 on the new branch allowed" none codex-adversary "ledger: $PC" pc1
bash "$RL" -C "$PC" link branch:feat/plan-cap plan:PROJ-9 >/dev/null
dispatch "2 plan rounds + 1 branch round linked: next asks" ask codex-adversary "ledger: $PC" pc2 "round 4 for branch:feat/plan-cap"

# --- absent tool_use_id -----------------------------------------------------
DW="$T/dw"
git -C "$REPO" worktree add -q -b feat/genid "$DW"
dispatch "absent tool_use_id is allowed" none codex-adversary "ledger: $DW" -
bash "$RL" -C "$REPO" show branch:feat/genid >"$T/show" 2>&1
grep -Eq "gen:sess-1:[0-9]{8}T[0-9.]+Z:[0-9a-f]{12} \(generated\)" "$T/show" && pass "generated id gen:<session>:<ts>:<sha12> recorded as generated" || fail "generated id row: $(cat "$T/show")"

# --- two concurrent calls at count 2: exactly one allow, one ask ------------
CW="$T/conc"
git -C "$REPO" worktree add -q -b feat/conc "$CW"
dispatch "concurrency setup 1" none codex-adversary "ledger: $CW" c1
dispatch "concurrency setup 2" none codex-adversary "ledger: $CW" c2
payload codex-adversary "ledger: $CW" c3 >"$T/pa.json"
payload codex-adversary "ledger: $CW" c4 >"$T/pb.json"
REVIEW_LEDGER_TEST_DELAY=0.5 python3 "$HOOK" <"$T/pa.json" >"$T/oa" 2>&1 &
PA=$!
REVIEW_LEDGER_TEST_DELAY=0.5 python3 "$HOOK" <"$T/pb.json" >"$T/ob" 2>&1 &
PB=$!
wait "$PA"; wait "$PB"
DA="none"; [ -s "$T/oa" ] && { OUT="$(cat "$T/oa")"; parse; DA="$DEC"; }
DB="none"; [ -s "$T/ob" ] && { OUT="$(cat "$T/ob")"; parse; DB="$DEC"; }
R="$(printf '%s\n%s\n' "$DA" "$DB" | sort | tr '\n' ',')"
[ "$R" = "ask,none," ] && pass "two concurrent calls at count 2: one allow, one ask" || fail "concurrent calls: $R ($(cat "$T/oa" "$T/ob"))"
count_is "both concurrent calls counted" "$REPO" branch:feat/conc 4

# --- corrupt ledger and failed lock -> ask with ledger error ----------------
KW="$T/corrupt"
git -C "$REPO" worktree add -q -b feat/corrupt "$KW"
printf '{"version": 1, "key": "branch:feat/corrupt", "rows": 7}' >"$LDIR/branch%3Afeat%2Fcorrupt.json"
dispatch "corrupt ledger asks with ledger error" ask codex-adversary "ledger: $KW" k1 "codex-cap-gate: ledger error corrupt"
case "$REASON" in *"; count unknown") pass "ledger error reason ends 'count unknown'" ;; *) fail "ledger error reason: $REASON" ;; esac
rm -f "$LDIR/branch%3Afeat%2Fcorrupt.json"

mv "$LDIR/.lock" "$T/lock.bak" && mkdir "$LDIR/.lock"
dispatch "unopenable lock asks with ledger error" ask codex-adversary "ledger: $KW" k2 "codex-cap-gate: ledger error cannot open lock"
rmdir "$LDIR/.lock" && mv "$T/lock.bak" "$LDIR/.lock"

python3 - "$LDIR/.lock" "$T/held" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(5)
PY
HOLDER=$!
i=0; while [ ! -f "$T/held" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
payload codex-adversary "ledger: $KW" k3 >"$T/p.json"
hook "$T/p.json" REVIEW_LEDGER_LOCK_TIMEOUT=0.5
expect "busy lock asks with ledger error" ask "codex-cap-gate: ledger error lock busy"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
count_is "failed lock and corruption recorded nothing" "$REPO" branch:feat/corrupt 0

printf 'not json' >"$T/p.json"
hook "$T/p.json"
expect "unreadable hook input asks with ledger error" ask "ledger error unreadable hook input"

# --- ledger lines: fences, duplicates, conflicts -----------------------------
FW="$T/fence wt"
git -C "$REPO" worktree add -q -b feat/fence "$FW"
FENCED="Example of the line every brief carries:
\`\`\`
ledger: $FEAT
\`\`\`
The real one:
ledger: $FW"
dispatch "a fenced example before the real line: the real one is charged" none codex-adversary "$FENCED" f1
count_is "fenced example charged nothing to its key" "$REPO" branch:feat/cap 3
count_is "the real line's key was charged" "$REPO" branch:feat/fence 1
dispatch "the same ledger line twice is fine" none codex-adversary "ledger: $FW
ledger: $FW" f2
dispatch "two different unfenced ledger lines are denied" deny codex-adversary "ledger: $FEAT
ledger: $FW" f3 "2 different \`ledger:\` lines"
case "$REASON" in *"ledger: $FEAT"*"ledger: $FW"*) pass "conflict denial lists both candidates" ;; *) fail "conflict denial candidates: $REASON" ;; esac
dispatch "a ledger line only inside a fence counts as missing" deny codex-adversary "~~~
ledger: $FW
~~~" f4 "no \`ledger:\` line outside code fences"
count_is "denied and conflicting briefs charged nothing" "$REPO" branch:feat/fence 2

# --- malformed tool_input -> ask, not a crash -------------------------------
printf '{"tool_name":"Agent","tool_input":["x"]}' >"$T/p.json"
hook "$T/p.json"
expect "tool_input that is a list asks with ledger error" ask "codex-cap-gate: ledger error malformed hook input"

# --- git failures other than not-a-repo -> ask ------------------------------
FAKEBIN="$T/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho "fatal: unable to access config: Permission denied" >&2\nexit 128\n' >"$FAKEBIN/git"
chmod +x "$FAKEBIN/git"
payload codex-adversary "ledger: $FW" g1 >"$T/p.json"
hook "$T/p.json" PATH="$FAKEBIN:$PATH"
expect "a failing git (not 'not a git repository') asks, not denies" ask "codex-cap-gate: ledger error git rev-parse failed"
PY3="$(command -v python3)"
mkdir -p "$T/nogit"
env PATH="$T/nogit" "$PY3" "$HOOK" <"$T/p.json" >"$T/out" 2>"$T/err"
RC=$?; OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"; parse
expect "git missing from PATH asks with ledger error" ask "codex-cap-gate: ledger error cannot run git"
count_is "git failures charged nothing" "$REPO" branch:feat/fence 2

# --- non-English locale: "not a git repository" still denies ----------------
if locale -a 2>/dev/null | grep -qx 'de_DE.UTF-8'; then
  payload codex-adversary "ledger: $NOREPO" l1 >"$T/p.json"
  hook "$T/p.json" LC_ALL=de_DE.UTF-8 LANG=de_DE.UTF-8 LANGUAGE=de
  expect "non-repo path under LC_ALL=de_DE.UTF-8 still denies" deny "is not inside a git repository"
else
  echo "SKIP: de_DE.UTF-8 locale not installed (non-English locale case)"
fi
# A git that translates unless LC_ALL=C and LANGUAGE is unset: proves the hook
# forces the C locale even where the real git ships no translations.
LOCBIN="$T/locbin"
mkdir -p "$LOCBIN"
REALGIT="$(command -v git)"
cat >"$LOCBIN/git" <<EOF
#!/bin/sh
if [ "\${LC_ALL:-}" != C ] || [ -n "\${LANGUAGE+x}" ]; then
  echo "fatal: Kein Git-Repository (oder irgendeines der Elternverzeichnisse): .git" >&2
  exit 128
fi
exec "$REALGIT" "\$@"
EOF
chmod +x "$LOCBIN/git"
payload codex-adversary "ledger: $NOREPO" l2 >"$T/p.json"
hook "$T/p.json" PATH="$LOCBIN:$PATH" LC_ALL=de_DE.UTF-8 LANGUAGE=de
expect "git runs with LC_ALL=C and no LANGUAGE (translating fake git): deny" deny "is not inside a git repository"

# --- off switch -------------------------------------------------------------
payload codex-adversary "no ledger line" t9 >"$T/p.json"
hook "$T/p.json" CLAUDE_CODEX_CAP_GATE=off
expect "CLAUDE_CODEX_CAP_GATE=off passes silently" none

if [ "$FAIL" -eq 0 ]; then echo "codex-cap-gate: all tests passed"; else echo "codex-cap-gate: FAILED" >&2; fi
exit "$FAIL"
