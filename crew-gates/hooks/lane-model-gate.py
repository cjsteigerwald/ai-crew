#!/usr/bin/env python3
"""PreToolUse gate on Agent|Task: no lane runs on the frontier tier; Opus needs a reason.

Rules (see the crew-gates README, § Worker lane ladder):
  - model == FRONTIER (alias or full id)  -> deny unless subagent_type is EXEMPT
  - model == "opus"                        -> deny unless the prompt has a line
                                              starting `escalate:` (the reason)
  - anything else (haiku/sonnet/absent)    -> allow; the env default and lane
                                              frontmatter pick the tier
Tier ALIASES only; never a dated model id. Fails open on any internal error.
Off switch: CLAUDE_LANE_MODEL_GATE=off.
"""
import json
import os
import re
import sys

FRONTIER = "fable"                       # tier alias; full ids look like claude-fable-*
DEFAULT_VERIFIER = "fresh-verifier"      # designed to run on the session model
RE_ESCALATE = re.compile(r"^\s*escalate:\s*\S", re.I | re.M)


def load_exempt():
    """EXEMPT lanes: the verifier lane from the crew config file (see the crew-gates
    README, § Crew config), falling back to DEFAULT_VERIFIER on any failure -- missing
    file, bad JSON, missing/non-string `lanes.verifier`. Never raises."""
    verifier = DEFAULT_VERIFIER
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    path = os.path.join(config_dir, "plugins", "data", "crew", "config.json")
    try:
        with open(path, "r") as fh:
            data = json.load(fh)
        lanes = data.get("lanes")
        if isinstance(lanes, dict):
            value = lanes.get("verifier")
            if isinstance(value, str) and value.strip():
                verifier = value.strip()
    except Exception:
        pass
    return {verifier}


def is_exempt(lane: str, exempt: set) -> bool:
    """A lane running inside a plugin arrives as '<plugin>:<name>'. A plugin-qualified
    exempt entry (contains ':') must match the full lane string exactly. An unqualified
    exempt entry (e.g. the default 'fresh-verifier') matches the lane exactly OR as the
    suffix after a ':' (so 'dev-workflow:fresh-verifier' passes under the default) --
    but never as a substring: 'other:fresh-verifier-x' must NOT match 'fresh-verifier'."""
    for entry in exempt:
        if ":" in entry:
            if lane == entry:
                return True
        elif lane == entry or lane.endswith(f":{entry}"):
            return True
    return False


def deny(reason: str) -> None:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


def main() -> int:
    if os.environ.get("CLAUDE_LANE_MODEL_GATE", "").lower() == "off":
        return 0
    payload = json.loads(sys.stdin.read() or "{}")
    if payload.get("tool_name") not in ("Agent", "Task"):
        return 0
    ti = payload.get("tool_input") or {}
    model = str(ti.get("model") or "").strip().lower()
    lane = str(ti.get("subagent_type") or "").strip()
    if not model:
        return 0
    if model == FRONTIER or model.startswith(f"claude-{FRONTIER}"):
        if is_exempt(lane, load_exempt()):
            return 0
        deny(f"lane-model-gate: `{lane or 'general-purpose'}` may not run on the "
             f"session tier (`{model}`). Drop the model parameter (env default = sonnet), "
             f"or use `model: opus` with an `escalate: <reason>` first line.")
        return 0
    if model == "opus" and not RE_ESCALATE.search(str(ti.get("prompt") or "")):
        deny("lane-model-gate: `model: opus` needs an `escalate: <reason>` line at the "
             "start of the prompt so the escalation is visible in the transcript.")
        return 0
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:               # never block on a broken gate
        sys.stderr.write(f"lane-model-gate: internal error: {exc}\n")
        sys.exit(0)
