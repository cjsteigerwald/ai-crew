# sdlc-process chain — step 6 of intaking-work-items

Read only after the sdlc-process chain is chosen in SKILL.md step 6; it ends by returning to SKILL.md
step 7 (Verify).

## Precondition

The Sidkik `sdlc-process` plugin must be installed: the skill `sdlc-process:sdlc-process` is
available. If it is not, say so and re-ask the chain question without sdlc-process — no silent
fallback to another chain.

Its skills share names with `mattpocock-skills` (`to-spec`, `to-tickets`, `tdd`, `code-review`, …).
**Always use the `sdlc-process:` prefix**, in every invocation and every instruction you pass on.

## Authority and tracker contract

"Loading a flow grants no authority and answers no human decision." The authority is what the user
gave at intake, and nothing more:

- The user authorized delivery of this ticket. Step 5 confirmed writes are the only tracker writes.
- The tracker is Jira (or the GitHub issue, if that is what was intaken). `sdlc-process` supports
  GitHub only and has no Jira support, so its tracker-writing steps do not apply:
  - **Skip `sdlc-process:to-spec`.** `docs/specs/<KEY>-requirements.md` already is the spec;
    `to-spec` would publish one to GitHub.
  - `sdlc-process:to-tickets`, if decomposition is needed, writes **local ticket files only** —
    never publish to GitHub issues, and never create Jira issues or tickets.
  - Do not prompt the user to run `/setup-matt-pocock-skills`, even if `sdlc-process` suggests it.
  - No ticket creation, no tracker writes beyond what step 5 confirmed.

## Stages

1. **Handoff.** Invoke `sdlc-process:sdlc-process` (the session entry procedure), then
   `sdlc-process:orchestrator` (required before route selection for any multi-agent build), both via
   the Skill tool. Pass one brief containing:
   - the ticket key and URL;
   - the path `docs/specs/<KEY>-requirements.md`, stated as THE spec;
   - the settled AC list with each AC's disposition (SKILL.md step 6) and the deferred-gap list —
     deferred, skipped, and out-of-scope AC must not be implemented;
   - the AC→test table as the pre-agreed seams (the `confirmed seam list` for every `tdd` call; a
     seam not in the table is a stop — report it, never ask or invent);
   - the run mode, and every skipped intake step (e.g. "Intake: gap analysis skipped — requirements
     not gap-checked");
   - the authority and tracker contract above, restated verbatim: delivery of this ticket is
     authorized; **never publish to GitHub** and create no tickets or issues anywhere; local ticket
     files only.
2. **Tickets — the plan stage (only if decomposition is needed).** `sdlc-process:to-tickets`
   from the requirements doc, local files only. Every ticket cites the `AC-n` it satisfies; only
   active AC get tickets. Check coverage: every active AC is cited by at least one ticket, and no
   ticket cites a deferred, skipped, or out-of-scope AC. Take any gap back to the user. Record the
   ticket files (path — `AC-n` each) in **Chain artifacts**.

   Then, in unattended mode, run Preflight ([run-modes.md](run-modes.md)) and ask once
   (`AskUserQuestion`): "`go unattended?`" — stating that the go
   `pre-authorizes exactly two outward actions` (commit/push and the draft PR), with the gate
   mapping from run-modes.md. Record the answer in the Run log. If no decomposition was needed,
   ask this once before stage 3.
3. **Implement.** Route `sdlc-process:implement` → `sdlc-process:tdd` → `sdlc-process:code-review`,
   always prefixed. Give `implement` the requirements doc (and ticket files, if any) and the
   settled AC list as the only scope; pass a `review base` — the merge-base of the integration
   branch with main, settled in the sitting and recorded in the Run log — for every
   `sdlc-process:code-review` call. Nothing is published: no PR, no ready or close, no closing
   keywords — intake's step 8 owns the draft PR.

   **After it returns, before Verify:** check the diff and tests against the active AC list, and
   flag back to the user any change that implements a non-active AC; in unattended mode this is a
   scope stop (run-modes.md § Stop conditions).

After stage 3, return to SKILL.md step 7 (Verify).

## Controls on this path

The **Controls** in SKILL.md apply, with these specifics:

- **Skip** at a stage checkpoint follows the whole-step skip rules (warn once, in one line, about
  what the skip loses; record it; continue).
  - **Skip `to-tickets`** is the plan-skip rule: warn once, record it, get an explicit go-ahead.
    The Implement stage still runs, with the settled AC list as the only scope. The PR body states
    "Intake: plan skipped".
- **Cancel:** stop and invoke no further `sdlc-process` skill. Local ticket files already written
  are reported (path each), not deleted. Nothing is posted anywhere.
- **Run modes:** attended keeps a checkpoint between stages; unattended ends the checkpoints at the
  go, after which only [run-modes.md](run-modes.md) § Stop conditions halt the run.
- **Resume:** the doc's `Chain:` field and **Chain artifacts** (ticket files, last completed
  stage) record where the chain stopped. After the usual refetch-and-diff, restart at the first
  incomplete stage; AC rows reopened by the diff invalidate the ticket files that cite them —
  regenerate those through `sdlc-process:to-tickets` and record the superseded ones.
