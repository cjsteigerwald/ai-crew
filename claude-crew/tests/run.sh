#!/usr/bin/env bash
# claude-crew plugin tests: every agents/*.md must be write-capable to the
# orchestrator (SendMessage) but never web-capable, and must carry the
# worker->orchestrator NEEDS_LOOKUP lookup rule addressed to `main`; the
# sendmessage-recipient-gate hook must enforce that recipient.
#
# DECISION_ONLY=1 GATE=<script> runs only the hook decision table against <script>
# (used by the meta-negative check below to prove the table can fail).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE="${GATE:-$ROOT/hooks/sendmessage-recipient-gate.py}"
DECISION_ONLY="${DECISION_ONLY:-}"
unset CLAUDE_SENDMESSAGE_GATE SENDMESSAGE_GATE_DEBUG

pass=0
fail=0

pass_() { echo "  PASS  $1"; pass=$((pass + 1)); }
fail_() { echo "  FAIL  $1"; fail=$((fail + 1)); }

# extract_frontmatter <file> — prints the YAML frontmatter block (between the
# first two '---' lines) to stdout.
extract_frontmatter() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm { print }
  ' "$1"
}

if [ -z "$DECISION_ONLY" ]; then
echo "== agents/*.md carry the NEEDS_LOOKUP lookup rule =="

