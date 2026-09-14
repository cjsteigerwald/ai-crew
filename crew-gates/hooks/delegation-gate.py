#!/usr/bin/env python3
"""PreToolUse gate on Edit|Write|NotebookEdit|Bash: require a delegation classification.

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

Bash: only a command that WRITES a file consults the classification (redirects, a
heredoc script calling a write API, and writers such as tee/dd/sed -i/cp/touch/curl -o/
tar -x in command position). Read-only commands pass untouched -- gating every Bash
call would deadlock the investigation that precedes classification -- and the marker
command ":" is allowed before any inspection, or the recovery path itself would be
blocked. A write passes only when EVERY destination resolves to an absolute path under
/tmp, /private/tmp, /var/tmp, /dev, or the Claude config dir's projects/ or _backups/;
an unresolvable destination is gated. The detection is a heuristic and knowingly
incomplete -- see the _bash_needs_classification block.

Design rules, in priority order:
  1. FAIL OPEN on any internal error. A broken gate must never brick the session;
     a missed dispatch is cheaper than an unusable edit path. The one exception:
     a deny already decided is never downgraded to allow -- see _VERDICT.
  2. FAIL CLOSED when the transcript is readable and carries no token. That is the
     entire point of the gate.
  3. NEVER fire inside a subagent. The subagent IS the delegation target.
"""
import json
import os
import re
import signal
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


# The verdict, latched by the store in block(). Once that store has completed, a later
# in-process failure (KeyboardInterrupt, SystemExit, a failed stderr write or flush)
# does not downgrade it to allow. None means "nothing decided yet" => allow. The
# contract is enforced by the __main__ handler, so tests must run this as __main__.
_VERDICT = None


def _exit(code):
    """Exit with an EXACT status from the alphabet {0, 2}. Flush stderr inside a guard,
    then bypass the interpreter shutdown flush -- if that flush fails, CPython replaces
    the status with 120, and this hook's exit code IS its verdict."""
    if code not in (0, 2):
        code = 2 if _VERDICT == 2 else 0
    try:
        sys.stderr.flush()
    except BaseException:
        pass
    os._exit(code)


def allow(reason=""):
    if reason and os.environ.get("DELEGATION_GATE_DEBUG"):
        try:
            print(f"[delegation-gate] allow: {reason}", file=sys.stderr)
        except BaseException:
            pass
    _exit(0)


def block(message):
    # COMMIT POINT: the successful `_VERDICT = 2` store, not entry to this function. A
    # fault before the store exits 0 (irreducible in pure Python); after it, delivery is
    # best-effort and must not turn the deny into exit 0 -- a silent allow.
    global _VERDICT
    _VERDICT = 2
    try:
        signal.signal(signal.SIGINT, signal.SIG_IGN)
    except BaseException:
        pass
    try:
        print(message, file=sys.stderr)
    except BaseException:
        pass
    _exit(2)  # exit 2 == deny the tool call, surface stderr to the model


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


