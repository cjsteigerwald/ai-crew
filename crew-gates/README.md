# crew-gates

PreToolUse gates that make an orchestrator delegate to cheaper lanes instead of doing
everything itself, plus a UserPromptSubmit hook that keeps the routing policy in front
of the model every turn. All four hooks fail open: a broken gate must never brick a
session. The two PreToolUse edit/read gates (`delegation-gate.py`, `read-budget-gate.py`)
never fire inside a subagent, while `lane-model-gate.py` and `routing-table.py` apply to
the main session's Agent dispatches and prompts.

## Hooks

| Hook | Fires on | What it does |
|---|---|---|
| `delegation-gate.py` | PreToolUse, `Edit\|Write\|NotebookEdit` | Blocks an edit/write until the transcript carries a classification token since the last genuine user message. |
| `read-budget-gate.py` | PreToolUse, `Read\|Grep\|Glob\|Bash` | Caps inline bulk reading in the main session (call count + byte total) since the last genuine user message. |
| `lane-model-gate.py` | PreToolUse, `Agent\|Task` | Denies dispatching the frontier-tier model to any lane except the configured verifier lane, and denies `model: opus` without an `escalate:` reason. |
| `routing-table.py` | UserPromptSubmit | Injects a compact routing table (lane names, disqualifiers, evidence rules) into context every turn, so the policy doesn't rely on a large doc the model has to remember to read. |

### Classification tokens (`delegation-gate.py`)

After every genuine user message, before the first edit, the transcript must carry one
of:

- `dispatching <lane>` — work was routed to a subagent lane. Must be line-initial or
  arrow-preceded and name an actual lane (`dispatching my-scout-lane`,
  `mechanical -> dispatching my-writer-lane`). Passing mentions of the word do not count.
- `solo: D<n>` — kept inline, citing exactly one disqualifier:
  - **D1** single file, under ~40 changed lines
  - **D2** files share mutable state or a contract changing in this task
  - **D3** needs live cloud reads (kubectl/az/aws/gcloud/terraform) interleaved with edits
  - **D4** needs a user decision mid-task

Also accepted: a Bash tool call whose command is exactly `:` and whose `description` is
the token, run on its own with a non-error result, edit made in a later step. This
recovers sessions where mid-turn assistant text is not persisted at hook time.

### Read budget (`read-budget-gate.py`)

Default budget: 3 counted read calls or ~20 KB of read output since the last genuine
user message. A `solo: D<n>` classification in the window raises the tier to 10 calls /
80 KB — `dispatching` does not, because the lane does the reading, not the orchestrator.
Exempt from the call count: small-output reads, memory files, files under 4 KB, and
re-reads of files just edited successfully in the window (bytes still count). Never
gated: `git diff`/`git status`/summary-only `git log`, and live cloud CLIs
(kubectl/az/aws/gcloud/terraform — by policy they stay in the main loop).

### Model tier (`lane-model-gate.py`)

No lane may run on the frontier-tier model alias except the configured verifier lane
(default `fresh-verifier`); `model: opus` requires an `escalate: <reason>` first line in
the dispatch prompt so the escalation is visible in the transcript.

## Crew config

`routing-table.py` and `lane-model-gate.py` read lane names from
`${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/data/crew/config.json`, key `lanes` — an object
with any of these keys: `scout`, `reader`, `implementer_haiku`, `implementer_sonnet`,
`implementer_opus`, `writer`, `verifier`, `adversary`. Any key that is absent, or whose
value isn't a non-empty string, falls back to its default. A missing or malformed
config file falls back to all defaults; the gates never crash on it.

Lane names may be plugin-qualified (`<plugin>:<name>`, e.g. `dev-workflow:fresh-verifier`)
— a verifier that itself ships inside a plugin arrives at `lane-model-gate.py` with that
prefix. If `lanes.verifier` is set qualified, only that exact `<plugin>:<name>` string is
exempt (not the bare name, not a different plugin's copy); if it's left unqualified
(the default `fresh-verifier`), both the bare name and any `<plugin>:fresh-verifier` are
exempt — but never as a substring: `other:fresh-verifier-x` does NOT match
`fresh-verifier`.

Defaults:

```json
{
  "scout": "claude-crew:claude-scout",
  "reader": "claude-crew:claude-reader",
  "implementer_haiku": "claude-crew:claude-implementer-haiku",
  "implementer_sonnet": "claude-crew:claude-implementer-sonnet",
  "implementer_opus": "claude-crew:claude-implementer-opus",
  "writer": "code-writer",
  "verifier": "fresh-verifier",
  "adversary": "codex-adversary"
}
```

## Off switches

Each gate can be disabled independently, per session:

- `CLAUDE_DELEGATION_GATE=off`
- `CLAUDE_READ_BUDGET=off`
- `CLAUDE_LANE_MODEL_GATE=off`

## Install

Enable the plugin and let `ai-crew-update` reconcile settings.json — it merges
`settings.fragment.json` (currently just the `CLAUDE_CODE_SUBAGENT_MODEL` env default)
and removes any legacy hook entries so hooks stay resolved from this plugin's
`hooks/hooks.json` rather than a version-pinned path.

### Manual install

1. Enable the plugin — hooks load from `hooks/hooks.json` automatically once the
   plugin is active; you do not need to add PreToolUse/UserPromptSubmit entries by hand.
2. Add the env default from `settings.fragment.json` to your `settings.json`:

   ```json
   {
     "env": { "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet" }
   }
   ```

3. If your `settings.json` has older, absolute-path hook entries pointing directly at
   `<plugin-root>/hooks/*.py` (from before hooks.json-based loading), remove them —
   run `"${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh" reconcile --dry-run`
   first to preview, then the same without `--dry-run` to apply. Version-keyed install
   paths written into settings.json go stale on update, since the harness sweeps old
   version directories; `hooks.json` is resolved per session by the harness instead.
4. Run `/reload-plugins` to pick up the hooks, or open a new session. The `env` change needs a full restart.

The off-switch env vars above still work regardless of install method.
