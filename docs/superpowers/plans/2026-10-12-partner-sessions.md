# Partner-session coordinator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `dev-workflow:coordinating-partner-sessions`, which intake's sdlc-process chain calls at stage 5 to run one attended `sdlc-process:sdlc-process` partner session per GitHub issue — in parallel where the blocked-by graph allows, verified and fast-forward-merged into the ticket branch one at a time — and hand back to intake steps 7–8 for one draft PR.

**Architecture:** The coordinator loop is prose (`SKILL.md` plus three reference files), because launching sessions, reading `claude agents --json`, `SendMessage` and talking to the user are model actions. Every decision that must come out the same way every time lives in four bash scripts under `scripts/`: `parse-msg.sh` (validate one partner line), `frontier.sh` (what to launch; cycle refusal), `ff-merge.sh` (fast-forward-only merge) and `ledger.sh` (the only writer of coordinator state: transitions, lock, intents, outbox, binding, dedup, reconciliation). The scripts never call `claude` or `gh`; the coordinator passes `claude agents --json` output in as a file, so the scripts are fully testable in CI.

**Tech Stack:** Markdown skill files; bash 3.2-compatible scripts using `git` and `jq` (≥1.6); behavioural tests in the style of `dev-workflow/tests/test-audit-sh.sh`; `grep -qF` pins in `dev-workflow/tests/run.sh`. Run everything with `bash dev-workflow/tests/run.sh` (prints `PASSED`, exits 0).

**Spec:** `docs/superpowers/specs/2026-10-12-partner-sessions-design.md` at `3566c05` (approved). The transition table, message protocol, merge rule, verification gate, error handling and preflight sections are normative; every task below cites them.

## Global Constraints

- Skill directory: `dev-workflow/skills/coordinating-partner-sessions/`; scripts in its `scripts/` (repo convention: `copilot-agent-readiness/scripts/audit.sh`).
- Scripts: bash 3.2 compatible (no associative arrays, `mapfile`, `${var,,}`) — macOS CI runs `/bin/bash`; depend only on `git`, `jq`, POSIX tools; never `eval`, never interpolate message text into a command.
- Scripts never invoke `claude`, `gh` or the network. Live-session data arrives as a file argument holding `claude agents --json` output.
- Message regexes, verbatim from the spec: `#n` `^#[0-9]+$`; `gen=<g>` `^gen=[0-9]+$`; `<sha>`/`<head>` `^[0-9a-f]{40}$`; `<branch>` `^[a-z0-9][a-z0-9._/-]*$` and passes `git check-ref-format --branch`.
- Frame: `<cross-session-message from="<name>">…</cross-session-message>`; `from` must equal the recorded session name exactly.
- Statuses, verbatim: `pending`, `launched`, `started`, `blocked-on #m`, `done-claimed`, `verifying`, `rework-n/3` (stored as `rework-1/3`, `rework-2/3`), `resync-requested`, `merged`, `failed`, `cancelled`. Live = `launched`, `started`, `done-claimed`, `verifying`, `rework-n/3`, `resync-requested`.
- Concurrency cap default `3`. Rework budget `3` per generation; relaunch resets it.
- Names: coordinator recommended `<KEY>-coord`; partner `<KEY>-<n>`; partner branch `<key>-<slug>-<n>`; superseded branch `<key>-<slug>-<n>-g<old>`; ticket branch `<key>-<slug>`.
- Ledger: `docs/specs/<KEY>-partners.md`, a Markdown file whose state is one fenced ```` ```json ```` block that only `ledger.sh` writes (temp file + `mv`). Run lock: directory `<git-common-dir>/partners-<KEY>.lock/` (created with `mkdir`, atomic) holding file `holder` = coordinator `sessionId`.
- Version floors: Claude Code `v2.1.236` (`v2.1.248` on Bedrock, Vertex or Foundry, or with flag fetching off).
- Canary timeout: `600` seconds per leg, via a background `sleep 600` Bash call as the backstop timer (decided here — Spec Open item 3; see Task 8).
- `dev-workflow/.claude-plugin/plugin.json` version `0.1.7` → `0.1.8`.
- `SKILL.md` under 500 lines; description ≤ 1024 chars.
- Public-repo hygiene: no whole-word `ces` in `coordinating-partner-sessions/` or `intaking-work-items/` (`run.sh` already enforces it for intake). Decision 7's retrospective target is therefore written as "the workspace's ticket-creation skill (the one that created this ticket)", not by name.
- Every existing `run.sh` assertion stays green. Do not edit sdlc-process, superpowers or mattpocock plugin files.
- No push, PR or GitHub write during implementation except where a step says so and the user confirms it.

## Review Focus

1. **The canary partner asks the user a readiness question before `STARTED`.** Expected: the canary waits (the partner is `blocked` in `--json`), it is not a failed leg, and the user is told the canary is waiting on them in `<KEY>-<n>` (Task 8 pin; Task 5 `json_blocked_noop` test).
2. **The ticket-branch worktree is dirty or on another branch when a merge runs** (the user edited files in the coordinator's checkout). Expected: `ff-merge.sh` exits `3` without touching anything; the coordinator tells the user and never stashes or resets (Task 4 tests).
3. **A `Blocked by: #n` names an issue outside this ticket's set.** Expected: recorded as an external blocker; satisfied only if it was closed when read, otherwise the coordinator asks the user (wait or remove the edge) before writing the ledger; `frontier.sh` never launches an issue with an open external blocker (Task 3 test).
4. **A partner line arrives with trailing spaces or a CRLF ending.** Expected: trailing spaces and one trailing `\r` are stripped, then validated; an embedded newline or `\r` elsewhere is rejected (Task 2 tests).
5. **Two tickets coordinated at once in the same repo.** Expected: independent locks (`partners-<KEY>.lock`), ledgers and names; one coordinator never takes or reads the other's lock (Task 5 test).

