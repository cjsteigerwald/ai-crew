# Ledger

Detail for SKILL.md's ledger steps. The ledger is the coordinator's only state. `scripts/ledger.sh`
is its only writer; never edit the JSON by hand and never keep state anywhere else.

## Location and lifetime

- Path: `$(git rev-parse --git-common-dir)/partner-sessions/<KEY>/ledger.json`. Get it, and create
  its directory, with `ledger.sh path <KEY>`. It lives in git metadata (the `git-common-dir`), so
  every worktree of the repository sees the same one.
- Beside it: `lock/` (the run lock; `lock/holder` holds `<session-id> <nonce>`; `lock/write/`
  is the transient write mutex), `takeover/` (transient, present only while a lock is being taken
  over) and `ledger.log` (append-only diagnostics, not state).
- It is never committed and never inside a working tree. What leaves it is `ledger.sh summary`,
  a Markdown table the coordinator puts in the ticket PR body.

## Schema

Top level: `key`, `ticketBranch`, `coordinator` (`name`, `sessionId`), `cap` (3), `canary`
(`pending` or `passed`), `claimSeq` (counter ordering the merge queue), `issues`, `intents`,
`outbox`.

`issues` is an object keyed by issue number as a string. Per issue:

| Field | Meaning |
|---|---|
| `status` | One of the 11 statuses below |
| `gen` | Generation; 0 until first launched |
| `blockers` | In-ticket issue numbers that must be `merged` first |
| `external` | Blockers outside this ticket: `{n, closed}`; satisfied only if `closed` |
| `branch`, `testCmd`, `ac` | Partner branch, the issue's test command, its acceptance criteria |
| `sessionName`, `sessionId`, `sessions` | Current partner session; `sessions` is the history `{gen, name, sessionId}` |
| `worktree`, `startSha` | Partner worktree path; ticket head it started from |
| `claim` | The persisted `DONE`: `{gen, branch, sha, synced, claimSeq}`; null before one |
| `rework`, `resyncs` | Failed-gate count for this generation (budget 3); RESYNCs sent |
| `mergeSha`, `gateResults`, `reason` | Merge result; `{gen, result, text}` per gate; why `failed` or `cancelled` |

`intents` entries: `{id, kind, n, gen, open, outcome, ...}`. `launch` and `relaunch` add
`sessionName`, `worktree`, `branch`, `baseSha`, `prior` (the status to restore if the launch
fails). `relaunch` also adds `priorPid`: the `pid` of the issue's recorded session when the intent
was written (null if absent or ended). `merge` adds `candidateSha`, `expectedHead`.

`outbox` entries: `{n, gen, to, line}`: a coordinator message to send, addressed to a session name.

## Statuses

`pending`, `launched`, `started`, `blocked-on #m`, `done-claimed`, `verifying`, `rework-n/3`
(stored as `rework-1/3`, `rework-2/3`), `resync-requested`, `merged`, `failed`, `cancelled`.

- Live: `launched`, `started`, `done-claimed`, `verifying`, `rework-n/3`, `resync-requested`. Live
  statuses hold a slot (cap 3, via `ledger.sh slots`).
- Terminal: `merged`, `cancelled`.
- Whether a partner waits on the user is read from `claude agents --json` on each wake. It is not
  ledger state.
- "Session ended" means the `claude agents --json --all` row is absent or has no `pid`. A row with
  `state: done` and a `pid` is alive (idle).

## Rules

- **One write.** A status change and everything that must accompany it (the outbox entry, the
  claim, the closed intent, the dependents released) are one atomic write (temp file, then
  `mv -f`). Never split them.
- **Slot rule.** A launch is refused (exit 30) unless a slot is free, every blocker is `merged`,
  every external blocker is closed, and the issue has no open intent. Until the canary has passed,
  only one issue may have been launched.
- **Generation.** A launch or relaunch increments the issue's generation and resets its rework
  count. A wake of a stopped partner keeps the generation (`ledger.sh session` rebinds the name and
  session ID). Every partner line carries `gen=<g>`; a message with any other generation is
  rejected.
