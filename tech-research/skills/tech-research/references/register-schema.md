# Register Schema Reference

Detail for the register: per-domain constraint/decision/open-question notes
under `<research_root>/register/<domain>/` and `<research_root>/register/_shared/`. Read
this before creating, updating, or superseding any register note.

## Table of Contents

1. Frontmatter schema
2. Note body format and worked examples
3. Atomicity and naming
4. Domain routing
5. Supersession
6. Domain hub note (MOC)
7. Run lifecycle
8. First-run bootstrap

## 1. Frontmatter schema

The schema below is canonical. This is a fresh tree at the research root (crew config key
`research_root`, default `~/Research`) with no prior notes and no existing convention
to reconcile with — apply it as written.

`tags` on every register note includes `research`, the note's `type`, and each
`domain` slug. `last-confirmed` records the last time this skill re-verified
the claim, distinct from any edit to the file's wording. `domain`, `strength`,
`established-by`, `resolves-with`, `established`, `review-by` are the fields
specific to this schema; add as specified.

```yaml
---
type: constraint | decision | open-question | hub | index
domain: [domain-slug]
status: active | superseded | resolved | unknown
strength: hard-requirement
tags: [research, <type>, <domain-slug>]
established-by: ["../../artifacts/<domain>/research-doc-slug.md"]
resolves-with: What evidence would settle this. Open-question notes only.
established: YYYY-MM-DD
last-confirmed: YYYY-MM-DD
review-by: YYYY-MM-DD
---
```

| Field | Required/Optional | Allowed values | Meaning |
|---|---|---|---|
| `type` | Required | `constraint`, `decision`, `open-question`, `hub`, `index` | Kind of register note. |
| `domain` | Required | array of canonical slugs from `_domains.md` | Every domain this note governs; a constraint can span several. |
| `status` | Required | `active`, `superseded`, `resolved`, `unknown` | Lifecycle state. `resolved` is for open-questions; `superseded` is for constraints and decisions. |
| `strength` | Constraints only | `hard-requirement` (only) | How binding on future decisions. Omit elsewhere. Strong-preference and nice-to-have items are never register notes — see the warning below the field table. |
| `tags` | Required | array, free-form | Must include `research`, the `type` value, and every `domain` slug. |
| `established-by` | Required | array of relative markdown links | Research doc that established or last confirmed the claim, linked as a relative path from the register note, e.g. `../../artifacts/<domain>/doc-slug.md`. |
| `resolves-with` | Open-questions only | free text | Evidence, event, or decision that would close the question. Omit elsewhere. |
| `established` | Required | `YYYY-MM-DD` | Date first created. Immutable. |
| `last-confirmed` | Required | `YYYY-MM-DD` | Date a research run last re-verified this claim. Update on every touching run, even if unchanged. |
| `review-by` | Required | `YYYY-MM-DD` | Defaults to `established + 90 days`. Extend only alongside a `last-confirmed` update. |

**Warning — preferences and sealed priors are never register notes.** A register
constraint note may only carry `strength: hard-requirement`. Strong-preference and
nice-to-have items, and both sealed priors (`prior-initial`, `prior-post-sweep`),
belong in the run-state directory outside `<research_root>`
(`<research_state_dir>/<domain>/<YYYY-MM-DD>-<question-slug>/`) — never in
`<research_root>/register/`. The reason is structural, not stylistic: every run's Phase 0
sweep reads all active register notes as ground truth before gathering evidence. A
preference or a prior leaning persisted as a register note would be re-ingested by
the next run as if it were a settled fact, quietly laundering that run's bias into
this one.

## 2. Note body format

State the constraint, decision, or question in one or two sentences, then one
or two sentences on why it holds — the evidence or reasoning, not a
restatement. No headers needed for a single-claim note.

