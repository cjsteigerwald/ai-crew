---
name: intaking-work-items
description: >
  Takes a Jira ticket or GitHub issue from "assigned" to "ready to build":
  fetches its full context, gap-analyzes the story, scope, requirements and
  acceptance criteria, blocks on clarifying questions until every gap is closed
  or explicitly deferred, writes docs/specs/<KEY>-requirements.md, offers
  confirmed writebacks to the ticket, then chains design, plan, implementation
  and PR with a user checkpoint between each. Use when starting work on an
  existing ticket — "start work on PROJ-571", "pick up issue #12", "bring in
  this ticket", "work on owner/repo#N", a pasted Jira or GitHub issue URL, or
  "is this ticket ready". Skip when creating a new ticket (use a
  ticket-creation skill such as creating-ces-tickets), root-causing an incident
  (investigating-incidents), executing an already-approved plan
  (plan-implementation), or just shipping finished work (opening-pull-requests).
---

# Intaking work items

Turn an existing ticket into a settled, testable requirements doc **before** any design or code.
Tickets routinely reach implementation with acceptance criteria nobody can test; this skill is the
gate that stops that. Run the steps in order — the gate in step 3 is hard.

## When to Use This Skill

- Starting work on an existing Jira ticket or GitHub issue, by key, URL, `owner/repo#N`, or `#N`
- "start work on PROJ-571", "pick up issue #12", "bring in this ticket", "work on owner/repo#N"
- "is this ticket ready?" — run steps 1–3 and stop at the gap table if the user only wants a verdict

## When *Not* to Use This Skill

- Filing a new ticket → a ticket-creation skill (e.g. `creating-ces-tickets`)
- Root-causing a failure or alert → `[[investigating-incidents]]`
- A plan already exists and the user approved it → `[[plan-implementation]]`
- The work is done and only needs to ship → `[[opening-pull-requests]]`

## 0. Repo procedure first

- Read the **target** repo's `CLAUDE.md` / `AGENTS.md` before anything else. If it defines a start
  procedure (read the latest `## Handoff` comment, read a plan section, check phase gates), run that
  first. **On any conflict the repo procedure wins**; this skill layers gap analysis on top of it.
- An unmet repo gate is a blocker, not a gap to clarify away: record it and stop where the repo says to.
- Respect repo rules about **when a GitHub issue may exist** — some repos forbid creating it until the
  Jira ticket enters a sprint. Intake never creates an issue or ticket on its own; at most it notes
  that one is missing and points at the repo's rule.

## 1. Resolve and fetch

**Resolve the reference** to a canonical source and a `KEY`:

| Input | Source | `KEY` |
|---|---|---|
| `PROJ-571`, or a Jira `/browse/PROJ-571` URL | Jira | `PROJ-571` |
| `https://github.com/owner/repo/issues/12`, `owner/repo#12` | GitHub | `repo-12` |
| `#12` | GitHub, repo from `git remote -v` (confirm `gh repo set-default` first) | `repo-12` |

Write every GitHub reference fully qualified (`owner/repo#12`) from here on — a bare `#12` changes
meaning the moment it leaves this repo.

**Jira** — Atlassian MCP `getJiraIssue`. Collect: summary, description, any acceptance-criteria
field, comments, status, sprint, story points, parent/epic, issue links, remote links.
- If a Jira conventions skill is installed (e.g. `jira-conventions`), load it first: it carries the
  site's cloud ID, the story-points and sprint custom-field IDs, where AC actually live, and the MCP's
  projection quirks. Don't guess custom-field IDs — they are instance-specific.

**GitHub** — `gh issue view <N> --comments --repo owner/repo`, plus linked PRs: `gh api
repos/owner/repo/issues/<N>/timeline` and keep the `cross-referenced` events whose source is a PR.

**Cross-link** — look for a Jira key in the GitHub title/body and GitHub URLs in the Jira remote
links. When both exist, fetch both: they are one work item with two views, and they disagree often.

**Optional context** — if an Atlassian/notes bridge skill is installed (e.g.
`atlassian-obsidian-bridge`), use it for linked Confluence pages and prior notes. Cite what you used.

## 2. Gap analysis

Rate every row of [checklist.md](checklist.md) **Present / Vague / Missing**, each with a one-line
reason that cites *where* in the ticket (description, AC field, comment by X on date, linked page).
"Missing" means you looked in every fetched source, not just the description.

