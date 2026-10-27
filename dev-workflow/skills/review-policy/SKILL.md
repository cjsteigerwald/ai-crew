---
name: review-policy
description: >
  Loads dev-workflow's review policy — the tier table (Exempt / Routine / Full
  chain), codex-adversary governance, and the evidence rule. Use when a skill
  or orchestrator must decide or apply a review tier before a PR, or on a
  plan/decision doc, or when the user asks "which review tier is this", "does
  this need the full chain", or "apply the review policy". Skip for performing
  the review itself (dispatch fresh-verifier / codex-adversary instead).
---

# Review policy

The skills and agents in this plugin assume a tiered review policy. Adopt it as-is, or
substitute your own and update the cross-references in each skill/agent.

## Tiers (check in order — first match wins)

1. **Exempt** — pure docs with no behavioral or factual load (README, meeting notes),
   pure-judgment ADRs (scope/appetite decisions asserting no facts about existing
   systems), typo/comment-only edits. **Not exempt**: your project's own instructions
   file(s) and any repo-overlay-style file (they alter agent behavior like skill
   definitions do — Routine minimum; any behavioral change to review governance itself is
   Full chain — a gate must not approve its own weakening), and incident write-ups with
   operational content (a common credential/hostname leak surface — Routine minimum plus
   a `fresh-verifier` security-lens dispatch on the pasted-excerpt checklist).
2. **Full chain** — touches Terraform, CI/workflows, auth/credential handling,
   hooks/settings that gate behavior, or agent/command/skill definitions; OR Helm chart
   templates, or any values/manifest file used by a prod deploy (decided by the repo's deploy
   workflows, not by filename; shared base values that prod uses count; target unknown →
   Full; image tag/digest bumps that only affect non-prod follow the size thresholds; the
   other triggers apply on their own); OR >3 files
   changed; OR >~150 changed lines; OR cross-cutting/architectural. Dispatch
   `dev-workflow:codex-adversary` alone on the plan (the verifier checks requirements
   against written code and re-runs tests, which a plan does not have), and
   `dev-workflow:fresh-verifier` + `dev-workflow:codex-adversary` in one message before
   `gh pr create` (on `git diff main...HEAD`). Dispatch `fresh-verifier` with
   `run_in_background` so its time overlaps the Codex wait.
   Read the verifier's Lens recommendation (`lens_recommendation`).
   For each lens it names, dispatch one lens-scoped fresh-verifier or record why not.
   At most two lens-scoped instances per full-tier review (security, tests).
   At least one adversarial pass is required; cap three per PR in aggregate, counted per
   key in the review ledger across sessions (see **Codex round ledger**); every pass
   beyond the first declares its trigger in the transcript **before** dispatch. Effort
   cannot be set per dispatch (the Agent tool exposes model, not effort), so escalate by
   dispatching `dev-workflow:fresh-verifier-high` in place of `fresh-verifier` — model may
   still be overridden per dispatch — rather than counting it as an extra verifier
   instance beyond what this policy already allows. When a `code-review` report (Standards
   and Spec axes) already exists for the diff, pass it to both as input; they focus on
   independence and refutation rather than redoing standards and spec conformance.
3. **Routine** — everything else: small, low-blast-radius changes (≤3 files, ≤~150
   lines, none of the sensitive surfaces above). A single `code-review` pass is enough.

When in doubt between Routine and Full, run Full. The tier is re-checked against the
**actual diff** at pre-PR time — a Routine-planned change that grew past the thresholds
gets Full then.

## Evidence rule

A finding from `fresh-verifier` or `codex-adversary` cannot be dismissed without written
evidence — independently verifiable evidence (code, command output, a cited artifact a
reader can re-check) or explicit human adjudication, recorded with who decided and why. A
later adversarial pass disagreeing with an earlier one is analysis, not evidence, on its
own; where two passes disagree and neither is backed by such evidence, the finding stands
open.

## Re-review after fixes

A fix after a review does not default to a full re-run. Which re-review applies depends on
the tier and on whether the fix is still within what the last full pass saw.

