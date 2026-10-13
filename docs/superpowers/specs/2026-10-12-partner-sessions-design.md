# coordinating-partner-sessions: one sdlc-process partner session per GitHub issue — design

- **Date:** 2026-10-12
- **Skill:** `dev-workflow/skills/coordinating-partner-sessions/` (new), called from
  `dev-workflow/skills/intaking-work-items/chain-sdlc-process.md` stage 5
- **Status:** Approved design (parts 1–4 approved in session 2026-10-12); revised after review
  round 1 (see Review history), pending user review of the revision

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
  new ID ([agent-view](https://code.claude.com/docs/en/agent-view.md)).
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
  turn on arrival; a session is reachable only while it binds an inbox socket, and a send to an
  unreachable session returns `Not sent`. Messaging requires v2.1.224+. `notify_when_idle` sends the
  main conversation **one** notice when a session next finishes a turn with nothing queued (which
  includes ending a turn by asking the user a question) or exits; it requires **v2.1.236+ in both
  sessions** and expires after 12 hours. Inbound messages can be held for approval depending on the
  sender's and recipient's permission classes; `crossSessionInbound: accept` on the recipient avoids
  that ([cross-session-messaging](https://code.claude.com/docs/en/cross-session-messaging.md)).
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
| `ledger.md` | Ledger file format, status vocabulary and transition rules |
| `scripts/frontier.sh` | Which issues to launch next; refuses a cyclic graph |
| `scripts/ff-merge.sh` | Fast-forward-only merge into the ticket branch |
| `scripts/parse-msg.sh` | Validates one partner → coordinator message line |
| `scripts/ledger.sh` | Atomic ledger writes, run lock, intents, dedup and resume reconciliation |

Changes elsewhere: `chain-sdlc-process.md` stage 5 gains the sequential-vs-parallel question and the
hand-off; `dev-workflow/.claude-plugin/plugin.json` version 0.1.7 → 0.1.8;
`dev-workflow/tests/run.sh` gains pins and runs the script tests.

**Naming.** Coordinator session `<KEY>-coord`; partner sessions `<KEY>-<n>` (`n` = issue number);
partner branch `<key>-<slug>-<n>`; ticket branch `<key>-<slug>` (from stage 1).

**Defaults.** At most 3 partners running at once. Partners launch with an explicit
`--permission-mode <coordinator's mode>`; permission prompts surface as `Needs input` in
`claude agents`. No partner pushes; the coordinator pushes the ticket branch only at intake step 8,
with the user's confirmation.

**Coordinator lifetime.** The coordinator is the attended intake session the user started. If it is
backgrounded, stopped (including the ~1 h idle stop) or restarted, it recovers through resume
reconciliation (Error handling and resume); nothing is lost because all state is in the ledger and
git.

## Ledger and durable state (`ledger.md`, `ledger.sh`)

The ledger `docs/specs/<KEY>-partners.md` is the single source of coordinator state.

- **Single writer.** Only one coordinator runs per ticket, enforced by a run lock
  (`<git-common-dir>/partners-<KEY>.lock`, holding the coordinator's session ID). A second
  coordinator that finds a live lock stops and tells the user.
- **Atomic writes.** Every update writes a temp file and renames it over the ledger, so a crash never
  leaves a half-written ledger.
- **Intents before side effects.** Before launching a partner the coordinator records
  `launch-intent` (issue, generation, worktree, branch, base SHA); before merging it records
  `merge-intent` (issue, generation, candidate SHA, expected ticket head). The outcome is recorded
  after. On resume, each open intent is reconciled against git and `claude agents --json` before any
  message is replayed (e.g. a `merge-intent` whose candidate SHA is already an ancestor of the ticket
  head is recorded as `merged`).
- **Generation per issue.** Each launch or relaunch of an issue's partner increments its generation;
  the ledger records the session name, full `sessionId`, and generation. Messages and intents carry
  the generation they belong to.
- **`DONE` claims are persisted** in the ledger on receipt (before verification), so a claim survives
  the partner stopping and the coordinator restarting.
- **Dedup.** A `DONE` is keyed by issue + generation + SHA; a repeated key is ignored.
- **Statuses:** `launched`, `started`, `blocked` (partner waiting on the user), `blocked-on #m`
  (cancelled until `#m` merges), `done-claimed`, `verifying`, `rework-n/3`, `resync-requested`,
  `merged`, `failed`, `cancelled`. `ledger.md` defines the allowed transitions; `ledger.sh` refuses
  any other.

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
5. **Write the ledger.** `frontier.sh` validates the graph; a cycle stops the run and is shown to the
   user.
6. **Launch the frontier.** `frontier.sh` returns the issues with no unmerged blockers, capped by the
   concurrency limit. For each:
   1. Check the name `<KEY>-<n>` is free with `ListAgents` (live sessions); on a collision, stop and
      ask the user.
   2. Record `launch-intent` with the next generation.
   3. Create the worktree and branch `<key>-<slug>-<n>` from the current ticket head.
   4. Fill `partner-brief.md`.
   5. `cd <partner-worktree> && claude --bg --name <KEY>-<n> --permission-mode <mode> "<brief>"`.
   6. Record the full `sessionId` and status `launched`; register `notify_when_idle`.
7. **Wait.** The coordinator is woken by a partner message or an idle notice. On every wake it reads
   `claude agents --json` and re-registers any notice older than about 11 hours.
8. **On a partner message:** apply sender binding and `parse-msg.sh` (Message protocol), then act
   per message. A `DONE` joins the integration queue.
9. **Integration queue.** One `DONE` at a time, in arrival order (Merge rule and Verification gate).
   A successful merge updates the ledger and launches the new frontier, including any
   `blocked-on` issue whose blocker just merged.
10. **When every issue is merged**, release the run lock and hand back to intake step 7
    (verify the Jira ticket's AC against the whole ticket branch, using `verify.md` in full), then
    step 8 (review tier for the full diff, one draft PR, closing keywords per Decision 3).

## Partner flow (`partner-brief.md`)

The brief states:
- **Identity:** ticket key, issue `#n` and URL, own session name `<KEY>-<n>`, generation, coordinator
  name `<KEY>-coord`.
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
     `STARTED #n`.
  2. Run `sdlc-process:sdlc-process` on this one issue (attended).
  3. Merge the current ticket head into its branch, resolve conflicts, re-run its tests.
  4. Commit locally.
  5. Send `DONE`.
- **On coordinator messages:** `RESYNC` → step 3–5 again; `REWORK` → fix, then 3–5; `STATUS?` →
  reply with the message for its current state; `QUERY` → reply with `REPLY`; `CANCEL` → stop,
  commit nothing more, exit.

## Message protocol

One line per message, keyword first. `parse-msg.sh` validates **partner → coordinator** lines only;
coordinator → partner lines are produced by the coordinator.

| Direction | Message | Meaning |
|---|---|---|
| partner → coordinator | `STARTED #n` | Readiness re-check passed, work begun |
| partner → coordinator | `DONE #n <branch> <sha> synced=<head>` | Finished, tested against ticket head `<head>` |
| partner → coordinator | `STUCK #n <reason>` or `STUCK #n needs=#m <reason>` | Needs something outside its issue; `needs=#m` names a sibling issue that must merge first |
| partner → coordinator | `SCOPE #n <reason>` | Issue or ticket looks too big |
| partner → coordinator | `FAILED #n <reason>` | Gave up, or the user cancelled it |
| partner → coordinator | `REPLY #n <text>` | Answer to a `QUERY` |
| coordinator → partner | `STATUS? #n` | Reply with the message for your current state |
| coordinator → partner | `QUERY #n <question>` | A question from the coordinator (e.g. sibling-owned files) |
| coordinator → partner | `RESYNC #n <head-sha>` | Ticket branch moved: merge it in, re-test, send `DONE` again |
| coordinator → partner | `REWORK #n <failed check + evidence>` | Verification failed: fix, re-test, send `DONE` again |
| coordinator → partner | `CANCEL #n` | Stop: commit nothing more, exit |

**Sender binding.** A partner message is accepted only if the transport sender name equals the
session recorded in the ledger for that issue at its current generation, and, for `DONE`, `<branch>`
equals the issue's recorded branch. Anything else is rejected and logged before any state change.

**Parsing safety.** `parse-msg.sh` takes the line as a single argv argument, never through `eval`,
command substitution of the message, or shell interpolation. `#n` must match `^#[0-9]+$`; `<sha>`
and `<head>` must match `^[0-9a-f]{40}$`; `<branch>` must match `^[a-z0-9][a-z0-9._/-]*$` and pass
`git check-ref-format --branch`. It prints structured `key=value` lines (or exits non-zero with a
reason). Free-text fields (`<reason>`, `<text>`) are stored, never executed.

**Delivery failure.** If `SendMessage` returns `Not sent` (the partner's process was stopped), the
coordinator wakes it with `claude --resume <sessionId> --bg "<message>"`, then records the session's
new ID if it changed.

## Merge rule: fast-forward only, through a serialized queue

For the `DONE` at the head of the integration queue:
1. **Stale-base check first.** If the current ticket head is not an ancestor of `<sha>`, send
   `RESYNC #n <head>` and record `resync-requested`. This does **not** count against the `REWORK`
   budget. The issue leaves the queue until its next `DONE`.
2. **Pin** the ticket head and the candidate `<sha>`, and run the verification gate against them.
3. **Recheck and merge.** Record `merge-intent`, then `ff-merge.sh <ticket-branch> <sha> <pinned-head>`
   fast-forwards only if the ticket head still equals the pinned head and is an ancestor of `<sha>`;
   otherwise it exits with the distinct `resync-needed` code and prints the current head.
4. Record `merged` (or `resync-requested`).

Merges are serialized by the single coordinator, so each merge forces at most the other in-flight
finishers to resync once, bounded by the issue count. Nothing reaches the ticket branch that was not
tested against exactly its current head.

## Verification gate before accepting `DONE`

Run against the pinned head and `<sha>`. All four must pass; results are recorded in the ledger:
1. **Git state matches the claim.** The branch exists at `<sha>`; `<sha>` contains the pinned head;
   the diff stays within the issue. If it touches files clearly owned by a sibling issue, the
   coordinator sends `QUERY` and waits for `REPLY` before continuing.
2. **Tests pass, run by the coordinator.** The issue's test command, run on `<sha>` in a throwaway
   worktree the coordinator creates (never the partner's worktree). The partner's report does not
   count.
3. **Every AC has evidence.** A lighter per-issue check than intake step 7's `verify.md`: each AC of
   the issue maps to a test or a `file:line` in the diff from the partner's start SHA to `<sha>`.
   Step 7 still runs the full `verify.md` on the whole ticket branch.
4. **Independent review.** A `dev-workflow:fresh-verifier` checks the diff against the issue's AC.

On a failure the coordinator sends `REWORK` and records `rework-n/3`. After the third failed gate on
the same issue it stops sending it back and asks the user.

## Error handling and resume

- **Idle notice.** An idle notice only means a turn ended; it triggers a check of that partner in
  `claude agents --json`:
  - `blocked` (waiting on the user): re-register `notify_when_idle`; nothing else.
  - `done` with no `DONE` received: send `STATUS? #n` and re-register.
  - `failed` or `stopped`: the failure path below.
  - `working`: re-register.
  A notice is one-shot, so the coordinator re-registers after **every** consumed notice.
- **`FAILED`, or `claude agents --json` shows `failed`/`stopped` with no persisted `DONE`:** mark the
  issue `failed`, keep its worktree and branch, launch nothing that depends on it, let independent
  issues continue, and ask the user: relaunch (`claude --resume <sessionId> --bg`, new generation,
  record the new ID), handle it themselves, or cancel the ticket. A `stopped` partner with a
  persisted `DONE` is not failed; its `DONE` proceeds through the queue.
- **`STUCK` without `needs=`:** the partner keeps its slot; the user answers in that partner.
- **`STUCK needs=#m`:** validate the edge `#n blocked-by #m` against the ledger graph. If it would
  create a cycle, refuse it and ask the user which issue absorbs the work. Otherwise, with the user's
  agreement, record the edge (and on GitHub), send `CANCEL #n`, record `blocked-on #m`, free the slot,
  and launch the next frontier issue. When `#m` merges, relaunch `#n` with a fresh brief and a new
  generation from the current ticket head.
- **`SCOPE`:** tell the user, recommend the retrospective in Decision 7, and ask: continue with one
  PR, split, or stop.
- **Cancel the ticket:** send `CANCEL` to every running partner, record the final state, release the
  lock. Branches and worktrees stay until the user cleans them up.
- **Resume reconciliation** (coordinator restarted, backgrounded or stopped):
  1. Take the run lock.
  2. Reconcile every open intent against git ancestry and `claude agents --json`.
  3. Re-queue every persisted `done-claimed` that is not yet merged.
  4. Re-register `notify_when_idle` for each live partner and send it `STATUS?`, so a `DONE` sent
     while the coordinator was down is resent (dedup drops repeats).
- **Name collision:** checked with `ListAgents` (live sessions only), so a dead row in
  `claude agents --all` does not block a relaunch. On a live collision, stop and ask the user rather
  than message the wrong session.

## Preflight

- Claude Code is **v2.1.236+** in the coordinator (partners are started by the same binary).
- **Bidirectional capability probe:** the coordinator launches a throwaway probe session, sends it a
  message, has it message back, and registers `notify_when_idle` on it. If any step fails or is held,
  stop. The probe session is stopped afterwards.
- **Held messages, both directions.** If either direction would be held for approval (permission
  class mismatch, or `crossSessionInbound` not `accept`), stop and tell the user which setting to
  change. Never edit settings.
- `gh` is authenticated for the repo; the ticket branch exists and is checked out clean.
- The filled brief contains the integration-base rule and the push/PR ban.

## Testing

**Scripts, behavioural tests** (style of `dev-workflow/tests/test-audit-sh.sh`):
- `frontier.sh`: JSON fixtures for independent issues in parallel, a chain A → B → C, a diamond, a
  failed blocker holding back its dependents, a `blocked-on` issue released when its blocker merges,
  the concurrency cap, and a dependency cycle (must exit non-zero, never hang), including a cycle
  introduced by a new `needs=` edge.
- `ff-merge.sh`: throwaway git repos for a clean fast-forward, a stale branch (`resync-needed`), a
  head that moved after pinning, a diverged branch, and a nonexistent SHA.
- `parse-msg.sh`: each valid message; malformed lines, trailing prose, bad SHAs and refs, and shell
  metacharacters (`;`, `$( )`, backticks, newlines) are rejected or stored inert, never executed.
- `ledger.sh`: atomic write; lock contention; sender binding rejects a message from another issue's
  session or an old generation (spoofing); duplicate `DONE` dropped; stale `DONE` routed to
  `RESYNC` without consuming the `REWORK` budget; illegal transitions refused; crash/reconcile at
  each side-effect boundary (after `launch-intent` before launch, after launch before record, after
  `merge-intent` before merge, after merge before record).

**Pins in `run.sh`** (intake style, `grep -qF`):
- frontmatter, SKILL.md under 500 lines, support files exist and are linked;
- the phrases `fast-forward only`, `RESYNC`, `REWORK`, `STATUS?`, the four verification checks,
  partners never push or open PRs, ask the user after the third failed gate, stop on a name
  collision, the held-messages warning, `v2.1.236`, the integration base is the ticket branch;
- `chain-sdlc-process.md` stage 5 has the sequential-vs-parallel question and names the new skill;
- `dev-workflow/.claude-plugin/plugin.json` version is `0.1.8`.

**Live trial, run by the user before release:** a throwaway ticket with issues A, B (blocked by A)
and C (independent). Expected: A and C run in parallel; at least one partner asks the user a question
and is **not** marked failed while waiting; B launches only after A merges and holds once on
sdlc-process's start rule until the user resolves it; at least one `RESYNC`; one draft PR covering
all three. The plan carries this as a checklist.

**Review tier:** full chain (skill definitions change): `fresh-verifier` and `codex-adversary` on
the plan and on the diff.

## Out of scope

- Agent teams and the Agent SDK.
- The superpowers and mattpocock chains.
- Launching `/retro` or `skill-retrospective` automatically.
- Partners pushing, opening PRs or closing issues.
- Modifying sdlc-process.

## Open items for the plan

- Verify a GitHub REST endpoint that lists which issues block an issue; fall back to the
  `Blocked by: #n` body line if absent.
- Verify how the coordinator reads a message's transport sender name (needed for sender binding);
  if the harness does not expose it, the plan must raise this before implementation.
- Verify the probe session can be launched and stopped cleanly in preflight without leaving a
  `claude agents` row the user must clear.

## Review history

**Round 1** (spec at `a86d636`; `fresh-verifier` verdict BLOCK, `codex-adversary` verdict
needs-attention). Addressed in this revision:
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
- Missing status/query vocabulary → `STATUS?`, `QUERY`, `REPLY`.
- Unreachable stopped sessions → `Not sent` wakes via `--resume <sessionId> --bg`; full `sessionId`
  recorded.
- Open-blocker hold in sdlc-process → Decision 11 (user chose option a); integration base named.
- `Closes` vs intake step 8 → follow step 8's rule.
- Permission mode not inherited → explicit `--permission-mode`.
- Wrong version path → `plugin.json`.
- Decision 8 rationale corrected; draft-PR-on-finish marked confirmed; `issue-tracker.md:68`
  reworded; gate check 3 distinguished from `verify.md`; throwaway verification worktree; ledger
  statuses enumerated; `ListAgents` for collisions.
