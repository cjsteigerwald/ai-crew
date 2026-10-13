# Readiness

Detail for SKILL.md's readiness step and for the partner brief's step 1. An issue is ready when a
partner can build it without asking the user anything the issue should have answered. This is the
mini-intake checklist; every issue needs all of it.

## Checklist

1. **Story.** The issue states a story: who needs what, and why, in one or two sentences.
2. **Acceptance criteria.** Observable, testable criteria. Each one can be checked by a test or a
   command; "works well" is a gap.
3. **Test approach.** How each criterion is tested (the seam and the kind of test), or
   a stated reason none is needed, written `tests: n/a — <why>`. A bare "n/a" is a gap.
4. **Test command.** The one command that runs the issue's tests, recorded in the ledger's
   `testCmd`. If the issue has no tests, the test command is the issue's stated check.

A gap is any item that is missing, vague, or contradicted by the issue's blockers or by the code.

## Up-front mode (coordinator)

Run once, before any launch, for every issue in the ticket's set.

1. Check every issue against the checklist.
2. Collect all gaps and ask the user in one sitting, as one batch grouped by issue. Do not drip
   questions across the run.
3. Write each answer back to the issue's record: the requirements doc and the ledger's `ac` and
   `testCmd`.
4. Close every gap before any launch. An issue with an open gap blocks the run; do not launch the
   rest and leave it for later.

## Partner re-check mode (partner)

Run as step 1 of the partner flow, in the partner's worktree, against the current code.

1. Re-read the issue and the recorded acceptance criteria, test approach and test command.
2. Check them against the code as it is now. Earlier merged work may have changed what the issue
   needs: a file moved, a function now exists, a criterion is already met.
3. Re-check, then ask only about what changed. Do not repeat questions the up-front sitting
   settled. If nothing changed, ask nothing.
4. Send `STARTED #<n> gen=<g>` once the check passes. If the issue cannot be made ready, send
   `STUCK` with the gap as the reason.
