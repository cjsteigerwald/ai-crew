#!/usr/bin/env python3
"""review_ledger.py — the Codex round ledger behind review-ledger.sh and codex-cap-gate.py.

Warning accounting, not enforcement: it counts every Codex dispatch the hook lets
through, per key, across sessions, so round 4+ prompts the user. See
review-ledger.sh for the CLI and the on-disk format. Stdlib only.

Library entry points (used by hooks/codex-cap-gate.py):
  ledger_dir(repo)                    <git-common-dir>/review-ledger, created on demand
  record(dir, key, tool_use_id, id_source, agent, cap=3, origin=None)
                                      -> (decision, count_after); read, decide and
                                         write under one lock
  count(dir, key), show(dir, key=None), link(...), void(...), reset(...)
Every failure the caller cannot fix raises LedgerError (corrupt file, lock, git);
a bad argument raises UsageError.
"""
import datetime
import errno
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

VERSION = 1
CAP = 3
DIR_NAME = "review-ledger"
LOCK_NAME = ".lock"
KEY_RE = re.compile(r"^(branch|plan):[^\x00-\x1f\x7f]+$")
ID_SOURCES = ("payload", "generated")
DECISIONS = ("allow", "ask")
ROW_FIELDS = ("key", "generation", "tool_use_id", "id_source", "agent", "ts", "origin", "decision")


class LedgerError(Exception):
    """The ledger could not be read or written (corrupt file, lock, git)."""


class UsageError(Exception):
    """A bad argument: the caller's to fix."""


def now_ts():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git_env():
    """The caller's GIT_DIR / GIT_WORK_TREE would override -C; drop them. Force
    the C locale so git's "not a git repository" message is matchable."""
    env = dict(os.environ)
    for var in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "LANGUAGE"):
        env.pop(var, None)
    env["LC_ALL"] = "C"
    return env


def git_full(repo, *args):
    """Run git -C <repo> <args>; returns (rc, stdout, stderr), both stripped.
    Raises LedgerError when git itself cannot run."""
    try:
        proc = subprocess.run(["git", "-C", repo] + list(args), capture_output=True,
                              text=True, timeout=10, env=git_env())
    except (OSError, subprocess.SubprocessError) as exc:
        raise LedgerError(f"cannot run git: {exc}")
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def git(repo, *args):
    """git_full without stderr: (rc, stdout stripped)."""
    rc, out, _ = git_full(repo, *args)
    return rc, out


def common_dir(repo):
    """Absolute git-common-dir of the checkout at <repo>, or None if <repo> does
    not exist or git says it is not a git repository. Any other git failure
    (unreadable metadata, dubious ownership, git missing) is a LedgerError: not
    the caller's to fix by changing the path."""
    if not os.path.isdir(repo):
        return None
    rc, out, err = git_full(repo, "rev-parse", "--git-common-dir")
    if rc != 0:
        if "not a git repository" in err.lower():
            return None
        raise LedgerError(f"git rev-parse failed in {repo} (exit {rc}): {err or 'no message'}")
    if not out:
        raise LedgerError(f"git rev-parse printed no git-common-dir in {repo}")
    return os.path.abspath(os.path.join(repo, out))   # out may be relative to <repo>


def ledger_dir(repo):
    cdir = common_dir(repo)
    if cdir is None:
        raise UsageError(f"not a git repository: {repo}")
    return os.path.join(cdir, DIR_NAME)


def encode_key(key):
    """Every UTF-8 byte outside A-Za-z0-9-_.~ becomes %XX ('%' included), as in
    piece-track.sh: injective, so branch:a/b and branch:a%2Fb never collide."""
    safe = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
    return "".join(chr(b) if b in safe else f"%{b:02X}" for b in key.encode("utf-8"))


def check_key(key):
    if not isinstance(key, str) or not KEY_RE.match(key) or key.endswith(":"):
        raise UsageError(f"bad key {key!r}: expected branch:<name> or plan:<ticket>")
    return key


def key_path(ldir, key):
    return os.path.join(ldir, encode_key(key) + ".json")


# ---------------------------------------------------------------- file I/O

