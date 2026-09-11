#!/usr/bin/env bash
# Behavioral test for copilot-agent-readiness/scripts/audit.sh: runs the
# script against two mktemp fixture repos (instruction files present, and
# empty) and checks its actual output strings, exit code, and that it never
# writes into the fixture it inspects.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AUDIT_SH="$ROOT/skills/copilot-agent-readiness/scripts/audit.sh"

FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=1
}

[ -f "$AUDIT_SH" ] || { echo "FAIL: $AUDIT_SH not found" >&2; exit 1; }

# --- Fixture 1: instruction files present ----------------------------------

PRESENT_DIR="$(mktemp -d)"
trap 'rm -rf "$PRESENT_DIR" "${EMPTY_DIR:-}"' EXIT

mkdir -p "$PRESENT_DIR/.github/instructions"
cat >"$PRESENT_DIR/.github/copilot-instructions.md" <<'EOF'
# Repo instructions
Trust these instructions; only search if incomplete.
Build with `make build`; test with `make test`.
EOF
cat >"$PRESENT_DIR/AGENTS.md" <<'EOF'
# Agents
Synthetic fixture AGENTS.md.
EOF
cat >"$PRESENT_DIR/.github/instructions/backend.instructions.md" <<'EOF'
---
applyTo: "src/backend/**"
---
Backend-specific fixture instructions.
EOF

find "$PRESENT_DIR" -type f | sort >"$PRESENT_DIR.before"
present_out="$(bash "$AUDIT_SH" "$PRESENT_DIR" 2>&1)"
present_rc=$?
find "$PRESENT_DIR" -type f | sort >"$PRESENT_DIR.after"

echo "== audit.sh: fixture with instruction files present =="

[ "$present_rc" -eq 0 ] || fail "audit.sh exited $present_rc on the present-files fixture"

diff -q "$PRESENT_DIR.before" "$PRESENT_DIR.after" >/dev/null 2>&1 \
  || fail "audit.sh wrote into the present-files fixture (file list changed)"

printf '%s\n' "$present_out" | grep -qE '^\s*\[x\]\s+\.github/copilot-instructions\.md' \
  || fail "present fixture: .github/copilot-instructions.md not reported present"

printf '%s\n' "$present_out" | grep -qE '^\s*\[x\]\s+AGENTS\.md' \
  || fail "present fixture: AGENTS.md not reported present"

printf '%s\n' "$present_out" | grep -qE '^\s*\[x\]\s+\.github/instructions/backend\.instructions\.md' \
  || fail "present fixture: .github/instructions/backend.instructions.md not reported"

printf '%s\n' "$present_out" | grep -qE 'applyTo: "src/backend/\*\*"' \
  || fail "present fixture: applyTo value not echoed for the path-specific instruction file"

rm -f "$PRESENT_DIR.before" "$PRESENT_DIR.after"

# --- Fixture 2: empty repo ---------------------------------------------------

EMPTY_DIR="$(mktemp -d)"

find "$EMPTY_DIR" -type f | sort >"$EMPTY_DIR.before"
empty_out="$(bash "$AUDIT_SH" "$EMPTY_DIR" 2>&1)"
empty_rc=$?
find "$EMPTY_DIR" -type f | sort >"$EMPTY_DIR.after"

echo "== audit.sh: fixture with no instruction files =="

[ "$empty_rc" -eq 0 ] || fail "audit.sh exited $empty_rc on the empty fixture"

diff -q "$EMPTY_DIR.before" "$EMPTY_DIR.after" >/dev/null 2>&1 \
  || fail "audit.sh wrote into the empty fixture (file list changed)"

printf '%s\n' "$empty_out" | grep -qE '^\s*\[ \]\s+\.github/copilot-instructions\.md\s+MISSING' \
  || fail "empty fixture: .github/copilot-instructions.md not flagged MISSING"

printf '%s\n' "$empty_out" | grep -qE '^\s*\[ \]\s+AGENTS\.md\s+MISSING' \
  || fail "empty fixture: AGENTS.md not flagged MISSING"

printf '%s\n' "$empty_out" | grep -qE '^\s*\[ \]\s+none \(Copilot-only add-on' \
  || fail "empty fixture: missing .github/instructions/ not flagged as none-found"

printf '%s\n' "$empty_out" | grep -qE '^\s*\[ \]\s+none found in \.claude/skills' \
  || fail "empty fixture: missing skills dirs not flagged as none-found"

rm -f "$EMPTY_DIR.before" "$EMPTY_DIR.after"

echo "== Result =="
if [ "$FAIL" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
exit 0
