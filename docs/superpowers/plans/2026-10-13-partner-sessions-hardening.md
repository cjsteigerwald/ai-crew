# Partner-session ledger and lifecycle hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four findings the adversarial re-check left open on `feat/partner-sessions-design` (HEAD `5061c1d`): stale work commands resent forever, a pid-reuse wedge of the write mutex, the stale-reap lost update, and "CANCEL and wait" never ending.

**Architecture:** Item 1 becomes an outbox invariant enforced in `ledger.jq` and repaired by `reconcile`. Items 2 and 4 replace the `mkdir` write mutex and the `takeover/` directory with one kernel advisory lock (the OS lock command: macOS `lockf`, Linux `flock`) taken on the writer's own file descriptor and held for the whole mutating command, so a crash releases it and nothing is ever reaped. Item 3 makes the coordinator end a cancelled partner itself with `claude stop <id>`.

**Tech Stack:** bash 3.2 (macOS `/bin/bash`), BSD/GNU tools, jq 1.6+, the OS lock command (`/usr/bin/lockf` on macOS, util-linux `flock` on Linux), Claude Code ≥ 2.1.236.

**Spec:** `docs/superpowers/specs/2026-10-12-partner-sessions-design.md` (binding). Prior plan: `docs/superpowers/plans/2026-10-12-partner-sessions.md`. Findings and rulings: `.superpowers/sdd/2026-10-12-partner-sessions/progress.md` (git-ignored).

## Global Constraints

- Everything from the prior plan's Global Constraints still binds: bash 3.2, BSD/GNU tools, jq 1.6+, no `claude`/`gh` inside scripts, message text argv-only (never eval'd or interpolated), SKILL.md < 500 lines, no whole-word `ces`, pins are specific phrases.
- **Decision:** User approved the OS lock command (lockf/flock) over perl, 2026-10-13. No new language dependency.
- **Lock tool, chosen at runtime** (fd form, no re-exec): the writer opens `exec 9>>"$D/write.lock"` itself, then macOS `/usr/bin/lockf -s -t <secs> 9` or Linux util-linux `flock -w <secs> 9` locks that fd. Verified on macOS 27.0.1: `/usr/bin/lockf` exists; `exec 9>>file; /usr/bin/lockf -s -t N 9` holds the lock, a contender gets rc 75 while the holder lives, and the lock is released when the holder exits; `type flock` → not found. Ubuntu runners ship util-linux `flock`. CI runs the suite on macOS (lockf path) and Ubuntu (flock path), so both are exercised.
- **Rejected: the re-exec form** (`lockf -k … bash ledger.sh …`). Reproduced on macOS: SIGKILL or SIGTERM to the `lockf` process frees the lock while the child bash keeps writing, a lost update. With the fd form the lock belongs to the writer's own open file description and is released only when that bash and its children exit, including SIGKILL.
- `ledger.sh` exit codes never include 75, so lockf's timeout code is unambiguous and is mapped to 41; flock's timeout rc 1 is mapped to 41 the same way.
- New exit code **41** = ledger busy (the write lock wait ran out). Exit 40 keeps its meaning (lost run lock); 2 stays usage/IO.
- Outbox invariant: a non-`CANCEL` ("work") entry exists only for its issue's **current** `gen`, and only while the issue is `resync-requested` or `rework-n/3`.
- The coordinator stops only sessions it launched, and only as the consequence of a user decision (drop, cancel the ticket, relaunch). `claude stop <id>` keeps the conversation (`claude stop --help`, 2.1.296: "Stop a background session. Its conversation is kept; resume it later").
- Every task verifies with: `/bin/bash dev-workflow/tests/run.sh` → `PASSED`; `bash scripts/scrub-check.sh --check-overbroad --allow scripts/scrub-allow.txt .` → exit 0.

## Review record (2026-10-13)

