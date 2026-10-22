# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues on `{{owner}}/{{repo}}`. Use the `gh` CLI for all
operations, and always pass `--repo {{owner}}/{{repo}}`.

## Instruction precedence

This file sits below the repo's own instruction files (start at `{{instruction_file}}`); on a conflict, the repo's instruction precedence decides.

## Repo rules

- Always pass `--repo {{owner}}/{{repo}}`; write fully qualified references (`{{owner}}/{{repo}}#N`) outside this repo.
<!-- optional: backlog -->
- {{backlog_name}} is the backlog; when to create an issue and how it joins the board: "Backlog and the project board" below.
- Every issue body starts with a `**Ticket:**` line linking its {{backlog_name}} ticket.
<!-- /optional -->
- PRs reference issues with `Refs {{owner}}/{{repo}}#N`, never a closing keyword. Close an issue by hand only when every task and exit criterion has evidence in a `## Handoff` comment.
- Evidence in issues: names, status codes, ids, decoded claims only. Never token, key, password or secret values.

## Conventions

- **Create an issue**: `gh issue create --repo {{owner}}/{{repo}} --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --repo {{owner}}/{{repo}} --comments`, filtering comments by `jq` and also fetching labels.
- **List issues**: `gh issue list --repo {{owner}}/{{repo}} --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --repo {{owner}}/{{repo}} --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --repo {{owner}}/{{repo}} --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --repo {{owner}}/{{repo}} --comment "..."`

<!-- optional: backlog -->
## Backlog and the project board

{{backlog_name}} is the backlog. Create the `{{owner}}/{{repo}}` issue when a ticket is pulled into a sprint, not when it is filed.
Create it earlier only when a repo artifact must reference it.

<!-- /optional -->
## Project board

Add every new `{{owner}}/{{repo}}` issue to the {{project_title}} project ({{project_url}}) as you
create it, with Status and any required fields set: `gh project item-add {{project_number}} --owner {{owner}} --url <issue-url>`,
then `gh project item-edit` for each field.

Project workflows may set Status when an item is added or closed. Every other label or Status move is
made by the session at its lifecycle step ("Issue lifecycle" below) and recorded in its handoff.

## Issue lifecycle (labels and board Status)

The session that does a step makes the change in that same step and records it in its handoff. The board is
project {{project_number}} (`gh project item-edit` on the Status field). The triage labels are the five in
`docs/agents/triage-labels.md`.

| Step | Board Status | Triage label |
|---|---|---|
| Created, not yet assessed | {{status_not_triaged}} | `needs-triage` |
| Spec being written or refined | {{status_refining}} | none, or `needs-info` while waiting on someone for information |
| Fully specified, ready for an agent | {{status_ready_agent}} | `ready-for-agent` |
| Fully specified, ready for a human | {{status_ready_human}} | `ready-for-human` |
| A session starts work | {{status_building}} | remove the `ready-for-*` label |
| PR open, or changes applied and being verified | {{status_validating}} | none |
| Closed: every checkbox and exit criterion has evidence in a `## Handoff` | {{status_done}} | none |
| Closed as won't do: the owner cancelled it, and the handoff records that decision | {{status_wont_do}} | `wontfix` |

- **Merging a PR does not finish an issue.** The issue stays at the validating step (Status: {{status_validating}}) until a handoff records evidence for every criterion. Only then is it closed (Status: {{status_done}}).
<!-- optional: phase_gates -->
- **Gates.** An issue is ready only when every gate it depends on (`docs/agents/phase-gates.md`) has a passing handoff.
<!-- /optional -->
- **Blocked.** A specified issue that cannot proceed stays at the refining step (Status: {{status_refining}}). An issue found blocked after work starts is set back (Status: {{status_refining}}), and you remove the `ready-for-*` label. Either way, the handoff names the blocker under **Open / blocked**.
- **Reopened.** The session that reopens an issue removes `wontfix` and sets Status: {{status_refining}}, or Status: {{status_building}} if work resumes at once.
<!-- optional: backlog -->
- **Reopened, backlog.** It also puts the {{backlog_name}} ticket (and its parent issue) back in progress if either is done (Status: {{status_done}}).
<!-- /optional -->
- **Parent (spec) issue.** It carries no `ready-for-*` label. It is at the building step (Status: {{status_building}}) while any child issue is open. It is closed (Status: {{status_done}}), with its own handoff, once every child issue is closed.
<!-- optional: backlog -->
- **Backlog ticket.** Close it (Status: {{status_done}}) only after every `{{owner}}/{{repo}}` issue for it is closed. If the owner cancels the whole ticket, close it as cancelled instead (Status: {{status_wont_do}}).
<!-- /optional -->
- **Missing labels.** If a label in this table does not exist on the repo, create it with the description from `docs/agents/triage-labels.md` before applying it.

## Handoff comment

A session ends with one comment headed `## Handoff`. It records what was done, the evidence for each criterion,
the label and Status changes made, and an **Open / blocked** section naming anything unmet or waiting. Evidence
is names, ids and status codes; never secret values.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> --repo {{owner}}/{{repo}} --comments` and `gh pr diff <number> --repo {{owner}}/{{repo}}` for the diff.
- **List external PRs for triage**: `gh api repos/{{owner}}/{{repo}}/pulls --paginate --jq '.[] | select(.author_association | IN("CONTRIBUTOR","FIRST_TIME_CONTRIBUTOR","FIRST_TIMER","NONE")) | {number, title, body, labels: [.labels[].name], user: .user.login}'` (`gh pr list --json` has no author-association field; the REST form drops `OWNER`/`MEMBER`/`COLLABORATOR`).
- **Comment / label / close**: `gh pr comment`, `gh pr edit --add-label`/`--remove-label`, `gh pr close`, each with `--repo {{owner}}/{{repo}}`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either: resolve with `gh pr view 42 --repo {{owner}}/{{repo}}` and fall back to `gh issue view 42 --repo {{owner}}/{{repo}}`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue on `{{owner}}/{{repo}}`, subject to the repo rules above.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --repo {{owner}}/{{repo}} --comments`.
<!-- optional: backlog -->
The {{backlog_name}} ticket named in its `**Ticket:**` line is the backlog source; read it too.
<!-- /optional -->

<!-- optional: wayfinding -->
## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create --repo {{owner}}/{{repo}} --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh api` on the sub-issues endpoint). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of {{owner}}/{{repo}}#<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies**. Add an edge with `gh api --method POST repos/{{owner}}/{{repo}}/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/{{owner}}/{{repo}}/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only). Where dependencies aren't available, fall back to a `Blocked by: {{owner}}/{{repo}}#<n>` line at the top of the child body. A closed blocker is a dependency only: it does not by itself show the blocked ticket is ready.
- **Frontier query**: list the map's open children, drop any with an open blocker or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --repo {{owner}}/{{repo}} --add-assignee @me`, the session's first write.
- **Resolve**: `gh issue comment <n> --repo {{owner}}/{{repo}} --body "<answer>"`, then close the ticket following this repo's close rule, then append a context pointer to the map's Decisions-so-far.
<!-- /optional -->