Present the result as one table, then the questions you will ask, in order.

- An AC is **Present** only if it is testable as written — Given/When/Then, or a command plus its
  expected output. "Works correctly", "is fast", "handles errors" are **Vague**.
- Questions already asked in the ticket's comments and never answered are their own gaps.
- Don't rate from memory of similar tickets; rate what this ticket says.

## 3. Close the gaps — HARD GATE

- Ask **one question per message**. Prefer `AskUserQuestion` with 2–4 concrete options, your
  recommendation first and labelled as such. Open-ended only when options would be invented.
- You **may propose draft AC**, phrased testably, as an option. The user must accept, edit, or reject
  each one. **Never silently invent AC** and never upgrade your own draft to Present without a yes.
- Log every exchange as `Q → A (date)` — it becomes the decision log in step 4.
- Re-rate the table after each answer.
- **Gate:** no design, plan, or code until **zero rows are Vague or Missing**, except rows the user
  explicitly marks *out of scope* or *deferred* — record which, and the user's words.
- **Fast path:** if every row is already Present, say so with the evidence column and go to step 4.
  The gate still ran; it just had nothing to block.

If the user asked only "is this ticket ready?", stop here with the table and the open questions.

## 4. Write the requirements doc

- Write `docs/specs/<KEY>-requirements.md` in the **target** repo from [template.md](template.md).
- Every AC gets a stable number (`AC-1`, `AC-2`, …) — downstream plans and PRs cite them.
- Record source links and the fetched date: the doc is a snapshot, and the ticket will drift.
- No secrets, tokens, or credential values — names, IDs, and status codes only.
- Don't commit unless the user or the repo's workflow says to.
- Show the user the path and a short summary; get an explicit OK before step 5.

## 5. Writeback offer — confirm each action

The ticket is outward-facing; every write is the user's call, every time.

- Offer, don't apply. For each proposed write, show the **exact** payload: the comment body or the
  field and its new value, and the target (`PROJ-571` or `owner/repo#12`).
- Apply only on an explicit yes **for that action**. A yes to one write is not a yes to the next.
- Jira: MCP `addCommentToJiraIssue` / `editJiraIssue` (follow the conventions skill for field
  formats). GitHub: `gh issue comment <N> --repo owner/repo --body-file -` / `gh issue edit`.
- Typical offers: a comment linking the requirements doc and the decision log; agreed AC written to
  the ticket's AC field; a Jira↔GitHub cross-link that is missing. Declining all of them is fine.
- After an applied write, re-read the ticket and confirm it landed — a success response alone proves
  little on some fields.

## 6. Chain — a user checkpoint between each skill

Stop after each stage and get an explicit go before invoking the next. If a chained skill is not
installed, say so and do that step by hand to the same standard.

1. **Design — `superpowers:brainstorming`.** Hand it the requirements doc path and say plainly:
   *requirements and AC are settled; brainstorm the design and approach only — do not re-open
   scope or AC.* Its "write back your understanding" step should be a short summary of the doc for
   the user to confirm, not a second interview.
   - Brainstorming picks a path itself. **Architectural** → it writes a design doc (default
     `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`) and hands off to writing-plans; ask it to
     link the requirements doc from the design doc. **Bounded** → it presents an in-chat design and
     writes no spec or plan; that approved design plus the AC list is the plan, so skip stage 2.
     **Spike** → the output is a recommendation; come back to step 3 if it changes requirements.
   - If design surfaces a genuine requirements gap, stop, return to step 3 for that row, and update
     the requirements doc and its decision log. Don't patch requirements inside the design.
2. **Plan — `superpowers:writing-plans`** (architectural path). Ask that every task cite the AC
   numbers it satisfies and that every AC is covered by at least one task; list both doc paths in the
   plan's **Spec** line. Tell it up front that execution will be `dev-workflow:plan-implementation`,
   so its handoff asks only for plan review — not to choose an executor.
3. **Implement — `[[plan-implementation]]`**, only after the user approves the plan (or, on the
   bounded path, the in-chat design). A single small edit doesn't need the orchestrator — just do it.
4. **Ship — `[[opening-pull-requests]]`.** The ticket question for its gate 7 is already answered
   here: Jira → `**Ticket:** [PROJ-571](<jira-url>)` first line; GitHub →
   `Refs owner/repo#12` (use the closing keyword only if the repo allows a merge to close the issue).
   The PR body says which AC numbers it delivers and which are deferred.

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
