#!/usr/bin/env bash
# dev-workflow plugin tests: frontmatter lint (skills + agents), scrub-check
# (if the scanner is available in this checkout), and a [[wikilink]] resolver
# check against this plugin's own skills/ and agents/.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=1
}

# --- 1. Frontmatter lint -----------------------------------------------

# extract_frontmatter <file> — prints the YAML frontmatter block (between the
# first two '---' lines) to stdout, or nothing if the file has none.
extract_frontmatter() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { exit }
    infm { print }
  ' "$1"
}

lint_skill() {
  f="$1"
  fm="$(extract_frontmatter "$f")"
  if [ -z "$fm" ]; then
    fail "$f: missing frontmatter (no leading --- block)"
    return
  fi
  echo "$fm" | grep -qE '^name:[[:space:]]*\S' || fail "$f: frontmatter missing 'name'"
  echo "$fm" | grep -qE '^description:' || fail "$f: frontmatter missing 'description'"
}

lint_agent() {
  f="$1"
  fm="$(extract_frontmatter "$f")"
  if [ -z "$fm" ]; then
    fail "$f: missing frontmatter (no leading --- block)"
    return
  fi
  echo "$fm" | grep -qE '^name:[[:space:]]*\S' || fail "$f: frontmatter missing 'name'"
  echo "$fm" | grep -qE '^description:' || fail "$f: frontmatter missing 'description'"
  echo "$fm" | grep -qE '^model:[[:space:]]*\S' || fail "$f: frontmatter missing 'model'"
}

echo "== Frontmatter lint =="

