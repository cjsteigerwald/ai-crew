#!/usr/bin/env bash
# Runs every crew-gates test, plus the repo-wide scrub-check on this plugin's own
# directory. Exits non-zero if any suite fails.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0

for t in test-delegation-gate.sh test-read-budget-gate.sh test-config-lanes.sh; do
  echo "== $t =="
  bash "$HERE/$t"
  rc=$?
  [ "$rc" = 0 ] || fail=1
  echo
done

echo "== hooks.json =="
if python3 - "$HERE/../hooks/hooks.json" "$HERE/.." <<'PY'
import json, sys
hooks_path, plugin_root = sys.argv[1], sys.argv[2]
import os
data = json.load(open(hooks_path))
cmds = []
for event in data.get("hooks", {}).values():
    for entry in event:
        for h in entry.get("hooks", []):
            cmds.append(h.get("command", ""))
ok = len(cmds) == 4
for c in cmds:
    if "${CLAUDE_PLUGIN_ROOT}/hooks/" not in c:
        ok = False
        print(f"FAIL: command missing plugin-root path: {c}")
    else:
        rel = c.split("${CLAUDE_PLUGIN_ROOT}/hooks/", 1)[1].rstrip('"')
        script = os.path.join(plugin_root, "hooks", rel)
        if not os.path.isfile(script):
            ok = False
            print(f"FAIL: referenced file does not exist: {script}")
sys.exit(0 if ok else 1)
PY
then
  echo "  PASS  hooks.json valid, all 4 commands reference existing files"
else
  echo "  FAIL  hooks.json"
  fail=1
fi
echo

echo "== bash 3.2 portability =="
# The macOS CI job runs these suites under /bin/bash, which is bash 3.2. Bash 3.2 leaks
# the enclosing double-quote state into a $(...) body, so a nested "..." argument's own
# quotes CANCEL the outer quoting: the braces and commas inside it become UNQUOTED and
# the whole word is brace-expanded into several words, silently corrupting the payload
# (and, when a surplus word reaches a command, turning it into `env: {...}: not found`).
# Bash 4+ parses the same line correctly, so this can only be caught statically here.
if python3 - "$HERE"/*.sh <<'PORT'
import sys
bad = []
for path in sys.argv[1:]:
    with open(path, "r", errors="ignore") as fh:
        for ln, line in enumerate(fh, 1):
            if line.lstrip().startswith("#"):   # prose may quote the anti-pattern
                continue
            dq = sq = False; depth = 0; inside = brace = False; i = 0
            while i < len(line):
                c = line[i]
                if sq:
                    if c == "'": sq = False
                    i += 1; continue
                if c == "\\":
                    i += 2; continue
                if c == "'":
                    if not dq: sq = True     # inside "..." a quote is a literal
                    i += 1; continue
                if c == '"':
                    dq = not dq; i += 1; continue
                if c == "$" and line[i+1:i+2] == "(":
                    if depth == 0 and dq: inside, brace = True, False
                    depth += 1; i += 2; continue
                if c == ")" and depth:
                    depth -= 1
                    if depth == 0: inside = False
                    i += 1; continue
                if inside and not dq:
                    if c == "{": brace = True
                    # a brace expansion needs an unquoted ',' (list) or '..' (sequence)
                    elif brace and (c == "," or line[i:i+2] == ".."):
                        bad.append((path, ln, line.rstrip())); brace = False
                i += 1
for path, ln, txt in bad:
    print("FAIL: %s:%d: a $(...) inside double quotes exposes an unquoted '{ , }';" % (path, ln))
    print("      bash 3.2 brace-expands it. Build the payload in a helper function or a")
    print("      variable OUTSIDE double quotes: %s" % txt[:90])
sys.exit(1 if bad else 0)
PORT
then
  echo "  PASS  no bash-3.2 brace-expansion hazards in the test scripts"
else
  echo "  FAIL  bash-3.2 brace-expansion hazard"
  fail=1
fi
echo

SCRUB="$HERE/../../scripts/scrub-check.sh"
if [ -x "$SCRUB" ] || [ -f "$SCRUB" ]; then
  echo "== scrub-check =="
  bash "$SCRUB" "$HERE/.."
  rc=$?
  [ "$rc" = 0 ] || fail=1
else
  echo "scrub-check: not present, skipped"
fi

exit "$fail"
