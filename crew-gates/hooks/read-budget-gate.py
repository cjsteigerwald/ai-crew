#!/usr/bin/env python3
"""PreToolUse gate on Read|Grep|Glob|Bash: cap inline bulk reading in the main session.

Contract: in the window since the last genuine user message (the SAME window as
delegation-gate.py -- task notifications do not reset it), the main session may make at
most CLAUDE_READ_BUDGET_CALLS counted read calls (default 3) and pull less than
CLAUDE_READ_BUDGET_BYTES characters of read output (default 20000). A `solo: D<n>`
classification in the window (text line or the Bash ":" marker) raises the tier to
10 calls / 80000 characters. A `dispatching <lane>` token does NOT raise it: dispatching
means the lane reads, not the orchestrator.

Rules summary:
  * Read-shaped: Read, Grep, Glob; Bash where ANY pipeline stage is a counted read. The
    command is split into commands on unquoted && || ; & ( ) and newlines (heredoc
    bodies dropped, `2>&1`-style redirects kept intact), each command into pipeline
    stages on `|`. A stage's first word -- after VAR=x, env [-i|-u N], sudo [-u x ...],
    command, builtin, exec, nohup, time -- is a file-reading tool, `sed -n`, a read-only
    git subcommand, or git-read/gh-read. `sh|bash|zsh -c '<script>'` is recursed into.
    A stage that is NOT first in its pipeline and has no file operand (reads stdin
    only: `| head -200`, `| grep foo`, `| wc -l`, `| cat`) inherits its producer's
    classification -- so it is counted after `cat big` but not after `git diff`.
    NOT read-shaped: live cloud CLIs (kubectl az aws gcloud terraform -- by policy
    they stay in the main loop), `git diff` / `git status` and summary-only `git log`
    (`--oneline`/`--format`/`--pretty` without `-p`/`--patch`): the crew-gates README
    mandates the orchestrator's OWN diff inspection of delegated work, so gating them would block a
    required review step. Also not: `cat > file` (a write), the ":" marker.
    KNOWN GAP: interpreter one-liners (`python3 -c "open(f).read()"`, `perl -ne`, ...)
    and reads hidden behind variables/aliases/functions are not detected.
  * Call count: an earlier read-shaped call counts unless it is exempt, its result is
    is_error, or its result is <= SMALL_RESULT_CHARS (bulk-output budget: `grep -c`,
    short `ls`).
  * Exempt from the call count (bytes still count): Read of a memory file
    (~/.claude/projects/*/memory/), Read of a file under 4096 bytes or not a regular
    file, and "re-read after edit" -- Read of a path that a SUCCESSFUL (non-is_error)
    Edit/Write/MultiEdit/NotebookEdit already touched in the window.
  * Byte total: every read-shaped result in the window, including exempt and is_error
    ones, EXCEPT denials by this gate or delegation-gate. Deny when total >= cap.
  * Byte bound before execution: a Read (not a memory file) whose estimated output --
    file size minus offset*~120, capped at limit*~120 when limit > 0 -- exceeds the
    tier's byte cap is denied.
  * Parallel calls: calls in the SAME assistant message are not on disk at PreToolUse
    time, so each allowed counted call is also reserved in a per-session ledger
    (CLAUDE_READ_BUDGET_STATE_DIR, default <config-dir>/state/read-budget/<session>.json
    where <config-dir> is $CLAUDE_CONFIG_DIR or ~/.claude, flock-serialized, keyed by
    the window's start record). Reservations not yet in the
    transcript count as large calls (erring to block). A reservation is released when
    its tool_use_id appears in the transcript, after RESERVATION_TTL seconds, or -- for
    a generated id (payload had no tool_use_id) -- once more transcript tool_uses with
    the same (name, input) exist than did at reservation time.

Design rules, same priority as delegation-gate.py:
  1. FAIL OPEN on unreadable input -- but VISIBLY (exit 1 + stderr line) once a valid
     payload with a transcript_path was parsed: missing/empty transcript, ledger I/O
     failure, sibling import failure, any exception.
  2. FAIL CLOSED when the transcript is readable and the budget is spent.
  3. NEVER fire inside a subagent. The subagent IS where bulk reading belongs.
"""
import fcntl
import hashlib
import importlib.util
import json
import os
import re
import shlex
import sys
import time
import uuid

