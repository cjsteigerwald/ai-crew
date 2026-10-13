# coordinating-partner-sessions: one sdlc-process partner session per GitHub issue — design

- **Date:** 2026-10-12
- **Skill:** `dev-workflow/skills/coordinating-partner-sessions/` (new), called from
  `dev-workflow/skills/intaking-work-items/chain-sdlc-process.md` stage 5
- **Status:** Approved design (parts 1–4 approved in session 2026-10-12); revised after review
  rounds 1 and 2 (see Review history), pending user review of the revision

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
   recommends a retrospective on `developer:creating-ces-tickets`: the user runs `/retro`
   (user-level skill at `~/.claude/skills/retro/`, `disable-model-invocation: true`, so the model
   cannot launch it), then `dev-workflow:skill-retrospective` to apply the learnings. The
   coordinator never launches either itself.
8. **Approach 1: event-driven with a ledger.** Partners message the coordinator; idle notices are a
   backstop. Chosen over polling `claude agents --json` on a timer because it wakes the coordinator
   only when something happened. Polling *can* tell a partner waiting on the user (`blocked`) from
   one working (`working`) (`agent-view.md`, `--json` states), so on every wake the coordinator reads
   `claude agents --json` as the source of truth for partner liveness. Also chosen over an external
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

## Platform facts relied on (code.claude.com docs, fetched 2026-10-12; local CLI 2.1.296)

