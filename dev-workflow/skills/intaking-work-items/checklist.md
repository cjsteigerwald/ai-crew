# Intake gap checklist

Rate each row **Present / Vague / Missing** with a one-line reason that cites where in the ticket
the evidence is (description, AC field, comment author + date, linked page). Present the result in
this shape:

| # | Area | Rating | Reason (with source) |
|---|---|---|---|
| 1 | Story | Present | Description ¶1: "As an on-call engineer, I want …, so that …" |
| 4 | Acceptance criteria | Vague | AC field: "alerts work correctly" — no observable outcome |

## Rows

| # | Area | Present means | Typical Vague / Missing signal |
|---|---|---|---|
| 1 | **Story** | Who it is for, what they get, and why it matters — stated, not inferable | Title-only ticket; a solution with no problem; "why" missing |
| 2 | **Scope — in** | The concrete behaviours, components, or environments this ticket changes | "Improve X"; scope implied only by the title |
| 3 | **Scope — out** | What is explicitly *not* included, especially the nearby work a reader would assume | No out-of-scope line at all — the most common Missing row |
| 4 | **Functional requirements** | Each behaviour the change must have, one per line | Requirements mixed into prose; only the happy path |
| 5 | **Non-functional requirements** | Performance, security, availability, compliance, cost, or observability expectations — or an explicit "none beyond current" | "Fast", "secure", "scalable" with no number or check |
| 6 | **Acceptance criteria** | Every AC testable as written: Given/When/Then, or a command plus its expected output; each maps to a requirement | "Works", "handles errors", "is documented"; AC that restate the title |
| 7 | **Dependencies, blockers, gates** | Upstream tickets, approvals, access, environments, or repo gates named with their current state | A "depends on" link whose state nobody checked; implicit access needs |
| 8 | **Definition of done** | What must be true beyond the AC to close it: merged, deployed where, docs updated, ticket transitioned | Done = "PR merged" when the work is only real once deployed |
| 9 | **Test plan** | How each AC will be verified: automated test, manual check, or live command — and where it runs | No test plan; "QA will test"; an AC with no way to observe it |
| 10 | **Risks** | Known failure modes, blast radius, rollback path for anything that touches running systems | Production-touching change with no rollback or risk line |
| 11 | **Open questions in comments** | Every question raised in the comment thread has an answer | A comment question with no reply, or a reply that changed scope without updating the description |
| 12 | **Sizing and sprint status** | Estimate set per the team's convention; sprint/milestone matches the intent to start now | Unestimated; not in a sprint while the repo requires one before work starts |
| 13 | **Contradictions** | No conflict between any two sources: Jira vs GitHub equivalent, description vs comments, a field vs the body | Description says "retain 30 days", a later comment says "90 days"; AC field and description list different AC |

## Rating rules

- **Present** needs evidence in the ticket or its linked sources. Your own reasonable guess is a
  proposal for step 3, not a Present.
- **Vague** — the area is addressed but cannot be checked or acted on as written.
- **Missing** — not addressed in any fetched source (description, fields, comments, links).
- A row the user rules out of scope or defers stays in the table with that status and the user's words.
- **Contradictions block the gate.** Row 13 lists each conflict with both statements and where
  each lives. Every area a conflict touches is at best **Vague** — never Present — until the user
  resolves or defers it; the decision log records both statements and the resolution.
- Only the primary item and confirmed **equivalent** linked items supply requirements and AC. A
  parent, dependency, or related item informs rows 1, 2 and 7 but never row 6.
- Rows 7 and 12 can be **blockers** rather than gaps: an unmet gate is reported and stops the work;
  it is not something a clarifying answer can close.
