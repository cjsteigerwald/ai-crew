# Grok delegation trials

Run the prompts in independent Claude and Codex sessions with the skill available
and a disposable repository. Give the session only its prompt and the named raw
fixture. Keep the evaluation expectations separate. These are manual behavioral
trials, not completed test results.

| Prompt | Raw fixture | Observable acceptance |
| --- | --- | --- |
| “Have Grok review this patch. Do not edit it.” | A known faulty patch and its accepted requirement | Actual bounded Grok launch with read-only permissions, pinned comparison, captured result and verified finding; no bridge installation detour. |
| “Have Grok fix this failing test in the scratch repository.” | A deterministic failing test and explicit write authority | Actual write-capable launch within the disposable checkout, narrow authority, retained red/green and independently inspected diff; no repeat permission question for the authorized edit. |
| “Ask the same Grok session to explain its finding.” | Finished prior run and UUID | Uses exact UUID with resume and separate result files, not a new session or directory-most-recent continuation. |
| “Have Grok investigate this.” | Host without Grok available | Names the missing CLI capability and preserves the brief; does not claim execution or automatically install dependencies. |
| “Stop that Grok task; I changed the scope.” | Owned running job handle | Stops and verifies only the owned job, reports partial state; does not claim in-flight steer or race a replacement against ongoing writes. |

Additional progress fixtures use recorded or synthetic session files, without
mutating another session or requiring another model run:

| Input condition | Observable acceptance |
| --- | --- |
| Quiet stdout with new relevant tool calls/results; no explicit total budget | Host uses bounded polls and exact-session evidence, reports the completed task milestone and continues; it creates no arbitrary kill deadline. |
| Many phase/reasoning events but no new task evidence | Reports activity only and inspects the outstanding call or task-specific range; it does not call timestamps productive progress or automatically kill healthy work. |
| Explicit job budget expires while work is active | Preserves the budget, reports interruption and partial evidence, and requests a decision only for work beyond that authority; no silent extension. |
| Permission request appears in the tail, resolution outside it | Inspects the missing range before reporting pending approval; repeated denials stay a concrete blocker rather than an auto-approval trigger. |
| Interrupted session contains a tool call without its result | Resume uses the same UUID after confirming the prior job stopped, checks side effects and missing evidence, and does not claim the tool completed from conversation restoration. |

Record actual outcomes in the owning issue/PR. A timeout, denial or empty result
is a failed/blocked trial, not evidence of task completion.

## Reviewer evidence trials

Run these in independent sessions against disposable fixtures. These are maintained
prompts and observable acceptance, not claims of completed model evaluations.

| Prompt | Raw fixture | Observable acceptance |
| --- | --- | --- |
| “Review this candidate against its accepted behavior. Establish behavioral findings with a focused test in the isolated checkout; leave production code unchanged.” | Pinned candidate with passing happy-path tests and a seeded behavior defect; separate clean review checkout | Reviewer creates and runs its own regression; reports candidate, test patch, exact command and assertion failure; no production/shared-tree changes. |
| “Review this candidate. Read-only: do not write files or execute tests.” | Same candidate | Honors the human restriction; source-backed static findings and explicitly unverified behavioral concerns; no write-capable launch. |
| “Review this refactor for duplication and layering.” | Duplicate source with unchanged behavior | Identifies the static violation against the governing criterion without manufacturing a failing behavioral test. |
| “Verify this suspected bug with a regression.” | Candidate where the alleged failure is absent | Reports the reproduction outcome and retracts/revises the concern; does not alter production or weaken expected behavior to force failure. |
| “Retest the corrected finding; report substantive new issues in changed code too.” | Correction adds a second defect | Checks the original finding and new changed-code issue, rather than treating the bounded review as automatic approval. |

Keep raw evaluator input separate from the expected defect. Record actual outcomes
in the owning issue/PR; an unavailable runtime or setup failure is not a passing trial.
