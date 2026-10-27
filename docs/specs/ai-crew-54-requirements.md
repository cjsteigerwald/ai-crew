# ai-crew-54: dev-workflow 0.2.8: enforce the fresh-verifier dispatch boundary with a PreToolUse guard

**Source:** [cjsteigerwald/ai-crew#54](https://github.com/cjsteigerwald/ai-crew/issues/54)
**Linked items:** cjsteigerwald/ai-crew#52 — related (origin of the findings: Codex [high] PR comment 6444673937, verifier I-1/I-2/I-3, S-1; merged as 55a2ac4). No equivalent tracker item.
**Fetched:** 2026-10-27 — ticket status `OPEN`, no comments, sprint `none`, estimate `none`
**Intake by:** Christopher Steigerwald (owner) with Claude, using the `dev-workflow:intaking-work-items` skill
**Status:** Ready — implemented and verified locally (AC-1..AC-19 at `9e79f40`); AC-20 (CI on PR head) and AC-21..AC-23 (live, post-merge) pending. No steps skipped.
**Chain:** sdlc-process

> Snapshot of the ticket on the fetched date plus the decisions below. If the ticket changes,
> re-run intake for the changed rows rather than editing this doc by memory.

## Story

As the owner and reviewer of the dev-workflow plugin, I want the verifier's "read lanes only" dispatch rule enforced by a hook instead of prose, so that a cold-context fresh-verifier cannot spawn a write-capable agent.

## Scope

**In scope**
- New hook `dev-workflow/hooks/verifier-dispatch-gate.py`, registered in `dev-workflow/hooks/hooks.json` on `Agent|Task`, with off switch `CLAUDE_VERIFIER_DISPATCH_GATE=off`.
- Agent bodies `dev-workflow/agents/fresh-verifier.md` and `fresh-verifier-high.md`: one added hook sentence, the rename clause removed, the cost sentence made tier-neutral (I-1). Bodies stay identical.
- S-1 sentence in `dev-workflow/skills/review-policy/SKILL.md` (Full-chain diff paragraph) and `dev-workflow/skills/intaking-work-items/SKILL.md` (diff-pass paragraph).
- Version 0.2.7 → 0.2.8 in `dev-workflow/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` and the `dev-workflow/tests/run.sh` AC-8 check.
- README entry for the new hook in `dev-workflow/README.md`.
- Tests: `dev-workflow/tests/verifier-dispatch-gate.test.sh`, wired into `dev-workflow/tests/run.sh`; extended hooks.json registration check.

**Out of scope**
- Restricting the verifier's Bash — pre-existing, prose-only read-only rule.
- Changes to lane-model-gate.
- Other agents' use of `Agent`.
- Honouring `lanes.scout` / `lanes.reader` renames for verifier dispatch — owner decision; revisit with capability validation if a rename is ever needed.

## Requirements

### Functional
- **FR-1** The hook acts only when `agent_type` is one of `dev-workflow:fresh-verifier`, `dev-workflow:fresh-verifier-high`, `fresh-verifier`, `fresh-verifier-high`. This includes `claude --agent` main sessions. Any other parseable payload (no `agent_type`, or another agent) exits 0 with no output.
- **FR-2** For a verifier caller, the allowed targets are a closed, hardcoded set: exactly `claude-crew:claude-scout` and `claude-crew:claude-reader`.
- **FR-3** For a verifier caller, the hook denies when `subagent_type` is missing, not a string, empty, or not in the allowed set. This covers implementers, `general-purpose`, `fork`, `dev-workflow:code-writer`, verifier recursion, `dev-workflow:codex-adversary` and the bare name `claude-scout`.
- **FR-4** For a verifier caller, the hook denies when `model` is present and non-empty.
- **FR-5** For a verifier caller, the hook denies when `isolation` is present and non-empty. This is unconditional policy, whatever the runtime sends.
- **FR-6** For a verifier caller, the hook denies when `tool_input` is missing or not an object.
- **FR-7** Every deny sets `permissionDecision: "deny"` and a reason that names the rule and ends with: read inline and declare `reading → inline: <denied: reason>`.
- **FR-8** The hook reads no crew config. `lanes.scout` / `lanes.reader` renames are ignored for verifier callers. A renamed lane means the verifier's dispatch is denied and it reads inline (existing Fallback path).
- **FR-9** Unknown caller: stdin unparseable, stdin not a JSON object, or `agent_type` present but not a string → `permissionDecision: "ask"` with reason `verifier-dispatch-gate: unreadable hook input (<detail>); caller unknown`. This matches `ledger_error` in `dev-workflow/hooks/codex-cap-gate.py:55-56`.
- **FR-10** `tool_name` not in {`Agent`, `Task`} → exit 0 with no output, for every caller.
- **FR-11** `CLAUDE_VERIFIER_DISPATCH_GATE=off` → exit 0 with no output, before any parsing.
- **FR-12** Both agent bodies gain one sentence in "Delegate bulk reading": a dispatch hook enforces the scout/reader-only (stock names), no-`model` and no-`isolation` rules, and a denial means read inline and declare `reading → inline: <denied: reason>`.
- **FR-13** Both agent bodies drop the clause "or the names the dispatch gives for those two roles (crew config `lanes.scout` / `lanes.reader`)" from the Lanes bullet (`fresh-verifier.md:25`).
- **FR-14** I-1: both agent bodies replace the whole sentence "Your context runs on the frontier tier, so every file you open here costs the most it can." (`fresh-verifier.md:23`) with tier-neutral wording, e.g. "Your context runs on a costlier tier than the read lanes, so every file you open here costs more than it would there."
- **FR-15** The two agent bodies stay identical (existing parity check, `dev-workflow/tests/run.sh:1226-1228`).
- **FR-16** S-1: review-policy's Full-chain diff paragraph states: "Read the verifier's Lens recommendation (`lens_recommendation`). For each lens it names, dispatch one lens-scoped fresh-verifier or record why not. At most two lens-scoped instances per full-tier review (security, tests)." intaking-work-items' diff-pass paragraph carries the same sentence.
- **FR-17** Version is 0.2.8 in `dev-workflow/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` and the `dev-workflow/tests/run.sh` AC-8 version check (lines 955-971).
- **FR-18** `dev-workflow/README.md` hooks list gains `verifier-dispatch-gate`, with its off switch and the note that renamed scout/reader lanes are not honoured for verifiers.

### Non-functional
- **NFR-1** Python 3 standard library only; same style as `dev-workflow/hooks/codex-cap-gate.py` (off switch first, `emit(...)` helper, `main()` return codes).
- **NFR-2** Type-check before set membership. A `subagent_type` or `agent_type` that is a list or dict (unhashable) must not raise; it is denied or asked as above (Codex round 2 implementation note).
- **NFR-3** The hook reads no config file and no environment path other than the off switch.

## Acceptance criteria

Each AC is testable as written and names how it is verified. Plans and PRs cite these numbers. Test cases named below live in `dev-workflow/tests/verifier-dispatch-gate.test.sh` unless stated. "Both tools" means the case runs once with `tool_name: Agent` and once with `tool_name: Task`. Note: "AC-8" inside `run.sh` is that file's own numbering for the version check, not this doc's AC-8.

- **AC-1** (FR-1, FR-2) Given a caller whose `agent_type` is each of the four verifier spellings, when it dispatches `claude-crew:claude-scout` or `claude-crew:claude-reader` with no `model` and no `isolation`, then the hook exits 0 with no output. Both tools.
  *Verify:* test cases `allow scout` and `allow reader`, looped over the four spellings.
- **AC-2** (FR-3) Given a verifier caller, when `subagent_type` is `claude-crew:claude-implementer-sonnet`, `general-purpose`, `fork`, `dev-workflow:code-writer`, `dev-workflow:fresh-verifier`, `dev-workflow:codex-adversary`, or bare `claude-scout`, then the hook denies. Both tools.
  *Verify:* test cases `deny <name>`, one per value.
- **AC-3** (FR-3, NFR-2) Given a verifier caller, when `subagent_type` is missing, `""`, `123`, a list or a dict, then the hook denies and does not crash. Both tools.
  *Verify:* test cases `deny subagent_type missing`, `empty`, `non-string`, `unhashable`. The `unhashable` case (list and dict) goes beyond the plan's Tests list; it exercises the Codex round 2 note.
- **AC-4** (FR-4) Given a verifier caller dispatching `claude-crew:claude-scout`, when `model` is `haiku`, then the hook denies. Both tools.
  *Verify:* test case `deny scout with model`.
- **AC-5** (FR-5) Given a verifier caller dispatching `claude-crew:claude-scout`, when `isolation` is `worktree`, then the hook denies. Both tools.
  *Verify:* test case `deny scout with isolation`.
- **AC-6** (FR-6) Given a verifier caller, when `tool_input` is missing or is a string, then the hook denies. Both tools.
  *Verify:* test cases `deny tool_input missing` and `deny tool_input string`.
- **AC-7** (FR-7) Given any deny from AC-2 to AC-6, when the output is parsed, then `permissionDecision` is `deny` and the reason names the rule and ends with the read-inline instruction `reading → inline: <denied: reason>`.
  *Verify:* the deny cases assert the decision and the reason suffix.
- **AC-8** (FR-8, NFR-3) Given `CLAUDE_CONFIG_DIR` points at a temp dir whose `plugins/data/crew/config.json` sets `lanes.scout` to `dev-workflow:code-writer`, when a verifier dispatches `dev-workflow:code-writer`, then it is denied; and when it dispatches `claude-crew:claude-scout`, then it is allowed. The same two results hold with a conflicting config file placed under a temp `HOME` (`~/.claude`-style) instead.
  *Verify:* test cases `config ignored (CLAUDE_CONFIG_DIR)` and `config ignored (HOME)`, both tools.
- **AC-9** (FR-1) Given a payload with no `agent_type`, or `agent_type: general-purpose`, or `agent_type: claude-crew:claude-implementer-opus` with `model: opus`, when it dispatches an implementer, then the hook exits 0 with no output. Both tools.
  *Verify:* test cases `pass-through main session`, `pass-through general-purpose`, `pass-through implementer with model`.
- **AC-10** (FR-10) Given a verifier caller, when `tool_name` is `Bash`, then the hook exits 0 with no output.
  *Verify:* test case `pass-through Bash from verifier`.
- **AC-11** (FR-9) Given unparseable stdin, stdin that is a JSON array, or `agent_type: 42`, when the hook runs, then it emits `permissionDecision: "ask"` with a reason starting `verifier-dispatch-gate: unreadable hook input`. For the `agent_type: 42` payload, both tools.
  *Verify:* test cases `ask unparseable`, `ask array`, `ask agent_type non-string`.
- **AC-12** (FR-11) Given `CLAUDE_VERIFIER_DISPATCH_GATE=off`, when a verifier → implementer payload is piped in, then the hook exits 0 with no output. Both tools.
  *Verify:* test case `off switch`.
- **AC-13** (FR-1, FR-10; hook registration) Given `dev-workflow/hooks/hooks.json`, when parsed, then `verifier-dispatch-gate.py` is registered under `PreToolUse` in an entry whose matcher regex matches both `Agent` and `Task`, and its script exists.
  *Verify:* extended hooks.json check in `dev-workflow/tests/run.sh` (current check at lines 1246-1267 asserts only that command paths exist); `bash dev-workflow/tests/run.sh` exits 0.
- **AC-14** (FR-12, FR-13, FR-14, FR-15) Given both agent files, when compared and grepped, then the bodies are identical, each contains the hook sentence, neither contains `lanes.scout` or the tier-sentence "costs the most it can", and each contains the tier-neutral wording.
  *Verify:* existing parity assertion in `dev-workflow/tests/run.sh` (lines 1226-1228) plus new greps added there, `bash dev-workflow/tests/run.sh`.
- **AC-15** (FR-16) Given both skills, when grepped for the S-1 sentence "At most two lens-scoped instances per full-tier review (security, tests).", then each file contains it once.
  *Verify:* `grep -c "At most two lens-scoped instances per full-tier review (security, tests)." dev-workflow/skills/review-policy/SKILL.md dev-workflow/skills/intaking-work-items/SKILL.md` → `1` for each; also asserted in `dev-workflow/tests/run.sh`.
- **AC-16** (FR-17) Given the plugin manifest and the marketplace entry, when read, then both say `0.2.8`.
  *Verify:* the AC-8 version check in `dev-workflow/tests/run.sh` (lines 955-971) updated to 0.2.8; `bash dev-workflow/tests/run.sh`.
- **AC-17** (FR-18) Given `dev-workflow/README.md`, when grepped, then it names `verifier-dispatch-gate`, `CLAUDE_VERIFIER_DISPATCH_GATE=off` and the not-honoured-renames note.
  *Verify:* `grep -n "verifier-dispatch-gate\|CLAUDE_VERIFIER_DISPATCH_GATE" dev-workflow/README.md` → matches for both; person check of the renames note in diff review.
- **AC-18** (NFR-1) Given the hook source, when its imports are listed, then only standard-library modules appear, and the file is executable like `codex-cap-gate.py`.
  *Verify:* `grep -nE "^(import|from) " dev-workflow/hooks/verifier-dispatch-gate.py` shows stdlib only; `test -x dev-workflow/hooks/verifier-dispatch-gate.py`. Adding it to the executable list at `dev-workflow/tests/run.sh:1239` is an implementation choice, flagged for the plan.
- **AC-19** (all) Given the head commit, when every CI check is run locally, then all pass.
  *Verify:* the `tests` workflow steps from `.github/workflows/tests.yml`: `bash scripts/scrub-check.sh --check-overbroad --allow scripts/scrub-allow.txt .`, `bash scripts/check-vendored-libs.sh`, `bash lib/tests/test-crew-config.sh`, `bash scripts/tests/test-scrub-check.sh`, `bash scripts/tests/test-scrub-history.sh`, and `for t in */tests/run.sh; do bash "$t"; done`. Run the last with `/bin/bash` too (macOS job).
- **AC-20** (all) Given the PR head SHA, when the `tests` workflow finishes, then every job is green on that exact SHA.
  *Verify:* `gh pr checks <PR> --repo cjsteigerwald/ai-crew` with the head SHA recorded.
- **AC-21** (FR-1, FR-2, NFR) Given installed 0.2.8 in a restarted session, when one raw PreToolUse stdin is captured from inside a verifier subagent by a temporary local debug hook outside the repo, then the `agent_type` value and the `tool_input` keys (no prompt text) are recorded with `claude --version`.
  *Verify:* live read; capture recorded in the PR.
- **AC-22** (FR-2, FR-3, FR-5) Given installed 0.2.8, when each of `dev-workflow:fresh-verifier` and `dev-workflow:fresh-verifier-high` attempts one scout dispatch, one implementer dispatch, and one scout dispatch with `isolation: worktree`, then the scout dispatch is allowed and the other two are denied.
  *Verify:* live read; evidence is the session JSONL `Agent` `tool_use` entries and the hook's deny `tool_result` text, not the verifier's narrative; recorded in the PR with `claude --version`.
- **AC-23** (FR-1, FR-3) Given installed 0.2.8, when a `claude --agent dev-workflow:fresh-verifier` main session attempts an implementer dispatch, then it is denied.
  *Verify:* live read; session JSONL `tool_use` and deny `tool_result`; recorded in the PR with `claude --version`.

## Definition of done

- [ ] All AC above verified with recorded evidence
- [ ] PR merged with CI green on the exact head SHA
- [ ] Installed plugin updated: `claude plugin marketplace update cjs-plugins`, then `claude plugin update dev-workflow@cjs-plugins` at user and project scope
- [ ] Live evidence (AC-21 to AC-23) recorded in the PR
- [ ] Issue cjsteigerwald/ai-crew#54 closed

## Dependencies and gates

| Item | Kind | State on fetched date |
|---|---|---|
| Full-tier diff review: fresh-verifier (Opus) plus codex-adversary in one message; churn (A..HEAD ÷ B..A, limit 20%) recorded for any fix | blocks | open |
| Owner OK for commit and push | blocks | open |
| CI green on the head SHA before merge | blocks | open |
| dev-workflow 0.2.7 stays installed until the PR merges and 0.2.8 is installed | informs | done (0.2.7 installed) |
| Codex plan review (ledger `plan:verifier-dispatch-guard`, rounds 2 of 3 used) | informs | done (PASS WITH NITS) |

## Test plan

| AC | Kind | Seam | Catches / misses | Test name | Location |
|---|---|---|---|---|---|
| AC-1 | integration | hook stdin → stdout and exit code | catches wrong allowlist or caller scope; misses runtime field names | `allow scout`, `allow reader` (4 spellings) | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-2 | integration | hook stdin → stdout and exit code | catches any write-capable or recursive target slipping through; misses lanes not yet invented | `deny <name>` | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-3 | integration | hook stdin → stdout and exit code | catches missing, empty, non-string and unhashable targets, and crashes | `deny subagent_type missing / empty / non-string / unhashable` | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-4 | integration | hook stdin → stdout and exit code | catches model override from a verifier | `deny scout with model` | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-5 | integration | hook stdin → stdout and exit code | catches isolation override; misses whether the runtime sends the field (AC-22 covers it) | `deny scout with isolation` | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-6 | integration | hook stdin → stdout and exit code | catches malformed `tool_input` | `deny tool_input missing / string` | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-7 | integration | hook stdin → stdout | catches a deny without the read-inline recovery text | deny-case reason assertions | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-8 | integration | hook stdin → stdout with temp `CLAUDE_CONFIG_DIR` and `HOME` | catches any config read; misses config paths not under those two | `config ignored (CLAUDE_CONFIG_DIR)`, `config ignored (HOME)` | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-9 | integration | hook stdin → stdout and exit code | catches over-reach onto non-verifier callers | `pass-through ...` | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-10 | integration | hook stdin → stdout and exit code | catches over-reach onto other tools | `pass-through Bash from verifier` | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-11 | integration | hook stdin → stdout | catches a silent pass on unknown caller | `ask unparseable / array / agent_type non-string` | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-12 | integration | hook env + stdin → exit code | catches a broken off switch | `off switch` | `dev-workflow/tests/verifier-dispatch-gate.test.sh` |
| AC-13 | integration | `hooks/hooks.json` parse in run.sh | catches a missing or mismatched registration; misses the runtime actually loading it (AC-22) | hooks.json registration assertion | `dev-workflow/tests/run.sh` |
| AC-14 | integration | agent files, parity diff and grep | catches body drift between variants and stale clauses | parity and clause assertions | `dev-workflow/tests/run.sh` |
| AC-15 | integration | skill files, grep | catches a missing S-1 sentence; misses whether callers follow it | S-1 sentence assertion | `dev-workflow/tests/run.sh` |
| AC-16 | integration | manifests parse in run.sh | catches a missed version location | version check (run.sh AC-8) | `dev-workflow/tests/run.sh` |
| AC-17 | integration | README grep | catches a missing entry; misses wording quality | README grep | `dev-workflow/tests/run.sh` or command in PR |
| AC-18 | integration | source grep, file mode | catches a non-stdlib import or lost exec bit | imports and mode check | command in PR |
| AC-19 | integration | repo CI commands | catches regressions elsewhere in the repo | CI mirror | local shell |
| AC-20 | integration | GitHub Actions | catches platform differences (Linux, macOS bash 3.2) | `tests` workflow | GitHub |
| AC-21 | live read | real Claude Code session, temporary debug hook | catches doc-versus-runtime field name drift | raw capture | restarted session after plugin update |
| AC-22 | live read | real verifier subagents, session JSONL | catches the hook not loading for subagents or not denying | both-variants dispatch attempts | restarted session after plugin update |
| AC-23 | live read | `claude --agent` session, session JSONL | catches `--agent` sessions escaping the guard | `--agent` implementer attempt | restarted session after plugin update |

Repo-wide checks: GitHub workflow `tests` (jobs `ubuntu` run steps and `macos`): `bash scripts/scrub-check.sh --check-overbroad --allow scripts/scrub-allow.txt .`; `bash scripts/check-vendored-libs.sh`; `bash lib/tests/test-crew-config.sh`; `bash scripts/tests/test-scrub-check.sh`; `bash scripts/tests/test-scrub-history.sh`; every `*/tests/run.sh` (`claude-crew`, `codex-crew`, `crew-gates`, `dev-workflow`, `harness-skills`, `tech-research`); the private-denylist scrub step runs only in CI.

## Verification evidence

| AC | Check | Kind | Result | Evidence | Base / head / time |
|---|---|---|---|---|---|
| AC-1..AC-12 | `bash` and `/bin/bash dev-workflow/tests/verifier-dispatch-gate.test.sh` | automated, new | verified | RED per slice before the hook existed (`hooks/verifier-dispatch-gate.py not found`, then 52 and 12 failing cases); head: 115 PASS, "all tests passed", rc 0 under bash 5.3 and 3.2 | `55a2ac4` / `9e79f40` 11:38 |
| AC-13..AC-17 | `bash` and `/bin/bash dev-workflow/tests/run.sh` | automated, new assertions | verified | RED 19 failures before the edits; head: "PASSED", rc 0 | `55a2ac4` / `9e79f40` 11:38 |
| AC-18 | imports and file mode | automated | verified | imports `json`, `os`, `sys` only; `git ls-tree` mode 100755; run.sh executable list | — / `9e79f40` |
| AC-19 | CI mirror (`.github/workflows/tests.yml`) | automated | verified | scrub-check, check-vendored-libs, test-crew-config, test-scrub-check, test-scrub-history rc 0; all six `*/tests/run.sh` rc 0 under bash and `/bin/bash` | — / `9e79f40` 11:38 |
| AC-20 | `tests` workflow on the PR head | CI | pending | PR not opened | — |
| AC-21..AC-23 | live capture and dispatch attempts | live read | pending | runs after merge and plugin update | — |

## Run log

| Time | Step | Event | Attempt | Blocker |
|---|---|---|---|---|
| 09:29 | step 4 | requirements doc written | 1 | — |
| 09:29 | step 4 | review base recorded: merge-base `55a2ac4` on branch `feat/verifier-dispatch-guard` | 1 | — |
| 09:45 | step 4 | owner OK on the doc incl. AC-3 unhashable case, AC-18, live-after-merge ("OK on all three, go ahead") | 1 | — |
| 09:47 | stage 1 | review ledger linked: `branch:feat/verifier-dispatch-guard` ← `plan:verifier-dispatch-guard`, count 2 of cap 3 | 1 | — |
| 09:51 | step 5 | owner-approved writeback: intake comment on cjsteigerwald/ai-crew#54 (issuecomment-6448027991) | 1 | — |
| 09:53 | stage 5 | policy review (sdlc-policy-reviewer) for start implementation: PASS; holds: no commit/push/PR without owner OK; Codex diff pass is round 3 of 3 | 1 | — |
| 09:53 | stage 5 | implementer dispatched (claude-crew:claude-implementer-opus), uncommitted; code-review reviews the pinned uncommitted patch | 1 | — |
| 10:05 | stage 5 | implementer done (RED→GREEN per slice); orchestrator re-ran scrub, hook tests, dev-workflow run.sh: green | 1 | — |
| 10:10 | stage 5 | owner OK: local commit; committed `52fef9c` (unpushed) | 1 | — |
| 10:15 | stage 5 | policy review: hand to code-review and diff pass — PASS | 1 | — |
| 10:25 | stage 5 | code-review @52fef9c: Standards 0/0/7 flagged, Spec 0/0 | 1 | — |
| 10:50 | stage 5 | full-tier diff pass @52fef9c: fresh-verifier (Opus) APPROVE_WITH_COMMENTS 0/0/5 info, lens_recommendation none; codex-adversary round 3 of 3 PASS | 1 | — |
| 11:20 | stage 5 | fix wave committed `9e79f40` (owner OK: fix + doc-status commits); churn 13/622 = 2.1% | 1 | — |
| 11:30 | stage 5 | policy review: bounded re-review + Verify — PASS; hold H1: anchor the bounded re-review at the final head | 1 | — |
| 11:38 | step 7 | Verify at `9e79f40`: AC-1..AC-19 verified (table above) | 1 | — |

## Risks

- Runtime field names differ from the docs (`agent_type`, `tool_input` keys, `isolation`) — the guard could miss a verifier or never see a field — AC-21 live capture, which can run only after merge and plugin update; a mismatch is fixed in a follow-up patch (0.2.9), with the off switch available meanwhile.
- A renamed scout or reader lane blocks verifier dispatch — the verifier reads inline (existing Fallback) — documented in the README; owner decision.
- A hook bug denies a legitimate dispatch — verifier loses lane reads, costs more context — off switch `CLAUDE_VERIFIER_DISPATCH_GATE=off`; 0.2.7 stays installed until live evidence is in.
- `--agent` verifier sessions are restricted like subagents — intended; documented in the hook and live-tested (AC-23).
- Verifier Bash stays unrestricted — a verifier can still run write commands — out of scope; prose rule only.

## Decision log

| # | Question | Answer | Who / date |
|---|---|---|---|
| 1 | Build the guard vs accept the I-2 informational rating | Build the guard; keep 0.2.7 installed meanwhile | Christopher Steigerwald, 2026-10-27 |
| 2 | F1 (high): configured lane names could authorize write lanes | Closed allowlist of the two stock names; config never read; `dev-workflow:code-writer` negative test and config-ignored test added | Christopher Steigerwald, 2026-10-27 |
| 3 | F2 (medium): fail-open on malformed input cites a false precedent | Unparseable or non-object stdin, or non-string `agent_type` → ask (matches `codex-cap-gate.py:56`); verifier with malformed `tool_input` → deny; payload without `agent_type` → main session, pass | Christopher Steigerwald, 2026-10-27 |
| 4 | F3 (medium): config path disagrees with routing configuration | Moot: the guard reads no config; tests set conflicting files under `CLAUDE_CONFIG_DIR` and `HOME` | Christopher Steigerwald, 2026-10-27 |
| 5 | F4 (medium): tests do not cover the whole boundary | Every case under both `Agent` and `Task`; `fork` and malformed `tool_input` cases; `--agent` session live; registration assertion with a matcher covering both tools; live evidence for both variants from transcript entries plus `claude --version` | Christopher Steigerwald, 2026-10-27 |
| 6 | Codex note on S-1: the two-lens limit is undefined | Define the limit directly in review-policy's sentence (FR-16) | Christopher Steigerwald, 2026-10-27 |
| 7 | Round 2 nit 1: agent bodies still permit renames (`fresh-verifier.md:25`) and keep "costs the most it can" (`:23`) | Delete the rename clause; replace the whole cost sentence (FR-13, FR-14) | Christopher Steigerwald, 2026-10-27 |
| 8 | Round 2 nit 2: `isolation` policy vs "do not depend on it until captured" conflict | Rejection is unconditional policy; the schema question is separate; live test adds an isolation attempt (FR-5, AC-22) | Christopher Steigerwald, 2026-10-27 |

## Deferred and out-of-scope items

| Item | Status | Source | User's words | Gap left open | Follow-up |
|---|---|---|---|---|---|
| Restrict the verifier's Bash | out of scope | plan §Out of scope | "Restricting the verifier's Bash. That is pre-existing, prose-only read-only." | Verifier Bash can still write | none |
| Change lane-model-gate | out of scope | plan §Out of scope | "Changing lane-model-gate." | None | none |
| Other agents' use of `Agent` | out of scope | plan §Out of scope | "Other agents' Agent use." | Non-verifier agents stay unguarded by this hook | none |
| Honour `lanes.scout` / `lanes.reader` renames for verifiers | out of scope | owner decision | "owner decision; revisit with capability validation if a rename is ever needed" | Renamed lanes cannot be used by verifiers | none |

## Gap table at skip

None — step 3 completed.

## Chain artifacts

- Wayfinding: none
- `CONTEXT.md` and ADR paths grilling changed: none
- Work branch (also the integration branch): `feat/verifier-dispatch-guard`, worktree `.claude/worktrees/verifier-dispatch-guard` in the ai-crew checkout
- Review base: `55a2ac4`
- Review tier: Full
- Plan pass: `plan pass @rev3 (codex-adversary round 2 PASS WITH NITS, ledger plan:verifier-dispatch-guard)`
- Spec issue: cjsteigerwald/ai-crew#54
- Tickets: none — one slice (the spec issue is the delivery issue)
- Code-review: `code-review @52fef9c` (Standards 0 must / 0 should / 7 flagged; Spec 0 must / 0 should)
- Diff pass: `full-tier diff pass @52fef9c (base 55a2ac4)` — fresh-verifier (Opus) APPROVE_WITH_COMMENTS; codex-adversary PASS (ledger `branch:feat/verifier-dispatch-guard` round 3 of 3, cap reached)
- S-1: `lens_recommendation` = none ("security swept in full; test gaps already scheduled"); no lens-scoped instance dispatched
- Review dispositions: accepted — duplicated `emit()` and test helpers (standalone hooks), separate hooks.json entry, verbatim S-1 sentence in two skills (run.sh enforces it), `RecursionError` catch, extra tests, test section order; fixed in `9e79f40` — docstring clause (fv-3), spec path in test header, tests for padded scout name, `model` false/0/[], `isolation` false, Bash with `agent_type: 42` (fv-4); kept — `agent_type: null` → ask per FR-9, AC-21 decides (fv-1); no change — top-level exit 1 on emit failure matches codex-cap-gate, out of scope (fv-2); fixed in the doc-status commit — stale status sections (fv-5)
- Fix: `9e79f40`, churn A..HEAD ÷ B..A = 13 / 622 = 2.1% before this doc commit
- Bounded re-review: pending, anchored at the final head (policy hold H1)
- Verify: `verify @9e79f40` (AC-1..AC-19)
- Draft PR: none yet
- **Last completed stage:** Verify (bounded re-review pending)