def _validate(data, path, key=None):
    def bad(why):
        raise LedgerError(f"corrupt {path}: {why}")
    if not isinstance(data, dict) or data.get("version") != VERSION:
        bad("not a version-1 ledger object")
    if not isinstance(data.get("key"), str) or (key is not None and data["key"] != key):
        bad(f"key field {data.get('key')!r} does not match the file name")
    gen = data.get("generation")
    if not isinstance(gen, int) or isinstance(gen, bool) or gen < 1:
        bad("generation is not an integer >= 1")
    rows, events = data.get("rows"), data.get("events")
    if not isinstance(rows, list) or not isinstance(events, list):
        bad("rows or events is not a list")
    for row in rows:
        if not isinstance(row, dict) or any(f not in row for f in ROW_FIELDS):
            bad(f"row missing a field: {row!r}")
        if not isinstance(row["generation"], int) or not isinstance(row["tool_use_id"], str):
            bad(f"row has a bad generation or tool_use_id: {row!r}")
    for ev in events:
        if not isinstance(ev, dict) or not isinstance(ev.get("type"), str):
            bad(f"bad event: {ev!r}")
    return data


def load(ldir, key):
    """The ledger object for <key>; a fresh generation-1 object if it has no file."""
    path = key_path(ldir, key)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except FileNotFoundError:
        return {"version": VERSION, "key": key, "generation": 1, "rows": [], "events": []}
    except OSError as exc:
        raise LedgerError(f"cannot read {path}: {exc}")
    try:
        data = json.loads(raw)
    except ValueError as exc:
        raise LedgerError(f"corrupt {path}: {exc}")
    return _validate(data, path, key)


def all_keys(ldir):
    """Every key with a file, read from inside the files (names are only encodings)."""
    try:
        # Key files never start with '.' (a key starts with branch: or plan:);
        # skipping dotfiles skips .lock and in-flight or orphaned .tmp-* files.
        names = sorted(n for n in os.listdir(ldir) if n.endswith(".json") and not n.startswith("."))
    except FileNotFoundError:
        return []
    except OSError as exc:
        raise LedgerError(f"cannot list {ldir}: {exc}")
    keys = []
    for name in names:
        path = os.path.join(ldir, name)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = _validate(json.load(fh), path)
        except ValueError as exc:
            raise LedgerError(f"corrupt {path}: {exc}")
        except OSError as exc:
            raise LedgerError(f"cannot read {path}: {exc}")
        if encode_key(data["key"]) + ".json" != name:
            raise LedgerError(f"corrupt {path}: key field {data['key']!r} does not match the file name")
        keys.append(data["key"])
    return keys


def save(ldir, data):
    """Write-then-rename, so lock-free readers never see a partial file."""
    path = key_path(ldir, data["key"])
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=ldir, prefix=".tmp-", suffix=".partial")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=1, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    except OSError as exc:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        raise LedgerError(f"cannot write {path}: {exc}")


class Lock:
    """flock(2) on <ledger-dir>/.lock (persistent, never deleted), held across read,
    decide and write. One lock per ledger, not per key: link and void span keys.
    A busy lock is retried every 0.1 s for REVIEW_LEDGER_LOCK_TIMEOUT seconds
    (default 10); then LedgerError."""

    def __init__(self, ldir):
        self.ldir = ldir
        self.fd = None

    def __enter__(self):
        path = os.path.join(self.ldir, LOCK_NAME)
        try:
            os.makedirs(self.ldir, exist_ok=True)
            self.fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
        except OSError as exc:
            raise LedgerError(f"cannot open lock {path}: {exc}")
        try:
            timeout = float(os.environ.get("REVIEW_LEDGER_LOCK_TIMEOUT", "10"))
        except ValueError:
            timeout = 10.0
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                    os.close(self.fd)
                    raise LedgerError(f"cannot lock {path}: {exc}")
                if time.monotonic() >= deadline:
                    os.close(self.fd)
                    raise LedgerError(f"lock busy: {path} (waited {timeout:g} s)")
                time.sleep(0.1)
        return self

    def __exit__(self, *exc):
        os.close(self.fd)       # closing the fd releases the flock
        return False


# ---------------------------------------------------------------- commands

def current(data):
    return [r for r in data["rows"] if r["generation"] == data["generation"]]


def count(ldir, key):
    return len(current(load(ldir, check_key(key))))