# --- Bash: gate only the commands that WRITE a file -------------------------
# Writing a file through a Bash heredoc routed around this gate entirely while the
# matcher covered only Edit|Write|NotebookEdit. Gating EVERY Bash call would be wrong:
# the gate blocks until a classification exists, and the read-only investigation that
# PRECEDES the classification (git status, grep, ls, cat) would deadlock the start of
# every task. So a Bash command is inspected, and only one that writes a file consults
# the classification at all.
#
# THIS DETECTION IS A HEURISTIC OVER ARBITRARY SHELL AND IS KNOWN TO BE INCOMPLETE. It
# covers: output redirections (>, >>, >|, &>, &>>, >&file, <>; spaced or not), a
# heredoc script body that writes, command substitutions inside [[ ]] / (( )), and these
# writers in command position (also behind sudo/env/nice/time/timeout/nohup/command/
# builtin/exec/xargs and after find -exec/-execdir/-ok/-okdir): tee FILE, dd of=, sed/
# perl/ruby in-place, cp/mv/install/ln, rsync (destination plus --log-file/batch/temp/
# backup/partial dirs), touch, truncate, patch, git apply, curl -o/-O and its dump/
# cookie/trace files, wget, tar extraction, unzip, and `time -o FILE`. It does NOT catch
# a write inside a `python3 -c` / `node -e` / awk / `sh -c` string, an eval'd command, a
# helper script or shell function that writes on the command's behalf, or deliberate
# obfuscation. Destinations are compared lexically: a symlink out of an exempt directory
# is not followed. The bias is intentional: a missed exotic write is a gap, but gating
# an innocent read-only command trains the user to switch the hook off, losing everything.
#
# Every pattern below must stay linear on hostile input: the hook runs on each Bash call,
# and a regex that backtracks quadratically stalls the session (a 25,000-character
# `((((` took 77s on a lazy span pattern).
# `<<<` is a herestring, never a heredoc: the lookbehind stops `<<< foo` opening one.
_HEREDOC_START = re.compile(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_]\w*)\1")
# Every redirection operator, input ones included so they can be REMOVED before the
# command words are tokenized (`cp a b < /dev/null` must not make /dev/null the
# destination). Longest operators first. The target stops at whitespace and at shell
# metacharacters, so `echo x>a` and `2>&1>out` both split correctly. The fd digits start
# only at the beginning of a digit run: retrying inside the run was quadratic.
_REDIR = re.compile(r"(?<!\d)\d*(<<<|<<-?|&>>|&>|<>|>>|>\||>&|<&|>|<)[ \t]*([^\s;&|()<>]*)")
# An unquoted comment: `#` at the start of a word, i.e. after whitespace or at the start.
# `${x#y}` and `$#` have no whitespace before the `#`, so they stay.
_COMMENT = re.compile(r"(?:^|(?<=\s))#[^\n]*")
# Placeholders written by _neutralize_quotes. _QPH replaces a quoted span that cannot
# stand in as one plain word; its `$` makes it unresolvable, so as a destination it
# gates. _EPH replaces an escaped metacharacter (`\>`, `\;`) or a quoted lone `;`/`+`.
_QPH = "$__Q"
_EPH = "__E__"
# `[[ ... ]]` and `(( ... ))` / `$(( ... ))` compare with `>`; they never redirect. The
# spans are found by _blank_test_spans (a linear scan) from these openers and closers.
_TEST_OPEN = re.compile(r"\[\[[ \t]|\$?\(\(")
_BRACKET_CLOSE = re.compile(r"[ \t]\]\]")
# Nesting depth past which a command substitution inside a test span is not analysed
# further; its destination is then unknown (gated) rather than silently dropped.
_SUBST_DEPTH = 4
# Writes performed by a script fed in on a heredoc, for which no shell redirect appears.
# sys.stdout/sys.stderr .write() are excluded: those are prints. The open() argument
# scan stops at `(` as well as `)`: with `[^)]*` a body of repeated `open(` rescanned to
# the end from each one (quadratic), and a nested call already failed to match anyway.
_SCRIPT_WRITE = re.compile(
    r"""\bopen\s*\([^()]*,\s*['"][rbt+]*[wax][\w+]*['"]"""
    r"""|\.write_text\s*\(|\.writelines\s*\("""
    r"""|(?<!sys\.stdout)(?<!sys\.stderr)\.write\s*\("""
    r"""|\bwriteFileSync\s*\(|\bappendFileSync\s*\("""
    r"""|\bshutil\.(?:copy|copy2|copyfile|move)\s*\("""
    r"""|\bos\.(?:replace|rename|remove)\s*\("""
)
# String literals inside a heredoc body. Both quote styles are scanned independently,
# so a stray quote of one kind cannot hide a literal of the other.
_BODY_LITERALS = (re.compile(r'"([^"\n]*)"'), re.compile(r"'([^'\n]*)'"))
_FILENAME = re.compile(r"[\w.+-]*\w\.[A-Za-z][A-Za-z0-9]{0,9}")
_SEG_SPLIT = re.compile(r"\|\||&&|[;|&()\n]|(?:^|(?<=\s))[{}](?=\s|;|$)")
_BACKTICK = re.compile(r"`([^`]*)`")
_ENV_ASSIGN = re.compile(r"^\w+=")

