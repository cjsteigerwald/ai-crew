#!/usr/bin/env bash
# claude-crew plugin tests: every agents/*.md must be write-capable to the
# orchestrator (SendMessage) but never web-capable, and must carry the
# worker->orchestrator NEEDS_LOOKUP lookup rule addressed to `main`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

pass=0
fail=0

pass_() { echo "  PASS  $1"; pass=$((pass + 1)); }
fail_() { echo "  FAIL  $1"; fail=$((fail + 1)); }

# extract_frontmatter <file> — prints the YAML frontmatter block (between the
# first two '---' lines) to stdout.
extract_frontmatter() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm { print }
  ' "$1"
}

echo "== agents/*.md carry the NEEDS_LOOKUP lookup rule =="

AGENT_FILES=("$ROOT"/agents/*.md)
if [ ! -e "${AGENT_FILES[0]}" ]; then
  fail_ "no agents/*.md files found in $ROOT/agents"
else
  for f in "${AGENT_FILES[@]}"; do
    name="$(basename "$f")"
    fm="$(extract_frontmatter "$f")"
    tools_line="$(echo "$fm" | grep -E '^tools:' || true)"

    if echo "$tools_line" | grep -q 'SendMessage'; then
      pass_ "$name: tools: includes SendMessage"
    else
      fail_ "$name: tools: missing SendMessage ($tools_line)"
    fi

    if echo "$tools_line" | grep -qE 'WebFetch|WebSearch'; then
      fail_ "$name: tools: must not include WebFetch/WebSearch ($tools_line)"
    else
      pass_ "$name: tools: no WebFetch/WebSearch"
    fi

    if grep -q 'NEEDS_LOOKUP:' "$f"; then
      pass_ "$name: body contains NEEDS_LOOKUP:"
    else
      fail_ "$name: body missing NEEDS_LOOKUP:"
    fi

    if grep -q 'addressed to `main`' "$f"; then
      pass_ "$name: body contains \"addressed to \`main\`\""
    else
      fail_ "$name: body missing \"addressed to \`main\`\""
    fi
  done
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
