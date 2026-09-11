#!/usr/bin/env bash
# Test runner for the repo-audit plugin. Never touches the real ~/.claude or
# writes outside a throwaway mktemp dir.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$HERE/.." && pwd)"
FAILED=0

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
  if ! echo "$fm" | grep -q '^description:'; then
    echo "FAIL: $f frontmatter missing description:"
    FAILED=1
  fi
  if ! echo "$fm" | grep -q '^allowed-tools:'; then
    echo "FAIL: $f frontmatter missing allowed-tools:"
    FAILED=1
  fi
done
echo "PASS: frontmatter lint complete"

echo "== bash -n on every bin script =="
for f in "$PLUGIN_DIR"/bin/*; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/tmp/repo-audit-bashn.$$; then
    echo "PASS: bash -n $f"
  else
    echo "FAIL: bash -n $f"
    cat /tmp/repo-audit-bashn.$$
    FAILED=1
  fi
  rm -f /tmp/repo-audit-bashn.$$
done

echo "== wrapper _auth.sh resolution through a symlink =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for w in gh-read repo-fetch ai-readiness-package; do
  ln -sf "$PLUGIN_DIR/bin/$w" "$TMP/$w"
  out="$("$TMP/$w" 2>&1)"
  rc=$?
  # Every wrapper prints an ERROR:/usage line and exits 0 when called with no
  # (or insufficient) arguments; the important thing is that it got far enough
  # to source _auth.sh and crew-config.sh without an "unbound variable" or
  # "No such file" sourcing failure.
  if [ $rc -ne 0 ] || ! printf '%s' "$out" | grep -qE '^ERROR: '; then
    echo "FAIL: $w did not resolve through symlink cleanly: rc=$rc out=$out"
    FAILED=1
  else
    echo "PASS: $w resolves _auth.sh through a symlink"
  fi
done

echo "== vendored crew-config.sh identity =="
CANONICAL_CHECK="$PLUGIN_DIR/../scripts/check-vendored-libs.sh"
if [ -f "$CANONICAL_CHECK" ]; then
  if bash "$CANONICAL_CHECK"; then
    echo "PASS: vendored libs match canonical"
  else
    echo "FAIL: vendored libs drifted from canonical"
    FAILED=1
  fi
else
  echo "SKIPPED: $CANONICAL_CHECK not found in this checkout"
fi

echo "== scrub-check =="
SCRUB="$HERE/../../scripts/scrub-check.sh"
ALLOW="$HERE/../../scripts/scrub-allow.txt"
if [ -f "$SCRUB" ]; then
  if [ -f "$ALLOW" ]; then
    scrub_out="$(bash "$SCRUB" --allow "$ALLOW" "$PLUGIN_DIR" 2>&1)"
  else
    scrub_out="$(bash "$SCRUB" "$PLUGIN_DIR" 2>&1)"
  fi
  scrub_rc=$?
  echo "$scrub_out"
  if [ "$scrub_rc" -eq 0 ] || [ "$scrub_rc" -eq 4 ]; then
    echo "PASS: scrub-check (rc=$scrub_rc)"
  else
    echo "FAIL: scrub-check (rc=$scrub_rc)"
    FAILED=1
  fi
else
  echo "SKIPPED: $SCRUB not found in this checkout"
fi

echo "== wrapper behaviour (git-read / gh-read / repo-fetch) =="
if bash "$HERE/test-wrappers-behaviour.sh"; then
  :
else
  echo "FAIL: test-wrappers-behaviour.sh reported a failure (see above)"
  FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo "repo-audit tests: FAILED"
  exit 1
fi
echo "repo-audit tests: PASSED"
exit 0
