---
name: authoring-incident-docs
description: >
  Produces the three post-investigation artifacts for a repo's incident-docs
  layout — a root cause analysis, findings, and a runbook — with correct file
  placement, naming, severity tier, metadata headers, and section structure.
  Use when an investigation has concluded and needs writing up, when the user
  says "write the RCA", "create rca, runbook and findings", "document this
  incident", or "turn this into a finding". Skip when the investigation itself
  is still running (use investigating-incidents, which invokes this skill at
  its artifact gate) and when editing an unrelated document that merely
  mentions an incident.
---

# Authoring incident docs

Produces root cause analysis (RCA), findings, and runbooks meeting a repo's incident-docs standards: correct tier, placement, metadata, section structure, and evidence labelling.

## When to Use This Skill

- Investigation has concluded and needs artifact write-up.
- User says "write the RCA", "create rca, runbook and findings", "document this incident", "turn this into a finding".
- Post-incident review or recurrence discovery requires new or amended documentation.

## When *Not* to Use This Skill

- Investigation is still active — use [[investigating-incidents]], which invokes this skill at artifact gate.
- Editing an unrelated document that merely mentions an incident.
- The incident is still running; await resolution before writing.

## The incident-docs layout

This skill assumes the default layout — `rca/sev{1-4}/` for root cause analyses, `findings/` for
findings, `runbooks/` for runbooks, all under the repo root. **This is configurable**: if the repo's
own instructions file documents a different layout, follow that instead and treat every path below
as the default, not a hard requirement.

## Which artifact

