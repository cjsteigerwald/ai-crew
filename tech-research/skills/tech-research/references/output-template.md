# Output Template Reference

Detail for research artifacts: the readable document and its evidence
sidecar. Read this before drafting Phase 4/5 output.

## Table of Contents

1. Research document structure and skeleton
2. Positions section format
3. Dissent log format
4. Evidence sidecar
5. MLA 9 citation forms
6. Bidirectional citation check
7. Confidence reporting

## 1. Research document structure

Sections, in order, one paragraph each on what belongs there:

**Frontmatter.** `type: research`, `status` (`draft | final | superseded | incomplete`),
`tags` (array; `research` plus each domain slug), `updated`, `domain` (array,
primary first), `depth` (the depth gate this run used, per SKILL.md),
`review-by` (when this document's conclusions should be re-checked, distinct
from any single register note's `review-by`).

**Incomplete-run banner.** A run abandoned before Phase 5 completes and the
rebuttal-judge rules on surviving objections leaves an artifact that carries
tiered evidence, citations, confidence labels, and a polished sidecar —
every visual marker of rigor, with none of the adversarial testing that
earns them. That is worse than no research at all, because it looks
finished. Any document that has not completed Phase 5 and received a
rebuttal-judge ruling MUST set `status: incomplete` in frontmatter AND carry
a banner at the very top of the body, immediately under the title, naming
exactly which phases did not run. Omit the banner entirely once the run
completes.

**Decision frame.** What the user asked, restated as what the question
turned out to actually be once interrogated — often narrower or differently
shaped than the opening ask — plus the axes real answers vary along (cost,
timeline, reversibility, team capability). The contract for everything that
follows: if this is wrong, the rest answers the wrong question.

**What we already knew.** Phase 0's internal-sweep output — active register
constraints and decisions pulled in at the start — stated plainly so the
reader isn't sent back to the register to know what was already settled.

**Framing challenges.** The framing-challenger's attack on the candidate
set and the question framing, dispatched before any gathering lane in Phase
2, and its disposition — each challenge accepted (framing or candidate set
changed as a result) or rejected (with the reason it was rejected).

**Positions (2-4).** See section 2. Distinct bets, not distinct vendors of
the same bet.

**Dissent log.** Always present, even empty. See section 3.

**Surviving adversarial objections.** Phase 5 is three steps:
`research-adversarial` raises objections, the orchestrator writes rebuttals,
and `research-rebuttal-judge` rules on which objections survived — the
orchestrator does not score its own rebuttals. First-class body content,
never an appendix. State the objection, who raised it, the orchestrator's
rebuttal, and the judge's verdict for why it survived.

**Implementation steps.** For whichever position the user picks, a concrete
step list, each step linked to the source that justifies it (a Works Cited
entry or a register note).

**Open constraints still unresolved.** Constraints or open-questions the
research could not close, cross-linked to their register notes, with what
would resolve each (mirrors `resolves-with` where one exists).

**Scope ledger.** Every adjacent question surfaced during the run and its
disposition: pulled in, spun out as a separate question, or parked with a
one-line reason.

**What we did not check.** Explicit, not implied — named gaps in coverage:
sources not consulted, angles not interrogated, cutoffs hit.

**Provenance block.** Date, model, subagents run, depth gate used, every
query issued (or a pointer to the sidecar's complete log), and which
register notes were active inputs.

**Sealed prior vs conclusion.** Links to both sealed priors
(`prior-initial`, recorded before the internal sweep; `prior-post-sweep`,
recorded at Phase 1 exit). For every material point where the conclusion
agrees with either prior, name the specific independently-gathered sources
that support it — agreement without independent support is exactly what
this section exists to catch. Required whether or not the conclusion
agrees with the priors.

**Capture self-audit.** The 18-row checklist from `references/anti-capture.md`,
reproduced with a pass/fail and a short note per row.

**Recommendation.** Only present if explicitly requested, under its own
heading, written so it can be deleted without damaging the rest — the
positions must stand alone.

**Works Cited.** Alphabetical, hanging indent, MLA 9. See section 5.

Copyable skeleton:

```markdown
---
type: research
status: draft
tags: [research, <domain-slug>]
updated: YYYY-MM-DD
domain: [<primary-domain>, <other-domains>]
depth: <depth-gate-value>
review-by: YYYY-MM-DD
---

# <Research Question, As Refined>

> **INCOMPLETE.** Phases not run: <list>. (Omit this banner entirely once
> Phase 5 has completed and received a rebuttal-judge ruling; set
> `status: incomplete` above for as long as this banner is present.)

## Decision Frame
What the question turned out to actually be. The axes of variation: ...

## What We Already Knew
- [register-note-slug](../../register/<primary-domain>/register-note-slug.md) — one-line restatement.

## Framing Challenges
- <Challenge to the candidate set or question framing>, raised by the
  framing-challenger. Accepted (framing/candidate set changed: ...) / Rejected
  because: ...

## Positions

### Position A — <name>
Optimizes for: ...
Forecloses: ...
Would have to be true: ...
Cost of being wrong: ...
Reversibility: ...

### Position B — <name>
...

## Dissent Log
(See section 3 format. State explicitly if empty.)

## Surviving Adversarial Objections
- <Objection>, raised by <reviewer>. Rebuttal: ... Judge's verdict: survived
  because: ...

## Implementation Steps (for the chosen position)
1. Step, justified by (<Author Year>) / [register-note-slug](../../register/<primary-domain>/register-note-slug.md).

## Open Constraints Still Unresolved
- <Constraint>, resolved by: <evidence needed>. See [open-question-slug](../../register/<primary-domain>/open-question-slug.md).

## Scope Ledger
- <Adjacent question> — pulled in / spun out / parked, because: ...

## What We Did Not Check
- <Named gap>.

## Provenance
- Date: YYYY-MM-DD
- Model: <model>
- Subagents run: <list>
- Depth gate: <value>
- Queries issued: see `<basename> — Evidence.md`
- Register notes active as inputs: [note-slug](../../register/<primary-domain>/note-slug.md), ...

## Sealed Prior vs Conclusion
- `prior-initial`: <link to run-state file>. Agrees / disagrees on: ...,
  supported by: (<Author Year>), ...
- `prior-post-sweep`: <link to run-state file>. Agrees / disagrees on: ...,
  supported by: (<Author Year>), ...

## Capture Self-Audit
The 18-row checklist from `references/anti-capture.md`, pass/fail plus a
short note per row.

| # | Check | Pass/Fail | Note |
|---|---|---|---|
| 1 | ... | ... | ... |

## Recommendation
(Omit entirely unless explicitly requested.)

## Works Cited
Author. "Title of Page." *Site Name*, Publisher, Date, URL. Accessed DD Mon. YYYY.
```

## 2. Positions section format

Each position states five things: what it optimizes for; what it forecloses
(the option it gives up, not just the thing it gains); what would have to be
true about the world for it to be the right call; what it costs to be wrong
(recoverable expense vs. structural damage); and its reversibility (cheap to
reverse, expensive, or one-way door).

State explicitly where reasonable engineers diverge on this question and why
— which of the five axes above is actually contested, not manufactured
disagreement for the sake of having multiple positions.

**Distinctness test.** Positions must be different bets, not different
vendors placing the same bet. If two positions share the same answer on all
five axes above, they are one position wearing two labels — collapse them or
find the real second bet.

Example 1 — cosmetically distinct, actually identical: "adopt Vendor X's
managed queue" vs. "adopt Vendor Y's managed queue." Both outsource
operational risk, cost the same way, foreclose customization, reverse the
same way. Not a real second bet. Genuinely distinct replacement: "managed
hosted queue — outsource ops risk, recurring cost, cheap to reverse" vs.
"self-hosted open-source queue — own ops risk, no recurring cost, gains
customization, expensive to reverse (migrating off it is a project)."

Example 2 — cosmetically distinct, actually identical: "migrate everything
now" vs. "migrate everything in Q3." Same bet (full migration), differing
only in timing. Genuinely distinct replacement: "full migration — single
cutover, risk concentrated in one window, faster payoff, one-way door once
cut over" vs. "strangler-fig incremental migration — lower risk per step,
slower payoff, dual-run cost, each step independently reversible."

## 3. Dissent log format

Records every point where evidence contradicted the user's stated
expectation, where the user pushed back on a finding, or where the user
declined to accept a finding. One entry per point, with the source that
produced the contradicting evidence:

```markdown
| Date | User's prior / expectation | Evidence found | Resolution | Source |
|---|---|---|---|---|
| YYYY-MM-DD | What the user expected or asserted | What the evidence showed instead | Accepted / pushed back / declined | (Author Year) |
```

Rules: never omit the log; never move it to an appendix; never summarize away
the specific contradiction. If empty, say so explicitly rather than deleting
the heading, and treat it as a WARNING SIGN, not a clean bill of health —
state which is believed and why: the research genuinely confirmed priors on
independent evidence, or the run was captured (evidence-gathering steered
toward confirming what was already believed). See `anti-capture.md` for what
capture looks like and how to check for it first.

## 4. The evidence sidecar

Same folder as the research document, filename is the same basename plus
` — Evidence.md` (an em dash, with spaces on both sides, before the suffix).
It is a separate file, not inlined, because inlining a full evidence table
and query log into the readable document makes the document unreadable and
nobody reads past it to the positions.

Sidecar skeleton:

```markdown
---
type: research-evidence
status: draft
tags: [research, evidence, <domain-slug>]
updated: YYYY-MM-DD
domain: [<primary-domain>]
---

# Evidence — <Research Question>

## Claim Table
| Claim | Label | Tier | Source URL | Works-Cited Key | Locator | Publication Date | Access Date | Confidence | Funding Disclosure |
|---|---|---|---|---|---|---|---|---|---|
| <Claim as stated in main doc> | DOCUMENTED/OBSERVED/INFERRED | T1 | https://example.com/... | <Author Year> | URL section or doc section | YYYY-MM-DD | YYYY-MM-DD | HIGH/MEDIUM/LOW | none / vendor-funded / self-published by interested party |

## Query Log
| Subagent | Query Text | Date Issued | Tool |
|---|---|---|---|
| <name> | <exact query string> | YYYY-MM-DD | <search tool / API> |
```

**Label**, one of:
- `DOCUMENTED` — a source states it.
- `OBSERVED` — we ran or measured it ourselves.
- `INFERRED` — we reasoned to it; no source states it directly.

The claim table is keyed to the SAME Works Cited entries as the main
document — `Works-Cited Key` holds the exact in-text parenthetical key
(`<Author Year>`) so every row's source resolves to a specific entry there,
and every Works Cited entry consequential enough to matter should have a
row here. This is the field the bidirectional check (section 6) actually
matches on. Source tiers T0-T4 are defined in `source-tiers.md`; do not
redefine them here.

## 5. MLA 9 citation forms

Works Cited: alphabetical by author (or corporate author, or title if
neither exists), hanging indent. Every consequential claim in the body gets
an in-text parenthetical.

**Web and technical sources:**
```
Author. "Title of Page." *Site Name*, Publisher, Date, URL. Accessed DD Mon. YYYY.
```
Filled examples:
```
Example Corp. "Platform Pricing Overview." Example Corp Docs, Example Corp, 14 Jan. 2026, example.com/pricing. Accessed 3 Sep. 2026.

Doe, Jane. "Benchmarking Queue Throughput at Scale." Example Engineering Blog, Example Corp, 2 Mar. 2026, blog.example.com/queue-benchmarks. Accessed 3 Sep. 2026.
```

Technical docs usually have no personal author — use the corporate author
(company or org name) or lead with the title. NEVER invent an author to fill
the slot: an absent author is itself informative (it may signal marketing
copy over an engineering source) and inventing one destroys that signal.

Always include the Accessed date — technical sources change under their
URLs, and it is often the only thing making a claim checkable later.

**GitHub issues, PRs, commits** — cite by repository, number, and date; put
the commit SHA in the sidecar's `locator` field, not in the Works Cited
entry itself:
```
Example-Org/example-repo. "Fix race condition in connection pool." Pull Request #482, GitHub, 9 Feb. 2026. Accessed 3 Sep. 2026.

Example-Org/example-repo. Issue #117, GitHub, 20 Nov. 2025. Accessed 3 Sep. 2026.
```

## 6. Bidirectional citation check

Run before finalizing output. Checklist:

- [ ] Every Works Cited entry has at least one in-text parenthetical
      referencing it somewhere in the body.
- [ ] Every in-text parenthetical resolves to exactly one Works Cited entry.
- [ ] Every Works Cited entry has a matching row in the sidecar's claim
      table.
- [ ] Every sidecar claim-table row's Works-Cited Key resolves to an entry
      in Works Cited.
- [ ] No Works Cited entry has an invented author.
- [ ] No claim-table row is missing an Accessed date.
- [ ] "Sealed Prior vs Conclusion" is present, links both priors, and names
      independent sources for every point of agreement.
- [ ] "Capture Self-Audit" is present with a pass/fail and note on all 12
      rows.

## 7. Confidence reporting

Never state a confidence level without meeting its rubric definition:

- **HIGH** — 3+ independent non-T4 sources, no unresolved contradictions,
  primary source within 12 months or verified current.
- **MEDIUM** — 2 independent non-T4 sources, or 3+ with a minor unresolved
  conflict.
- **LOW** — single source, contested evidence, stale primary source, or
  heavy inference.

The document's overall confidence is capped at the LOWEST confidence of any
load-bearing claim — not an average. A claim is load-bearing if removing it
or reversing its finding would change which position is defensible, change
a cost or reversibility estimate materially, or invalidate an
implementation step. Cosmetic or background claims (context, history,
definitions) do not count even at LOW confidence. Identify load-bearing
claims by tracing each position's "would have to be true" statement back to
the claims that support it — those are load-bearing by construction.
