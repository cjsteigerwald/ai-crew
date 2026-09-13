#!/usr/bin/env python3
"""PreToolUse gate on Edit|Write|NotebookEdit: require a delegation classification.

Contract: the orchestrator must emit ONE of these in the transcript after every genuine
user message (task notifications do not reset it), before the first edit in that
window --
    "dispatching <lane>"   (work was routed to a subagent lane)
    "solo: D<n>"           (kept inline, citing a disqualifier from the closed list)

Two places carry it, both scanned only in the window since the last genuine user turn:
  - TEXT: a visible assistant text block with the token as a structured line.
  - MARKER: a Bash tool call whose command is exactly ":" (surrounding whitespace
    ignored) and whose description is the token, with a later non-error tool_result.
    Needed because claude-code 2.1.267 (observed) does not persist visible text written
    mid-turn (after a tool_result) -- only a thinking "narration" summary is saved, and
    thinking is never read. A tool_use is persisted, and its tool_result proves the
    call was actually allowed to run.

Timing: live-checked 2026-09-10 on 2.1.267 (local print mode, 5 sessions, n=1 per
scenario): a marker or text line in the SAME API message as the edit was not visible at
hook time; a marker in an EARLIER message was. Whether the boundary is per-message or
time-based is not established -- follow the procedure: marker on its own, edit after its
non-error result. The marker requires a `Bash(:)` allow rule in settings; without it the
marker call is denied (is_error=True) and the gate keeps blocking. Static fixtures
cannot test this: the timing above came from a live session recorder, not the suite.

Design rules, in priority order:
  1. FAIL OPEN on any internal error. A broken gate must never brick the session;
     a missed dispatch is cheaper than an unusable edit path.
  2. FAIL CLOSED when the transcript is readable and carries no token. That is the
     entire point of the gate.
  3. NEVER fire inside a subagent. The subagent IS the delegation target.
"""
import json
import os
import re
import sys

# A classification is a STRUCTURED line, not a clause buried in prose. Accepted forms:
#     dispatching <lane>                      (line-initial, optional -/*/>/** decoration)
#     ... -> dispatching <lane>               (arrow-preceded, e.g. "mechanical -> dispatching X")
#     ... \u2192 dispatching <lane>
# This deliberately rejects incidental prose that merely contains the word: cold review
# confirmed "the dispatch queue is full", "I removed the redispatch logic", and
# "per policy, full-tier review requires dispatching fresh-verifier" (quoting policy)
# all satisfied the earlier loose pattern without any classification being made.
# A lane NAME, not a count or a filler word. Every real lane carries a hyphen or colon
# (code-writer, fresh-verifier, codex-adversary, claude-crew:claude-scout); Explore and
# Plan are the only bare-word lanes. This rejects "dispatching the", "dispatching 2
# scout lanes", and "dispatching a worker" -- none of which name what was dispatched.
_LANE = r"[`*\"']?(?:[A-Za-z][\w.]*[-:][\w.:-]+|Explore|Plan)"
RE_DISPATCH = re.compile(
    r"^\s*(?:[-*>]\s*)?(?:\*\*)?dispatching\s+" + _LANE
    + r"|(?:\u2192|->)\s*(?:\*\*)?dispatching\s+" + _LANE,
    re.I | re.M,
)
# "solo: D2" -- a disqualifier code from the closed list, not free text. Anchored exactly
# like RE_DISPATCH: an unanchored match let "where does my `solo: D2` text appear" pass.
_SOLO = r"solo\s*[:\-]\s*D[1-4]\b"
RE_SOLO = re.compile(
    r"^\s*(?:[-*>]\s*)?(?:\*\*)?" + _SOLO
    + r"|(?:\u2192|->)\s*(?:\*\*)?" + _SOLO,
    re.I | re.M,
)

# The marker: ONLY this exact command counts (surrounding whitespace ignored).
# ":;", ": x", "true", "echo" do not.
MARKER_COMMAND = ":"
# Persistence pattern: versions at or above this drop mid-turn visible text.
TEXT_DROP_VERSION = (2, 1, 267)

