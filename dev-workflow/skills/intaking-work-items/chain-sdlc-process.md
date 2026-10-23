# sdlc-process chain — step 6 of intaking-work-items

Read when SKILL.md reaches step 6 with sdlc-process installed; it ends by returning to SKILL.md
step 7 (Verify). sdlc-process is the only chain: it owns the spec, ticket and implement skills,
and this file only says what intake hands them and checks afterwards.

**Piece mode.** In piece mode ([piece-mode.md](piece-mode.md)) that file wins wherever it differs
from this one: no push or PR, no new work branch, the piece branch from the handoff prompt.

## Attended only

Every user gate is answered live: sdlc-process's readiness and publication gates, and step 8's push
and draft PR, each need the user's confirmation. Policy review is not a user gate (see **Entry**).

## Precondition

The Sidkik `sdlc-process` plugin must be installed: the skill `sdlc-process:sdlc-process` is
available. If it is not, say so and offer **Skip** (SKILL.md step 6) — no silent fallback to
another chain.

Its skills share names with `mattpocock-skills` (`to-spec`, `to-tickets`, `tdd`, `code-review`, …).
**Always use the `sdlc-process:` prefix**, in every invocation and every instruction you pass on.
Load every skill through the `Skill` tool yourself. The bundled `sdlc-process:implement` says "Use
/tdd" and "use /code-review": tell the agent to load `sdlc-process:tdd` and
`sdlc-process:code-review` via the `Skill` tool, and never ask the user to type either.

If the ticket is Jira-only, warn the user once: sdlc-process tracks owning work on GitHub, so expect
it to ask about or hold on ownership and readiness; the user decides each.

## Entry

Every flow skill intake loads (`grill-with-docs`, `wayfinder`, `to-spec`, `to-tickets`,
`implement`) goes through the entry: load `sdlc-process:sdlc-process` with the `Skill` tool, then
`sdlc-process:orchestrator` — do not invert the order — once at the start of step 3 (or at resume,
if the run starts later), and again at each new session. Reload the orchestrator at the start of
any session that dispatches agents and before each dispatch wave. Intake states which flow it
expects the entry's situation table to select (step 3: "Bounded repo-backed idea"; wayfinder:
"Uncertainty exceeds a session"; stage 4: "Resolved intent/design"; stage 5: "Authorized delivery
assignment"); if the entry selects another flow, relay that to the user rather than forcing
intake's. Intake's stage gates stay; the entry does not replace them.

**Policy review** is an independent assessment by a separately assigned agent
(`sdlc-process:sdlc-policy-reviewer`, via `sdlc-process:sdlc-policy-review`), never a user gate and
never skippable. Obtain it, supplying exact artifacts, at every checkpoint boundary the entry's
contract names — in this flow at least:
- publishing the spec or tickets;
- starting implementation (each `implement-spec` wave, or one assessment that explicitly covers them);
- handing the candidate to code-review;
- pushing and opening the draft PR, as one publication sequence;
- marking the PR ready, closing tickets, or transitioning Jira at close-out;
- reassessment after any hold is resolved (not a new "go").

The user's role is resolving a hold or recording a permitted exception, which the entry keeps on
record as a missed checkpoint. Intake never marks its own checkpoint passed.

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
   with main (the `review base`) in the Run log. As the last action of this step, run
   `${CLAUDE_PLUGIN_ROOT}/scripts/review-ledger.sh link branch:<ticket-branch> plan:<ticket>`
   so any Codex rounds already counted under the ticket carry over.
2. **Handoff.** Hand the entry (already loaded, see **Entry**; load it now if not, and
   `sdlc-process:orchestrator` after it — do not invert the order) one brief containing:
   - the ticket key and URL;
   - the path `docs/specs/<KEY>-requirements.md` as THE source for the spec and the work record;
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
   skip the stage, or cancel.
   Never answer a sdlc-process gate on the user's behalf. A resolved policy hold is followed by
   reassessment, not a new "go". Record each hold and its resolution in the Run log.