DEFAULT_CALLS = 3
DEFAULT_BYTES = 20000
SOLO_CALLS = 10
SOLO_BYTES = 80000
SMALL_FILE_BYTES = 4096
SMALL_RESULT_CHARS = 1500  # prior results at or below this do not count as a call
CHARS_PER_LINE = 120       # estimate for Read offset/limit (lines) -> characters
RESERVATION_TTL = 600      # seconds; a ledger reservation older than this is dropped

# Set once stdin parsed into a payload; after that, an internal error is surfaced
# (exit 1, non-blocking) instead of passing silently.
_PARSED = False

READ_COMMANDS = frozenset((
    "cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "find",
    "ls", "tree", "wc", "awk", "jq", "git-read", "gh-read",
))
# Read tools that read stdin when given no file operand (pipeline consumers).
# ls/find/tree never read stdin: as a consumer they still read the filesystem.
STDIN_READERS = frozenset(("cat", "head", "tail", "less", "more", "grep", "egrep",
                           "fgrep", "rg", "wc", "awk", "jq", "sed"))
# Per-tool flags that consume the NEXT word as their value (so it is not an operand).
VALUE_FLAGS = {
    "head": ("-n", "-c", "--lines", "--bytes"),
    "tail": ("-n", "-c", "--lines", "--bytes"),
    "grep": ("-e", "-f", "-A", "-B", "-C", "-m", "--regexp", "--file", "--max-count",
             "--context", "--after-context", "--before-context", "--label"),
    "rg": ("-e", "-f", "-A", "-B", "-C", "-m", "-g", "-t", "-T", "-M", "--regexp",
           "--file", "--glob", "--type", "--type-not", "--max-count", "--context"),
    "awk": ("-F", "-v", "-f"),
    "sed": ("-e", "-f", "--expression", "--file"),
    "jq": ("-f", "--from-file", "--indent"),
}
VALUE_FLAGS["egrep"] = VALUE_FLAGS["fgrep"] = VALUE_FLAGS["grep"]
# jq flags that consume TWO following words.
JQ_TWO_VALUE = ("--arg", "--argjson", "--slurpfile", "--rawfile")
# When none of these explicit-script flags is present, the first operand is the
# pattern/program/filter, not a file.
SCRIPT_FLAGS = {
    "grep": ("-e", "-f", "--regexp", "--file"), "rg": ("-e", "-f", "--regexp", "--file"),
    "awk": ("-f",), "sed": ("-e", "-f", "--expression", "--file"),
    "jq": ("-f", "--from-file"),
}
SCRIPT_FLAGS["egrep"] = SCRIPT_FLAGS["fgrep"] = SCRIPT_FLAGS["grep"]
# No diff/status: the orchestrator's own diff inspection must never be gated.
GIT_READ_SUBCOMMANDS = frozenset(("show", "log", "grep", "ls-files", "blame", "cat-file"))
# git global options that take a separate value argument (skipped to find the subcommand)
GIT_OPTS_WITH_VALUE = frozenset(("-C", "-c", "--git-dir", "--work-tree", "--namespace"))
SHELLS = frozenset(("sh", "bash", "zsh", "dash", "ksh"))
# Command prefixes stripped before the first word; value = flags that take an argument.
WRAPPERS = {
    "env": frozenset(("-u", "--unset", "-C", "--chdir", "-S", "--split-string")),
    "sudo": frozenset(("-u", "-g", "-U", "-C", "-D", "-h", "-p", "-r", "-t", "-T")),
    "command": frozenset(), "builtin": frozenset(), "nohup": frozenset(),
    "exec": frozenset(("-a",)), "time": frozenset(), "nice": frozenset(("-n",)),
    "!": frozenset(), "{": frozenset(), "then": frozenset(), "do": frozenset(),
    "else": frozenset(), "if": frozenset(), "while": frozenset(), "until": frozenset(),
}
EDIT_TOOLS = frozenset(("Edit", "Write", "MultiEdit", "NotebookEdit"))
DENIAL_MARKERS = ("BLOCKED by read-budget-gate", "BLOCKED by delegation-gate")
RE_MEMORY = re.compile(r"/\.claude/projects/[^/]+/memory/")
RE_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
RE_HEREDOC = re.compile(r"(?<!<)<<(?!<)(-?)\s*(['\"]?)([A-Za-z_][\w-]*)\2")
RE_SESSION = re.compile(r"^[\w.-]{1,128}$")