# Record prefixes the harness writes as type=user with string content. These are
# bookkeeping, not genuine user turns, and must not reset the classification window.
HARNESS_PREFIXES = (
    "<system-reminder>",
    "<local-command",
    "<task-notification>",
)

# Paths where a classification is not meaningful (agent bookkeeping, not repo work)
EXEMPT_SUBSTRINGS = (
    "/.claude/projects/",     # transcripts AND memory files (~/.claude/projects/*/memory/)
    "/.claude/_backups/",     # our own backups
)


def allow(reason=""):
    if reason and os.environ.get("DELEGATION_GATE_DEBUG"):
        print(f"[delegation-gate] allow: {reason}", file=sys.stderr)
    sys.exit(0)


def block(message):
    print(message, file=sys.stderr)
    sys.exit(2)  # exit 2 == deny the tool call, surface stderr to the model


DENY_MESSAGE = """\
BLOCKED by delegation-gate: no routing classification found for this task.

RECOVERY (recommended): emit a Bash tool call ON ITS OWN, with
  command:     :
  description: solo: D<n>          (or: dispatching <lane>)
wait for its result, THEN retry the edit as a separate step. The command must be
exactly ":" (surrounding whitespace ignored) and the call must succeed. Do not put
the marker and the edit in the same message: the gate cannot see the current message
yet, so that blocks again.

Alternatively, make the classification the first line of visible text in your first
message after the user's message, and make the edit in a LATER step (text in the same
message as the edit is not yet visible to the gate). The line is one of:

  dispatching <lane>     -- you routed the work to a subagent lane. Must be
                            line-initial or arrow-preceded, e.g.
                              dispatching claude-crew:claude-scout
                              independent/mechanical -> dispatching code-writer
                            Merely using the word in a sentence does NOT count, and
                            the lane must be NAMED -- "dispatching 2 scout lanes" or
                            "dispatching a worker" are rejected, "dispatching
                            claude-crew:claude-scout" is accepted.
  solo: D<n>             -- you are keeping it inline, citing ONE disqualifier:

    D1  single file, under ~40 changed lines
    D2  files share mutable state or a contract that changes in this task
    D3  needs live cloud reads (kubectl/az/aws/gcloud/terraform) interleaved with edits
    D4  needs a user decision mid-task

Free-text justification is NOT accepted. "Cohesive", "interdependent", and
"it's faster to just do it" are not disqualifiers unless they reduce to D2 with
the shared contract named explicitly.

Delegation is the default. If a lane fits, dispatch it -- do not re-derive the
cost tradeoff, it is settled: inline work is paid once now AND re-read on every
later turn, while a lane's tool output and reasoning never enter this context.

Emit the marker (or the line), then retry the edit."""

DIAGNOSIS = (
    "\n\nThis session matches a known transcript-persistence pattern (observed on "
    "claude-code 2.1.267): classification text written mid-turn is not saved, so "
    "retrying in text this turn will block again. Use the Bash `:` marker above -- on its own, "
    "then the edit after its result returns."
)


def _version_tuple(v):
    m = re.match(r"\s*(\d+)\.(\d+)\.(\d+)", v) if isinstance(v, str) else None
    return tuple(int(x) for x in m.groups()) if m else None