- `claude --bg --name <name> "<prompt>"` starts a full background session; it can dispatch
  subagents, invoke skills and use worktrees. Managed with `claude agents [--json --all]`,
  `claude attach`, `claude logs`, `claude stop`, `claude --resume <sessionId> --bg`. `--resume`
  needs the full session UUID; on recent versions it may continue in place or start a copy under a
  new ID ([agent-view](https://code.claude.com/docs/en/agent-view.md)). The docs do not say a
  session name carries over to such a copy.
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
  In practice the frame is `<agent-message from="<sender name or id>">`. Names are not unique (the
  harness adds a short identifier when several sessions share one), and `from` may be an ID when the
  sender is unnamed. Binding is therefore name-level, which is acceptable because every session runs
  as the same OS user on one machine; see Sender binding.
- Session names come only from `--name` at launch or the user's `/rename` at that session's own
  keyboard; a session cannot rename itself.
- Agent teams are experimental, cap a session at one team, and teammates cannot spawn teammates
  ([agent-teams](https://code.claude.com/docs/en/agent-teams.md)) — not used.
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
| `scripts/ledger.sh` | Atomic ledger writes, run lock, intents, outbox, sender binding, dedup, transitions and resume reconciliation |

Changes elsewhere: `chain-sdlc-process.md` stage 5 gains the sequential-vs-parallel question and the
hand-off; `dev-workflow/.claude-plugin/plugin.json` version 0.1.7 → 0.1.8;
`dev-workflow/tests/run.sh` gains pins and runs the script tests.

**Naming.** Recommended coordinator name `<KEY>-coord`; the coordinator uses whatever user-set name
it actually has (Preflight). Partner sessions `<KEY>-<n>` (`n` = issue number); partner branch
`<key>-<slug>-<n>`; ticket branch `<key>-<slug>` (from stage 1).

**Defaults.** At most 3 partners running at once. Partners launch with an explicit
`--permission-mode <coordinator's mode>`; permission prompts surface as `Needs input` in
`claude agents`. No partner pushes; the coordinator pushes the ticket branch only at intake step 8,
with the user's confirmation.

**Coordinator lifetime.** The coordinator is the attended intake session the user started. If it is
backgrounded, stopped (including the ~1 h idle stop) or restarted, it recovers through resume
reconciliation (Error handling and resume); nothing is lost because all state is in the ledger and
git.

## Ledger and durable state (`ledger.md`, `ledger.sh`)

The ledger `docs/specs/<KEY>-partners.md` is the single source of coordinator state. It records the
coordinator's session name and ID, and per issue: status, blockers, generation, partner session
name and full `sessionId`, worktree, branch, start SHA, persisted claims, gate results, rework
count, and outbox.

- **Single writer.** Only one coordinator runs per ticket, enforced by a run lock
  (`<git-common-dir>/partners-<KEY>.lock`, holding the coordinator's session ID). The lock is
  **live** if the holder's session ID equals the caller's own, or appears in `claude agents --json`
  with a live process. A caller that finds a live lock held by another session stops and tells the
  user. Otherwise the caller takes the lock over and logs the takeover (old holder, time) in the
  ledger.
- **Atomic writes.** Every update writes a temp file and renames it over the ledger, so a crash never
  leaves a half-written ledger.
- **Intents before side effects.** Before launching a partner the coordinator records
  `launch-intent` (issue, generation, worktree, branch, base SHA); before merging it records
  `merge-intent` (issue, generation, candidate SHA, expected ticket head). The outcome is recorded
  after. On resume, each open intent is reconciled against git and `claude agents --json` before any
  message is replayed (e.g. a `merge-intent` whose candidate SHA is already an ancestor of the ticket
  head is recorded as `merged`).
- **Outbox.** Before sending `RESYNC`, `REWORK` or `CANCEL`, the coordinator records the message and
  its generation in the issue's outbox. The entry is cleared when that partner's next valid message
  for the same generation arrives (or, for `CANCEL`, when the session is gone). On resume, every
  outbox entry is resent; partners treat a repeated coordinator message as idempotent.
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
| `launched`, `started` | `STUCK needs=#m`, `#m` unmerged, no cycle, user agrees; `CANCEL` via outbox | `blocked-on #m` |
| `launched`, `started` | `STUCK needs=#m`, `#m` already `merged` | `resync-requested` (sends `RESYNC`) |
| `launched`, `started` | `STUCK` without `needs=`, or user declines the new edge, or `SCOPE` | unchanged |
| `rework-n/3`, `resync-requested` | `STARTED` (partner reworking or re-testing) | unchanged |
| `done-claimed` | Head of queue; ticket head not an ancestor of `<sha>` | `resync-requested` |
| `done-claimed` | Head of queue; base current | `verifying` |
| `verifying` | Gate passes; `merge-intent`; `ff-merge.sh` succeeds | `merged` |
| `verifying` | Gate passes; `ff-merge.sh` returns `resync-needed` | `resync-requested` |
| `verifying` | Gate fails, fewer than 3 failures so far | `rework-n/3` (sends `REWORK`) |
| `verifying` | Gate fails for the third time | `failed` (reason: rework budget) |
| `blocked-on #m` | `#m` becomes `merged` | `pending` (relaunched with a fresh brief, new generation) |
| `blocked-on #m` | `#m` becomes `failed` or `cancelled`; user removes the edge | `pending` |
| `blocked-on #m` | `#m` becomes `failed` or `cancelled`; user drops this issue too | `cancelled` |
| Any live | `FAILED`, or `--json` shows `failed`, or a wake of a `stopped` partner fails or it replies `FAILED` | `failed` |
| `failed` | User: relaunch (`--resume`, new generation) | `launched` |
| `failed` | User: handled it themselves; coordinator verifies the issue branch tip is an ancestor of the ticket head | `merged` |
| `failed` | User drops the issue | `cancelled` |
| `pending`, `blocked-on #m`, any live, `failed` | User cancels the ticket (`CANCEL` via outbox to live partners) | `cancelled` |

When an issue becomes `cancelled`, every issue blocked on it is re-evaluated: the coordinator asks
the user, per dependent, whether to drop it too (`cancelled`) or remove the edge (`pending`). A
`failed` issue's dependents stay `pending` (or `blocked-on`) until the user resolves the failure.

## Coordinator flow

1. **Preflight** (see below). Stop on any failure.
2. **Take the run lock**, create or reopen the ledger, and run resume reconciliation if the ledger
   already exists.
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
   capped by the concurrency limit. For each:
   1. Check the name `<KEY>-<n>` is free with `ListAgents` (live sessions); on a collision, stop and
      ask the user.
   2. Record `launch-intent` with the next generation.
   3. Create the worktree and branch `<key>-<slug>-<n>` from the current ticket head.
   4. Fill `partner-brief.md`.
   5. `cd <partner-worktree> && claude --bg --name <KEY>-<n> --permission-mode <mode> "<brief>"`.
   6. Read the name and full `sessionId` from `claude agents --json`, record them and status
      `launched`; register `notify_when_idle`.
7. **Wait.** The coordinator is woken by a partner message or an idle notice. On every wake it reads
   `claude agents --json` and re-registers any notice older than about 11 hours.
8. **On a partner message:** apply sender binding and `parse-msg.sh` (Message protocol), clear any
   matching outbox entry, then act per the transition table. A `DONE` joins the integration queue.
9. **Integration queue.** One `DONE` at a time, in arrival order (Merge rule and Verification gate).
   A successful merge updates the ledger and launches the new frontier, including any `blocked-on`
   issue whose blocker just merged.
10. **When every issue is `merged` or `cancelled`** (and at least one is `merged`), release the run
    lock and hand back to intake step 7 (verify the Jira ticket's AC against the whole ticket
    branch, using `verify.md` in full), then step 8 (review tier for the full diff, one draft PR,
    closing keywords per Decision 3).

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
- the frame's `from` value is **exactly equal** to the session name recorded for that issue (no
  prefix or case-insensitive match; an ID-valued `from` is rejected);
- `gen=<g>` equals the issue's current generation;
- for `DONE`, `<branch>` equals the issue's recorded branch.

The coordinator copies `from` out of the message frame and passes it to `ledger.sh` as an argv
argument; `ledger.sh` performs the comparison.

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

For the `DONE` at the head of the integration queue:
1. **Stale-base check first.** If the current ticket head is not an ancestor of `<sha>`, send
   `RESYNC #n <head>` (via the outbox) and record `resync-requested`. This does **not** count
   against the `REWORK` budget. The issue leaves the queue until its next `DONE`.
2. **Pin** the ticket head and the candidate `<sha>`, record `verifying`, and run the verification
   gate against them.
3. **Recheck and merge.** Record `merge-intent`, then `ff-merge.sh <ticket-branch> <sha> <pinned-head>`
   fast-forwards only if the ticket head still equals the pinned head and is an ancestor of `<sha>`;
   otherwise it exits with the distinct `resync-needed` code and prints the current head.
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
   the issue maps to a test or a `file:line` in the diff from the partner's start SHA to `<sha>`.
   Step 7 still runs the full `verify.md` on the whole ticket branch.
4. **Independent review.** A `dev-workflow:fresh-verifier` checks the diff against the issue's AC,
   including whether it strays outside the issue.

On a failure the coordinator sends `REWORK` (via the outbox) and records `rework-n/3`. The third
failed gate on the same issue moves it to `failed` and asks the user (the failure options below).

## Error handling and resume

- **Idle notice.** An idle notice only means a turn ended; it triggers a check of that partner in
  `claude agents --json`:
  - `blocked` (waiting on the user): re-register `notify_when_idle`; nothing else.
  - `done` with no `DONE` received: send `STATUS? #n` and re-register.
  - `working`: re-register.
  - `stopped`: not terminal. Wake it with
    `claude --resume <sessionId> --bg --name <KEY>-<n> "STATUS? #n"` (same generation), record the
    new name and `sessionId`, and re-register. Mark `failed` only if the wake fails or the partner
    replies `FAILED`. A `stopped` partner with a persisted `DONE` is not woken for that claim; its
    `DONE` proceeds through the queue.
  - `failed`: the failure path below.
  A notice is one-shot, so the coordinator re-registers after **every** consumed notice.
- **Failure path** (`FAILED`, `--json` `failed`, a failed wake, or the third failed gate): mark the
  issue `failed`, keep its worktree and branch, launch nothing that depends on it, let independent
  issues continue, and ask the user: relaunch, handle it themselves, or drop the issue (or cancel
  the whole ticket).
  - **Relaunch** uses `claude --resume <sessionId> --bg --name <KEY>-<n> "<generation g+1 + brief
    reminder>"`, keeping the partner's context because the failure was in its own work; record the
    new generation, name and `sessionId`. A `blocked-on` relaunch instead starts a fresh `--bg`
    session with a fresh brief, because its old session was cancelled before doing the work and its
    base must be the current ticket head.
  - **Handle it themselves:** the user tells the coordinator when done; the coordinator records
    `merged` only after verifying that the issue branch tip is an ancestor of the ticket head.
  - **Drop:** record `cancelled` and re-evaluate its dependents (transition table).
- **`STUCK` without `needs=`:** the partner keeps its slot; the user answers in that partner.
- **`STUCK needs=#m`:** if `#m` is already `merged`, send `RESYNC #n <head>` instead. Otherwise
  validate the edge `#n blocked-by #m` against the ledger graph. If it would create a cycle, refuse
  it and ask the user which issue absorbs the work. Otherwise ask the user; if they agree, record the
  edge (and on GitHub), send `CANCEL #n` via the outbox, record `blocked-on #m`, free the slot, and
  launch the next frontier issue. If they decline, nothing changes and the partner keeps its slot.
- **`SCOPE`:** tell the user, recommend the retrospective in Decision 7, and ask: continue with one
  PR, split (move issues out of this run: drop them), or stop (cancel the ticket).
- **Cancel the ticket:** send `CANCEL` to every live partner via the outbox, record `cancelled` for
  every non-terminal issue, release the lock. Branches and worktrees stay until the user cleans them
  up.
- **Resume reconciliation** (coordinator restarted, backgrounded or stopped):
  1. Take the run lock (liveness rule above).
  2. Check the coordinator's own name still equals the name recorded in the ledger (partners message
     that name). If not, ask the user to `/rename` back to it before continuing.
  3. Reconcile every open intent against git ancestry and `claude agents --json`.
  4. Re-queue every `done-claimed` and `verifying` issue that is not yet merged (a `verifying` issue
     re-enters at the stale-base check; its gate is re-run).
  5. Resend every outbox entry (`RESYNC`, `REWORK`, `CANCEL`) for its recorded generation.
  6. Re-register `notify_when_idle` for each live partner and send it `STATUS?`, so a `DONE` sent
     while the coordinator was down is resent (dedup drops repeats). Stopped partners follow the
     `stopped` rule above.
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
- **Bidirectional capability probe:** the coordinator launches a throwaway probe session, sends it a
  message, has it message back, and registers `notify_when_idle` on it. If any step fails or is held,
  stop. The probe session is stopped afterwards.
- **Held messages, both directions.** If either direction would be held for approval (permission
  class mismatch, or `crossSessionInbound` not `accept`), stop and tell the user which setting to
  change. Never edit settings.
- `gh` is authenticated for the repo; the ticket branch exists and is checked out clean.
- The filled brief contains the integration-base rule, the push/PR ban and the `gen=` rule.

## Testing

**Scripts, behavioural tests** (style of `dev-workflow/tests/test-audit-sh.sh`):
- `frontier.sh`: JSON fixtures for independent issues in parallel, a chain A → B → C, a diamond, a
  failed blocker holding back its dependents, a `blocked-on` issue released when its blocker merges,
  a cancelled blocker, the concurrency cap, and a dependency cycle (must exit non-zero, never hang),
  including a cycle introduced by a new `needs=` edge.
- `ff-merge.sh`: throwaway git repos for a clean fast-forward, a stale branch (`resync-needed`), a
  head that moved after pinning, a diverged branch, and a nonexistent SHA.
- `parse-msg.sh`: each valid message; missing or malformed `gen=`; malformed lines, trailing prose,
  bad SHAs and refs, and shell metacharacters (`;`, `$( )`, backticks, newlines) are rejected or
  stored inert, never executed.
- `ledger.sh`:
  - atomic write; lock contention; stale-lock takeover (dead holder) and own-lock recognition;
  - sender binding rejects another issue's session name, a near-match or ID-valued `from`, an old
    generation, and a mismatched branch (spoofing), with a fixture pinning the
    `<agent-message from="…">` frame format;
  - duplicate `DONE` dropped; same-state repeats (`STARTED` on `started`) accepted as no-ops;
  - stale `DONE` routed to `RESYNC` without consuming the `REWORK` budget; third gate failure →
    `failed`;
  - every row of the transition table, and illegal transitions refused; no reachable non-terminal
    status without an exit;
  - outbox entries recorded before send, cleared on the next valid message, resent on resume;
  - crash/reconcile at each side-effect boundary (after `launch-intent` before launch, after launch
    before record, after `merge-intent` before merge, after merge before record, during
    `verifying`, after an outbox record before send).

**Pins in `run.sh`** (intake style, `grep -qF`):
- frontmatter, SKILL.md under 500 lines, support files exist and are linked;
- the phrases `fast-forward only`, `RESYNC`, `REWORK`, `STATUS?`, `gen=`, the four verification
  checks, partners never push or open PRs, the third failed gate moves the issue to `failed`, stop on
  a name collision, the held-messages warning, `v2.1.236`, the integration base is the ticket
  branch, the coordinator's own name is checked before launch;
- `chain-sdlc-process.md` stage 5 has the sequential-vs-parallel question and names the new skill;
- `dev-workflow/.claude-plugin/plugin.json` version is `0.1.8`.

**Live trial, run by the user before release:** a throwaway ticket with issues A, B (blocked by A)
and C (independent). Expected:
- A and C run in parallel; B launches only after A merges and holds once on sdlc-process's start
  rule until the user resolves it.
- At least one partner asks the user a question and is **not** marked `failed` while waiting.
- At least one partner is left waiting unattended for over an hour (idle stop); the coordinator
  wakes it with `STATUS?` rather than failing it.
- A partner's message arrives framed as `from="<KEY>-<n>"`, matching the recorded name.
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
- Verify the probe session can be launched and stopped cleanly in preflight without leaving a
  `claude agents` row the user must clear.
- Verify `claude --resume <sessionId> --bg` accepts `--name`, and whether a copy started under a new
  ID keeps the name; if not, the coordinator must re-bind on the name it reads back from
  `claude agents --json`.

## Review history

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
resolved). Addressed in this revision:
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
