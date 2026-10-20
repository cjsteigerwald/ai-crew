---
name: setting-up-project-boards
description: >
  Sets up a GitHub Projects (v2) board for a repository by copying a template
  project, linking the repo, bringing its open issues onto the board, moving
  closed items to Done, telling the user which workflows to enable in the UI,
  then triaging each issue onto the board. Use when "set up a project board for
  <repo>", "copy this project/view to another repo", a pasted
  `github.com/orgs/<org>/projects/<n>/views/<m>` URL with a request to explain
  or reproduce it, "add the repo's issues to the board", or "triage the issues
  onto the board". Skip when triaging one issue with no board (use the repo's
  triage skill), creating new tickets, planning or decomposing work, or editing
  a single field value on an existing board.
---

# Setting up project boards

Reproduce a template GitHub Project for another repo, populate it, and triage the issues onto it.
Run the steps in order. Every outward-facing batch (copy, link, adding items, creating labels,
posting comments) is confirmed with the user first. State counts from command output, never memory,
never put token values in comments or output, and never delete a project workflow (the API allows
it; nothing here needs it).

Long GraphQL queries live in [references/queries.md](references/queries.md).

## 1. Inputs and instruction layers

Collect: template project (owner + number), target owner, target repo, new project title.
Read the target repo's instruction files plus `docs/agents/issue-tracker.md` and
`docs/agents/triage-labels.md` if present. They govern labels and close rules.

## 2. Auth preflight

- `gh auth status`: reading projects needs `read:project`; copy, link and item edits need `project`.
  A missing scope surfaces as `INSUFFICIENT_SCOPES` naming the field.
- If `GH_TOKEN`/`GITHUB_TOKEN` is set, or a `gh` wrapper earlier on PATH sets it (check `type -a gh`),
  `gh auth refresh` refuses: "The value of the GH_TOKEN environment variable is being used for
  authentication." Run the real binary by absolute path with the env cleared:
  `env -u GH_TOKEN -u GITHUB_TOKEN <real-gh> auth refresh -h github.com -s project`.
- Run the refresh from a non-interactive (background) shell. It then skips the interactive
  "Authenticate Git with your GitHub credentials? (Y/n)" prompt and prints the one-time code. An
  interactive terminal the agent cannot type into stalls at that prompt. Give the user the code and
  https://github.com/login/device. Under enterprise SSO they must approve in their own signed-in
  browser. Wait for "Authentication complete", then re-check scopes through BOTH the wrapper and the
  real binary.
- A refresh updates the stored login; an environment or wrapper token takes precedence over it. If
  the gh you will use for later commands still lacks the scope after the refresh, stop and tell the
  user. Do not switch credentials silently: confirm the account (`<that gh> api user` → `login`) with
  the user, and with their OK run every later command through that same invocation.
- A wrapper can also pick the account by working directory. Run `gh auth status` from the directory
  you will run the project commands in. A run from another checkout can switch accounts and surface
  as `INSUFFICIENT_SCOPES` or `NOT_FOUND` on queries that worked elsewhere.
- An SSO-protected project cannot be read through a browser that is not signed in; use the GraphQL API.

## 3. Inspect the template

Run the "Inspect a project" query for `<template-owner>` / `<n>`. Explain to the user: the layout, the
column field (board columns = `verticalGroupByFields`), the filter, visible fields, custom fields and
their options, and which workflows are enabled.

## 4. Check the target and confirm

Run the "Check the target" query: the repo's `projectsV2`, plus the org's `projectsV2 { totalCount }`
and `viewerCanCreateProjects`. A repo can only be linked to a project owned by the same owner, so
create the project under the repo's owner. **Confirm owner and title with the user before creating
anything.**

## 5. Copy and link

```bash
gh project copy <n> --source-owner <template-owner> --target-owner <org> --title "<title>" --format json
gh project link <new-n> --owner <org> --repo <org>/<repo>
```