Worked example — constraint (`ci-pipeline-must-complete-under-10-minutes.md`):
```markdown
---
type: constraint
domain: [build-tooling]
status: active
strength: hard-requirement
tags: [research, constraint, build-tooling]
established-by: ["../../artifacts/build-tooling/ci-latency-investigation-2026-08.md"]
established: 2026-08-12
last-confirmed: 2026-08-12
review-by: 2026-11-10
---

The CI pipeline must complete in under 10 minutes end to end for a
single-service change. This threshold came from the platform team's incident
retro: pipelines over 10 minutes measurably increased merge-without-rebase
conflicts.
```

Worked example — decision (`adopted-vendor-a-for-log-aggregation.md`):
```markdown
---
type: decision
domain: [observability]
status: active
tags: [research, decision, observability]
established-by: ["../../artifacts/observability/log-aggregation-tradeoff-2026-07.md"]
established: 2026-07-20
last-confirmed: 2026-07-20
review-by: 2026-10-18
---

Adopted Vendor A's managed log aggregation service as the default for new
services, chosen over the self-hosted alternative because the team has no
on-call capacity to operate a stateful ingestion pipeline this year.
```

Worked example — open-question (`unresolved-cost-at-scale-for-vendor-b.md`):
```markdown
---
type: open-question
domain: [observability]
status: active
tags: [research, open-question, observability]
established-by: ["../../artifacts/observability/log-aggregation-tradeoff-2026-07.md"]
resolves-with: A quote from Vendor B at projected 12-month ingest volume, not the trial-tier price.
established: 2026-07-20
last-confirmed: 2026-07-20
review-by: 2026-10-18
---

Whether Vendor B's per-GB ingest pricing stays competitive past the trial tier
is unresolved. Every public number found so far describes the introductory
tier; none confirms sustained-volume pricing.
```

## 3. Atomicity and naming

One constraint, decision, or open-question per note — never bundle several
claims into one file, even if established in the same run.

Naming: kebab-case, subject then predicate, descriptive enough to identify the
claim without opening the file, no dates in the filename (dates live in
frontmatter), avoid generic words (`note`, `misc`, `general`).

Examples: `ci-pipeline-must-complete-under-10-minutes.md`,
`adopted-vendor-a-for-log-aggregation.md`,
`unresolved-cost-at-scale-for-vendor-b.md`,
`data-residency-requires-single-region-storage.md`,
`deprecated-legacy-queue-in-favor-of-vendor-c.md`.

## 4. Domain routing

`<research_root>/_domains.md` is a registry table of canonical domain slugs. Exact
copyable format:

```markdown
| Slug | Aliases | Scope | Established |
|---|---|---|---|
| observability | monitoring, telemetry, o11y | Tooling and practices for metrics, logs, traces, and alerting. | 2026-09-03 |
```

Per-run routing procedure:

a. Read `<research_root>/_domains.md` in full before doing anything else.
b. Match the question to an existing domain, checking `Aliases` as well as
   `Slug` — an alias match is a match.
c. On a match, state which domain and why (which slug or alias triggered it),
   then proceed using that domain's folder.
d. On an ambiguous match between two domains, stop and ask the user which one,
   showing both candidate rows and where register notes would land under each.
e. On no match, propose exactly one new canonical slug with a one-line scope
   description and get explicit confirmation before creating any folder. Once
   confirmed, add the row (slug, aliases, scope, established date) to
   `_domains.md` before writing any note into it.

Hard rules: never create a domain folder without confirmation; never create a
near-duplicate slug (check aliases too, not just slugs); when a question spans
domains, pick one primary domain for the artifact's location but tag every
register note with ALL applicable domains. Cross-cutting constraints go in
`<research_root>/register/_shared/`, not a domain folder.

## 5. Supersession

Never delete a superseded note. Set `status: superseded` and add a body line:
`Superseded by [replacement-note-slug](replacement-note-slug.md).`

Supersession propagates. Before finalizing:

1. Find backlinks (matches the target filename regardless of link text or
   relative path depth, since a relative markdown link's display text is
   independent of what it points to):
   ```
   grep -rln "old-note-slug\.md" <research_root>/
   ```