for skill_md in "$ROOT"/skills/*/SKILL.md; do
  [ -e "$skill_md" ] || continue
  lint_skill "$skill_md"
done

for agent_md in "$ROOT"/agents/*.md; do
  [ -e "$agent_md" ] || continue
  lint_agent "$agent_md"
done

if [ "$FAIL" -eq 0 ]; then
  echo "ok: all skill/agent frontmatter has the required fields"
fi

# --- 2. Scrub check -------------------------------------------------------

echo "== Scrub check =="

SCRUB_CHECK="$HERE/../../scripts/scrub-check.sh"
SCRUB_ALLOW="$HERE/../../scripts/scrub-allow.txt"

if [ -x "$SCRUB_CHECK" ] || [ -f "$SCRUB_CHECK" ]; then
  if [ -f "$SCRUB_ALLOW" ]; then
    bash "$SCRUB_CHECK" --allow "$SCRUB_ALLOW" "$ROOT"
  else
    bash "$SCRUB_CHECK" "$ROOT"
  fi
  rc=$?
  case "$rc" in
    0) echo "ok: scrub-check clean" ;;
    4) echo "ok: scrub-check clean (soft dangling-link warning only, see above)" ;;
    *) fail "scrub-check.sh reported denylist hits (exit $rc)" ;;
  esac
else
  echo "skip: scrub-check.sh not found at $SCRUB_CHECK (not in this checkout)"
fi

# --- 3. Link check ---------------------------------------------------------

echo "== Link check =="

link_target_exists() {
  name="$1"
  [ -d "$ROOT/skills/$name" ] && return 0
  [ -f "$ROOT/agents/$name.md" ] && return 0
  return 1
}

# Collect every [[name]] reference across the plugin's own markdown content.
# Restricted to *.md — scripts/ can contain bash [[ ... ]] test syntax, which
# is not a wikilink and would otherwise produce false positives.
LINKS="$(find "$ROOT/skills" "$ROOT/agents" "$ROOT/README.md" -name '*.md' 2>/dev/null \
  | xargs grep -hoE '\[\[[^]]+\]\]' 2>/dev/null | sort -u)"

LINK_FAIL_MARKER="$(mktemp)"
if [ -n "$LINKS" ]; then
  echo "$LINKS" | while IFS= read -r link; do
    name="${link#\[\[}"
    name="${name%\]\]}"
    if ! link_target_exists "$name"; then
      echo "FAIL: dangling [[$name]] — no skills/$name/ or agents/$name.md in this plugin" >&2
      : > "$LINK_FAIL_MARKER.hit"
    fi
  done
  if [ -f "$LINK_FAIL_MARKER.hit" ]; then
    FAIL=1
    rm -f "$LINK_FAIL_MARKER.hit"
  else
    echo "ok: every [[wikilink]] resolves inside this plugin"
  fi
else
  echo "ok: no [[wikilink]] references found"
fi
rm -f "$LINK_FAIL_MARKER"

echo "== NEEDS_LOOKUP lookup rule =="

CODE_WRITER="$ROOT/agents/code-writer.md"
if [ -f "$CODE_WRITER" ]; then
  fm="$(extract_frontmatter "$CODE_WRITER")"
  tools_line="$(echo "$fm" | grep -E '^tools:' || true)"
  echo "$tools_line" | grep -q 'SendMessage' || fail "code-writer.md: tools: missing SendMessage ($tools_line)"
  echo "$tools_line" | grep -qE 'WebFetch|WebSearch' && fail "code-writer.md: tools: must not include WebFetch/WebSearch ($tools_line)"
  grep -q 'NEEDS_LOOKUP:' "$CODE_WRITER" || fail "code-writer.md: body missing NEEDS_LOOKUP:"
  grep -qF 'addressed to `main`' "$CODE_WRITER" || fail "code-writer.md: body missing \"addressed to \`main\`\""
  grep -qF 'from `main`' "$CODE_WRITER" || fail "code-writer.md: step 3 missing \"from \`main\`\""
  # The report-format bullet, not the step-4 mention of **Waiting on**.
  grep -qE '^- \*\*Waiting on\*\*:' "$CODE_WRITER" || fail "code-writer.md: final report format missing a **Waiting on** section"
else
  fail "agents/code-writer.md not found"
fi

PLAN_SKILL="$ROOT/skills/plan-implementation/SKILL.md"
if [ -f "$PLAN_SKILL" ]; then
  grep -qF 'When a lane sends `NEEDS_LOOKUP`' "$PLAN_SKILL" || fail "plan-implementation/SKILL.md: missing \"When a lane sends \`NEEDS_LOOKUP\`\" section"
  grep -qF 'sendmessage-recipient-gate' "$PLAN_SKILL" || fail "plan-implementation/SKILL.md: does not name the sendmessage-recipient-gate enforcement hook"
else
  fail "skills/plan-implementation/SKILL.md not found"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ok: NEEDS_LOOKUP lookup rule present in code-writer.md and plan-implementation/SKILL.md"
fi

echo "== audit.sh behavior =="

if bash "$HERE/test-audit-sh.sh"; then
  :
else
  fail "test-audit-sh.sh reported a failure (see above)"
fi

echo "== review-policy skill =="

# Content pin on the skill BODY (everything after the frontmatter's closing
# '---'). The heading/tier-label checks below would still pass a reversed
# evidence rule; the hash catches wording changes the heading checks can't.
# The frontmatter description is excluded on purpose — description tuning
# shouldn't trip this.
REVIEW_POLICY_SHA256="dc396434f418dc4f5ffcf9c7a0b165cec61905b51e9019bc726bed213dec35a8"

# extract_skill_body <file> — prints everything after the frontmatter's
# closing '---' line.
extract_skill_body() {
  awk '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---" { infm=0; started=1; next }
    started { print }
  ' "$1"
}

# sha256_of_stdin — portable sha256 over stdin: sha256sum on Linux,
# shasum -a 256 on macOS (CI runs both).
sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo ""
  fi
}

REVIEW_POLICY_SKILL="$ROOT/skills/review-policy/SKILL.md"
if [ -f "$REVIEW_POLICY_SKILL" ]; then
  fm="$(extract_frontmatter "$REVIEW_POLICY_SKILL")"
  echo "$fm" | grep -qE '^name:[[:space:]]*review-policy[[:space:]]*$' || fail "review-policy/SKILL.md: frontmatter name is not 'review-policy'"
  grep -q '^## Tiers' "$REVIEW_POLICY_SKILL" || fail "review-policy/SKILL.md: missing '## Tiers' heading"
  grep -qF '**Exempt**' "$REVIEW_POLICY_SKILL" || fail "review-policy/SKILL.md: missing Exempt tier"
  grep -qF '**Routine**' "$REVIEW_POLICY_SKILL" || fail "review-policy/SKILL.md: missing Routine tier"
  grep -qF '**Full chain**' "$REVIEW_POLICY_SKILL" || fail "review-policy/SKILL.md: missing Full chain tier"
  grep -q '^## Evidence rule' "$REVIEW_POLICY_SKILL" || fail "review-policy/SKILL.md: missing '## Evidence rule' heading"

  actual_sha256="$(extract_skill_body "$REVIEW_POLICY_SKILL" | sha256_of_stdin)"
  if [ -z "$actual_sha256" ]; then
    fail "review-policy/SKILL.md: no sha256sum or shasum -a 256 available to compute the content pin"
  elif [ "$actual_sha256" != "$REVIEW_POLICY_SHA256" ]; then
    fail "review-policy/SKILL.md: review policy wording changed (body sha256 $actual_sha256, expected $REVIEW_POLICY_SHA256) — an intentional policy change must update REVIEW_POLICY_SHA256 in this same PR so the change shows up in review"
  fi
else
  fail "skills/review-policy/SKILL.md not found"
fi

grep -qF 'dev-workflow:review-policy' "$ROOT/README.md" || fail "README.md: § Review policy does not point at dev-workflow:review-policy"

grep -qF '| `review-policy` |' "$ROOT/README.md" || fail "README.md: Skills table missing a row starting with '| \`review-policy\`'"

# Repo-wide leftover-citation guard: not just dev-workflow, and not just the
# exact old phrase — case-insensitive, covering "README's review policy",
# "README § review policy", and "this plugin's README" style references.
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
LEFTOVER_CITATION_RE="README['’]?s?[[:space:]]*(§[[:space:]]*)?review[[:space:]]+policy|plugin['’]s README"
LINGERING_CITATIONS="$(find "$REPO_ROOT" \( -path "$REPO_ROOT/.git" -o -path "$REPO_ROOT/.claude/worktrees" -o -name tests \) -prune -o \( -name '*.md' -o -name '*.json' \) -type f -print0 2>/dev/null \
  | xargs -0 grep -liE "$LEFTOVER_CITATION_RE" 2>/dev/null)"
if [ -n "$LINGERING_CITATIONS" ]; then
  fail "found a lingering README/review-policy citation — should point at the dev-workflow:review-policy skill instead: $LINGERING_CITATIONS"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "ok: review-policy skill present with the moved tier table, evidence rule, and content pin; no lingering README citations"
fi

echo "== intaking-work-items skill =="

INTAKE_DIR="$ROOT/skills/intaking-work-items"
INTAKE_SKILL="$INTAKE_DIR/SKILL.md"
# Local counter: fail() only ever sets FAIL=1, so comparing FAIL before and
# after this block cannot see an intake failure that follows an earlier one.
INTAKE_FAILS=0
ifail() {
  INTAKE_FAILS=$((INTAKE_FAILS + 1))
  fail "$1"
}
desc_len=0
lines=0
if [ -f "$INTAKE_SKILL" ]; then
  fm="$(extract_frontmatter "$INTAKE_SKILL")"
  echo "$fm" | grep -qE '^name:[[:space:]]*intaking-work-items[[:space:]]*$' || ifail "intaking-work-items/SKILL.md: frontmatter name is not 'intaking-work-items'"

  # Description length: the folded '>' block after 'description:', joined
  # with single spaces the way YAML folds it. Skill descriptions cap at 1024.
  desc="$(echo "$fm" | awk '
    /^description:/ { indesc=1; next }
    indesc && /^[^[:space:]]/ { exit }
    indesc { sub(/^[[:space:]]+/, ""); printf "%s%s", sep, $0; sep=" " }
  ')"
  desc_len="$(printf '%s' "$desc" | wc -c | tr -d ' ')"
  [ "$desc_len" -gt 0 ] || ifail "intaking-work-items/SKILL.md: could not read the description"
  [ "$desc_len" -le 1024 ] || ifail "intaking-work-items/SKILL.md: description is $desc_len chars (max 1024)"

  lines="$(wc -l < "$INTAKE_SKILL" | tr -d ' ')"
  [ "$lines" -lt 500 ] || ifail "intaking-work-items/SKILL.md: $lines lines (keep under 500; push detail into supporting files)"

  # Supporting files exist and are linked one level deep from SKILL.md.
  for support in checklist.md template.md chain-mattpocock.md chain-sdlc-process.md verify.md; do
    [ -f "$INTAKE_DIR/$support" ] || ifail "intaking-work-items/$support not found"
    grep -qF "]($support)" "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: does not link $support"
  done

  # The AC gate and the per-action writeback confirmation are the skill's
  # load-bearing rules — pin their presence.
  grep -qF 'HARD GATE' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the HARD GATE on gap closure"
  grep -qF 'Never silently invent AC' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the no-invented-AC rule"
  grep -qF 'docs/specs/<KEY>-requirements.md' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the requirements doc path"
  grep -qF 'confirm each action' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing per-action writeback confirmation"
  grep -qF 'Contradictions block the gate' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the contradiction-blocks-the-gate rule"
  grep -qF 'Contradictions block the gate' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: missing the contradiction rating rule"
  grep -qF 'classify before you merge' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the linked-item classification rule"
  grep -qF 'Equivalent needs evidence' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the evidence rule for equivalent items"
  grep -qF '## Controls: skip and cancel' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the 'Controls: skip and cancel' section"
  grep -qF 'Skipped by user' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the 'Skipped by user' deferral record"
  grep -qF 'Status: CANCELLED' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the 'Status: CANCELLED' doc marker"
  grep -qF 'post to Jira or GitHub on cancel' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the no-post-on-cancel rule"
  grep -qF 'Status: CANCELLED' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the 'Status: CANCELLED' marker"
  grep -qF 'user-deferred' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: deferred table missing the user-deferred / skipped source column"
  grep -qF 'A generic remote link is not identity evidence' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the generic-remote-link rule"
  grep -qF 'A generic remote link is not identity evidence' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: missing the generic-remote-link rule"
  grep -qF 'always refetch and diff against the snapshot' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the resume refetch/diff rule"
  grep -qF 'except the single edit that marks an existing requirements doc CANCELLED' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the cancel-marker exception"
  grep -qF 'Never create a doc on cancel' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the no-doc-on-cancel rule"
  grep -qF 'Every skipped step is stated downstream' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the skipped-step-in-plan/PR rule"
  grep -qF 'Intake: gap analysis skipped — requirements not gap-checked' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the 'requirements not gap-checked' plan/PR line"
  grep -qF 'still write a stub doc' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the stub-doc rule"
  grep -qF 'unless the user skipped the whole step' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: gate text missing the whole-step-skip exception"
  grep -qF 'Intake: plan skipped' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the 'Intake: plan skipped' PR line"
  grep -qF 'A row 7/12 blocker that is a repo gate' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the row-7/12 repo-gate second-confirmation rule"
  grep -qF 'Gap table at skip' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the 'Gap table at skip' rule"
  grep -qF '## Gap table at skip' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the 'Gap table at skip' section"
  grep -qF 'cover only active AC' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the 'cover only active AC' settled-AC rule"
  grep -qF 'Acceptance criteria (settled)' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: stub doc missing the 'Acceptance criteria (settled)' section"
  grep -qF '## Acceptance criteria (settled)' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: stub note missing the 'Acceptance criteria (settled)' section"
  grep -qF '**Chain:**' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the '**Chain:**' header field"
  grep -qF 'Never replicate these skills' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing the 'Never replicate' rule for user-only mattpocock skills"
  grep -qF 'mattpocock path needs GitHub issues' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the GitHub-only gate for the mattpocock chain"
  grep -qF 'sdlc-process:sdlc-process' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the sdlc-process:sdlc-process chain entry"
  grep -qF 'sdlc-process:implement' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the sdlc-process:implement route"
  grep -qF 'sdlc-process:code-review' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the sdlc-process:code-review route"
  grep -qF 'never publish to GitHub' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the no-GitHub-publish rule"
  grep -qF 'Attended only' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the attended-only rule"
  grep -qF 'per-issue confirmation' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the per-issue confirmation rule"
  grep -qF 'review base' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the review base"
  grep -qF 'Always use the `sdlc-process:` prefix' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the prefix rule"
  grep -qF 'Never answer a sdlc-process gate on the user' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the no-answering-gates rule"
  grep -qF 'no local-file' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the no-local-file-fallback rule"
  grep -qF 'one after another or parallel partners' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the partner-sessions rule 'one after another or parallel partners'"
  grep -qF 'dev-workflow:coordinating-partner-sessions' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the partner-sessions rule 'dev-workflow:coordinating-partner-sessions'"
  grep -qF 'partner-sessions/<KEY>/ledger.json' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the partner-sessions rule 'partner-sessions/<KEY>/ledger.json'"
  grep -qF 'AC of a cancelled issue are deferred' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the partner-sessions rule 'AC of a cancelled issue are deferred'"
  grep -qF 'closing keywords and Refs cover merged issues only' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the partner-sessions rule 'closing keywords and Refs cover merged issues only'"
  grep -qF 'only when two or more issues are published' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the partner-sessions rule 'only when two or more issues are published'"
  grep -qF 'partner-sessions/<KEY>/ledger.json' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: Chain artifacts missing the partner ledger location"
  grep -qF 'sdlc-process' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the sdlc-process chain artifacts"

  grep -qF '**Access and environment**' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: missing the Access and environment row"
  grep -qF 'agent-verifiable' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: missing the agent-verifiable / person-only AC tag"
  grep -qF '| AC | Kind | Seam | Catches / misses | Test name | Location |' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the AC→test table"
  grep -qF '## Verification evidence' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Verification evidence section"
  grep -qF '## Run log' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Run log section"
  grep -qF 'Ready | Partial | Delivered' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: Status missing Partial / Delivered"

  grep -qF 'draft PR already open' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: cancel rule missing the open-draft-PR case"

  grep -qF '## 7. Verify' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing step 7 Verify"
  grep -qF 'fail on an assertion' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: red check not limited to assertion failures"
  grep -qF 'red n/a — new interface' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the new-interface red rule"
  grep -qF 'names a module or symbol the branch adds' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: new-interface exception too broad"
  grep -qF 'only test files and fixtures' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing what is copied to the base worktree"
  grep -qF 'pass twice on head' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the flake check"
  grep -qF 'up to 2 fix attempts' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the 2-attempt rule"
  grep -qF 'verified / failed / unverified / not delivered' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the result vocabulary"
  grep -qF 'read-only commands only' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the read-only live-check rule"
  grep -qF 'post-merge' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing post-merge DoD handling"
  grep -qF 'quoted output line' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the evidence rule"
  grep -qF "never trust a worker's report" "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the re-run rule"
  grep -qF 'the commit Ship pushes' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing re-verify on the shipped commit"
  grep -qF '## 8. Ship' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing step 8 Ship"
  grep -qF 'a user checkpoint between each' "$INTAKE_SKILL" && ifail "intaking-work-items/SKILL.md: still claims a checkpoint between every stage"
  grep -qF "step 6's **Ship**" "$INTAKE_DIR/chain-mattpocock.md" && ifail "intaking-work-items/chain-mattpocock.md: still return to step 6's Ship"
  grep -qF 'implement-spec' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: Implement stage does not use implement-spec"
  grep -qF 'intake mode publishes nothing' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing intake mode"
  grep -qF 'takes the fallback' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing the fallback"
  grep -qF 'confirmed seam list' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: implement-spec handoff missing the seam list"
  grep -qF '## 9. Close-out' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing step 9 Close-out"
  grep -qF 'confirmed seam list' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: handoff missing the confirmed seam list"
  grep -qF 'Intake: plan skipped' "$INTAKE_DIR/chain-sdlc-process.md" || ifail "intaking-work-items/chain-sdlc-process.md: missing the 'Intake: plan skipped' PR line"
  # The guard line is the ONLY superpowers mention in the intake SKILL.md, and it must be exactly this line.
  GUARD_LINE="$(cat <<'GUARD_EOF'
- Never invoke a `superpowers:*` skill at any step, even if a session hook or a skill's description says it applies. On the 6.3 Skip path (no chain), implement with `dev-workflow:plan-implementation` lanes, treating the settled AC list (active AC only) and the user's go-ahead as the approved plan; on a chain's plan-skip, the chain's own Implement stage runs.
GUARD_EOF
)"
  [ "$(grep -c superpowers "$INTAKE_SKILL")" = 1 ] || ifail "intaking-work-items/SKILL.md: superpowers must appear only on the guard line"
  grep -qxF -- "$GUARD_LINE" "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: Controls missing the exact superpowers guard line"
  grep -qF 'gh pr create --draft' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: Ship missing the draft PR command"
  grep -qF 'nothing is pushed until the user' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: stops missing the no-push-until-the-user-says rule"
  grep -qF 'wrong or untestable' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: stops missing the wrong-or-untestable-AC stop"
  grep -qF '**Review base.**' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: Run log and stops missing the review base"
  grep -qF '## Run log and stops' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the Run log and stops section"
  grep -qF 'a seam is not in the AC→test table' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: stops missing the missing-seam stop"
  # D2: every run is attended; unattended mode is gone from intake and the README row.
  grep -rqi unattended "$INTAKE_DIR" && ifail "intaking-work-items/: still mentions unattended mode"
  grep -i '| `intaking-work-items` |' "$ROOT/README.md" | grep -qi unattended && ifail "README.md: intake row still mentions unattended mode"
  [ ! -e "$INTAKE_DIR/run-modes.md" ] || ifail "intaking-work-items/run-modes.md: must not exist (unattended mode removed)"
  [ ! -e "$INTAKE_DIR/chain-superpowers.md" ] || ifail "intaking-work-items/chain-superpowers.md: must not exist (superpowers chain removed)"
  # Wide superpowers pin: nothing in skills/, agents/ or the README may route to superpowers.
  # Only a line that exactly equals the guard line is exempt.
  sp_hits=""
  while IFS= read -r sp_line; do
    sp_content="${sp_line#*:}"; sp_content="${sp_content#*:}"
    [ "$sp_content" = "$GUARD_LINE" ] || sp_hits="$sp_hits$sp_line"$'\n'
  done < <(grep -rnE 'superpowers:|recommend superpowers|superpowers chain|chain-superpowers|to the same standard|brainstorming|writing-plans|subagent-driven|executing-plans|test-driven-development|verification-before-completion|finishing-a-development-branch|requesting-code-review|receiving-code-review|systematic-debugging|using-git-worktrees|dispatching-parallel-agents' "$ROOT/skills" "$ROOT/agents" "$ROOT/README.md" 2>/dev/null)
  [ -z "$sp_hits" ] || ifail "skills/, agents/ or README.md: superpowers reference found: $sp_hits"
  grep -qF 'Recommend **sdlc-process** whenever it is installed' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: step 6 does not recommend sdlc-process whenever it is installed"
  grep -qF 'mattpocock never outranks an installed' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the rule that mattpocock never outranks an installed sdlc-process"
  grep -qF 'sdlc-process / mattpocock / **Skip**' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: chain question is not sdlc-process / mattpocock / Skip"
  grep -qF '`/retro`' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: close-out missing the /retro offer"
  grep -qF 'skill-retrospective' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: close-out missing the skill-retrospective route"
  grep -qF 'separate branch and PR' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: retro changes not kept off the ticket PR"
  grep -qF 'Status becomes Delivered only if' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the Delivered rule"
  grep -qF 'context only' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: live read lacks the revision-provenance rule"
  grep -qF 'review base' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: handoff missing the review base"
  grep -qF 'In intake mode' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing the implement-spec intake-clause check"
  grep -qF 'a seam not in the table is a stop' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: handoff missing the unanswered-seam stop"
  grep -qF 'person-only' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: checklist missing person-only"
  # Public-repo hygiene: no organisation-specific ticket project or skill
  # names in this skill (they don't resolve from a public checkout).
  ces_hits="$(grep -rniwE 'ces' "$INTAKE_DIR" 2>/dev/null || true)"
  [ -z "$ces_hits" ] || ifail "intaking-work-items/: organisation-specific term 'ces' found: $ces_hits"
else
  ifail "skills/intaking-work-items/SKILL.md not found"
fi

grep -qF '| `intaking-work-items` |' "$ROOT/README.md" || ifail "README.md: Skills table missing a row starting with '| \`intaking-work-items\`'"

if [ "$INTAKE_FAILS" -eq 0 ]; then
  echo "ok: intaking-work-items skill present (description $desc_len chars, SKILL.md $lines lines), supporting files linked, gate rules pinned"
fi

echo "== coordinating-partner-sessions skill =="
PS_DIR="$ROOT/skills/coordinating-partner-sessions"
PARTNER_FAILS=0
pfail() {
  PARTNER_FAILS=$((PARTNER_FAILS + 1))
  fail "$1"
}
for f in ledger.md readiness.md partner-brief.md; do
  [ -f "$PS_DIR/$f" ] || pfail "coordinating-partner-sessions/$f not found"
done
if [ -f "$PS_DIR/ledger.md" ]; then
  for pin in '## Transition table' '`pending`' '`launched`' '`started`' '`blocked-on #m`' '`done-claimed`' '`verifying`' \
             '`rework-n/3`' '`resync-requested`' '`merged`' '`failed`' '`cancelled`' 'generation' 'outbox' \
             'done nopid' 'exit 30' 'supersedes' 'gen=<g>' 'canary-passed' 'launch-failed' \
             'launch-intent' 'merge-intent' 'partner-sessions/<KEY>/ledger.json' 'git-common-dir' \
             'never committed' 'PS_OWNER' 'ledger.sh event' 'write.lock' 'exit 41' 'lockf -s' 'flock -w'; do
    grep -qF -- "$pin" "$PS_DIR/ledger.md" || pfail "coordinating-partner-sessions/ledger.md: missing '$pin'"
  done
fi
if [ -f "$PS_DIR/readiness.md" ]; then
  for pin in 'a story' 'acceptance criteria' 'test command' 'a stated reason none is needed' 'ask only about what changed'; do
    grep -qF -- "$pin" "$PS_DIR/readiness.md" || pfail "coordinating-partner-sessions/readiness.md: missing '$pin'"
  done
fi
if [ -f "$PS_DIR/partner-brief.md" ]; then
  for pin in 'gen=' 'never rebase onto main' 'Never push' 'never open a PR' 'never close or edit GitHub issues' \
             'STATUS?' 'RESYNC' 'REWORK' 'CANCEL' 'its issue stays open until the ticket PR merges, by design' \
             '{{COORD_NAME}}' '{{BLOCKER_EVIDENCE}}' 'end your turn; the coordinator will stop this session'; do
    grep -qF -- "$pin" "$PS_DIR/partner-brief.md" || pfail "coordinating-partner-sessions/partner-brief.md: missing '$pin'"
  done
fi
PS_SKILL="$PS_DIR/SKILL.md"
ps_desc_len=0
ps_lines=0
if [ -f "$PS_SKILL" ]; then
  fm="$(extract_frontmatter "$PS_SKILL")"
  echo "$fm" | grep -qE '^name:[[:space:]]*coordinating-partner-sessions[[:space:]]*$' || pfail "coordinating-partner-sessions/SKILL.md: frontmatter name is not 'coordinating-partner-sessions'"
  ps_desc="$(echo "$fm" | awk '
    /^description:/ { indesc=1; next }
    indesc && /^[^[:space:]]/ { exit }
    indesc { sub(/^[[:space:]]+/, ""); printf "%s%s", sep, $0; sep=" " }
  ')"
  ps_desc_len="$(printf '%s' "$ps_desc" | wc -c | tr -d ' ')"
  [ "$ps_desc_len" -gt 0 ] || pfail "coordinating-partner-sessions/SKILL.md: could not read the description"
  [ "$ps_desc_len" -le 1024 ] || pfail "coordinating-partner-sessions/SKILL.md: description is $ps_desc_len chars (max 1024)"
  ps_lines="$(wc -l < "$PS_SKILL" | tr -d ' ')"
  [ "$ps_lines" -lt 500 ] || pfail "coordinating-partner-sessions/SKILL.md: $ps_lines lines (keep under 500; push detail into supporting files)"
  for support in ledger.md readiness.md partner-brief.md; do
    grep -qF "]($support)" "$PS_SKILL" || pfail "coordinating-partner-sessions/SKILL.md: does not link $support"
  done
  # The coordinator loop's load-bearing rules: merge rule, gate, canary,
  # preflight, resume, failure paths and hand-back.
  for pin in 'fast-forward only' 'RESYNC' 'REWORK' 'STATUS?' 'gen=' \
             'Git state matches the claim' 'Tests pass, run by the coordinator' 'Every AC has evidence' \
             'dev-workflow:fresh-verifier' 'Partners never push or open PRs' 'third failed gate' \
             'stop and ask the user' 'held for approval' 'v2.1.236' 'v2.1.248' 'not in plan mode' \
             'integration base is the ticket branch' '/rename' 'canary-passed' 'sleep 600' \
             'only a canary that has ended' 'cross-session-message' \
             'For each `cancelled` issue, mark its AC `deferred` in the settled AC list, with the reason stored by `drop` or `cancel-ticket`.' \
             'Refs owner/repo#' 'notify_when_idle' 're-register' 'skip steps 3–5' 'PS_OWNER' \
             'ledger.sh summary' 'after the user confirms' '/retro' 'skill-retrospective' \
             'claude stop <id>' "stop every alive session in the issue's session history" \
             'never stop a session it did not launch' 'sleep 300' 'do not loop'; do
    grep -qF -- "$pin" "$PS_SKILL" || pfail "coordinating-partner-sessions/SKILL.md: missing '$pin'"
  done
else
  pfail "coordinating-partner-sessions/SKILL.md not found"
fi
for s in parse-msg.sh frontier.sh ff-merge.sh ledger.sh piece-track.sh; do
  [ -f "$PS_DIR/scripts/$s" ] || pfail "coordinating-partner-sessions/scripts/$s not found"
  [ -x "$PS_DIR/scripts/$s" ] || pfail "coordinating-partner-sessions/scripts/$s is not executable"
done
# Public-repo hygiene: no organisation-specific ticket skill names.
if [ -d "$PS_DIR" ]; then
  ps_ces="$(grep -rniwE 'ces' "$PS_DIR" 2>/dev/null || true)"
  [ -z "$ps_ces" ] || pfail "coordinating-partner-sessions/: organisation-specific term 'ces' found: $ps_ces"
fi
if [ "$PARTNER_FAILS" -eq 0 ]; then
  echo "ok: coordinating-partner-sessions skill present (description $ps_desc_len chars, SKILL.md $ps_lines lines), reference files linked and pinned"
fi

echo "== coordinating-partner-sessions scripts =="
# Run with the interpreter running this file, so `/bin/bash run.sh` on macOS
# exercises bash 3.2 end to end.
for t in parse-msg frontier ff-merge ledger coordinator-contract piece-track; do
  if "$BASH" "$HERE/test-$t-sh.sh"; then
    :
  else
    fail "test-$t-sh.sh reported a failure (see above)"
  fi
done

echo "== Result =="
if [ "$FAIL" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
exit 0
