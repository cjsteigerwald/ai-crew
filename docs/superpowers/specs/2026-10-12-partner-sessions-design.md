# coordinating-partner-sessions: one sdlc-process partner session per GitHub issue — design

- **Date:** 2026-10-12
- **Skill:** `dev-workflow/skills/coordinating-partner-sessions/` (new), called from
  `dev-workflow/skills/intaking-work-items/chain-sdlc-process.md` stage 5
- **Status:** Approved design (parts 1–4 approved in session 2026-10-12); revised after review
  rounds 1, 2 and 3 (see Review history), pending user review of the revision

## Problem

Intake's sdlc-process chain implements every published issue in one session, one after another.
Stage 1 creates one work branch `<key>-<slug>`; stage 2 hands `sdlc-process:sdlc-process` a single
brief; stage 5 runs implement → tdd → code-review sequentially (`chain-sdlc-process.md:40-86`).
Issues that do not block each other still wait for each other, and one session's context carries
every issue.

## Goal

The user's words: "invoke a new orchestration agent per github issue … if github issues can be run
in parallel then invoke and pass handoff/prompts to each orchestration agent … if blocked by another
github issue, then when the issue is resolved invoke orchestration agent … When each invoked
orchestration agent completes pass back up to original orchestration agent … so that it can start
work on github issues that were blocked, track all work, when all work is complete open PR." And:
"I don't want this to replace SDLC, I want this to enhance the SDLC process by spawning a SDLC
process for each github issue."

Success:
- Each published issue is worked by its own full `sdlc-process:sdlc-process` run in its own
  background session, worktree and branch.
- Issues with no unmerged blockers run in parallel; a blocked issue starts only after every blocker
  has been verified and merged into the ticket branch.
- The coordinator tracks every issue in a crash-safe ledger, verifies every completion claim itself,
  and, when all issues are merged, hands back to intake steps 7–8, which open one draft PR.

## Decisions (user, 2026-10-12)

1. **Partners, not children.** Each per-issue session is a partner that talks to the user directly;
   the user watches, attaches and answers in `claude agents`. The coordinator does not relay
   questions. It launches, tracks, verifies, merges and hands back for the PR.
2. **One worktree and one branch per issue.**
3. **Done = verified and merged.** An issue unblocks its dependents when its partner's `DONE` passes
   the verification gate and its branch is fast-forwarded into the ticket branch. GitHub issues stay
   open until the ticket PR merges. The PR body follows intake step 8's rule
   (`intaking-work-items/SKILL.md:326-327, 335-336`): `Closes #n` only where the repo lets a merge
   close issues, otherwise `Refs owner/repo#n`; close-out then offers to close the issues.
4. **Readiness check runs twice** (option c): the coordinator checks every issue up front in one
   sitting with the user; each partner re-checks its issue at start and asks the user only about
   what changed since.
5. **Standalone skill called at stage 5** of `chain-sdlc-process.md`. After `to-tickets` publishes
   the issues, intake asks once: sequential (today's behaviour) or parallel partners. Parallel hands
   off to the new skill, which can also be run on its own given a ticket key and its issues.
6. **The partner resolves its own merge conflicts**, before it reports done.
7. **One PR per Jira ticket is guidance, not a rule.** If the work looks like it needs more than one
   PR, the coordinator asks the user instead of refusing. When the cause is ticket scope, it
   recommends a retrospective on the workspace's ticket-creation skill (the one that created this
   ticket): the user runs `/retro`
   (user-level skill at `~/.claude/skills/retro/`, `disable-model-invocation: true`, so the model
   cannot launch it), then `dev-workflow:skill-retrospective` to apply the learnings. The
   coordinator never launches either itself.
8. **Approach 1: event-driven with a ledger.** Partners message the coordinator; idle notices are a
   backstop. Chosen over polling `claude agents --json` on a timer because it wakes the coordinator
   only when something happened. Polling *can* tell a partner waiting on the user (`blocked`) from
   one working (`working`) (`agent-view.md`, `--json` states), so on every wake the coordinator reads
   `claude agents --json` as the source of truth for partner liveness: a row is alive only while it
   has a `pid`; a session has ended when its row is absent or has no `pid`. Also chosen over an external
   Agent SDK script (outside the skill and plugin model `dev-workflow` uses).
9. **Fast-forward-only merges** (added after review, approved): a partner's tested branch is merged
   only if it already contains the current ticket head.
10. **The coordinator verifies every `DONE` before accepting it** (user addition to part 2).
11. **Open blockers and sdlc-process's start rule** (option a, review round 1). sdlc-process's
    start rule wants completed blockers, but blocker issues stay open until the ticket PR merges
    (Decision 3). A dependent partner's brief carries the blocker evidence ("#A verified and merged
    into `<ticket-branch>` at `<sha>`; its issue stays open until the ticket PR merges, by design").
    sdlc-process will still hold once at start; the user resolves that one hold per dependent issue
    in the partner session. sdlc-process's rule is not bypassed or modified.
12. **Canary instead of a preflight messaging probe** (option b, review round 3). Replaces the
    approved "preflight confirms messaging works". Preflight is a version check plus a settings
    read; the first launch is a canary partner that proves real delivery both ways before any other
    partner launches (flow step 6). No throwaway session is created.
13. **The ledger lives in git metadata, never in the working tree** (user, after plan review). It
    sits at `$(git rev-parse --git-common-dir)/partner-sessions/<KEY>/ledger.json`, with the run
    lock and the append-only diagnostic log beside it. Git never sees it as a change, so the
    coordinator's strict clean-worktree check before a merge still holds, and every worktree of the
    repo resolves the same path. It is never committed; at hand-back the coordinator writes a
    readable summary of it into the PR body.

## Platform facts relied on (code.claude.com docs, fetched 2026-10-12; local CLI 2.1.296)

