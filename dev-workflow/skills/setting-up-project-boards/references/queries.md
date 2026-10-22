# GraphQL queries for project boards

Placeholders: `<template-owner>`, `<org>`, `<repo>`, `<n>`. Run each with `gh api graphql -f query='…'`.
For a user-owned project, swap `organization(login:…)` for `user(login:…)`.

## Inspect a project (template or copy)

```bash
gh api graphql -f query='
{
  organization(login: "<template-owner>") {
    projectV2(number: <n>) {
      id
      title
      items { totalCount }
      views(first: 20) {
        nodes {
          number name layout filter
          groupByFields(first: 5) { nodes { ... on ProjectV2FieldCommon { name } } }
          verticalGroupByFields(first: 5) { nodes { ... on ProjectV2FieldCommon { name } } }
          sortByFields(first: 5) { nodes { field { ... on ProjectV2FieldCommon { name } } direction } }
          fields(first: 30) { nodes { ... on ProjectV2FieldCommon { name } } }
        }
      }
      fields(first: 30) {
        nodes {
          ... on ProjectV2Field { id name dataType }
          ... on ProjectV2SingleSelectField { id name options { id name } }
          ... on ProjectV2IterationField { id name configuration { duration startDay iterations { title startDate } } }
        }
      }
      repositories(first: 20) { nodes { nameWithOwner } }
      workflows(first: 20) { nodes { name enabled } }
    }
  }
}'
```

Board columns are the view's `verticalGroupByFields`; `groupByFields` is the row grouping of a table.

## Check the target

```bash
gh api graphql -f query='
{
  repository(owner: "<org>", name: "<repo>") { projectsV2(first: 20) { nodes { number title } } }
  organization(login: "<org>") { viewerCanCreateProjects projectsV2 { totalCount } }
}'
```

## List board items with state and Status

```bash
gh api graphql -f query='
query($endCursor: String) {
  organization(login: "<org>") {
    projectV2(number: <new-n>) {
      items(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          content {
            ... on Issue {
              number title state
              labels(first: 10) { nodes { name } }
              comments(last: 5) { nodes { body } }
            }
          }
        }
      }
    }
  }
}' --paginate
```

`gh api --paginate` only advances a GraphQL query whose cursor variable is named `$endCursor`.

Group by `status.name` for the final report. `state` finds closed items (move to Done or Won't do).
`comments(last: 5)` lets you find the latest triage comment (it starts with the AI disclaimer) even
when a later human reply follows it.

## Count issues

```bash
gh api graphql -f query='
{
  repository(owner: "<org>", name: "<repo>") {
    open: issues(states: OPEN) { totalCount }
    closed: issues(states: CLOSED) { totalCount }
  }
}'
```
