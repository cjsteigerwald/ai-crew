# Anti-patterns

Each with its failure mode and why it happens. The "why" column matters more than the
list: these are not carelessness, they are what competent execution drifts into. Every one
of them feels like the right call at the moment it is made.

## Contents

- [Capture](#capture)
- [Process](#process)
- [Storage](#storage)

## Capture

| Anti-pattern | Failure mode | Why it happens |
|---|---|---|
| Adversarial agent sees synthesis reasoning | It rationalizes the conclusion instead of attacking it; the pass becomes theater | Passing full context feels helpful, and withholding feels like sabotaging your own reviewer |
| Preferences passed to gathering agents as constraints | Every lane retrieves toward the preferred answer; the bias is invisible because each lane looks rigorous | Preferences and constraints sound alike in transcript, and the split is extra work |
| Asymmetric queries | The favored option gets researched harder, so it has more supporting evidence by construction | Curiosity follows interest; you search more where you expect to find |
| Padding the two-source minimum with T4 or sponsored content | A claim reads as corroborated when it rests on one vendor's marketing restated twice | The quota is a number, and T4 content is abundant and easy to find |
| Softening a sourced finding after pushback | The document now reflects the user's preference wearing evidence's clothes | Disagreement is socially costly, and hedging language is always available |
| Producing an unrequested recommendation | The positions collapse into a verdict, and the user's own judgment is pre-empted | Recommending feels like completing the job; leaving it open feels like dodging |
| Cosmetically distinct positions | Four options that all bet on the same thing look like real optionality and aren't | Vendors are easy to enumerate; underlying bets are hard |
| Reporting an empty dissent log without flagging it | A captured run is indistinguishable from a genuinely confirming one | An empty section looks like nothing to report rather than a warning sign |
| Storing a prior or preference in the register | The next run's sweep reads it back as a T0 evidence record and relays the user's own leaning to every lane as evidence. The seal holds on run 1 and breaks on run 2 | The register is the natural home for durable run state, and the sweep is designed to read all of it — two correct designs combining into a leak |
| Letting a depth downgrade delete Phase 5 | The one pass designed to attack the user's leaning is removed by the user, through a sanctioned door | Depth reads as a cost dial, so scaling it down feels like thrift rather than like disarming a control |
| The orchestrator scoring its own rebuttals | It dismisses the strongest objection against its favored position and still truthfully reports that a rebuttal round occurred | Whoever wrote the rebuttal is closest to the argument and feels best placed to judge it |
| Locking the candidate set before challenging it | No amount of symmetric retrieval recovers an option never admitted; every later audit runs on the wrong set | The candidate set feels like input to the research rather than its first and most consequential output |
| Claiming structural prevention while the orchestrator owns the choke points | The ceremony produces confidence proportional to its cost, not to its actual guarantee | Elaborate process feels like proof; the more steps, the more prevented it seems |

## Process

| Anti-pattern | Failure mode | Why it happens |
|---|---|---|
| Skipping Phase 0 | Re-researching a settled decision, or contradicting one without knowing it exists | The external question feels more interesting than the internal search |
| Front-loading a questionnaire | The user answers cheaply and generically; later questions can't build on earlier answers | Batching feels efficient and respectful of the user's time |
| Treating "I don't know" as a blocker | The run stalls, or the same question gets re-asked in different words | Uncertainty reads as a gap to close rather than a state to record |
| Asking only about what the user raised | The decisive consideration never enters the frame because nobody named it | The user's framing is the path of least resistance |
| Stating a version, limit, or price from memory | A confidently wrong number propagates into a cost model | Model memory is fluent and feels like knowledge |
| Confident recommendations on thin evidence | Confidence language outruns the source base and gets believed | Hedged prose reads as weak; the confidence rubric is extra work |
| Silently expanding scope | The run balloons, the original question goes unanswered, and nobody chose the expansion | Adjacent dependencies are genuinely relevant, so pulling them in feels correct |
| A mandatory rule with no field to record it | The rule is unenforceable and unauditable — a dead rule that reads as a control | Rules are written in prose and schemas are written elsewhere; nobody checks that one can carry the other |
| Hardcoding a session-scoped tool or server ID | The agent reports the capability as unavailable forever, indistinguishable from a real auth failure | The ID is right there in the current session and looks like a stable address |
| Abandoning a run without stamping the artifact | A half-finished document carries tiered evidence, citations, and confidence labels — every visual marker of rigor, none of the adversarial testing | Nothing about a partial artifact looks partial; the markers of rigor accrue before the checks that earn them |
| Treating a one-time gate as covering the whole run | Sensitivity is a property of what the research finds, not only of what was asked; the gate passes at the door and the run turns sensitive after it | Gates are naturally placed at entrances, and re-asking feels like friction |

## Storage

| Anti-pattern | Failure mode | Why it happens |
|---|---|---|
| Writing outside confirmed paths | Files scatter; the register stops being the index of what exists | A phase needs a file the agreement didn't cover, and asking again feels like friction |
| Open-ended "where should this go?" | The user does the discovery work the skill was supposed to do | Enumerating real candidates costs tool calls |
| Re-interviewing on storage | Every run repeats a settled decision, training the user to skim the phase | The register holds the answer, but reading it is a step |
| Near-duplicate domain slug | The register fragments; two folders hold half the constraints each and neither is complete | Alias matching is skipped when a new slug is easier to name |
| Sensitive research accumulating unnoticed | NDA pricing or security posture piles up on a corporate VM whose backup and retention policy the user does not control | The VM is the habitual destination and its backup/retention policy is invisible from inside the editor |
| Inlining the full evidence table | The readable document becomes unreadable and nobody reads the positions | Keeping evidence adjacent feels more rigorous |
| Deleting a superseded register note | Backlinks break and the reasoning history is gone | Superseded looks like obsolete |
| Adopting a query-driven index for durable records | The index renders as dead code fences the moment the plugin it depends on is removed | A live query is obviously better than a stale list, right up until the plugin goes away |
