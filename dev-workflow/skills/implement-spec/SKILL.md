---
name: implement-spec
description: >
  Implements a published spec and its tickets on one integration branch: reads
  the ticket task graph, runs one implementer subagent per ready ticket (each
  isolated through the Agent tool's worktree isolation), merges their work, then
  code-reviews the whole branch. Use when a spec has two or more published
  tickets — called by intaking-work-items in intake mode, or directly when the
  user says "implement the spec" or "build the tickets". Skip for one ticket or
  no decomposition (use sdlc-process:implement), for tickets that are
  long-running and each need direct user interaction (use
  dev-workflow:orchestrating-pieces), and for an unpublished spec (to-spec and
  to-tickets first).
---

<!--
Adapted from `implement-spec` in mattpocock/skills (https://github.com/mattpocock/skills),
Copyright (c) 2026 Matt Pocock, MIT License; the full license text is in ./LICENSE.
Changes: no `disable-model-invocation` (agents may call it), an intake-mode clause,
isolation only through the Agent tool's `isolation: "worktree"`, a stop-on-refusal rule,
and `sdlc-process:`-prefixed skill calls.
-->

You have been provided a spec. This spec should have tickets associated with it, describing how to implement the spec.

The issue tracker should have been provided to you. If not, stop and tell the user the tracker is not configured (sdlc-process reads it from `docs/agents/issue-tracker.md`).

The goal is the entire spec implemented on a single **integration branch**, with every ticket resolved the way the issue tracker closes work.

The tickets are not a list of steps. They are a **task graph** with blocking relationships between them. This means there is always a **frontier** of tickets which are ready to be grabbed.

Communication to and from subagents should be sparse. Communicate primarily through **context pointers**: to the spec, tickets, research notes, and previous commits. Don't duplicate information already available via pointers.

**Implementer subagents** should be run in the background where possible for maximum concurrency.

**Intake mode.** When the caller says "intake mode" (`dev-workflow:intaking-work-items` does), this skill publishes nothing: no PR, no ready-for-review, no closed tickets, no closing keywords. It returns the integration branch, and the caller owns the PR.

## Isolation

Each implementer gets its own worktree only through the Agent tool's `isolation: "worktree"` parameter. Never run `git worktree add` by hand and point a subagent at it. Every implementer brief ends with: if a write, cd or git command is refused, stop and report; never script around the refusal.

## Orchestration

When sdlc-process is installed, load `sdlc-process:orchestrator` with the Skill tool before the first implementer dispatch, and re-read it before each new wave of implementers (step 6). Follow its brief rules for implementer and merger briefs; they are not repeated here.

## Steps

1. Read the spec and tickets to understand the task graph.

2. (optional) Use an **exploration subagent** to conduct any exploration required by the tickets - relevant codebase files or external documentation. Ensure the exploration subagent can save files - it should save its markdown notes in a directory outside the repo, accessible by all future subagents. This lets **implementer subagents** focus on implementation rather than exploration.

3. Create the integration branch. If the issue tracker closes work through PRs, or the user asks for one, open a draft PR after the first merge in step 5 (a branch with no commits ahead of main can't open one), marked as closing the spec and tickets. In intake mode, open no PR.

4. Use **implementer subagents** to implement each ticket, each started with `isolation: "worktree"` on its own branch. Each implementer subagent:
   - confirms its worktree is based on the integration branch before starting, and resets onto it if not;
   - calls the Skill tool with `sdlc-process:tdd` to build the ticket (in intake mode with the caller's `confirmed seam list`; a seam not in the list is a stop: report it, never ask or invent);
   - merges the integration branch tip into its own branch before reporting done

5. Once an **implementer subagent** completes, verify its report yourself before any merge: inspect the actual diff (`git diff` of its branch) and the actual test command output, red then green per `tdd`. A report alone is not proof. If it is not verified, merge nothing and send the work back to the implementer. Then merge its work to the integration branch with a **merger subagent**.

6. If this changes the **frontier** of available tickets, kick off more **implementer subagents** to work on the new tickets. This allows for maximum concurrency.

7. Once all tickets are complete, call the Skill tool with `sdlc-process:code-review` on the integration branch (in intake mode, with the caller's review base and spec path). Fix all issues raised by the code review in a single **implementer subagent**.

8. If a draft PR exists, mark it ready for review. Otherwise, resolve each ticket the way the issue tracker closes work, and report the integration branch. In intake mode, mark nothing ready, close no tickets, and use no closing keywords; report the integration branch to the caller.

9. Clean up the implementer worktrees the Agent tool left behind.
