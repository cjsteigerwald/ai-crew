---
name: grok-crew-runtime
description: Delegate review, investigation or implementation from Claude Code or Codex to the Grok CLI; launch bounded work, collect results, resume a known session or stop owned work.
---

# Delegate to Grok

When the user asks to send work to Grok, perform that delegation using the host's
shell tool. Reuse existing scope and authorization; the user need not install a
bridge, construct a prompt or repeat permission already given. This skill works
from Claude Code and Codex. It uses the installed `grok` CLI directly; an official
Claude bridge is optional. It is not a new workflow engine or a `crew-grok` binary.

## Launch and return

1. Read the governing repository instructions and applicable orchestration skills.
   Establish the bounded task, owning checkout, permitted paths/actions and return
   criteria. For review, pin the base and candidate. For implementation, use an
   isolated checkout when concurrent edits would collide. Carry the actual skill
   paths and instruction precedence into the brief. Completion: Grok can act from
   that self-contained brief without guessing the parent's conversation.
2. Check `grok --version` and `grok --help` with a short timeout. Use the existing
   authenticated CLI; if readiness is unknown, `timeout 30s grok models` is a soft
   probe, not proof a model turn will succeed. On macOS use `gtimeout` instead,
   or skip this optional probe when neither exists ([timeouts on macOS](../../README.md#timeouts-on-macos)). Select a model only when requested
   or required by the governing instructions. If the binary, authentication or
   permission capability is unavailable, report that specific gap and preserve the
   brief. Do not launch installation or change global settings as a substitute.
3. Write the brief to a prompt file in the host session's existing scratch area.
   Include outcome, sources, allowed edits, skill reads, tests and required report
   (findings or changed paths, evidence, unresolved blockers). Keep durable work in
   its owning repository/issue; scratch prompts and logs need no repository commit.
   Set a new UUID for a new conversation, an absolute checkout and separate stdout
   and stderr paths. Use the [launch recipes](../../README.md#launch-recipes),
   choosing read-only inspection or the authorized isolated-test/implementation
   permissions described below.
   Completion: a real Grok process has been launched with a recorded session ID,
   host job handle, scope, bounded poll interval, output paths and any justified
   job deadline with its source; a command proposal is not a run.
4. Supervise through the host's background/yielding handle with short bounded
   polls, continuing independent work and user updates. A poll timeout yields
   control; it does not kill the job. Use a total-runtime kill limit only from an
   existing explicit task budget or concrete documented resource constraint;
   preserve it without automatic extension. Follow [exact-session progress
   inspection](../../README.md#check-progress-in-the-exact-session): compare recent
   tool calls/results with the pinned task's outstanding milestones. Quiet plain
   stdout, elapsed time, a PID or fresh reasoning/phase events do not establish a
   stall or productive progress. Distinguish pending permission, an outstanding
   tool and repeated errors; investigate the actual gap before intervention.
   Completion: process exit, status and actual final output are collected, or the
   precise interruption/blocker and partial work are accounted for. A deadline
   expiry is interrupted work, never a successful review.
5. Read stdout and stderr and inspect the reported artifacts. Exit zero alone is
   not success. Independently verify material findings, diffs and applicable tests
   under the repository's review contract. Report the consolidated result to the
   user with the Grok session ID and remaining gaps. Do not claim a model's own
   success report proves completion.

## Reviewer-owned regression proof

Carry the complete governing review checklist and human scope into the brief;
coordinator assumptions are claims to test. Preserve substantive new findings
and applicable standards when a re-review is bounded to a correction.

For a governing code review permitting regression proof, select the isolated
workspace/acceptEdits mode at dispatch, with allowed test paths and commands.
Grok writes and runs the smallest focused regression needed for a behavioral
concern in that separate clean checkout at the pinned candidate. For WIP, pin
the base plus exact patch identity and apply that patch to the isolated checkout.
The primary prepares isolation and verifies the return; it does not write the
reviewer’s proof. Name allowed test/fixture files and authorized commands. Keep
production code unchanged; exclude shared worktree writes and live environment
changes. Use the README’s workspace/acceptEdits recipe for this authorized test
mode. Those settings permit workspace writes, not a test-only OS boundary: the
file fence remains an instruction. Explicit human read-only/no-execution limits
win; retain unverified concerns and explain the precise capability gap instead
of bypassing the restriction.

Return each finding as a proven behavioral defect (candidate revision, proof
patch/path, exact command, expected behavior and observed assertion failure), a
static finding (source and violated criterion), or an unverified behavioral
concern (missing evidence/capability). Build/setup failures are not reproductions.
Duplication and other inspectable static violations need no artificial red test.
Stop once the test discriminates the claimed bug; retain the proof for the
implementer’s repair and subsequent green verification without applying it to the
delivery branch. Retract or revise a claim contradicted by its reproduction.

## Continue or change direction

Use `--resume UUID` with a new prompt file after the previous process exits. Keep
its checkout and permission scope explicit. `--session-id UUID` creates a new
conversation; it does not resume one. Avoid `--continue` for delegated work because
it selects by directory rather than the job identity. Resume restores conversation;
it does not restore code unless separately requested through Grok's restore tools,
and does not guarantee capture of an interrupted tool result. Inspect actual
calls/results and partial side effects before repeating work.

A direct headless run has no in-flight message-injection command provided by this
skill. Choose one of these actual operations:

- **Queue:** retain a follow-up, wait for exit, then resume that UUID.
- **Interrupt:** stop only the owned host job/process group, verify it stopped and
  inspect partial side effects; then resume with the corrected brief if appropriate.
- **Steer:** requires a separately verified runtime capability. Grok TUI input and
  Grok's native child-agent messaging do not address this Claude/Codex-launched job.

Do not start two prompts against the same session concurrently or kill unrelated
Grok leaders/sessions. If the host cannot establish that owned work stopped, report
that uncertainty before launching a replacement that might duplicate its effects.
