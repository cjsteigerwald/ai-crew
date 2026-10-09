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
| 9 | **Test plan** | The AC→test table is filled for every active AC (AC-n → kind: unit / integration / live read / person-only → seam, the public interface the test goes through → what it catches and misses → test name → location) and each AC is tagged `agent-verifiable` or `person-only`. This table is what step 4 approves as the `tdd` seam confirmation | No test plan; "QA will test"; an AC with no way to observe it |
| 10 | **Risks** | Known failure modes, blast radius, rollback path for anything that touches running systems | Production-touching change with no rollback or risk line |
| 11 | **Open questions in comments** | Every question raised in the comment thread has an answer | A comment question with no reply, or a reply that changed scope without updating the description |
| 12 | **Sizing and sprint status** | Estimate set per the team's convention; sprint/milestone matches the intent to start now | Unestimated; not in a sprint while the repo requires one before work starts |
| 13 | **Contradictions** | No conflict between any two sources: Jira vs GitHub equivalent, description vs comments, a field vs the body | Description says "retain 30 days", a later comment says "90 days"; AC field and description list different AC |
| 14 | **Access and environment** | The agent can run the suite and reach every environment, credential, and cloud read the checks need, each named with how it was confirmed | "Needs prod access" unchecked; tests that only run in CI |

## Rating rules

- **Present** needs evidence in the ticket or its linked sources. Your own reasonable guess is a
  proposal for step 3, not a Present.
- **Vague** — the area is addressed but cannot be checked or acted on as written.
- **Missing** — not addressed in any fetched source (description, fields, comments, links).
- A row the user rules out of scope, defers, or skips stays in the table with that status and the
  user's words.
- **Contradictions block the gate.** Row 13 lists each conflict with both statements and where
  each lives. Every area a conflict touches is at best **Vague** — never Present — until the user
  resolves or defers it; the decision log records both statements and the resolution.
- **Row 13's own rating:** **Present** = the sources were cross-checked and no conflicts were
  found, or every conflict was resolved; **Vague** = at least one conflict is unresolved;
  **Missing** = the sources were not cross-checked.
- Only the primary item and confirmed **equivalent** linked items supply requirements and AC. A
  parent, dependency, or related item informs rows 1, 2 and 7 but never row 6.
- **A generic remote link is not identity evidence.** An item counts as equivalent only if the link
  type, the link text, or the item itself asserts same-work ("mirrors", "tracked in", a sync link
  type, the same key in the title), or the user confirms it. Otherwise it is related context.
- Row 14 unmet or skipped ⇒ `unattended unavailable`; offer attended.
- Rows 7 and 12 can be **blockers** rather than gaps: an unmet gate is reported and stops the work;
  it is not something a clarifying answer can close.
