# Piece mode — intaking-work-items for one piece of a larger ticket

Read when the first prompt starts with the line `Piece mode: on`. An orchestrator's handoff
prompt (from `dev-workflow:orchestrating-pieces`) sets it; nothing else does, and the user cannot
switch it on mid-run. The prompt supplies the issue, acceptance criteria, test command, piece
branch, worktree, base branch (the orchestrator's branch), orchestrator session name and depth.

Piece mode narrows intake to one issue. Outside it, nothing in SKILL.md changes.

**Precedence.** Where this file and [chain-sdlc-process.md](chain-sdlc-process.md) differ, piece
mode wins: the chain's push, PR and work-branch-creation steps do not apply, its push and PR
confirmations are never asked, and nothing is pushed.

## What changes

| Intake | In piece mode |
|---|---|
| Primary item | The piece's issue. Its acceptance criteria are the starting AC. Fetch it as step 1 says. |
| Steps 0 to 7 | Run as written, through Verify, attended, against that issue. A gap table with no Vague or Missing row and no contradiction takes step 3's fast path: no questions, and step 4 still writes the requirements doc. Open questions are asked as step 3 says, one at a time, by you, to the user. |
| Chain | Fixed to sdlc-process, per [chain-sdlc-process.md](chain-sdlc-process.md). Step 6.1's chain question is not asked; record `Chain: sdlc-process` in the doc. If sdlc-process is not installed, report `STUCK` with that reason. |
| Doc key | `<repo>-<issue number>` per step 1 (for example `ai-crew-37`), never the ticket key, so sibling pieces do not collide. The doc is `docs/specs/<repo>-<issue number>-requirements.md`. |
| Work branch | The piece branch from the prompt, already created in your worktree. Create no other branch. |
| Review base | The merge-base of the piece branch with the base branch, not with `main`. |
| Requirements doc and run log | Written on the piece branch, committed locally. |
| Step 5 writebacks and the chain's ticket or spec comments | Skipped. Offer one only when the user asks for it in this session, and apply it under step 5's per-action yes. |
| Step 8 Ship | Never run. Hand back instead, below. |
| Step 9 Close-out | Not run. The orchestrator owns it. |

## Reports

Send each one-line report to the orchestrator session named in the prompt, in the formats the
prompt gives. Each is a single line with no tab or other control character:

- `STARTED #N` when you begin.
- `STUCK #N [needs=#M] <reason>` at any stop under **Run log and stops**, or when a chained gate
  cannot proceed. Add `needs=#M` when sibling issue #M must merge first.

## Hand back instead of Ship

After step 7 passes every active AC (or marks it unverified with a reason):

1. Merge the current head of the base branch into the piece branch. Resolve conflicts.
2. Re-run the prompt's test command. A failure is a step-7 failure: fix and re-verify, or `STUCK`.
3. Commit locally.
4. Send `DONE #N <piece-branch> <sha>` with the full 40-character SHA you tested, then stop.

A `RESYNC` request repeats 1 to 4 with the head it names. A `CANCEL` request: send nothing,
commit nothing, end the turn quietly.

## Hard limits

- Never push, never open a PR, never close or edit issues, never move the base branch.
- Other issue or ticket writes (a comment, or the issues `to-tickets` publishes when splitting)
  need the user's yes in this session. Closing or editing an issue is never offered, even with a yes.
- Every question and gate goes to the user directly; the orchestrator relays nothing.

## Splitting the piece

When the piece is several issues, publish them through the chain's `to-tickets` stage under its
per-issue confirmation, then run `dev-workflow:orchestrating-pieces`
with the piece branch as the ticket branch. You remain in piece mode at your own level: your
children's reports come to you, the hand-back above replaces your Ship, and the single `DONE` goes to your orchestrator. At the
depth cap from the prompt you cannot split: work the piece, or report `STUCK` with a scope reason.