def record(ldir, key, tool_use_id, id_source, agent, cap=CAP, origin=None):
    """Count one dispatch: decision is allow below <cap>, ask at or above it,
    decided and written under the lock. An id already in the key's current
    generation is not counted twice: its recorded decision is returned."""
    check_key(key)
    if not tool_use_id or not isinstance(tool_use_id, str):
        raise UsageError("record needs a tool_use_id")
    if id_source not in ID_SOURCES:
        raise UsageError(f"id_source must be one of {', '.join(ID_SOURCES)}")
    with Lock(ldir):
        data = load(ldir, key)
        rows = current(data)
        for row in rows:
            if row["tool_use_id"] == tool_use_id:
                return row["decision"], len(rows)
        decision = "allow" if len(rows) < cap else "ask"
        # Tests only: widen the window between the read above and the write
        # below, so a missing lock shows up as a lost update.
        delay = os.environ.get("REVIEW_LEDGER_TEST_DELAY")
        if delay:
            time.sleep(float(delay))
        data["rows"].append({
            "key": key, "generation": data["generation"], "tool_use_id": tool_use_id,
            "id_source": id_source, "agent": agent or "", "ts": now_ts(),
            "origin": origin or key, "decision": decision,
        })
        save(ldir, data)
        return decision, len(rows) + 1


def link(ldir, to_key, from_key):
    """Snapshot from_key's current-generation rows into to_key's current generation,
    skipping ids already there. Copies keep their origin. Returns (added, skipped)."""
    check_key(to_key)
    check_key(from_key)
    if to_key == from_key:
        raise UsageError("link: to-key and from-key are the same")
    with Lock(ldir):
        src, dst = load(ldir, from_key), load(ldir, to_key)
        have = {r["tool_use_id"] for r in current(dst)}
        added = skipped = 0
        for row in current(src):
            if row["tool_use_id"] in have:
                skipped += 1
                continue
            copy = dict(row)
            copy["key"], copy["generation"] = to_key, dst["generation"]
            dst["rows"].append(copy)
            have.add(row["tool_use_id"])
            added += 1
        dst["events"].append({"type": "link", "ts": now_ts(), "from": from_key,
                              "generation": dst["generation"], "added": added, "skipped": skipped})
        save(ldir, dst)
        return added, skipped


def void(ldir, tool_use_id, reason):
    """Remove every row with <tool_use_id>, in every key and generation, linked
    copies included. Each affected key records the void and the removed rows.
    Returns {key: removed}; raises UsageError if no row has that id."""
    if not tool_use_id:
        raise UsageError("void needs a tool_use_id")
    if not reason or not reason.strip():
        raise UsageError("void needs a reason")
    with Lock(ldir):
        changed = {}
        datas = [load(ldir, k) for k in all_keys(ldir)]   # validate all before writing any
        for data in datas:
            gone = [r for r in data["rows"] if r["tool_use_id"] == tool_use_id]
            if not gone:
                continue
            data["rows"] = [r for r in data["rows"] if r["tool_use_id"] != tool_use_id]
            data["events"].append({"type": "void", "ts": now_ts(), "tool_use_id": tool_use_id,
                                   "reason": reason, "removed": gone})
            changed[data["key"]] = (data, len(gone))
        if not changed:
            raise UsageError(f"void: no row has tool_use_id {tool_use_id!r}")
        for data, _ in changed.values():
            save(ldir, data)
        return {k: n for k, (_, n) in changed.items()}


def reset(ldir, key, reason):
    """Start a new generation for <key> (count 0); the reset is recorded."""
    check_key(key)
    if not reason or not reason.strip():
        raise UsageError("reset needs a reason")
    with Lock(ldir):
        data = load(ldir, key)
        old = data["generation"]
        data["generation"] = old + 1
        data["events"].append({"type": "reset", "ts": now_ts(), "from": old,
                               "to": old + 1, "reason": reason})
        save(ldir, data)
        return old + 1