# Shell keywords that precede a command word without being it.
_KEYWORDS = frozenset(("then", "else", "elif", "do", "if", "while", "until", "!"))
# Wrappers: name -> (short options taking an argument, long options taking one,
# leading positionals, option keys whose value is a file the wrapper itself writes).
# Their options are stripped so `sudo -u root cp` finds `cp`.
_NONE = frozenset()
_WRAPPERS = {
    "sudo": (frozenset("CDghpRrTtUu"), frozenset((
        "--close-from", "--chdir", "--group", "--host", "--prompt", "--chroot",
        "--role", "--type", "--command-timeout", "--other-user", "--user")), 0, _NONE),
    "env": (frozenset("uCSP"), frozenset(("--unset", "--chdir", "--split-string")), 0,
            _NONE),
    "nice": (frozenset("n"), frozenset(("--adjustment",)), 0, _NONE),
    "time": (frozenset("of"), frozenset(("--output", "--format")), 0,
             frozenset(("o", "--output"))),
    "timeout": (frozenset("sk"), frozenset(("--signal", "--kill-after")), 1, _NONE),
    "xargs": (frozenset("ILnPsdEa"), frozenset((
        "--max-args", "--max-procs", "--max-chars", "--delimiter", "--arg-file",
        "--max-lines")), 0, _NONE),
    "exec": (frozenset("a"), _NONE, 0, _NONE),
    "nohup": (_NONE, _NONE, 0, _NONE),
    "command": (_NONE, _NONE, 0, _NONE),
    "builtin": (_NONE, _NONE, 0, _NONE),
}


def _resolve_dest(dest, cwd):
    """Absolute form of a write destination, for exemption matching only.

    Relative destinations resolve against the payload cwd, so `> ./out.txt` while cwd is
    a scratch directory is not gated. A destination containing a variable, a command
    substitution, or a leading `~` is returned unchanged: its value is not knowable
    here, and _exempt_dest refuses anything not absolute. normpath collapses `..`, so
    `> /tmp/../repo/src/x.ts` gates rather than passing itself off as scratch."""
    p = dest.strip().strip("'\"")
    if not p or "$" in p or "`" in p or p.startswith("~"):
        return p
    if p.startswith("/"):
        return os.path.normpath(p)
    if isinstance(cwd, str) and cwd.startswith("/"):
        return os.path.normpath(os.path.join(cwd, p))
    return p  # no usable cwd -> unresolvable -> gates


def _claude_config_dir():
    base = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
    return os.path.normpath(base) if base.startswith("/") else None


def _exempt_dest(dest, cwd=None):
    """A write destination that is never a project edit. None means "a write whose
    destination could not be determined" and is never exempt."""
    if not isinstance(dest, str):
        return False
    p = _resolve_dest(dest, cwd)
    # Unresolved (`$HOME/...`, `~/...`, `` `pwd`/... ``, relative with no cwd): refuse
    # BEFORE any prefix test, or `$X/.claude/projects/../../src/a.py` passes as
    # bookkeeping while the shell writes it into the repo.
    if not p.startswith("/") or "$" in p or "`" in p:
        return False
    if p.startswith("/dev/"):
        return True
    # /tmp and /private/tmp are the SAME directory on macOS (/tmp is a symlink), and the
    # per-session scratchpad lives under /private/tmp/claude-*/.
    for root in ("/tmp", "/private/tmp", "/var/tmp"):
        if p == root or p.startswith(root + "/"):
            return True
    # Bookkeeping, anchored to the REAL Claude config dir. An unanchored substring test
    # exempted /repo/.claude/projects/pkg/src/a.py. Mirrors EXEMPT_SUBSTRINGS.
    base = _claude_config_dir()
    if base:
        for s in EXEMPT_SUBSTRINGS:
            if p.startswith(base + s[len("/.claude"):]):
                return True
    return False


def _strip_heredocs(command):
    """Return (shell_text_without_heredoc_bodies, [body, ...]).

    Bodies are pulled out before any tokenizing so their contents cannot invent phantom
    redirects or command words in the surrounding shell text."""
    lines = command.split("\n")
    kept, bodies = [], []
    i = 0
    while i < len(lines):
        line = lines[i]
        kept.append(line)
        i += 1
        for m in _HEREDOC_START.finditer(line):
            delim = m.group(2)
            # bash: `<<WORD` ends only on a line that IS the word; `<<-WORD` strips
            # leading tabs, and nothing else, first.
            tabs = m.group(0).startswith("<<-")
            body = []
            while i < len(lines) and (lines[i].lstrip("\t") if tabs else lines[i]) != delim:
                body.append(lines[i])
                i += 1
            i += 1  # consume the terminator (or run off the end, which is fine)
            bodies.append("\n".join(body))
    return "\n".join(kept), bodies


