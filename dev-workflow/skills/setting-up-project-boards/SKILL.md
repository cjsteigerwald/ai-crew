---
name: setting-up-project-boards
description: >
  Sets up a GitHub Projects (v2) board for a repository by copying a template
  project, linking the repo, installing the board's agent docs (issue tracker
  lifecycle, triage labels, optional phase gates) into the repo, bringing its
  open issues onto the board, moving closed items to Done or Won't do, telling
  the user which workflows to enable in the UI, then triaging each issue onto
  the board. Use when "set up a project board for
  <repo>", "copy this project/view to another repo", a pasted
  `github.com/orgs/<org>/projects/<n>/views/<m>` URL with a request to explain
  or reproduce it, "add the repo's issues to the board", or "triage the issues
  onto the board". Skip when triaging one issue with no board (use the repo's
  triage skill), creating new tickets, planning or decomposing work, or editing
  a single field value on an existing board.
---

# Setting up project boards

Reproduce a template GitHub Project for another repo, populate it, and triage the issues onto it.
Run the steps in order. Every outward-facing batch (copy, link, writing docs, pushing and opening the
PR, editing an instruction file, adding items, creating labels, posting comments) is confirmed with the
user first. State counts from command output, never memory, never put token values in comments
or output, and never delete a project workflow (the API allows it; nothing here needs it).

Long GraphQL queries live in [references/queries.md](references/queries.md).

## 1. Inputs and instruction layers

Collect: template project (owner + number), target owner, target repo, new project title.
Read the target repo's instruction files plus `docs/agents/issue-tracker.md`,
`docs/agents/triage-labels.md` and `docs/agents/phase-gates.md` if present. They govern labels and close rules.

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

## 5. Checkout preflight

Read-only; nothing is written. It decides whether step 7 can install the board's agent docs.

- Resolve the checkout: a path the user names, or the current directory only if its `git remote -v`
  resolves to `<org>/<repo>` (ssh or https). Never clone.
- From that directory run `gh auth status` and `gh api user`, and confirm the account (`login`) with the user.
- Detect a dirty tree (`git status --porcelain`) and the repo's default branch
  (`gh repo view <org>/<repo> --json defaultBranchRef`; always name the repo, because a fork checkout
  with an `upstream` remote makes unqualified `gh` resolve the wrong repo). Note which git remote's URL
  matches `<org>/<repo>`.
- With no usable checkout, record "install skipped" and continue; step 7 is then skipped.

## 6. Copy and link

```bash
gh project copy <n> --source-owner <template-owner> --target-owner <org> --title "<title>" --format json
gh project link <new-n> --owner <org> --repo <org>/<repo>
```

The copy brings views, fields, options and workflow settings, not items. Observed: "Auto-add
sub-issues to project" came across enabled although the GitHub docs say auto-add workflows are not
copied. Verify; do not assume. Always pass `--owner` to `link`, `view`, `field-list`, `item-add` and
`item-list` (copy uses `--source-owner`/`--target-owner`; `item-edit` uses `--project-id`): project
numbers are per owner, so the copy and the template can both be number 1. Re-run the step 3 query against the new project to verify.

## 7. Install the board's agent docs

Skip this step, and say so in the final report, when step 5 recorded "install skipped". Writes land in the
target checkout under `docs/agents/`, from the files in [templates/](templates/).

1. Ask first whether the repo has phase gates. If yes, `phase-gates.md` is installed and `phase_gates`
   sections stay; otherwise they are dropped. Likewise keep `backlog` only if the user names an external
   backlog, and `wayfinding` only if the repo uses wayfinder maps. Offer to fill in any gates the user already knows.
2. Read the Status options from the copied project (step 6 re-inspection), never from the template.
   Show the user a mapping table for review: each step of the template's "Issue lifecycle" table to a
   Status option. For an unmatched step the user picks an existing option, or the cell reads "no column; label only".
   Never create a column or rename one. The same mapping drives this install, triage (step 10) and verify
   (step 11). A step mapped label only gets no Status write anywhere in this skill.
3. Fill the placeholders from the [Placeholders table](#placeholders). For a step mapped "label only", fill
   its cell with `no column; label only` and reword lifecycle bullets naming that step to its label (for
   example "keeps `wontfix`, no Status change"). No unresolved `{{…}}` may remain in a written file; strip
   the `<!-- optional: … -->` markers and the content of dropped sections.
4. Branch from the default branch, `<remote>/<default-branch>`, after `git fetch <remote>` (the remote found
   in the preflight, step 5), with a collision-free branch name (check local and remote branches, suffix on a clash).
   Use a `git worktree` when the tree is dirty. Never reset or discard existing work.
5. For each target file that already exists, show a diff and ask merge / overwrite / skip. For
   `issue-tracker.md` the default is to append only the missing board sections. Show conflicting rules in
   the diff. Keep the target's own instruction precedence and resolve label strings through its
   `triage-labels.md` mapping. If a conflicting section is skipped, the existing policy keeps governing and
   the final report says the install is incomplete.
6. Confirm the batch before writing, then write and commit the files on the branch.
7. Push and open the PR is one confirmed action: `git push <remote> <branch>`, then
   `gh pr create --repo <org>/<repo> --base <default-branch>`. Declining leaves the branch local.
8. A one-line pointer to `docs/agents/` in `AGENTS.md` (or `CLAUDE.md` when there is no `AGENTS.md`) is a
   separate confirmed edit. If the repo has neither, ask which to create or skip the pointer.

## 8. Add issues

Run the "Count issues" query first. Default scope is open issues, confirm with the user. List with
`--limit` at least the open `totalCount`, then check the listed count equals it; if not, raise the
limit and re-list. Report the closed count from the same query:

```bash
gh issue list --repo <org>/<repo> --state open --limit 1000 --json number,title,url
```

`gh project field-list <new-n> --owner <org> --format json` gives the Status field id and option
ids (fields only, not the project id). Take the project id `PVT_…` from the step 6
`gh project copy --format json` output (`.id`), `gh project view <new-n> --owner <org> --format json`,
or the Inspect query's `id`. The intake column is the one the step 7 mapping gives for "not yet triaged" (the template's
first-stage column only when step 7 was skipped); if that step is "label only", skip Status. For each issue:

