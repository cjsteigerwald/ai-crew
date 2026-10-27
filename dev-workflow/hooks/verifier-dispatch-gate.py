#!/usr/bin/env python3
"""PreToolUse gate on Agent|Task: a fresh-verifier may dispatch only the two
stock read lanes.

Acts only when the caller's agent_type is a fresh-verifier variant (subagent or
`claude --agent` main session): dev-workflow:fresh-verifier,
dev-workflow:fresh-verifier-high, fresh-verifier, fresh-verifier-high. A
payload without agent_type (main session), another agent, or a tool other than
Agent/Task exits 0 silently.

Outcomes:
  - unknown caller (stdin unparseable or not a JSON object, or agent_type present
    but not a string): permissionDecision "ask", reason
    "verifier-dispatch-gate: unreadable hook input (<detail>); caller unknown".
    Only if no JSON can be written: stderr + exit 1.
For a verifier caller:
  - allow (exit 0, no output): tool_input is an object, subagent_type is exactly
    claude-crew:claude-scout or claude-crew:claude-reader, model and isolation
    are absent or empty.
  - deny, naming the rule, otherwise. The verifier's recovery is its Fallback:
    read inline and declare `reading → inline: <denied: reason>`.
The allowed set is closed and hardcoded: crew config (lanes.scout /
lanes.reader) is never read, so a renamed lane is denied, not honoured. No
environment variable is read except the off switch.
Off switch: CLAUDE_VERIFIER_DISPATCH_GATE=off.
"""
import json
import os
import sys

VERIFIERS = {"dev-workflow:fresh-verifier", "dev-workflow:fresh-verifier-high",
             "fresh-verifier", "fresh-verifier-high"}
READ_LANES = ("claude-crew:claude-scout", "claude-crew:claude-reader")
RULE = (f"a verifier dispatches only {READ_LANES[0]} or {READ_LANES[1]}, "
        f"with no model and no isolation")
INLINE = "read inline and declare `reading → inline: <denied: reason>`"


def emit(decision, reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}))


def deny(problem):
    emit("deny", f"verifier-dispatch-gate: {problem}; {RULE}. Do not retry with another lane: {INLINE}")


def violation(ti):
    """The first rule a verifier's tool_input breaks, or None when allowed.
    Every check is a type check before any comparison, so lists and dicts
    cannot raise."""
    if not isinstance(ti, dict):
        return f"tool_input is {'missing' if ti is None else type(ti).__name__}, not an object"
    agent = ti.get("subagent_type")
    if not isinstance(agent, str) or agent not in READ_LANES:
        return f"subagent_type {json.dumps(agent, ensure_ascii=False)} is not an allowed read lane"
    for field in ("model", "isolation"):
        value = ti.get(field)
        if value is not None and value != "":
            return f"{field} {json.dumps(value, ensure_ascii=False)} is set"
    return None


def unknown_caller(detail):
    emit("ask", f"verifier-dispatch-gate: unreadable hook input ({detail}); caller unknown")


def main():
    if os.environ.get("CLAUDE_VERIFIER_DISPATCH_GATE", "").lower() == "off":
        return 0
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        if not isinstance(payload, dict):
            raise ValueError(f"{type(payload).__name__}, not an object")
    except (ValueError, RecursionError) as exc:    # UnicodeDecodeError is a ValueError
        unknown_caller(str(exc) or type(exc).__name__)
        return 0
    if payload.get("tool_name") not in ("Agent", "Task"):
        return 0
    if "agent_type" not in payload:
        return 0                           # main session: not a verifier
    caller = payload["agent_type"]
    if not isinstance(caller, str):
        unknown_caller(f"agent_type is {type(caller).__name__}, not a string")
        return 0
    if caller not in VERIFIERS:
        return 0
    problem = violation(payload.get("tool_input"))
    if problem:
        deny(problem)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:               # emit() itself failed: no JSON possible
        sys.stderr.write(f"verifier-dispatch-gate: error {exc}\n")
        sys.exit(1)