fresh-verifier FIX-FIRST (0 MUST, 6 SHOULD, 7 NIT) and an Opus adversary FIX-FIRST (2 HIGH); all folded in. Changed: Task 2 moved from the lock-tool re-exec (lost update when `lockf` is killed) to an in-process fd lock (`take_write_lock`) and supersedes rulings CX1/T5-M2(a); Task 1 purges stale `CANCEL`s on relaunch and builds the `drop` test with `jset`; Task 3 drops the same-id resume claim, adds the `stuck-accept` stop, a timer guard, an ambiguity rule, unlock ordering and the resume path, and fixes pin wording; Task 4 targets the spec's real sections; Option B shrunk to a rejection.

## Review Focus

1. **A partner that never reaches idle after CANCEL** (busy mid-turn): the stop procedure must still end it after 300 s and must not loop if `claude stop` fails.
2. **Neither `lockf` nor `flock` on a user's machine**: preflight must stop with a named cause, never fall through to an unlocked write (Task 2 test `no_lock_tool_refused`).
3. **A raw frame with quotes, `$()`, backticks, tabs and spaces**: reaches `parse-msg.sh` byte-identical (Task 2 `frame_argv_preserved`).
4. **A ledger written by HEAD `5061c1d`** (stale work entries, an old `lock/write/` or `takeover/` left on disk): must load, and `reconcile` must repair it (Task 1 `reconcile_repairs_stale_work`; Task 2 `legacy_lock_dirs_ignored`).
5. **Two alive copies of one issue's session before a relaunch** (M2): after "stop every alive session in the issue's session history", `priorPid` is null; Rebind as usual (Task 3 pins; live trial).
6. **lockf/flock killed or absent mid-write**: the lock is the writer's own fd, so killing a lock-tool process cannot free it (Task 2 `lock_held_until_writer_exits`).

---

### Task 1: Outbox invariant — purge stale work commands (item 1)

Root cause, verified: outbox entries are keyed `(n, gen)`. `outbox_clear_gen` (`scripts/ledger.jq:75-77`) clears only the current `gen`; `record_launch` (`:81-88`) never touches the outbox; transitions into `merged` (`to_merged`, `:90`, used by `gate merged` `:181`, `user-merged` `:284`, reconcile `:403`), `cancelled` (`drop` `:256`, `cancel-ticket` `:294`) and `failed` (`:202`, `:264`, `:275`, `:346`) leave work entries behind, and `reconcile-actions` (`:448`) resends every entry.

**Files:**
- Modify: `dev-workflow/skills/coordinating-partner-sessions/scripts/ledger.jq`
- Modify: `dev-workflow/skills/coordinating-partner-sessions/ledger.md` (Rules → Outbox bullet)
- Test: `dev-workflow/tests/test-ledger-sh.sh`, `dev-workflow/tests/test-coordinator-contract-sh.sh`

**Interfaces:**
- Produces (jq): `def outbox_purge_work($k)` — drops every entry of issue `$k` whose `line` does not start with `CANCEL #`. CANCEL entries are untouched by it (Task 3 owns their lifecycle), with one exception: `record_launch` also drops every `CANCEL` of `$k` whose `gen` < `$in.gen`. That is safe because Task 3 stops every older session before any relaunch or re-launch. Reproduced: `stuck-accept` puts #1 in `blocked-on` and queues `CANCEL #1`; #2 merges, `to_merged` returns #1 to `pending`, and `json done nopid` is a no-op for `pending` (`ledger.jq` ~:267), so the gen-2 launch under the same name gets `resend 1 TEST-1 CANCEL #1` on reconcile.
- Produces (log line): `outbox-stale-purged n=<n> gen=<g>` written by `reconcile` for each repaired entry.
- Produces (test helper): `assert_outbox_invariant <ledger>` — a jq check that every non-CANCEL entry has `.gen == .issues[n].gen` and that issue's status is `resync-requested` or starts with `rework-`; and once the issue is `launched` or later, no `CANCEL` exists with `.gen` < the issue's current `gen`.
- No CLI change.