- **Intents before side effects.** Record a `launch-intent` (`ledger.sh intent launch|relaunch`)
  before starting a partner, and a `merge-intent` (`ledger.sh intent merge`) before merging. The
  `launch` and `gate` events take the intent ID and close it in the same write. On resume,
  `reconcile` settles each open intent against git and `claude agents --json`. Closed intents are
  never replayed. Pass `intent relaunch` the agents file (`<agents.json>`, last argument) so it
  records `priorPid`: `reconcile` takes an alive row of the intent's session name for the relaunch
  only if its `pid` differs from `priorPid` (the old process still running is not a relaunch);
  otherwise the intent closes as `launch-failed`.
- **Outbox.** `RESYNC`, `REWORK` and `CANCEL` are queued by the write that requires them; send them
  afterwards with `ledger.sh outbox`, which prints `<n>\t<gen>\t<to>\t<line>`. Only one pending
  entry exists per issue: a newer entry supersedes the older one. The one exception: `CANCEL`s to
  two different sessions of an issue (its recorded session and an open intent's) both stay. Only the partner's next `DONE`
  or `FAILED` for that generation clears its `RESYNC`/`REWORK`; a `STARTED`, `STUCK` or `SCOPE`
  leaves it outstanding (resume resends it). A `CANCEL` stays until its session has
  ended (see `json` below).
- **Claims.** A `DONE` is stored in `claim` on receipt, before verification. A repeated `DONE`
  (same issue, generation, sha) is a no-op (exit 10). A `DONE` with a new sha while the issue is
  `done-claimed` or `verifying` is refused (exit 30); the coordinator must surface that to the user.
- **Messages.** `ledger.sh message <ledger> <whole frame>` parses, binds (`from` equals the
  recorded session name exactly, `gen` is current, a `DONE` branch is the recorded branch) and
  applies in one call. A message restating the current state is an idempotent no-op.
- **Sessions.** `ledger.sh session <ledger> <n> <name> <session-id>` rebinds a woken partner. It
  keeps gen and status and retargets pending outbox entries to the new name.
- **Drop and cancel.** `drop` and `cancel-ticket` close the issue's open intents (outcome
  `cancelled`) and queue `CANCEL` to every session of the issue that may still run: its recorded
  session if the issue is live or `failed`, and the session name of an open launch or relaunch
  intent (that session may already run).
- **Resume.** `ledger.sh reconcile <ledger> <agents.json>` settles open intents, returns every
  `verifying` issue to `done-claimed`, drops `CANCEL` entries whose session has ended, and prints
  action lines for the coordinator: `requeue <n>` (a `done-claimed` issue, in claim order),
  `resend <n> <to> <line>` (an outbox entry, verbatim) and `status <n>` (any other live issue:
  send `STATUS? #<n>`).
