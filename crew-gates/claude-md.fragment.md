<!-- crew-gates:start -->
## MANDATORY: Delegation is the default; solo needs a named disqualifier

Enforced by a hook, not by good intentions: `delegation-gate.py` (PreToolUse on
Edit|Write|NotebookEdit) blocks an edit until one of these appears after the last
genuine user message (the window resets on every genuine user message, not once per
task — task notifications don't reset it). It fails open on error, never fires inside
subagents, and is disabled per-session with `CLAUDE_DELEGATION_GATE=off`.

- `dispatching <lane>` — work routed to a subagent lane. The lane must be NAMED, and the
  token must be line-initial or arrow-preceded:
  `dispatching claude-crew:claude-scout` / `independent/mechanical -> dispatching claude-crew:claude-implementer-haiku`.
  Rejected: the word in passing prose, `dispatching 2 scout lanes`, `dispatching a worker`.
- `solo: D<n>` — kept inline, line-initial or arrow-preceded (quoting it in prose does not
  count), citing ONE disqualifier:
  - **D1** single file, under ~40 changed lines
  - **D2** files share mutable state or a contract changing in this task
  - **D3** needs live cloud reads (kubectl/az/aws/gcloud/terraform) interleaved with edits
  - **D4** needs a user decision mid-task

Also accepted: a Bash tool call whose command is `:` (surrounding whitespace ignored)
whose `description` is the token (e.g. `solo: D1`) and whose result is NON-ERROR, emitted
as its own tool call, with the edit made in a LATER step, after that result returns. A
classification in the SAME message as the edit is not yet visible to the gate — this
applies to the text path too: put it on the first line of your first message and make the
edit in a later step.

Classify once after every genuine user message (task notifications don't reset this) —
first line of your first message (edit later), or the Bash `:` marker as above. Free-text
justification is NOT accepted — "cohesive", "interdependent", and "faster inline" are not
disqualifiers unless they reduce to D2 with the shared contract named.

Do not re-derive the cost tradeoff — it is settled. Inline work is paid once now AND
re-read on every later turn; a lane's tool output and reasoning never enter this context.

The live routing table (which lane for which task shape) and the evidence rules are
injected into every turn by `routing-table.py`. They are deliberately NOT duplicated
here — this file is always in context, so repeating them costs twice.

**Test clause:** if the task adds or changes public behavior, the classification line
also states the test plan — "tests: <what will be authored>" or "tests: n/a — <why>".
Applies to solo and delegated work alike.

**Read budget (second hook):** `read-budget-gate.py` (PreToolUse on Read|Grep|Glob|Bash,
main session only) blocks bulk reading since the last genuine user message: after 3 read
calls whose output exceeded ~1.5 KB (parallel calls included), or ~20 KB of read output
in total; a `Read` of a file over the cap needs `offset`/`limit`. A `solo: D<n>`
classification raises that to 10 calls / 80 KB; `dispatching` does not — the lane reads,
not you. Not counted as calls once their result lands: small-output reads (`grep -c`,
short `ls`) — parallel ones each hold a slot until then, so batch them into one command
— memory files, files under 4 KB, and re-reads of files successfully edited in the
window (their bytes still count). Never gated: `git diff`/`git status` (diff inspection
of delegated work is mandatory) and live cloud reads (kubectl/az/aws/gcloud/terraform);
any read segment in a Bash chain counts. Subagents are never gated. Off switch: relaunch
with `CLAUDE_READ_BUDGET=off`. An internal error (including a missing transcript or
ledger failure) prints `read-budget-gate: internal error` and lets the call through —
treat that as a broken gate to fix, not a pass.

## Worker lane ladder

| Lane | Use for |
|---|---|
| `claude-crew:claude-implementer-haiku` | Mechanical, exact-recipe, parallelizable chores (cheapest — prefer for fan-out) |
| `claude-crew:claude-implementer-sonnet` | Routine, well-specified implementation with clear spec |
| `claude-crew:claude-implementer-opus` | Intricate logic, correctness-critical, would need rework at mid-tier |
| `claude-crew:claude-scout` / `claude-crew:claude-reader` | Bounded search / bulk digest (read-side; before the 3rd consecutive grep/cat, delegate) |

Lane names above are the defaults; a repo running crew-gates can rename any lane by
setting `lanes.<key>` in its crew config (see the crew-gates README, § Crew config) —
the routing table and lane-model-gate pick up the rename automatically.

**Model tier rule:** built-ins default to Sonnet via `CLAUDE_CODE_SUBAGENT_MODEL`.
Ceiling for a lane is the frontier tier, reached only by escalation: dispatch a
frontier-pinned lane, or pass `model: opus`, and in either case the prompt's first line
is `escalate: <reason>` so the choice is visible in the transcript. Never pass the
frontier-tier model alias to any dispatch except the configured verifier lane (default
`fresh-verifier`). Enforced
by `lane-model-gate.py` (PreToolUse on `Agent|Task`): it denies the frontier tier for any
lane other than the verifier, and denies `model: opus` when the prompt has no
`escalate:` line. Tier aliases only, fails open, off switch `CLAUDE_LANE_MODEL_GATE=off`.

Every dispatch names its lane with a one-line justification.

## Review tier — check in order, first match wins

Tier review effort to blast radius:

1. **Exempt** — pure docs with no behavioural or factual load, typo/comment-only edits.
   No review chain needed.
2. **Fact-asserting decision docs** — a design doc whose decisions assert facts about
   existing code, infra, or running environments. Full chain: an independent verifier and
   an adversarial pass check its claims against source and live state.
3. **Full chain** — touches infra-as-code, CI/CD, auth/credential handling,
   hooks/settings that gate behavior, or agent/command/skill definitions; OR more than a
   few files changed; OR more than roughly 150 changed lines; OR cross-cutting/
   architectural. Dispatch an independent verifier and an adversarial reviewer in ONE
   message, on the plan and on the diff before opening a PR.
4. **Routine** — everything else: small, low-blast-radius changes. A lighter single-pass
   review suffices.

When in doubt between Routine and Full, run Full. Re-check the tier against the ACTUAL
diff at pre-PR time: a Routine-planned change that grew past the thresholds gets Full then.
<!-- crew-gates:end -->