def diagnosis(window):
    """Deny-path-only hint. NEVER raises: an exception here would reach the outer
    fail-open wrapper and turn a block into an allow."""
    try:
        for rec in window:
            if not isinstance(rec, dict) or rec.get("type") != "assistant":
                continue
            # Either signal suffices. Evidence (fresh-verifier, this host, 2026-09-10):
            # thinking blocks were empty in 0 of 6,000+ blocks across 2.1.223-2.1.266 --
            # i.e. never non-empty -- and non-empty only on 2.1.267. So non-empty
            # thinking is itself the pattern's fingerprint, even without a version field.
            ver = _version_tuple(rec.get("version"))
            if ver is not None and ver >= TEXT_DROP_VERSION:
                return DIAGNOSIS
            msg = rec.get("message")
            content = msg.get("content") if isinstance(msg, dict) else None
            for blk in content if isinstance(content, list) else []:
                if (isinstance(blk, dict) and blk.get("type") == "thinking"
                        and isinstance(blk.get("thinking"), str)
                        and blk["thinking"].strip()):
                    return DIAGNOSIS
    except Exception:
        return ""
    return ""


def _content(rec):
    """message.content of a record, or None unless both levels are well-formed."""
    msg = rec.get("message") if isinstance(rec, dict) else None
    return msg.get("content") if isinstance(msg, dict) else None


def has_token(s):
    return bool(s) and bool(RE_SOLO.search(s) or RE_DISPATCH.search(s))


def marker_found(window):
    """A non-sidechain Bash tool_use with command exactly ":" and a token description,
    answered by a LATER non-sidechain tool_result that is not is_error. Reads no other
    tool input: tokens in Edit/Write/Agent/other Bash inputs never count."""
    for i, rec in enumerate(window):
        if not isinstance(rec, dict):
            continue
        if rec.get("type") != "assistant" or rec.get("isSidechain"):
            continue
        content = _content(rec)
        for blk in content if isinstance(content, list) else []:
            if not isinstance(blk, dict) or blk.get("type") != "tool_use":
                continue
            if blk.get("name") != "Bash":
                continue
            inp = blk.get("input")
            if not isinstance(inp, dict):
                continue
            cmd = inp.get("command")
            desc = inp.get("description")
            if not isinstance(cmd, str) or cmd.strip() != MARKER_COMMAND:
                continue
            if not isinstance(desc, str) or not has_token(desc):
                continue
            tid = blk.get("id")
            if tid and _answered_ok(window[i + 1:], tid):
                return True
    return False


def _answered_ok(later, tid):
    for rec in later:
        if not isinstance(rec, dict):
            continue
        if rec.get("type") != "user" or rec.get("isSidechain"):
            continue
        content = _content(rec)
        if not isinstance(content, list):
            continue
        for blk in content:
            if (isinstance(blk, dict) and blk.get("type") == "tool_result"
                    and blk.get("tool_use_id") == tid
                    and blk.get("is_error") is not True):
                return True
    return False