def show(ldir, key=None):
    """Human-readable state of one key, or one summary line per key."""
    if key is None:
        lines = []
        for k in all_keys(ldir):
            data = load(ldir, k)
            lines.append(f"{k}  generation {data['generation']}  count {len(current(data))}")
        return "\n".join(lines) if lines else "(ledger empty)"
    data = load(ldir, check_key(key))
    rows = current(data)
    out = [f"key: {key}", f"generation: {data['generation']}  count: {len(rows)}  cap: {CAP}"]
    out.append("rows (current generation):" if rows else "rows (current generation): none")
    for r in rows:
        origin = "" if r["origin"] == key else f"  origin={r['origin']}"
        out.append(f"  {r['ts']}  {r['decision']:<5}  {r['agent']}  {r['tool_use_id']} ({r['id_source']}){origin}")
    if data["events"]:
        out.append("history:")
    for ev in data["events"]:
        t = ev["type"]
        if t == "reset":
            out.append(f"  {ev.get('ts')}  reset generation {ev.get('from')} -> {ev.get('to')}: {ev.get('reason')}")
        elif t == "void":
            out.append(f"  {ev.get('ts')}  void {ev.get('tool_use_id')} ({len(ev.get('removed') or [])} row(s)): {ev.get('reason')}")
        elif t == "link":
            out.append(f"  {ev.get('ts')}  link from {ev.get('from')}: +{ev.get('added')} ({ev.get('skipped')} already present)")
        else:
            out.append(f"  {ev.get('ts')}  {t}")
    return "\n".join(out)


def generated_id(prefix, text):
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    return f"gen:{prefix}:{ts}:{hashlib.sha256(text.encode('utf-8')).hexdigest()[:12]}"


# ---------------------------------------------------------------- CLI

USAGE = """usage: review-ledger.sh [-C <repo-path>] <command> ...
  record <key> <agent> [--id <tool_use_id>] [--id-source payload|generated] [--cap <n>]
  link <to-key> <from-key>
  void <tool_use_id> <reason>
  reset <key> <reason>
  count <key>
  show [<key>]
<key> is branch:<name> or plan:<ticket>."""


def cli(argv):
    repo = os.getcwd()
    if len(argv) >= 2 and argv[0] == "-C":
        repo, argv = argv[1], argv[2:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE, file=sys.stderr if not argv else sys.stdout)
        return 1 if not argv else 0
    cmd, args = argv[0], argv[1:]

    def need(n_min, n_max=None):
        if len(args) < n_min or (n_max is not None and len(args) > n_max):
            raise UsageError(f"{cmd}: wrong number of arguments\n{USAGE}")

    ldir = ledger_dir(repo)
    if cmd == "record":
        need(2)
        key, agent, rest = args[0], args[1], args[2:]
        tid, src, cap = None, None, CAP
        while rest:
            if len(rest) < 2 or rest[0] not in ("--id", "--id-source", "--cap"):
                raise UsageError(f"record: bad option {rest[0]!r}\n{USAGE}")
            opt, val, rest = rest[0], rest[1], rest[2:]
            if opt == "--id":
                tid = val
            elif opt == "--id-source":
                src = val
            else:
                try:
                    cap = int(val)
                except ValueError:
                    raise UsageError(f"record: --cap needs an integer, got {val!r}")
        if tid is None:
            tid, src = generated_id("cli", f"{key}\n{agent}\n{time.time_ns()}"), src or "generated"
        decision, n = record(ldir, key, tid, src or "payload", agent, cap=cap)
        print(f"{decision} {n} {tid}")
    elif cmd == "link":
        need(2, 2)
        added, skipped = link(ldir, args[0], args[1])
        print(f"linked {added} row(s) from {args[1]} into {args[0]} ({skipped} already present); "
              f"count {count(ldir, args[0])}")
    elif cmd == "void":
        need(2, 2)
        for k, n in sorted(void(ldir, args[0], args[1]).items()):
            print(f"voided {n} row(s) in {k}")
    elif cmd == "reset":
        need(2, 2)
        print(f"{args[0]}: generation {reset(ldir, args[0], args[1])}, count 0")
    elif cmd == "count":
        need(1, 1)
        print(count(ldir, args[0]))
    elif cmd == "show":
        need(0, 1)
        print(show(ldir, args[0] if args else None))
    else:
        raise UsageError(f"unknown command {cmd!r}\n{USAGE}")
    return 0


def main():
    try:
        return cli(sys.argv[1:])
    except UsageError as exc:
        print(f"review-ledger: {exc}", file=sys.stderr)
        return 1
    except LedgerError as exc:
        print(f"review-ledger: ledger error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