4. **Spec and tickets — the plan stage.** Each output is published to the tracker; record its link
   in **Chain artifacts** so the next stage reads a pointer, not the conversation. Recommend a
   fresh session between this stage and stage 5 to keep context small: load `sdlc-process:handoff`
   with the `Skill` tool to produce the handoff.
   - `sdlc-process:to-spec` synthesizes the spec from the requirements doc, the grilling outcome
     and the settled AC list. After it publishes, read the issue back: every active AC is
     reflected, and no deferred, skipped, or out-of-scope AC appears as in scope (extra user
     stories are fine).
   - `sdlc-process:to-tickets` decomposes the spec. Under sdlc-process, decomposition means GitHub
     issues (its bundled tracker doc applies regardless of the target repo; there is no local-file
     fallback and no competing backlog). Run each publication only after the user's per-issue
     confirmation — never publish to GitHub without the user's explicit confirmation, issue by
     issue. If the user declines, or GitHub access is missing, that is a hold: relay it (resolve /
     skip / cancel).
   - **Labels.** The spec issue and every `to-tickets` child issue are
     published without a `ready-for-*` label, in every repo. Where the tracker doc read at step 0
     (e.g. `docs/agents/issue-tracker.md`) defines a refining state, publish in that state;
     otherwise publish with no triage label. Only the readiness gate applies `ready-for-*`.
     This overrides
     the `ready-for-agent` defaults of `sdlc-process:to-spec` and `sdlc-process:to-tickets`
     (`to-tickets` permits it: "unless instructed otherwise").
   - **One slice.** When a spec issue was published and the breakdown `to-tickets` proposes has one
     slice, publish no child issue: the spec issue is the delivery issue. Record
     `tickets: none — one slice` in Chain artifacts. This is not the plan-skip rule: no skip
     warning and no "Intake: plan skipped" line. Check AC coverage against the spec issue, run
     the Full-tier plan pass on the spec issue alone, and take stage 5's "One ticket, or no
     decomposition" route. The delivery issue gets `ready-for-*` through the readiness gate like
     any delivery issue: it has no children, so the board's "parent carries no `ready-for-*`"
     rule does not apply to it. When `to-spec` was skipped, this rule does not apply:
     `to-tickets` publishes its one ticket as the delivery issue, as before.
   - A step-0 repo rule forbidding issues (e.g. "no GitHub issue until the Jira ticket is in a
     sprint") still applies: publication is then a hold, and proceeding needs the step-0 second
     confirmation (Controls).
   - Every ticket cites the `AC-n` it satisfies. Check coverage: every active AC is cited by at least
     one ticket and no ticket cites a non-active AC. Take any gap back to the user.
     With `tickets: none — one slice`, check coverage against the spec issue: every active AC appears
     in it and it states no non-active AC.
   - On Full tier, run the plan pass on the published spec and tickets
     (the spec issue alone with one slice) after `to-tickets` and
     before stage 5 (SKILL.md **Review = tier**); record `plan pass @<revisions>`. The Codex brief's
     `ledger:` line names the repo path only (the ticket branch exists, so the branch key applies).
5. **Implement.** Route by the number of published tickets. With `tickets: none — one slice`, take
   the "One ticket, or no decomposition" route with the spec issue as the delivery issue and its
   scope. The implementer gets the requirements
   doc, the tickets and the settled AC list as the only scope:
   - **One ticket, or no decomposition:** `sdlc-process:implement`, which runs `sdlc-process:tdd`
     then `sdlc-process:code-review`.
   - **Two or more tickets:** `dev-workflow:implement-spec` in intake mode. This is dev-workflow's
     local adaptation of the entry table's "Authorized delivery assignment" row (`implement`,
     `tdd`) for a spec with two or more published tickets; `tdd` and `code-review` obligations are
     carried inside it, and the row's readiness and start checks still apply. Pass the spec issue
     URL, the work branch as the integration branch (in intake mode the work branch IS the
     integration branch; none is created), the AC→test table as the `confirmed seam list`, the
     `review base` and the requirements doc path. A seam not in the table is a stop. Intake mode
     publishes nothing.
   - **Parallel pieces**, below, only when the pieces are long-running and each needs direct user
     interaction; otherwise implement-spec.

   `sdlc-process:code-review` diffs committed trees (`<review base>...HEAD`), so the candidate is
   committed locally on the work branch (unpushed) before each call; if sdlc-process's
   orchestrator first reviews a pinned uncommitted patch ("every build wave gets a conformance
   review before its commit"), that satisfies it too — either way nothing is pushed. Record this
   in the Run log. Re-record the `review base` after any rebase. Pass the `review base`
   AND the path `docs/specs/<KEY>-requirements.md` as the spec to every code-review call. No PR,
   push, ready, close or closing keywords — intake step 8 owns the draft PR (pushing still needs
   the user's go per step 8).

   **Records.** Write a record with its SHA to **Chain artifacts** as stage 5 goes (SKILL.md step
   1, **Resume status**): each ticket `integrated @<sha>`, then `code-review @<sha>`, then on
   Full tier the diff pass, last, as `full-tier diff pass @A (base B)`: the end of stage 5, after
   code-review and before Verify. A Verify fix that changes code re-runs the bounded
   code-review and the bounded re-review here, or the diff pass when eligibility fails, recording
   `bounded re-review @N (A..N): resolved|NEEDS FULL PASS` (SKILL.md **Review = tier**).
   With `tickets: none — one slice`, the `integrated @<sha>` record is written against the spec issue.

   **After the review completes, before Verify:** check the diff and tests against the active AC
   list, and flag back to the user any change that implements a non-active AC.

**Parallel pieces (stage 5 option).** Offer this only when two or more issues are published and
each piece is long-running and needs direct user interaction; ask once, before the hand-off,
whether to use implement-spec (the default) or parallel pieces. Parallel pieces invokes
`dev-workflow:orchestrating-pieces` with the ticket key, the ticket branch, the issue
links and the settled AC list; the orchestrator then owns stage 5 and returns to SKILL.md step 7.
Record the choice in the Run log. Its hand-back contract, which steps 7 and 8 rely on:

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
  - **Skip `to-spec`:** no spec issue, so tickets have no parent and step 8 lists none.
  - **Skip `to-tickets`** is the plan-skip rule: warn once, record it, get an explicit go-ahead.
    The Implement stage still runs, with the settled AC list as the only scope. The PR body states
    "Intake: plan skipped".
- **Cancel:** stop and invoke no further `sdlc-process` skill. Issues already published and any
  sdlc-process records created are reported (link or path each), nothing deleted.
- **Resume:** SKILL.md step 1's **Resume status** suggests where to restart; the doc's **Chain
  artifacts** (work branch, spec issue, published issues, holds, last completed stage) are the
  records it reads. AC rows reopened by the refetch diff invalidate the tickets that cite
  them — regenerate those through `sdlc-process:to-tickets` (again with per-issue confirmation)
  and record the superseded ones. With `tickets: none — one slice` there is no ticket to
  regenerate: an AC reopened by the refetch diff makes intake refresh the spec issue body (a
  per-action confirmed writeback; `to-tickets` does not modify the parent), re-run the
  `to-tickets` breakdown (it may now yield more than one slice and publish children), then repeat
  the coverage check, readiness and, on Full tier, the plan pass. In piece mode the refresh is not
  offered ([piece-mode.md](piece-mode.md) forbids the edit):
  the piece reports STUCK, naming the spec refresh it needs, and resumes once the parent session
  has refreshed the issue. Decomposition never re-runs on a stale spec.
  Re-invoke `dev-workflow:orchestrating-pieces` (it reconciles) only when stage 5 is the
  first incomplete stage and the tracking file at `$(git rev-parse --git-common-dir)/piece-tracking/`
  (`piece-track.sh path` prints it) exists. A finished or cancelled run leaves its tracking file in
  git metadata (cleanup is out of scope).
