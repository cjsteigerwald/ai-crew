# sdlc-process chain — step 6 of intaking-work-items

Read only after the sdlc-process chain is chosen in SKILL.md step 6; it ends by returning to SKILL.md
step 7 (Verify).

**Piece mode.** In piece mode ([piece-mode.md](piece-mode.md)) that file wins wherever it differs
from this one: no push or PR, no new work branch, the piece branch from the handoff prompt.

## Attended only

Every gate is answered live: sdlc-process's readiness, policy-review and publication gates, and
step 8's push and draft PR, each need the user's confirmation.

## Precondition

The Sidkik `sdlc-process` plugin must be installed: the skill `sdlc-process:sdlc-process` is
available. If it is not, say so and re-ask the chain question without sdlc-process — no silent
fallback to another chain.

Its skills share names with `mattpocock-skills` (`to-spec`, `to-tickets`, `tdd`, `code-review`, …).
**Always use the `sdlc-process:` prefix**, in every invocation and every instruction you pass on.

If the ticket is Jira-only, warn the user once: sdlc-process tracks owning work on GitHub, so expect
it to ask about or hold on ownership and readiness; the user decides each.

## Authority

Intake supplies evidence and surfaces holds. It does not pre-answer or bypass sdlc-process's
readiness, policy-review or publication gates.

- Build authority for this ticket's active AC is granted.
- **No publication approval is granted.** Every outward action sdlc-process proposes (GitHub issue,
  label or comment, `to-spec` publication, writes to `sidkik/planning` or another repo, Jira writes,
  PR, push) needs the user's explicit per-action confirmation at the time. Intake never creates an
  issue or ticket on its own.

## Stages

