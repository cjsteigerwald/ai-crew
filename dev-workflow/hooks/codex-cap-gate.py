#!/usr/bin/env python3
"""PreToolUse gate on Agent|Task: counts Codex review rounds in the review ledger
and prompts the user from round 4 on.

Warning accounting, not enforcement (review-policy skill, Codex cap). Only
subagent_type codex-adversary, dev-workflow:codex-adversary and
codex-crew:codex-reviewer are looked at; every other call exits 0 silently.

The brief (tool_input.prompt) must carry one line, outside ``` fences
(fenced lines are ignored; repeats of the same value are fine)
    ledger: <repo-path>[ | plan:<ticket>]
The key is derived, never chosen: branch:<name> from
`git -C <repo-path> symbolic-ref --short -q HEAD`, or plan:<ticket> when the
line names one -- allowed only on the default branch (origin/HEAD, else main or
master) or a detached HEAD. A relative <repo-path> is taken from the payload cwd.

Outcomes:
  - deny (caller's to fix), with the ledger's `show` for recovery: no ledger
    line; two different ledger lines; path missing or not a git repo; plan: on a feature branch; detached HEAD
    without plan:.
  - count below 3: record decision allow, exit 0 silently (normal permission flow).
  - count 3 or more: record decision ask, permissionDecision "ask" recommending stop.
  - internal error (corrupt ledger, failed lock, any other git failure, bad input):
    permissionDecision "ask", reason "codex-cap-gate: ledger error <detail>;
    count unknown". Only if no JSON can be written: stderr + exit 1.
No tool_use_id in the payload: gen:<session_id>:<ts>:<sha256(brief)[:12]> is
recorded with id_source generated, and the call goes on.
Off switch: CLAUDE_CODEX_CAP_GATE=off.
"""
import datetime
import hashlib
import json
import os
import re
import shlex
import sys

CODEX_AGENTS = {"codex-adversary", "dev-workflow:codex-adversary", "codex-crew:codex-reviewer"}
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEDGER_CLI = os.path.join(PLUGIN_ROOT, "scripts", "review-ledger.sh")
RE_LEDGER = re.compile(r"^[ \t]*ledger:[ \t]*(.*?)[ \t]*$")
RE_FENCE = re.compile(r"^[ \t]*(```|~~~)")
RE_PLAN = re.compile(r"^plan:(\S+)$")
LEDGER_FORMAT = "`ledger: <repo-path>` (or `ledger: <repo-path> | plan:<ticket>` on the default branch or a detached HEAD)"


def emit(decision, reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": decision,
        "permissionDecisionReason": reason,
    }}))


def ledger_error(detail):
    emit("ask", f"codex-cap-gate: ledger error {detail}; count unknown")


def load_ledger():
    sys.dont_write_bytecode = True         # no __pycache__ in the plugin tree
    sys.path.insert(0, os.path.join(PLUGIN_ROOT, "scripts"))
    import review_ledger                   # noqa: E402  (sibling script, stdlib only)
    return review_ledger


def branch_of(rl, repo):
    """Checked-out branch at <repo>, or '' on a detached HEAD."""
    rc, out = rl.git(repo, "symbolic-ref", "--short", "-q", "HEAD")
    if rc == 0:
        return out
    if rc == 1:
        return ""
    raise rl.LedgerError(f"git symbolic-ref HEAD failed in {repo} (exit {rc})")


