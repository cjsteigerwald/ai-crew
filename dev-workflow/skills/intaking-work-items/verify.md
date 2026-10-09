# Verify

Detail for SKILL.md's `## 7. Verify`. Results go in the doc's `## Verification evidence` table;
fixes and retries go in its `## Run log`.

## When

- Once, on the final branch after all merges; never trust a worker's report, re-run it.
- Again on the commit Ship pushes whenever a rebase or review fix changed the tree. Evidence is
  stale once the tree changes.

## Order

1. **Repo checks** — full suite, lint, type checks as the repo names them.
2. **Each active AC**, by its AC→test row:
   - **Automated** — run it, quote the output line, record the commit. Run the red check below for each new test. Checklist kinds unit and integration map to Automated.
   - **Live read** — read-only commands only (`az … show`, `kubectl get`, `terraform plan`); never
     apply or deploy. A live read verifies an AC only if its output identifies the observed
     artifact's revision and that revision is the shipped commit or built from it; otherwise the
     result is `unverified` and the evidence is marked `context only`.
   - **Person-only** — not run; result `unverified`, with exact steps for the user at close-out.
3. **Definition of done** items, each with evidence or marked post-merge and carried to close-out.

## Red check

For each new test, prove it can fail:

- Copy only test files and fixtures from the branch to the base commit in a throwaway worktree.
  Never copy implementation files.
- The test must fail on an assertion about the AC's behaviour.
- A collection, import, or compile failure is recorded as `red n/a — new interface` only when the
  error names a module or symbol the branch adds. The AC then rests on the head run plus the
  reviewers' check that the test asserts the AC.
- Any other setup failure is a failed check.
- Each new test must pass twice on head. Differing results are a failure.
- Record the base SHA, the command, and the failure reason, and remove the worktree afterwards.

## Failure

- Make up to 2 fix attempts, each in the Run log, then step 7 re-runs in full.
- A third failure is a stop. See [run-modes.md](run-modes.md).
- A wrong or untestable AC is an immediate stop. Never fix it by editing the AC.

## Results

**verified / failed / unverified / not delivered.** A verified row needs a quoted output line.

| AC | Check | Kind | Result | Evidence | Base / head / time |
|---|---|---|---|---|---|
| AC-1 | `pytest tests/test_retention.py::test_purge_after_90d` | automated, new | verified | base: `AssertionError: 30 != 90`; head ×2: `1 passed` | `9f8e7d6` / `a1b2c3d` 14:02 |
| AC-2 | `pytest tests/test_export.py::test_csv_header` | automated, new | verified (red n/a — new interface) | base: `ImportError: export`; head ×2: `1 passed` | `9f8e7d6` / `a1b2c3d` 14:03 |
| AC-3 | log in as read-only user, open /admin | person-only | unverified | steps at close-out | — |
| AC-4 | — | deferred | not delivered | "<user's words>" | — |