---

### Task 1: Resolve the spec's open items (spikes)

Non-code. Results go in a `## Spike results` section appended to this plan, plus fixtures later tasks consume.

**Files:**
- Modify: `docs/superpowers/plans/2026-10-12-partner-sessions.md` (append `## Spike results`)
- Create: `dev-workflow/tests/fixtures/partner-sessions/agents.json` (a real `claude agents --json --all` sample, names and IDs replaced with `TEST-1`, `TEST-coord` and fake UUIDs)
- Create: `dev-workflow/tests/fixtures/partner-sessions/blocked_by.json` (a real response from step 1, scrubbed)

**Interfaces — Produces:** the exact GitHub read command for blockers (Task 8 uses it verbatim); the field names of `claude agents --json` entries (`name`, `sessionId`, `state`, and the process-liveness field) used by Task 5's lock liveness and Task 6's reconciliation.

- [ ] **Step 1: GitHub blockers endpoint.** Run `gh api repos/cjsteigerwald/ai-crew/issues/<n>/dependencies/blocked_by` against an issue that has a native blocker (create a throwaway pair only with the user's confirmation, then close both). Expected: a JSON array of issue objects with `number` and `state`. Record the command and one trimmed output. If it 404s, record that and the fallback: parse body lines matching `^Blocked by: #[0-9]+(, *#[0-9]+)*$`.
- [ ] **Step 2: `claude agents --json` shape.** Run `claude agents --json --all`; save a scrubbed sample as the fixture. Record which field carries the process ID or liveness (expected `pid` per review round 1; if absent, record what is there).
- [ ] **Step 3: `--resume` + `--name` (live, run by the orchestrator or the user, ~30 s).** `claude --bg --name ps-spike-a "reply OK then stop"`; wait for `done`; `claude stop <id>`; `claude --resume <sessionId> --bg --name ps-spike-b "reply OK"`; `claude agents --json --all`. Expected evidence: the resumed entry's `sessionId` equals the original and its `name` is `ps-spike-b` (or record what it is). Remove both with `claude rm`.
- [ ] **Step 4: Commit.**

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

- [ ] **Step 1: Write the failing tests** (`test-parse-msg-sh.sh`, same skeleton as `test-audit-sh.sh`: `fail()`, `FAIL` counter, exit 1 on failure). Cases and assertions:

| Test | Input | Expect |
|---|---|---|
| valid STARTED | `STARTED #12 gen=1` | rc 0; stdout has `kind=STARTED`, `issue=12`, `gen=1` |
| valid DONE | `DONE #12 gen=2 abc-x-12 <40 hex> synced=<40 hex>` | rc 0; `branch=abc-x-12`, `sha=`, `synced=` match |
| STUCK needs | `STUCK #12 gen=1 needs=#9 waits on schema` | `needs=9`, `reason=waits on schema` |
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

- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/test-parse-msg-sh.sh` → `FAIL: … parse-msg.sh not found`, exit 1.
- [ ] **Step 3: Implement `parse-msg.sh`.** Read the argument into a variable only; split with `read -r` / parameter expansion; validate each field with `[[ =~ ]]` against the Global Constraints regexes and `git check-ref-format --branch`; print with `printf '%s\n'`.
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
  - `frontier.sh --check-edge <state.json> <n> <m>` — exit `0` if adding "`n` blocked by `m`" keeps the graph acyclic, `2` (with the cycle on stderr) if not.

- [ ] **Step 1: Write the failing tests.** JSON fixtures built inline with heredocs:

| Test | Graph / statuses | Expect |
|---|---|---|
| independent | 1,2,3 pending, no edges, cap 3 | `1 2 3` |
| cap | 1..5 pending, cap 3 | `1 2 3` |
| cap minus live | 1 `started`, 2 `verifying`, 3,4 pending, cap 3 | `3` |
| chain A→B→C | 2 blocked by 1, 3 by 2; all pending | `1` |
| chain after merge | 1 merged, 2,3 pending | `2` |
| diamond | 3 blocked by 1 and 2; 1 merged, 2 started | empty |
| failed blocker | 1 failed, 2 blocked by 1 | 2 not listed |
| cancelled blocker | 1 cancelled, 2 blocked by 1 | 2 not listed |
| blocked-on released | 2 `pending` (was blocked-on 1), 1 merged | `2` |
| external open (Review Focus 3) | 1 pending, external `{"n":40,"closed":false}` | empty |
| external closed | same, `closed:true` | `1` |
| cycle | 1↔2 | exit 2, stderr contains `cycle:`, finishes within 5 s (`timeout`-free: run in background, `kill` after 5 s → fail) |
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

**Interfaces — Produces** (run with cwd = the worktree that has the ticket branch checked out):
- `ff-merge.sh --check <ticket-branch> <sha>` — exit `0` if the ticket head is an ancestor of `<sha>`; exit `10` (`resync-needed`) printing `head=<sha>`; never changes a ref.
- `ff-merge.sh <ticket-branch> <sha> <pinned-head>` — fast-forwards (`git merge --ff-only <sha>`) only if the ticket head equals `<pinned-head>` and is an ancestor of `<sha>`; exit `0` printing `head=<sha>`; exit `10` printing the current `head=`.
- Exit `3`: the cwd does not have `<ticket-branch>` checked out, or the worktree is dirty (`git status --porcelain` non-empty). Exit `2`: argument errors, an SHA that does not match `^[0-9a-f]{40}$`, or an SHA that does not exist.

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

- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/test-ff-merge-sh.sh` → exit 1.
- [ ] **Step 3: Implement** with `git merge-base --is-ancestor`, `git rev-parse --verify --quiet "<sha>^{commit}"`, `git symbolic-ref --short HEAD`, `git merge --ff-only`.
- [ ] **Step 4: Run to verify it passes.** Exit 0.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): add ff-merge.sh fast-forward-only integration"`.