ADVICE = (
    "Bulk reading belongs in a lane: dispatch claude-crew:claude-scout (locate) or "
    "claude-crew:claude-reader (digest) and use its conclusion. If this read is genuinely "
    "inline work, classify first with `solo: D<n>` (raises the budget to 10 calls / 80KB). "
    "Reads of files you are about to edit: dispatch the edit to a lane, or classify solo "
    "first. If the gate is wrong here, ask the user to relaunch with CLAUDE_READ_BUDGET=off."
)


def _env_int(name, default):
    try:
        v = int(os.environ.get(name, ""))
        return v if v > 0 else default
    except ValueError:
        return default


def _now():
    # READ_BUDGET_NOW exists for tests only (TTL expiry without sleeping).
    try:
        return float(os.environ["READ_BUDGET_NOW"])
    except (KeyError, ValueError):
        return time.time()


def allow(reason=""):
    if reason and os.environ.get("READ_BUDGET_DEBUG"):
        print(f"[read-budget-gate] allow: {reason}", file=sys.stderr)
    sys.exit(0)


def block(message):
    print(message, file=sys.stderr)
    sys.exit(2)  # exit 2 == deny the tool call, surface stderr to the model


def inactive(reason):
    print(f"read-budget-gate: internal error, gate inactive: {reason}", file=sys.stderr)
    sys.exit(1)  # non-blocking error: the call proceeds, the user sees it


