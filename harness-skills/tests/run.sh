#!/usr/bin/env bash
# Test runner for the harness-skills plugin. Never touches the real
# ~/.claude.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
SCRUB="$(dirname "$0")/../../scripts/scrub-check.sh"
SCRUB_ALLOW="$(dirname "$0")/../../scripts/scrub-allow.txt"

FAILED=0

echo "== scrub-check on plugin dir =="
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

echo "== crew-configure tests =="
if bash "$HERE/test-crew-configure.sh" >/tmp/harness-skills-cctest.$$ 2>&1; then
  cat /tmp/harness-skills-cctest.$$
  echo "PASS: crew-configure tests"
else
  cat /tmp/harness-skills-cctest.$$
  echo "FAIL: crew-configure tests"
  FAILED=1
fi
rm -f /tmp/harness-skills-cctest.$$

echo "== vendored lib tests =="
if bash "$HERE/../../lib/tests/test-crew-config.sh" >/tmp/harness-skills-libtest.$$ 2>&1; then
  cat /tmp/harness-skills-libtest.$$
  echo "PASS: lib tests (canonical)"
else
  cat /tmp/harness-skills-libtest.$$
  echo "FAIL: lib tests (canonical)"
  FAILED=1
fi
rm -f /tmp/harness-skills-libtest.$$

# Also run the same fixture suite against THIS plugin's vendored copy, by
# temporarily pointing the test's LIB resolution at it via a thin wrapper —
# the fixture suite hardcodes ../crew-config.sh relative to itself, so copy
# it next to the vendored file to reuse it verbatim.
VENDOR_TEST_DIR="$(mktemp -d)"
cp "$HERE/../lib/crew-config.sh" "$VENDOR_TEST_DIR/crew-config.sh"
mkdir -p "$VENDOR_TEST_DIR/tests"
cp "$HERE/../../lib/tests/test-crew-config.sh" "$VENDOR_TEST_DIR/tests/test-crew-config.sh"
if bash "$VENDOR_TEST_DIR/tests/test-crew-config.sh" >/tmp/harness-skills-vendortest.$$ 2>&1; then
  cat /tmp/harness-skills-vendortest.$$
  echo "PASS: lib tests (vendored copy)"
else
  cat /tmp/harness-skills-vendortest.$$
  echo "FAIL: lib tests (vendored copy)"
  FAILED=1
fi
rm -f /tmp/harness-skills-vendortest.$$
rm -rf "$VENDOR_TEST_DIR"

echo "== ai-crew-update tests =="
if bash "$PLUGIN_DIR/skills/ai-crew-update/test-ai-crew.sh" >/tmp/harness-skills-crewtest.$$ 2>&1; then
  cat /tmp/harness-skills-crewtest.$$
  echo "PASS: ai-crew-update tests"
else
  cat /tmp/harness-skills-crewtest.$$
  echo "FAIL: ai-crew-update tests"
  FAILED=1
fi
rm -f /tmp/harness-skills-crewtest.$$

echo "== SKILL.md frontmatter lint =="
for f in "$PLUGIN_DIR"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  first_line="$(sed -n '1p' "$f")"
  if [ "$first_line" != "---" ]; then
    echo "FAIL: $f does not start with a --- frontmatter block"
    FAILED=1
    continue
  fi
  fm="$(awk '/^---$/{c++; next} c==1{print}' "$f")"
  if echo "$fm" | grep -q '^name:'; then
    :
  else
    echo "FAIL: $f frontmatter missing name:"
    FAILED=1
  fi
  if echo "$fm" | grep -q '^description:'; then
    :
  else
    echo "FAIL: $f frontmatter missing description:"
    FAILED=1
  fi
done
echo "PASS: frontmatter lint complete"

if [ "$FAILED" -ne 0 ]; then
  echo "harness-skills tests: FAILED"
  exit 1
fi
echo "harness-skills tests: PASSED"
exit 0
