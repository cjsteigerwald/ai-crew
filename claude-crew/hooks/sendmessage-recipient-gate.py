#!/usr/bin/env python3
"""PreToolUse gate on SendMessage: claude-crew lanes may message only `main`.

Purpose: the NEEDS_LOOKUP rule in each covered agent definition tells the lane to send
its outside-fact questions to the orchestrator (`main`) and nobody else. SendMessage can
reach other agents and sessions, so prose alone does not confine the recipient. This hook
is the enforcement.

Rules:
  - tool_name != "SendMessage"                         -> allow
  - agent_type missing, empty, or not a string         -> allow; that is the main session
                                                          (the orchestrator may message
                                                          anyone)
  - agent_type is NOT a covered lane                   -> allow; other plugins' agent
                                                          messaging is not ours to police
  - agent_type IS a covered lane                       -> the recipient rules below apply
    whatever agent_id holds (present, missing, null, or ""): agent_id is not needed to
    confine a caller that names a covered lane.
  - covered lane, tool_input.to.strip() == "main"      -> allow
  - covered lane, anything else                        -> DENY. That includes another
    name, "main [ref]", "", a missing or non-string `to`, and a missing/non-object
    tool_input. A covered lane whose payload is malformed is denied, not waved through.
  - covered lane, `to` is `main` but tool_input also carries a `recipient` key whose
    value is not `main` (same strip rule)            -> DENY

Covered lanes (agent_type matched EXACTLY as `plugin:name`, or as the bare `name` either
exactly or as the suffix after a ':' -- the lane-model-gate is_exempt rule; never a
substring, so `claude-crew:claude-scout-x` is not covered):
  claude-crew:claude-implementer-haiku / -sonnet / -opus, claude-crew:claude-scout,
  claude-crew:claude-reader, dev-workflow:code-writer.

Evidence:
  - Subagent identification copies crew-gates/hooks/delegation-gate.py (Rule 3, main()):
    a payload captured 2026-09-09 (claude-code 2.1.266, sample of ONE) from a subagent
    tool call carried BOTH `agent_id` and `agent_type` as non-empty strings, with the
    PARENT transcript_path; the main-session call carried neither. Only `agent_type` is
    used here: requiring `agent_id` as well would let a covered-lane payload that lacks it
    escape the rule. The `agent_type` format for plugin agents (`plugin:name` vs bare `name`) is
    not confirmed, so both forms are matched.
  - Plugin agents ignore `hooks` frontmatter (code.claude.com/docs/en/sub-agents), so this
    must be a plugin-level hooks/hooks.json. No documented SendMessage recipient
    restriction exists.
  - SendMessage input schema: required `to` (recipient name) and `message`; optional
    `summary`, `notify_when_idle`.
  - Live capture 2026-09-15 (claude-code 2.1.269, print mode, one background
    claude-crew:claude-scout, sample of ONE session): agent_type was the full
    `claude-crew:claude-scout`; tool_input carried `to`, `message`, `summary` plus
    undocumented `type` ("message"), `recipient` (equal to `to`) and `content` (equal to
    `message`). A deny on to="nonexistent-peer" blocked the call; to="main" was delivered.

What is NOT enforced: message content; the recipients of non-covered agents; anything if
the harness stops sending agent_type on subagent calls (the covered-lane check would then
never match and every call would be allowed -- confirm with the debug capture below after
a harness upgrade).

Fail direction (known boundary): if stdin is unreadable, not JSON, or not an object, the
caller cannot be identified, so the gate ALLOWS and prints
`sendmessage-recipient-gate: internal error` to stderr. Failing closed there would block
SendMessage in every session, the main session included. Such a payload from a covered
lane is therefore NOT confined. Once a caller has been identified as a covered lane, an
unexpected error DENIES instead: there the failure is not "cannot tell who is calling".

Output: deny is the PreToolUse JSON `permissionDecision: "deny"` on stdout with exit 0
(the lane-model-gate format); allow is exit 0 with no stdout.
Off switch: CLAUDE_SENDMESSAGE_GATE=off.
Debug: SENDMESSAGE_GATE_DEBUG=1 appends a sanitized record of each SendMessage payload to
${CLAUDE_CONFIG_DIR:-~/.claude}/state/sendmessage-gate/payloads.jsonl. Kept in clear
(truncated to 128 chars) are string values of hook_event_name, tool_name, agent_type, and
tool_input's to/recipient/type; agent_id becomes `agent_id_present` (a bool). Every other
value -- non-string values under those keys, a non-object tool_input, session_id,
transcript_path, cwd, and any other key -- is replaced by a `<redacted:TYPE>` marker.
"""
import json
import os
import sys

