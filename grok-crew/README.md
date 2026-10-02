# Grok Crew

Version **0.2.0** supplies a delegation skill for **Claude Code and Codex**. It
launches the installed Grok CLI for reviews, investigations and authorized edits,
collects its output, and resumes known sessions. No custom broker or official
Claude bridge is required. Read [the skill](skills/grok-crew-runtime/SKILL.md).

The host needs shell execution, an installed/authenticated `grok`, and a
background/yielding command runner. The recipes below use Bash, and must also
run under macOS's stock `/bin/bash` 3.2. GNU `timeout` is optional, needed only
when a justified total runtime limit exists; stock macOS does not ship it, so
use `gtimeout` from Homebrew `coreutils` there (see [timeouts on macOS](#timeouts-on-macos)).
A manifest makes the skill package loadable; it does not install the CLI,
authenticate it or automatically install in Codex. Claude users can install
`grok-crew@cjs-plugins` from this marketplace. In Codex, load this package
through the configured plugin mechanism, or read the skill's source when native
discovery is unavailable. This plugin is vendored from
[`sidkik/claude-plugins`](https://github.com/sidkik/claude-plugins); see
[UPSTREAM.md](UPSTREAM.md).

## Launch recipes

The accountable agent fills these values from the task and writes the actual
brief, rather than asking the user to assemble shell commands. `grok_prompt` is an
existing absolute prompt-file path; `grok_run` is an existing private session
scratch directory; `grok_checkout` is the chosen absolute checkout. Generate a
fresh UUID using the host's UUID facility and retain it as `grok_session`.

Read-only review or investigation, submitted through the host's background/yielding
command facility with a bounded initial yield and a retained job handle:

```bash
if grok \
  --cwd "$grok_checkout" --session-id "$grok_session" \
  --prompt-file "$grok_prompt" --no-subagents \
  --permission-mode plan --sandbox read-only --output-format plain \
  >"$grok_run/stdout.log" 2>"$grok_run/stderr.log"; then
  grok_exit=0
else
  grok_exit=$?
fi
printf '%s\n' "$grok_exit" >"$grok_run/exit-code"
```

A **poll timeout** bounds how long the host waits before yielding control; it does
not terminate Grok. Use short host waits (for example 10 seconds) and an active
supervision cadence that keeps the user informed. Do not run this as an unbounded
blocking foreground call. If the host cannot return a background handle, establish
that capability before launch.

A **job deadline** kills work. Add `timeout --kill-after=10s "$grok_budget"`
before `grok` only when an existing explicit task budget or a concrete documented
resource constraint supplies that limit. Retain its source and remaining budget;
there is no default total runtime limit. A healthy review taking longer than a
poll interval is not a reason to kill it. Preserve explicit user budgets without
automatic extension; report the affected work when one expires. Exit 124 from
GNU timeout means interrupted work, not a completed review.

### Timeouts on macOS

Stock macOS has no `timeout`. Resolve the command once and use it in place of
`timeout` in the recipes above and in the skill's readiness probe:

```bash
grok_timeout="$(command -v timeout || command -v gtimeout || true)"
```

`gtimeout` comes from `brew install coreutils` and takes the same arguments,
including `--kill-after`. When `grok_timeout` is empty, skip the optional soft
probe, and if a job deadline is required, report that the deadline cannot be
enforced on this host instead of launching without it.

For authorized implementation or [reviewer-owned regression proof](skills/grok-crew-runtime/SKILL.md#reviewer-owned-regression-proof)
in a separate checkout pinned to the reviewed candidate, use the same invocation with
`--permission-mode acceptEdits --sandbox workspace`. Carry exact allowed files and
commands in the brief; permit necessary shell commands using narrowly scoped
`--allow` rules supported by the installed CLI, for example
`--allow 'Bash(node --test grok-crew/tests/example.test.mjs)'` for that actual test.
Do not use blanket auto-approval to work around a denial. If a command still needs
interactive approval, report the exact blocked operation and apply the host's
normal authorization handling. The workspace profile allows writes within its
checkout plus Grok state/temp; a prompt's path list is an instruction, not an OS
security boundary.

To continue, write the next brief and use `--resume "$grok_session"` **instead of**
`--session-id "$grok_session"`. Preserve the chosen permission/sandbox flags and
use new output files so the previous result remains available. Do not overlap runs
for the same session. The headless CLI invocation does not itself provide a steer
channel; interruption requires stopping and checking the owned job before resume.


## Check progress in the exact session

Quiet `--output-format plain` stdout is expected while work runs. At each
supervision check, inspect the host handle, stderr and the exact session's recent
events plus tool calls/results. Compare these with the pinned task's outstanding
milestones: for example, which named claims have acquired source evidence and
which review obligations remain. A PID, fresh timestamp, phase changes or reasoning
activity establish liveness only; they prove neither productive progress nor
completion. Repeated errors, an unanswered permission request and an outstanding
tool each need their own diagnosis. Let useful work continue within actual limits.

Installed Grok 1.0.34 was observed on 2026-09-28 to store sessions under
`~/.grok/sessions/<percent-encoded-checkout>/<UUID>/`, including `events.jsonl`
and `chat_history.jsonl`. Resolve the directory for the recorded UUID and confirm
its `turn_started.session_id` before inspection; do not select a directory's most
recent session. Recheck the schema if the version or storage configuration changes.
With `grok_session_dir` set to that verified directory, these bounded reads show
recent evidence without dumping reasoning or encrypted content:

```bash
tail -n 400 "$grok_session_dir/events.jsonl" | jq -c '
  select(.type == "turn_started" or .type == "turn_ended" or
         .type == "tool_started" or .type == "tool_completed" or
         .type == "permission_requested" or .type == "permission_resolved") |
  {ts,type,session_id,tool_name,tool_call_id,outcome,decision,wait_ms}'
tail -n 40 "$grok_session_dir/chat_history.jsonl" | jq -c '
  def preview:
    if type == "string" then
      {text: .[0:600], truncated: (length > 600)}
    else {schema: type, inspect_required: true} end;
  if .type == "assistant" then
    {type, content: (.content | preview),
     tool_calls: [.tool_calls[]? |
       {id,name,arguments: (.arguments | preview)}]}
  elif .type == "tool_result" then
    {type,tool_call_id,content: (.content | preview)}
  else empty end'
```

Content and argument previews are capped at 600 characters with explicit
truncation markers; IDs and tool names stay intact. Retrieve the exact relevant
record when a preview cannot establish what happened.

These are bounded windows, not a complete history or an automatic progress
verdict. If they contain only phase noise, a result without its call, or no relevant
change, inspect the missing task-specific range before diagnosing a stall. A
partially written JSONL record is incomplete observation: reread after the next
poll rather than claiming a runtime failure. Use equivalent bounded file reads
if `jq` is unavailable.

In this version chat records use top-level `type`, not `role`. An assistant's
`tool_calls` entries contain `id`, `name` and `arguments` (a JSON string); results
use `type: "tool_result"`, `tool_call_id` and `content`. Correlate those exact IDs.
Events use `ts` and `type`; `tool_completed` carries `tool_call_id` and `outcome`
(such as `success`). Observed `tool_started` and permission events lack call IDs;
never pair concurrent operations by position or tool name alone. An unresolved
request in a tail may have its resolution outside the window: inspect that range
before declaring permission pending. Read the actual call/result to distinguish
useful evidence gathering from repeated failures or irrelevant work.

A completed turn and final report still require the host's exit status and
independent result verification. After interruption, resume restores conversation;
it does not guarantee that an interrupted tool's result was captured. Inspect
retained calls/results and partial file changes before deciding what to repeat.

## Verified interface and limits

The launch flags were checked against installed **Grok 1.0.34** help on
2026-09-27. Recheck local help before relying on a different version. Public
[headless documentation](https://docs.x.ai/build/cli/headless-scripting) describes
the supported scripting route. Its session-ID summary differs from this installed
version: local help requires a fresh UUID for `--session-id`, and `--resume` for an
existing conversation. The examples follow that verified local contract.

[Permissions](https://docs.x.ai/build/features/permissions) govern tool approval;
[the sandbox](https://docs.x.ai/build/features/sandbox) limits filesystem/network
access separately. Read-only is not a promise that nothing anywhere is written:
Grok session state and temporary files remain writable. Managed settings can
constrain these flags. A launch must report actual runtime failures accurately.

The optional [official Claude bridge](https://github.com/xai-org/grok-build-plugin-cc)
also shells out to Grok and adds its own job management. Its
[launch source](https://github.com/xai-org/grok-build-plugin-cc/blob/main/plugins/grok-build/scripts/lib/grok.mjs)
confirms that a bridge is not required for direct CLI delegation. Grok's TUI and
native child-agent messaging are separate channels; this plugin claims no runtime
steering, approval enforcement or authenticated verification of agent reports.

Use [behavioral trials](tests/behavioral-prompts.md) for fresh host-session checks.
They are evaluation inputs, not a claim that every host integration has passed.