The copy brings views, fields, options and workflow settings, not items. Observed: "Auto-add
sub-issues to project" came across enabled although the GitHub docs say auto-add workflows are not
copied. Verify; do not assume. Always pass `--owner` to `link`, `view`, `field-list`, `item-add` and
`item-list` (copy uses `--source-owner`/`--target-owner`; `item-edit` uses `--project-id`): project
numbers are per owner, so the copy and the template can both be number 1. Re-run the step 3 query against the new project to verify.

## 6. Add issues

Run the "Count issues" query first. Default scope is open issues, confirm with the user. List with
`--limit` at least the open `totalCount`, then check the listed count equals it; if not, raise the
limit and re-list. Report the closed count from the same query:

```bash
gh issue list --repo <org>/<repo> --state open --limit 1000 --json number,title,url
```

`gh project field-list <new-n> --owner <org> --format json` gives the Status field id and option
ids (fields only, not the project id). Take the project id `PVT_…` from the step 5
`gh project copy --format json` output (`.id`), `gh project view <new-n> --owner <org> --format json`,
or the Inspect query's `id`. The intake column is the template's first-stage column (for
example "Not yet triaged"). For each issue:

```bash
gh project item-add <new-n> --owner <org> --url <issue-url> --format json     # -> item id
gh project item-edit --project-id <PVT_…> --id <item> --field-id <status-field> --single-select-option-id <intake-option>
```

Side effect: auto-add sub-issues pulls in sub-issues of added parents, including closed ones, with no
Status. Re-list board items afterward (items query) and report the extras. Closed items on the board
go to Done: find them with the items query (content `state`) and set Status to the Done option.

## 7. Workflows the user must turn on in the UI

The API can read built-in workflows but cannot enable or configure them. Tell the user: Project →
⋯ → Workflows, then:

- "Auto-add to project": repo + filter `is:issue is:open` (not retroactive).
- "Item added to project": set Status to the intake column.
- "Item closed": set Status to Done.
- Optionally "Pull request merged": Done.

## 8. Triage onto the board

Follow the target repo's triage process (its triage skill if it has one) and its label mapping.

a. `gh label list --repo <org>/<repo>` against the mapping. Propose creating missing state labels
   (for example `needs-info`).
b. Gather context: delegate digests to a read-only lane in batches of ~10 issues (issue view with
   comments, labels and assignees; timeline for linked PRs and their state; sub-issues; parent). Tell
   the lane to report stale bodies and blockers faithfully.
c. Recommend a table to the user: issue | category | state label | board column | why. Default mapping applies to a template with
   those columns; substitute the template's own columns found in step 3.

   | Situation | Column |
   |---|---|
   | `ready-for-agent` | Ready for an agent |
   | `ready-for-human` | Ready for a human |
   | `needs-info` | Refining |
   | Blocked by an open issue or an outside party | Backlog (keeps its ready label; the comment names the blocker) |
   | Delivered, awaiting a final check | Validating |
   | Umbrella with open children | Building |

   Never close issues or edit bodies here; respect the repo's close rule. Flag stale bodies in the
   comment instead. The approved per-issue plan lists labels to ADD and to REMOVE. Triage state labels
   are mutually exclusive: remove a superseded state label (e.g. `ready-for-agent` when moving to
   `needs-info`), keep unrelated labels. **Wait for approval.**
d. Apply (mechanical; the cheapest writer lane can do it given exact per-issue text): create the
   approved labels; post one comment per issue whose first line is
   `> *This was generated by AI during triage.*`; apply labels with
   `gh issue edit --add-label … --remove-label …`; set Status. `needs-info` comments use a
   "Triage Notes" layout: what is established / what we still need, with specific questions.

## 9. Verify and report

Use the items query: group items by Status, list labels per issue, and check that each issue has exactly
one state label consistent with its Status, and that its latest triage comment starts with the
disclaimer (a later human reply may follow it, so look through the last few comments). Check the label counts add up to the triaged total and report any
extra board items. Undo a Status change with `gh project item-edit … --clear`.
