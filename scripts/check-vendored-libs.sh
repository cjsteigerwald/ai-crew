#!/usr/bin/env bash
# check-vendored-libs.sh — asserts every plugin's vendored copy of
# lib/crew-config.sh is byte-identical to the canonical copy at
# <repo-root>/lib/crew-config.sh. Plugins vendor the library (rather than
# depend on a sibling path) because each plugin ships and installs
# independently; drift between copies is a bug, not an intentional fork.
#
# Usage: check-vendored-libs.sh
# Exit 0 when every vendored copy matches (or none exist yet); exit 1 and
# list the drifted files otherwise.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
CANONICAL="$REPO_ROOT/lib/crew-config.sh"

if [ ! -f "$CANONICAL" ]; then
  echo "check-vendored-libs: canonical file not found: $CANONICAL" >&2
  exit 1
fi

VENDORED="$(find "$REPO_ROOT" -type f -path '*/lib/crew-config.sh' \
  ! -path "$CANONICAL" \
  -not -path '*/.git/*' 2>/dev/null || true)"

if [ -z "$VENDORED" ]; then
  echo "no vendored copies"
  exit 0
fi

DRIFT=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! cmp -s "$CANONICAL" "$f"; then
    echo "drift: $f"
    DRIFT=1
  fi
done <<EOF
$VENDORED
EOF

if [ "$DRIFT" -ne 0 ]; then
  exit 1
fi

echo "all vendored copies match canonical"
exit 0
