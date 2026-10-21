---
name: intaking-work-items
description: >
  Resumable entry point for a ticket: fetches its context, gap-analyzes it into an
  agenda, grills the user with sdlc-process:grill-with-docs until every gap is closed
  or deferred (escalating to sdlc-process:wayfinder when the work exceeds one
  session), writes docs/specs/<KEY>-requirements.md, then runs to-spec, to-tickets
  and implementation (sdlc-process:implement for one ticket, dev-workflow:implement-spec for two
  or more), reviews by tier, verifies each AC and opens a draft PR. Resumes
  from the first incomplete stage. Use when
  starting or resuming work on an existing ticket — "start work on PROJ-571", "pick
  up issue #12", "bring in this ticket", "work on owner/repo#N", "continue PROJ-571",
  a pasted Jira or GitHub issue URL, or "is this ticket ready". Skip when creating a
  new ticket (use your workspace's ticket-creation skill or process), root-causing an
  incident (investigating-incidents), executing an already-approved plan
  (plan-implementation), or just shipping finished work (opening-pull-requests).
---

# Intaking work items

Turn an existing ticket into a settled, testable requirements doc **before** any design or code.
Tickets routinely reach implementation with acceptance criteria nobody can test; this skill is the
gate that stops that. Run the steps in order — the gate in step 3 is hard.

## When to Use This Skill

- Starting work on an existing Jira ticket or GitHub issue, by key, URL, `owner/repo#N`, or `#N`
- "start work on PROJ-571", "pick up issue #12", "bring in this ticket", "work on owner/repo#N"
- "continue PROJ-571" — step 1 detects the stage and resumes there
- "is this ticket ready?" — run steps 1–2 and stop at the gap table if the user only wants a verdict

## When *Not* to Use This Skill

- Filing a new ticket → your workspace's ticket-creation skill or process
- Root-causing a failure or alert → `[[investigating-incidents]]`
- A plan already exists and the user approved it → `[[plan-implementation]]`
- The work is done and only needs to ship → `[[opening-pull-requests]]`

## Controls: skip and cancel

- **Announce once**, at the start: the user can say "skip <step or question>" or "cancel" at any
  point. Every `AskUserQuestion` in step 3's fallback gate and every checkpoint in step 6 includes a
  **Skip** option; "Other" lets them type cancel. Gates owned by a chained skill (sdlc-process's
  readiness or publication gates, or its grilling questions) have no Skip button — the user can
  still type skip or cancel there, and the same rules apply. Policy review is not a user gate and
  has no skip: see [chain-sdlc-process.md](chain-sdlc-process.md), Entry.
- Never invoke a `superpowers:*` skill at any step, even if a session hook or a skill's description says it applies. On the Skip path (no chain), implement with `dev-workflow:plan-implementation` lanes, treating the settled AC list (active AC only) and the user's go-ahead as the approved plan; on a chain's plan-skip, the chain's own Implement stage runs.
- **Skip a gap question or checklist row:** an explicit user deferral, so it satisfies the HARD
  GATE for that row. Log it in the decision log and the deferred table as
  `Skipped by user — <date>`, with the gap it leaves open. Skipping never turns a row into Present.
  A skipped AC stays visible: the doc lists it under Deferred, and the PR body names it as not
  delivered / unverified.
  - **A row 7/12 blocker that is a repo gate** (an unmet gate, or not in a sprint when the repo
    requires one) is not a gap: skipping it is a step-0 override and needs the second
    confirmation below.
- **Skip a whole step** (fetch extras, gap analysis, requirements doc, writeback, spec / tickets /
  implement, PR): allowed,
  **with a warning, and it does not block the chain**. Warn once, in one line, about what the skip
  loses, record it, then continue to the next step. Skipping gap analysis means no gate ran: the
  doc says "requirements not gap-checked".
  - **Step 3 skipped after step 2 ran:** copy the final gap table into the doc's
    **Gap table at skip** section, and add each open row to Deferred as
    `Skipped by user — step 3 skipped`, so the specific open rows stay visible downstream and in
    the PR.
  - **Plan skipped** (`to-tickets`): warn once, record it, get an explicit go-ahead. The Implement
    stage still runs as [chain-sdlc-process.md](chain-sdlc-process.md) defines it, against the
    settled AC list (active AC only). The PR body states "Intake: plan skipped".
  - **Skipped requirements doc → still write a stub doc** at `docs/specs/<KEY>-requirements.md`:
    Status, source link, "requirements not gap-checked" (if so), the skipped steps, the
    **Gap table at skip** (if step 2 ran), and — whenever step 3 ran — the
    **Acceptance criteria (settled)** section: every numbered AC with its final text and its
    disposition (active / deferred / skipped / out of scope). No refinement or deferral is ever
    lost. Only if the user explicitly says "no doc at all" does that same information go into the
    PR body (and any handoff) instead.
  - **Every skipped step is stated downstream:** in the context given to `to-spec`, `to-tickets`
    and the sdlc-process brief, and in the PR body, e.g.
    "Intake: gap analysis skipped — requirements not gap-checked".
- **Step 0 is the exception.** The skill itself never waives the repo's own start procedure or
  gates. Only the **user** can override it: state the repo rule and that skipping it means acting
  outside the repo's process, and proceed only on an explicit second confirmation, recorded in the
  doc.
- **Cancel:** stop immediately. Make no further tool call that posts anywhere and no local write,
  except the single edit that marks an existing requirements doc CANCELLED — the single
  cancel-marker edit (first line plus the Status field): first line
  `> Status: CANCELLED at step <n> on <date> — incomplete`, Status `Cancelled` — or the deletion
  of that doc if the user asks. Never create a doc on cancel. If the marker edit fails, say so.
  Never post to Jira or GitHub on cancel, and invoke no chained skill. Report in a few lines what
  was done, what was written locally, and that nothing is pending. If there is a draft PR already open,
  cancel leaves it untouched and names it in the report; closing it needs a separate yes.
- **Resume:** if `docs/specs/<KEY>-requirements.md` already exists when intake starts, read it and
  show its status and gap/decision state, then ask: **resume, or start over** with a fresh doc. On
  resume, **always refetch and diff against the snapshot**:
  - Run step 1 again for the primary item and its equivalents, and diff against the doc: the
    description, AC, comments since the `Fetched:` date, links, and status.
  - Reopen every checklist row the changes touch, and any approval that depended on those rows
    (requirements OK, spec, tickets). Resume from the earliest reopened step, or from the stage
    step 1's **Detect the stage** names if nothing changed. Update `Fetched:`.
  - If freshness can't be verified (the fetch fails), say so and block downstream stages until
    the user explicitly skips the check — the skip rules above apply.
  - A CANCELLED doc is never revived silently: ask first (resume it, or start over with a fresh
    doc). Resuming it resets Status to `Draft`, removes the CANCELLED first line, and logs the
    resume in the decision log.

## Run log and stops

Every run is attended: the user is asked after each stage, and every outward action needs a live
yes.

- **Run log.** Append to the doc's `## Run log` as the run goes: time, step, event, attempt,
  blocker. On resume, refetch and diff per **Controls**, then continue from the Run log.
- **Seams.** The AC→test table (checklist row 9), approved with the doc at step 4, is the seam
  confirmation `tdd` requires; every implementer gets it as the `confirmed seam list`.
- **Review base.** The merge-base of the work branch with main, recorded in the Run log.
- **Stops.** Stop and report to the user when a check still fails after 2 fix attempts, an AC is
  wrong or untestable, the work goes beyond the agreed scope, a repo gate or access is missing, or
  a seam is not in the AC→test table. Commits stay on the branch; nothing is pushed until the user
  says so.

## Piece mode

When the first prompt starts with the line `Piece mode: on`, an orchestrator has handed you one
issue of a larger ticket. Read [piece-mode.md](piece-mode.md) before step 0: steps 0 to 7 run
against that issue, then the piece hands back by a `DONE` report in place of step 8 (Ship). It
never pushes, never opens a PR, never closes or edits issues, and skips step 5's publishing
writebacks unless the user confirms them in that session. Without that line, ignore this section.

## 0. Repo procedure first

- Read the **target** repo's `CLAUDE.md` / `AGENTS.md` before anything else. If it defines a start
  procedure (read the latest `## Handoff` comment, read a plan section, check phase gates), run that
  first. **On any conflict the repo procedure wins**; this skill layers gap analysis on top of it.
- An unmet repo gate is a blocker, not a gap to clarify away: record it and stop where the repo says to.
- Respect repo rules about **when a GitHub issue may exist** — some repos forbid creating it until the
  Jira ticket enters a sprint. Intake never creates an issue or ticket on its own — only
  `sdlc-process:to-spec`, `to-tickets` and `wayfinder` publish, after the user's per-issue
  confirmation; at most intake notes that one is missing and points at the repo's rule.
- This skill never skips or waives step 0 on its own. The **user** may override it, but only with
  the second confirmation described in **Controls** — the only step that needs one.

## 1. Resolve and fetch

**Resolve the reference** to a canonical source and a `KEY`:

| Input | Source | `KEY` |
|---|---|---|
| `PROJ-571`, or a Jira `/browse/PROJ-571` URL | Jira | `PROJ-571` |
| `https://github.com/owner/repo/issues/12`, `owner/repo#12` | GitHub | `repo-12` |
| `#12` | GitHub, current repo — read it with `gh repo set-default --view` or `gh repo view --json nameWithOwner` and confirm it against `git remote -v` | `repo-12` |

Write every GitHub reference fully qualified (`owner/repo#12`) from here on — a bare `#12` changes
meaning the moment it leaves this repo.

If `docs/specs/<KEY>-requirements.md` already exists, this is a resume: fetch anyway, then diff
against the doc's snapshot (see **Controls**) before resuming.

**Detect the stage** from durable artifacts, never from conversation. Verify each pointer in
**Chain artifacts** against the tracker and git (`gh issue view`, `git log <review base>..HEAD`,
`gh pr list --head <branch>`). Read the rows top to bottom; **the first row whose state holds
decides**, so each row assumes the rows above it do not hold:

| State | Resume at |
|---|---|
| `Wayfinding: active <map URL>` in Chain artifacts | load `sdlc-process:wayfinder` with that map URL to resolve its next decision, then stop. Never return to grilling or chart a second map. A map that meets step 3's completion predicate goes to step 2 re-rating and step 4 instead |
| A PR (draft or ready) exists for the work branch | step 9 (Close-out) |
| All tickets integrated, code-review outcome recorded, and (Full tier) verifier + adversary outcome recorded; no PR | step 7 (Verify), then step 8 (Ship) |
| Tickets published but those three records are not all present (commits only show progress) | step 6 Implement for the unintegrated tickets, or resume review |
| Spec issue published, no tickets | step 6, `to-tickets` (Full tier: plan-side pass first, see **Review = tier**) |
| Requirements doc `Ready`, no spec issue | step 6, `to-spec` |
| Requirements doc `Draft` | step 3 |
| No requirements doc | step 2 |

Each stage writes its output to the tracker or the repo and records the pointer in the doc, so the
next stage reads a pointer, not the conversation.

**Jira** — Atlassian MCP `getJiraIssue`. Collect: summary, description, any acceptance-criteria
field, comments, status, sprint, story points, parent/epic, issue links, remote links.
- Load a Jira conventions skill, if installed, first: it carries the site's cloud ID, the
  story-points and sprint custom-field IDs, where AC actually live, and the MCP's projection quirks.
  Don't guess custom-field IDs — they are instance-specific.

**GitHub** — `gh issue view <N> --comments --repo owner/repo`, plus linked PRs: `gh api
repos/owner/repo/issues/<N>/timeline` and keep the `cross-referenced` events whose source is a PR.

**Linked items — classify before you merge.** A reference to another ticket does not make it the
same work item. Fetch each linked or cross-referenced item (Jira key in the GitHub title/body, GitHub
URLs in the Jira remote links, issue links, parent) and classify it as exactly one of:

| Class | Means | Its requirements and AC |
|---|---|---|
| **Equivalent** | The same work tracked in the other tracker, with identity evidence (below) | Merge into this doc |
| **Parent / epic** | The larger goal this item serves | Context for story and scope only |
| **Dependency / blocker** | Work that must land first, or that this blocks | A Dependencies row — never this item's AC |
| **Related context** | Mentioned, similar, historical — and any remote link without identity evidence | Cite if useful; nothing merges |

- **Equivalent needs evidence** of identity: the link type, the link text, or the item itself
  explicitly asserts same-work — "mirrors", "tracked in", a tracker-sync "GitHub issue" link type,
  or the same key in the title — or the user confirms it.
- **A generic remote link is not identity evidence.** A plain URL in remote links or a "see also"
  mention is **Related context** until the user says otherwise. If unclear, ask — don't merge on a
  hunch.
- A dependency's AC never becomes this item's AC.
- Writeback targets (step 5) are limited to the primary item and confirmed equivalents.

**Optional context** — use a Confluence/notes bridge skill, if installed, for linked pages and
prior notes. Cite what you used.

## 2. Gap analysis

Rate every row of [checklist.md](checklist.md) **Present / Vague / Missing**, each with a one-line
reason that cites *where* in the ticket (description, AC field, comment by X on date, linked page).
"Missing" means you looked in every fetched source, not just the description.

Present the result as one table, then the questions you will ask, in order. That list is the
**agenda** for step 3.

- An AC is **Present** only if it is testable as written — Given/When/Then, or a command plus its
  expected output. "Works correctly", "is fast", "handles errors" are **Vague**.
- Questions already asked in the ticket's comments and never answered are their own gaps.
- **Contradictions block the gate.** Any conflict between sources — Jira vs GitHub, description vs
  comments, a field vs the body (e.g. "retain 30 days" vs "retain 90 days") — is listed in the
  table's Contradictions row with both statements and where each lives. The affected area cannot be
  rated Present until the user resolves or defers the conflict.
- Don't rate from memory of similar tickets; rate what this ticket says.

## 3. Close the gaps — HARD GATE

- **Entry first.** Before any flow skill below, load the entry and the orchestrator as
  [chain-sdlc-process.md](chain-sdlc-process.md), Entry, says. Expected selection here:
  "Bounded repo-backed idea" (grill-with-docs).
- Load `sdlc-process:grill-with-docs` with the `Skill` tool, passing the step-2 agenda (the gap
  table, the ordered questions, the contradictions). It grills the user, models the domain, and
  updates `CONTEXT.md` and the ADRs as terms and decisions settle. The rules below bind that
  grilling too: draft AC, the decision log, re-rating, the gate.
- **Fallback** when `sdlc-process:grill-with-docs` is not listed by the `Skill` tool: ask **one
  question per message** yourself. Prefer `AskUserQuestion` with 2–4 concrete options, your
  recommendation first and labelled as such, plus a **Skip** option (see **Controls**). Open-ended
  only when options would be invented.
- You **may propose draft AC**, phrased testably, as an option. The user must accept, edit, or reject
  each one. **Never silently invent AC** and never upgrade your own draft to Present without a yes.
- Log every exchange as `Q → A (date)` — it becomes the decision log in step 4. For a
  contradiction, log both source statements (with where each lives) and the resolution.
- Re-rate the table after each answer.
- **Gate:** no design, plan, or code until **zero rows are Vague or Missing and zero contradictions
  are unresolved**, except items the user explicitly marks *out of scope*, *deferred*, or skips —
  record which, and the user's words (skips as `Skipped by user — <date>`). **The gate binds
  unless the user skipped the whole step** (gap analysis or this step): then warn once, record
  "requirements not gap-checked", and continue per **Controls**.
- **Fast path:** if every row is already Present and there are no contradictions, say so with the
  evidence column and go to step 4. The gate still ran; it just had nothing to block.

**Escalate to wayfinder** only after grilling, and only when the remaining uncertainty is more than
one agent session can hold. Signals: research or a prototype is needed before decisions can be
made, the work spans multiple repos, or it spans multiple phases. Never call it by default. Load
`sdlc-process:wayfinder` to chart the map (publication is an outward action under step 5's
per-action rule). Before stopping, write the requirements doc (Status `Draft`) with the Chain
artifacts field `Wayfinding: active <map URL>`, then **STOP** the run. Wayfinder resolves one
decision ticket per session; later runs resume it through step 1's first stage-detection row.

**The map is complete** only when all of these hold: the map issue shows no remaining in-scope
fog; every decision ticket's resolution has been read; and no ticket was closed with "new tickets
to follow" still pending. Zero open decision tickets alone is not enough. Then re-rate the gap
table (step 2), update the requirements doc and get the user's OK (step 4) so the settled AC list
reflects the decisions, mark `Wayfinding: complete` in Chain artifacts, and continue at `to-spec`
in step 6.

If the user asked only "is this ticket ready?", stop at the step-2 table and the open questions.

## 4. Write the requirements doc

- Write `docs/specs/<KEY>-requirements.md` in the **target** repo from [template.md](template.md).
- Set the doc's **Status** line: `Draft` while gaps are open, `Ready` once the step-3 gate passes.
  `Cancelled` is set only by the single cancel-marker edit (first line plus the Status field) in
  **Controls**. Record any skipped step and what it lost.
- If the user skips this step, write the stub doc described in **Controls** instead.
- The doc records what grilling resolved: the decision log, the `CONTEXT.md` and ADR changes it
  made (paths), and the wayfinder map URL if step 3 escalated.
- Every AC gets a stable number (`AC-1`, `AC-2`, …) — downstream plans and PRs cite them.
- Record source links and the fetched date: the doc is a snapshot, and the ticket will drift.
- No secrets, tokens, or credential values — names, IDs, and status codes only.
- Don't commit unless the user or the repo's workflow says to.
- Show the user the path and a short summary; get an explicit OK before step 5.

## 5. Writeback offer — confirm each action

The ticket is outward-facing; every write is the user's call, every time. In piece mode, offer
none unless the user asks for one in this session.

- Offer, don't apply. For each proposed write, show the **exact** payload: the comment body or the
  field and its new value, and the target (`PROJ-571` or `owner/repo#12`).
- Apply only on an explicit yes **for that action**. A yes to one write is not a yes to the next.
- Targets are limited to the primary item and confirmed equivalents (step 1) — never a parent,
  dependency, or related item.
- Jira: MCP `addCommentToJiraIssue` / `editJiraIssue` (follow the conventions skill for field
  formats). GitHub: `gh issue comment <N> --repo owner/repo --body-file -` / `gh issue edit`.
- Typical offers: a comment linking the requirements doc and the decision log; agreed AC written to
  the ticket's AC field; a Jira↔GitHub cross-link that is missing. Declining or skipping all of
  them is fine. On cancel, nothing is posted — not even an already-drafted payload.
- A comment or Jira remote link pointing at the published spec issue is offered under this same
  per-action rule.
- After an applied write, re-read the ticket and confirm it landed — a success response alone proves
  little on some fields.

## 6. Chain — spec, tickets, implement

Steps 0–5 feed one chain: sdlc-process. It runs `to-spec`, `to-tickets` and the implement stage,
then goes to step 7 (Verify) and step 8 (Ship). It is attended (see
[chain-sdlc-process.md](chain-sdlc-process.md)); there is no chain choice.

- **Installed** (the `Skill` tool lists `sdlc-process:sdlc-process`): run the chain per
  [chain-sdlc-process.md](chain-sdlc-process.md) and record `sdlc-process` in the doc's `Chain:`
  field. A step-0 rule forbidding issues makes publication a hold there.
- **Not installed:** say so. The only options are **Skip** and cancel; intake does not replicate
  sdlc-process's skills.
- **Skip** means no chain (the plan-skip rule in **Controls**): warn once, record
  "Intake: chain skipped — no spec/tickets", get an explicit go-ahead, implement with
  `dev-workflow:plan-implementation` lanes against the settled AC list (active AC only), then go to
  step 7. The PR body states the same line.

**Checkpoints.** Stop after each stage and get an explicit go before the next (go / **Skip** /
cancel, see **Controls**). Between to-tickets and implementation, recommend a fresh session: load
`sdlc-process:handoff` with the `Skill` tool to produce the handoff; the next session resumes from
the published pointers. After cancel, no chained skill is invoked.

**Settled AC list.** Plans and tickets cite `AC-n` from the **settled AC list**: the requirements
doc, the stub's **Acceptance criteria (settled)** section, or (with "no doc at all") the same list
carried for the PR body. Plans and tickets **cover only active AC**; deferred, skipped, and
out-of-scope AC get no task or ticket and are listed as not delivered. Fall back to the ticket's
original AC (in ticket order) only when intake made no revisions or deferrals, and say so; with
none, tasks cite "no AC — unverified". Never plan from the original text after step 3 changed it.

## 7. Verify

Follow [verify.md](verify.md): re-run the repo checks, then every active AC by its
AC→test row, then the Definition of done, on the final branch. Write each result with its evidence
to the doc's Verification evidence table. Nothing ships until every active AC is verified or
unverified with reason, or a stop applies (see **Run log and stops**).

## 8. Ship

In piece mode, skip steps 8 and 9 and hand back as [piece-mode.md](piece-mode.md) says.

Ship through `[[opening-pull-requests]]`; its push and PR gates each need the user's live yes. The ticket question for its gate 7 is
already answered here. The PR body's first line is the ticket link: Jira → `**Ticket:** [PROJ-571](<jira-url>)`;
GitHub → `**Ticket:** [owner/repo#12](<issue-url>)`, followed by `Refs owner/repo#12` (use a
closing keyword only if the repo allows a merge to close the issue).
The PR body works from the same settled AC list: it says which active AC numbers it delivers and
lists the deferred, skipped, and out-of-scope ones as not delivered / unverified, and states every
skipped intake step — e.g. "Intake: gap analysis skipped — requirements not gap-checked". If the
user chose "no doc at all", the PR body also carries the stub doc's content.
The PR body also lists the spec issue (none if `to-spec` was skipped) and `Refs owner/repo#N` for
each issue sdlc-process published (a closing keyword only where the repo allows a merge to close
it), or "sdlc-process: no tickets published".

**Review = tier.** `dev-workflow:review-policy` owns the tiers; intake only cites them. The
`sdlc-process:code-review` run inside Implement (Standards and Spec axes) is the Routine pass;
Exempt runs none. **Full** adds two passes, each one message dispatching
`dev-workflow:fresh-verifier` + `dev-workflow:codex-adversary`: on the published spec and tickets
before Implement, and at the PR gate on the diff with the code-review report as input (they
focus on independence and refutation). Record both outcomes in Chain artifacts.

A lint/test failure inside `opening-pull-requests` is a step-7 failure. If gate 2's rebase or a
review fix changes the tree, step 7 re-runs on the commit Ship pushes. The PR body carries the
step-7 evidence table.

The PR is opened with `gh pr create --draft`. Deferred, skipped, and out-of-scope AC are listed as
not delivered.

## 9. Close-out

Runs after Ship.

1. Show the Run log, the evidence table, and any blockers.
2. Walk each person-only AC with the user and record the result in the doc's evidence table.
3. Offer each outward action separately under step 5's per-action rule, each with Skip:
   - mark the PR ready — state any failed or unverified AC first;
   - Jira transition;
   - ticket comment;
   - close tickets, as the repo allows.
4. Status becomes Delivered only if every active AC is verified and the PR is ready; otherwise Partial, listing the open AC.
5. End with one line offering `/retro` for the user to run. Nothing is routed automatically.

## Gotchas

- **Why this exists:** tickets reach implementation with untestable AC, and the ambiguity is then
  resolved silently in code where nobody reviews the decision. The gate moves it into the open.
- **Jira descriptions and rich-text fields may come back as ADF JSON**, not text. Read the text
  nodes; never paste raw ADF into the requirements doc or a gap reason.
- **AC may live outside the description** — a dedicated field, an app-owned checklist, or a comment.
  An empty "Acceptance Criteria" heading in the description is not proof there are none.
- **Jira status and GitHub issue state are different facts.** A Jira "Done" doesn't close the GitHub
  issue, and a closed GitHub issue doesn't mean the Jira ticket is done.
- **Closed ≠ done.** An issue closed by a merge, or by hand, may still have unmet exit criteria —
  check the AC against evidence, not the state badge.
- **A bare `#N` is ambiguous** — GitHub numbers issues and PRs in one space, and the repo is inferred.
  Resolve it once, then write `owner/repo#N`.
