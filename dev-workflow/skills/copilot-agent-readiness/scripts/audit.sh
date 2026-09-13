#!/usr/bin/env bash
# Copilot-agent-readiness audit. Read-only inventory of the instruction files the
# GitHub cloud coding agent reads, plus the common traps. Run from a repo root.
#
#   bash audit.sh [repo_path]   (defaults to cwd)
set -euo pipefail

ROOT="${1:-.}"
cd "$ROOT"

line() { printf '%s\n' "------------------------------------------------------------"; }
exists() { [[ -e "$1" ]]; }

echo "Copilot agent readiness audit: $(pwd)"
line

# --- Files the cloud agent auto-reads (always-on instructions) ---
echo "Always-on instructions READ by cloud agent:"
for f in .github/copilot-instructions.md AGENTS.md CLAUDE.md GEMINI.md; do
  if exists "$f"; then
    lines=$(wc -l < "$f" | tr -d ' ')
    flag=""
    if [[ "$f" == ".github/copilot-instructions.md" && "$lines" -gt 200 ]]; then
      flag="  <-- OVER ~2 pages, slim it (move detail to .github/instructions/)"
    fi
    printf '  [x] %-34s %4s lines%s\n' "$f" "$lines" "$flag"
  else
    printf '  [ ] %-34s MISSING\n' "$f"
  fi
done

# nested AGENTS.md
nested=$(find . -name AGENTS.md -not -path './AGENTS.md' -not -path '*/.git/*' 2>/dev/null || true)
if [[ -n "$nested" ]]; then
  echo "  nested AGENTS.md (nearest-wins):"
  printf '    %s\n' $nested
fi

# nested CLAUDE.md with NO sibling AGENTS.md = invisible to Copilot (cloud agent
# reads root CLAUDE.md only). The cross-tool fix is AGENTS.md (canonical) + a
# CLAUDE.md->@AGENTS.md shim. See SKILL.md "Co-located, per-module instructions".
orphan=$(find . -name CLAUDE.md -not -path './CLAUDE.md' -not -path '*/.git/*' 2>/dev/null \
  | while read -r c; do [[ -e "$(dirname "$c")/AGENTS.md" ]] || echo "$c"; done || true)
if [[ -n "$orphan" ]]; then
  echo "  [!] nested CLAUDE.md with NO sibling AGENTS.md (Copilot-invisible — add AGENTS.md + @AGENTS.md shim):"
  printf '    %s\n' $orphan
fi

line
# --- Path-specific instructions ---
echo "Path-specific (.github/instructions/*.instructions.md) — cloud-agent only:"
if compgen -G ".github/instructions/*.instructions.md" > /dev/null; then
  for f in .github/instructions/*.instructions.md; do
    applyto=$(grep -m1 -i 'applyTo' "$f" 2>/dev/null | sed 's/^[[:space:]]*//' || true)
    printf '  [x] %s\n      %s\n' "$f" "${applyto:-(no applyTo: frontmatter — FIX)}"
  done
else
  echo "  [ ] none (Copilot-only add-on; prefer co-located AGENTS.md+shim above for cross-tool path scoping)"
fi

line
# --- Agent skills (model-invoked; GA Dec 2025) ---
echo "Agent skills (model-invoked, not always-on):"
skill_seen=0
for d in .claude/skills .github/skills .agents/skills; do
  if exists "$d"; then
    skill_seen=1
    n=$(find "$d" -iname 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')
    printf '  [x] %-16s %s SKILL.md  (Copilot reads this; leave the repo convention as-is)\n' "$d/" "$n"
  fi
done
[[ "$skill_seen" -eq 0 ]] && echo "  [ ] none found in .claude/skills, .github/skills, .agents/skills"

line
# --- Traps ---
echo "Traps:"
exists .copilot && echo "  [!] repo-level .copilot/ present — not a skills dir (personal skills are ~/.copilot/skills)."
echo "  [i] guardrails ('never deploy to prod', etc.) must be in always-on instructions, not only in model-invoked skills."

line
# --- Content quality hints on the repo-wide file ---
CI=.github/copilot-instructions.md
if exists "$CI"; then
  echo "Content hints for $CI:"
  grep -qiE 'trust (these|the) instructions' "$CI" \
    && echo "  [ok] tells agent to trust instructions" \
    || echo "  [ ] add: 'Trust these instructions; only search if incomplete'"
  grep -qiE '(test|pytest|lint|ruff|build|validate|make )' "$CI" \
    && echo "  [ok] mentions build/test/lint commands" \
    || echo "  [ ] add concrete build/test/lint commands (with tool versions)"
  grep -qiE '(error|cause|fix|troublesh)' "$CI" \
    && echo "  [ok] documents known errors/mitigations" \
    || echo "  [ ] add a known-errors -> fix table"
fi

line
echo "Next: judge findings against the checklist in SKILL.md, then remediate on a branch."