- [ ] **Step 1: Write the failing tests** in `test-ledger-sh.sh`:
  - `stale_gen_work_purged`: launch, `STARTED`, `DONE`, `queue-check ok`, `gate fail "fix the tests"`, `json failed`, `intent relaunch` + `event relaunch` (gen 2). Assert `outbox` has no line containing `REWORK #1`. Then `STARTED gen=2`, `DONE gen=2`, `reconcile`: assert no `resend 1` line.
  - `user_merged_purges_work`: an issue with an outstanding `REWORK`, then `json failed`, `user-merged` → outbox has no `REWORK #<n>`.
  - `failed_and_cancelled_purge_work`: `drop` refuses `resync-requested` (`ledger.jq` ~:246), so build the `drop` case with `jset` (issue `failed`, outbox holding a `RESYNC` at the current gen, the shape a HEAD-`5061c1d` ledger can have), then run `drop` → no `RESYNC #<n>`. Keep the event-driven legs for `cancel-ticket` from `resync-requested` and for `json failed` → no `RESYNC #<n>`; a queued `CANCEL #<n>` (where the transition queues one) is still present.
  - `blocked_cancel_purged_on_relaunch`: `stuck-accept` puts #1 in `blocked-on #2` and queues `CANCEL #1`; #2 merges (#1 → `pending`); launch #1 again (gen 2) → outbox has no `CANCEL #1` of gen 1; `reconcile` prints no `resend 1`.
  - `reconcile_repairs_stale_work`: hand-build a ledger (via `jset`) with issue 1 at `gen: 2`, status `started`, outbox `[{n:1,gen:1,to:"TEST-1",line:"REWORK #1 x"}]`. `reconcile` → exit 0, the entry is gone, the log has `outbox-stale-purged n=1 gen=1`, output has no `resend 1`.
  - Add `assert_outbox_invariant` and call it after every rc-0 mutating call by wrapping the existing `run` helper (`test-ledger-sh.sh:38`) when its subcommand is one of `init intent event message session reconcile`. Do the same in `test-coordinator-contract-sh.sh`'s ledger wrapper. Hand-built ledgers that deliberately violate it (the repair test) call the raw script.
- [ ] **Step 2: Run, expect FAIL**: `/bin/bash dev-workflow/tests/test-ledger-sh.sh` → FAIL in `stale_gen_work_purged` (REWORK still listed) and invariant failures.
- [ ] **Step 3: Implement** `outbox_purge_work($k)` in `ledger.jq`; call it at the end of `record_launch` (which also drops older-gen `CANCEL`s of `$k`) and in `to_merged`, and in every `drop`, `cancel-ticket`, and `→ failed` branch listed above. In `reconcile`, purge every non-CANCEL entry violating the invariant in the same write, collecting `{n,gen}` for the log line (written by `cmd_reconcile` via `logl`).
- [ ] **Step 4: Run, expect PASS**: `/bin/bash dev-workflow/tests/test-ledger-sh.sh` → `all ledger tests passed`; `/bin/bash dev-workflow/tests/test-coordinator-contract-sh.sh` → `ok`.
- [ ] **Step 5: Docs**: ledger.md Outbox bullet states the invariant in one sentence. Run `/bin/bash dev-workflow/tests/run.sh` → `PASSED`.
- [ ] **Step 6: Commit** `fix(dev-workflow): ledger outbox holds work commands only for the current generation`.

Rejected alternative: adding `gen=` to coordinator→partner lines so partners ignore stale commands. Unneeded once the invariant holds, and it would change the partner protocol and brief.

---

### Task 2: Kernel write lock via the OS lock command — `lockf`/`flock` (items 2 and 4, Option A)

Root cause, verified: the write mutex is `mkdir lock/write` with `lock/write/pid` (`scripts/ledger.sh:168-221`, `wm_pid`/`wm_acquire`/`wm_release`). Staleness is `kill -0 <pid>` only (`:196-197`), so a reused pid wedges every write (exit 2) and takeover (exit 40). Reaping is check-then-`rm -rf` (`:200-206`); with only `mkdir`/`rename` there is no compare-and-swap, so any reap protocol narrows the race but cannot close it. The `takeover/` directory (`take_mutex`/`takeover_stale`, `:143-166`, used by `cmd_lock` `:223-292`) has the same shape and the BSD/GNU `find -mmin` age skew.