- **`json` events.** `ledger.sh event <ledger> <n> json <failed|stopped|blocked|done|working>`
  records a `claude agents --json` observation. `failed` fails a working issue. `failed`,
  `stopped` or `done nopid` drops a pending `CANCEL` to the recorded session of a `blocked-on` or
  `cancelled` issue, since that session ended (a `CANCEL` to an open intent's other session stays). A bare `json done` keeps it and exits 10, because `done` with a `pid` is alive.

## Command reference

All take the ledger path (from `path`) as the first argument after the verb, except `path`.

| Call | Does |
|---|---|
| `ledger.sh path <KEY>` | Prints the ledger path; creates its directory |
| `ledger.sh lock <ledger> <own-session-id> <agents.json>` | Takes the run lock; prints `owner=<sid>:<nonce>` |
| `ledger.sh unlock <ledger>` | Releases the run lock |
| `ledger.sh init <ledger> <KEY> <ticket-branch> <coord-name> <coord-session-id> <issues.json>` | Creates the ledger; all issues `pending` |
| `ledger.sh get <ledger> [<n>]` | The state, or one issue, as JSON |
| `ledger.sh intent <ledger> launch\|relaunch <n> <session-name> <worktree> <branch> <base-sha> [<agents.json>]` | Records a `launch-intent`; prints `intent=<id>`. `<agents.json>` (relaunch only) records `priorPid` |
| `ledger.sh intent <ledger> merge <n> <candidate-sha> <expected-head>` | Records a `merge-intent`; prints `intent=<id>` |
| `ledger.sh event <ledger> <n> <event> [args]` | The only way statuses change (see the table and below) |
| `ledger.sh message <ledger> <raw-frame>` | A partner message, as the whole frame in one argument: bind, dedup, apply |
| `ledger.sh session <ledger> <n> <session-name> <session-id>` | Rebinds a woken partner |
| `ledger.sh reconcile <ledger> <agents.json>` | Resume: prints `requeue`, `resend` and `status` lines |
| `ledger.sh outbox <ledger>` | Prints `<n>\t<gen>\t<to>\t<line>` per pending entry |
| `ledger.sh slots <ledger>` | Prints the live count |
| `ledger.sh done <ledger>` | Prints `handback` or `cancel-ticket`; exit 1 if not finished |
| `ledger.sh summary <ledger>` | Markdown table for the PR body |

Two events are not rows of the transition table:

- `ledger.sh event <ledger> <n> canary-passed` opens the canary gate (`canary` goes `pending` to
  `passed`) once the first partner has passed its canary legs. Until then a second issue's launch
  is refused (exit 30), so the run stalls without it. A repeat exits 10.
- `ledger.sh event <ledger> <n> launch-failed <intent-id>` records that the launch for that open
  intent did not happen: the issue returns to its prior status (`pending`, or `failed` for a
  relaunch) and the intent closes (outcome `launch-failed`). A closed intent exits 10.

## Lock protocol

1. `ledger.sh lock <ledger> <own-session-id> <agents.json>` takes the run lock and prints
   `owner=<session-id>:<nonce>`. Export it as `PS_OWNER`.
2. Every mutating call (`unlock`, `init`, `intent`, `event`, `message`, `session`, `reconcile`)
   needs `PS_OWNER` to equal `lock/holder`. Otherwise it prints `holder=<id>` and exits 40.
3. A lock held by another live session exits 40 from `lock`: stop and tell the user. A lock whose
   holder is not live is taken over.
4. Exit 40 from any call means this coordinator lost the lock: stop.
5. `ledger.sh unlock <ledger>` on finish.
6. **Write mutex.** Every read-modify-write, every takeover and `unlock` hold `lock/write/`
   (created with `mkdir`; `lock/write/pid` is the writer's own process ID) across the owner check,
   the read and the `mv`. So a takeover never lands between a writer's owner check and its write:
   the old writer either finishes first or re-checks after the takeover and exits 40 without
   writing. A held mutex is waited for (about 10 s; then exit 2, or 40 from `lock`). It is stale
   only when `kill -0 <pid>` fails (a local process check), and is then removed once.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | Applied; prints the new status or the requested output |
| 10 | Idempotent no-op; the reason goes to stderr |
| 20 | Partner message rejected (bad frame, wrong `from`, wrong `gen`, wrong branch); prints `reason=` |
| 30 | Illegal transition refused (logged) |
| 40 | Lock held by a live other session, or `PS_OWNER` no longer matches |
| 2 | Usage or I/O error |
| 1 | `done` only: the ticket is not finished |

`ledger.sh done` prints `handback` (every issue `merged` or `cancelled`, at least one `merged`) or
`cancel-ticket` (every issue `cancelled`).

## Transition table

`merged` and `cancelled` are terminal. "Any live" means `launched`, `started`, `done-claimed`,
`verifying`, `rework-n/3` or `resync-requested`. "Working" means `launched`, `started`,
`rework-n/3` or `resync-requested`. `<id>` is an intent ID.

| From | Event | To | `ledger.sh` call |
|---|---|---|---|
| `pending` | `frontier.sh` selects it (every blocker `merged`, slot free); `launch-intent`, launch, `sessionId` recorded | `launched` | `intent launch`, then `event <n> launch <id> <session-id>` |
| `pending` | User drops the issue | `cancelled` | `event <n> drop [reason]` |
| `launched` | `STARTED` | `started` | `message` |
| working | Valid `DONE` | `done-claimed` | `message` |
| working | `STUCK needs=#m`, `#m` unmerged, no cycle, user agrees; `CANCEL` via outbox | `blocked-on #m` | `message` prints `ask-user=edge`; then `event <n> stuck-accept <m>` |
| working | `STUCK needs=#m`, `#m` already `merged` | `resync-requested` (sends `RESYNC`) | `message` |
| working | `STUCK` without `needs=`, or user declines the new edge, or `SCOPE` | unchanged | `message` prints `ask-user=...` |
| `done-claimed`, `verifying` | `STUCK` or `SCOPE` (e.g. as a `STATUS?` reply) | unchanged; logged and surfaced to the user; the queued claim proceeds | `message` (exit 10, prints `ask-user=...`) |
| `rework-n/3`, `resync-requested` | `STARTED` (partner reworking or re-testing) | unchanged | `message` |
| `done-claimed` | Head of queue; `ff-merge.sh --check` exits 10 (prints `head=<sha>`) | `resync-requested` (no budget used) | `event <n> queue-check stale <head>` |
| `done-claimed` | Head of queue; `ff-merge.sh --check` passes | `verifying` | `event <n> queue-check ok` |
| `verifying` | Gate passes; `merge-intent`; `ff-merge.sh` succeeds | `merged` | `intent merge`, then `event <n> gate merged <id> [text]` |
| `verifying` | Gate passes; `ff-merge.sh` exits 10 (prints `head=<sha>`) | `resync-requested` | `event <n> gate resync <head> [<id>]` |
| `verifying` | Gate fails, fewer than 3 failures in this generation | `rework-n/3` (sends `REWORK`) | `event <n> gate fail <evidence>` |
| `verifying` | Gate fails for the third time in this generation | `failed` (reason: rework budget) | `event <n> gate fail <evidence>` |
| `blocked-on #m` | `#m` becomes `merged` | `pending` (relaunched with a fresh brief, new generation, fresh branch and worktree) | automatic, in the write that merges `#m` |
| `blocked-on #m` | `#m` is or becomes `failed` or `cancelled`; user removes the edge | `pending` | `event <n> edge-remove [<m>]` (a given `<m>` must be `m`) |
| `pending` | A blocker `#m` is or becomes `failed` or `cancelled`; user removes the edge | `pending` (edge gone) | `event <n> edge-remove <m>` (exit 10 if no such edge; bare call exits 30) |
| `blocked-on #m` | `#m` is or becomes `failed` or `cancelled`; user drops this issue too | `cancelled` | `event <n> drop [reason]` |
| working | `FAILED`, or `--json` shows `failed`, or a wake fails (of a `stopped` partner, or to deliver `REWORK`/`RESYNC`), or the woken partner replies `FAILED` | `failed` | `message`; `event <n> json failed`; `event <n> wake-failed` |
| `done-claimed`, `verifying` | `--json` shows `failed` or `stopped` | unchanged (the persisted claim is verifiable from git and proceeds) | `event <n> json failed\|stopped` (exit 10) |
| `done-claimed`, `verifying` | Partner sends `FAILED` | `failed` | `message` |
| `failed` | User: relaunch (`--resume`, new generation, rework budget reset to 0/3) | `launched` | `intent relaunch`, then `event <n> relaunch <id> <session-id>` |
| `failed` | User: handled it themselves; coordinator verifies the issue branch tip is an ancestor of the ticket head | `merged` | `event <n> user-merged` |
| `failed` | User drops the issue | `cancelled` | `event <n> drop [reason]` |
| `pending`, `blocked-on #m`, any live, `failed` | User cancels the ticket (`CANCEL` via outbox to live and `failed` partners) | `cancelled` | `event <any n> cancel-ticket [reason]` (cancels every issue not terminal) |

The rework count belongs to a generation: every new generation, from a launch or a relaunch,
starts at `0/3`. When an issue becomes `cancelled`, every issue blocked on it is re-evaluated: `drop` prints
`dependents=<list>`; ask the user, per dependent, whether to drop it too (`cancelled`) or remove the
edge (`pending`). A `failed` issue's dependents stay `pending` (or `blocked-on`) until the user
resolves the failure.

The `<head>` in `queue-check stale <head>` and `gate resync <head>` is the sha from the `head=<sha>`
line that `ff-merge.sh` printed with exit 10. `ff-merge.sh` exit 3 (merge call only) means the ticket
branch is not checked out there or the worktree is dirty; fix that, it is not a resync.

A call whose transition is not in the table exits 30 (refused, ledger unchanged). Other outcomes
keep their own codes: a repeat of an applied call exits 10, bad arguments exit 2, a rejected
partner message exits 20, and a lost lock exits 40.
