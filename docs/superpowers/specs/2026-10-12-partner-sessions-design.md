# coordinating-partner-sessions: one sdlc-process partner session per GitHub issue — design

- **Date:** 2026-10-12
- **Skill:** `dev-workflow/skills/coordinating-partner-sessions/` (new), called from
  `dev-workflow/skills/intaking-work-items/chain-sdlc-process.md` stage 5
- **Status:** Approved design (parts 1–4 approved in session 2026-10-12), pending spec review

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
- Issues with no open blockers run in parallel; a blocked issue starts only after every blocker has
  been verified and merged into the ticket branch.
- The coordinator tracks every issue in a ledger, verifies every completion claim itself, and, when
  all issues are merged, hands back to intake steps 7–8, which open one draft PR for the ticket.

## Decisions (user, 2026-10-12)

1. **Partners, not children.** Each per-issue session is a partner that talks to the user directly;
   the user watches, attaches and answers in `claude agents`. The coordinator does not relay
   questions. It launches, tracks, verifies, merges and opens the PR.
2. **One worktree and one branch per issue.**
3. **Done = verified and merged.** An issue unblocks its dependents when its partner's `DONE` passes
   the verification gate and its branch is merged into the ticket branch. GitHub issues close when
   the single PR merges: its body carries `Closes #n` for every issue.
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
8. **Approach 1: event-driven with a ledger**, chosen over polling `claude agents --json` on a timer
   (wakes for nothing; cannot tell a partner waiting on the user from one working) and over an
   external Agent SDK script (outside the skill and plugin model `dev-workflow` uses).
9. **Fast-forward-only merges** (added after review, approved): a partner's tested branch is merged
   only if it already contains the current ticket head.
10. **The coordinator verifies every `DONE` before accepting it** (user addition to part 2).

## Platform facts relied on (code.claude.com docs, fetched 2026-10-12)