---

### Task 5: `ledger.sh` — state, lock and the transition table

**Files:**
- Create: `dev-workflow/skills/coordinating-partner-sessions/scripts/ledger.sh`
- Test: `dev-workflow/tests/test-ledger-sh.sh` (Task 6 extends it)

**Interfaces:**
- Consumes: `frontier.sh --check-edge` (Task 3); `git`.
- Produces — every subcommand takes the ledger path first; exit codes shared by all: `0` applied (prints the new status), `10` idempotent no-op, `20` message rejected (logged), `30` illegal transition refused (logged), `40` lock held by a live other session (prints `holder=`), `2` usage or I/O error.
  - `ledger.sh init <ledger> <KEY> <ticket-branch> <coord-name> <coord-session-id> <issues.json>` — `issues.json` is `[{"n":12,"blockers":[9],"external":[],"branch":"…","testCmd":"…","ac":["AC-1"]}]`; writes every issue `pending`, `gen` 0, `canary` `pending`, `cap` 3. Refuses (exit 2) if the ledger exists.
  - `ledger.sh get <ledger> [<n>]` — the JSON state (or one issue) on stdout; the shape `frontier.sh` consumes.
  - `ledger.sh lock <ledger> <own-session-id> <agents.json>` / `ledger.sh unlock <ledger> <own-session-id>` — lock at `$(git rev-parse --git-common-dir)/partners-<KEY>.lock/holder`. Live = holder equals own ID, or `agents.json` has an entry with that `sessionId` whose process is alive (field per Task 1; `kill -0 <pid>`). Not live → take over, append `{"event":"lock-takeover","old":…,"at":…}` to `.log`.
  - `ledger.sh event <ledger> <n> <event> [args]` — the only way statuses change. Events (one per transition-table row; spec "Transition table"):