AGENT_FILES=("$ROOT"/agents/*.md)
if [ ! -e "${AGENT_FILES[0]}" ]; then
  fail_ "no agents/*.md files found in $ROOT/agents"
else
  for f in "${AGENT_FILES[@]}"; do
    name="$(basename "$f")"
    fm="$(extract_frontmatter "$f")"
    tools_line="$(echo "$fm" | grep -E '^tools:' || true)"

    if echo "$tools_line" | grep -q 'SendMessage'; then
      pass_ "$name: tools: includes SendMessage"
    else
      fail_ "$name: tools: missing SendMessage ($tools_line)"
    fi

    if echo "$tools_line" | grep -qE 'WebFetch|WebSearch'; then
      fail_ "$name: tools: must not include WebFetch/WebSearch ($tools_line)"
    else
      pass_ "$name: tools: no WebFetch/WebSearch"
    fi

    if grep -q 'NEEDS_LOOKUP:' "$f"; then
      pass_ "$name: body contains NEEDS_LOOKUP:"
    else
      fail_ "$name: body missing NEEDS_LOOKUP:"
    fi

    if grep -q 'addressed to `main`' "$f"; then
      pass_ "$name: body contains \"addressed to \`main\`\""
    else
      fail_ "$name: body missing \"addressed to \`main\`\""
    fi

    if grep -qE '^3\. .*from `main`' "$f"; then
      pass_ "$name: step 3 contains \"from \`main\`\""
    else
      fail_ "$name: step 3 missing \"from \`main\`\""
    fi
  done
fi

echo
echo "== hooks/hooks.json registers the recipient gate =="

if python3 - "$ROOT/hooks/hooks.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
want = 'python3 "${CLAUDE_PLUGIN_ROOT}/hooks/sendmessage-recipient-gate.py"'
groups = data["hooks"]["PreToolUse"]
hits = [g for g in groups if g.get("matcher") == "SendMessage"
        and any(h.get("type") == "command" and h.get("command") == want
                for h in g.get("hooks", []))]
sys.exit(0 if len(hits) == 1 else 1)
PY
then
  pass_ "hooks.json valid; PreToolUse matcher SendMessage -> \${CLAUDE_PLUGIN_ROOT}/hooks/sendmessage-recipient-gate.py"
else
  fail_ "hooks.json invalid or does not register the SendMessage gate"
fi

if [ -x "$ROOT/hooks/sendmessage-recipient-gate.py" ]; then
  pass_ "sendmessage-recipient-gate.py is executable"
else
  fail_ "sendmessage-recipient-gate.py is not executable"
fi
echo
fi

echo "== sendmessage-recipient-gate decision table ($GATE) =="

TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT

# pj <python-literal> — prints it as JSON. Payloads are built at runtime so a non-string
# `to` or a missing key is exactly what the test says.
pj() { python3 -c 'import ast, json, sys; print(json.dumps(ast.literal_eval(sys.argv[1])))' "$1"; }

# verdict <stdout-file> <stderr-file> <rc> — prints allow | deny | bad:<why>, judging the
# house format: allow = exit 0 + empty stdout; deny = exit 0 + PreToolUse JSON
# permissionDecision "deny" whose reason names the rule.
verdict() {
  python3 - "$1" "$3" <<'PY'
import json, sys
out, rc = open(sys.argv[1]).read(), sys.argv[2]
if rc != "0":
    print("bad:exit=" + rc); sys.exit()
if not out.strip():
    print("allow"); sys.exit()
try:
    h = json.loads(out)["hookSpecificOutput"]
except Exception:
    print("bad:stdout=" + out.strip()[:80]); sys.exit()
ok = (h.get("hookEventName") == "PreToolUse" and h.get("permissionDecision") == "deny"
      and "may SendMessage only to `main` (NEEDS_LOOKUP rule)" in h.get("permissionDecisionReason", ""))
print("deny" if ok else "bad:json=" + out.strip()[:80])
PY
}

# check_raw <name> <allow|deny> <raw-payload> [env assignments...]
check_raw() {
  local name=$1 want=$2 raw=$3 rc=0 got
  shift 3
  printf '%s' "$raw" | env "$@" python3 "$GATE" >"$TD/out" 2>"$TD/err" || rc=$?
  got=$(verdict "$TD/out" "$TD/err" "$rc")
  if [ "$got" = "$want" ]; then pass_ "$name -> $want"; else fail_ "$name -> expected $want, got $got"; fi
}

sm() { # sm <agent_type|-> <tool_input python literal|-> : SendMessage payload from a subagent
  local at=$1 ti=$2 extra=""
  [ "$at" = "-" ] || extra="'agent_id': 'a2189cd7fc5a7bd06', 'agent_type': '$at', "
  if [ "$ti" = "-" ]; then pj "{${extra}'tool_name': 'SendMessage'}"
  else pj "{${extra}'tool_name': 'SendMessage', 'tool_input': $ti}"; fi
}

# Payloads are built INSIDE these helpers, from variables: a literal '{..,..}' inside a
# "$(...)" is brace-expanded by bash 3.2 (the macOS CI shell) -- see crew-gates run.sh.
# check_pj <name> <want> <python-literal> [env...]
check_pj() { local raw; raw=$(pj "$3"); local n=$1 w=$2; shift 3; check_raw "$n" "$w" "$raw" "$@"; }
# check_sm <name> <want> <agent_type|-> <tool_input literal|-> [env...]
check_sm() { local raw; raw=$(sm "$3" "$4"); local n=$1 w=$2; shift 4; check_raw "$n" "$w" "$raw" "$@"; }

MSG="'message': 'NEEDS_LOOKUP: q'"
check_pj "non-SendMessage tool from covered lane" allow \
  "{'tool_name': 'Bash', 'agent_id': 'x1', 'agent_type': 'claude-crew:claude-scout', 'tool_input': {'command': 'ls'}}"
check_sm "main session to other" allow - "{'to': 'other-agent', $MSG}"

COVERED="claude-crew:claude-implementer-haiku claude-crew:claude-implementer-sonnet claude-crew:claude-implementer-opus claude-crew:claude-scout claude-crew:claude-reader dev-workflow:code-writer"
for full in $COVERED; do
  for at in "$full" "${full#*:}"; do
    check_sm "$at to main" allow "$at" "{'to': 'main', $MSG}"
    check_sm "$at to ' main '" allow "$at" "{'to': ' main ', $MSG}"
    check_sm "$at to other-agent" deny "$at" "{'to': 'other-agent', $MSG}"
    check_sm "$at to 'main [abc123]'" deny "$at" "{'to': 'main [abc123]', $MSG}"
    check_sm "$at to ''" deny "$at" "{'to': '', $MSG}"
    check_sm "$at missing to" deny "$at" "{$MSG}"
    check_sm "$at non-string to" deny "$at" "{'to': ['main'], $MSG}"
    check_sm "$at missing tool_input" deny "$at" -
  done
done

# Live-shaped tool_input (2.1.269 capture): harness adds type/recipient/content.
LIVE="'type': 'message', 'content': 'NEEDS_LOOKUP: q', $MSG, 'summary': 's'"
check_sm "live shape, to=main recipient=main" allow claude-crew:claude-scout "{'to': 'main', 'recipient': 'main', $LIVE}"
check_sm "live shape, to=main recipient=other-agent" deny claude-crew:claude-scout "{'to': 'main', 'recipient': 'other-agent', $LIVE}"
check_sm "live shape, to=other-agent recipient=main" deny claude-crew:claude-scout "{'to': 'other-agent', 'recipient': 'main', $LIVE}"
check_sm "live shape, to=main recipient non-string" deny claude-crew:claude-scout "{'to': 'main', 'recipient': None, $LIVE}"
check_sm "non-covered, to=main recipient=other-agent" allow tech-research:research-vendor-docs "{'to': 'main', 'recipient': 'other-agent', $LIVE}"

check_sm "non-covered tech-research:research-vendor-docs to other" allow tech-research:research-vendor-docs "{'to': 'other-agent', $MSG}"
check_sm "non-covered claude-crew:claude-scout-x to other (no prefix match)" allow claude-crew:claude-scout-x "{'to': 'other-agent', $MSG}"
check_sm "non-covered other:claude-scout-x to other (no substring match)" allow other:claude-scout-x "{'to': 'other-agent', $MSG}"
check_pj "agent_id only, no agent_type, to other" allow \
  "{'tool_name': 'SendMessage', 'agent_id': 'x1', 'tool_input': {'to': 'other-agent', $MSG}}"
check_pj "covered with empty agent_id, to other" deny \
  "{'tool_name': 'SendMessage', 'agent_id': '', 'agent_type': 'claude-crew:claude-scout', 'tool_input': {'to': 'other-agent', $MSG}}"
check_pj "covered with null agent_id, to other" deny \
  "{'tool_name': 'SendMessage', 'agent_id': None, 'agent_type': 'claude-crew:claude-scout', 'tool_input': {'to': 'other-agent', $MSG}}"
check_pj "covered with missing agent_id, to other" deny \
  "{'tool_name': 'SendMessage', 'agent_type': 'claude-crew:claude-scout', 'tool_input': {'to': 'other-agent', $MSG}}"
check_pj "bare covered name with missing agent_id, to other" deny \
  "{'tool_name': 'SendMessage', 'agent_type': 'code-writer', 'tool_input': {'to': 'other-agent', $MSG}}"
check_pj "covered with missing agent_id, to main" allow \
  "{'tool_name': 'SendMessage', 'agent_type': 'claude-crew:claude-scout', 'tool_input': {'to': 'main', $MSG}}"
check_pj "non-covered with missing agent_id, to other" allow \
  "{'tool_name': 'SendMessage', 'agent_type': 'tech-research:research-vendor-docs', 'tool_input': {'to': 'other-agent', $MSG}}"
check_pj "empty agent_type, to other" allow \
  "{'tool_name': 'SendMessage', 'agent_id': 'x1', 'agent_type': '', 'tool_input': {'to': 'other-agent', $MSG}}"
check_sm "CLAUDE_SENDMESSAGE_GATE=off, covered to other" allow claude-crew:claude-scout "{'to': 'other-agent', $MSG}" CLAUDE_SENDMESSAGE_GATE=off

check_raw "invalid JSON" allow '{not json'
if grep -q 'sendmessage-recipient-gate: internal error' "$TD/err"; then
  pass_ "invalid JSON -> stderr names internal error"
else
  fail_ "invalid JSON -> stderr missing internal error ($(head -c 120 "$TD/err"))"
fi
check_raw "JSON array payload" allow '[1, 2]'

# Debug capture: verdict unchanged, a sanitized record written, no SECRET- anywhere.
# dbg_ok <cfg-dir> <label> [grep -F pattern that must be present]
dbg_ok() {
  local f="$1/state/sendmessage-gate/payloads.jsonl"
  if [ -f "$f" ] && ! grep -q 'SECRET-' "$f" && { [ -z "${3:-}" ] || grep -qF "$3" "$f"; }; then
    pass_ "debug capture ($2) written with no SECRET- content"
  else
    fail_ "debug capture ($2) missing or unredacted ($f)"
  fi
}
check_pj "debug on, covered to other" deny \
  "{'tool_name': 'SendMessage', 'hook_event_name': 'PreToolUse', 'agent_id': 'SECRET-AID', 'agent_type': 'claude-crew:claude-reader', 'session_id': 'SECRET-SID', 'transcript_path': '/SECRET-TP', 'cwd': '/SECRET-CWD', 'tool_input': {'to': 'other-agent', 'recipient': 'other-agent', 'type': 'message', 'message': 'SECRET-BODY', 'content': 'SECRET-BODY', 'summary': 'SECRET-SUM'}}" \
  SENDMESSAGE_GATE_DEBUG=1 CLAUDE_CONFIG_DIR="$TD/cfg"
dbg_ok "$TD/cfg" "dict tool_input" '"to": "other-agent", "recipient": "other-agent", "type": "message", "message": "<redacted:str len=11>"'
if grep -qF '"agent_id_present": true' "$TD/cfg/state/sendmessage-gate/payloads.jsonl" 2>/dev/null; then
  pass_ "debug capture records agent_id presence as a bool"
else
  fail_ "debug capture missing agent_id_present"
fi
check_sm "debug on, string tool_input" deny claude-crew:claude-reader "'SECRET-BODY'" \
  SENDMESSAGE_GATE_DEBUG=1 CLAUDE_CONFIG_DIR="$TD/cfg-str"
dbg_ok "$TD/cfg-str" "string tool_input" '"tool_input": "<redacted:str len=11>"'
check_sm "debug on, list tool_input" deny claude-crew:claude-reader "[{'message': 'SECRET-BODY'}]" \
  SENDMESSAGE_GATE_DEBUG=1 CLAUDE_CONFIG_DIR="$TD/cfg-list"
dbg_ok "$TD/cfg-list" "list tool_input" '"tool_input": "<redacted:list>"'
check_sm "debug on, non-string to" deny claude-crew:claude-reader "{'to': {'message': 'SECRET-BODY'}}" \
  SENDMESSAGE_GATE_DEBUG=1 CLAUDE_CONFIG_DIR="$TD/cfg-to"
dbg_ok "$TD/cfg-to" "non-string to" '"to": "<redacted:dict>"'

if [ -z "$DECISION_ONLY" ]; then
  echo
  echo "== meta-negative: an always-allow gate must fail the decision table =="
  MUT="$TD/always-allow-gate.py"
  python3 - "$ROOT/hooks/sendmessage-recipient-gate.py" "$MUT" <<'PY'
import sys
src = open(sys.argv[1]).read()
anchor = "def main() -> int:\n"
assert src.count(anchor) == 1
open(sys.argv[2], "w").write(src.replace(anchor, anchor + "    return 0\n"))
PY
  mrc=0
  mout="$(DECISION_ONLY=1 GATE="$MUT" "$BASH" "$0" 2>&1)" || mrc=$?
  if [ "$mrc" -ne 0 ] && echo "$mout" | grep -q '^  FAIL  claude-crew:claude-scout to other-agent -> expected deny, got allow'; then
    pass_ "always-allow mutant fails the suite ($(echo "$mout" | grep -c '^  FAIL') failures, exit $mrc)"
  else
    fail_ "always-allow mutant was NOT caught (exit $mrc)"
  fi
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