2. For every hit (excluding the note itself and the hub note, which is
   regenerated anyway), read enough to judge if its conclusion depended on
   the now-superseded claim.
3. Report to the user: the superseded note, its replacement, and every
   artifact whose conclusion may now be partly invalid. Do not silently edit
   those artifacts — let the user decide whether to re-open them.

## 6. Domain hub note (MOC)

One hub note per domain folder, materialized static lists only — no query
syntax of any kind.

**Why materialized lists, not a live query.** They are plain files that any
editor, `grep`, and `git` can read, with no plugin or application dependency.
A materialized list keeps working regardless of what tooling is installed,
shows a supersession as a readable line change, and is something an agent can
read with a plain file read instead of evaluating a query engine.

Table format: a two-column table, `Page` and `One line`, each row a relative
markdown link plus a one-line description — not a bullet list.

```markdown
---
type: hub
domain: [domain-slug]
---

# <Domain Name>

## Active constraints
_as of YYYY-MM-DD_

| Page | One line |
|---|---|
| [constraint-slug](constraint-slug.md) | One-line gloss of what it requires. |

## Open questions
_as of YYYY-MM-DD_

| Page | One line |
|---|---|
| [open-question-slug](open-question-slug.md) | One-line gloss of what is unresolved. |

## Prior decisions
_as of YYYY-MM-DD_

| Page | One line |
|---|---|
| [decision-slug](decision-slug.md) | One-line gloss of what was chosen and when. |

## Past review-by (stale)
_as of YYYY-MM-DD_

| Page | One line |
|---|---|
| [constraint-or-decision-slug](constraint-or-decision-slug.md) | review-by YYYY-MM-DD, now overdue. |
```

**Why every section carries its own `as of` stamp.** If a run aborts between
writing notes and regenerating the hub, a materialized list silently
under-reports — it looks complete but isn't. This is worst for Past
review-by: that section goes stale specifically in the direction of hiding
overdue constraints, not merely omitting a random one. A dated stamp on
each section declares its own possible staleness instead of quietly
asserting completeness it may no longer have.

Regeneration, run at the end of every research run touching this domain:

1. Enumerate every note file in the folder, excluding the hub note itself.
2. Read each note's frontmatter: `type`, `status`, `review-by`.
3. Sort: `active` constraints -> Active constraints; `active` open-questions
   -> Open questions; all decisions regardless of status -> Prior decisions
   (note supersession inline in the gloss); any `active` note past its
   `review-by` -> also listed in Past review-by.
4. Rewrite each section's list from scratch — do not append. Stale leftovers
   mean a prior regeneration was skipped.
5. Set every section's `as of` stamp to today's date, even sections whose
   contents did not change.

## 7. Run lifecycle

Start of every run: read the domain hub note, every active register note in
that domain, and every note in `<research_root>/register/_shared/`. Tell the user
what is already held as constraints, decisions, and open questions BEFORE
asking the first interview question.

End of every run: create notes for what was established; mark invalidated
notes `status: superseded`, link the replacement, and run section 5's
propagation; update `last-confirmed` (and `review-by` if re-verified) on
constraints the research confirmed unchanged; regenerate the hub note (section
6); show the user a diff of every note to be created, edited, or superseded
BEFORE writing it.

## 8. First-run bootstrap

`<research_root>/_domains.md` and `<research_root>/register/_shared/` do not exist yet
on this machine. Bootstrap once, after explicit user confirmation:

1. Confirm with the user before creating anything.
2. Create `<research_root>/_domains.md`, header only, no data rows:
   ```markdown
   # Research Domains

   | Slug | Aliases | Scope | Established |
   |---|---|---|---|
   ```
3. Create the directory `<research_root>/register/_shared/`, empty.
4. Proceed to normal domain routing (section 4) for the current question,
   proposing the first real domain row.