- `claude --bg --name <name> "<prompt>"` starts a full background session; it can dispatch
  subagents, invoke skills and use worktrees. Managed with `claude agents [--json --all]`,
  `claude attach`, `claude logs`, `claude stop`, `claude --resume <sessionId> --bg`. `--resume`
  needs the full session UUID ([agent-view](https://code.claude.com/docs/en/agent-view.md)). Local
  `claude --help` (2.1.296) for `--bg`: "With --resume <session-id>, continues that session in the
  background under the same ID, or starts a copy and says so when the session is already running."
  The coordinator only resumes stopped partners, but a copy with a new `sessionId` is possible
  (notably after `claude stop`), so it never assumes the same ID: it re-reads name and `sessionId`
  after every wake or relaunch and rebinds the ledger. `-n, --name` is a plain session option with no stated
  exclusion against `--resume`; whether it renames a resumed session is a live check (Open items).
- A `--bg` session started from a shell starts the way a new `claude` session in that directory
  would: dispatch defaults are not inherited, so the permission mode must be passed explicitly
  (agent-view).
- A `--bg` session started outside a linked worktree moves into its own `.claude/worktrees/`
  worktree, branched from the default branch, before editing. One started *inside* an existing
  linked worktree stays there, and asks before committing (agent-view;
  [worktrees](https://code.claude.com/docs/en/worktrees.md)). `worktree.baseRef` cannot name a
  branch, so the coordinator creates each partner's worktree itself and launches the partner from
  inside it.
- **Confirmed:** a background session finishing in a worktree *it entered itself* commits, pushes
  when there is a remote, and may open a draft PR; the user's git instructions take precedence
  (agent-view). It does not apply to coordinator-created worktrees; the partner brief forbids push
  and PR regardless.
- `claude agents --json` reports `state` as `working`, `blocked` (waiting on the user, with
  `waitingFor`), `done` (turn finished normally), `failed` or `stopped` (agent-view). Unattached
  sessions that are idle or awaiting a reply are stopped after about an hour, and under low memory.
  Observed on 2.1.296: liveness is the row's `pid`. A `done` row with a `pid` is idle and alive; a
  stopped session shows `done` without a `pid`; `failed` and `stopped` were never reported, so they
  are accepted but not relied on.
- Subagents may nest up to three layers below the main conversation
  ([sub-agents](https://code.claude.com/docs/en/sub-agents.md)). Partners are top-level sessions, so
  sdlc-process's own dispatches keep their full depth.
- `SendMessage` / `ListAgents` address live local sessions by name; an idle recipient starts a new
  turn on arrival; a session is reachable only while it binds an inbox socket, so a local session
  whose process stopped is absent from `ListAgents`. Messaging requires v2.1.224+ (v2.1.248+ for
  same-machine messaging on Bedrock, Vertex or Foundry, or with flag fetching off).
  `notify_when_idle` sends the main conversation **one** notice when a session next finishes a turn
  with nothing queued (which includes ending a turn by asking the user a question) or exits; it
  requires **v2.1.236+ in both sessions** and expires after 12 hours. Inbound messages can be held
  for approval depending on the sender's and recipient's permission classes;
  `crossSessionInbound: accept` on the recipient avoids that
  ([cross-session-messaging](https://code.claude.com/docs/en/cross-session-messaging.md)).
- **Sender attribution.** cross-session-messaging, "What a message looks like": "Claude receives the
  message with the sender's name and a reply address, except for a one-way cross-machine message."
  The SendMessage tool documentation states that cross-session messages arrive wrapped as
  `<cross-session-message from="<sender name or id>">` (subagent hand-backs use a different
  `<agent-message from=…>` frame, which this design does not consume). Names are not unique (the
  harness adds a short identifier when several sessions share one), and `from` may be an ID when the
  sender is unnamed. Binding is therefore name-level, which is acceptable because every session runs
  as the same OS user on one machine; see Sender binding.
- Session names come only from `--name` at launch or the user's `/rename` at that session's own
  keyboard; a session cannot rename itself.
- Agent teams are experimental, cap a session at one team, and teammates cannot spawn teammates
  ([agent-teams](https://code.claude.com/docs/en/agent-teams.md)) — not used.
- **Ledger write lock.** Every mutating `ledger.sh` call takes an exclusive kernel lock on
  `write.lock`, held on the call's own file descriptor with `/usr/bin/lockf -s` (macOS) or util-linux
  `flock -w` (Linux). The tool must support locking a descriptor; `ledger.sh` has no fallback and
  exits 2 when neither tool is present. The kernel drops the lock when the process, and any child
  still holding the descriptor, has exited, however it exits.
- **`claude stop <id>`** ends a running background session; `<id>` is the `id` of its
  `claude agents --json` row. A `CANCEL` message alone leaves an idle partner alive with its `pid`.
- **Unverified:** the docs describe no parent/spawner relationship; a partner reaches the
  coordinator only by its session name, as a peer. The design relies on names only.

## Components

`dev-workflow/skills/coordinating-partner-sessions/`:

| File | Purpose |
|---|---|
| `SKILL.md` | The coordinator loop: preflight, readiness, ledger, launch, wait, verify, merge, hand back |
| `partner-brief.md` | Template for each partner's starting prompt |
| `readiness.md` | Mini-intake checklist, used up front and for the partner re-check |
| `ledger.md` | Ledger file format, status vocabulary and the transition table |
| `scripts/frontier.sh` | Which issues to launch next; refuses a cyclic graph |
| `scripts/ff-merge.sh` | Fast-forward-only merge into the ticket branch |
| `scripts/parse-msg.sh` | Validates one partner → coordinator message line |
| `scripts/ledger.sh` | Atomic ledger writes under a kernel write lock, run lock, intents, outbox, sender binding, dedup, transitions and resume reconciliation |

Changes elsewhere: `chain-sdlc-process.md` stage 5 gains the sequential-vs-parallel question and the
hand-off; `dev-workflow/.claude-plugin/plugin.json` version 0.1.7 → 0.1.8;
`dev-workflow/tests/run.sh` gains pins and runs the script tests.

**Naming.** Recommended coordinator name `<KEY>-coord`; the coordinator uses whatever user-set name
it actually has (Preflight). Partner sessions `<KEY>-<n>` (`n` = issue number); partner branch
`<key>-<slug>-<n>`; ticket branch `<key>-<slug>` (from stage 1).

**Defaults.** At most 3 partners running at once. A **slot** is held by every issue in a live
status (`launched`, `started`, `done-claimed`, `verifying`, `rework-n/3`, `resync-requested`); it is
freed when the issue reaches `blocked-on`, `failed`, `merged` or `cancelled`. Partners launch with an explicit
`--permission-mode <coordinator's mode>`; permission prompts surface as `Needs input` in
`claude agents`. No partner pushes; the coordinator pushes the ticket branch only at intake step 8,
with the user's confirmation.

**Coordinator lifetime.** The coordinator is the attended intake session the user started. If it is
backgrounded, stopped (including the ~1 h idle stop) or restarted, it recovers through resume
reconciliation (Error handling and resume); nothing is lost because all state is in the ledger and
git.

## Ledger and durable state (`ledger.md`, `ledger.sh`)

The ledger is the single source of coordinator state (Decision 13). It lives in git metadata at
`$(git rev-parse --git-common-dir)/partner-sessions/<KEY>/ledger.json`, never in a working tree and
never committed; the run lock (`lock/`), the write lock file (`write.lock`) and an append-only
diagnostic log (`ledger.log`, not state) sit in the same directory. It records the coordinator's session name and ID, and per issue: status,
blockers, generation, partner session name and full `sessionId`, worktree, branch, start SHA,
persisted claims, gate results, rework count, and outbox.

- **Single writer.** Only one coordinator runs per ticket, enforced by a run lock (`lock/`, holding
  a `holder` file with the coordinator's session ID and a random nonce). The lock is **live** if the
  holder's session ID equals the caller's own, or is listed in `claude agents --json` with a live
  process (a `pid` that passes `kill -0`; where no `pid` is reported: listed with `state` not in
  {`stopped`, `failed`, `done`}). A missing or empty `holder` is not live. A caller that finds a live
  lock held by another session stops and tells the user. Otherwise it replaces the holder in place
  (new nonce) and logs the takeover (old holder, time). Every mutating call, including `lock`, first
  takes the **write lock**: an exclusive kernel lock on `<dir>/write.lock`, held on the call's own
  file descriptor (`lockf -s` / `flock -w`) from before the holder check through the read and the
  rename. A takeover needs the same lock, so no writer is ever between its holder check and its
  rename while the holder is replaced, and parallel calls never lose an update. The kernel releases
  the lock when the call, and any child still holding the descriptor, has exited, however it exits
  (`kill -9` included), so nothing is left to detect, reap or take over. The call's children (`jq`,
  `frontier.sh`) are synchronous and short; `git` runs with the descriptor closed, so a helper it
  spawns cannot inherit the lock. `lock` also removes a legacy `lock/write/` or `takeover/` directory left by an
  earlier version. A held lock is waited for `PS_WRITE_WAIT` seconds (default 10), then the call
  prints `busy=<dir>/write.lock` and exits 41 without changing anything. Read-only calls take no
  lock. Every mutating call also checks that the holder's nonce is its own; a coordinator that has
  lost the run lock (exit 40) stops.
- **Atomic writes.** Every update writes a temp file and renames it over the ledger, so a crash never
  leaves a half-written ledger. A status change and everything that must accompany it (the outbox
  command it implies, the claim it records, the intent it closes, dependents it releases) are one
  write.
- **Intents before side effects.** Before launching a partner the coordinator records
  `launch-intent` (issue, generation, session name, worktree, branch, base SHA); before merging it
  records `merge-intent` (issue, generation, candidate SHA, expected ticket head). Recording the
  outcome and closing the intent are one atomic write (the `launch` and `gate` events take the
  intent ID). On resume, each **open** intent is reconciled against git and `claude agents --json`
  before any message is replayed (e.g. a `merge-intent` whose candidate SHA is already an ancestor of
  the ticket head is recorded as `merged`); closed intents are never replayed, so reconciliation
  never moves an issue backwards.
- **Outbox.** A `RESYNC`, `REWORK` or `CANCEL` is recorded in the issue's outbox, with its generation
  and full text, in the same write as the transition that requires it; the coordinator sends it
  afterwards. Only one entry exists per issue and a newer entry supersedes the older, except that
  `CANCEL`s to two different sessions of one issue (its recorded session and an open intent's)
  coexist. A `RESYNC` or `REWORK` is cleared only by that partner's next `DONE` or `FAILED` for the
  same generation; a `STARTED`, `STUCK` or `SCOPE` leaves it outstanding. A `CANCEL` is cleared when
  its session has ended (its `claude agents --json` row is absent or has no `pid`), which the
  coordinator records after stopping the session (Error handling, Stop a session) or `reconcile`
  observes. **Invariant:** an entry other than `CANCEL` exists only for the issue's current
  generation while the issue is `resync-requested` or `rework-n/3`. A launch, relaunch, merge, cancel
  or failure purges the issue's `RESYNC`/`REWORK` in the same write; a launch or relaunch also drops
  older-generation `CANCEL`s; `reconcile` repairs any violation and logs `outbox-stale-purged`. On
  resume, every remaining outbox entry is resent verbatim (a `CANCEL` through Stop a session);
  partners treat a repeated coordinator message as idempotent.
- **Generation per issue.** Each launch or relaunch of an issue's partner increments its generation;
  the ledger records the session name, full `sessionId`, and generation. Every partner → coordinator
  line carries `gen=<g>`, and every intent and outbox entry records its generation. A wake of a
  stopped partner (same logical partner) keeps the generation; a relaunch increments it.
- **`DONE` claims are persisted** in the ledger on receipt (before verification), so a claim survives
  the partner stopping and the coordinator restarting.
- **Dedup and idempotency.** A `DONE` is keyed by issue + generation + SHA; a repeated key is a
  no-op. Any message that restates the issue's current state (e.g. `STARTED` on a `started` row, the
  usual reply to `STATUS?`) is an idempotent no-op, not a refused transition.
- **Statuses:** `pending`, `launched`, `started`, `blocked-on #m`, `done-claimed`, `verifying`,
  `rework-n/3`, `resync-requested`, `merged`, `failed`, `cancelled`. Whether a partner is waiting on
  the user is a per-wake observation from `claude agents --json`, not ledger state. `ledger.sh`
  refuses any transition not in the table below.

### Transition table

`merged` and `cancelled` are terminal. Every other status has at least one exit. "Any live" means
`launched`, `started`, `done-claimed`, `verifying`, `rework-n/3` or `resync-requested`.

| From | Event | To |
|---|---|---|
| `pending` | `frontier.sh` selects it (every blocker `merged`, slot free); `launch-intent`, launch, `sessionId` recorded | `launched` |
| `pending` | User drops the issue | `cancelled` |
| `launched` | `STARTED` | `started` |
| `launched`, `started`, `rework-n/3`, `resync-requested` | Valid `DONE` | `done-claimed` |
| `launched`, `started`, `rework-n/3`, `resync-requested` | `STUCK needs=#m`, `#m` unmerged, no cycle, user agrees; `CANCEL` via outbox | `blocked-on #m` |
| `launched`, `started`, `rework-n/3`, `resync-requested` | `STUCK needs=#m`, `#m` already `merged` | `resync-requested` (sends `RESYNC`) |
| `launched`, `started`, `rework-n/3`, `resync-requested` | `STUCK` without `needs=`, or user declines the new edge, or `SCOPE` | unchanged |
| `done-claimed`, `verifying` | `STUCK` or `SCOPE` (e.g. as a `STATUS?` reply) | unchanged; logged and surfaced to the user; the queued claim proceeds |
| `rework-n/3`, `resync-requested` | `STARTED` (partner reworking or re-testing) | unchanged |
| `done-claimed` | Head of queue; `ff-merge.sh --check` returns `resync-needed` | `resync-requested` (no budget used) |
| `done-claimed` | Head of queue; `ff-merge.sh --check` passes | `verifying` |
| `verifying` | Gate passes; `merge-intent`; `ff-merge.sh` succeeds | `merged` |
| `verifying` | Gate passes; `ff-merge.sh` returns `resync-needed` | `resync-requested` |
| `verifying` | Gate fails, fewer than 3 failures in this generation | `rework-n/3` (sends `REWORK`) |
| `verifying` | Gate fails for the third time in this generation | `failed` (reason: rework budget) |
| `blocked-on #m` | `#m` becomes `merged` | `pending` (relaunched with a fresh brief, new generation, fresh branch and worktree) |
| `blocked-on #m` | `#m` is or becomes `failed` or `cancelled`; user removes the edge | `pending` |
| `blocked-on #m` | `#m` is or becomes `failed` or `cancelled`; user drops this issue too | `cancelled` |
| `launched`, `started`, `rework-n/3`, `resync-requested` | `FAILED`, or `--json` shows `failed`, or a wake fails (of a `stopped` partner, or to deliver `REWORK`/`RESYNC`), or the woken partner replies `FAILED` | `failed` |
| `done-claimed`, `verifying` | `--json` shows `failed` or `stopped` | unchanged (the persisted claim is verifiable from git and proceeds) |
| `done-claimed`, `verifying` | Partner sends `FAILED` | `failed` |
| `failed` | User: relaunch (`--resume`, new generation, rework budget reset to 0/3) | `launched` |
| `failed` | User: handled it themselves; coordinator verifies the issue branch tip is an ancestor of the ticket head | `merged` |
| `failed` | User drops the issue | `cancelled` |
| `pending`, `blocked-on #m`, any live, `failed` | User cancels the ticket (`CANCEL` via outbox to live partners) | `cancelled` |

The rework count belongs to a generation: a relaunch (either kind) starts the new generation at
`0/3`. When an issue becomes `cancelled`, every issue blocked on it is re-evaluated: the coordinator asks
the user, per dependent, whether to drop it too (`cancelled`) or remove the edge (`pending`). A
`failed` issue's dependents stay `pending` (or `blocked-on`) until the user resolves the failure.

## Coordinator flow

1. **Preflight** (see below). Stop on any failure.
2. **Take the run lock**, create or reopen the ledger. If the ledger already exists, run resume
   reconciliation (Error handling and resume), **skip steps 3–5**, and continue at step 6.
3. **Read the issues** published by `to-tickets` and their blocked-by edges from GitHub (native
   dependencies, which `to-tickets` writes where available; the `Blocked by: #n` body line as
   fallback). `issue-tracker.md:68` documents the POST that creates an edge and the
   `issue_dependencies_summary.blocked_by` open-blocker count, but not an endpoint listing *which*
   issues block (Open items).
4. **Readiness, up front, one sitting.** Run `readiness.md` on every issue: story, acceptance
   criteria, a test approach (or a stated reason none is needed), and the issue's test command.
   Close every gap with the user before any launch.
5. **Write the ledger** with every issue `pending`. `frontier.sh` validates the graph; a cycle stops
   the run and is shown to the user.
6. **Launch the frontier.** `frontier.sh` returns the `pending` issues with every blocker `merged`,
   capped by the concurrency limit. An issue blocked by an open issue outside the ticket is not
   launched until that issue is closed (the coordinator first asks the user to wait or drop the edge
   before writing the ledger); blockers outside the ticket are recorded in `init` as
   `{n, closed}`. On a run's first launch (no partner has yet completed the canary
   check in this ledger), use the **canary phase**:
   - Launch only the first frontier issue (sub-steps below).
   - Wait for its `STARTED #n gen=<g>`: proves partner → coordinator delivery.
   - Send it `STATUS? #n` and wait for its reply: proves coordinator → partner delivery.
   - Record `canary: passed` in the ledger, then launch the rest of the frontier.
   - Each leg has a timeout (the plan sets 600 s). When it expires, read `claude agents --json` for
     the canary: `working` or `blocked` (still busy, or waiting on the user) restarts the timer and
     tells the user the canary is still running; a `done` row with a `pid` is idle, not ended. Only a
     canary that has ended (row absent or without a `pid`) without the expected message is a failed
     leg.
   - If a leg fails, stop launching: tell the user which leg failed and the likely setting (`crossSessionInbound` or a
     permission-class mismatch on the receiving side), and launch nothing more until the user has
     fixed it and asked to continue. The canary partner keeps running.

   For each launch:
   1. Check the name `<KEY>-<n>` is free with `ListAgents` (live sessions); on a collision, stop and
      ask the user.
   2. Record `launch-intent` with the next generation.
   3. Create the worktree and branch `<key>-<slug>-<n>` from the current ticket head. If they
      already exist from an earlier generation (a `blocked-on` relaunch), first rename the old branch
      to `<key>-<slug>-<n>-g<old>` (partial work kept for reference), remove the old worktree, then
      create both fresh.
   4. Fill `partner-brief.md`.
   5. `cd <partner-worktree> && claude --bg --name <KEY>-<n> --permission-mode <mode> "<brief>"`.
   6. Read the name and full `sessionId` from `claude agents --json`, record them and status
      `launched` while closing the launch intent (one write); register `notify_when_idle`.
7. **Wait.** The coordinator is woken by a partner message or an idle notice. On every wake it reads
   `claude agents --json` and re-registers any notice older than about 11 hours.
8. **On a partner message:** apply sender binding and `parse-msg.sh` (Message protocol), apply it
   (a valid `DONE` or `FAILED` for the generation clears that partner's `RESYNC`/`REWORK` entry; other
   messages do not), then act per the transition table. A `DONE` joins the integration queue.
9. **Integration queue.** One `DONE` at a time, in arrival order (Merge rule and Verification gate).
   A successful merge updates the ledger and launches the new frontier, including any `blocked-on`
   issue whose blocker just merged.
10. **When every issue is `merged` or `cancelled`:**
    - In both cases below, before the run lock is released, every open stop-pending note is
      finished: its Stop a session reaches step 3, step 2 closed it, or the user answers its
      step-4 hold. Otherwise
      its `json done nopid` write after the release exits 40 (for example, the last issue is
      dropped, the run is ready to hand back, and its stop still waits on `sleep 300`).
    - If every issue is `cancelled`, treat it as **cancel the ticket** (Error handling): release the
      lock and tell the user; no hand-back.
    - Otherwise, for each `cancelled` issue, mark its AC `deferred` in the settled AC list with the
      user's reason. Write a readable summary of the ledger (each issue's final status, branch,
      merge SHA, rework and resync counts, and reason for any cancellation) for the PR body. Release
      the run lock and hand back to intake step 7 (verify the Jira ticket's
      active AC against the whole ticket branch, using `verify.md` in full), then step 8 (review tier
      for the full diff, one draft PR). Closing keywords or `Refs` (Decision 3) cover `merged` issues
      only; the PR body lists each `cancelled` issue as not delivered, with its reason.

## Partner flow (`partner-brief.md`)

The brief states:
- **Identity:** ticket key, issue `#n` and URL, own session name `<KEY>-<n>`, generation `<g>`, and
  the coordinator's actual session name as recorded in the ledger.
- **Inputs:** `docs/specs/<KEY>-requirements.md`; the issue's AC, test approach and test command as
  recorded in the ledger; worktree path; branch; the ticket-head SHA it started from.
- **Integration base:** the ticket branch `<key>-<slug>`, not `main`. sdlc-process's default of
  rebasing onto current `main` does not apply; never rebase onto `main`.
- **Blocker evidence** (dependent issues only): for each blocker, "#A verified and merged into
  `<ticket-branch>` at `<sha>`; its issue stays open until the ticket PR merges, by design." Expect
  sdlc-process to hold once on its start rule; the user resolves that hold (Decision 11).
- **Authority:** build what this issue's AC need; commit locally in this worktree (the session may
  still show `Needs input` before committing, because it started inside an existing worktree — the
  user approves it there); talk to the user directly for every question and every sdlc-process gate.
- **Forbidden:** push, open a PR, close or edit GitHub issues, touch the ticket branch, any automatic
  PR on finish.
- **Steps:**
  1. Re-check readiness against the current code; ask the user only about what changed. Send
     `STARTED #n gen=<g>`.
  2. Run `sdlc-process:sdlc-process` on this one issue (attended).
  3. Merge the current ticket head into its branch, resolve conflicts, re-run its tests.
  4. Commit locally.
  5. Send `DONE`.
- **Every line to the coordinator** carries `gen=<g>`. If a wake or relaunch prompt states a new
  generation, use it from then on.
- **On coordinator messages:** `RESYNC` → steps 3–5 again; `REWORK` → fix, then 3–5; `STATUS?` →
  reply with exactly one of `STARTED` (still working), `DONE` (repeating the last claim), `STUCK` or
  `FAILED`; `CANCEL` → stop, commit nothing more, exit. A repeated coordinator message is handled
  once.

## Message protocol

One line per message, keyword first. `parse-msg.sh` validates **partner → coordinator** lines only;
coordinator → partner lines are produced by the coordinator.

| Direction | Message | Meaning |
|---|---|---|
| partner → coordinator | `STARTED #n gen=<g>` | Readiness re-check passed and working (also the "still working" reply to `STATUS?`) |
| partner → coordinator | `DONE #n gen=<g> <branch> <sha> synced=<head>` | Finished, tested against ticket head `<head>` |
| partner → coordinator | `STUCK #n gen=<g> <reason>` or `STUCK #n gen=<g> needs=#m <reason>` | Needs something outside its issue; `needs=#m` names a sibling issue that must merge first |
| partner → coordinator | `SCOPE #n gen=<g> <reason>` | Issue or ticket looks too big |
| partner → coordinator | `FAILED #n gen=<g> <reason>` | Gave up, or the user cancelled it |
| coordinator → partner | `STATUS? #n` | Reply with `STARTED`, `DONE`, `STUCK` or `FAILED` for your current state |
| coordinator → partner | `RESYNC #n <head-sha>` | Ticket branch moved: merge it in, re-test, send `DONE` again |
| coordinator → partner | `REWORK #n <failed check + evidence>` | Verification failed: fix, re-test, send `DONE` again |
| coordinator → partner | `CANCEL #n` | Stop: commit nothing more, exit |

**Sender binding.** A partner message is accepted only if all hold, else it is rejected and logged
before any state change:
- the message arrived in a `<cross-session-message …>` frame, and its `from` value is **exactly equal** to the session name recorded for that issue (no
  prefix or case-insensitive match; an ID-valued `from` is rejected);
- `gen=<g>` equals the issue's current generation;
- for `DONE`, `<branch>` equals the issue's recorded branch.

The coordinator passes the whole received frame to `ledger.sh` as one argv argument;
`parse-msg.sh --frame` checks the frame shape and extracts `from` in code (adopted from the plan,
which is stricter than the coordinator copying `from` by hand), and `ledger.sh` performs the
comparison.

`synced=<head>` in `DONE` is informational (stored for diagnosis); the merge rule decides currency
from git, not from this field.

**Parsing safety.** `parse-msg.sh` takes the line as a single argv argument, never through `eval`,
command substitution of the message, or shell interpolation. `#n` must match `^#[0-9]+$`; `gen=<g>`
must match `^gen=[0-9]+$`; `<sha>` and `<head>` must match `^[0-9a-f]{40}$`; `<branch>` must match
`^[a-z0-9][a-z0-9._/-]*$` and pass `git check-ref-format --branch`. It prints structured
`key=value` lines (or exits non-zero with a reason). Free-text fields (`<reason>`) are stored, never
executed.

**Delivery failure.** If the partner is absent from `ListAgents` or the send fails, the coordinator
wakes it with `claude --resume <sessionId> --bg --name <KEY>-<n> "<message>"` (same generation),
then re-reads the name and `sessionId` from `claude agents --json` and records them.

## Merge rule: fast-forward only, through a serialized queue

All base-currency checks live in `ff-merge.sh`. For the `DONE` at the head of the integration queue:
1. **`ff-merge.sh --check <ticket-branch> <sha>`** before anything else. If the current ticket head
   is not an ancestor of `<sha>`, it exits with the distinct `resync-needed` code and prints the
   head; the coordinator sends `RESYNC #n <head>` (via the outbox) and records `resync-requested`.
   This does **not** count against the `REWORK` budget. The issue leaves the queue until its next
   `DONE`.
2. **Pin** the ticket head and the candidate `<sha>`, record `verifying`, and run the verification
   gate against them.
3. **Merge.** Record `merge-intent`, then `ff-merge.sh <ticket-branch> <sha> <pinned-head>`
   fast-forwards only if the ticket head still equals the pinned head and is an ancestor of `<sha>`;
   otherwise it exits `resync-needed` and prints the current head.
4. Record `merged` (or `resync-requested`).

Merges are serialized by the single coordinator, so each merge forces at most the other in-flight
finishers to resync once, bounded by the issue count. Nothing reaches the ticket branch that was not
tested against exactly its current head.

## Verification gate before accepting `DONE`

Run against the pinned head and `<sha>`. All four must pass; results are recorded in the ledger:
1. **Git state matches the claim.** The branch exists at `<sha>` and `<sha>` contains the pinned
   head. Out-of-scope changes are caught by checks 2–4, not by a file-ownership map.
2. **Tests pass, run by the coordinator.** The issue's test command, run on `<sha>` in a throwaway
   worktree the coordinator creates (never the partner's worktree). The partner's report does not
   count.
3. **Every AC has evidence.** A lighter per-issue check than intake step 7's `verify.md`: each AC of
   the issue maps to a test or a `file:line` in `git diff <pinned ticket head>..<sha>` (exactly what
   the merge adds; the partner's start SHA would also count sibling changes merged in by a RESYNC).
   Step 7 still runs the full `verify.md` on the whole ticket branch.
4. **Independent review.** A `dev-workflow:fresh-verifier` checks the diff against the issue's AC,
   including whether it strays outside the issue.

On a failure the coordinator sends `REWORK` (via the outbox) and records `rework-n/3`. The third
failed gate in the same generation moves the issue to `failed` and asks the user (the failure
options below). A relaunch starts a fresh budget.

## Error handling and resume

- **Idle notice.** An idle notice only means a turn ended; it triggers a check of that partner in
  `claude agents --json`:
  - `blocked` (waiting on the user): re-register `notify_when_idle`; nothing else.
  - `done` with a `pid` (idle, alive) and no `DONE` received: send `STATUS? #n` and re-register.
  - `working`: re-register.
  - Ended (row absent or without a `pid`, which is how a `stopped` session shows): not terminal.
    Wake it with
    `claude --resume <sessionId> --bg --name <KEY>-<n> "STATUS? #n"` (same generation), record the
    new name and `sessionId`, and re-register. Mark `failed` only if the wake fails or the partner
    replies `FAILED`.
  - `failed`: the failure path below.
  - For an issue in `done-claimed` or `verifying`, neither `stopped` nor `failed` changes its status:
    the persisted claim is verifiable from git and proceeds through the queue without a wake. If it
    then needs `REWORK` or `RESYNC`, Delivery failure applies; a failed wake moves it to `failed`.
  A notice is one-shot, so the coordinator re-registers after **every** consumed notice.
- **Failure path** (`FAILED`, `--json` `failed`, a failed wake, or the third failed gate): mark the
  issue `failed`, keep its worktree and branch, launch nothing that depends on it, let independent
  issues continue, and ask the user: relaunch, handle it themselves, or drop the issue (or cancel
  the whole ticket).
  - **Relaunch** first stops every alive session in the issue's session history (Stop a session), so
    that no resumed copy works the same branch, then records the relaunch intent with `priorPid`,
    the `pid` of the issue's recorded session at that moment (null after the stops). `reconcile`
    counts an alive row of the intent's session name as the relaunch only if its `pid` differs from
    `priorPid`; the old process still running is not a relaunch, and the intent closes as
    `launch-failed`. If a session is still alive after the stop procedure, the coordinator does not
    relaunch until the user answers. It then runs
    `claude --resume <sessionId> --bg --name <KEY>-<n> "<generation g+1 + brief
    reminder>"`, keeping the partner's context because the failure was in its own work; record the
    new generation, name and `sessionId` (a copy with a new `sessionId` is possible after
    `claude stop`; the coordinator rebinds to whatever the agents row shows); the rework budget
    resets to `0/3`. A `blocked-on` relaunch
    instead starts a fresh `--bg` session with a fresh brief, because its old session was cancelled
    before doing the work and its base must be the current ticket head: the old branch is kept as
    `<key>-<slug>-<n>-g<old>`, the old worktree is removed, and both are recreated from the current
    ticket head (flow step 6.3). The two relaunch kinds are deliberately different.
  - **Handle it themselves:** the user tells the coordinator when done; the coordinator records
    `merged` only after verifying that the issue branch tip is an ancestor of the ticket head.
  - **Drop:** record `cancelled`, run Stop a session for any alive session of the issue, and
    re-evaluate its dependents (transition table).
- **Stop a session.** A `CANCEL` alone leaves an idle partner alive, so the coordinator ends the
  session. Triggers: a user **drop**, **cancel-ticket**, a **relaunch**, and a `stuck-accept`; and a
  reconcile-resent `CANCEL`. The rule: stop every alive session in the issue's session history (rows
  matched by any recorded `sessionId`, or by the recorded name), and only sessions the coordinator
  launched.
  0. If no alive row matches the session has already ended: skip to step 3.
  1. Deliver `CANCEL #n` (this is the delivery of that outbox entry) and register
     `notify_when_idle`. Keep a "stop pending" note per process: the issue, and the row's
     `sessionId` and `pid`.
  2. On the idle notice, or after a background `sleep 300` with no notice, read the noted row (by
     its `sessionId`, else by name). Ignore the trigger if the note is closed. If the row's `pid`
     differs from the noted `pid`, the noted process ended: close the note with no ledger write,
     tell the user a new process now runs that session, and do not stop it without their
     confirmation. If the row is absent or has no `pid`, go to step 3. Otherwise
     `claude stop <id>`, with `<id>` the `id` of that row, matched by recorded `sessionId`, else by
     name.
  3. Read agents up to six times, 5 s apart. When the row has no `pid`, record the observation
     (`json done nopid`), and close the note. For `stuck-accept` it is recorded while the issue is
     still `blocked-on`. The event drops only the recorded session's `CANCEL`, and only in
     `blocked-on` or `cancelled`: it is a no-op for a `failed` (relaunch) issue, and the next
     `reconcile` clears an open-intent session's `CANCEL`.
  4. Still alive after the sixth read: tell the user the session's name and id and do not loop. The
     caller holds its next action (relaunch, freeing the slot, releasing the lock) until the user
     confirms the session is gone or says to proceed. The user's answer closes the note.
  - Before any launch or relaunch of an issue, every stop-pending note for that issue is closed.
  - **Ambiguity:** if more than one alive row matches, or a matching row's `sessionId` is not one the
    ledger recorded for the issue, list the rows and ask the user before stopping. An open launch or
    relaunch intent's session, whose `sessionId` is usually unknown, is matched by the intent's
    recorded name. That alone is not ambiguity, but the coordinator cannot prove it launched a
    session whose launch was never recorded, so it stops that session only after the user
    confirms. Never stop by name when the match is ambiguous.
- **`STUCK` without `needs=`:** the partner keeps its slot; the user answers in that partner.
- **`STUCK` or `SCOPE` from a `done-claimed` or `verifying` issue:** status unchanged; logged and
  shown to the user; the queued claim proceeds.
- **`STUCK needs=#m`:** if `#m` is already `merged`, send `RESYNC #n <head>` instead. Otherwise
  validate the edge `#n blocked-by #m` against the ledger graph. If it would create a cycle, refuse
  it and ask the user which issue absorbs the work. Otherwise ask the user; if they agree, record the
  edge in the ledger (added to the issue's blockers), then write it to GitHub after the user confirms
  that write, record `blocked-on #m` (which queues the `CANCEL`), run Stop a session for `#n`'s
  session, free the slot, and launch the next frontier issue. If they decline, nothing changes and the partner keeps its slot.
- **`SCOPE`:** tell the user, recommend the retrospective in Decision 7, and ask: continue with one
  PR, split (move issues out of this run: drop them), or stop (cancel the ticket).
- **Cancel the ticket:** record `cancelled` for every non-terminal issue (which queues a `CANCEL` for
  every session that may still run), run Stop a session for each, then release the lock. Branches and worktrees stay until the user cleans them
  up.
- **Resume reconciliation** (coordinator restarted, backgrounded or stopped):
  1. Take the run lock (liveness rule above).
  2. Check the coordinator's own name still equals the name recorded in the ledger (partners message
     that name). If not, ask the user to `/rename` back to it before continuing.
  3. Reconcile every open intent against git ancestry and `claude agents --json`.
  4. Return every `verifying` issue to `done-claimed` (its gate was interrupted), then re-queue every
     `done-claimed` issue that is not yet merged; each re-enters at `ff-merge.sh --check` and its
     gate is re-run.
  5. Resend every outbox entry (`RESYNC`, `REWORK`, `CANCEL`) for its recorded generation; a
     `CANCEL` is resent through Stop a session.
  6. Re-register `notify_when_idle` for each live partner and send it `STATUS?`, so a `DONE` sent
     while the coordinator was down is resent (dedup drops repeats). Stopped partners follow the
     `stopped` rule above.
  7. Continue at flow step 6 (launch the frontier); steps 3–5 are not re-run.
- **Name collision:** checked with `ListAgents` (live sessions only), so a dead row in
  `claude agents --all` does not block a relaunch. On a live collision, stop and ask the user rather
  than message the wrong session.

## Preflight

- Claude Code is **v2.1.236+** in the coordinator (partners are started by the same binary);
  **v2.1.248+** when running on Bedrock, Vertex or Foundry, or with flag fetching off.
- The coordinator is **not in plan mode** (partners inherit its mode and could not edit). If it is,
  stop and ask the user to switch.
- **Own name.** Read the coordinator's own session name from `ListAgents`. If it has no user-set
  name (auto-generated), or the name collides with another live session, ask the user to `/rename`
  it (recommended: `<KEY>-coord`) and re-check. Record the actual name in the ledger; every brief
  uses it.
- **Held messages, both directions, from settings.** Read the effective `crossSessionInbound` and
  permission class that apply to the coordinator and, from the partner worktree's directory, to a
  partner launched with `--permission-mode <mode>`. If either direction would be held for approval
  (permission-class mismatch, or `crossSessionInbound` not `accept`), stop and tell the user which
  setting to change. Never edit settings. No throwaway probe session is launched; real delivery in
  both directions is proven by the canary phase (flow step 6, Decision 12).
- **Lock tool.** `/usr/bin/lockf` (macOS) or util-linux `flock` is present and can lock a file
  descriptor (probed once on a scratch file). Otherwise stop and tell the user: every mutating
  `ledger.sh` call needs it.
- `gh` is authenticated for the repo; the ticket branch exists and is checked out clean.
- The filled brief contains the integration-base rule, the push/PR ban and the `gen=` rule.

## Testing

**Scripts, behavioural tests** (style of `dev-workflow/tests/test-audit-sh.sh`):
- `frontier.sh`: JSON fixtures for independent issues in parallel, a chain A → B → C, a diamond, a
  failed blocker holding back its dependents, a `blocked-on` issue released when its blocker merges,
  a cancelled blocker, the concurrency cap, and a dependency cycle (must exit non-zero, never hang),
  including a cycle introduced by a new `needs=` edge.
- `ff-merge.sh`: throwaway git repos for a clean fast-forward, a stale branch (`resync-needed`), a
  head that moved after pinning, a diverged branch, and a nonexistent SHA; `--check` mode for a
  current base (exit 0, no ref changed) and a stale base (`resync-needed`, no ref changed).
- `parse-msg.sh`: each valid message; missing or malformed `gen=`; malformed lines, trailing prose,
  bad SHAs and refs, and shell metacharacters (`;`, `$( )`, backticks, newlines) are rejected or
  stored inert, never executed.
- `ff-merge.sh`: an integration test that initializes a real ledger, records a merge intent and
  merges successfully (the ledger, in git metadata, never dirties the worktree).
- `ledger.sh`:
  - atomic write; run-lock contention; takeover of a dead or missing holder and own-lock
    recognition; the write lock: parallel mutating calls lose no update, a held lock exits 41 after
    `PS_WRITE_WAIT`, a killed holder frees it, a takeover of a dead holder waits for that holder's
    in-flight write; a writer that has lost the lock is refused;
  - a transition and its outbox command in one write (crash right after the transition: reconcile
    resends the exact command); recording an outcome closes its intent (restart after a successful
    launch followed by `DONE` or cancel, or after a successful merge, never regresses);
  - every transition to `merged` (gate, user-driven, reconcile) releases `blocked-on` dependents;
  - sender binding rejects another issue's session name, a near-match or ID-valued `from`, an old
    generation, a mismatched branch, and a line in a non-`cross-session-message` frame (spoofing),
    with a fixture pinning the `<cross-session-message from="…">` frame format;
  - the canary gate: no second launch is allowed until `canary: passed` is recorded;
  - duplicate `DONE` dropped; same-state repeats (`STARTED` on `started`) accepted as no-ops;
  - stale `DONE` routed to `RESYNC` without consuming the `REWORK` budget; third gate failure in a
    generation → `failed`; a relaunch resets the budget to `0/3`;
  - `STUCK`/`SCOPE` accepted from `rework-n/3` and `resync-requested`; on `done-claimed`/`verifying`
    they leave the status unchanged; `--json` `failed`/`stopped` on `done-claimed`/`verifying` leaves
    the status unchanged;
  - slot accounting (live statuses hold a slot; `blocked-on`, `failed`, terminal free it); all issues
    `cancelled` → cancel the ticket, no hand-back;
  - every row of the transition table, and illegal transitions refused; no reachable non-terminal
    status without an exit;
  - outbox entries recorded before send, `RESYNC`/`REWORK` cleared only by `DONE` or `FAILED`, resent
    on resume; the outbox invariant (stale entries purged, by a launch too, `reconcile` repairs),
    `CANCEL`s to different sessions of one issue coexisting, and a relaunch's `priorPid` check;
  - crash/reconcile at each side-effect boundary (after `launch-intent` before launch, after launch
    before record, after `merge-intent` before merge, after merge before record, during
    `verifying`, after an outbox record before send).

**Pins in `run.sh`** (intake style, `grep -qF`):
- frontmatter, SKILL.md under 500 lines, support files exist and are linked;
- the phrases `fast-forward only`, `RESYNC`, `REWORK`, `STATUS?`, `gen=`, the four verification
  checks, partners never push or open PRs, the third failed gate moves the issue to `failed`, stop on
  a name collision, the held-messages warning, `v2.1.236`, the integration base is the ticket
  branch, the coordinator's own name is checked before launch, `canary`, `cross-session-message`,
  cancelled issues' AC marked `deferred`;
- `chain-sdlc-process.md` stage 5 has the sequential-vs-parallel question and names the new skill;
- `dev-workflow/.claude-plugin/plugin.json` version is `0.1.8`.

**Live trial, run by the user before release:** a throwaway ticket with issues A, B (blocked by A)
and C (independent). Expected:
- A and C run in parallel; B launches only after A merges and holds once on sdlc-process's start
  rule until the user resolves it.
- At least one partner asks the user a question and is **not** marked `failed` while waiting.
- At least one partner is left waiting unattended for over an hour (idle stop); the coordinator
  wakes it with `STATUS?` rather than failing it.
- The canary passes both legs before any other partner launches; a deliberately mis-set
  `crossSessionInbound` (on a scratch run) makes the canary stop with the right leg named.
- A partner's message arrives framed as `<cross-session-message from="<KEY>-<n>">`, matching the
  recorded name.
- At least one `RESYNC`; one draft PR covering all three.

The plan carries this as a checklist.

**Review tier:** full chain (skill definitions change): `fresh-verifier` and `codex-adversary` on
the plan and on the diff.

## Out of scope

- Agent teams and the Agent SDK.
- The superpowers and mattpocock chains.
- Launching `/retro` or `skill-retrospective` automatically.
- Partners pushing, opening PRs or closing issues.
- Modifying sdlc-process.
- Coordinator → partner questions (`QUERY`/`REPLY`) and a sibling file-ownership map (removed in
  round 2).

## Open items for the plan

- Verify a GitHub REST endpoint that lists which issues block an issue; fall back to the
  `Blocked by: #n` body line if absent.
- Live check (about 30 seconds): does `claude --resume <sessionId> --bg --name <KEY>-<n> "<msg>"` on
  a stopped session keep or set the display name? `claude --help` (2.1.296) says a resumed session
  continues under the same ID, but a copy with a new `sessionId` is possible after `claude stop`; the
  live trial records which happens, and the coordinator always rebinds. `--name`
  is not documented as incompatible with `--resume`. If the name is not kept, the coordinator
  re-binds on the name it reads back from `claude agents --json`, as it already does after every
  wake.
- Set the canary timeout (flow step 6). The plan sets 600 s per leg.

## Review history

*Historical record of earlier review rounds; where an entry conflicts with the sections above (e.g. mkdir/takeover locking), the sections above govern.*

**Round 1** (spec at `a86d636`; `fresh-verifier` verdict BLOCK, `codex-adversary` verdict
needs-attention). Addressed in `b44f74c`:
- Idle notice misread as partner death (both reviewers) → idle is a check trigger only; branch on
  `--json` state; re-register after every notice.
- `STUCK` deadlock and unchecked cycles → `needs=#m`, cancel and free the slot, `blocked-on`,
  cycle refusal, relaunch on merge.
- Spoofable messages, unsafe parsing → sender binding by session name + generation + branch; strict
  regexes; argv-only `parse-msg.sh`.
- Crash windows and lost `DONE` → run lock, atomic ledger, launch/merge intents, persisted claims,
  dedup, reconciliation; `ledger.sh` with crash-boundary tests.
- Stale `DONE` consuming the rework budget → stale-base check first, `RESYNC` free, serialized queue,
  pinned head rechecked at merge.
- Version floor v2.1.224 → v2.1.236; bidirectional probe; held-message check both ways.
- Launch cwd and auto-worktree from `main` → launch from inside the coordinator-created worktree.
- Missing status/query vocabulary → `STATUS?`, `QUERY`, `REPLY` (`QUERY`/`REPLY` later removed in
  round 2).
- Unreachable stopped sessions → wake via `--resume <sessionId> --bg`; full `sessionId` recorded.
- Open-blocker hold in sdlc-process → Decision 11 (user chose option a); integration base named.
- `Closes` vs intake step 8 → follow step 8's rule.
- Permission mode not inherited → explicit `--permission-mode`.
- Wrong version path → `plugin.json`.
- Decision 8 rationale corrected; draft-PR-on-finish marked confirmed; `issue-tracker.md:68`
  reworded; gate check 3 distinguished from `verify.md`; throwaway verification worktree; ledger
  statuses enumerated; `ListAgents` for collisions.

**Round 2** (spec at `b44f74c`; `fresh-verifier` verdict BLOCK, all round-1 findings confirmed
resolved). Addressed in `17b381e`:
- F1 coordinator name assumed → preflight reads its own name from `ListAgents`, asks the user to
  `/rename` if auto-generated or colliding; briefs use the recorded name; resume re-checks it.
- F2 `QUERY`/`REPLY` stalling the queue → removed, with the sibling file-ownership check; checks 2–4
  and the fresh-verifier cover out-of-scope diffs.
- F3 generation not carried in messages → `gen=<g>` on every partner line, required by
  `parse-msg.sh`; binding on name + generation + branch; `--name` passed on every wake or relaunch
  and the name/`sessionId` re-read.
- F4 `stopped` treated as failure → non-terminal; wake with `STATUS?` first; trial adds a >1 h wait.
- F5 `blocked` status with no exit → removed from the ledger; it is a per-wake observation.
- F6 resume stranding `verifying` and pending messages → re-queue `verifying`; outbox recorded before
  send and resent on resume.
- F7 "handle it themselves" with no path to `merged` → user-driven `failed → merged` after an
  ancestry check; drop → `cancelled` with dependents re-evaluated.
- F8 stale-lock liveness undefined → live = own ID or listed with a live process; else take over and
  log.
- F9 `STATUS?` replies undefined → `STARTED`/`DONE`/`STUCK`/`FAILED`; same-state repeats are no-ops.
- I1 `needs=` on a merged issue → `RESYNC`. I2 delivery trigger reworded. I3 plan mode refused.
  I4 v2.1.248 floor noted. I5 relaunch-by-resume vs fresh-brief relaunch explained.
- Sender-identity open item closed (attribution documented); residuals recorded.
- Transition table added; every non-terminal status has an exit; `pending` added for issues not yet
  launched.

**Round 3** (spec at `17b381e`; `fresh-verifier` verdict PASS-WITH-NITS, F1–F9 of round 2 confirmed
resolved). Addressed in this revision:
- F1 cancelled issues at hand-back → their AC marked `deferred` with the user's reason; closing
  keywords/`Refs` cover `merged` issues only; PR body lists cancelled issues as not delivered.
- F2 resume re-running steps 3–5 → resume skips them and continues at step 6.
- F3 rework budget after relaunch → resets to `0/3` per generation.
- F4 `STUCK`/`SCOPE` only from `launched`/`started` → extended to `rework-n/3` and
  `resync-requested`; on `done-claimed`/`verifying` they leave the status unchanged and are surfaced.
- F5 `blocked-on` relaunch reusing branch/worktree → old branch kept as `<branch>-g<old>`, old
  worktree removed, both recreated from the current ticket head.
- F6 all issues cancelled → treated as cancel the ticket.
- F7 slot accounting → a slot is held by every live status.
- F8 `--json failed` with a persisted `DONE` → status unchanged; the claim proceeds; a later
  undeliverable `REWORK`/`RESYNC` goes through the delivery-failure path.
- F9 "becomes" → "is or becomes".
- YAGNI: the separate stale-base check is collapsed into `ff-merge.sh --check`. The preflight probe
  session is removed: preflight is a version check plus a settings read, and the user chose a canary
  phase (Decision 12) that proves real delivery both ways on the first partner.
- Frame format corrected to `<cross-session-message from="…">` (SendMessage tool documentation).
- `--resume` open item narrowed using `claude --help` 2.1.296; the probe-cleanup open item removed.

**Plan review** (plan at `7c7a62b`; `fresh-verifier` verdict BLOCK, `codex-adversary` verdict
needs-attention). Spec changes made with the plan revision:
- Ledger in the working tree blocking the coordinator's own merges (both reviewers) → Decision 13
  (user's choice): the ledger, lock and log live in git metadata and are never committed; a readable
  summary goes into the PR body; the strict clean-worktree merge check stays.
- Transition and outbox command written separately → one atomic write; recording an outcome closes
  its intent in the same write; closed intents are never replayed.
- Non-exclusive stale-lock takeover → `mkdir` takeover directory, re-check, nonce-confirmed holder
  rename; every write re-checks ownership; a missing holder is not live; no-pid liveness fallback.
- Interrupted `verifying` → returned to `done-claimed` by reconciliation before re-queueing.
- Canary timer expiring on a busy partner → read `--json`; only an ended canary is a failed leg.
- Every transition to `merged` releases `blocked-on` dependents; an accepted `needs=` edge joins the
  issue's blockers and is written to GitHub after the user confirms.
- `parse-msg.sh --frame` extracts `from` (adopted from the plan); `synced=` is informational.
- Decision 7's retrospective target written generically (public-repo hygiene).