def is_default(rl, repo, branch):
    rc, out = rl.git(repo, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD")
    if rc == 0 and out.startswith("origin/"):
        return branch == out[len("origin/"):]
    return branch in ("main", "master")


def show_for(rl, repo, key):
    """`review-ledger.sh show` for the recovery message; never raises."""
    try:
        if repo is None or rl.common_dir(repo) is None:
            return "(no git repository to show a ledger for)"
        return rl.show(rl.ledger_dir(repo), key or None)
    except Exception as exc:
        return f"(could not read the ledger: {exc})"


def deny(rl, problem, repo, key):
    cmd = f"{LEDGER_CLI} -C {shlex.quote(repo)} show{' ' + shlex.quote(key) if key else ''}" if repo else f"{LEDGER_CLI} show"
    emit("deny", f"codex-cap-gate: {problem}. Put {LEDGER_FORMAT} on its own line in the brief and "
                 f"dispatch again; reuse the key below rather than inventing a new one.\n"
                 f"$ {cmd}\n{show_for(rl, repo, key)}")


def ledger_values(brief):
    """Distinct non-empty `ledger:` values outside ``` / ~~~ fenced blocks, in
    order of appearance. A quoted example inside a fence never charges a key."""
    values, fence = [], None
    for line in brief.splitlines():
        f = RE_FENCE.match(line)
        if f:
            if fence is None:
                fence = f.group(1)
            elif f.group(1) == fence:
                fence = None
            continue
        if fence is not None:
            continue
        m = RE_LEDGER.match(line)
        if m and m.group(1) and m.group(1) not in values:
            values.append(m.group(1))
    return values


def cwd_key(rl, cwd):
    """Best-effort key for the session cwd, for recovery messages only."""
    try:
        if rl.common_dir(cwd) is None:
            return None, None
        branch = branch_of(rl, cwd)
        return cwd, (f"branch:{branch}" if branch else None)
    except Exception:
        return None, None


def main():
    if os.environ.get("CLAUDE_CODEX_CAP_GATE", "").lower() == "off":
        return 0
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        if not isinstance(payload, dict):
            raise ValueError("not an object")
    except ValueError as exc:
        ledger_error(f"unreadable hook input ({exc})")
        return 0
    if payload.get("tool_name") not in ("Agent", "Task"):
        return 0
    ti = payload.get("tool_input")
    if ti is None:
        ti = {}
    if not isinstance(ti, dict):
        ledger_error(f"malformed hook input (tool_input is {type(ti).__name__}, not an object)")
        return 0
    agent = str(ti.get("subagent_type") or "").strip()
    if agent not in CODEX_AGENTS:
        return 0

    try:
        rl = load_ledger()
    except Exception as exc:
        ledger_error(f"cannot load review_ledger.py ({exc})")
        return 0

    try:
        brief = str(ti.get("prompt") or "")
        cwd = str(payload.get("cwd") or os.getcwd())
        values = ledger_values(brief)
        if not values:
            repo, key = cwd_key(rl, cwd)
            deny(rl, "the brief has no `ledger:` line outside code fences", repo, key)
            return 0
        if len(values) > 1:
            repo, key = cwd_key(rl, cwd)
            listed = "; ".join(f"`ledger: {v}`" for v in values)
            deny(rl, f"the brief has {len(values)} different `ledger:` lines outside code fences "
                     f"({listed}); keep exactly one, and put any example inside a ``` fence", repo, key)
            return 0
        spec, plan = values[0], None
        if "|" in spec:
            left, right = spec.rsplit("|", 1)
            pm = RE_PLAN.match(right.strip())
            if pm:
                spec, plan = left.strip(), pm.group(1)
        if spec.startswith("`") and spec.endswith("`") and len(spec) > 1:
            spec = spec[1:-1]
        repo = os.path.join(cwd, os.path.expanduser(spec))   # an absolute spec wins
        if rl.common_dir(repo) is None:
            c_repo, c_key = cwd_key(rl, cwd)
            deny(rl, f"`ledger:` path {repo!r} is not inside a git repository", c_repo, c_key)
            return 0
        branch = branch_of(rl, repo)
        if plan is not None:
            if branch and not is_default(rl, repo, branch):
                deny(rl, f"`plan:{plan}` is only for the default branch or a detached HEAD, but "
                         f"{repo!r} has feature branch {branch!r} checked out: drop `| plan:{plan}` "
                         f"so the round counts under branch:{branch}", repo, f"branch:{branch}")
                return 0
            key = f"plan:{plan}"
        elif branch:
            key = f"branch:{branch}"
        else:
            deny(rl, f"{repo!r} is on a detached HEAD, so there is no branch key: add "
                     f"`| plan:<ticket>`", repo, None)
            return 0

        tool_use_id, id_source = payload.get("tool_use_id"), "payload"
        if not isinstance(tool_use_id, str) or not tool_use_id:
            ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
            session = str(payload.get("session_id") or "nosession")
            digest = hashlib.sha256(brief.encode("utf-8")).hexdigest()[:12]
            tool_use_id, id_source = f"gen:{session}:{ts}:{digest}", "generated"

        decision, n = rl.record(rl.ledger_dir(repo), key, tool_use_id, id_source, agent)
    except Exception as exc:            # LedgerError, git failure, anything unforeseen
        ledger_error(str(exc) or type(exc).__name__)
        return 0

    if decision == "allow":
        return 0
    emit("ask", f"codex-cap-gate: the Codex cap is reached: this is round {n} for {key} "
                f"(cap {rl.CAP}, counted across sessions in this clone's review ledger). "
                f"Recommended: stop -- run a bounded fresh-verifier on the remaining fix, or hand "
                f"to human review if it is not bounded-eligible. Approve only for a named trigger. "
                f"If you decline, run: {LEDGER_CLI} -C {shlex.quote(repo)} void {shlex.quote(tool_use_id)} 'declined at cap'")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:               # emit() itself failed: no JSON possible
        sys.stderr.write(f"codex-cap-gate: ledger error {exc}; count unknown\n")
        sys.exit(1)