- `claude --bg --name <name> "<prompt>"` starts a full background session; it can dispatch
  subagents, invoke skills and use worktrees. Managed with `claude agents [--json --all]`,
  `claude attach`, `claude logs`, `claude stop`, `claude --resume <id> --bg`
  ([agent-view](https://code.claude.com/docs/en/agent-view.md)).
- Subagents may nest up to three layers below the main conversation
  ([sub-agents](https://code.claude.com/docs/en/sub-agents.md)). Partners are top-level sessions, so
  sdlc-process's own dispatches keep their full depth.
- `SendMessage` / `ListAgents` address local sessions by name; an idle recipient starts a new turn on
  arrival. Requires Claude Code v2.1.224+ on macOS/Linux/WSL2. `SendMessage` with `notify_when_idle`
  sends the main conversation one notice when a local session next goes idle or exits; it expires
  after 12 hours. Inbound messages can be held for approval depending on permission modes; the
  recipient's `crossSessionInbound: accept` avoids that
  ([cross-session-messaging](https://code.claude.com/docs/en/cross-session-messaging.md)).
- Background sessions with no attached terminal stop after about an hour idle; a session needing
  permission shows `Needs input` and waits until attached
  ([agent-view](https://code.claude.com/docs/en/agent-view.md)).
- New worktrees branch from the default branch unless `worktree.baseRef` is `head`
  ([worktrees](https://code.claude.com/docs/en/worktrees.md)). The coordinator therefore creates
  each partner's worktree explicitly from the current ticket head (Coordinator flow step 5), not
  through the default.
- Agent teams are experimental, cap a session at one team, and teammates cannot spawn teammates
  ([agent-teams](https://code.claude.com/docs/en/agent-teams.md)) — not used.
- **Unverified:** a changelog entry (v2.1.198) says a background session that worked in a worktree
  commits, pushes and opens a draft PR when it finishes. The partner brief forbids it either way.
- **Unverified:** the docs describe no parent/spawner relationship; a partner reaches the
  coordinator only by its session name, as a peer.

## Components

`dev-workflow/skills/coordinating-partner-sessions/`:

| File | Purpose |
|---|---|
| `SKILL.md` | The coordinator loop: preflight, readiness, ledger, launch, wait, verify, merge, hand back |
| `partner-brief.md` | Template for each partner's starting prompt |
| `readiness.md` | Mini-intake checklist, used up front and for the partner re-check |
| `ledger.md` | Ledger file format and status vocabulary |
| `scripts/frontier.sh` | Which issues to launch next |
| `scripts/ff-merge.sh` | Fast-forward-only merge into the ticket branch |
| `scripts/parse-msg.sh` | Validates one partner message line |

Changes elsewhere: `chain-sdlc-process.md` stage 5 gains the sequential-vs-parallel question and the
hand-off; `intaking-work-items` version bumps to 0.1.8; `dev-workflow/tests/run.sh` gains pins.

**Naming.** Coordinator session `<KEY>-coord`; partner sessions `<KEY>-<n>` (`n` = issue number);
partner branch `<key>-<slug>-<n>`; ticket branch `<key>-<slug>` (from stage 1).

**Defaults.** At most 3 partners running at once. Partners run in the coordinator's permission mode;
permission prompts surface as `Needs input` in `claude agents`. No partner pushes; the coordinator
pushes the ticket branch only at intake step 8, with the user's confirmation.

## Coordinator flow

1. **Preflight** (see below). Stop on any failure.
2. **Read the issues** published by `to-tickets` and their blocked-by edges from GitHub (native
   dependencies, with the `Blocked by: #n` body line as fallback, `docs/agents/issue-tracker.md:68`).
3. **Readiness, up front, one sitting.** Run `readiness.md` on every issue: story, acceptance
   criteria, a test approach (or a stated reason none is needed), and the issue's test command.
   Close every gap with the user before any launch.
4. **Write the ledger** `docs/specs/<KEY>-partners.md`.
5. **Launch the frontier.** `frontier.sh` returns the issues with no unmerged blockers, capped by the
   concurrency limit. For each: create the worktree and branch from the current ticket head, fill
   `partner-brief.md`, `claude --bg --name <KEY>-<n>`, register `notify_when_idle`, record in the
   ledger.
6. **Wait.** The coordinator is woken by a partner message or an idle notice.
7. **On `DONE`:** run the verification gate. On pass, run `ff-merge.sh`. On a successful merge,
   update the ledger and launch the new frontier. On `resync-needed`, send `RESYNC`.
8. **When every issue is merged**, hand back to intake step 7 (verify the Jira ticket's AC against
   the whole ticket branch), then step 8 (review tier for the full diff, one draft PR with
   `Closes #n` per issue).

## Partner flow (`partner-brief.md`)

The brief states:
- **Identity:** ticket key, issue `#n` and URL, own session name `<KEY>-<n>`, coordinator name
  `<KEY>-coord`.
- **Inputs:** `docs/specs/<KEY>-requirements.md`; the issue's AC, test approach and test command as
  recorded in the ledger; worktree path; branch; the ticket-head SHA it started from.
- **Authority:** build what this issue's AC need; talk to the user directly for every question and
  every sdlc-process gate.
- **Forbidden:** push, open a PR, close or edit GitHub issues, touch the ticket branch, any
  automatic PR on finish.
- **Steps:**
  1. Re-check readiness against the current code; ask the user only about what changed. Send
     `STARTED #n`.
  2. Run `sdlc-process:sdlc-process` on this one issue (attended).
  3. Merge the current ticket head into its branch, resolve conflicts, re-run its tests.
  4. Commit locally.
  5. Send `DONE`.

## Message protocol

One line per message, keyword first; `parse-msg.sh` rejects anything else.

| Direction | Message | Meaning |
|---|---|---|
| partner → coordinator | `STARTED #n` | Readiness re-check passed, work begun |
| partner → coordinator | `DONE #n <branch> <sha> synced=<head>` | Finished, tested against ticket head `<head>` |
| partner → coordinator | `STUCK #n <reason>` | Needs something outside its issue |
| partner → coordinator | `SCOPE #n <reason>` | Issue or ticket looks too big |
| partner → coordinator | `FAILED #n <reason>` | Gave up, or the user cancelled it |
| coordinator → partner | `RESYNC <head-sha>` | Ticket branch moved: merge it in, re-test, send `DONE` again |
| coordinator → partner | `REWORK #n <failed check + evidence>` | Verification failed: fix, re-test, send `DONE` again |
| coordinator → partner | `CANCEL` | Stop: commit nothing more, exit |

## Merge rule: fast-forward only

`ff-merge.sh <ticket-branch> <sha>` fast-forwards the ticket branch to `<sha>` only if the current
ticket head is an ancestor of `<sha>`. Otherwise it exits with a distinct `resync-needed` code and
prints the current head; the coordinator sends `RESYNC <head>` and records `resync-requested`.
Merges are serialized, so each merge forces at most the other in-flight finishers to resync. Nothing
reaches the ticket branch that was not tested against exactly its current head.

## Verification gate before accepting `DONE`

All four must pass; results are recorded in the ledger:
1. **Git state matches the claim.** The branch exists at `<sha>`; `<sha>` contains the current ticket
   head; the diff stays within the issue. If it touches files clearly owned by a sibling issue, ask
   the partner.
2. **Tests pass, run by the coordinator.** The issue's test command, run on `<sha>` in a clean
   checkout. The partner's report does not count.
3. **Every AC has evidence.** Using intake's `verify.md` method, each AC of the issue maps to a test
   or a `file:line` in the diff from the partner's start SHA to `<sha>`.
4. **Independent review.** A `dev-workflow:fresh-verifier` checks the diff against the issue's AC.

On a failure the coordinator sends `REWORK`. After the third failed gate on the same issue it stops
sending it back and asks the user.

## Error handling and resume

- **`FAILED`, or a partner that dies without `DONE`** (`claude agents --json` shows `failed` or
  `stopped`, or the idle notice fires with no `DONE`): mark the issue `failed`, keep its worktree and
  branch, launch nothing that depends on it, let independent issues continue, and ask the user:
  relaunch (`claude --resume <id> --bg`), handle it themselves, or cancel the ticket.
- **`STUCK`:** show the user the reason. If another issue must finish first, add the edge to the
  ledger and, with the user's agreement, on GitHub. Otherwise the user answers in that partner.
- **`SCOPE`:** tell the user, recommend the retrospective in Decision 7, and ask: continue with one
  PR, split, or stop.
- **Cancel the ticket:** send `CANCEL` to every running partner, record the final state. Branches and
  worktrees stay until the user cleans them up.
- **Coordinator stopped or restarted:** re-read the ledger, reconcile with `claude agents --json` and
  `git branch`, re-register `notify_when_idle` for live partners, and ask each live partner for its
  status so a missed `DONE` is resent. On every wake, re-register any notice older than about 11
  hours (they expire at 12).
- **Name collision:** if `claude agents` already lists `<KEY>-coord` or a `<KEY>-<n>`, stop and ask
  the user rather than message the wrong session.

## Preflight

- Claude Code supports cross-session messaging (v2.1.224+).
- The coordinator's inbound setting will not hold partner messages for approval. If it would, stop
  and tell the user which setting to change (`crossSessionInbound: accept`). Never edit settings.
- `gh` is authenticated for the repo; the ticket branch exists and is checked out clean.
- The brief's ban on automatic PR-on-finish is present in the filled brief.

## Testing

**Scripts, behavioural tests** (style of `dev-workflow/tests/test-audit-sh.sh`):
- `frontier.sh`: JSON fixtures for independent issues in parallel, a chain A → B → C, a diamond, a
  failed blocker holding back its dependents, the concurrency cap, and a dependency loop (must exit
  non-zero, never hang).
- `ff-merge.sh`: throwaway git repos for a clean fast-forward, a stale branch (`resync-needed`), a
  diverged branch, and a nonexistent SHA.
- `parse-msg.sh`: each valid message; malformed lines and trailing prose are rejected.

**Pins in `run.sh`** (intake style, `grep -qF`):
- frontmatter, SKILL.md under 500 lines, support files exist and are linked;
- the phrases `fast-forward only`, `RESYNC`, `REWORK`, the four verification checks, partners never
  push or open PRs, ask the user after the third failed gate, stop on a name collision, the
  held-inbound warning;
- `chain-sdlc-process.md` stage 5 has the sequential-vs-parallel question and names the new skill;
- the intake version is 0.1.8.

**Live trial, run by the user before release:** a throwaway ticket with issues A, B (blocked by A)
and C (independent). Expected: A and C run in parallel; B launches only after A merges; at least one
`RESYNC`; one draft PR closing all three. The plan carries this as a checklist.

**Review tier:** full chain (skill definitions change): `fresh-verifier` and `codex-adversary` on
the plan and on the diff.

## Out of scope

- Agent teams and the Agent SDK.
- The superpowers and mattpocock chains.
- Launching `/retro` or `skill-retrospective` automatically.
- Partners pushing, opening PRs or closing issues.

## Open items for the plan

- Verify the GitHub REST endpoint for reading an issue's dependencies (`issue-tracker.md:68`
  documents only the POST); fall back to the `Blocked by: #n` body line if absent.