def _neutralize_quotes(text):
    """Collapse quoting so a quoted or escaped metacharacter cannot fake a redirect or a
    separator (awk '$1 > 5', [ a \\> b ]). A quoted span that is a plain word is kept
    as that word, so `> "/tmp/x"` still yields its destination; anything else becomes
    one placeholder token, never several words."""
    out, i, n = [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "\\":
            nxt = text[i + 1:i + 2]
            if nxt and nxt != "\n":
                out.append(nxt if (nxt.isalnum() or nxt in "/._-") else _EPH)
            i += 2
            continue
        if ch in "'\"":
            j = i + 1
            while j < n and text[j] != ch:
                j += 2 if (ch == '"' and text[j] == "\\") else 1
            if j >= n:
                out.append(_QPH)  # unterminated: a syntax error, never a clean word
                break
            inner = text[i + 1:j]
            if inner in (";", "+"):
                out.append(_EPH)
            # `#` too: an unwrapped "#x" or `""#` would start a word with `#` and be
            # stripped as a comment, taking a real redirect after it along.
            elif not inner or any(c.isspace() or c in "<>;|&(){}`\\#" for c in inner):
                out.append(_QPH)
            else:
                out.append(inner)
            i = j + 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _parse_opts(args, short=None, long_arg=frozenset()):
    """GNU-style option parse -> ([(key, value), ...], operands).

    short maps a letter to how it takes a value: "next" (rest of the cluster, else the
    next word), "rest" (rest of the cluster only, possibly empty), "digits" (leading
    digits only). Unlisted letters are flags. Options may follow operands."""
    short = short or {}
    opts, operands = [], []
    i, n = 0, len(args)
    while i < n:
        a = args[i]
        i += 1
        if a == "--":
            operands.extend(args[i:])
            break
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            if eq:
                opts.append((name, val))
            elif name in long_arg and i < n:
                opts.append((name, args[i]))
                i += 1
            else:
                opts.append((name, None))
            continue
        if a.startswith("-") and len(a) > 1:
            j = 1
            while j < len(a):
                c, rest, kind = a[j], a[j + 1:], short.get(a[j])
                if kind == "next":
                    if rest:
                        opts.append((c, rest))
                    elif i < n:
                        opts.append((c, args[i]))
                        i += 1
                    else:
                        opts.append((c, ""))
                    break
                if kind == "rest":
                    opts.append((c, rest))
                    break
                if kind == "digits":
                    k = j + 1
                    while k < len(a) and a[k].isdigit():
                        k += 1
                    opts.append((c, a[j + 1:k]))
                    j = k
                    continue
                opts.append((c, None))
                j += 1
            continue
        operands.append(a)
    return opts, operands


def _values(opts, *keys):
    return [v for k, v in opts if k in keys]


def _keys(opts):
    return {k for k, _ in opts}


def _nexts(letters):
    return {c: "next" for c in letters}


def _w_tee(args):
    return [a for a in _parse_opts(args)[1] if a != "-"]


def _w_dd(args):
    return [a.split("=", 1)[1] for a in args if a.startswith("of=")]


def _inplace(short, long_arg, inplace_keys, script_keys):
    """sed/perl/ruby: a write only with the in-place flag actually set. The script is
    the first operand unless given by an option, and is never a destination."""
    def handler(args):
        opts, ops = _parse_opts(args, short, long_arg)
        keys = _keys(opts)
        if not keys & inplace_keys:
            return []
        files = ops if keys & script_keys else ops[1:]
        return files or [None]
    return handler


def _copy(short, long_arg, target_keys, one_operand):
    """cp/mv/install/ln/rsync: -t/--target-directory if given, else the last operand."""
    def handler(args):
        opts, ops = _parse_opts(args, short, long_arg)
        tgt = _values(opts, *target_keys)
        if tgt:
            return tgt
        if len(ops) >= 2:
            return [ops[-1]]
        if len(ops) == 1:
            return one_operand(ops)
        return []
    return handler


_RSYNC_LONG = frozenset((
    "--log-file", "--log-file-format", "--exclude", "--include", "--exclude-from",
    "--include-from", "--files-from", "--filter", "--rsh", "--rsync-path",
    "--temp-dir", "--compare-dest", "--copy-dest", "--link-dest", "--backup-dir",
    "--suffix", "--chmod", "--chown", "--partial-dir", "--timeout", "--contimeout",
    "--bwlimit", "--password-file", "--port", "--out-format", "--max-size",
    "--min-size", "--max-delete", "--block-size", "--modify-window", "--iconv",
    "--checksum-choice", "--compress-choice", "--compress-level", "--skip-compress",
    "--usermap", "--groupmap", "--info", "--debug", "--outbuf", "--sockopts",
    "--write-batch", "--only-write-batch", "--read-batch", "--protocol",
    "--stop-after", "--stop-at", "--remote-option"))


def _w_rsync(args):
    """rsync: the transfer destination (last of >= 2 operands; one operand only lists)
    plus the files its options write. -t is --times, not a target. The temp/backup/
    partial dirs resolve against the DESTINATION when relative, which is not modelled:
    only an absolute one is a known destination."""
    opts, ops = _parse_opts(args, _nexts("efTBM"), _RSYNC_LONG)
    dests = [ops[-1]] if len(ops) >= 2 else []
    dests += _values(opts, "--log-file", "--write-batch", "--only-write-batch")
    for v in _values(opts, "T", "--temp-dir", "--backup-dir", "--partial-dir"):
        dests.append(v if isinstance(v, str) and v.startswith("/") else None)
    return dests


def _w_touch(args):
    return _parse_opts(args, _nexts("rtdA"), frozenset(("--reference", "--date", "--time")))[1]


def _w_truncate(args):
    return _parse_opts(args, _nexts("sr"), frozenset(("--size", "--reference")))[1]


def _w_patch(args):
    opts, ops = _parse_opts(args, _nexts("BDdFgiopVrYzx"), frozenset((
        "--directory", "--input", "--output", "--strip", "--reject-file", "--prefix",
        "--suffix", "--basename-prefix", "--ifdef", "--fuzz", "--get", "--quoting-style",
        "--version-control")))
    if _keys(opts) & {"--dry-run", "--check", "C"}:
        return []
    out = _values(opts, "o", "--output")
    if out:
        return [v for v in out if v != "-"]
    d = _values(opts, "d", "--directory")
    base = d[-1] if d else "."
    if ops:
        return [ops[0] if ops[0].startswith("/") else os.path.join(base, ops[0])]
    return [base]


def _w_git(args):
    rest, base, worktree = list(args), ".", None
    while rest and rest[0].startswith("-"):
        a = rest.pop(0)
        name, eq, val = a.partition("=")
        if not eq and name in ("-C", "-c", "--git-dir", "--work-tree", "--namespace",
                               "--super-prefix", "--config-env") and rest:
            val = rest.pop(0)
        if name == "-C":
            base = val if val.startswith("/") else os.path.join(base, val)
        elif name == "--work-tree":
            worktree = val
    if not rest or rest[0] != "apply":
        return []
    opts, _ = _parse_opts(rest[1:], _nexts("pC"), frozenset((
        "--directory", "--exclude", "--include", "--whitespace", "--build-fake-ancestor")))
    keys = _keys(opts)
    if keys & {"--check", "--stat", "--numstat", "--summary"} and "--apply" not in keys:
        return []
    if worktree:
        return [worktree if worktree.startswith("/") else os.path.join(base, worktree)]
    return [base]


def _w_curl(args):
    opts, _ = _parse_opts(args, _nexts("AbcCdDeEFHKmoPQrtTuUwxXyYz"), frozenset((
        "--output", "--output-dir", "--data", "--data-binary", "--data-raw",
        "--data-urlencode", "--header", "--request", "--user", "--user-agent", "--referer",
        "--cookie", "--cookie-jar", "--form", "--upload-file", "--proxy", "--max-time",
        "--write-out", "--config", "--range", "--cert", "--key", "--cacert",
        "--dump-header", "--connect-timeout", "--retry", "--resolve", "--url", "--json",
        "--limit-rate", "--proto", "--trace", "--trace-ascii", "--stderr", "--etag-save",
        "--hsts")))
    outdir = _values(opts, "--output-dir")
    base = outdir[-1] if outdir else None
    dests = []
    for k, v in opts:
        if k in ("o", "--output") and v != "-":
            dests.append(v if base is None or v.startswith("/") else os.path.join(base, v))
        elif k in ("O", "--remote-name", "--remote-name-all"):
            dests.append(base or ".")
        elif k in ("D", "--dump-header", "c", "--cookie-jar", "--trace", "--trace-ascii",
                   "--stderr", "--etag-save", "--hsts") and v != "-":
            dests.append(v)  # side files; `-` is stdout
    return dests


def _w_wget(args):
    opts, ops = _parse_opts(args, _nexts("eoaiBtOTwQPUYlARDIX"), frozenset((
        "--output-document", "--output-file", "--append-output", "--input-file", "--base",
        "--tries", "--timeout", "--wait", "--quota", "--directory-prefix", "--user-agent",
        "--level", "--accept", "--reject", "--domains", "--include-directories",
        "--exclude-directories", "--user", "--password", "--header", "--post-data",
        "--post-file", "--load-cookies", "--save-cookies", "--limit-rate", "--execute",
        "--referer", "--warc-file")))
    keys = _keys(opts)
    dests = _values(opts, "o", "a", "--output-file", "--append-output", "--save-cookies",
                    "--warc-file")
    doc = _values(opts, "O", "--output-document")
    if doc:
        dests += [v for v in doc if v != "-"]
    elif "--spider" not in keys and (ops or keys & {"i", "--input-file"}):
        prefix = _values(opts, "P", "--directory-prefix")
        dests.append(prefix[-1] if prefix else ".")  # plain `wget URL` writes into cwd
    return dests


def _w_tar(args):
    args = list(args)
    if args and re.fullmatch(r"[A-Za-z]+", args[0]):
        args[0] = "-" + args[0]  # old-style bundle: `tar xzf a.tgz`
    opts, _ = _parse_opts(args, _nexts("bCfFgHIKLNTVX"), frozenset((
        "--directory", "--file", "--files-from", "--exclude-from", "--exclude",
        "--use-compress-program", "--transform", "--xform", "--strip-components",
        "--owner", "--group", "--mode", "--label", "--newer", "--after-date",
        "--blocking-factor", "--format", "--listed-incremental", "--to-command")))
    keys = _keys(opts)
    if not keys & {"x", "--extract", "--get"} or keys & {"O", "--to-stdout", "t", "--list"}:
        return []
    return _values(opts, "C", "--directory") or ["."]


def _w_unzip(args):
    dests, operands, readonly, i = [], [], False, 0
    while i < len(args):
        a = args[i]
        i += 1
        if a.startswith("-") and len(a) > 1:
            letters, _, rest = a[1:].partition("d")
            readonly = readonly or any(c in "clptvzZ" for c in letters)
            if "d" in a[1:]:
                if rest:
                    dests.append(rest)
                elif i < len(args):
                    dests.append(args[i])
                    i += 1
        else:
            operands.append(a)
    if readonly or not operands:
        return []
    return dests or ["."]


def _w_find(args):
    dests, i = [], 0
    while i < len(args):
        if args[i] in ("-exec", "-execdir", "-ok", "-okdir"):
            j = i + 1
            while j < len(args) and args[j] not in (_EPH, "+", ";"):
                j += 1
            dests.extend(_segment_dests(args[i + 1:j]))
            i = j + 1
        else:
            i += 1
    return dests


_CP_LONG = frozenset(("--target-directory", "--suffix"))
_WRITERS = {
    "tee": _w_tee,
    "dd": _w_dd,
    "sed": _inplace({"e": "next", "f": "next", "l": "next", "i": "rest"},
                    frozenset(("--expression", "--file", "--line-length")),
                    {"i", "--in-place"}, {"e", "f", "--expression", "--file"}),
    "perl": _inplace({"e": "next", "E": "next", "I": "next", "i": "rest", "M": "rest",
                      "m": "rest", "x": "rest", "d": "rest", "D": "rest", "F": "rest",
                      "V": "rest", "l": "digits", "0": "digits", "C": "digits"},
                     frozenset(), {"i"}, {"e", "E"}),
    "ruby": _inplace({"e": "next", "I": "next", "r": "next", "C": "next", "E": "next",
                      "i": "rest", "x": "rest", "F": "rest", "K": "rest",
                      "0": "digits", "W": "digits", "T": "digits"},
                     frozenset(("--encoding", "--external-encoding", "--internal-encoding",
                                "--enable", "--disable", "--dump")),
                     {"i"}, {"e"}),
    "cp": _copy(_nexts("tS"), _CP_LONG, ("t", "--target-directory"), lambda ops: ops),
    "mv": _copy(_nexts("tS"), _CP_LONG, ("t", "--target-directory"), lambda ops: ops),
    "ln": _copy(_nexts("tS"), _CP_LONG, ("t", "--target-directory"), lambda ops: ["."]),
    "install": _copy(_nexts("tSmog"), _CP_LONG | frozenset((
        "--mode", "--owner", "--group", "--strip-program")),
        ("t", "--target-directory"), lambda ops: ops),
    "rsync": _w_rsync,
    "touch": _w_touch,
    "truncate": _w_truncate,
    "patch": _w_patch,
    "git": _w_git,
    "curl": _w_curl,
    "wget": _w_wget,
    "tar": _w_tar,
    "unzip": _w_unzip,
    "find": _w_find,
}
# Writers whose file operands `xargs` may supply on stdin: with none on the line, the
# destination is unknown, not absent.
_STDIN_OPERAND_WRITERS = frozenset(("tee", "touch", "truncate", "cp", "mv", "install",
                                    "ln", "rsync"))


def _strip_wrappers(tokens):
    """Drop env assignments, keywords, and wrappers WITH their options from the front of
    tokens (in place). Returns (via_xargs, files the wrappers themselves write), e.g.
    `time -o FILE`."""
    via_xargs, dests = False, []
    while tokens:
        t = tokens[0]
        if _ENV_ASSIGN.match(t) or t in _KEYWORDS:
            tokens.pop(0)
            continue
        name = t.rsplit("/", 1)[-1]
        spec = _WRAPPERS.get(name)
        if spec is None:
            break
        tokens.pop(0)
        via_xargs = via_xargs or name == "xargs"
        short, long_arg, positionals, outputs = spec
        while tokens and tokens[0].startswith("-") and tokens[0] != "-":
            a = tokens.pop(0)
            if a == "--":
                break
            if a.startswith("--"):
                opt, eq, val = a.partition("=")
                if not eq and opt in long_arg:
                    val = tokens.pop(0) if tokens else ""
                if opt in outputs:
                    dests.append(val or None)
                continue
            for j in range(1, len(a)):
                if a[j] in short:
                    if j == len(a) - 1:
                        val = tokens.pop(0) if tokens else ""
                    else:
                        val = a[j + 1:]
                    if a[j] in outputs:
                        dests.append(val or None)
                    break
        for _ in range(positionals):
            if tokens and not _ENV_ASSIGN.match(tokens[0]):
                tokens.pop(0)
    return via_xargs, dests


def _segment_dests(tokens):
    """Destinations written by one simple command (a token list)."""
    tokens = list(tokens)
    via_xargs, dests = _strip_wrappers(tokens)
    if not tokens:
        return dests
    cmd = tokens[0].rsplit("/", 1)[-1]
    handler = _WRITERS.get(cmd)
    if handler is None:
        return dests
    written = handler(tokens[1:])
    if not written and via_xargs and cmd in _STDIN_OPERAND_WRITERS:
        written = [None]
    return dests + written


def _substitutions(text):
    """Inner text of every outermost `$( ... )` and `` `...` `` in text, by a balanced
    paren scan (a regex cannot nest). `$((` arithmetic is stepped over, so substitutions
    INSIDE it are still found. An unclosed one yields the rest of the text: its shell
    still runs as far as bash is concerned, and over-reporting only errs toward gating."""
    subs, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("$((", i):
            i += 3
        elif text.startswith("$(", i):
            j, depth = i + 2, 1
            while j < n:
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                    if not depth:
                        break
                j += 1
            subs.append(text[i + 2:j])
            i = j + 1
        elif text[i] == "`":
            j = text.find("`", i + 1)
            if j < 0:
                j = n
            subs.append(text[i + 1:j])
            i = j + 1
        else:
            i += 1
    return subs


def _blank_test_spans(text):
    """Replace each `[[ ... ]]` / `(( ... ))` / `$(( ... ))` span (closed on its own
    line) with a placeholder. Returns (text, [command substitution inside a span, ...]).

    Linear: once an opener of one kind finds no closer, no later opener of that kind on
    the same line can close either, so the rest of the line is not rescanned for it. An
    unclosed span is left in place for the plain redirect scan (a false block at worst)."""
    out, subs, pos, n = [], [], 0, len(text)
    dead = {"[": -1, "(": -1}  # per kind: end of the line on which it cannot close
    scan = 0
    while True:
        m = _TEST_OPEN.search(text, scan)
        if not m:
            break
        start = m.start()
        kind = "[" if text[start] == "[" else "("
        if start < dead[kind]:
            scan = start + 1
            continue
        eol = text.find("\n", start)
        if eol < 0:
            eol = n
        if kind == "[":
            c = _BRACKET_CLOSE.search(text, m.end(), eol)
            end = c.end() if c else -1
        else:
            end = text.find("))", m.end(), eol)
            end = end + 2 if end >= 0 else -1
        if end < 0:
            dead[kind] = eol
            scan = start + 1
            continue
        out.append(text[pos:start])
        out.append("$__T")
        subs.extend(_substitutions(text[start:end]))
        pos = scan = end
    out.append(text[pos:])
    return "".join(out), subs


def _bash_write_dests(command):
    """Every destination a Bash command line writes. None stands for a write whose
    destination could not be determined. An empty list means no write was detected."""
    shell, bodies = _strip_heredocs(command)
    shell = _neutralize_quotes(shell)
    shell = _COMMENT.sub("", shell)
    dests = _shell_dests(shell, 0)

    # A heredoc script body that writes is exempt only if it names at least one path or
    # filename literal and every such literal is exempt. Otherwise its destination is
    # unknown: open("out.txt","w").write("/tmp/looks-safe") must not pass on the decoy.
    for body in bodies:
        if not _SCRIPT_WRITE.search(body):
            continue
        lits = [s for rx in _BODY_LITERALS for s in rx.findall(body)
                if "/" in s or _FILENAME.fullmatch(s)]
        dests.extend(lits or [None])

    return dests


def _shell_dests(shell, depth):
    """Destinations written by shell text whose heredocs, quotes and comments are
    already neutralized. Command substitutions hidden in a test span are analysed the
    same way, recursively, since blanking the span would otherwise hide them."""
    shell, subs = _blank_test_spans(shell)
    dests = []

    def take(m):
        op, target = m.group(1), m.group(2)
        if op.startswith("<") and op != "<>":
            return " "  # input, heredoc, herestring: removed so it is not an operand
        if op == ">&" and re.fullmatch(r"\d*-?", target) and target:
            return " "  # 2>&1, >&2, 1>&-: a descriptor, not a file
        if not target:
            if op == ">" and shell[m.end():m.end() + 1] == "(":
                return " "  # >(cmd) process substitution
            dests.append(None)
        else:
            dests.append(target)
        return " "

    shell = _REDIR.sub(take, shell)

    # Writers count only in COMMAND POSITION. Matching them anywhere made
    # `grep -rn cp src/` look like a copy.
    segments = _SEG_SPLIT.split(shell)
    for inner in _BACKTICK.findall(shell):
        segments.extend(_SEG_SPLIT.split(inner.replace("`", " ")))
    for seg in segments:
        dests.extend(_segment_dests(seg.split()))

    for inner in subs:
        if depth >= _SUBST_DEPTH:
            dests.append(None)
            break
        dests.extend(_shell_dests(inner, depth + 1))
    return dests


def _bash_needs_classification(command, cwd=None):
    """True when a Bash command must face the same gate as an Edit/Write."""
    if not isinstance(command, str) or not command.strip():
        return False
    # Gated if ANY destination is not provably exempt (including an unknown one).
    return any(not _exempt_dest(d, cwd) for d in _bash_write_dests(command))


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

    tool_input = payload.get("tool_input") or {}

    # --- Bash: only a file-writing command consults the classification -------
    # Reached only AFTER the subagent exemption above, so a lane's shell work is never
    # gated. A write that does need classification falls through to the SAME transcript
    # scan as Edit/Write below (its empty fpath matches no path exemption).
    if payload.get("tool_name") == "Bash":
        command = tool_input.get("command") if isinstance(tool_input, dict) else ""
        # The marker must never require classification, or recovery deadlocks.
        if isinstance(command, str) and command.strip() == MARKER_COMMAND:
            allow("bash: classification marker")
        if not _bash_needs_classification(command, payload.get("cwd")):
            allow("bash: no project-file write detected")

    # --- Path exemptions (Edit/Write/NotebookEdit only) ------------------------
    # Never for Bash: a stray file_path key in a Bash payload says nothing about where
    # the command writes, and honouring it let `echo x > src/a.py` pass as /tmp.
    fpath = ""
    if payload.get("tool_name") != "Bash" and isinstance(tool_input, dict):
        fpath = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not isinstance(fpath, str):
        fpath = ""
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
    except BaseException as exc:
        # Rule 1: fail open on ANY internal error -- SystemExit and KeyboardInterrupt
        # included. An arbitrary SystemExit code is never propagated (SystemExit(7) from
        # stdin.read() used to exit 7); only a latched deny may exit 2.
        if os.environ.get("DELEGATION_GATE_DEBUG"):
            try:
                print(f"[delegation-gate] internal error, failing open: {exc!r}",
                      file=sys.stderr)
            except BaseException:
                pass
        _exit(2 if _VERDICT == 2 else 0)
    # main() never returns -- allow()/block() both exit -- but if it ever did, the
    # latched verdict still wins over an implicit exit 0.
    _exit(2 if _VERDICT == 2 else 0)