def main():
    if os.environ.get("CLAUDE_DELEGATION_GATE", "").lower() == "off":
        allow("disabled via CLAUDE_DELEGATION_GATE=off")

    try:
        raw = sys.stdin.read()
    except Exception:
        allow("stdin unreadable")
    if not raw or not raw.strip():
        allow("empty stdin")

    try:
        payload = json.loads(raw)
    except Exception:
        allow("stdin not JSON")
    if not isinstance(payload, dict):
        allow("payload not an object")

    # --- Rule 3: never fire inside a subagent -------------------------------
    # The harness passes the PARENT session's transcript_path to hooks fired inside a
    # subagent, so the path test below did not match on the payloads captured here.
    # What was actually captured (2026-09-09, claude-code 2.1.266, one session): ONE
    # subagent Write, whose payload carried BOTH agent_id and agent_type and whose
    # transcript_path was the parent .jsonl; and ONE main-session invocation of the same
    # tool on the same file, whose payload carried NEITHER key. That is the whole sample.
    # Requiring BOTH keys, each a non-empty string, is deliberate. Accepting either key
    # alone with any truthy value would silently disable the gate for the main session the
    # day a main-session payload gains an unrelated `agent_type` (model/session metadata) --
    # a silent allow, the worst failure direction here. A single field, or a non-string
    # value, falls through to the transcript scan instead, which errs toward a false block.
    transcript = payload.get("transcript_path") or ""
    agent_id = payload.get("agent_id")
    agent_type = payload.get("agent_type")
    if (isinstance(agent_id, str) and agent_id
            and isinstance(agent_type, str) and agent_type):
        allow("subagent invocation (agent_id + agent_type present)")
    if "/subagents/" in transcript:
        allow("subagent transcript path")

    # --- Path exemptions ----------------------------------------------------
    tool_input = payload.get("tool_input") or {}
    fpath = ""
    if isinstance(tool_input, dict):
        fpath = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    # Genuine scratch only: /tmp/... at the START of the path. A substring test wrongly
    # exempted any repo file under a tmp/ directory (e.g. /repo/tmp/thing.py).
    if fpath.startswith("/tmp/") or fpath.startswith("/var/tmp/"):
        allow(f"scratch path: {fpath}")
    if any(s in fpath for s in EXEMPT_SUBSTRINGS):
        allow(f"exempt path: {fpath}")

    if not transcript or not os.path.isfile(transcript):
        allow("no readable transcript")

    # --- Scan the window since the last genuine user turn -------------------
    try:
        with open(transcript, "r", errors="ignore") as fh:
            lines = fh.readlines()
    except Exception:
        allow("transcript read failed")

    records = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue  # tolerate partial/corrupt lines
        # Only objects are records. A bare null/"str"/42/[] line would otherwise raise on
        # .get() below and reach the fail-open wrapper -- a silent allow on a readable
        # transcript, which Rule 2 forbids.
        if isinstance(obj, dict):
            records.append(obj)

    if not records:
        allow("no parseable records")

    # A genuine user turn: type=user, string content, not meta, not a system-reminder,
    # not a sidechain (subagent) record.
    start = 0
    for i, rec in enumerate(records):
        if rec.get("type") != "user" or rec.get("isSidechain"):
            continue
        content = _content(rec)
        if not isinstance(content, str):
            continue  # tool_result turns carry list content
        if rec.get("isMeta"):
            continue
        stripped = content.lstrip()
        # Harness-generated records, not human turns. They are written with type=user and
        # string content, so the content alone cannot distinguish them from a real user
        # turn -- the user can type or paste anything, including a literal
        # "<task-notification>" block followed by a real request. Content CANNOT establish
        # provenance; promptSource can. Measured on the live 667-record transcript
        # (2026-09-09, claude-code 2.1.266), over the 19 string-content non-meta
        # non-sidechain user records: all 6 promptSource="system" records start with a
        # harness prefix, and none of the 13 genuine records (typed/suggestion_accepted/
        # queued) do. So BOTH signals are required.
        #
        # This is deliberately fail-closed: when promptSource is absent -- an older
        # harness, a resumed session, an unknown mode -- the record is NOT skipped, so it
        # resets the window and the gate blocks. A false block is the acceptable failure
        # here; a silent allow (reusing a stale classification from an earlier task) is not.
        if rec.get("promptSource") == "system" and any(
                stripped.startswith(p) for p in HARNESS_PREFIXES):
            continue
        start = i

    window = records[start:]

    # Any visible assistant text after that point may carry the token.
    for rec in window:
        if rec.get("type") != "assistant" or rec.get("isSidechain"):
            continue
        content = _content(rec)
        for blk in content if isinstance(content, list) else []:
            if not isinstance(blk, dict):
                continue
            # Visible text ONLY. A token inside a thinking block would satisfy the gate
            # while being invisible in the transcript, defeating the audit trail.
            if blk.get("type") != "text":
                continue
            text = blk.get("text")
            if not isinstance(text, str) or not text:
                continue
            if has_token(text):
                allow("token found")

    # Or a Bash ":" marker whose description carries it (survives mid-turn text loss).
    if marker_found(window):
        allow("marker found")

    block(DENY_MESSAGE + diagnosis(window))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # Rule 1: fail open, always
        if os.environ.get("DELEGATION_GATE_DEBUG"):
            print(f"[delegation-gate] internal error, failing open: {exc}", file=sys.stderr)
        sys.exit(0)