```bash
gh project item-add <new-n> --owner <org> --url <issue-url> --format json     # -> item id
gh project item-edit --project-id <PVT_…> --id <item> --field-id <status-field> --single-select-option-id <intake-option>
```

Side effect: auto-add sub-issues pulls in sub-issues of added parents, including closed ones, with no
Status. Re-list board items afterward (items query) and report the extras. Closed items on the board
go to Done or Won't do (when mapped), from the step 7 mapping: `stateReason` NOT_PLANNED or a `wontfix`
label goes to the won't-do option, any other close to done. Find them with the items query (content
`state`) and set Status to that option, skipping Status for label only steps (see step 7).

## 9. Workflows the user must turn on in the UI

The API can read built-in workflows but cannot enable or configure them. Tell the user: Project →
⋯ → Workflows, then:

- "Auto-add to project": repo + filter `is:issue is:open` (not retroactive).
- "Item added to project": set Status to the mapped intake option.
- "Item closed": set Status to the mapped done option. Won't do items closed as not planned need Status
  set to Won't do by hand.
- Skip Status for label only steps (see step 7).
- Skip "Pull request merged": merging a PR does not finish an issue.

## 10. Triage onto the board

Follow the target repo's triage process (its triage skill if it has one) and its label mapping. When the
repo has a `docs/agents/issue-tracker.md` lifecycle (installed, merged or pre-existing), that
lifecycle table decides the Status for each state label. Triage uses the Status mapping from step 7
(label only steps: see step 7);
the default table's column names are a fallback only when no mapping or lifecycle exists.

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
   | Blocked by an open issue or an outside party | Refining (remove the `ready-for-*` label; the comment names the blocker) |
   | Delivered, awaiting a final check | Validating |
   | Umbrella with open children | Building |
   | Owner cancelled it (`wontfix`) | Won't do |

   Never close issues or edit bodies here; respect the repo's close rule. Flag stale bodies in the
   comment instead. The approved per-issue plan lists labels to ADD and to REMOVE. Triage state labels
   are mutually exclusive: remove a superseded state label (e.g. `ready-for-agent` when moving to
   `needs-info`), keep unrelated labels. **Wait for approval.**
d. Apply (mechanical; the cheapest writer lane can do it given exact per-issue text): create the
   approved labels; post one comment per issue whose first line is
   `> *This was generated by AI during triage.*`; apply labels with
   `gh issue edit --add-label … --remove-label …`; set Status (not for label only steps: see step 7).
   `needs-info` comments use a "Triage Notes" layout: what is established / what we still need, with
   specific questions.

## 11. Verify and report

Use the items query: group items by Status, list labels per issue, and check that each issue has at most one
state label and that the label matches the lifecycle row for its Status. A "label only" step (no mapped
column) is checked by label alone. When no lifecycle exists, check labels against the default table in
step 10. Check that its latest triage comment starts with the disclaimer (a later human reply may follow
it, so look through the last few comments), and report any extra board items. Undo a Status change with
`gh project item-edit … --clear`.

## Placeholders

Every `{{name}}` in [templates/](templates/) is listed here; step 7 fills them all.

| Placeholder | Meaning | Source |
|---|---|---|
| `{{owner}}` | Org or user that owns the repo | Step 1 target owner |
| `{{repo}}` | Repo name | Step 1 target repo |
| `{{instruction_file}}` | Entry instruction file (`AGENTS.md`, else `CLAUDE.md`; ask the user if neither exists) | Step 1 instruction files |
| `{{project_title}}` | Board title | Step 1 new project title |
| `{{project_url}}` | Board URL | Step 6 `gh project copy` output |
| `{{project_number}}` | Board number under the owner | Step 6 `gh project copy` output |
| `{{backlog_name}}` | Name of the external backlog | The user, when the `backlog` section is kept |
| `{{status_not_triaged}}` | Status option for "not yet triaged" | Step 7 mapping table |
| `{{status_refining}}` | Status option for "refining" | Step 7 mapping table |
| `{{status_ready_agent}}` | Status option for "ready for an agent" | Step 7 mapping table |
| `{{status_ready_human}}` | Status option for "ready for a human" | Step 7 mapping table |
| `{{status_building}}` | Status option for "building" | Step 7 mapping table |
| `{{status_validating}}` | Status option for "validating" | Step 7 mapping table |
| `{{status_done}}` | Status option for "done" | Step 7 mapping table |
| `{{status_wont_do}}` | Status option for "won't do" | Step 7 mapping table |
