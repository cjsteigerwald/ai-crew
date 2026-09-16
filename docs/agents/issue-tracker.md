# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --comments` for human-readable output. To filter with `jq`, request JSON explicitly: `gh issue view <number> --json number,title,body,labels,comments` (the `--comments` flag alone does not emit JSON).
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

Infer the repo from `git remote -v` — but see "Base-repo resolution in this clone" below before relying on `gh`'s automatic inference.

## Base-repo resolution in this clone

⚠️ This repository is a fork and `codex-crew/UPSTREAM.md` instructs every fresh clone to add an
`upstream` remote pointing at `sidkik/claude-plugins`. **`gh` prefers a remote named `upstream`
over `origin`**, so on a clone that has followed those instructions, an unqualified
`gh issue create` targets the upstream project, not this fork.

This checkout is currently safe only because of untracked local config
(`git config remote.origin.gh-resolved` → `base`), which does not travel with the repo.

Do one of these once per clone, before any `gh issue` / `gh pr` write:

```bash
gh repo set-default cjsteigerwald/ai-crew
```

or pass the repo explicitly on every call: `gh issue create -R cjsteigerwald/ai-crew ...`

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> --comments` and `gh pr diff <number>` for the diff.
- **List external PRs for triage**: `authorAssociation` is **not** a supported `--json` field (verified against `gh` 2.63.2: `gh pr list --json authorAssociation` → `Unknown JSON field`). Use the REST API instead:

  ```bash
  gh api repos/cjsteigerwald/ai-crew/pulls --paginate \
    --jq '.[] | select(.author_association | IN("CONTRIBUTOR","FIRST_TIME_CONTRIBUTOR","NONE")) | {number, title, user: .user.login}'
  ```

  (drop `OWNER`/`MEMBER`/`COLLABORATOR`.)
- **Comment / label / close**: `gh pr comment`, `gh pr edit --add-label`/`--remove-label`, `gh pr close`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either: resolve with `gh pr view 42` and fall back to `gh issue view 42`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Wayfinding operations

Used by `/wayfinder`, which ships in the **mattpocock-skills** plugin — this section applies only
when that plugin is installed. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh api` on the sub-issues endpoint). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies**, the canonical, UI-visible representation. Add an edge with `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/<owner>/<repo>/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only, the live gate). Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children (`gh issue list --state open`, scoped to the map's sub-issues / task list), drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me`, the session's first write.
- **Resolve**: `gh issue comment <n> --body "<answer>"`, then `gh issue close <n>`, then append a context pointer (gist + link) to the map's Decisions-so-far.
