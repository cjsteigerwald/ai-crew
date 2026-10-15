# Recipes

Command recipes for [SKILL.md](../SKILL.md). Variables: `PT` is `piece-track.sh`, `FF` is
`ff-merge.sh`, `OS` is this skill's directory, `W` is a scratch directory from `mktemp -d`
(made once), `REPO` is `owner/repo`, `ORCH` is the orchestrator's branch, `KEY` is the ticket
key, `OWN_SESSION` is this session's name, `DEPTH` is this orchestrator's depth (0 at top level),
`DEPTH_CAP` and `LIVE_CAP` are 2 and 3 unless the handoff names others, `TEST_CMD` is the
ticket's test command, `ISSUES` is the piece set (space-separated issue numbers) and `PREFIX` is
the name prefix (Launch). Set them at the top of
every Bash call; each call is a fresh shell. Every value that came from GitHub or a message is
passed as an argument or a file, never pasted into a command line.

## Snapshot

`ISSUES` is the piece set (space-separated issue numbers). Write the result to `$W/snapshot.json`.

```bash
rm -f "$W/snapshot.json"; : >"$W/deps.jsonl"
for n in $ISSUES; do
  raw="$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by" --paginate)" \
    || { echo "snapshot: gh failed for #$n" >&2; exit 1; }
  printf '%s' "$raw" | jq -sc --argjson n "$n" \
    'if length >= 1 and all(.[]; type == "array")
     then {issue: $n, deps: (add // [] | map({number, state}))} else error("not an array") end' \
    >>"$W/deps.jsonl" || { echo "snapshot: bad response for #$n" >&2; exit 1; }
done
jq -s '[.[].issue] as $set
  | {pieces: [.[] | {issue, blocked_by: [.deps[].number]}],
     external: ([.[].deps[] | select(.number as $x | $set | index($x) | not)
                 | {key: (.number | tostring), value: .state}] | unique_by(.key) | from_entries)}' \
  "$W/deps.jsonl" >"$W/snapshot.json" || { rm -f "$W/snapshot.json"; echo "snapshot: build failed" >&2; exit 1; }
```

Any failure aborts the whole snapshot (no `snapshot.json` is left): run neither `register` nor
`reconcile`; tell the user which issue failed. A blocker outside the set lands in `external`
with its GitHub state, `open` or `closed`.
Then `bash "$PT" register "$W/snapshot.json" --depth "$DEPTH"` (nested: the CHILD_DEPTH from your handoff).

## Launch

Per issue `N` from `bash "$PT" launchable`. `PREFIX` is `<KEY>-` (top level) or `<own session
name>.` (nested); `AGENT="$PREFIX$N"`; `PB="$ORCH-$N"`;
`WT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.claude/worktrees/$AGENT"`.

1. **Branch and worktree off the observed head.**
   ```bash
   BASE="$(git rev-parse "$ORCH")"
   git worktree add -b "$PB" "$WT" "$BASE"
   ```
   A branch or worktree that already exists is a stop: ask the user.
2. **Values.** `ACS` is the issue's `## Acceptance criteria` section verbatim (the whole body when
   it has none). `TEST_CMD` is the ticket's test command from its requirements doc. Blocker
   evidence is one line per blocker: `#M merged at <sha>` (the sha is `.pieces["M"].sha` in the
   tracking file) or `#M closed outside this set`.
   ```bash
   : >"$W/ev-$N.txt"   # then append one evidence line per blocker (empty when none)
   gh issue view "$N" -R "$REPO" --json body,url >"$W/issue-$N.json"
   jq -r '.body' "$W/issue-$N.json" >"$W/ac-$N.md"   # cut to the AC section
   jq -n --arg key "$KEY" --arg n "$N" --rawfile ac "$W/ac-$N.md" --arg url "$(jq -r .url "$W/issue-$N.json")" \
     --arg test "$TEST_CMD" --arg pb "$PB" --arg wt "$WT" --arg base "$ORCH" --arg orch "$OWN_SESSION" \
     --arg depth "$((DEPTH + 1))" --arg dcap "$DEPTH_CAP" --arg lcap "$LIVE_CAP" --rawfile ev "$W/ev-$N.txt" \
     '{TICKET_KEY: $key, ISSUE_NUMBER: $n, ISSUE_URL: $url, ACCEPTANCE_CRITERIA: $ac, TEST_COMMAND: $test,
       PIECE_BRANCH: $pb, WORKTREE: $wt, BASE_BRANCH: $base, ORCHESTRATOR_SESSION: $orch,
       CHILD_DEPTH: $depth, DEPTH_CAP: $dcap, LIVE_CAP: $lcap, BLOCKER_EVIDENCE: $ev}' >"$W/values-$N.json"
   bash "$OS/scripts/render-handoff.sh" "$OS/references/handoff-prompt.md" "$W/values-$N.json" >"$W/handoff-$N.md"
   ```
   `DEPTH_CAP` and `LIVE_CAP` are 2 and 3 unless the handoff names others. A non-zero exit blocks
   this launch: remove the worktree and branch you just made, then fix the value or tell the user.
