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
   hooks/settings that gate behavior, or agent/command/skill definitions; OR >3 files
   changed; OR >~150 changed lines; OR cross-cutting/architectural. Dispatch
   `dev-workflow:fresh-verifier` + `dev-workflow:codex-adversary` in one message, both in
   plan mode (on the plan) and again before `gh pr create` (on `git diff main...HEAD`).
   At least one adversarial pass is required; cap three per PR in aggregate; every pass
   beyond the first declares its trigger in the transcript **before** dispatch. Effort
   cannot be set per dispatch (the Agent tool exposes model, not effort), so escalate by
   dispatching `dev-workflow:fresh-verifier-high` in place of `fresh-verifier` — model may
   still be overridden per dispatch — rather than counting it as an extra verifier
   instance beyond what this policy already allows.
3. **Routine** — everything else: small, low-blast-radius changes (≤3 files, ≤~150
   lines, none of the sensitive surfaces above). A single code-review pass is enough.

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