| Artifact | Purpose | Decision |
|----------|---------|----------|
| **RCA** | Document one specific incident that happened: incident date, timeline, root cause, resolution. One per incident. | File in `rca/sev{1-4}/` (or the repo's configured equivalent) with incident date in filename. **A recurrence gets its own RCA** — each incident has its own date and timeline, and its own ticket when one is tracked. Name the prior RCA in the executive summary ("recurrence of `<file>`"). Do not append the new incident's timeline or recurrence history to the prior RCA — that history accumulates on the *finding*. Correcting a prior RCA is still allowed and expected: factual fixes, credential redaction, and broken-link repair. |
| **Finding** | Document a systemic gap or risk discovered, independent of whether the incident recurs. May be zero or many per investigation. | File in `findings/` (or the repo's configured equivalent). Check that directory first — if a finding of the same gap exists, append recurrence record instead of creating a second one. |
| **Runbook** | Reusable procedure for the next operator hitting this failure class. Written only when the procedure generalizes beyond this incident. | File in `runbooks/` (or the repo's configured equivalent) with no date prefix. Check that directory first — extend existing runbook of that failure class rather than creating a near-duplicate. |

## Severity tier

**The tracker ticket is authoritative.** Derive the tier from the ticket's Priority
field; do not judge it independently when a ticket carries one.

The priority scheme itself — valid names, ids, and any repo-specific quirks (e.g. standard names
like `High` being rejected) — lives wherever this repo documents its tracker conventions. Do not
duplicate it here. This skill owns only the mapping from priority to tier:

| Ticket priority | Tier |
|---|---|
| `(P1) Show Stopper` | `rca/sev1/` |
| `(P2) Critical` | `rca/sev2/` |
| `(P3) Major` | `rca/sev3/` |
| `(P4) Minor` | `rca/sev4/` |
| `(P5) Trivial` | `rca/sev4/` |

Cite the derivation in the severity line so it is auditable:
`**Severity:** Sev3 (from PROJ-123 priority `(P3) Major`; <one-line impact>)`

**When priority is `None` or `TBD`** — `None` is the instance default, so an
untriaged ticket lands there. Do not silently infer a tier around it. If your
tracker convention requires incidents to carry a real priority, propose one to
the user, set it on the ticket, then derive the tier from it. Fixing the
ticket is the correct move; inferring around it leaves the ticket wrong for
everyone else.

**Only when no ticket exists at all**, tier by impact and label it inferred:

- **Sev1** — external partner or customer-facing data delivery failed
- **Sev2** — caller-visible errors or an outage window; multi-environment or multi-service
- **Sev3** — internal-only impact, recovered automatically, no data loss; or an escalating recurring pattern
- **Sev4** — single job or component failure, no data loss, contained blast radius

If an inferred tier disagrees with an existing ticket priority, raise the
mismatch with the user rather than overriding either.

**Gotcha**: Existing files are often inconsistent — some sev4 files write
`**Severity:** Low` instead of `Sev4`, and some incidents were filed a tier above
what their ticket priority implies. Always write `**Severity:** SevN`, and derive
from the ticket, never from a neighbouring file's precedent.

## File placement and naming

| Artifact | Directory | Filename | H1 |
|----------|-----------|----------|-----|
| RCA | `rca/sev{1-4}/` | `YYYY-MM-DD-kebab-slug.md` | `# Root Cause Analysis: <incident>` |
| Finding | `findings/` | `YYYY-MM-DD-kebab-slug.md` | `# Finding: <gap>` |
| Runbook | `runbooks/` | `kebab-slug.md` (no date) | `# <Topic> Runbook` |

(Substitute the repo's own directory names if it overrides the default layout above.)

## Metadata header block

⛔ **Before drafting an RCA: the root-cause conclusion needs an adversarial pass.** Per this plugin's
README § Review policy, this is unconditional, and it must happen *before* the document
exists. If you were invoked directly ("write the RCA") rather than through `[[investigating-incidents]]`
Gate 7a, check whether that pass ran — if it did not, **run it before drafting**. This gate is
unconditional: a decline does not satisfy it, and "the user asked me to just write it" is not an
exemption. If the pass genuinely cannot run (no Codex tooling), say so explicitly and record
`**Conclusion pass:** not run — <reason>` under `## Root Cause`, so the absence is visible rather than
looking like a verdict nobody bothered to write down.

Bolded metadata lines follow H1 immediately, before any prose.

**RCA (required)**:
- `**Ticket:**` — always first; markdown hyperlink to the tracker issue, or `**Ticket:** none — <reason>` if untracked.
- `**Incident Date:**`
- `**Environment:**`
- `**Severity:**` — write `SevN`, not `Low`/`High`.
- `**Status:**` — e.g. `Resolved`, `Monitoring`.

**Finding (required)**:
- `**Ticket:**` — always first; markdown hyperlink to the tracker issue, or `none — <reason>`.
- `**Date:**` — discovery date.
- `**Severity:**` — `SevN`.
- `**Status:**` — e.g. `Open`, `Mitigated`.
- `**Affected Resource:**` — system, component, or asset.

**Runbook**: No metadata block; environment details go inside `## Overview`.

## Section structure

### RCA

Ordered list of `##` headings:

1. `## Executive Summary` (required) — one paragraph, reader knows impact and resolution in 30s.
2. `## Incident Timeline` (required) — table in local time, zone labelled; a parallel UTC column is optional.
3. `## Impact Assessment` (required) — data loss, blast radius, duration, affected users/systems.
4. `## Root Cause` (required) — the single causal event that triggered the incident. Record the conclusion-refutation verdict here beside the claim: model, date, and whether the conclusion was upheld or revised (`[[investigating-incidents]]` Gate 7a).
5. `## Contributing Factors` (required) — conditions that enabled the root cause.
6. `## Resolution` (required) — actions taken to stop the incident.
7. `## Action Items` (required) — follow-up tasks with owners.
8. `## References` (required) — links to related RCAs, findings, code commits, dashboards.
9. `## Lessons Learned` (optional).

### Finding

Ordered list of `##` headings:

1. `## Summary` (required) — one paragraph; the gap, its scope, why it matters.
2. `## Evidence` (required) — factual claims labelled as Proven live, Inspected only, or Not established.
3. `## Risk Assessment` (required) — likelihood of recurrence, potential impact.
4. `## Recommendation` (required) — remediation or detection approach.
5. `## References` (required) — RCAs citing this finding, related findings, code, docs.
6. `## Update/Recurrence` (optional, appended when finding recurs) — date, ticket, new evidence.

### Runbook

Ordered list of `##` headings:

1. `## Overview` (required) — failure class, trigger scenarios, environment scope.
2. `## Symptoms` (required) — observable signals; error messages, metrics, logs.
3. `## Quick Diagnosis` (required) — one-person decision tree; reach the root in under 5min.
4. `## Remediation` (required) — step-by-step procedure; include rollback.
5. `## References` (required) — links to dashboards, logs, related runbooks, findings.
6. `## Prevention` (optional) — architectural or operational safeguards.

## Evidence labelling

Every factual claim carries one of three labels; separate visibly (subsection or explicit prefix, not mixed into prose):

- **Proven live** — a command was run against the real environment; name the command or tool.
- **Inspected only** — read from repo, config, doc, or design spec; states intent, not reality.
- **Not established** — could not be determined; state why (access denied, no logs, no metric).

**Principle**: Repo files state intent. Only the environment states truth.

## Timezone

All times in artifacts use one consistent local zone, labelled explicitly, converted from whatever UTC the cloud APIs return. Label the zone explicitly in timeline tables:

```
| Time (local) | Time (UTC) | Event |
|---|---|---|
| 2026-08-23 10:15 MDT | 2026-08-23 16:15 UTC | Alert fired |
```

## Before committing

- [ ] Every relative link resolves: run the repo's link checker (e.g. `python3 scripts/check-doc-links.py`) from the repo root; it must exit 0. Do not substitute a `grep` for link-shaped text — that matches the syntax without resolving the target and passes broken links.
- [ ] No secret VALUES appear; variable names (e.g. `$KEY_VAULT_NAME`) are fine.
- [ ] Commit subject starts with the ticket key (e.g. `PROJ-123: Document incident`) — **or**, where no ticket applies, carries no key and the PR body records why (below).
- [ ] PR body opens with `**Ticket:** [link]` as the first line — **or** `**Ticket:** none — <reason>`, which is a first-class outcome, not a failure. Silence on that first line is the failure.
- [ ] `## Root Cause` carries the conclusion-refutation verdict, or an explicit `**Conclusion pass:** not run — <reason>`.
- [ ] Severity tier matches the rule, not precedent.
- [ ] H1 matches the filename slug.

## References

- [[investigating-incidents]] — invokes this skill at artifact gate.
- [[opening-pull-requests]] — PR workflow for landing artifacts.
- Corpora: `rca/`, `findings/`, `runbooks/` (or the repo's configured equivalent) — match patterns and section structure.
