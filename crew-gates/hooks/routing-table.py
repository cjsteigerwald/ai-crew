#!/usr/bin/env python3
"""UserPromptSubmit hook: inject the delegation routing table every turn.

Why this exists: routing policy documented only in a README or CLAUDE.md is NOT
auto-loaded into context on every turn, and pointing at a file is not loading it -- a
cost-aware model skips the read. This puts the decision table in front of the model
directly, at a cost of roughly 250 tokens per prompt instead of a large file read that
never happened.

Lane names are read from the crew config file (see the crew-gates README, § Crew
config) and fall back to the defaults below when the file or key is absent or
malformed.

Fails open (emits nothing, exit 0) on any error.
"""
import json
import os
import sys

DEFAULT_LANES = {
    "scout": "claude-crew:claude-scout",
    "reader": "claude-crew:claude-reader",
    "implementer_haiku": "claude-crew:claude-implementer-haiku",
    "implementer_sonnet": "claude-crew:claude-implementer-sonnet",
    "implementer_opus": "claude-crew:claude-implementer-opus",
    "writer": "code-writer",
    "verifier": "fresh-verifier",
    "adversary": "codex-adversary",
}


def load_lanes():
    """Read the `lanes` object from the crew config file. Any failure -- missing
    file, bad JSON, non-dict `lanes`, non-string values -- falls back to the
    defaults for the affected keys only. Never raises."""
    lanes = dict(DEFAULT_LANES)
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    path = os.path.join(config_dir, "plugins", "data", "crew", "config.json")
    try:
        with open(path, "r") as fh:
            data = json.load(fh)
        overrides = data.get("lanes")
        if isinstance(overrides, dict):
            for key, value in overrides.items():
                if key in lanes and isinstance(value, str) and value.strip():
                    lanes[key] = value.strip()
    except Exception:
        pass
    return lanes


def build_table(lanes):
    return """<delegation-routing>
Delegation is the DEFAULT. Route by shape, then classify: first line of your first message
this turn -- edit in a LATER step. Or emit a Bash `:` marker (description = the token) as
its own call, edit after its NON-ERROR result returns; this also recovers after a block.

DISPATCH (no deliberation, no cost analysis):
- read-only search/inventory -> {scout}
- digest logs/docs/many files -> {reader}
- mechanical exact-recipe edits -> {implementer_haiku}
- routine well-specified impl -> {implementer_sonnet}
- intricate/correctness-critical within one bounded task -> {implementer_opus}
- needs repo conventions / judgment beyond spec -> {writer}
- full-tier review -> {verifier} + {adversary} in ONE message
Hard budget: at most 2 consecutive read-only Bash/Grep/Glob calls. The 3rd is a violation.

SOLO only by naming one disqualifier verbatim as "solo: D<n>":
  D1 single file, under ~40 changed lines
  D2 files share mutable state or a contract changing in this task
  D3 needs live cloud reads interleaved with edits
  D4 needs a user decision mid-task
"Cohesive"/"interdependent"/"faster inline" are NOT disqualifiers unless they reduce
to D2 with the shared contract named. The cost tradeoff is settled -- do not re-derive it.

EVIDENCE: state a fact only with its evidence inline (file:line, or command + output
line). A NEGATIVE claim needs a command whose output enumerates the search space.
Never establish a fact through --jq / 2>/dev/null (discards the error channel).
Memory files and docs are UNVERIFIED until re-checked: documented-as-shipped != built.
</delegation-routing>""".format(**lanes)


def main():
    try:
        sys.stdin.read()  # drain payload; content not needed
    except Exception:
        pass
    table = build_table(load_lanes())
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": table,
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
