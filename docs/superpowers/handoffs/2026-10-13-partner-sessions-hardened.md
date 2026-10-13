# Handoff — partner-session coordinator, hardening done (2026-10-13, second)

**Resume:** `continue dev-workflows`. Supersedes `2026-10-13-partner-sessions.md` (its steps 1-4 are done).

## Where things are

- Worktree `.claude/worktrees/partner-sessions-design`, branch `feat/partner-sessions-design`.
- Nothing pushed since `3566c05`. The user approves each push separately.
- Hardening plan: `docs/superpowers/plans/2026-10-13-partner-sessions-hardening.md`, reviewed and approved at `c8b148e`.
- SDD ledger (git-ignored): `.superpowers/sdd/2026-10-13-partner-sessions-hardening/progress.md`. It holds 9 `Ruling:` lines, the deferred minors and the review packages.

## State

- The plan's Tasks 1-4 are done and each one reviewed clean (`c8b148e..0437c5c`):
  - Task 1: the outbox invariant.
  - Task 2: an own-fd `lockf -s`/`flock -w` write lock, with exit 41 for busy.
  - Task 3: the `claude stop` procedure.
  - Task 4: the spec sync, plus the external-blocker sentence.
- Whole-branch full chain:
  - fresh-verifier: PASS-WITH-NITS.
  - Opus adversary: FIX-FIRST. All four original findings are confirmed closed by repro and by a fuzz run (0 invariant violations).
- One fix wave covered all 13 findings: `29df817`, `02be6bf`, `1628909`. The scoped re-review marked 12 of 13 ADDRESSED.
- At HEAD `1628909`: `run.sh` PASSED, scrub rc 0, SKILL.md 467 lines.

## Open: two user decisions, asked and not yet answered

1. **Residual A2 (Important).** In SKILL "Stop a session" step 2, a row whose `pid` differs from the noted pid makes the coordinator ignore the trigger. The note never closes, so step 10 can never `unlock` and hand-back stalls.
   - Proposed fix:
     - Step 2: a differing pid means the noted process ended. Close the note with no ledger write, tell the user that a new process runs that session, and do not stop it without their confirmation.
     - Step 10's finish condition adds "or closed by step 2".
     - Same change in the spec, around the Stop step 2 text and the hand-back text.
   - Recommended: apply it before the PR. Use a sonnet lane, then a short scoped re-review.
2. **Push.** Run `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push`; the leading empty helper is required. After that, watch both CI jobs:
   - the macOS job's new `lockf` fd-form probe;
   - the Ubuntu `flock` path, which has only been desk-checked.
   - If macOS fails the probe, pin the runner to an image whose `lockf` takes an fd, and state the minimum macOS in SKILL preflight and the README.

## Next steps

1. Get the answers to 1 and 2. Apply A2 if approved, then run `/bin/bash dev-workflow/tests/run.sh` and the scrub-check.
2. Push only with the user's go, then confirm CI is green.
3. `dev-workflow:opening-pull-requests`. Ask the user before opening the PR. The Codex adversary cap of 3 per PR is already used.
4. After the PR, give the user the live-trial (Task 12) checks. These are the ones in the earlier handoff, plus:
   - whether `startedAt` and `pid` stay stable across `--resume`;
   - whether `notify_when_idle` fires at once for an already-idle session;
   - whether `claude stop` on a busy partner leaves its worktree usable.
5. Once the PR is open, delete the workspace `.superpowers/sdd/2026-10-13-partner-sessions-hardening/`. Copy its `Ruling:` lines into the PR body first.

## Process notes

- The global delegation gate, read budget and review tiers apply. Ask before every push.
- Run SDD scripts from `~/.claude/plugins/cache/superpowers-marketplace/superpowers/6.4.2/skills/subagent-driven-development/scripts/` as separate plain commands.
