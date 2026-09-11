---
name: opening-pull-requests
description: >
  Runs the ordered gate sequence before and during PR creation in any repo:
  branch hygiene, sync with main, lint and test, CI mirror, review-tier
  decision, review chain, ticket references, user confirmation, then create and
  verify. Use when about to push work for review or open a PR — "open a PR",
  "ready for review", "push this", "raise a PR", "is this ready to merge",
  "create the PR" — and when a push has just failed CI. Policy lives in this
  plugin's README § Review policy; this skill only sequences the gates and
  cites it. Skip when implementing an approved plan (use plan-implementation),
  when reviewing someone else's PR (use /review), or when the question is
  which review tier applies rather than how to ship (read the README § Review
  policy directly).
---

# Opening pull requests

The gates that fire between "code works" and "PR is open". They fail by **omission**, not ignorance —
every rule below is written down somewhere, which is exactly why one gets skipped. Run them in order.

## When to Use This Skill

- About to push work for review, or about to run `gh pr create`
- "open a PR", "ready for review", "push this", "raise a PR", "create the PR"
- A push just failed CI (gate 4 was skipped or approximated)
- Adding commits to an existing open PR — gates 1–4 and 7 still apply

## When *Not* to Use This Skill

- Executing an approved multi-step plan → `[[plan-implementation]]`
- Reviewing a PR someone else opened → `/review`
- Deciding *which* tier a change is → read this plugin's README § Review policy directly

## The gates

### 1. Branch

Never commit to `main`. Branch from `main`, not from whatever the shared checkout is sitting on.
For repo work, create the worktree from `main` first.

⚠️ A branch created from a stale checkout inherits that state. A stale branch once destroyed a
non-prod cluster's node pool via an apply that looked clean.

### 2. Sync with main

`git fetch origin main` and rebase before any apply or PR. Check what landed while you worked —
a merged PR can silently make your branch's premise false.

⚠️ If `main` moved and your PR was squash-merged earlier, a new PR from the same branch replays the
whole diff. Branch fresh from `main` and cherry-pick instead.

### 3. Lint AND test — both, zero failures

Both must be clean before pushing, not one. Run the full suite, not a subset.

### 4. CI mirror — literal commands, never approximations

Run the repo's CI-mirror script if it has one (e.g. `./scripts/ci-local.sh`). If it doesn't,
extract the literal `run:` commands from the workflow files and execute those.

⚠️ Approximation drift is the top cause of "verified locally, failed in CI": CI also runs mypy,
bandit, helm lint, checkov with a skip-config, and gitleaks **pinned to an older version whose rules
differ**. A SKIPPED gate is not a green gate — install the missing binary.

⚠️ Check whether the repo has PR-triggered CI at all. Some repos have none, so nothing
catches what you miss.

### 5. Tier decision

Per this plugin's README § Review policy — Exempt / Routine / Full chain. Decide against the **actual
diff**, not the plan's stated scope: a Routine-planned change that grew past the thresholds gets the
full chain now. When torn between Routine and Full, run Full.

### 6. Review chain for that tier

Per the same table. On the **full chain**, `codex-adversary` is mandatory — omitting it
is a blocking error. A finding from the verifier or adversary cannot be dismissed without written
evidence.

### 7. Ticket references

Per your project's commit convention for ticket references. The ask happens **at commit time**: whether a
ticket exists, and an offer to file one — filing is a write, so propose it, never do it unasked. If there
is one, the key goes in every commit subject and the PR title.

If that ask already happened, do not re-open it here. **If it never happened, this gate is where you
catch it** — ask now, and amend the commit subjects if a key turns up.

**The PR body opens with the ticket as a hyperlink** — first line, before any prose:

```
**Ticket:** [PROJ-210](https://<your-jira-host>/browse/PROJ-210)
```

Multiple tickets: comma-separate, each linked. Then any PR this depends on or supersedes. No ticket →
`**Ticket:** none — <reason>` on that same first line, so the absence is as visible as a key would be.
That line is a **first-class outcome, not a fallback**: if the user declined or none applies, record the
reason and ship.

⚠️ A bare `PROJ-210` is not enough: GitHub does not auto-link tracker keys, so an unlinked key costs every
reader a copy-paste. Link it once at the top and the ticket is one click from the diff forever.

### 8. Confirm before creating

Present the title and summary and ask before running `gh pr create`. The user reviews the diff and
approves; opening unasked is too proactive.

### 9. Create

⚠️ If `gh` answers *"Could not resolve to a Repository"*, check `gh auth status` before believing it —
a personal account active against a work org produces exactly that message, and `git push` will have
just succeeded because `git` and `gh` use different credentials. Retry with a per-invocation token
rather than switching accounts:
`GH_TOKEN="$(gh auth token --hostname github.com --user <org-account>)" gh pr create ...`.
If that still fails the cause is elsewhere (scopes, SSO, a renamed repo).

Body carries: what, why, verification evidence, review tier, and any known-open issues the PR does
**not** fix. State what was proven live versus what was only inspected — they are different claims.

### 10. Verify after opening

Confirm checks are green and the diff is what you intended. If it grew past the tier thresholds,
re-run gate 5.

⚠️ **Never close a PR as an alternative to merging.** Even if the change is already applied by hand,
merge it — closing leaves `main` describing something that is not deployed.

⚠️ Infrastructure objects applied from a branch do **not** reconcile on merge. If you applied
before merging, say so in the body and confirm the live environment matches the branch.

## References

- This plugin's README § Review policy — tier table, Codex governance
- Your project's commit convention — conventional commits, attribution, ticket references
- `[[plan-implementation]]` — orchestrating the work this ships
