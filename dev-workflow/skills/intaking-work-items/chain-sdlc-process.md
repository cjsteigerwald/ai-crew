# sdlc-process chain — step 6 of intaking-work-items

Read only after the sdlc-process chain is chosen in SKILL.md step 6; it ends by returning to SKILL.md
step 7 (Verify).

## Attended only

This chain runs attended: sdlc-process's readiness, policy-review and publication gates need a live
human. If the run mode is unattended, say so once, switch to attended for step 6, and record "Run
mode: attended (sdlc-process chain)" in the Run log. There is no "go unattended?" question here.

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
   - If decomposition is needed, run `sdlc-process:to-tickets`. In a repo with no tracker config,
     instruct it to use its **Local files** mode (`.scratch/<KEY>/issues/NN-<slug>.md`) and do not
     prompt for `/setup-matt-pocock-skills`. In a repo whose tracker config is GitHub, to-tickets
     publishes issues — a publication needing the user's explicit confirmation first, else use Local
     files mode. In all cases, never publish to GitHub without the user's explicit confirmation.
   - Every ticket cites the `AC-n` it satisfies. Check coverage: every active AC is cited by at least
     one ticket and no ticket cites a non-active AC. Take any gap back to the user. Record the
     ticket files or published issue links (each with `AC-n`) in **Chain artifacts**.
5. **Implement.** Route `sdlc-process:implement` → `sdlc-process:tdd` → `sdlc-process:code-review`,
   always prefixed. Give `implement` the requirements doc (and tickets, if any) and the settled AC
   list as the only scope. Commit the implementation candidate to the work branch BEFORE each
   `sdlc-process:code-review` call (its diff is `<review base>...HEAD`), and pass the `review base`
   AND the path `docs/specs/<KEY>-requirements.md` as the spec to every code-review call. No PR,
   push, ready, close or closing keywords — intake step 8 owns the draft PR (pushing still needs
   the user's go per step 8).

   **After code-review completes, before Verify:** check the diff and tests against the active AC
   list, and flag back to the user any change that implements a non-active AC.

After stage 5, return to SKILL.md step 7 (Verify).

## Controls on this path

The **Controls** in SKILL.md apply, with these specifics:

- **Skip** at a stage checkpoint follows the whole-step skip rules (warn once, in one line, about
  what the skip loses; record it; continue).
  - **Skip `to-tickets`** is the plan-skip rule: warn once, record it, get an explicit go-ahead.
    The Implement stage still runs, with the settled AC list as the only scope. The PR body states
    "Intake: plan skipped".
- **Cancel:** stop and invoke no further `sdlc-process` skill. Local ticket files already written
  and any sdlc-process records created are reported (path or link each), not deleted.
- **Resume:** the doc's `Chain:` field and **Chain artifacts** (work branch, ticket files, holds,
  last completed stage) record where the chain stopped. After the usual refetch-and-diff, restart at
  the first incomplete stage; AC rows reopened by the diff invalidate the tickets that cite them —
  regenerate those through `sdlc-process:to-tickets` and record the superseded ones.