- **Routine:** a bounded `sdlc-process:code-review` on the fix delta.
- **Full:** the same, plus **one bounded `fresh-verifier`**, which may be dispatched with
  `model: sonnet` (delta-only work; the full diff pass uses the agent's default). No Codex
  round.

Apply every finding from a review round first, then run **one** bounded re-review on the
batch, not one per fix commit. On the plan pass, re-reviews and changed-input passes are
Codex-only (each counted under the cap); the bounded `fresh-verifier`, the verifier half of
the changed-input row and the at-cap bounded-verifier option apply to the diff pass.

**Anchor.** The last full pass records the reviewed SHA `A` and its comparison base `B`
(the merge-base with the PR's target branch, pinned when that pass runs).

**Eligibility** is checked each time and is cumulative from `A`; it is not reset after a
bounded pass. A fix is bounded-eligible only if all of these hold:
- churn = (lines added + deleted in `A..HEAD`) ÷ (lines added + deleted in `B..A`) is
  **≤ 20%**;
- no new file or service;
- the **same architecture and trust boundaries** as the pass at `A`;
- no binary changes, and a non-zero denominator.

If any condition fails, the fix is **changed input**.

**Bounded `fresh-verifier` inputs:** `A`, `B`, the delta `A..HEAD`, the prior findings, and
the deterministic checks to re-run. **Duties:** mark each prior finding resolved or not;
check every consumer of what the delta changed (code callers, and any workflow, config,
Helm values, or agent/skill instructions that read a changed file or key); re-run the tests
that cover them; check eligibility itself and return `NEEDS FULL PASS` if any condition
fails.

**Triggers keep their existing scope:**

| Trigger | What it re-runs |
|---|---|
| Changed input (eligibility fails) | A full pass: verifier + Codex; it becomes the new anchor |
| New lens | Only the skipped dimension |
| Escalated effort | Only the one contested finding, in task mode |

**Coverage chain.** A Full-tier PR is covered at HEAD when there is a
`full-tier diff pass @A (base B)` record, every later commit falls inside a
`bounded re-review @N (A..N): resolved` record, and no record says `NEEDS FULL PASS`.

## Codex round ledger

Codex rounds are counted per key (`branch:<name>`, or `plan:<ticket>` before a branch
exists) in the review ledger, across sessions, by `${CLAUDE_PLUGIN_ROOT}/scripts/review-ledger.sh`
(`record`, `link`, `void`, `reset`, `count`, `show`). The `codex-cap-gate` hook derives the
key from the `ledger: <repo-path>[ | plan:<ticket>]` line every Codex brief carries, records
each dispatch, and asks before round 4. It is accounting that prompts you, not a security
boundary.

- Put the `ledger:` line outside code fences, once per brief.

- After a branch rename, run `review-ledger.sh link branch:<new> branch:<old>` so the count
  follows the work. `link` is a snapshot and idempotent; run it at the end of the step.
- Starting genuinely new work under a recycled branch name is a deliberate
  `review-ledger.sh reset <key> <reason>`.
- A dispatch that never ran Codex (a BLOCKING envelope, a failed launch) or a round 4 you
  declined at the prompt is removed with `review-ledger.sh void <tool_use_id> <reason>`.

**Declared limits:**
- the count is per clone;
- attribution comes from the brief's repo path;
- a direct Bash Codex launch (`crew-codex adversarial-review`) is invisible to the hook, so
  record it by hand;
- triggers remain self-certified;
- dispatches blocked by another gate are counted (fix with `void`).

**At the cap**, ask with `AskUserQuestion`; exceeding the cap is never the recommended
option:
- **Recommended when the remaining diff fix is bounded-eligible:** "Stop Codex: bounded
  fresh-verifier on the remaining fix".
- **Recommended otherwise** (a diff fix that is not eligible, or any plan-pass fix): "Stop:
  hand to human review" (a bounded verifier cannot cover a change that needs a full pass,
  and plan-pass reviews are Codex-only).
- **Always second:** "One more Codex round", which must name its trigger.
