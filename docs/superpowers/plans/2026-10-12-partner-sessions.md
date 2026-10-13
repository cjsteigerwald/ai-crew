# Partner-session coordinator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `dev-workflow:coordinating-partner-sessions`, which intake's sdlc-process chain calls at stage 5 to run one attended `sdlc-process:sdlc-process` partner session per GitHub issue — in parallel where the blocked-by graph allows, verified and fast-forward-merged into the ticket branch one at a time — and hand back to intake steps 7–8 for one draft PR.

**Architecture:** The coordinator loop is prose (`SKILL.md` plus three reference files), because launching sessions, reading `claude agents --json`, `SendMessage` and talking to the user are model actions. Every decision that must come out the same way every time lives in four bash scripts under `scripts/`: `parse-msg.sh` (validate one partner frame), `frontier.sh` (what to launch; cycle refusal), `ff-merge.sh` (fast-forward-only merge) and `ledger.sh` (the only writer of coordinator state: lock, transitions, intents, outbox, binding, dedup, reconciliation). The scripts never call `claude` or `gh`; the coordinator passes `claude agents --json` output in as a file. A scripted coordinator-contract test drives the four scripts through a whole run, including a crash and resume, so the prose loop's script contract is tested end to end.

**Tech Stack:** Markdown skill files; bash 3.2-compatible scripts using `git` and `jq` (≥1.6); behavioural tests in the style of `dev-workflow/tests/test-audit-sh.sh`; `grep -qF` pins in `dev-workflow/tests/run.sh`. Run everything with `bash dev-workflow/tests/run.sh` (prints `PASSED`, exits 0); on macOS also `/bin/bash dev-workflow/tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-10-12-partner-sessions-design.md` (approved at `3566c05`; revised in this plan's commit for the plan review, including Decision 13). The transition table, ledger, message protocol, merge rule, verification gate, error handling and preflight sections are normative; every task below cites them.

## Global Constraints

- Skill directory: `dev-workflow/skills/coordinating-partner-sessions/`; scripts in its `scripts/` (repo convention: `copilot-agent-readiness/scripts/audit.sh`).
- Scripts: bash 3.2 compatible (no associative arrays, `mapfile`, `${var,,}`, `wait -n`); BSD and GNU tools both (no `sed -i` without a suffix, no `date -d`, no `readlink -f`, no `timeout`); depend only on `git`, `jq`, POSIX tools; never `eval`, never interpolate message text into a command. Scripts call each other as `"${BASH:-bash}" "$DIR/x.sh"`, and every test runs scripts with `"$BASH"`, so `/bin/bash run.sh` on macOS exercises bash 3.2 end to end.
- Scripts never invoke `claude`, `gh` or the network. Live-session data arrives as a file argument holding `claude agents --json` output.
- Message regexes, verbatim from the spec: `#n` `^#[0-9]+$`; `gen=<g>` `^gen=[0-9]+$`; `<sha>`/`<head>` `^[0-9a-f]{40}$`; `<branch>` `^[a-z0-9][a-z0-9._/-]*$` and passes `git check-ref-format --branch`.
- Frame: `<cross-session-message from="<name>">…</cross-session-message>`; `from` must equal the recorded session name exactly. The coordinator passes the whole frame; `parse-msg.sh --frame` extracts `from` (this plan's design, now adopted in the spec's Message protocol).
- `synced=<head>` in `DONE` is informational: parsed and stored, never used for a decision.
- Statuses, verbatim: `pending`, `launched`, `started`, `blocked-on #m`, `done-claimed`, `verifying`, `rework-n/3` (stored as `rework-1/3`, `rework-2/3`), `resync-requested`, `merged`, `failed`, `cancelled`. Live = `launched`, `started`, `done-claimed`, `verifying`, `rework-n/3`, `resync-requested`.
- Concurrency cap default `3`. Rework budget `3` per generation; relaunch resets it.
- Names: coordinator recommended `<KEY>-coord`; partner `<KEY>-<n>`; partner branch `<key>-<slug>-<n>`; superseded branch `<key>-<slug>-<n>-g<old>`; ticket branch `<key>-<slug>`.
- Ledger (spec Decision 13): `$(git rev-parse --git-common-dir)/partner-sessions/<KEY>/ledger.json`, plain JSON, written only by `ledger.sh` (temp file + `mv -f`). Beside it: `lock/` (run lock, holding `holder` = `<session-id> <nonce>`), `takeover/` (transient), `ledger.log` (append-only diagnostics, not state). Never in a working tree, never committed.
- Lock ownership token: `ledger.sh lock` prints `owner=<session-id>:<nonce>`; every mutating `ledger.sh` call requires it in env `PS_OWNER` and exits `40` if it no longer matches `lock/holder`.
- Version floors: Claude Code `v2.1.236` (`v2.1.248` on Bedrock, Vertex or Foundry, or with flag fetching off).
- Canary timeout: `600` seconds per leg, via a background `sleep 600` Bash call as the timer (decided here — the spec's canary-timeout open item). On expiry the coordinator reads `--json`; only a canary that has ended without the expected message is a failed leg (Task 9).
- External blockers (a `Blocked by: #n` naming an issue outside this ticket's set) extend the spec, which reads only in-ticket edges: recorded as `external`, satisfied only if closed when read; otherwise the coordinator asks the user (wait, or remove the edge) before writing the ledger.
- `dev-workflow/.claude-plugin/plugin.json` version `0.1.7` → `0.1.8`.
- `SKILL.md` under 500 lines; description ≤ 1024 chars.
- Public-repo hygiene: no whole-word `ces` in `coordinating-partner-sessions/` or `intaking-work-items/` (`run.sh:397` enforces it for intake). Decision 7's retrospective target is written as "the workspace's ticket-creation skill (the one that created this ticket)". Fixtures carry no UUIDs, logins, avatar or HTML URLs (`scripts/scrub-patterns.sh:170` flags any UUID).
- Every existing `run.sh` assertion stays green. Do not edit sdlc-process, superpowers or mattpocock plugin files.
- No push, PR or GitHub write during implementation except where a step says so and the user confirms it.

## Review Focus

1. **The canary partner asks the user a readiness question before `STARTED`, or is slow.** Expected: when the 600 s timer expires and `--json` says `blocked` or `working`, the timer restarts and the user is told; it is not a failed leg (Task 9 pins; Task 5 `json_blocked_noop`).
2. **The ticket-branch worktree is dirty or on another branch when a merge runs** (the user edited files in the coordinator's checkout). Expected: `ff-merge.sh` exits `3` without touching anything; the coordinator tells the user and never stashes or resets. The ledger itself never makes it dirty (Task 4 tests; Task 6 `merge_with_real_ledger`).
3. **A `Blocked by: #n` names an issue outside this ticket's set.** Expected: recorded as external; `frontier.sh` never launches an issue with an open external blocker (Task 3 test).
4. **A partner line arrives with trailing spaces or a CRLF ending.** Expected: trailing spaces and one trailing `\r` are stripped, then validated; an embedded newline or `\r` elsewhere is rejected (Task 2 tests).
5. **Two tickets coordinated at once in the same repo.** Expected: independent `partner-sessions/<KEY>/` directories, locks and names; one coordinator never takes or reads the other's lock (Task 5 test).

---

### Task 1: Resolve the spec's open items (spikes)

Non-code. Results go in a `## Spike results` section appended to this plan, plus fixtures later tasks consume.

**Files:**
- Modify: `docs/superpowers/plans/2026-10-12-partner-sessions.md` (append `## Spike results`)
- Create: `dev-workflow/tests/fixtures/partner-sessions/agents.json` — the shape of a real `claude agents --json --all` sample; every `sessionId` replaced with a non-UUID placeholder (`sid-coord`, `sid-1`, `sid-2`, …), names with `TEST-coord`, `TEST-1`, …; no paths, no other identifiers.
- Create: `dev-workflow/tests/fixtures/partner-sessions/blocked_by.json` — the step 1 response trimmed to `[{"number":<n>,"state":"open|closed"}]` only.

**Interfaces — Produces:** the exact GitHub read command for blockers (Task 9 uses it verbatim); the field names of `claude agents --json` entries (`name`, `sessionId`, `state`, and the process-liveness field) used by Task 5's lock liveness and Task 6's reconciliation.

- [ ] **Step 1: GitHub blockers endpoint.** Spike results use the same `sid-*`/`TEST-*` placeholders as the fixtures: no real `sessionId`, no paths (`scrub-patterns.sh` flags both). Confirm the write command too: `gh api --method POST repos/<owner>/<repo>/issues/<n>/dependencies/blocked_by -F issue_id=<blocker-db-id>` (documented in `docs/agents/issue-tracker.md:68`); Task 9 uses it for an accepted `STUCK needs=#m` edge. Run `gh api repos/cjsteigerwald/ai-crew/issues/<n>/dependencies/blocked_by` against an issue that has a native blocker (create a throwaway pair only with the user's confirmation, then close both). Expected: a JSON array of issue objects with `number` and `state`. Record the command and one trimmed output. If it 404s, record that and the fallback: parse body lines matching `^Blocked by: #[0-9]+(, *#[0-9]+)*$`.
- [ ] **Step 2: `claude agents --json` shape.** Run `claude agents --json --all`; build the fixture from its shape as above. Record which field carries the process ID or liveness (expected `pid`); if none, record that — the liveness fallback is then "listed with `state` not in {`stopped`, `failed`}" (spec, Single writer).
- [ ] **Step 2b: coordinator's own session ID.** Record how the coordinator learns its own `sessionId` (needed by `ledger.sh lock`): the `claude agents --json --all` entry whose `name` equals the coordinator's name, or an environment variable if the spike finds one. Task 9 preflight uses the recorded method.
- [ ] **Step 3: `--resume` + `--name` (live, run by the orchestrator or the user, ~30 s).** `claude --bg --name ps-spike-a "reply OK then stop"`; wait for `done`; `claude stop <id>`; `claude --resume <sessionId> --bg --name ps-spike-b "reply OK"`; `claude agents --json --all`. Expected evidence: the resumed entry's `sessionId` equals the original and its `name` is `ps-spike-b` (or record what it is). Remove both with `claude rm`.
- [ ] **Step 4: Verify.** `bash dev-workflow/tests/run.sh` → `ok: scrub-check clean` and `PASSED`.
- [ ] **Step 5: Commit.**

```bash
git add docs/superpowers/plans/2026-10-12-partner-sessions.md dev-workflow/tests/fixtures/partner-sessions/
git commit -m "docs(dev-workflow): record partner-session spike results and fixtures"
```

---

### Task 2: `parse-msg.sh`

**Files:**
- Create: `dev-workflow/skills/coordinating-partner-sessions/scripts/parse-msg.sh`
- Test: `dev-workflow/tests/test-parse-msg-sh.sh`

**Interfaces — Produces:**
- `parse-msg.sh <line>` — one argv argument. Exit `0`: prints `key=value` lines, always `kind=` (`STARTED|DONE|STUCK|SCOPE|FAILED`), `issue=<n>` (digits, no `#`), `gen=<g>`; `DONE` adds `branch=`, `sha=`, `synced=`; `STUCK` may add `needs=<m>`; `STUCK|SCOPE|FAILED` add `reason=<text>` (single line, stored verbatim). Exit `1`: invalid, `error=<reason>` on stderr, nothing on stdout.
- `parse-msg.sh --frame <raw>` — `<raw>` is the full frame text. Exit `0`: prints `from=<name>` then the body's `key=value` lines. Exit `1` if the frame is not exactly one `<cross-session-message from="…">…</cross-session-message>` (an `<agent-message …>` frame or any other is rejected).

- [ ] **Step 1: Write the failing tests** (`test-parse-msg-sh.sh`, same skeleton as `test-audit-sh.sh`: `fail()`, `FAIL` counter, exit 1 on failure; scripts run with `"$BASH"`). Cases and assertions:

| Test | Input | Expect |
|---|---|---|
| valid STARTED | `STARTED #12 gen=1` | rc 0; stdout has `kind=STARTED`, `issue=12`, `gen=1` |
| valid DONE | `DONE #12 gen=2 abc-x-12 <40 hex> synced=<40 hex>` | rc 0; `branch=abc-x-12`, `sha=`, `synced=` match |
| STUCK needs | `STUCK #12 gen=1 needs=#9 waits on schema` | `needs=9`, `reason=waits on schema` |
| STUCK no needs | `STUCK #12 gen=1 cannot reach the test db` | rc 0; `kind=STUCK`; no `needs=` line; `reason=cannot reach the test db` |
| valid SCOPE | `SCOPE #12 gen=1 needs three PRs` | rc 0; `kind=SCOPE`; `reason=needs three PRs` |
| valid FAILED | `FAILED #12 gen=3 user cancelled` | rc 0; `kind=FAILED`; `gen=3`; `reason=user cancelled` |
| missing gen | `STARTED #12` | rc 1, stdout empty |
| bad gen | `STARTED #12 gen=x` | rc 1 |
| short sha | DONE with 39-hex sha | rc 1 |
| uppercase sha | DONE with `ABC…` | rc 1 |
| bad branch | DONE with branch `-x` and with `a..b` | rc 1 (`check-ref-format`) |
| trailing prose on DONE | valid DONE + ` extra` | rc 1 |
| unknown kind | `MERGED #12 gen=1` | rc 1 |
| metachar reason | `FAILED #12 gen=1 $(touch $T/pwned); \`touch $T/pwned2\`` | rc 0; `reason=` holds the literal text; `$T/pwned` and `$T/pwned2` do not exist |
| metachar branch | DONE with branch `x;touch $T/p` | rc 1; `$T/p` does not exist |
| CRLF / trailing space (Review Focus 4) | `STARTED #12 gen=1  \r` | rc 0 |
| embedded newline | `STARTED #12 gen=1\nDONE …` | rc 1 |
| frame ok | `<cross-session-message from="ABC-12">STARTED #12 gen=1</cross-session-message>` | rc 0; `from=ABC-12` first line |
| frame wrong kind | same body in `<agent-message from="ABC-12">…</agent-message>` | rc 1 |
| frame two messages | two frames concatenated | rc 1 |
| frame metachar from | `from="a$(touch $T/f)"` | rc 1; `$T/f` does not exist |

- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/test-parse-msg-sh.sh` → `FAIL: … parse-msg.sh not found`, exit 1.
- [ ] **Step 3: Implement `parse-msg.sh`.** Read the argument into a variable only; first reject any newline and any `\r` other than one trailing (a bare `read -r` reads only the first line, so the embedded-newline test would otherwise pass wrongly); then strip trailing spaces and one trailing `\r`; split with `read -r` / parameter expansion; validate each field with `[[ =~ ]]` against the Global Constraints regexes (`from` against `^[A-Za-z0-9][A-Za-z0-9._-]*$`) and `git check-ref-format --branch`; print with `printf '%s\n'`.
- [ ] **Step 4: Run to verify it passes.** Same command → all `ok:` lines, exit 0.
- [ ] **Step 5: Commit.** `git add` both files; `git commit -m "feat(dev-workflow): add parse-msg.sh for partner messages"`.

---

### Task 3: `frontier.sh`

**Files:**
- Create: `dev-workflow/skills/coordinating-partner-sessions/scripts/frontier.sh`
- Test: `dev-workflow/tests/test-frontier-sh.sh`

**Interfaces:**
- Consumes: the ledger JSON shape (Task 5 `ledger.sh get` emits it): `.cap`, `.issues["<n>"].status`, `.issues["<n>"].blockers` (array of numbers), `.issues["<n>"].external` (array of `{"n":<num>,"closed":true|false}`).
- Produces:
  - `frontier.sh <state.json>` — prints the issue numbers to launch now, one per line, ascending: status `pending`, every blocker `merged`, every external blocker `closed`, limited to `cap − (live count)`. Exit `0` (empty output is fine). Exit `2` on a cycle, printing `cycle: 3 -> 5 -> 3` to stderr.
  - `frontier.sh --live-count <state.json>` — prints the number of live issues. This is the one definition of "live": status `launched`, `started`, `done-claimed`, `verifying`, `resync-requested`, or `rework-<k>/3` (prefix match). `blocked-on #m`, `pending`, `failed`, `merged`, `cancelled` are not live. `ledger.sh slots` and the `intent launch` slot check call it; nothing else defines it.
  - `frontier.sh --check-edge <state.json> <n> <m>` — exit `0` if adding "`n` blocked by `m`" keeps the graph acyclic, `2` (with the cycle on stderr) if not.

- [ ] **Step 1: Write the failing tests.** JSON fixtures built inline with heredocs:

| Test | Graph / statuses | Expect |
|---|---|---|
| independent | 1,2,3 pending, no edges, cap 3 | `1 2 3` |
| cap | 1..5 pending, cap 3 | `1 2 3` |
| cap minus live | 1 `started`, 2 `verifying`, 3,4 pending, cap 3 | `3` |
| live count per status | one issue each in `launched`, `started`, `done-claimed`, `verifying`, `resync-requested`, `rework-1/3` | `--live-count` prints `6` |
| non-live statuses | one each in `blocked-on #9`, `failed`, `merged`, `cancelled`, `pending` | `--live-count` prints `0` |
| chain A→B→C | 2 blocked by 1, 3 by 2; all pending | `1` |
| chain after merge | 1 merged, 2,3 pending | `2` |
| diamond | 3 blocked by 1 and 2; 1 merged, 2 started | empty |
| failed blocker | 1 failed, 2 blocked by 1 | 2 not listed |
| cancelled blocker | 1 cancelled, 2 blocked by 1 | 2 not listed |
| blocked-on released | 2 `pending` (was blocked-on 1), 1 merged | `2` |
| external open (Review Focus 3) | 1 pending, external `{"n":40,"closed":false}` | empty |
| external closed | same, `closed:true` | `1` |
| cycle | 1↔2 | exit 2, stderr contains `cycle:`; run in background, `kill` after 5 s → fail |
| check-edge ok | 2 blocked by 1; check `3 1` | exit 0 |
| check-edge cycle | 2 blocked by 1; check `1 2` | exit 2 |

- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/test-frontier-sh.sh` → not found, exit 1.
- [ ] **Step 3: Implement.** Cycle detection by iterative removal of nodes with no unremoved blockers (Kahn) in `jq`; whatever remains is cyclic. Ordering ascending numeric.
- [ ] **Step 4: Run to verify it passes.** Exit 0.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): add frontier.sh launch selection and cycle check"`.

---

### Task 4: `ff-merge.sh`

**Files:**
- Create: `dev-workflow/skills/coordinating-partner-sessions/scripts/ff-merge.sh`
- Test: `dev-workflow/tests/test-ff-merge-sh.sh`

**Interfaces — Produces** (run with cwd = the worktree that has the ticket branch checked out; the strict dirty check stays — the ledger is in git metadata, so it never trips it):
- `ff-merge.sh --check <ticket-branch> <sha>` — resolves the branch by ref and never inspects the worktree (so exit `3` does not apply to `--check`); exit `0` if the ticket head is an ancestor of `<sha>`; exit `10` (`resync-needed`) printing `head=<sha>`; never changes a ref. On exit `0` it prints nothing: the coordinator pins the head with `git rev-parse <ticket-branch>` right after (safe, because the 3-arg call re-checks equality and ancestry and exits `10` otherwise).
- `ff-merge.sh <ticket-branch> <sha> <pinned-head>` — fast-forwards (`git merge --ff-only <sha>`) only if the ticket head equals `<pinned-head>` and is an ancestor of `<sha>`; exit `0` printing `head=<sha>`; exit `10` printing the current `head=`.
- Exit `3` (merge call only): the cwd does not have `<ticket-branch>` checked out, or the worktree is dirty (`git status --porcelain` non-empty). Exit `2`: argument errors, an SHA that does not match `^[0-9a-f]{40}$`, or an SHA that does not exist.

- [ ] **Step 1: Write the failing tests.** Each builds a throwaway repo with `mktemp -d`, `git init`, commits, and a ticket branch checked out:

| Test | Setup | Expect |
|---|---|---|
| check current | candidate branched from head + 1 commit | `--check` exit 0; `git rev-parse ticket` unchanged |
| check stale | ticket advanced after candidate branched | `--check` exit 10, stdout `head=<new head>`; refs unchanged |
| clean ff | current candidate, pinned = head | exit 0; ticket head == candidate |
| head moved after pin | pinned = old head, ticket advanced | exit 10; ticket head unchanged |
| diverged | candidate does not contain head | exit 10; unchanged |
| nonexistent sha | 40 hex not in repo | exit 2; unchanged |
| malformed sha | `abc` | exit 2 |
| dirty worktree (Review Focus 2) | untracked file in cwd | exit 3; file still there; refs unchanged |
| wrong branch checked out | cwd on `main` | exit 3 |
| state in git dir is clean | a file written under `$(git rev-parse --git-common-dir)/partner-sessions/K/` | clean ff exit 0 |

- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/test-ff-merge-sh.sh` → exit 1.
- [ ] **Step 3: Implement** with `git merge-base --is-ancestor`, `git rev-parse --verify --quiet "<sha>^{commit}"`, `git symbolic-ref --short HEAD`, `git merge --ff-only`.
- [ ] **Step 4: Run to verify it passes.** Exit 0.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): add ff-merge.sh fast-forward-only integration"`.

---

### Task 5: `ledger.sh` — state, lock, intents, outbox and the transition table

Every state change, the outbox command it implies, the claim it records, the intent it closes and the dependents it releases are one atomic write (spec, Atomic writes).

**Files:**
- Create: `dev-workflow/skills/coordinating-partner-sessions/scripts/ledger.sh`
- Test: `dev-workflow/tests/test-ledger-sh.sh` (Task 6 extends it)

**Interfaces:**
- Consumes: `frontier.sh --check-edge` (Task 3); `git`.
- Ledger fields (the schema Task 8's `ledger.md` documents): top level `key`, `ticketBranch`, `coordinator` (`name`, `sessionId`), `cap`, `canary`, `issues`, `intents`, `outbox`; per issue `status`, `gen`, `blockers`, `external`, `branch`, `testCmd`, `ac`, `sessionName`, `sessionId`, `worktree`, `startSha`, `claim` (`branch`, `sha`, `synced`, `claimSeq`), `rework`, `resyncs`, `mergeSha`, `gateResults`, `reason`.
- Produces — the first argument after the subcommand is the ledger path (`<ledger>` = `…/partner-sessions/<KEY>/ledger.json`; lock and log are its siblings). Exit codes shared by all: `0` applied (prints the new status or requested output), `10` idempotent no-op, `20` message rejected (logged), `30` illegal transition refused (logged), `40` lock held by a live other session or `PS_OWNER` no longer matches (prints `holder=`), `2` usage or I/O error. Every mutating call requires `PS_OWNER`. `done` is the one exception: its exit `1` means "not done".
  - `ledger.sh path <KEY>` — prints `$(git rev-parse --git-common-dir)/partner-sessions/<KEY>/ledger.json` (absolute) and creates the directory.
  - `ledger.sh lock <ledger> <own-session-id> <agents.json>` (`agents.json` is the output of `claude agents --json --all`; the own session ID comes from Task 1 Step 2b) → prints `owner=<session-id>:<nonce>`; `ledger.sh unlock <ledger>` (needs `PS_OWNER`). Protocol (spec, Single writer): `mkdir lock` → write `holder` via temp + `mv`. If `lock` exists: live = holder's ID equals own (re-issue own token), or listed in `agents.json` with a live process (`kill -0 <pid>`; no pid field → `state` not in {`stopped`,`failed`}); missing/empty `holder` = not live. Not live → `mkdir takeover` (fail → exit 40, someone else is taking over); immediately write `takeover/owner` (own session ID); re-check liveness; write a new holder with a fresh nonce via temp + `mv`; re-read and confirm the nonce; `rm -rf takeover`; log `lock-takeover` (old holder, time). A `takeover` dir whose `owner` is not live, or with no `owner` and an mtime older than 60 s (only a crash between `mkdir` and the `owner` write leaves it ownerless), is removed once and the takeover retried.
  - `ledger.sh init <ledger> <KEY> <ticket-branch> <coord-name> <coord-session-id> <issues.json>` — `issues.json` is `[{"n":12,"blockers":[9],"external":[{"n":40,"closed":true}],"branch":"…","testCmd":"…","ac":["AC-1"]}]`; writes every issue `pending`, `gen` 0, `canary` `pending`, `cap` 3. Refuses (exit 2) if the ledger exists. Requires `PS_OWNER`, so the order is always `path`, `lock` (export `PS_OWNER`), `init`. An `external` item is `{"n":<num>,"closed":true|false}`; the coordinator writes the ledger only after the user resolves open externals, so no event flips `closed`; `frontier.sh` still guards on it.
  - `ledger.sh get <ledger> [<n>]` — the JSON state (or one issue) on stdout; the shape `frontier.sh` consumes.
  - `ledger.sh intent <ledger> launch|relaunch <n> <session-name> <worktree> <branch> <base-sha>` (enforces the launch refusals before any side effect: a blocker not `merged`, no free slot via `frontier.sh --live-count`, or `canary` not `passed` with another issue already launched -> exit `30`, nothing recorded; records the issue's prior status and the kind) / `ledger.sh intent <ledger> merge <n> <candidate-sha> <expected-head>` → prints `intent=<id>` (records gen). Intents are closed only by the event that records their outcome.
  - `ledger.sh event <ledger> <n> <event> [args]` — the only way statuses change. Events (one per transition-table row; spec "Transition table"):

| Event | Args | Row (and what the same write also does) |
|---|---|---|
| `launch` | `<intent-id> <session-id>` | `pending → launched`; gen+1; records name, `sessionId`, worktree, branch, start SHA from the intent; closes the intent. Only re-checks that the intent is open; the refusals live on `intent launch` |
| `launch-failed` | `<intent-id>` | launch errored: restores the status recorded in the intent (`pending` for a launch, `failed` for a relaunch); closes the intent |
| `relaunch` | `<intent-id> <session-id>` | `failed → launched`; gen+1; rework reset; closes the intent. No slot -> refused at `intent relaunch` (exit `30`) |
| `queue-check` | `stale <head>` \| `ok` | `done-claimed → resync-requested` (outbox `RESYNC #n <head>`, gen; increments `resyncs`) \| `→ verifying` |
| `gate` | `merged <intent-id> [<results>]` \| `resync <head> [<intent-id>]` \| `fail [<evidence>]` | `verifying → merged` (stores the gate results per issue; closes the merge intent; releases dependents) \| `resync-requested` (outbox `RESYNC`; closes the given merge intent in the same write; increments `resyncs`) \| `rework-n/3` (outbox `REWORK #n <evidence>`; the evidence is stored per issue); third `fail` in a gen → `failed` (reason `rework budget`) |
| `stuck-accept` | `<m>` | live except `done-claimed`/`verifying` (those exit `30`) → `blocked-on #m` via `--check-edge` (exit 30 + `cycle` on refusal); appends `m` to `.blockers`; outbox `CANCEL #n` |
| `edge-remove` | — | `blocked-on → pending`; removes the edge from `.blockers` |
| `drop` | `[<reason>]` | `pending\|blocked-on\|failed → cancelled` (reason stored); prints `dependents=<list>` for the user decision |
| `json` | `failed\|stopped\|blocked\|done\|working` | live (not `done-claimed`/`verifying`) + `failed` → `failed`; on `failed\|stopped\|done` for a `blocked-on`/`cancelled` issue, drops its `CANCEL` outbox entry in the same write; everything else: exit 10 (observation only) |
| `wake-failed` | — | live (not `done-claimed`/`verifying`) → `failed` |
| `user-merged` | — | `failed → merged` only if `git merge-base --is-ancestor <issue branch tip> <ticket-branch>`; releases dependents; else exit 30 |
| `cancel-ticket` | `[<reason>]` | (n ignored, pass `0`) every non-terminal → `cancelled` (reason stored); outbox `CANCEL` for each live issue |
| `canary-passed` | — | (n = canary issue) sets `.canary = "passed"` |

  - One shared helper performs every transition to `merged` (from `gate`, `user-merged` and Task 6's `reconcile`) and in the same write moves each `blocked-on #<n>` issue to `pending`.
  - `ledger.sh outbox <ledger>` — prints `<n>\t<gen>\t<line>` per pending entry. Entries are added only by the events above; cleared by Task 6's `message`.
  - `ledger.sh slots <ledger>` — prints the live count by calling `frontier.sh --live-count` (Task 3).
  - `ledger.sh done <ledger>` — exit 0 printing `handback` when every issue is `merged`/`cancelled` and ≥1 `merged`; `cancel-ticket` when all are `cancelled`; exit 1 ("not done") otherwise.
  - `ledger.sh summary <ledger>` — Markdown table for the PR body: issue, final status, branch, merge SHA, rework and resync counts, gate results, cancellation reason (as stored by `drop` / `cancel-ticket`).

- [ ] **Step 1: Write the failing tests.** Fixture ledgers via `path` + `lock` (export `PS_OWNER`) + `init` in a throwaway git repo. Test names and assertions:
  - `path_in_git_dir`: `path K` is under `git rev-parse --git-common-dir`; from a second worktree of the same repo it prints the same path; `git status --porcelain` is empty after `init`.
  - `atomic_write`: after any `event`, no `*.tmp*` file remains next to the ledger and `jq -e .` succeeds; a stray temp file from an interrupted write leaves the previous ledger readable.
  - `lock_contention`: lock as `S1` (exit 0); lock as `S2` with `agents.json` listing `S1` alive (pid `$$`) → exit 40, `holder=S1`.
  - `lock_own`: `S1` locks twice → both exit 0, same session ID in `owner=`.
  - `lock_stale_takeover`: holder `S1` listed with a dead pid (spawn `sleep 0 &`, `wait`, use its pid) → `S2` gets exit 0; `ledger.log` has `lock-takeover`.
  - `lock_missing_holder` (interruption between `mkdir` and the holder write): `lock/` exists with no `holder` → `S2` takes over, exit 0.
  - `lock_no_pid_fallback`: `agents.json` entry without a pid field, `state: working` → live (exit 40); `state: stopped` → takeover.
  - `lock_concurrent_takeover`: dead holder `S1`; the fixture `agents.json` lists `S2` and `S3` as live (pid `$$`), so a contender arriving after the winner finished sees a live holder; two background contenders `S2`, `S3` each wait for a `go` file (barrier: poll every 0.05 s), then `lock`; after both finish, exactly one exited 0 and one 40, and `lock/holder` carries the winner's nonce. Repeat 10 times.
  - `stale_takeover_dir`: a `takeover/` with no `owner` and mtime 120 s old (`touch -t`) → takeover proceeds; one with a live owner → exit 40.
  - `lost_lock_refused`: `S1` locks; `S2` takes over after `S1` is listed dead; a mutating call with `S1`'s old `PS_OWNER` → exit 40, ledger bytes unchanged.
  - `lock_per_key` (Review Focus 5): ledgers for `AAA` and `BBB` in one repo; locks by different sessions both succeed; two `partner-sessions/*/lock` dirs exist.
  - `canary_gate`: `intent launch` issue 1 → 0; `intent launch` issue 2 before `canary-passed` → 30 with nothing recorded; after → 0.
  - `launch_blocked`: `intent launch` for an issue with an unmerged blocker → 30, no intent recorded.
  - `launch_closes_intent`: after `intent launch` + `event launch`, `get` shows the intent closed and the worktree/branch/start SHA recorded; `launch-failed` restores `pending` and closes the intent; for a `relaunch` intent it restores `failed`.
  - `slots_cap`: three live issues; `intent launch` a fourth → 30 and `intent relaunch` of a failed issue → 30; `slots` prints `3`; `blocked-on`, `failed` and terminal statuses do not count.
  - `every_row`: one assertion per row of the event table, checking the new status string exactly (e.g. `rework-1/3`, `blocked-on #9`) and, where the row says so, the outbox line in the same write (`RESYNC #12 <head>`, `REWORK #12 <evidence>`, `CANCEL #12`).
  - `merged_releases_dependents`: 2 `blocked-on #1`; 1 reaches `merged` via `gate merged` → 2 is `pending`; repeat via `user-merged`.
  - `stuck_accept_edge`: after `stuck-accept 9` on 12, `.issues["12"].blockers` contains 9; `frontier.sh` does not list 12 until 9 is `merged`.
  - `illegal_refused`: e.g. `gate merged` on `started` → 30, status unchanged, `ledger.log` has `refused`; `stuck-accept` on `done-claimed` and on `verifying` → 30.
  - `third_gate_fail`: three `fail`s in one gen → `failed`; after `relaunch` one `fail` → `rework-1/3`.
  - `json_on_claimed`: `json stopped` and `json failed` on `done-claimed` → exit 10, unchanged.
  - `json_blocked_noop`: `json blocked` on `launched` and on `started` → exit 10, unchanged.
  - `drop_dependents`: dropping 1 where 2 is `blocked-on #1` prints `dependents=2`.
  - `user_merged_ancestry`: branch tip merged into ticket → `merged`; not merged → 30.
  - `all_cancelled`: `cancel-ticket` then `done` prints `cancel-ticket`; one merged + rest cancelled → `handback`.
  - `summary_table`: one merged (with gate results) and one cancelled (via `drop <reason>`; also `cancel-ticket <reason>`) issue → two rows with status, branch, gate results and the stored reason.
  - `resync_closes_intent`: `intent merge`, `ff-merge.sh` exit 10, `gate resync <head> <intent-id>`; `reconcile` afterwards leaves `resync-requested`; `resyncs` counts 1.
  - `done_not_done`: `done` on a ledger with a live issue exits 1.
  - `no_stranded_status`: seed each non-terminal status in turn, apply every event in the table, and require at least one exit 0 (the outcome is derived from the events, not from a hand-written expectation list).
- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/test-ledger-sh.sh` → exit 1.
- [ ] **Step 3: Implement** the subcommands above. Each mutating call: verify `PS_OWNER` against `lock/holder`, compute the whole new state with one `jq` program, write `<ledger>.tmp.$$`, `mv -f`. Append every refused or rejected call to `ledger.log` with a reason.
- [ ] **Step 4: Run to verify it passes.** Exit 0.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): add ledger.sh state machine, run lock, intents and outbox"`.

---

### Task 6: `ledger.sh` — messages, session rebinding and reconciliation

**Files:**
- Modify: `dev-workflow/skills/coordinating-partner-sessions/scripts/ledger.sh`
- Test: `dev-workflow/tests/test-ledger-sh.sh` (add cases)

**Interfaces:**
- Consumes: `parse-msg.sh --frame` (Task 2); Task 5's events, intents and outbox; `ff-merge.sh` (Task 4, in tests only).
- Produces:
  - `ledger.sh message <ledger> <raw-frame>` — parses with `parse-msg.sh --frame`; binds (`from` == recorded name exactly, `gen` == current gen, `DONE` branch == recorded branch) before any state change; dedups `DONE` by issue+gen+sha (exit 10); same-state repeats exit 10; in one write clears the issue's outbox entries for that gen and applies: `STARTED` (`launched → started`; on `rework-n/3`/`resync-requested` unchanged), `DONE` (claim persisted with a monotonically increasing `claimSeq`, → `done-claimed`, prints `queue=<n>`), `STUCK needs=#m` (prints `ask-user=edge <n> <m>` or, if `m` merged, → `resync-requested` with outbox `RESYNC #n <head>`), `STUCK`/`SCOPE` without a status change (on `launched`, `started`, `rework-n/3`, `resync-requested`: exit 0 and print `ask-user=…`; on `done-claimed`/`verifying`: exit 10 and print `ask-user=…`), `FAILED` (→ `failed`). Rejections exit 20 with `reason=` and a `ledger.log` entry.
  - `ledger.sh session <ledger> <n> <session-name> <session-id>` — records a woken partner's name and `sessionId`; gen and status unchanged; exit 0 (exit 10 if unchanged).
  - `ledger.sh reconcile <ledger> <agents.json>` — in one write: every open `merge` intent whose candidate is an ancestor of the ticket head → `merged` (shared helper, releases dependents), else the issue returns to `done-claimed`; every open `launch`/`relaunch` intent whose session name appears in `agents.json` → `launched` with that `sessionId` and the same effects as the matching event (gen+1; rework reset for a relaunch), else back to the status recorded in the intent (`pending` or `failed`); rows whose `sessionId` was already recorded for an earlier generation of that issue are ignored (`--all` keeps same-name rows of earlier generations); every `verifying` → `done-claimed`; every `CANCEL` outbox entry whose recorded session is absent from `agents.json` or listed `stopped`/`done`/`failed` is dropped; all those intents closed. Closed intents are never touched, so no issue moves backwards. Then prints action lines: `requeue <n>` (every `done-claimed`, in ascending `claimSeq`), `resend <n> <line>` (every outbox entry, verbatim), `status <n>` (every other live issue). Idempotent: a second run prints the same actions and changes no bytes.

- [ ] **Step 1: Write the failing tests.**
  - `bind_other_issue`: frame `from="K-13"` carrying `#12` → 20.
  - `bind_near_match`: `from="k-12"`, `from="K-12 "`, `from="K-1"`, ID-valued `from` (`sid-1`) → 20 each.
  - `bind_old_gen`: `gen=1` after a relaunch to gen 2 → 20.
  - `bind_branch_mismatch`: `DONE` with another branch → 20.
  - `bind_wrong_frame`: `<agent-message from="K-12">…` → 20.
  - `frame_fixture`: the pinned frame `<cross-session-message from="K-12">STARTED #12 gen=1</cross-session-message>` → 0.
  - `wake_rebinds_name`: `session 12 K-12b sid-9`; then a frame `from="K-12b"` → 0 and `from="K-12"` → 20; gen unchanged.
  - `done_persisted`: after `message DONE`, `get` shows the claim before any `queue-check`.
  - `done_dedup`: same `DONE` twice → second exit 10.
  - `same_state_noop`: `STARTED` on `started` → 10.
  - `stuck_merged_resync`: `STUCK needs=#9` with 9 merged → `resync-requested`, outbox has `RESYNC #12 <head>`.
  - `stuck_from_rework`: `STUCK` and `SCOPE` on `launched`, `started`, `rework-1/3` and `resync-requested` → exactly 0 with `ask-user=` and status unchanged, never 30.
  - `stuck_on_claimed`: `STUCK` on `done-claimed` → 10, prints `ask-user=`.
  - `stale_done_free`: `queue-check stale` leaves the rework count at 0.
  - `outbox_cleared`: after a gen-2 `RESYNC`, a valid gen-2 message clears it (the gen-1 rejection is covered by `bind_old_gen`).
  - `message_failed_rows`: a `FAILED` frame moves `launched`, `started`, `rework-1/3`, `done-claimed` and `verifying` to `failed`.
  - `started_transition`: `STARTED` moves `launched` to `started` (asserts the status string, not only the exit code).
  - `requeue_order`: two `DONE` claims arriving in reverse issue-number order; `reconcile` prints `requeue` in arrival (`claimSeq`) order.
  - `reconcile_stale_same_name_row`: `agents.json` holds a dead same-name row whose `sessionId` was recorded for gen 1 and no gen-2 row; an open relaunch intent is not bound to the stale row.
  - `cancel_cleared_when_gone`: `stuck-accept` leaves outbox `CANCEL #12`; with `K-12` absent from `agents.json`, `reconcile` prints no `resend 12` and `get` shows an empty outbox; separately, `event 12 json stopped` on the `blocked-on` issue drops it in the same write; with `K-12` still `working`, the entry stays and `reconcile` prints `resend 12 CANCEL #12`.
  - Crash right after a transition, before any send (the transition's outbox entry is in the same write), each followed by `reconcile`, which must print `resend <n> <exact line>`: `crash_after_queue_stale`, `crash_after_gate_resync`, `crash_after_gate_fail` (line carries the evidence), `crash_after_stuck_accept` (`CANCEL`), `crash_after_cancel_ticket` (one `CANCEL` per live issue).
  - Crash at intents:
    - `crash_after_launch_intent`: intent open, no session in `agents.json` → `pending`, intent closed.
    - `crash_after_relaunch_intent`: relaunch intent open (prior status `failed`), no session in `agents.json` → back to `failed`, intent closed; with session `K-12` present under a new `sessionId` → `launched`, gen+1, rework reset.
    - `crash_after_launch_before_record`: intent open, session `K-12` present with `sid-12` → `launched`, `sessionId` `sid-12` recorded.
    - `crash_after_merge_intent`: candidate not yet merged → `done-claimed`, `requeue 12`.
    - `crash_after_merge_before_record`: candidate already an ancestor of the ticket head → `merged`, dependents released.
  - No regression after success: `restart_after_launch_then_done` (launch recorded, then `DONE` → reconcile leaves `done-claimed`); `restart_after_launch_then_cancel` (stays `cancelled`); `restart_after_merge` (stays `merged`, no `requeue`).
  - `crash_during_verifying`: status `verifying` → reconcile sets `done-claimed`, prints `requeue 12`; then in a real repo drive `ff-merge.sh --check` → `queue-check ok` → `intent merge` → `ff-merge.sh` → `gate merged` → `merged`. Repeat with the ticket head advanced first: `--check` exit 10 → `queue-check stale <head>` → `resync-requested` with a durable outbox `RESYNC`.
  - `merge_with_real_ledger`: in a real repo, `path` + `lock` (export `PS_OWNER`) + `init` + `intent merge`, then `ff-merge.sh` from the ticket worktree → exit 0 (the ledger does not dirty the worktree).
  - `reconcile_idempotent`: second run prints the same actions and changes no bytes in the ledger.
- [ ] **Step 2: Run to verify the new cases fail.** `bash dev-workflow/tests/test-ledger-sh.sh` → the new names fail.
- [ ] **Step 3: Implement** `message`, `session`, `reconcile`. `message` calls `parse-msg.sh` by absolute path with the frame as one argv argument.
- [ ] **Step 4: Run to verify it passes.** Exit 0.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): ledger.sh message binding, session rebinding and reconcile"`.

---

### Task 7: Coordinator-contract test

A scripted run of the coordinator's script contract, with fake session observations, so the sequence `SKILL.md` prescribes is exercised end to end rather than only by phrase pins.

**Files:**
- Create: `dev-workflow/tests/test-coordinator-contract-sh.sh`

**Interfaces — Consumes:** all four scripts (Tasks 2–6) and `fixtures/partner-sessions/agents.json` (Task 1) as the template for fake observations.

- [ ] **Step 1: Write the test.** In a throwaway repo with a ticket branch and issues 1, 2 (blocked by 1), 3: `path`, `lock`, `init`; `frontier.sh` → launch 1 as canary (`intent launch`, `event launch`), `message STARTED`, `canary-passed`, launch 3; partner branches are created as `git worktree add` worktrees (so the ticket checkout is never disturbed) and partner commits are simulated with `git commit` there; after each `ff-merge.sh --check` exit 0 the head is pinned with `git rev-parse <ticket-branch>`; `message DONE` for 1 and 3; queue 1 (`--check`, `queue-check ok`, `intent merge`, `ff-merge.sh`, `gate merged`); queue 3 → `--check` exit 10 → `queue-check stale` → outbox `RESYNC`; **kill point**: discard the in-memory loop here, run `reconcile` with a fake `agents.json`, and consume every printed action (`resend`, `requeue`, `status`) the way `SKILL.md` will; partner 3 re-syncs (merge ticket head, new `DONE`); assert `frontier.sh` prints `2` right after 1 merges, and again after 3 merges (2 is launched afterwards on purpose); launch, `DONE`, merge 2; `done` prints `handback`; `summary` lists three merged rows; `git log` of the ticket branch contains all three partner commits. Assert the status after every step.
- [ ] **Step 2: Run.** `bash dev-workflow/tests/test-coordinator-contract-sh.sh` → exit 0. (It is written after Tasks 2–6, so it should pass on first run; any failure is a script bug to fix in the owning task's script, with a new unit test there.)
- [ ] **Step 3: Commit.** `git commit -m "test(dev-workflow): end-to-end coordinator contract for partner sessions"`.

---

### Task 8: Reference files — `ledger.md`, `readiness.md`, `partner-brief.md`

**Files:**
- Create: `dev-workflow/skills/coordinating-partner-sessions/ledger.md`, `readiness.md`, `partner-brief.md`
- Test: `dev-workflow/tests/run.sh` (new block `== coordinating-partner-sessions skill ==`, its own counter `pfail()` / `PARTNER_FAILS` like intake's `ifail`; this task adds the pins for these three files)

**Interfaces — Produces:** the brief's placeholders, which `SKILL.md` fills: `{{KEY}}`, `{{N}}`, `{{ISSUE_URL}}`, `{{GEN}}`, `{{SESSION_NAME}}`, `{{COORD_NAME}}`, `{{WORKTREE}}`, `{{BRANCH}}`, `{{TICKET_BRANCH}}`, `{{START_SHA}}`, `{{AC}}`, `{{TEST_CMD}}`, `{{BLOCKER_EVIDENCE}}`.

- [ ] **Step 1: Write the failing pins** in `run.sh` (each `grep -qF '<phrase>' "$PS_DIR/<file>" || pfail "..."`):
  - `ledger.md`: `## Transition table`; each of the 11 status strings; `generation`; `outbox`; `launch-intent`; `merge-intent`; `partner-sessions/<KEY>/ledger.json`; `git-common-dir`; `never committed`; `PS_OWNER`; `ledger.sh event`.
  - `readiness.md`: `a story`; `acceptance criteria`; `test command`; `a stated reason none is needed`; `ask only about what changed`.
  - `partner-brief.md`: `gen=`; `never rebase onto main`; `Never push`; `never open a PR`; `never close or edit GitHub issues`; `STATUS?`; `RESYNC`; `REWORK`; `CANCEL`; `its issue stays open until the ticket PR merges, by design`; `{{COORD_NAME}}`; `{{BLOCKER_EVIDENCE}}`.
- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/run.sh` → `FAIL: coordinating-partner-sessions/...` lines, `FAILED`.
- [ ] **Step 3: Write the three files.**
  - `ledger.md`: location and lifetime (git metadata, never committed, summary to the PR body), the JSON schema (fields per Tasks 5–6), status vocabulary, the spec's transition table verbatim with each row's `ledger.sh` event, the one-write rule, slot rule, generation rule, outbox and intent rules, lock protocol and `PS_OWNER`.
  - `readiness.md`: the mini-intake checklist (story, acceptance criteria, test approach or a stated reason none is needed, the issue's test command), the up-front mode (one sitting, every issue, close every gap before any launch) and the partner re-check mode (current code; ask only about what changed).
  - `partner-brief.md`: the spec's "Partner flow" as a fill-in template — identity, inputs, integration base (`{{TICKET_BRANCH}}`; never rebase onto main), blocker evidence, authority (local commits; may show `Needs input`), forbidden list, steps 1–5, the exact message lines with `gen=`, and the reply rules for `STATUS?`, `RESYNC`, `REWORK`, `CANCEL`.
- [ ] **Step 4: Run to verify it passes.** `bash dev-workflow/tests/run.sh` → no `coordinating-partner-sessions` failures.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): partner-session ledger, readiness and brief references"`.

---

### Task 9: `SKILL.md` — the coordinator loop

**Files:**
- Create: `dev-workflow/skills/coordinating-partner-sessions/SKILL.md`
- Test: `dev-workflow/tests/run.sh` (same block), and wire the five script tests into `run.sh` the way `test-audit-sh.sh` is wired, but with the running interpreter: `if "$BASH" "$HERE/test-<x>-sh.sh"; then :; else fail "…"; fi`

**Interfaces — Consumes:** every script interface (Tasks 2–6), the contract sequence (Task 7), the brief placeholders (Task 8), the blockers read command (Task 1).

- [ ] **Step 1: Write the failing pins:**
  - frontmatter `name: coordinating-partner-sessions`; description ≤ 1024 chars; `SKILL.md` under 500 lines; links `](ledger.md)`, `](readiness.md)`, `](partner-brief.md)`; each `scripts/*.sh` exists and is executable.
  - phrases: `fast-forward only`; `RESYNC`; `REWORK`; `STATUS?`; `gen=`; `Git state matches the claim`; `Tests pass, run by the coordinator`; `Every AC has evidence`; `dev-workflow:fresh-verifier`; `Partners never push or open PRs`; `third failed gate`; `stop and ask the user` (name collision); `held for approval`; `v2.1.236`; `v2.1.248`; `not in plan mode`; `integration base is the ticket branch`; `/rename`; `canary-passed`; `sleep 600`; `only a canary that has ended`; `cross-session-message`; one full sentence containing `deferred` (the cancelled-issue AC rule); `Refs owner/repo#`; `notify_when_idle`; `re-register`; `skip steps 3–5`; `PS_OWNER`; `ledger.sh summary`; `after the user confirms`; `/retro`; `skill-retrospective`.
  - negative: no whole-word `ces` anywhere under `coordinating-partner-sessions/`.
- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/run.sh` → `FAILED`.
- [ ] **Step 3: Write `SKILL.md`** following the spec's sections in order, each as an imperative section that names the script call (the sequence Task 7 exercises):
  - **When to use / inputs:** called from `chain-sdlc-process.md` stage 5, or standalone with a ticket key, the ticket branch and its published issues.
  - **Preflight:** version (`claude --version` ≥ `v2.1.236`, `v2.1.248` on Bedrock/Vertex/Foundry or flag fetching off); not in plan mode; own name from `ListAgents` and own session ID by the method recorded in Task 1 Step 2b (passed to `ledger.sh lock`); name auto-generated or colliding → ask the user to `/rename`, recommend `<KEY>-coord`); held messages in both directions from settings (`crossSessionInbound`, permission class) — stop and name the setting, never edit settings; `gh` auth; ticket branch checked out clean.
  - **Steps 2–5:** `ledger.sh path`, `ledger.sh lock` (export `PS_OWNER`; exit 40 → stop and tell the user); existing ledger → check the own name still equals the recorded coordinator name (else ask the user to `/rename` back), `ledger.sh reconcile`, act on its lines, **skip steps 3–5**; read issues with the Task 1 command (fallback `Blocked by:` parse; external blockers per Global Constraints, recorded as `{n, closed}` and `init` called only after the user resolves open ones); readiness up front (`readiness.md`); `ledger.sh init`; `frontier.sh` cycle → stop and show.
  - **Step 6 launch + canary:** per launch: `ListAgents` name check (collision → stop and ask the user); `ledger.sh intent launch`; worktree/branch (old ones → `-g<old>`); fill `partner-brief.md`; `cd <worktree> && claude --bg --name <KEY>-<n> --permission-mode <mode> "<brief>"`; on error `event launch-failed`; read `sessionId` from `claude agents --json --all`; `event launch <intent> <sessionId>`; `SendMessage` with `notify_when_idle`. Canary: first launch only; start a background `sleep 600` as the leg timer; leg 1 passes on `STARTED`; leg 2: `STATUS? #n` with a fresh `sleep 600`; on timer expiry read `claude agents --json --all` — `working` or `blocked` restarts the timer and tells the user (`blocked` → the canary is waiting on them in `<KEY>-<n>`), only a canary that has ended without the expected message is a failed leg; on pass `event … canary-passed`; on a failed leg stop launching and name the leg and likely setting.
  - **Steps 7–9 wait, messages, integration queue:** every coordinator read (wake, lock, reconcile) uses `claude agents --json --all` to a temp file (`ListAgents` stays the live-collision check) and `ledger.sh event … json <state>` for each partner; re-register `notify_when_idle` after every consumed notice and when older than ~11 h; messages go through `ledger.sh message` with the whole frame; act on its output lines; the queue runs one `DONE` at a time: `ff-merge.sh --check` → `queue-check ok|stale <head>`; pin the head with `git rev-parse <ticket-branch>` after `--check` exits 0; the four gate checks (test run in a throwaway worktree at `<sha>`; per-AC evidence; `dev-workflow:fresh-verifier`); `ledger.sh intent merge`; `ff-merge.sh`; `gate merged <intent>|resync <head>|fail <evidence>`; then send whatever `ledger.sh outbox` lists for that issue (the transition already recorded it); delivery failure → `claude --resume <sessionId> --bg --name <KEY>-<n> "<line>"`, re-read name and `sessionId`, `ledger.sh session`.
  - **Error handling:** idle-notice branches; failure options (relaunch / handled it themselves → `user-merged` / drop / cancel the ticket); `STUCK needs=#m` (cycle check, ask the user, `stuck-accept`, then write the edge to GitHub only after the user confirms that write, with `gh api --method POST repos/<owner>/<repo>/issues/<n>/dependencies/blocked_by -F issue_id=<blocker-db-id>` as recorded in Task 1); `SCOPE` handling (a split drops only non-live issues via `drop <reason>`; a live issue needs `cancel-ticket` or a failure first) including the retrospective recommendation (the user runs `/retro` on the workspace's ticket-creation skill, then `dev-workflow:skill-retrospective`; never launched by the coordinator).
  - **Step 10 hand-back:** `ledger.sh done`; `cancel-ticket` → `unlock`, tell the user; `handback` → mark each cancelled issue's AC `deferred` with the reason stored by `drop` / `cancel-ticket` (ask the user for it when calling them), put `ledger.sh summary` in the PR body draft, `unlock`, return to intake step 7 then 8; `Closes`/`Refs` for `merged` issues only; cancelled issues listed as not delivered.
- [ ] **Step 4: Run to verify it passes.** `bash dev-workflow/tests/run.sh` → `ok: coordinating-partner-sessions skill present …`, all five script tests ok, `PASSED`.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): coordinating-partner-sessions coordinator skill"`.

---

### Task 10: Intake integration at stage 5

**Files:**
- Modify: `dev-workflow/skills/intaking-work-items/chain-sdlc-process.md` (stage 5 and Controls → Resume)
- Modify: `dev-workflow/skills/intaking-work-items/template.md` (Chain artifacts gains the partners ledger location)
- Test: `dev-workflow/tests/run.sh` (intake block)

**Interfaces — Consumes:** the skill name `dev-workflow:coordinating-partner-sessions` and its hand-back contract (Task 9 step 10), including the `cancel-ticket` outcome (no hand-back).

- [ ] **Step 1: Write the failing pins** in the intake block:
  - `chain-sdlc-process.md`: `one after another or parallel partners`; `dev-workflow:coordinating-partner-sessions`; `partner-sessions/<KEY>/ledger.json`; `AC of a cancelled issue are deferred`; `closing keywords and Refs cover merged issues only`; `only when two or more issues are published`.
  - `template.md`: `partner-sessions/<KEY>/ledger.json`.
  - Existing negative pin still holds: no whole-word `ces` in `intaking-work-items/`.
- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/run.sh` → intake `FAIL` lines.
- [ ] **Step 3: Edit stage 5.** Before the router hand-off, add: when two or more issues are published, ask once — one after another (today's path, unchanged) or parallel partners. Parallel invokes `dev-workflow:coordinating-partner-sessions` with the ticket key, ticket branch, issue links and settled AC list; the coordinator owns stage 5 and returns to step 7. State the hand-back contract (deferred AC, `Refs`/`Closes` for merged issues only, ledger summary in the PR body) and the `cancel-ticket` outcome: the coordinator returns no hand-back, and intake stops at stage 5 and reports. Resume: re-invoke the coordinator (it reconciles) only when Chain artifacts show stage 5 as the first incomplete stage and `$(git rev-parse --git-common-dir)/partner-sessions/<KEY>/ledger.json` exists; a finished or cancelled run leaves its ledger in git metadata (cleanup is out of scope). Record the choice in the Run log.
- [ ] **Step 4: Run to verify it passes.** `bash dev-workflow/tests/run.sh` → `PASSED`.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): offer parallel partner sessions at sdlc-process stage 5"`.

---

### Task 11: Version, README, CI

**Files:**
- Modify: `dev-workflow/.claude-plugin/plugin.json` (`"version": "0.1.8"`), `dev-workflow/README.md` (Skills table row `| \`coordinating-partner-sessions\` |`; intake row mentions the parallel option), `.github/workflows/tests.yml` (macOS job)
- Test: `dev-workflow/tests/run.sh`

- [ ] **Step 1: Write the failing pins:** `grep -qF '"version": "0.1.8"' "$ROOT/.claude-plugin/plugin.json"`; `grep -qF '| \`coordinating-partner-sessions\` |' "$ROOT/README.md"`.
- [ ] **Step 2: Run to verify it fails.** → 2 `FAIL` lines.
- [ ] **Step 3: Edit** `plugin.json` and `README.md`. In `tests.yml`, add a step before the macOS job's `Run tests`: `command -v jq >/dev/null || brew install jq; jq --version; /bin/bash --version | head -1` (the Ubuntu job already installs `jq`). The macOS job already runs `/bin/bash "$t"` (bash 3.2, BSD tools), and Task 9's `"$BASH"` wiring keeps every script test on that interpreter.
- [ ] **Step 4: Verify.** `/bin/bash dev-workflow/tests/run.sh` → `PASSED`; `bash scripts/scrub-check.sh --check-overbroad --allow scripts/scrub-allow.txt .` → exit 0. After the user confirms the push, the CI run's macOS log shows `GNU bash, version 3.2` and `jq-1.`, and both jobs pass.
- [ ] **Step 5: Commit.** `git commit -m "chore(dev-workflow): bump to 0.1.8, list coordinating-partner-sessions, provision jq on macOS CI"`.

---

### Task 12: Live trial (manual, run by the user before release)

Not automatable: partners talk to the user and the run spans `claude agents`. The orchestrator prepares the checklist and the scratch ticket; the user runs it and records evidence in `docs/superpowers/plans/2026-10-12-partner-sessions.md` under `## Live trial results`.

- [ ] **Step 1: Setup (user confirms each GitHub write).** A throwaway requirements doc and ticket branch; three issues A, B (natively blocked by A), C (independent) in a scratch repo or this one.
- [ ] **Step 2: Mis-set inbound (scratch run first).** Set the partner side's `crossSessionInbound` so messages are held; start the coordinator. Expected: preflight names the setting, or the canary stops with the failed leg named; nothing else launches. Restore the setting.
- [ ] **Step 3: Real run.** Expected evidence, each with a quoted `claude agents --json` line, ledger excerpt or message frame:
  - Canary: A launches alone, sends `STARTED`, answers `STATUS?`; only then C launches.
  - A partner frame reads `<cross-session-message from="<KEY>-<n>">`, matching the ledger.
  - A partner asks the user a question and stays `blocked` — not `failed`.
  - One partner left unattended for over an hour is stopped by the idle stop and woken with `STATUS?`, not failed.
  - At least one `RESYNC` (finish A and C close together).
  - B launches only after A is `merged` and holds once on sdlc-process's start rule until the user resolves it.
  - `git status` in the coordinator's checkout stays clean throughout; the ledger is under `$(git rev-parse --git-common-dir)/partner-sessions/<KEY>/`.
  - Hand-back to intake step 7; one draft PR covering A, B and C with `Refs`/`Closes` per step 8's rule and the ledger summary in its body.
- [ ] **Step 4: Clean up** scratch issues, branches, worktrees and sessions (user confirms each remote deletion).
- [ ] **Step 5: Commit** the results section: `git commit -m "docs(dev-workflow): record partner-session live trial"`.

---

## Review chain

Full tier (skill definitions, new scripts, CI, more than 150 lines): `dev-workflow:fresh-verifier` and `dev-workflow:codex-adversary` in one message on this plan before Task 1 (done: plan at `7c7a62b`, findings folded into this revision), a quick re-check of this revision, and both on the full diff before the PR (intake-style `opening-pull-requests` gates). Every push needs the user's confirmation.

---

## Spike results

Recorded on Claude Code as installed 2026-10-12. Session IDs are placeholders (`sid-*`, `TEST-*`); fixtures live in `dev-workflow/tests/fixtures/partner-sessions/`.

### 1. GitHub blockers endpoint

- Read command (Task 9 uses it verbatim): `gh api repos/<owner>/<repo>/issues/<n>/dependencies/blocked_by`
- Observed: `gh api repos/cjsteigerwald/ai-crew/issues/1/dependencies/blocked_by` returned HTTP 200 with `[]`. The endpoint exists (no 404), so the native-dependency read path is available; the primary path stands, not the `Blocked by: #n` body-line fallback.
- Not observed: a non-empty response. The repo has no issues (`gh issue list --state all` returned `[]`) and creating a throwaway pair is a GitHub write, so it was not done. **Needs user-run verification:** create two throwaway issues A and B, add the edge with the write command below, run the read command against A, confirm the array holds objects with `number` and `state` (`open`/`closed`), then close both.
- Write command (documented at `docs/agents/issue-tracker.md:68`, not run): `gh api --method POST repos/<owner>/<repo>/issues/<n>/dependencies/blocked_by -F issue_id=<blocker-db-id>`
- Trim for the coordinator: `jq '[.[] | {number, state}]'`. Fixture `blocked_by.json` has that shape (`[{"number":12,"state":"open"},{"number":13,"state":"closed"}]`); its values are illustrative, built from the documented response shape, not captured.
- Fallback if a repo returns 404: parse body lines matching `^Blocked by: #[0-9]+(, *#[0-9]+)*$`.

### 2. `claude agents --json --all` shape

A JSON array. Entry fields: `id` (8-hex short id, accepted by `claude stop|rm|attach|logs`), `sessionId` (full UUID), `name`, `cwd`, `kind` (`background`), `startedAt` (epoch ms), `state`, and, only for live processes, `pid` and `status`. Observed `state` values: `done`, `working`, `blocked`. Observed `status` values: `idle`, `busy`.

- **Liveness field is `pid`.** It is present while the session process is alive and absent once stopped. Observed after `claude stop`: the entry stayed listed, lost `pid` and `status`, and kept `state: "done"`. So `state` alone does not distinguish stopped from finished: a stopped session shows `done`. Liveness = `pid` present. The spec fallback (listed with `state` not in {`stopped`,`failed`}) is not usable, since neither value was observed.
- Fixture `agents.json` carries four entries: working with pid (`TEST-coord`), idle-done with pid (`TEST-1`), blocked with pid (`TEST-2`), stopped with no pid (`TEST-3`). `cwd` is replaced with `<cwd>`.
- `tests/fixtures/partner-sessions/agents.json` is derived from a real `claude agents --json --all` run on 2.1.296, with ids, sessionIds and cwd replaced by placeholders.

### 2b. Coordinator's own sessionId

The environment variable `CLAUDE_CODE_SESSION_ID` holds the session's own UUID and matches the `sessionId` of that session's entry in `claude agents --json --all` (confirmed by exact match against one entry). Task 9 preflight: read `$CLAUDE_CODE_SESSION_ID`; fall back to the `--json --all` entry whose `name` equals the coordinator's name when it is unset (a session without a name has no fallback, so the coordinator must be named, as the spec requires). Caveat: the variable was read from a subagent's shell and matched the parent session's entry; the controller then confirmed in the main session that `$CLAUDE_CODE_SESSION_ID` matches the main session's own id.

### 3. `--resume` + `--name`

Run with one throwaway session (`ps-spike-a`):

1. `claude --bg --name ps-spike-a "reply OK then stop"` printed `backgrounded · <id> · ps-spike-a`; after about 20 s the entry showed `state: done`, `status: idle`.
2. `claude stop <id>` printed `stopped <id>`; the entry stayed listed without `pid`.
3. `claude --resume <sessionId> --bg --name ps-spike-b "reply OK"` printed `note: session <id> is already running in the background, so this started a copy as <id2>`, then `backgrounded · <id2> · ps-spike-b`.
4. `claude agents --json --all`: the resumed entry had a NEW `id` and a NEW `sessionId` (not equal to the original) and `name` `ps-spike-b`, with `pid` and `state: done`. The original entry was unchanged (`ps-spike-a`, no `pid`).

Result: resuming a session right after `claude stop` forked a new session rather than reusing the sessionId, because the CLI still considered the original "already running". The `--name` flag is honoured on resume. Both spike sessions were stopped and removed with `claude stop` and `claude rm`; `claude agents --json --all` no longer lists either.

- **Plan assumption:** the sessionId is UNSTABLE across `--resume`. Every wake or relaunch re-reads `name` and `sessionId` from `claude agents --json --all` and records them with `ledger.sh session`. Affected: Task 6 (session/reconcile) and Task 9 (wake and relaunch steps).
- **Needs user-run verification:** whether the sessionId is stable once the stop has settled. Sequence: `claude --bg --name <name> "reply OK then stop"`; wait for `done`; `claude stop <id>`; wait 30 s (no `claude rm`); `claude --resume <sessionId> --bg --name <name> "reply OK"`; then compare `sessionId` for that entry in `claude agents --json --all` with the original. If equal, the assumption can be relaxed; if not, it stands.