| Event | Args | Row |
|---|---|---|
| `launch` | `<session-name> <session-id> <start-sha>` | `pending → launched`; gen+1; refused if a blocker is not `merged`, no slot is free, or `canary` ≠ `passed` and another issue was already launched |
| `relaunch` | `<session-name> <session-id>` | `failed → launched`; gen+1; rework reset |
| `queue-check` | `stale\|ok` | `done-claimed → resync-requested\|verifying` |
| `gate` | `merged\|resync\|fail` | `verifying → merged\|resync-requested\|rework-n/3`; third `fail` in a gen → `failed` (reason `rework budget`); `merged` moves every `blocked-on #<n>` issue to `pending` |
| `stuck-accept` | `<m>` | live → `blocked-on #m` via `--check-edge` (exit 30 + `cycle` on refusal); queues `CANCEL #n` in the outbox |
| `edge-remove` | — | `blocked-on → pending` |
| `drop` | — | `pending\|blocked-on\|failed → cancelled`; prints `dependents=<list>` for the user decision |
| `json` | `failed\|stopped\|blocked\|done\|working` | live (not `done-claimed`/`verifying`) + `failed` → `failed`; everything else: exit 10 (observation only) |
| `wake-failed` | — | live (not `done-claimed`/`verifying`) → `failed` |
| `user-merged` | — | `failed → merged` only if `git merge-base --is-ancestor <issue branch tip> <ticket-branch>`; else exit 30 |
| `cancel-ticket` | — | (n ignored, pass `0`) every non-terminal → `cancelled`; `CANCEL` queued for each live issue |
| `canary-passed` | — | (n = canary issue) sets `.canary = "passed"` |
  - `ledger.sh slots <ledger>` — prints the count of issues in a live status.
  - `ledger.sh done <ledger>` — exit 0 printing `handback` when every issue is `merged`/`cancelled` and ≥1 `merged`; `cancel-ticket` when all are `cancelled`; exit 1 otherwise.

- [ ] **Step 1: Write the failing tests.** Fixture ledgers via `init` in a throwaway git repo (needed for the lock path and `user-merged`). Test names and assertions:
  - `atomic_write`: after any `event`, no `*.tmp*` file remains next to the ledger and `jq -e .` on the fenced block succeeds; a write interrupted between temp and `mv` (simulate: leave a stray temp) leaves the previous ledger readable.
  - `lock_contention`: lock as `S1` (exit 0); lock as `S2` with `agents.json` listing `S1` alive (pid `$$`) → exit 40, `holder=S1`.
  - `lock_own`: `S1` locks twice → both exit 0.
  - `lock_stale_takeover`: holder `S1` listed with a dead pid (spawn `sleep 0 &`, `wait`, use its pid) → `S2` gets exit 0 and `.log` has `lock-takeover`.
  - `lock_per_key` (Review Focus 5): ledgers for `AAA` and `BBB` in one repo; locks by different sessions both succeed; `ls` shows two lock dirs.
  - `canary_gate`: launch issue 1 → 0; launch issue 2 before `canary-passed` → 30; after `canary-passed` → 0.
  - `launch_blocked`: issue with unmerged blocker → 30.
  - `slots_cap`: three live issues; `launch` a fourth → 30; `slots` prints `3`; `blocked-on`, `failed` and terminal statuses do not count.
  - `every_row`: one assertion per row of the event table above, checking the new status string exactly (e.g. `rework-1/3`, `blocked-on #9`).
  - `illegal_refused`: e.g. `gate merged` on `started` → 30, status unchanged, `.log` has `refused`.
  - `third_gate_fail`: three `fail`s in one gen → `failed`; after `relaunch` one `fail` → `rework-1/3`.
  - `json_on_claimed`: `json stopped` and `json failed` on `done-claimed` → exit 10, unchanged.
  - `json_blocked_noop`: `json blocked` on `launched` and on `started` → exit 10, unchanged.
  - `drop_dependents`: dropping 1 where 2 is `blocked-on #1` prints `dependents=2`.
  - `user_merged_ancestry`: branch tip merged into ticket → `merged`; not merged → 30.
  - `all_cancelled`: `cancel-ticket` then `done` prints `cancel-ticket`; one merged + rest cancelled → `handback`.
  - `no_stranded_status`: for each non-terminal status, at least one event in the table moves it (table-driven loop over the statuses list).
- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/test-ledger-sh.sh` → exit 1.
- [ ] **Step 3: Implement** the subcommands above. State edits with `jq`; write `<ledger>.tmp.$$` then `mv -f`; append every refused or rejected call to `.log` with a reason.
- [ ] **Step 4: Run to verify it passes.** Exit 0.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): add ledger.sh state machine and run lock"`.

---

### Task 6: `ledger.sh` — messages, intents, outbox and reconciliation

**Files:**
- Modify: `dev-workflow/skills/coordinating-partner-sessions/scripts/ledger.sh`
- Test: `dev-workflow/tests/test-ledger-sh.sh` (add cases)

**Interfaces:**
- Consumes: `parse-msg.sh --frame` (Task 2); Task 5's events.
- Produces:
  - `ledger.sh message <ledger> <raw-frame>` — parses with `parse-msg.sh --frame`; binds (`from` == recorded name exactly, `gen` == current gen, `DONE` branch == recorded branch) before any state change; persists a `DONE` claim on receipt; dedups `DONE` by issue+gen+sha (exit 10); same-state repeats exit 10; clears the issue's outbox entries for that gen; then applies: `STARTED` (`launched → started`; on `rework-n/3`/`resync-requested` unchanged), `DONE` (→ `done-claimed`, prints `queue=<n>`), `STUCK needs=#m` (prints `ask-user=edge <n> <m>` or, if `m` merged, queues `RESYNC` → `resync-requested`), `STUCK`/`SCOPE` (unchanged, prints `ask-user=…`), `FAILED` (→ `failed`). Rejections exit 20 with `reason=` and a `.log` entry.
  - `ledger.sh intent <ledger> launch|merge <n> <k=v>...` → prints `intent=<id>`; `ledger.sh intent-done <ledger> <id> <outcome>`.
  - `ledger.sh outbox-add <ledger> <n> <line>` (records gen) / `ledger.sh outbox <ledger>` (prints `<n>\t<gen>\t<line>` per pending entry).
  - `ledger.sh reconcile <ledger> <agents.json>` — for each open intent: `merge` whose candidate is an ancestor of the ticket head → `merged`, else the issue returns to `done-claimed`; `launch` whose session appears in `agents.json` → record it `launched`, else back to `pending`. Then prints action lines for the coordinator: `requeue <n>` (every `done-claimed`/`verifying`), `resend <n> <line>` (every outbox entry), `status <n>` (every other live issue). Idempotent: running it twice prints the same actions and changes nothing the second time.

- [ ] **Step 1: Write the failing tests.**
  - `bind_other_issue`: frame `from="K-13"` carrying `#12` → 20.
  - `bind_near_match`: `from="k-12"`, `from="K-12 "`, `from="K-1"`, ID-valued `from` → 20 each.
  - `bind_old_gen`: `gen=1` after a relaunch to gen 2 → 20.
  - `bind_branch_mismatch`: `DONE` with another branch → 20.
  - `bind_wrong_frame`: `<agent-message from="K-12">…` → 20.
  - `frame_fixture`: the pinned frame `<cross-session-message from="K-12">STARTED #12 gen=1</cross-session-message>` → 0.
  - `done_persisted`: after `message DONE`, `get` shows the claim before any `queue-check`.
  - `done_dedup`: same `DONE` twice → second exit 10.
  - `same_state_noop`: `STARTED` on `started` → 10.
  - `stuck_merged_resync`: `STUCK needs=#9` with 9 merged → `resync-requested`, outbox has `RESYNC #12 <head>`.
  - `stuck_from_rework`: `STUCK` and `SCOPE` on `rework-1/3` and `resync-requested` → accepted (0 or 10), never 30.
  - `stuck_on_claimed`: `STUCK` on `done-claimed` → 10, prints `ask-user=`.
  - `stale_done_free`: `queue-check stale` leaves the rework count at 0.
  - `outbox_cleared`: after `outbox-add` RESYNC for gen 2, a valid gen-2 message clears it; a gen-1 message does not.
  - Crash boundaries, each followed by `reconcile` and a check of status and printed actions:
    - `crash_after_launch_intent`: intent recorded, no session in `agents.json` → `pending`.
    - `crash_after_launch_before_record`: intent open, session present in `agents.json` → `launched`.
    - `crash_after_merge_intent`: candidate not yet merged → `done-claimed`, `requeue`.
    - `crash_after_merge_before_record`: candidate already an ancestor of ticket head → `merged`.
    - `crash_during_verifying`: status `verifying` → `requeue`.
    - `crash_after_outbox_before_send`: entry present → `resend`.
  - `reconcile_idempotent`: second run changes no bytes in the ledger.
