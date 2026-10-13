# Handoff — partner-session coordinator (2026-10-13)

**Resume:** `continue dev-workflows`

## Goal

Ship `dev-workflow:coordinating-partner-sessions`. At stage 5 of intake's sdlc-process chain it
launches one background sdlc-process partner session per GitHub issue, respecting blocked-by
edges. Partners talk to the user directly. The coordinator verifies each partner's DONE itself,
merges fast-forward only, keeps a crash-safe ledger in git's common dir, and opens one draft PR
per Jira ticket through intake steps 7-8.

## Where things are

- Worktree: `.claude/worktrees/partner-sessions-design`, branch `feat/partner-sessions-design`.
- Remote: origin has only the early spec commits (up to `3566c05`); 32 local commits are
  unpushed (count at the start of this handoff commit).
- Spec (binding): `docs/superpowers/specs/2026-10-12-partner-sessions-design.md`
- Original plan: `docs/superpowers/plans/2026-10-12-partner-sessions.md`
- Hardening plan: `docs/superpowers/plans/2026-10-13-partner-sessions-hardening.md`
- SDD ledger (git-ignored, in the worktree): `.superpowers/sdd/2026-10-12-partner-sessions/progress.md`.
  It holds 62 `Ruling:` lines and the deferred minors.
- The hardening plan gets its own SDD workspace under `.superpowers/sdd/` (via `sdd-workspace`).

## State

- Original plan Tasks 1-11 are done, each reviewed clean.
- Final fix wave (CX1-CX4, FV1-FV5) is done: 8 commits `c7a1cb4..5061c1d`.
- Re-check of that wave: fresh-verifier PASS-WITH-NITS; adversarial (Opus lane) FIX-FIRST on items 1-4:
  1. A stale-gen REWORK/RESYNC is resent forever after a relaunch (reproduced).
  2. A pid-reused stale write mutex wedges the ledger.
  3. "CANCEL and wait for it to end" never ends (an idle partner keeps its pid).
  4. Two concurrent stale-mutex reapers can lose a write (reproduced).
- The hardening plan addresses items 1-4 (`b9ee8ab` plus this commit's switch from perl to
  `lockf`/`flock`, which the user approved).
- Task 12, the live trial, has not run. The user runs it.

## Next steps, in order

1. Full-chain review of the hardening plan: `dev-workflow:fresh-verifier` plus an adversarial
   pass. The Codex cap of 3 per PR is used, so the adversarial pass goes to
   `claude-crew:claude-implementer-opus` with an `escalate:` line, read-only.
2. Get the user's approval of the reviewed plan.
3. Execute it subagent-driven: Task 1 sonnet, Task 2 opus (escalated), Task 3 sonnet,
   Task 4 (spec sync plus the external-blocker sentence) runs: the user chose (a) and yes.
4. Whole-branch full chain (verifier plus the Opus adversarial pass).
5. Ask the user before any push or PR.
6. The user runs the live trial. Live-only checks:
   - the real `<cross-session-message>` frame shape (single or multi-line, extra attributes, name decoration)
   - the non-empty `blocked_by` response shape
   - whether `sessionId` survives `--resume` once a stop has settled
   - whether the interactive coordinator appears in `claude agents --json --all` with a `pid`
   - the canary legs under the real `crossSessionInbound` and permission settings
   - `notify_when_idle` on a blocked partner, and on the ~1 h idle stop
   - whether `claude --bg` started inside a coordinator-made worktree stays there
   - the dependent partner's single blocker hold
   - dirtiness of the real main checkout
   - three new `claude stop` cases: an idle partner's row loses its `pid`; `--resume` after a stop
     keeps the `sessionId`; stopping a busy partner leaves its worktree usable

## User decisions (answered 2026-10-13)

- Spec drift: **(a) update the spec to match the code.** The hardening plan's Task 4 (spec sync) runs.
- External-blocker sentence: **yes.** Task 4 also adds one sentence to the spec saying an issue blocked by an open issue outside the ticket is not launched until that issue is closed.
- Branch push: approved once on 2026-10-13. Later pushes still need the user's go each time.

## Process notes for the next session

- The user's global rules apply:
  - the delegation gate: a `dispatching <lane>` or `solo: D<n>` line before edits
  - the read budget
  - the review tiers: full chain for skill and CI changes
  - ask before every push. The user kept the remote branch, but approves each push separately.
- The sidkik SDLC observer is active and flags scope and approval gaps.
- SDD conventions: the `task-brief` and `review-package` scripts under the superpowers 6.4.2
  `subagent-driven-development` skill's `scripts/` directory. Run them as separate plain commands from
  the worktree root; the worktree guard rejects compound shell lines.
- Push: `git -c credential.helper='!gh auth git-credential' push` (memory note).

## Suggested skills

`superpowers:subagent-driven-development`, `dev-workflow:fresh-verifier`,
`dev-workflow:opening-pull-requests`.
