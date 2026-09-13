#!/usr/bin/env bash
# Test runner for the tech-research plugin. Bash 3.2 compatible. Never
# touches the real ~/.claude or ~/Research.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"

FAILED=0

echo "== frontmatter lint (SKILL.md + agents/*.md) =="
lint_frontmatter() {
  f="$1"
  need_model="$2"
  [ -f "$f" ] || { echo "FAIL: $f does not exist"; FAILED=1; return; }
  first_line="$(sed -n '1p' "$f")"
  if [ "$first_line" != "---" ]; then
    echo "FAIL: $f does not start with a --- frontmatter block"
    FAILED=1
    return
  fi
  fm="$(awk '/^---$/{c++; next} c==1{print}' "$f")"
  if ! echo "$fm" | grep -q '^name:'; then
    echo "FAIL: $f frontmatter missing name:"
    FAILED=1
  fi
  if ! echo "$fm" | grep -q '^description:'; then
    echo "FAIL: $f frontmatter missing description:"
    FAILED=1
  fi
  if [ "$need_model" = "1" ] && ! echo "$fm" | grep -q '^model:'; then
    echo "FAIL: $f frontmatter missing model:"
    FAILED=1
  fi
}

lint_frontmatter "$PLUGIN_DIR/skills/tech-research/SKILL.md" 0
for f in "$PLUGIN_DIR"/agents/*.md; do
  [ -f "$f" ] || continue
  lint_frontmatter "$f" 1
done
echo "frontmatter lint complete"

echo "== bash -n on lib =="
# Syntax-check with the interpreter THIS suite is running under, not whatever
# `bash` happens to be first on PATH. On the macOS CI job the suite is started
# as /bin/bash (3.2) while PATH may lead to a Homebrew bash 5 — using plain
# `bash` there would silently syntax-check the library under 5.x and never
# exercise 3.2, which is the only shell version this lib promises to support.
BASH_BIN="${BASH:-bash}"
for f in "$PLUGIN_DIR"/lib/*.sh; do
  [ -f "$f" ] || continue
  if "$BASH_BIN" -n "$f"; then
    echo "PASS: bash -n $f"
  else
    echo "FAIL: bash -n $f"
    FAILED=1
  fi
done

echo "== vendored-lib identity check =="
VENDOR_CHECK="$PLUGIN_DIR/../scripts/check-vendored-libs.sh"
if [ -f "$VENDOR_CHECK" ]; then
  if bash "$VENDOR_CHECK"; then
    echo "PASS: vendored libs match canonical"
  else
    echo "FAIL: vendored libs drifted from canonical"
    FAILED=1
  fi
else
  echo "check-vendored-libs.sh: not present, skipped"
fi

echo "== scrub-check =="
SCRUB="$(dirname "$0")/../../scripts/scrub-check.sh"
SCRUB_ALLOW="$(dirname "$0")/../../scripts/scrub-allow.txt"
if [ -f "$SCRUB" ]; then
  if [ -f "$SCRUB_ALLOW" ]; then
    bash "$SCRUB" --allow "$SCRUB_ALLOW" "$PLUGIN_DIR"
  else
    bash "$SCRUB" "$PLUGIN_DIR"
  fi
  scrub_rc=$?
  if [ "$scrub_rc" -eq 0 ]; then
    echo "PASS: scrub-check clean"
  elif [ "$scrub_rc" -eq 4 ]; then
    echo "WARN: scrub-check found only dangling-link warnings (exit 4) — not a failure"
  else
    echo "FAIL: scrub-check found hits (exit $scrub_rc)"
    FAILED=1
  fi
else
  echo "scrub-check.sh: not present, skipped"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "tech-research tests: FAILED"
  exit 1
fi
echo "tech-research tests: PASSED"
exit 0