def _load_sibling():
    """Reuse delegation-gate.py's token regex and record helpers so the solo-token and
    marker semantics cannot drift. Its main() is guarded by __name__, so exec is inert."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "delegation-gate.py")
    spec = importlib.util.spec_from_file_location("delegation_gate", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --- Bash classification ---------------------------------------------------------------

def _strip_heredocs(cmd):
    """Drop heredoc bodies: their lines are data, not commands."""
    out, pending = [], []
    for line in cmd.split("\n"):
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            continue
        out.append(line)
        pending.extend(m.group(3) for m in RE_HEREDOC.finditer(line))
    return "\n".join(out)


def _pipelines(cmd):
    """Split into pipelines on unquoted && || ; & ( ) and newlines, and each pipeline into
    stages on | (and |&). Quote/backslash aware. An `&` touching a redirect (`2>&1`,
    `&>f`, `>&2`) is part of the redirect, not a separator."""
    pipes, stages, cur, q, i, n = [], [], [], None, 0, len(cmd)

    def end_stage():
        stages.append("".join(cur))
        cur.clear()

    def end_pipe():
        end_stage()
        pipes.append([s for s in stages if s.strip()])
        stages.clear()

    while i < n:
        c = cmd[i]
        nxt = cmd[i + 1] if i + 1 < n else ""
        if q:
            cur.append(c)
            if c == q:
                q = None
            elif c == "\\" and q == '"' and nxt:
                cur.append(nxt)
                i += 1
        elif c in "'\"":
            q = c
            cur.append(c)
        elif c == "\\" and nxt:
            cur.append(c + nxt)
            i += 1
        elif c == "|" and nxt == "|":
            end_pipe()
            i += 1
        elif c == "|":
            end_stage()
            if nxt == "&":
                i += 1
        elif c == "&" and (nxt == ">" or (cur and cur[-1] in "<>")):
            cur.append(c)
        elif c == "&" and nxt == "&":
            end_pipe()
            i += 1
        elif c in ";\n&()":
            end_pipe()
        else:
            cur.append(c)
        i += 1
    end_pipe()
    return [p for p in pipes if p]


def _split(cmd):
    try:
        return shlex.split(cmd)
    except ValueError:  # unbalanced quotes etc.
        return cmd.split()


def _normalize(stage):
    """(first_word, args) after stripping wrappers, or None when the stage is inert."""
    words = _split(stage)
    i = 0
    while i < len(words):
        w = words[i]
        if RE_ASSIGN.match(w):
            i += 1
            continue
        if w not in WRAPPERS:
            break
        if w == "command" and i + 1 < len(words) and words[i + 1] in ("-v", "-V"):
            return None  # `command -v cat` looks a name up, reads nothing
        takes_value = WRAPPERS[w]
        i += 1
        while i < len(words) and words[i].startswith("-") and words[i] != "-":
            if words[i] == "--":
                i += 1
                break
            i += 2 if words[i] in takes_value else 1
        if w == "env":
            while i < len(words) and (RE_ASSIGN.match(words[i]) or words[i] == "-"):
                i += 1
    if i >= len(words):
        return None
    return os.path.basename(words[i]), words[i + 1:]


def _file_operands(first, args):
    """Operands of a stdin-capable reader that name files (pattern/program excluded)."""
    vflags = VALUE_FLAGS.get(first, ())
    sflags = SCRIPT_FLAGS.get(first, ())
    ops, has_script_flag, j = [], False, 0
    while j < len(args):
        a = args[j]
        if a == "--":
            ops.extend(args[j + 1:])
            break
        if re.match(r"^(\d*[<>]|&>)", a):
            # bare operator (`>`, `2>`, `<`) takes the next word as target; attached
            # forms (`2>/dev/null`, `2>&1`, `>out`) are one word.
            j += 2 if re.fullmatch(r"\d*(>>?|<)|&>>?", a) else 1
            continue
        if a.startswith("-") and a != "-":
            if a in sflags or any(a.startswith(f + "=") for f in sflags if f.startswith("--")):
                has_script_flag = True
            if first == "jq" and a in JQ_TWO_VALUE:
                j += 3
                continue
            j += 2 if a in vflags else 1
            continue
        ops.append(a)
        j += 1
    if first in SCRIPT_FLAGS and not has_script_flag and ops:
        ops = ops[1:]  # first operand is the pattern / program / filter
    return [o for o in ops if o != "-"]


def _stdin_only(norm):
    if not norm:
        return False
    first, args = norm
    return first in STDIN_READERS and not _file_operands(first, args)


def _stage_is_read(norm, depth):
    if not norm:
        return False
    first, args = norm
    if first == "cat":
        # `cat > f` / `cat >> f` is a write (typically a heredoc), not a read.
        return not any(a.startswith(">") for a in args)
    if first in READ_COMMANDS:
        return True
    if first == "sed":
        return any(a in ("--quiet", "--silent") or re.match(r"^-[A-Za-z]*n[A-Za-z]*$", a)
                   for a in args)
    if first == "git":
        j = 0
        while j < len(args) and args[j].startswith("-"):
            j += 2 if args[j] in GIT_OPTS_WITH_VALUE else 1
        if j >= len(args) or args[j] not in GIT_READ_SUBCOMMANDS:
            return False
        if args[j] == "log":
            rest = args[j + 1:]
            patch = any(a in ("-p", "-u", "--patch") for a in rest)
            summary = any(a == "--oneline" or a.startswith("--format")
                          or a.startswith("--pretty") for a in rest)
            return patch or not summary  # summary-only log is never gated
        return True
    if first in SHELLS and depth < 3:
        for j, a in enumerate(args):
            if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) and j + 1 < len(args):
                return bash_is_read(args[j + 1], depth + 1)
    return False


def bash_is_read(cmd, depth=0):
    if not isinstance(cmd, str) or not cmd.strip():
        return False
    for stages in _pipelines(_strip_heredocs(cmd)):
        prev = False
        for k, stage in enumerate(stages):
            norm = _normalize(stage)
            # A stdin-only consumer inherits its producer: `git diff | head` is free,
            # `cat big | head` is counted.
            cur = prev if (k > 0 and _stdin_only(norm)) else _stage_is_read(norm, depth)
            if cur:
                return True
            prev = cur
    return False


def is_read_shaped(name, inp):
    if name in ("Read", "Grep", "Glob"):
        return True
    if name == "Bash" and isinstance(inp, dict):
        return bash_is_read(inp.get("command"))
    return False


def _norm(p):
    return os.path.normpath(os.path.expanduser(p)) if isinstance(p, str) and p else ""


def read_exempt(name, inp, edited):
    """Call-count exemptions; they apply to the Read tool only."""
    if name != "Read" or not isinstance(inp, dict):
        return False
    p = _norm(inp.get("file_path"))
    if not p:
        return True  # malformed: let the tool error normally
    if RE_MEMORY.search(p):
        return True
    if p in edited:
        return True  # re-read after a successful edit
    try:
        st = os.stat(p)
    except OSError:
        return True  # missing/unstatable: the tool errors normally
    if not os.path.isfile(p):
        return True  # directory etc.: Read errors on it
    return st.st_size < SMALL_FILE_BYTES


def _pos_int(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and v > 0 else 0


def oversized_read(inp, max_bytes):
    """(path, size, estimate) when a Read would pull more than max_bytes, else None.
    Estimate = size - offset*CPL, capped at limit*CPL when limit > 0 (limit=0: no cap)."""
    p = _norm(inp.get("file_path")) if isinstance(inp, dict) else ""
    if not p or RE_MEMORY.search(p) or not os.path.isfile(p):
        return None
    size = os.path.getsize(p)
    est = max(0, size - _pos_int(inp.get("offset")) * CHARS_PER_LINE)
    limit = _pos_int(inp.get("limit"))
    if limit:
        est = min(est, limit * CHARS_PER_LINE)
    return (p, size, est) if est > max_bytes else None


def _result_text(content):
    if isinstance(content, str):
        return content
    parts = []
    for blk in content if isinstance(content, list) else []:
        if isinstance(blk, dict) and isinstance(blk.get("text"), str):
            parts.append(blk["text"])
        elif isinstance(blk, str):
            parts.append(blk)
    return "".join(parts)


# --- Reservation ledger ------------------------------------------------------------------

def _ledger_path(payload, transcript):
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    base = (os.environ.get("CLAUDE_READ_BUDGET_STATE_DIR")
            or os.path.join(config_dir, "state", "read-budget"))
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not RE_SESSION.match(sid):
        sid = "t-" + hashlib.sha256(transcript.encode()).hexdigest()[:32]
    return base, os.path.join(base, sid + ".json")


def _sig(name, inp):
    """Canonical (name, input) signature for matching a generated-id reservation."""
    blob = json.dumps([name, inp], sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(blob.encode()).hexdigest()


def main():
    if os.environ.get("CLAUDE_READ_BUDGET", "").lower() == "off":
        allow("disabled via CLAUDE_READ_BUDGET=off")

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
    global _PARSED
    _PARSED = True

    # Rule 3: DELIBERATE divergence from delegation-gate.py (lines ~264-271), which needs
    # BOTH keys. Here EITHER non-empty agent_id OR agent_type counts as a subagent:
    # blocking a lane's reads (where bulk reading belongs) is worse than missing one
    # main-loop read if a main payload ever gains one of these keys.
    transcript = payload.get("transcript_path")
    agent_id = payload.get("agent_id")
    agent_type = payload.get("agent_type")
    if ((isinstance(agent_id, str) and agent_id)
            or (isinstance(agent_type, str) and agent_type)):
        allow("subagent invocation (agent_id or agent_type present)")
    if isinstance(transcript, str) and "/subagents/" in transcript:
        allow("subagent transcript path")

    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}
    if not is_read_shaped(tool, tool_input):
        allow(f"not read-shaped: {tool}")

    if transcript is None or transcript == "":
        allow("no transcript_path in payload")  # harness gave none: silent
    if not isinstance(transcript, str) or not os.path.isfile(transcript):
        inactive(f"transcript missing: {transcript!r}")

    dg = _load_sibling()
    _content = dg._content

    try:
        with open(transcript, "r", errors="ignore") as fh:
            lines = fh.readlines()
    except Exception as exc:
        inactive(f"transcript unreadable: {type(exc).__name__}: {exc}")
    records = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            records.append(obj)
    if not records:
        inactive(f"no parseable records in {transcript}")

    # Window start: copied from delegation-gate.py main() lines ~313-344 (inline there,
    # not importable). Semantics MUST stay identical: skip sidechain, non-string content,
    # isMeta, and promptSource=="system" records carrying a harness prefix.
    start = 0
    for i, rec in enumerate(records):
        if rec.get("type") != "user" or rec.get("isSidechain"):
            continue
        content = _content(rec)
        if not isinstance(content, str):
            continue
        if rec.get("isMeta"):
            continue
        stripped = content.lstrip()
        if rec.get("promptSource") == "system" and any(
                stripped.startswith(p) for p in dg.HARNESS_PREFIXES):
            continue
        start = i
    window = records[start:]
    wkey = records[start].get("uuid")
    if not isinstance(wkey, str) or not wkey:
        wkey = f"idx:{start}"

    # One pass: main-session tool_uses, tool_results, solo tokens.
    uses = []          # (index, name, input, id)
    results = {}       # tool_use_id -> (index, is_error, length, is_gate_denial)
    solo = False
    for i, rec in enumerate(window):
        if rec.get("isSidechain"):
            continue
        content = _content(rec)
        if not isinstance(content, list):
            continue
        rtype = rec.get("type")
        for blk in content:
            if not isinstance(blk, dict):
                continue
            btype = blk.get("type")
            if rtype == "assistant" and btype == "text":
                text = blk.get("text")
                if isinstance(text, str) and dg.RE_SOLO.search(text):
                    solo = True
            elif rtype == "assistant" and btype == "tool_use":
                inp = blk.get("input") if isinstance(blk.get("input"), dict) else {}
                uses.append((i, blk.get("name"), inp, blk.get("id")))
            elif rtype == "user" and btype == "tool_result":
                tid = blk.get("tool_use_id")
                if tid and tid not in results:
                    text = _result_text(blk.get("content"))
                    results[tid] = (i, blk.get("is_error") is True, len(text),
                                    any(m in text for m in DENIAL_MARKERS))

    # Re-read after edit: only paths a SUCCESSFUL edit touched.
    edited = set()
    for i, name, inp, tid in uses:
        if name not in EDIT_TOOLS:
            continue
        r = results.get(tid) if tid else None
        if r and r[0] > i and not r[1]:
            p = _norm(inp.get("file_path") or inp.get("notebook_path"))
            if p:
                edited.add(p)

    # Solo via the Bash ":" marker: same shape as delegation-gate.marker_found, but the
    # description must carry a SOLO token (a dispatching marker does not raise the budget).
    if not solo:
        for i, name, inp, tid in uses:
            if name != "Bash":
                continue
            cmd, desc = inp.get("command"), inp.get("description")
            if not isinstance(cmd, str) or cmd.strip() != dg.MARKER_COMMAND:
                continue
            if not isinstance(desc, str) or not dg.RE_SOLO.search(desc):
                continue
            r = results.get(tid) if tid else None
            if r and r[0] > i and not r[1]:
                solo = True
                break

    if solo:
        max_calls, max_bytes = SOLO_CALLS, SOLO_BYTES
    else:
        max_calls = _env_int("CLAUDE_READ_BUDGET_CALLS", DEFAULT_CALLS)
        max_bytes = _env_int("CLAUDE_READ_BUDGET_BYTES", DEFAULT_BYTES)
    tier = "solo tier" if solo else "default tier"

    if tool == "Read":
        big = oversized_read(tool_input, max_bytes)
        if big:
            p, size, est = big
            block(f"BLOCKED by read-budget-gate: {p} is {size} bytes and this Read would "
                  f"return ~{est} chars, over the {max_bytes}-char cap ({tier}). Pass "
                  f"offset/limit to read only the part you need, or dispatch "
                  f"claude-crew:claude-reader to digest it and use its conclusion.\n"
                  + ADVICE)

    if read_exempt(tool, tool_input, edited):
        allow("exempt read")

    used_calls, used_bytes = 0, 0
    for i, name, inp, tid in uses:
        if not is_read_shaped(name, inp):
            continue
        r = results.get(tid) if tid else None
        if r and not r[3]:
            used_bytes += r[2]  # every read's output, except gate denials
        if read_exempt(name, inp, edited):
            continue
        if r and (r[1] or r[2] <= SMALL_RESULT_CHARS):
            continue  # errored, or small output: not a call
        used_calls += 1

    # Reservation ledger (parallel calls): serialize the decision under an flock.
    cur_id = payload.get("tool_use_id")
    generated = not isinstance(cur_id, str) or not cur_id
    if generated:
        cur_id = "gen-" + uuid.uuid4().hex
    seen = {tid for _, _, _, tid in uses if tid}
    sig_counts = {}
    for _, name, inp, _ in uses:
        s = _sig(name, inp)
        sig_counts[s] = sig_counts.get(s, 0) + 1
    now = _now()

    def live(e):
        if not isinstance(e, dict) or not isinstance(e.get("tool_use_id"), str):
            return False
        ts = e.get("ts")
        # abs(): a clock that jumped backwards must not pin a reservation forever.
        if not isinstance(ts, (int, float)) or abs(now - ts) > RESERVATION_TTL:
            return False
        if e["tool_use_id"] in seen:
            return False  # landed: the transcript is authoritative
        sig, was = e.get("sig"), e.get("seen")
        if isinstance(sig, str) and isinstance(was, int) and sig_counts.get(sig, 0) > was:
            return False  # generated id: a matching call has landed since reservation
        return True

    try:
        base, lpath = _ledger_path(payload, transcript)
        os.makedirs(base, exist_ok=True)
        fd = os.open(lpath, os.O_RDWR | os.O_CREAT, 0o600)
        with os.fdopen(fd, "r+") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            try:
                data = json.loads(fh.read() or "{}")
            except ValueError:
                data = {}  # corrupt ledger: start over
            entries = data.get("entries") if isinstance(data, dict) else None
            if not isinstance(entries, list) or data.get("window") != wkey:
                entries = []  # prune other windows
            entries = [e for e in entries if live(e)]
            inflight = sum(1 for e in entries if e["tool_use_id"] != cur_id)
            call_no = used_calls + inflight + 1
            ok = call_no <= max_calls and used_bytes < max_bytes
            if ok and not any(e["tool_use_id"] == cur_id for e in entries):
                entry = {"tool_use_id": cur_id, "bytes_unknown": True, "ts": now}
                if generated:
                    s = _sig(tool, tool_input)
                    entry.update(sig=s, seen=sig_counts.get(s, 0))
                entries.append(entry)
            fh.seek(0)
            fh.truncate()
            json.dump({"window": wkey, "entries": entries}, fh)
            fh.flush()
    except OSError as exc:
        inactive(f"ledger I/O failed: {type(exc).__name__}: {exc}")

    if ok:
        allow(f"within budget: call {call_no}/{max_calls}, {used_bytes}/{max_bytes} chars")

    block(
        f"BLOCKED by read-budget-gate: this would be read call {call_no} of {max_calls} "
        f"({tier}; {inflight} in flight); {used_bytes} of {max_bytes} characters of read "
        f"output already used since the last user message.\n" + ADVICE
    )


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # Rule 1: fail open, always -- but surfaced once parsed
        if _PARSED:
            print(f"read-budget-gate: internal error, gate inactive: "
                  f"{type(exc).__name__}: {exc}", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
