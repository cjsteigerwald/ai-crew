# Requirements doc template

Copy the block below to `docs/specs/<KEY>-requirements.md` in the target repo and fill every
section. A section with nothing to say gets an explicit "None" with a reason — never delete it and
never leave `TBD`. No secrets, tokens, or credential values anywhere in the doc.

```markdown
# <KEY>: <ticket summary>

**Source:** [<KEY>](<ticket URL>)<, [owner/repo#N](<issue URL>) if a confirmed equivalent exists>
**Linked items:** <key or owner/repo#N — equivalent / parent / dependency / related — evidence for the class>
**Fetched:** <YYYY-MM-DD, required — resume diffs comments and changes against this date> — ticket status `<status>`, sprint `<sprint or none>`, estimate `<value or none>`
**Intake by:** <name> with the `dev-workflow:intaking-work-items` skill
**Status:** <Draft | Ready | Cancelled> — <last completed step; skipped steps and what each lost, e.g. "gap analysis skipped — requirements not gap-checked">
**Chain:** <superpowers | mattpocock | — (not yet chosen)>

> Snapshot of the ticket on the fetched date plus the decisions below. If the ticket changes,
> re-run intake for the changed rows rather than editing this doc by memory.

## Story

As a <who>, I want <what>, so that <why>.

## Scope

**In scope**
- <behaviour / component / environment>

**Out of scope**
- <nearby work a reader would assume is included> — <why it is excluded, or the ticket that owns it>

## Requirements

### Functional
- **FR-1** <one behaviour per line>

### Non-functional
- **NFR-1** <measurable expectation, or "None beyond current behaviour">

## Acceptance criteria

Each AC is testable as written and names how it is verified. Plans and PRs cite these numbers.

- **AC-1** (FR-1) Given <context>, when <action>, then <observable outcome>.
  *Verify:* <test name, or `command` → expected output>
- **AC-2** (NFR-1) Running `<command>` returns `<expected output>`.
  *Verify:* <where and when it runs>

## Definition of done

- [ ] All AC above verified with recorded evidence
- [ ] <merged / deployed to … / docs updated / ticket transitioned to …>

## Dependencies and gates

| Item | Kind | State on fetched date |
|---|---|---|
| <ticket / approval / access / repo gate> | blocks / informs | <open, done, unknown> |

## Test plan

<How the AC are exercised: unit/integration tests, manual checks, live commands, and where each runs.>

## Risks

- <failure mode> — <blast radius> — <mitigation or rollback>

## Decision log

| # | Question | Answer | Who / date |
|---|---|---|---|
| 1 | <question asked during intake> | <answer as given> | <name, YYYY-MM-DD> |
| 2 | Contradiction: "<statement A>" (<source A>) vs "<statement B>" (<source B>) | <resolution, or deferred> | <name, YYYY-MM-DD> |

## Deferred and out-of-scope items

| Item | Status | Source | User's words | Gap left open | Follow-up |
|---|---|---|---|---|---|
| <gap or AC> | deferred / out of scope | user-deferred | "<quote>" | <what stays unknown> | <ticket key, or none> |
| <gap or AC> | Skipped by user — <YYYY-MM-DD> | skipped | "<quote>" | <what stays unknown> | <ticket key, or none> |
| <open checklist row> | Skipped by user — step 3 skipped | skipped | "<quote>" | <the row's Vague/Missing reason> | <ticket key, or none> |

## Gap table at skip

<Only if step 3 was skipped after step 2 ran: the final gap table, row by row with its rating and
reason, as it stood when the user skipped. Otherwise "None — step 3 completed, or gap analysis
skipped".>

## Chain artifacts

<Filled in step 6. superpowers: the design doc path and the plan path (or the approved bounded
task list). mattpocock: the spec issue (`owner/repo#N`) and the ticket issues (`owner/repo#N` —
`AC-n` each), plus any superseded tickets. Either chain: **Last completed stage:** <stage, or
"none">. Before step 6: "None — chain not started".>
```

**Stub doc** (the requirements-doc step was skipped): keep only the header lines — Source,
Fetched, Status with "requirements not gap-checked" if gap analysis was skipped, the skipped
steps, and `Chain:` — plus the **Deferred and out-of-scope items** table with every deferred or
skipped AC, the **Gap table at skip** section, the **Chain artifacts** section, and, whenever
step 3 ran, an **Acceptance criteria (settled)** section in this form:

    ## Acceptance criteria (settled)

    - **AC-1** — active — <final text as agreed in step 3>
    - **AC-2** — deferred — <final text> — "<user's words>"
    - **AC-3** — skipped — <final text, or original ticket text if never refined>

Plans, plan-skip implementation, and the PR body use this list and cover only active AC.

On cancel, the single cancel-marker edit (first line plus the Status field) makes the doc's first
line `> Status: CANCELLED at step <n> on <YYYY-MM-DD> — incomplete` and sets the **Status** field
to `Cancelled`.
