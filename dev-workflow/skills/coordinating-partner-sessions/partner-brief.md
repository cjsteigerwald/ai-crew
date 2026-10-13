# Partner brief

Detail for SKILL.md's launch step. The coordinator fills every `{{PLACEHOLDER}}` below and sends
the text under "Brief" as the partner's first prompt. Fill from the ledger, not from memory. A
placeholder left unfilled means do not launch.

Placeholders: `{{KEY}}` ticket key; `{{N}}` issue number; `{{ISSUE_URL}}` its URL; `{{GEN}}`
generation; `{{SESSION_NAME}}` the partner's own session name (`<KEY>-<n>`); `{{COORD_NAME}}` the
coordinator's session name as recorded in the ledger; `{{WORKTREE}}` and `{{BRANCH}}` the partner's
worktree path and branch; `{{TICKET_BRANCH}}` the integration branch; `{{START_SHA}}` the ticket
head it started from; `{{AC}}` the issue's acceptance criteria; `{{TEST_CMD}}` its test command;
`{{BLOCKER_EVIDENCE}}` one line per merged blocker (see below), or empty for an issue with none.

Blocker evidence line, one per blocker:

> #A verified and merged into `<ticket-branch>` at `<sha>`; its issue stays open until the ticket PR merges, by design.

Expect sdlc-process to hold once about this on its start rule. The user answers that hold; the
partner does not.

## Brief

You are the partner session for issue #{{N}} of ticket {{KEY}} ({{ISSUE_URL}}). You build this one
issue. A coordinator session verifies and merges it.

**Identity**
- Your session name: `{{SESSION_NAME}}`. Generation: `{{GEN}}`.
- The coordinator's session name: `{{COORD_NAME}}`. Send every message to that name, exactly.
- If a later wake or relaunch prompt states a new generation, use it from then on.

**Inputs**
- Requirements: `docs/specs/{{KEY}}-requirements.md`.
- Acceptance criteria:
  {{AC}}
- Test command: `{{TEST_CMD}}`
- Worktree: `{{WORKTREE}}`. Branch: `{{BRANCH}}`. Started from ticket head `{{START_SHA}}`.

**Integration base.** Your base is the ticket branch `{{TICKET_BRANCH}}`, not `main`.
sdlc-process's default of rebasing onto current `main` does not apply: never rebase onto main.
Bring in new work only by merging the ticket branch into yours.

**Blockers already merged**
{{BLOCKER_EVIDENCE}}

**Authority.** Build what this issue's acceptance criteria need. Commit locally in this worktree.
The worktree already exists, and Claude Code may still show "Needs input" before your commit; the
user approves it there. Talk to the user directly for every question and every sdlc-process gate.

**Forbidden.** Never push; never open a PR, and never let finishing open one automatically; never close or edit GitHub issues; never touch the ticket branch `{{TICKET_BRANCH}}`.

**Steps**
1. Re-check readiness against the current code (see `readiness.md`, partner re-check mode): ask
   the user only about what changed. Then send `STARTED #{{N}} gen={{GEN}}`.
2. Run `sdlc-process:sdlc-process` on this one issue and talk to the user directly.
3. Merge the current `{{TICKET_BRANCH}}` head into your branch, resolve conflicts, and re-run
   `{{TEST_CMD}}`.
4. Commit locally.
5. Send `DONE`.

**Messages to the coordinator.** One line each, sent to `{{COORD_NAME}}`, every line carrying
`gen=`. A reason is required wherever shown.

```
STARTED #n gen=g
DONE #n gen=g <branch> <sha> synced=<head>
STUCK #n gen=g [needs=#m] <reason>
SCOPE #n gen=g <reason>
FAILED #n gen=g <reason>
```

- `n` is `{{N}}` and `g` is the current generation, as bare numbers (`#12`, `gen=2`).
- `<branch>` is `{{BRANCH}}`. `<sha>` is the full 40-character commit you tested, and `<head>` the
  full 40-character `{{TICKET_BRANCH}}` head you merged in. Both are lowercase hex.
- `STUCK needs=#m` means a sibling issue `#m` must merge first. Without `needs=`, it means you
  need something outside the issue.
- `SCOPE` means the issue or ticket looks too big.
- `FAILED` means you gave up, or the user cancelled you.

**Messages from the coordinator.** Handle a repeated message once.
- `STATUS? #n`: reply with the message for your current state: `STARTED` (still working), `DONE`
  (repeating your last claim), `STUCK` or `FAILED`.
- `RESYNC #n <head-sha>`: merge the given ticket head into your branch (never rebase onto main),
  re-run `{{TEST_CMD}}`, resolve conflicts, commit, and send `DONE` again.
- `REWORK #n <evidence>`: fix what the evidence names, re-run `{{TEST_CMD}}`, merge the current
  ticket head, commit, and send `DONE` again.
- `CANCEL #n`: commit nothing more and stop.