- [ ] **Step 2: Run to verify the new cases fail.** `bash dev-workflow/tests/test-ledger-sh.sh` → the new names fail.
- [ ] **Step 3: Implement** `message`, `intent`, `intent-done`, `outbox-add`, `outbox`, `reconcile`. `message` calls `parse-msg.sh` by absolute path with the frame as one argv argument.
- [ ] **Step 4: Run to verify it passes.** Exit 0.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): ledger.sh message binding, intents, outbox and reconcile"`.

---

### Task 7: Reference files — `ledger.md`, `readiness.md`, `partner-brief.md`

**Files:**
- Create: `dev-workflow/skills/coordinating-partner-sessions/ledger.md`, `readiness.md`, `partner-brief.md`
- Test: `dev-workflow/tests/run.sh` (new block `== coordinating-partner-sessions skill ==`, its own counter `pfail()` / `PARTNER_FAILS` like intake's `ifail`; this task adds the pins for these three files)

**Interfaces — Produces:** the brief's placeholders, which `SKILL.md` fills: `{{KEY}}`, `{{N}}`, `{{ISSUE_URL}}`, `{{GEN}}`, `{{SESSION_NAME}}`, `{{COORD_NAME}}`, `{{WORKTREE}}`, `{{BRANCH}}`, `{{TICKET_BRANCH}}`, `{{START_SHA}}`, `{{AC}}`, `{{TEST_CMD}}`, `{{BLOCKER_EVIDENCE}}`.

- [ ] **Step 1: Write the failing pins** in `run.sh` (each `grep -qF '<phrase>' "$PS_DIR/<file>" || pfail "..."`):
  - `ledger.md`: `## Transition table`; each of the 11 status strings; `generation`; `outbox`; `launch-intent`; `merge-intent`; `partners-<KEY>.lock`; `ledger.sh event`.
  - `readiness.md`: `story`; `acceptance criteria`; `test command`; `a stated reason none is needed`; `ask only about what changed`.
  - `partner-brief.md`: `gen=`; `never rebase onto main`; `Never push`; `never open a PR`; `never close or edit GitHub issues`; `STATUS?`; `RESYNC`; `REWORK`; `CANCEL`; `its issue stays open until the ticket PR merges, by design`; `{{COORD_NAME}}`; `{{BLOCKER_EVIDENCE}}`.
- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/run.sh` → `FAIL: coordinating-partner-sessions/...` lines, `FAILED`.
- [ ] **Step 3: Write the three files.**
  - `ledger.md`: the JSON schema (fields per Task 5/6), status vocabulary, the spec's transition table verbatim with each row's `ledger.sh` event, slot rule, generation rule, outbox and intent rules, lock liveness.
  - `readiness.md`: the mini-intake checklist (story, acceptance criteria, test approach or a stated reason none is needed, the issue's test command), the up-front mode (one sitting, every issue, close every gap before any launch) and the partner re-check mode (current code; ask only about what changed).
  - `partner-brief.md`: the spec's "Partner flow" as a fill-in template — identity, inputs, integration base (`{{TICKET_BRANCH}}`; never rebase onto main), blocker evidence, authority (local commits; may show `Needs input`), forbidden list, steps 1–5, the exact message lines with `gen=`, and the reply rules for `STATUS?`, `RESYNC`, `REWORK`, `CANCEL`.
- [ ] **Step 4: Run to verify it passes.** `bash dev-workflow/tests/run.sh` → no `coordinating-partner-sessions` failures from these pins (the SKILL.md pins arrive in Task 8; until then gate them behind `[ -f "$PS_SKILL" ]` so this task can pass).
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): partner-session ledger, readiness and brief references"`.

---

### Task 8: `SKILL.md` — the coordinator loop

**Files:**
- Create: `dev-workflow/skills/coordinating-partner-sessions/SKILL.md`
- Test: `dev-workflow/tests/run.sh` (same block), and wire the four script tests into `run.sh` the way `test-audit-sh.sh` is wired (`if bash "$HERE/test-<x>-sh.sh"; then :; else fail "…"; fi`)

**Interfaces — Consumes:** every script interface (Tasks 2–6), the brief placeholders (Task 7), the blockers read command (Task 1).

- [ ] **Step 1: Write the failing pins:**
  - frontmatter `name: coordinating-partner-sessions`; description ≤ 1024 chars; `SKILL.md` under 500 lines; links `](ledger.md)`, `](readiness.md)`, `](partner-brief.md)`; each `scripts/*.sh` exists and is executable.
  - phrases: `fast-forward only`; `RESYNC`; `REWORK`; `STATUS?`; `gen=`; `Git state matches the claim`; `Tests pass, run by the coordinator`; `Every AC has evidence`; `dev-workflow:fresh-verifier`; `Partners never push or open PRs`; `third failed gate`; `stop and ask the user` (name collision); `held for approval`; `v2.1.236`; `v2.1.248`; `not in plan mode`; `integration base is the ticket branch`; `/rename`; `canary`; `600`; `cross-session-message`; `deferred`; `Refs`; `notify_when_idle`; `re-register`; `skip steps 3–5`; `/retro`; `skill-retrospective`.
  - negative: no whole-word `ces` anywhere under `coordinating-partner-sessions/`.
- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/run.sh` → `FAILED`.
- [ ] **Step 3: Write `SKILL.md`** following the spec's sections in order, each as an imperative section that names the script call:
  - **When to use / inputs:** called from `chain-sdlc-process.md` stage 5, or standalone with a ticket key, the ticket branch and its published issues.
  - **Preflight:** version (`claude --version` ≥ `v2.1.236`, `v2.1.248` on Bedrock/Vertex/Foundry or flag fetching off); not in plan mode; own name from `ListAgents` (auto-generated or colliding → ask the user to `/rename`, recommend `<KEY>-coord`); held messages in both directions from settings (`crossSessionInbound`, permission class) — stop and name the setting, never edit settings; `gh` auth; ticket branch checked out clean.
  - **Steps 2–5:** lock (`ledger.sh lock`); existing ledger → check the own name still equals the recorded coordinator name (else ask the user to `/rename` back), `ledger.sh reconcile`, act on its lines, **skip steps 3–5**; read issues with the Task 1 command (fallback `Blocked by:` parse; external blockers per Review Focus 3); readiness up front (`readiness.md`); `ledger.sh init`; `frontier.sh` cycle → stop and show.
  - **Step 6 launch + canary:** per launch: `ListAgents` name check (collision → stop and ask the user); `ledger.sh intent launch`; worktree/branch (old ones → `-g<old>`); fill `partner-brief.md`; `cd <worktree> && claude --bg --name <KEY>-<n> --permission-mode <mode> "<brief>"`; read `sessionId` from `claude agents --json`; `ledger.sh event … launch`; `SendMessage` with `notify_when_idle`. Canary: first launch only; start a background `sleep 600` as the leg timer; leg 1 passes on `STARTED`; if the idle notice arrives first and `--json` says `blocked`, tell the user the canary is waiting on them in `<KEY>-<n>` and keep waiting (not a failure; restart the timer); leg 2: `STATUS? #n` with a fresh `sleep 600`; on pass `ledger.sh event … canary-passed`; on a failed leg stop launching and name the leg and likely setting.
  - **Steps 7–9 wait, messages, integration queue:** every wake reads `claude agents --json` to a temp file and `ledger.sh event … json <state>` for each partner; re-register `notify_when_idle` after every consumed notice and when older than ~11 h; messages go through `ledger.sh message`; act on its output lines; the queue runs one `DONE` at a time: `ff-merge.sh --check` → `queue-check`; pin head; the four gate checks (test run in a throwaway worktree at `<sha>`; per-AC evidence; `dev-workflow:fresh-verifier`); `ledger.sh intent merge`; `ff-merge.sh`; `gate merged|resync|fail`; send outbox lines (`ledger.sh outbox-add` before every `SendMessage`); delivery failure → `claude --resume <sessionId> --bg --name <KEY>-<n> "<line>"`, re-read name and `sessionId`.
  - **Error handling:** idle-notice branches; failure options (relaunch / handled it themselves / drop / cancel the ticket); `STUCK`/`SCOPE` handling including the retrospective recommendation (the user runs `/retro` on the workspace's ticket-creation skill, then `dev-workflow:skill-retrospective`; never launched by the coordinator).
  - **Step 10 hand-back:** `ledger.sh done`; `cancel-ticket` → release lock, tell the user; `handback` → mark each cancelled issue's AC `deferred` with the user's reason, release the lock, return to intake step 7 then 8; `Closes`/`Refs` for `merged` issues only; cancelled issues listed as not delivered.
- [ ] **Step 4: Run to verify it passes.** `bash dev-workflow/tests/run.sh` → `ok: coordinating-partner-sessions skill present …`, all four script tests ok, `PASSED`.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): coordinating-partner-sessions coordinator skill"`.

---

### Task 9: Intake integration at stage 5

**Files:**
- Modify: `dev-workflow/skills/intaking-work-items/chain-sdlc-process.md` (stage 5 and Controls → Resume)
- Modify: `dev-workflow/skills/intaking-work-items/template.md` (Chain artifacts gains the partners ledger path)
- Test: `dev-workflow/tests/run.sh` (intake block)

**Interfaces — Consumes:** the skill name `dev-workflow:coordinating-partner-sessions` and its hand-back contract (Task 8 step 10).

- [ ] **Step 1: Write the failing pins** in the intake block:
  - `chain-sdlc-process.md`: `one after another or parallel partners`; `dev-workflow:coordinating-partner-sessions`; `docs/specs/<KEY>-partners.md`; `AC of a cancelled issue are deferred`; `closing keywords and Refs cover merged issues only`; `only when two or more issues are published`.
  - `template.md`: `<KEY>-partners.md`.
  - Existing negative pin still holds: no whole-word `ces` in `intaking-work-items/`.
- [ ] **Step 2: Run to verify it fails.** `bash dev-workflow/tests/run.sh` → intake `FAIL` lines.
- [ ] **Step 3: Edit stage 5.** Before the router hand-off, add: when two or more issues are published, ask once — one after another (today's path, unchanged) or parallel partners. Parallel invokes `dev-workflow:coordinating-partner-sessions` with the ticket key, ticket branch, issue links and settled AC list; the coordinator owns stage 5 and returns to step 7. State the hand-back contract (deferred AC, `Refs`/`Closes` for merged issues only). Resume: if `docs/specs/<KEY>-partners.md` exists, re-invoke the coordinator (it reconciles). Record the choice in the Run log.
- [ ] **Step 4: Run to verify it passes.** `bash dev-workflow/tests/run.sh` → `PASSED`.
- [ ] **Step 5: Commit.** `git commit -m "feat(dev-workflow): offer parallel partner sessions at sdlc-process stage 5"`.

---

### Task 10: Version, README, CI check

**Files:**
- Modify: `dev-workflow/.claude-plugin/plugin.json` (`"version": "0.1.8"`), `dev-workflow/README.md` (Skills table row `| \`coordinating-partner-sessions\` |`; intake row mentions the parallel option)
- Test: `dev-workflow/tests/run.sh`

- [ ] **Step 1: Write the failing pins:** `grep -qF '"version": "0.1.8"' "$ROOT/.claude-plugin/plugin.json"`; `grep -qF '| \`coordinating-partner-sessions\` |' "$ROOT/README.md"`.
- [ ] **Step 2: Run to verify it fails.** → 2 `FAIL` lines.
- [ ] **Step 3: Edit** both files.
- [ ] **Step 4: Verify CI coverage without editing the workflow.** `.github/workflows/tests.yml` already runs `*/tests/run.sh` on Ubuntu (installs `jq`) and macOS (`/bin/bash`), and Task 8 wires the script tests into `run.sh`. Run `/bin/bash dev-workflow/tests/run.sh` locally → `PASSED`. Run `bash scripts/scrub-check.sh --check-overbroad --allow scripts/scrub-allow.txt .` → exit 0. If the macOS runner lacks `jq` (first CI run fails with `jq: command not found`), add `brew install jq` to the macOS job and re-run — that is the only permitted CI edit.
- [ ] **Step 5: Commit.** `git commit -m "chore(dev-workflow): bump to 0.1.8 and list coordinating-partner-sessions"`.

---

### Task 11: Live trial (manual, run by the user before release)

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
  - Hand-back to intake step 7; one draft PR covering A, B and C with `Refs`/`Closes` per step 8's rule.
- [ ] **Step 4: Clean up** scratch issues, branches, worktrees and sessions (user confirms each remote deletion).
- [ ] **Step 5: Commit** the results section: `git commit -m "docs(dev-workflow): record partner-session live trial"`.

---

## Review chain

Full tier (skill definitions, new scripts, more than 150 lines): `dev-workflow:fresh-verifier` and `dev-workflow:codex-adversary` in one message on this plan before Task 1, and on the full diff before the PR (intake-style `opening-pull-requests` gates). Every push needs the user's confirmation.