**Files:**
- Modify: `dev-workflow/skills/coordinating-partner-sessions/scripts/ledger.sh` (header `:21-48`, new `take_write_lock`, `cmd_lock`, `begin_write`, `write_state`, `cmd_unlock`, and the other mutating subcommands' `set_paths` sites; delete `take_mutex`, `takeover_stale`, `wm_*`)
- Modify: `dev-workflow/skills/coordinating-partner-sessions/ledger.md` (Location and lifetime `:11-12`, Lock protocol `:144-159`, Exit codes `:161`)
- Modify: `dev-workflow/skills/coordinating-partner-sessions/SKILL.md` (Preflight `:90-111`, step 2 lock `:122-124`, step 8 exit handling `:257`, Hard rules `:40-51`)
- Modify: `.github/workflows/tests.yml` (macOS step "Provision jq and report bash", `:89-92`)
- Modify: `dev-workflow/tests/run.sh` (pins)
- Test: `dev-workflow/tests/test-ledger-sh.sh`

**Interfaces:**
- Consumes: Task 1's ledger.jq (unchanged by this task).
- Produces: every mutating subcommand (`lock unlock init intent event message session reconcile`) runs entirely under an exclusive kernel lock on `$D/write.lock` (via `lockf` or `flock` on fd 9), where `$D` is the ledger's directory derived from the first argument. Read-only subcommands (`path get outbox slots done summary`) take no lock; `mv` keeps the ledger a whole snapshot.
- Produces: exit **41**, stdout `busy=<D>/write.lock`, when the lock is not acquired within `PS_WRITE_WAIT` seconds (default `10`, integer ≥ 1).
- Produces: `take_write_lock` (the one decided body), in `ledger.sh` beside `begin_write`:

  ```bash
  take_write_lock() {
    [ -d "$D" ] || die "no ledger directory $D (run ledger.sh path first)"
    wait="${PS_WRITE_WAIT:-10}"
    lf="$D/write.lock"; exec 9>>"$lf" || die "cannot open $lf"
    if [ -x "${PS_LOCKF:-/usr/bin/lockf}" ]; then   # macOS / BSD
      "${PS_LOCKF:-/usr/bin/lockf}" -s -t "$wait" 9; rc=$?
      if [ "$rc" -eq 75 ]; then echo "busy=$lf"; exit 41; fi   # EX_TEMPFAIL = timed out
      [ "$rc" -eq 0 ] || die "lockf failed (rc $rc) on $lf"
    elif command -v flock >/dev/null 2>&1; then     # Linux util-linux
      flock -w "$wait" 9; rc=$?
      if [ "$rc" -eq 1 ]; then echo "busy=$lf"; exit 41; fi     # timed out
      [ "$rc" -eq 0 ] || die "flock failed (rc $rc) on $lf"
    else
      die "a lock tool is required: /usr/bin/lockf (macOS) or flock (util-linux)"
    fi
  }
  ```

  Call it in every mutating subcommand right after `set_paths` (before any read, and before the `PS_WRITE_TEST_PAUSE` hook): `cmd_lock` (`ledger.sh:225`, `set_paths "$1"; OWN=…`, so the call follows that line), `cmd_unlock` (`:325`; order `set_paths` → `take_write_lock` → `begin_write`), `cmd_init` (`:368`), `cmd_intent` (`:489`), `cmd_event` (`:540`), `cmd_message` (`:612`), `cmd_session` (`:650`), `cmd_reconcile` (`:667`). `cmd_lock` calls it before its own-holder early return. The lock belongs to the writer's own open fd and is released only when that bash and its children exit, including SIGKILL; there is no re-exec and no lock-tool process outliving the acquisition. Note: fd 9 is inherited by children (jq, `frontier.sh`); harmless, because they exit before the writer does. `lockf -s` is silent (no `already locked` text). `ledger.sh` never exits 75, so lockf's timeout code maps to 41 unambiguously. `lockf -t` and `flock -w` take whole seconds, so `PS_WRITE_WAIT` is an integer ≥ 1. `PS_LOCKF` (default `/usr/bin/lockf`) exists so a test can hide the tool on macOS. The implementer may restructure, but these properties are the contract.
- Produces: `cmd_lock` without `takeover/`: under the write lock, remove any legacy `lock/write/` or `takeover/` (logged `legacy-lock-dir-removed`) **before** the own-holder early return; `mkdir -p lock`; read holder; own holder → print `owner=<sid>:<nonce>`; a live other holder → exit 40; else write a fresh holder (temp + `mv`) and print `owner=`. `owner_check` stays at the start of every write and immediately before `mv` in `write_state`. The post-`mv` holder re-read and `write-after-takeover` are deleted (no writer can interleave).
- Supersedes ruling CX1's mechanism (mkdir mutex, `kill -0` staleness) and T5-M2(a) (post-`mv` holder re-read, `write-after-takeover`). Their property — no takeover or second writer between a writer's owner check and its `mv` — is kept by the kernel lock. Record a Ruling line when executed.
- Produces: a leftover `lock/write/` or `takeover/` from HEAD `5061c1d` is ignored and removed by the next `lock`.
- Test hooks: `PS_WRITE_TEST_PAUSE=<file>` pauses **inside** the write lock (after the owner check, before the read), so a test can hold the lock; the hook writes its own `$$` into `<file>.waiting`. `PS_LOCK_TEST_PAUSE` is removed (no window left to probe).

- [ ] **Step 1: Write the failing tests** in `test-ledger-sh.sh`:
  - `lock_released_on_kill9`: start a writer with `PS_WRITE_TEST_PAUSE` set (background); wait for `<file>.waiting`, which holds the writer's own `$$`; `kill -9` THAT pid (not `$!`); a second `event … canary-passed` completes with rc 0 in under 2 s; `jq -e 'type=="object"' "$L"` passes.
  - `parallel_writers_no_lost_update`: init 12 issues; launch 12 background `event <n> drop "r<n>"` calls with `PS_WRITE_WAIT=60`; wait; every one of the 12 is `cancelled` and every rc is 0.
  - `busy_timeout_41`: hold the lock with a paused writer; `PS_WRITE_WAIT=1` second writer → rc 41, stdout `busy=…/write.lock`, ledger bytes unchanged (`cmp`). Also assert that no `lockf`/`flock` process is alive while the paused writer holds the lock (`ps` check), which proves the lock is the writer's own fd.
  - `lock_held_until_writer_exits`: with a paused writer holding the lock, kill any lock-tool process found (expect none); a contender with `PS_WRITE_WAIT=1` still gets rc 41.
  - `takeover_serialized`: holder `S1` dead in agents.json; two background `lock "$L" S2 …` / `lock "$L" S3 …` with S2 and S3 live → exactly one rc 0 and one rc 40; `lock/holder` names the winner.
  - `lost_owner_refused`: after a takeover by S2, a write with S1's `PS_OWNER` → rc 40, `holder=S2`, ledger unchanged.
  - `frame_argv_preserved`: `ledger.sh message "$L" '<cross-session-message from="TEST-1">FAILED #1 gen=1 a "q" $(x) `y` \t z</cross-session-message>'` (a literal tab) → stored `.issues["1"].reason`, with the `FAILED: ` prefix removed, equals the input reason byte for byte; no file `x`/`y` created.
  - `legacy_lock_dirs_ignored`: pre-create `lock/write/pid` (pid 1) and `takeover/owner`, with the run lock already held by the caller (own-holder path) → `lock` succeeds, both are gone, log has `legacy-lock-dir-removed` (cleanup runs before `cmd_lock`'s own-holder early return).
  - `no_lock_tool_refused`: run with neither tool reachable: `PS_LOCKF=/nonexistent` and a stub `PATH` dir holding only symlinks to `jq`, `git`, `bash` and `dirname`, plus any other external tool `ledger.sh` calls before dispatch (check its top lines `:50-60`; `DIR=…$(dirname "$0")` is the first) → a mutating call exits 2 with `lock tool` in the message; ledger unchanged.
  - Remove `write_mutex` (`:942`), `stale_takeover_dir` (`:347`), `lock_concurrent_takeover` (`:316`, depends on `PS_LOCK_TEST_PAUSE` and `takeover/`) and `write_fencing` (`:874`, replaced by `lost_owner_refused` + `lock_released_on_kill9`). Keep `lock_contention`, `lock_own`, `unlock`, `lock_stale_takeover`, `lock_missing_holder`, `lock_no_pid_fallback`, `lost_lock_refused`, `lock_per_key`.
- [ ] **Step 2: Run, expect FAIL**: `/bin/bash dev-workflow/tests/test-ledger-sh.sh` → FAIL at `lock_released_on_kill9` / `busy_timeout_41` (no exit 41 today).
- [ ] **Step 3: Implement** `take_write_lock` called in each mutating subcommand right after `set_paths`, simplified `cmd_lock`, `begin_write` = owner check + pause hook, `write_state` = validate + owner check + `mv`. Delete `take_mutex`, `takeover_stale`, `wm_pid`, `wm_acquire`, `wm_release`, the `TK` path and the EXIT-trap mutex release. Rewrite the header (`:21-48`) for the write lock, exit 41 and the new hook position. Neither lock tool present → die with `a lock tool is required: /usr/bin/lockf (macOS) or flock (util-linux)`.
- [ ] **Step 4: Run, expect PASS**: test-ledger-sh.sh and test-coordinator-contract-sh.sh pass; run each new concurrency test 5 times in a loop (with `PS_WRITE_WAIT=60` for `parallel_writers_no_lost_update`) → 5/5.
- [ ] **Step 5: Docs and CI.**
  - ledger.md: Location lists `write.lock` (kernel lock, never committed, never reaped) and drops `lock/write/` and `takeover/`; Lock protocol step 6 rewritten; Exit codes row `41 | ledger busy: another mutating call holds write.lock`.
  - SKILL.md Preflight gains the probe `[ -x /usr/bin/lockf ] || command -v flock` (failure: stop, name the missing lock tool), then a one-shot fd probe in a temp file (`exec 9>>tmpfile; /usr/bin/lockf -s -t 0 9`, or `flock -n 9`) so an old `lockf` without fd support fails with a named cause. Exit handling: `41` → wait 5 s and retry once; still 41 → tell the user and show `lsof "<D>/write.lock"`. Replace "write mutex held → coordinator bug". Hard rules: never run two mutating `ledger.sh` calls in parallel is no longer required for safety but keep "one at a time" for ordering.
  - `.github/workflows/tests.yml`: no install needed (macOS ships `/usr/bin/lockf`, Ubuntu ships util-linux `flock`). Add a report line to each job's tool step: macOS `ls -l /usr/bin/lockf`, Ubuntu `flock --version`.
  - run.sh pins: `write.lock`, `exit 41`, `lockf -s`, `flock -w`.
- [ ] **Step 6: Verify** `/bin/bash dev-workflow/tests/run.sh` → `PASSED`; scrub-check exit 0; `wc -l SKILL.md` < 500.
- [ ] **Step 7: Commit** `fix(dev-workflow): serialize ledger writes under the OS lock command; drop mutex reaping`.

---

### Task 3: Stop a cancelled partner (item 3)

Root cause, verified: a partner is an interactive background session. On `CANCEL #n` ("commit nothing more and stop", `partner-brief.md:86`) it ends its turn and idles, keeping its `pid`, and `state: done` with a pid is alive (`SKILL.md:61-62`). So the failure path's "Relaunch … only once a Read shows that session ended" (`SKILL.md:337`) and the drop/cancel-ticket CANCEL clean-up never complete.

**Files:**
- Modify: `dev-workflow/skills/coordinating-partner-sessions/SKILL.md` (Conventions `:53-88`: new procedure; Hard rules `:40-51`; Failure path `:333-356`: Relaunch, Drop, Cancel the ticket)
- Modify: `dev-workflow/skills/coordinating-partner-sessions/partner-brief.md` (`:86`)
- Modify: `dev-workflow/skills/coordinating-partner-sessions/ledger.md` (Rules → Outbox, one line)
- Modify: `dev-workflow/tests/run.sh` (pins)
- Modify: `docs/superpowers/plans/2026-10-12-partner-sessions.md` Task 12 live trial (three cases)

**Interfaces:**
- Consumes: `ledger.sh event <n> json done nopid` (drops the recorded session's CANCEL; unchanged); `intent relaunch … <agents.json>` (priorPid; unchanged).
- Produces (SKILL procedure) **Stop a session `<row>`**:
  1. Deliver `CANCEL #n` (existing Deliver) with `notify_when_idle`. Keep a "stop pending" working note per row, recording the row's `sessionId` and `startedAt` (agents rows carry `id`, `sessionId`, `name`, `pid`, `state`, `startedAt`; fixture `dev-workflow/tests/fixtures/partner-sessions/agents.json`).
  2. On the idle notice, or after a background `sleep 300` with no notice: act only if the note is still open AND the row still matches (same `sessionId` and `startedAt`); otherwise ignore the timer. Then `claude stop <id>`, where `<id>` is the agents row's `id` matched by recorded sessionId, else by name.
  3. Read agents up to 6 times, 5 s apart. When the row has no `pid`: `ledger.sh event "$L" <n> json done nopid`, and close the note.
  4. Still alive after the sixth read: tell the user the session's name and id, and do not loop.
  - **Ambiguity:** if more than one alive row matches, or a matching row's `sessionId` is not in the issue's `sessions[]`, list the rows to the user and ask before stopping. Never `claude stop` by name when the match is ambiguous. This reconciles "stop every alive session in the issue's session history" with "never stop a session it did not launch".
  - **Resume:** a reconcile `resend <n> <to> CANCEL #n` line runs Stop a session, not a plain Deliver. Handback (`ledger.sh done` path) first lists any outstanding CANCEL to the user, which gives the "still alive after 6 reads" path a defined follow-up.
- Stop triggers: drop, cancel-ticket, relaunch, and `stuck-accept` (`blocked-on`; `SKILL.md:365`, the user agrees to the edge, the issue's session is CANCELled and its slot freed). Record `json done nopid` while the issue is still `blocked-on`: `ledger.jq:267-270` drops the CANCEL when `blocked($st)` (`startswith("blocked-on #")`, `:24`).
- Cancel the ticket ordering: step 10's `ledger.sh unlock` (`SKILL.md:304`; the Cancel the ticket text at `:354-356` says "then step 10") runs only after every Stop a session has completed. Otherwise the `json done nopid` writes exit 40.
- No script change.

- [ ] **Step 1: Write the failing pins** in run.sh (they fail until the text exists): `claude stop <id>`, `stop every alive session in the issue's session history`, `never stop a session it did not launch`, `end your turn; the coordinator will stop this session`, `sleep 300`, and the do-not-loop sentence (Review Focus 1; one fixed phrase in SKILL, e.g. `do not loop`). `run.sh` uses `grep -qF`, so each pin must match the text case exactly.
- [ ] **Step 2: Run, expect FAIL**: `/bin/bash dev-workflow/tests/run.sh` → FAIL naming the missing pins.
- [ ] **Step 3: Write the text.**
  - Conventions: the **Stop a session** procedure above.
  - Hard rules: "Never stop a session it did not launch; stop one only after the user's drop, cancel, relaunch or stuck-accept decision."
  - Failure path, Relaunch: "First stop every alive session in the issue's session history (rows matched by any `sessions[].sessionId`, or by the recorded name). Then `intent relaunch … "$W/agents.json"` records `priorPid` null. Rebind after the relaunch as usual (a copy with a new sessionId is possible, ruling T1-C3); the live trial records which happens after `claude stop`."
  - Drop, Cancel the ticket and `stuck-accept`: after the `ledger.sh` call, run Stop a session for each issue whose recorded or open-intent session is alive; for the ticket, run `unlock` (step 10) only after all of them complete.
  - partner-brief.md `:86`: "`CANCEL #n`: reply nothing, commit nothing, end your turn; the coordinator will stop this session."
  - ledger.md Outbox: "A `CANCEL` is cleared by `json done nopid` once SKILL's Stop a session has ended the session."
  - Prior plan Task 12 live trial: add `claude stop` on an idle partner → its row loses its pid; record whether `claude --resume <sessionId> --bg --name` after a stop keeps the sessionId or starts a copy; stopping a busy (mid-turn) partner leaves its worktree usable.
- [ ] **Step 4: Run, expect PASS**: run.sh → `PASSED`; `wc -l SKILL.md` < 500; `grep -rnw ces dev-workflow/skills/coordinating-partner-sessions` → no output.
- [ ] **Step 5: Commit** `fix(dev-workflow): coordinator stops cancelled partners with claude stop`.

---

### Task 4: Sync the spec

The user chose **(a) update the spec** on 2026-10-13, so this task runs.

**Files:** Modify `docs/superpowers/specs/2026-10-12-partner-sessions-design.md`.

- [ ] **Step 1:** Update exactly these spec topics to match the code:
  - outbox clearing — only `DONE` or `FAILED` acknowledges `REWORK`/`RESYNC` (CX4/FX-a), plus Task 1's invariant and the stale-`CANCEL` purge on relaunch;
  - the multi-CANCEL rule — an ADDITION (the spec has no single-CANCEL wording to amend): CANCELs to different sessions of one issue coexist (CX3);
  - the write lock — a kernel lock on `write.lock` via `lockf`/`flock` on the writer's own fd for every mutating call, exit 41 (Task 2), replacing the single-writer `mkdir`/takeover wording;
  - relaunch evidence — `priorPid` (CX2) and "stop every alive session first" (Task 3);
  - the stop procedure (Task 3), including the `stuck-accept` stop;
  - the lock-tool requirement (`/usr/bin/lockf` or util-linux `flock`) under the spec's "Platform facts relied on" and "Preflight" sections (the spec has no "Global Constraints").
- [ ] **Step 2:** Add one sentence to the spec's dependency/frontier section (user decision, 2026-10-13): an issue blocked by an open issue outside the ticket is not launched until that issue is closed. Blockers outside the ticket are recorded in `init` as `{n, closed}`.
- [ ] **Step 3:** `bash scripts/scrub-check.sh --check-overbroad --allow scripts/scrub-allow.txt .` → exit 0; `/bin/bash dev-workflow/tests/run.sh` → `PASSED`.
- [ ] **Step 4: Commit** `docs(dev-workflow): sync partner-session spec with hardened ledger and lifecycle`.

---

## Execution

| Task | Lane | Why |
|---|---|---|
| 1 | claude-implementer-sonnet | bounded jq change with exact tests |
| 2 | claude-implementer-opus (escalated) | concurrency, fd-lock and process-lifetime correctness |
| 3 | claude-implementer-sonnet | prose plus pins |
| 4 | claude-implementer-sonnet | spec prose, conditional |

Order 1 → 2 → 3 → 4, sequential (shared `ledger.md`, `run.sh`). Per-task review as before, then a whole-branch full chain before any PR: `dev-workflow:fresh-verifier` plus an adversarial pass on the Opus lane (the Codex cap of 3 per PR is used).

Rejected: Option B (mkdir + lstart + reap lock) narrows the race but does not close it; the fd lock closes it more simply.

## Self-review

- **Spec coverage:** items 1–4 each map to a task (1 → T1, 2 and 4 → T2, 3 → T3); the conditional spec sync is T4; the M2 edge is closed by T3's stop-all-before-relaunch.
- **Step scan:** every code step names the file, function or helper, and exact values (`PS_WRITE_WAIT` default 10 whole seconds, exit 41, lockf 75 → 41, flock rc 1 → 41, `sleep 300`, 6 reads × 5 s); the only body given is `take_write_lock`, whose tool choice and exit mapping are the decision.
- **Type consistency:** `outbox_purge_work($k)`, `assert_outbox_invariant`, `write.lock`, `take_write_lock`, `PS_LOCKF`, `PS_WRITE_WAIT`, `busy=` used identically across tasks.
- **Review Focus:** each of the six lines has its test or pin in the owning task.
- **Proportion:** the plan is shorter than the code it changes; no script bodies beyond `take_write_lock`.
- **Review fixes (2026-10-13):** the fd lock replaces the re-exec (kill of the lock tool no longer frees the lock); rulings CX1/T5-M2(a) are superseded, stated in Task 2; stale `CANCEL` purge on relaunch (Task 1); Task 3 stop guards (timer note, ambiguity, unlock ordering, resume); Task 4 names the spec's real sections.
