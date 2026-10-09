# mattpocock chain — step 6 of intaking-work-items

Read only after the mattpocock chain is chosen in SKILL.md step 6; it ends by returning to SKILL.md
step 7 (Verify).

## Why the user types each command

`mattpocock-skills` marks `to-spec`, `to-tickets` and `implement` with
`disable-model-invocation: true`. Claude cannot launch them: a `Skill` call to
`mattpocock-skills:to-spec` returns "cannot be used with Skill tool due to
disable-model-invocation. Ask the user to run /mattpocock-skills:to-spec themselves … Do not
replicate this skill's workflow by other means".

So at each stage intake prints the exact command, with its arguments, and the context to give it,
stops, and resumes when the user reports back. The one exception is `implement-spec` in intake
mode, which intake invokes itself (stage 3). **Never replicate these skills' workflows by other
means** — intake does not write the spec, break down tickets, or implement in their place, even
when a stage is skipped.

**Publication gate.** Before the user runs `to-spec` or `to-tickets`, the context intake states
always includes: *"Before publishing, show every final issue title, body and target repo, and
publish only after my explicit yes for each."* Typing the command plus those per-issue yeses is the
user's confirmation for the issues it creates. The same context names every skipped intake step
(e.g. "Intake: gap analysis skipped — requirements not gap-checked").

## Stages

1. **Spec.**
   - *GitHub ticket:* no `to-spec` — the issue is the spec. The expected default offer, still under
     SKILL.md step 5's per-action rule, is a comment on the issue carrying or linking the
     requirements doc and its settled AC list. If the user declines it, the implement handoff
     (stage 3) must carry the settled AC list itself. Record the issue as the spec issue in the
     doc's **Chain artifacts**.
   - *Jira ticket:* `to-spec` synthesizes the spec from the conversation, so first put into context
     the requirements doc's content and path, the Jira key and link, the publication gate, the
     skipped steps, and that the spec's user stories and out-of-scope must match the settled AC
     list (SKILL.md step 6). Then the user types `/mattpocock-skills:to-spec`. After it publishes,
     read the issue back (`gh issue view <N> --repo owner/repo`). `to-spec` writes an extensive
     user-story list, so the check is: every active AC is reflected, and no deferred, skipped, or
     out-of-scope AC appears as in scope — the stories may be a superset. Take any mismatch back
     to the user. Record the issue as the spec issue in **Chain artifacts**, and offer, as a
     confirmed writeback under step 5's rule, a Jira remote link to it.
2. **Tickets — the plan stage.** First state the constraints, with the publication gate and the
   skipped steps: every ticket cites the `AC-n` it satisfies and links the spec issue as its
   parent; only active AC get tickets. Then the user types
   `/mattpocock-skills:to-tickets <spec issue URL>` — `to-tickets` writes each ticket's `## Parent`
   link only when its source is an existing issue. After it publishes, list the tickets
   (`gh issue list` / `gh issue view`) and check coverage:
   - every active AC is cited by at least one ticket;
   - no ticket cites a deferred, skipped, or out-of-scope AC.

   Take any gap back to the user before implementation. Record the ticket list
   (`owner/repo#N` — `AC-n` each) in **Chain artifacts**.

   Then run Preflight ([run-modes.md](run-modes.md)) and ask once
   (`AskUserQuestion`): "`go unattended?`" — stating that the go
   `pre-authorizes exactly two outward actions` (commit/push and the draft PR), with the gate
   mapping from run-modes.md. Record the answer in the Run log.

3. **Implement.** First state the handoff, in both modes: the settled AC list with each AC's
   disposition, and the AC→test table as the pre-agreed seams; build only the tickets for active
   AC (list them); the spec issue — especially an original GitHub ticket whose text predates
   step 3 — is background only; deferred, skipped, and out-of-scope AC must not be implemented.
   - **Intake mode:** invoke the Skill `implement-spec` (bare name, not
     `mattpocock-skills:implement-spec`) with the spec issue URL, "intake mode", and the AC→test
     table as the `confirmed seam list` for every implementer's `tdd` call.
     `intake mode publishes nothing`: no draft PR at its step 3, no ready or close at step 8, no
     closing keywords; it returns the integration branch.
   - **If the Skill call errors** (e.g. `disable-model-invocation`), the chain runs `attended only`
     with today's command: the user types `/mattpocock-skills:implement <spec-url>` (it opens no
     PR). The unedited `implement-spec` is never used, in either mode.

   **After it returns, before Verify:** check the diff and tests against the active AC list, and
   flag back to the user any change that implements a non-active AC.

After stage 3, return to SKILL.md step 7 (Verify).

## Controls on this path

The **Controls** in SKILL.md apply, with these specifics:

- **Skip** at a stage checkpoint follows the whole-step skip rules (warn once, in one line, about
  what the skip loses; record it; continue).
  - **Skip `to-spec`** (Jira): the warning says what is lost — no spec issue, so tickets have no
    parent, `implement` is pointed at the tickets and the settled AC list only, and step 8 (Ship)
    lists no spec issue.
  - **Skip `to-tickets`** is the plan-skip rule: warn once, record it, get an explicit go-ahead.
    The Implement stage still runs — `implement-spec` in intake mode, or the user types
    `/mattpocock-skills:implement <spec issue URL>` on the attended fallback; intake never
    implements in their place — with the settled AC list stated as the only scope. The PR body
    states "Intake: plan skipped".
- **Cancel:** stop, and do not prompt the user to type any further command. Issues already created
  by commands the user ran are reported (`owner/repo#N` each), not deleted.
- **Resume:** the doc's `Chain:` field and **Chain artifacts** (spec issue, ticket list, last
  completed stage) record where the chain stopped. After the usual refetch-and-diff, restart at
  the first incomplete stage. AC rows reopened by the diff invalidate the tickets that cite them:
  list those tickets, and before implement either the user re-runs
  `/mattpocock-skills:to-tickets <spec issue URL>` for the affected AC, or intake offers a
  per-action, step-5-style edit to each affected issue. Record superseded tickets in
  **Chain artifacts**.