1. **Work branch.** Before handoff, create or check out the work branch (e.g. `<key>-<slug>` from
   main, or the repo's convention from step 0) — never main. Record the branch and its merge-base
   with main (the `review base`) in the Run log.
2. **Handoff.** Invoke `sdlc-process:sdlc-process` via the Skill tool; it loads
   `sdlc-process:orchestrator` itself — do not invert the order. Pass one brief containing:
   - the ticket key and URL;
   - the path `docs/specs/<KEY>-requirements.md`, stated as THE spec and the work record's source;
   - the settled AC list with each AC's disposition (SKILL.md step 6) and the deferred-gap list —
     deferred, skipped, and out-of-scope AC must not be implemented;
   - the AC→test table as the pre-agreed seams (the `confirmed seam list` for every `tdd` call);
   - every skipped intake step (e.g. "Intake: gap analysis skipped — requirements not gap-checked");
   - the work branch and the `review base`;
   - the authority statement above, restated.

   Supply the requirements doc, gap table and Step 5 writeback record as readiness and policy-review
   evidence; do not claim they satisfy sdlc-process's controls on its behalf.
3. **Holds.** When sdlc-process holds (missing owner, readiness evidence, policy reviewer) or asks a
   question, relay it to the user verbatim with options: resolve it (the user answers or provides),
   switch chain (back to SKILL.md step 6 chain choice), or cancel.
   Never answer a sdlc-process gate on the user's behalf. Record each hold and its resolution in the Run log.
4. **Tickets — the plan stage.**
   - `sdlc-process:to-spec` is skipped by default (the requirements doc is the spec) unless the user
     explicitly confirms publishing one.
   - Under sdlc-process, decomposition means GitHub issues published by `sdlc-process:to-tickets`
     (its bundled tracker doc applies regardless of the target repo; there is no local-file
     fallback and no competing backlog). Run it only after the user's per-issue confirmation —
     never publish to GitHub without the user's explicit confirmation, issue by issue. If the
     user declines, or GitHub access is missing, that is a hold: relay it (resolve / switch chain
     / cancel), or the user may take **Skip `to-tickets`** under the plan-skip rule.
   - A step-0 repo rule forbidding issues (e.g. "no GitHub issue until the Jira ticket is in a
     sprint") still applies: publication is then a hold, and proceeding needs the step-0 second
     confirmation (Controls).
   - Every ticket cites the `AC-n` it satisfies. Check coverage: every active AC is cited by at least
     one ticket and no ticket cites a non-active AC. Take any gap back to the user. Record the
     published issue links (each with `AC-n`) in **Chain artifacts**.
5. **Implement.** First pass the HARD GATE below (two or more open published issues need the
   `Implementation:` Run-log line before anything is implemented). The router is expected to select
   `sdlc-process:implement` → `sdlc-process:tdd` → `sdlc-process:code-review` after its readiness/start checks (intake does
   not dictate the sequence); always prefixed. Give `implement` the requirements doc (and
   tickets, if any) and the settled AC list as the only scope.
   `sdlc-process:code-review` diffs committed trees (`<review base>...HEAD`), so the candidate is
   committed locally on the work branch (unpushed) before each call; if sdlc-process's
   orchestrator first reviews a pinned uncommitted patch ("every build wave gets a conformance
   review before its commit"), that satisfies it too — either way nothing is pushed. Record this
   in the Run log. Re-record the `review base` after any rebase. Pass the `review base`
   AND the path `docs/specs/<KEY>-requirements.md` as the spec to every code-review call. No PR,
   push, ready, close or closing keywords — intake step 8 owns the draft PR (pushing still needs
   the user's go per step 8).

   **After code-review completes, before Verify:** check the diff and tests against the active AC
   list, and flag back to the user any change that implements a non-active AC.

**Pieces by default (stage 5).** With two or more issues published, the default is
`dev-workflow:orchestrating-pieces`, for independent issues and blocked chains alike. The purpose is
intake's context: each issue runs in its own agent, so only short reports come back here. It is
not about running issues side by side, so a blocked chain gains the same. The orchestrator is invoked with the
ticket key, the ticket branch, the issue links and the settled AC list, then owns stage 5 and
returns to SKILL.md step 7.

**Inline is an explicit opt-out.** "Run all issues in this session" is offered only for tiny work
and only when the user chooses it. It is never a silent fallback. If you ask the user, pieces is
the first and recommended option and inline is never first or recommended; if the user did not
choose inline, the answer is pieces. A single published issue stays on the inline path above.

**HARD GATE: `Implementation:` line.** With two or more open published issues, write
`Implementation: pieces` or `Implementation: inline (user chose)` in the Run log before stage 5
implements anything. Do not invoke `sdlc-process:implement` directly unless that line reads
`inline (user chose)`. A missing line, or `pieces`, means stage 5 goes through
`dev-workflow:orchestrating-pieces`. Loading this file is not the gate; the written line is.

The orchestrator's hand-back contract, which steps 7 and 8 rely on:

- The AC of a cancelled issue are deferred in the settled AC list, with the user's reason.
- Rule: closing keywords and Refs cover merged issues only: `Closes` where the repo lets a merge close
  the issue, otherwise `Refs owner/repo#N` (step 8's rule). Cancelled issues are listed as not
  delivered, with their reason.
- The `piece-track.sh summary` table goes into the PR body.
- A `cancel-ticket` outcome returns no hand-back: intake stops at stage 5 and reports (Cancel
  below). It does not continue to step 7.

After stage 5, return to SKILL.md step 7 (Verify).

## Controls on this path

The **Controls** in SKILL.md apply, with these specifics:

- **Skip** at a stage checkpoint follows the whole-step skip rules (warn once, in one line, about
  what the skip loses; record it; continue).
  - **Skip `to-tickets`** is the plan-skip rule: warn once, record it, get an explicit go-ahead.
    The Implement stage still runs, with the settled AC list as the only scope. The PR body states
    "Intake: plan skipped".
- **Cancel:** stop and invoke no further `sdlc-process` skill. Issues already published and any
  sdlc-process records created are reported (link or path each), nothing deleted.
- **Resume:** the doc's `Chain:` field and **Chain artifacts** (work branch, published issues, holds,
  last completed stage) record where the chain stopped. After the usual refetch-and-diff, restart at
  the first incomplete stage; AC rows reopened by the diff invalidate the tickets that cite them —
  regenerate those through `sdlc-process:to-tickets` (again with per-issue confirmation) and record
  the superseded ones.
  Re-invoke `dev-workflow:orchestrating-pieces` (it reconciles) only when stage 5 is the
  first incomplete stage and the tracking file at `$(git rev-parse --git-common-dir)/piece-tracking/`
  (`piece-track.sh path` prints it) exists. A finished or cancelled run leaves its tracking file in
  git metadata (cleanup is out of scope).