ALLOWED_RECIPIENT = "main"
COVERED = (
    "claude-crew:claude-implementer-haiku",
    "claude-crew:claude-implementer-sonnet",
    "claude-crew:claude-implementer-opus",
    "claude-crew:claude-scout",
    "claude-crew:claude-reader",
    "dev-workflow:code-writer",
)
DENY_REASON = ("sendmessage-recipient-gate: claude-crew lanes may SendMessage only to "
               "`main` (NEEDS_LOOKUP rule). Address the NEEDS_LOOKUP to `main`; "
               "got to={!r}.")
# Debug capture keeps only these string values in clear; every other value is replaced by
# a type marker. An allowlist, not a denylist: the live payload carried an undocumented
# `content` copy of `message` that a message/summary denylist wrote out verbatim.
CLEAR_FIELDS = ("to", "recipient", "type")
CLEAR_TOP_FIELDS = ("hook_event_name", "tool_name", "agent_type")
CLEAR_MAX = 128
# Undocumented recipient alias observed alongside `to` in the live payload. Which of the
# two the harness routes on is not established, so when present it must ALSO be `main`.
RECIPIENT_ALIASES = ("recipient",)


def is_covered(agent_type: str) -> bool:
    """Exact `plugin:name`, or the bare name exactly or as the suffix after ':'.
    Never a substring or prefix match."""
    for full in COVERED:
        name = full.split(":", 1)[1]
        if agent_type == full or agent_type == name or agent_type.endswith(":" + name):
            return True
    return False


def deny(to) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": DENY_REASON.format(to),
    }}))


def redacted(value) -> str:
    if isinstance(value, str):
        return "<redacted:str len=%d>" % len(value)
    return "<redacted:%s>" % type(value).__name__


def clear_or_redacted(value):
    return value[:CLEAR_MAX] if isinstance(value, str) else redacted(value)


def sanitize(payload: dict) -> dict:
    """Minimal record for identifying the caller; built fresh, never copied from payload."""
    rec = {}
    for key, value in payload.items():
        name = str(key)[:CLEAR_MAX]
        if key in CLEAR_TOP_FIELDS:
            rec[name] = clear_or_redacted(value)
        elif key == "agent_id":
            continue
        elif key == "tool_input" and isinstance(value, dict):
            rec[name] = {str(k)[:CLEAR_MAX]: (clear_or_redacted(v) if k in CLEAR_FIELDS
                                              else redacted(v))
                         for k, v in value.items()}
        else:                               # session_id, transcript_path, cwd, others
            rec[name] = redacted(value)
    rec["agent_id_present"] = bool(payload.get("agent_id"))
    return rec


def debug_capture(payload) -> None:
    """Best effort; never affects the verdict."""
    if not os.environ.get("SENDMESSAGE_GATE_DEBUG"):
        return
    try:
        rec = sanitize(payload)
        base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        out_dir = os.path.join(base, "state", "sendmessage-gate")
        os.makedirs(out_dir, exist_ok=True)
        with open(os.path.join(out_dir, "payloads.jsonl"), "a") as fh:
            fh.write(json.dumps(rec) + "\n")
    except Exception:
        pass


def main() -> int:
    if os.environ.get("CLAUDE_SENDMESSAGE_GATE", "").lower() == "off":
        return 0
    payload = json.loads(sys.stdin.read())
    if not isinstance(payload, dict):
        raise ValueError("payload not an object")
    if payload.get("tool_name") != "SendMessage":
        return 0
    debug_capture(payload)
    agent_type = payload.get("agent_type")
    if not (isinstance(agent_type, str) and agent_type):
        return 0                            # main session: allow
    if not is_covered(agent_type):          # agent_id is deliberately not consulted
        return 0
    try:
        ti = payload.get("tool_input")
        to = ti.get("to") if isinstance(ti, dict) else None
        if not (isinstance(to, str) and to.strip() == ALLOWED_RECIPIENT):
            deny(to)
            return 0
        for alias in RECIPIENT_ALIASES:
            if alias in ti:
                value = ti[alias]
                if not (isinstance(value, str) and value.strip() == ALLOWED_RECIPIENT):
                    deny(value)
                    return 0
        return 0
    except Exception:                       # covered lane identified: fail closed
        deny("<unreadable>")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:               # caller unidentifiable: never block
        sys.stderr.write(f"sendmessage-recipient-gate: internal error: {exc}\n")
        sys.exit(0)