3. **Start.** `cd "$WT" && claude --bg --name "$AGENT" --permission-mode <this session's mode>
   "$(cat "$W/handoff-$N.md")"`. A failed command: tell the user; record nothing.
4. **Record.** Find the new session, take its `sessionId`, then `launch`:
   ```bash
   SESSION_ID="$(claude agents --json | jq -r --arg n "$AGENT" \
     '[.[] | select(.name == $n and .pid != null)] | sort_by(.startedAt) | last | .sessionId // empty')"
   [ -n "$SESSION_ID" ] || { echo "no live session named $AGENT" >&2; exit 1; }
   bash "$PT" launch "$N" "$AGENT" "$SESSION_ID" "$PB" "$BASE"
   ```
   An empty `SESSION_ID` after a second read: tell the user and record nothing (a later
   `reconcile` lists the session as `unknown-session`).
   Then `SendMessage` to `$AGENT` with `notify_when_idle: true` and no message, for the idle notice.

**Relaunch** (a `failed` piece): first read `claude agents --json` again. If the old recorded
session (by its sessionId) still has a `pid`, tell the user and do not relaunch. Otherwise reuse
its branch and worktree (`git worktree add "$WT" "$PB"` if the worktree is gone), take `BASE`
from `.pieces["N"].base` in the tracking file, render a new handoff as above, start the
session, and run `PT launch` again with the new session id. `launch` accepts a failed piece and
is refused at either cap. A failed piece with no `base` (a legacy record) cannot be relaunched
from the file: drop it, or ask the user for the fork-point sha.

## Idle check

An idle notice is not an ending: a live piece agent idles while it waits on the user. Read the
recorded session's row (`SESSION_ID` is `.pieces["N"].session` in the tracking file):

```bash
claude agents --json | jq -r --arg s "$SESSION_ID" '[.[] | select(.sessionId == $s)] | first | .pid // "gone"'
```

A pid prints: the piece stays running or stuck; take no action (at most `STATUS? #N`). `gone`
(no pid, or no row): `bash "$PT" failed "$N"`.

## Record

A report arrives as `<cross-session-message from="<name>">LINE</cross-session-message>`. Check
`<name>` equals `.pieces["N"].agent` in the file `bash "$PT" path` prints. Write LINE (the text
between the tags, one line) to `$W/report.txt` with the Write tool, then:

```bash
bash "$PT" record "$(cat "$W/report.txt")"
```

The substitution's output is passed as one argument and is never re-parsed.

## Merge

The `done` pieces: `jq -r '.pieces | to_entries[] | select(.value.state == "done") | "\(.key) \(.value.branch) \(.value.sha)"' "$(bash "$PT" path)"`.
For one of them (`N`, `PB`, `SHA`), from the orchestrator worktree:

```bash
bash "$FF" --check "$ORCH" "$SHA"          # 0: head is an ancestor of SHA; 10: SHA does not descend from the current head=<h>
PIN="$(git rev-parse "$ORCH")"
bash "$FF" "$ORCH" "$SHA" "$PIN"           # 0: merged; 10: head moved, prints head=<h>; 3: wrong cwd or dirty
```

Exit 10 from either call: `SendMessage` `RESYNC #N <h>` to the piece's agent. Exit 0 from the
second: `bash "$PT" merged "$N"`.

## Reconcile

```bash
claude agents --json --all >"$W/sessions.json"
# $W/snapshot.json: the Snapshot recipe (it must have succeeded). Tips: one entry per piece
# in the snapshot or in the file whose branch exists.
TF="$(bash "$PT" path)"
KEPT=""; [ -f "$TF" ] && KEPT="$(jq -r '.pieces | keys[]' "$TF")"
ALL="$(printf '%s\n' $ISSUES $KEPT | sort -un)"
for n in $ALL; do
  pb="$(jq -r --arg n "$n" '.pieces[$n].branch // empty' "$TF" 2>/dev/null)"
  [ -n "$pb" ] || pb="$ORCH-$n"
  tip="$(git rev-parse --verify -q "refs/heads/$pb")" || continue
  base="$(jq -r --arg n "$n" '.pieces[$n].base // empty' "$TF" 2>/dev/null)"
  git merge-base --is-ancestor "$tip" "$ORCH" && c=true || c=false
  if [ -n "$base" ] && git merge-base --is-ancestor "$base" "$tip"; then a=true; else a=false; fi
  jq -n --arg n "$n" --arg b "$pb" --arg t "$tip" --argjson c "$c" --argjson a "$a" \
    '{($n): {branch: $b, tip: $t, contained: $c, advanced: $a}}'
done | jq -s 'add // {}' >"$W/tips.json"
bash "$PT" reconcile --sessions "$W/sessions.json" --snapshot "$W/snapshot.json" \
  --tips "$W/tips.json" --name-prefix "$PREFIX" --depth "$DEPTH"
```

`contained` is `git merge-base --is-ancestor <tip> <orchestrator head>`; `advanced` is
`git merge-base --is-ancestor <base> <tip>`. The loop uses a piece's recorded branch from the
file, else `$ORCH-$n`; a missing file adds no noise. A live row has a `pid`; the rows `--all` adds for ended
sessions have none.
