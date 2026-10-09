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
  for support in checklist.md template.md chain-superpowers.md chain-mattpocock.md run-modes.md verify.md; do
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
  grep -qF 'except when the user skipped the plan' "$INTAKE_DIR/chain-superpowers.md" || ifail "intaking-work-items/chain-superpowers.md: stage-3 prerequisite missing the plan-skip exception"
  grep -qF 'A row 7/12 blocker that is a repo gate' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the row-7/12 repo-gate second-confirmation rule"
  grep -qF 'Gap table at skip' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the 'Gap table at skip' rule"
  grep -qF '## Gap table at skip' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the 'Gap table at skip' section"
  grep -qF 'cover only active AC' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the 'cover only active AC' settled-AC rule"
  grep -qF 'Acceptance criteria (settled)' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: stub doc missing the 'Acceptance criteria (settled)' section"
  grep -qF '## Acceptance criteria (settled)' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: stub note missing the 'Acceptance criteria (settled)' section"
  grep -qF '**Chain:**' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the '**Chain:**' header field"
  grep -qF 'Never replicate these skills' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing the 'Never replicate' rule for user-only mattpocock skills"
  grep -qF 'mattpocock path needs GitHub issues' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the GitHub-only gate for the mattpocock chain"

  grep -qF '**Access and environment**' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: missing the Access and environment row"
  grep -qF 'agent-verifiable' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: missing the agent-verifiable / person-only AC tag"
  grep -qF 'unattended unavailable' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: row 14 missing the unattended-unavailable rule"
  grep -qF '| AC | Kind | Seam | Catches / misses | Test name | Location |' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the AC→test table"
  grep -qF '**Run mode:**' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Run mode header"
  grep -qF '## Verification evidence' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Verification evidence section"
  grep -qF '## Run log' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Run log section"
  grep -qF 'Ready | Partial | Delivered' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: Status missing Partial / Delivered"

  grep -qF '## Run mode' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the Run mode section"
  grep -qF 'Skip on the run-mode question means attended' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the run-mode Skip rule"
  grep -qF '`unattended` is the default' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the run-mode default"
  grep -qF 'plan-skip go-ahead' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: plan-skip rule missing the pre-authorization"
  grep -qF 'draft PR already open' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: cancel rule missing the open-draft-PR case"
  grep -qF 'pre-authorizes exactly two outward actions' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the go's pre-authorization"
  grep -qF 'gh pr create --draft' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the draft PR command"
  grep -qF 'is the seam confirmation' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: gate mapping missing the tdd seam answer"
  grep -qF 'answers gate 8' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: gate mapping missing opening-pull-requests gate 8"
  grep -qF 'a gate the sitting did not answer' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the unanswered-gate stop"
  grep -qF '## Preflight' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing Preflight"
  grep -qF 'baseline is green' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the green-baseline rule"
  grep -qF 'permission mode' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: preflight missing the permission-mode check"
  grep -qF '## Stop conditions' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing Stop conditions"
  grep -qF 'implementation blocker' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the implementation-blocker path"
  grep -qF 'publication blocker' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the publication-blocker path"
  grep -qF 'a seam not in the AC→test table' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the missing-seam stop"
  grep -qF 'before every go' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: preflight not required before every go"
  grep -qF 'stop locally' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the local-stop path"
  grep -qF 'PushNotification' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the notification channel"
  grep -qF 'continue from the Run log' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing resume-from-Run-log"

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
  grep -qF "step 6's **Ship**" "$INTAKE_DIR/chain-superpowers.md" "$INTAKE_DIR/chain-mattpocock.md" && ifail "intaking-work-items/chain-*.md: still return to step 6's Ship"
  grep -qF 'without its stage checkpoints' "$INTAKE_DIR/chain-superpowers.md" || ifail "intaking-work-items/chain-superpowers.md: missing the unattended implement rule"
  grep -qF 'pre-authorizes' "$INTAKE_DIR/chain-superpowers.md" || ifail "intaking-work-items/chain-superpowers.md: plan approval missing the pre-authorization"
  grep -qF 'go unattended?' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing the go question"
  grep -qF 'implement-spec' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: Implement stage does not use implement-spec"
  grep -qF 'intake mode publishes nothing' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing intake mode"
  grep -qF 'attended only' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing the attended fallback"
  grep -qF 'confirmed seam list' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: implement-spec handoff missing the seam list"
  grep -qF 'confirmed seam list' "$INTAKE_DIR/chain-superpowers.md" || ifail "intaking-work-items/chain-superpowers.md: implementer handoff missing the seam list"
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

echo "== Result =="
if [ "$FAIL" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "PASSED"
exit 0
