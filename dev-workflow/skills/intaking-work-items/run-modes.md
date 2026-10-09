# Run modes

Detail for SKILL.md's `## Run mode`. The mode is recorded in the doc's `**Run mode:**` field.

## Modes

- **`unattended`** (default): after one sitting the run implements, verifies (step 7 (Verify)),
  and ships a draft PR (step 8 (Ship)) without further questions. The user closes out on return.
- **`attended`**: today's behaviour, a user checkpoint between each stage.

Skip on the run-mode question means attended.

## What the sitting settles

The sitting answers every downstream gate in advance. Record each answer in the doc's Run log.

- The approved AC→test table is the seam confirmation `tdd` requires. It names each test's seam
  and what it catches and misses, and is handed to every implementer, on both chains, as the
  confirmed seam list.
- Plan approval answers `plan-implementation`'s commit/push/PR prompt and answers gate 8 of
  `opening-pull-requests`.
- On the mattpocock chain there is no plan approval: an explicit "go unattended?" question after
  the `to-tickets` coverage check is the equivalent go.

The go pre-authorizes exactly two outward actions: pushing the work branch, and opening one draft
PR with `gh pr create --draft` after step 7 (Verify) and the full review chain pass.

Forbidden until the user returns and closes out: marking the PR ready, editing any PR other than
the one intake opened, ticket comments, Jira transitions, closing tickets.

## Preflight

Run while the user is present, before every go: plan approval, the mattpocock go question, and the
plan-skip or chain-skip go-ahead. If any item fails, offer attended.

- Checklist row 14 (Access and environment) is Present.
- Row 9 is Present: the AC→test table is approved. A skipped row 9 means attended only.
- The baseline is green: the full suite and lint pass on the base commit. A red baseline or no
  runnable suite means attended only.
- The permission mode will not stall on prompts. Say so before the user leaves.
- `PushNotification` is available, else the user accepts the fallback (PR body or Run log, plus
  the final message).

## Stop conditions

Stop when any of these holds:

- a check still failing after 2 fix attempts;
- an AC found wrong or untestable;
- work beyond the agreed scope;
- a repo gate or missing access;
- any outward write outside the go's two actions;
- a gate the sitting did not answer, including a seam not in the AC→test table.

Each stop is one of two kinds:

- **implementation blocker** (scope, a wrong or untestable AC, a person-only gap, a missing seam)
  with checks green: run the review chain, push, open the draft PR with the blocker in its body,
  notify. Do this only if every publication gate (repo step-0 rules, `opening-pull-requests`) is
  satisfied.
- **publication blocker** (a repo gate, missing push or PR access, an unanswered publication
  gate) or failing checks: stop locally. Commits stay on the branch, the Run log and final
  message carry the blocker, notify. Nothing is pushed. Repo gates keep step 0's precedence.

Notify with `PushNotification`; if unavailable, use the PR body or Run log plus the final message.

## Run log

Append to the doc's `## Run log` as the run goes: time, step, event, attempt, blocker. On resume,
refetch and diff per Controls in SKILL.md, then continue from the Run log.
