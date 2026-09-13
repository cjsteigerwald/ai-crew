# Source Tiers

## Table of Contents

1. [The Tier Rubric](#the-tier-rubric)
2. [Inversion Rules](#inversion-rules)
3. [Provenance and Sponsorship Checks](#provenance-and-sponsorship-checks)
4. [Independence Test](#independence-test)
5. [Recency Rules](#recency-rules)
6. [Claim Labeling](#claim-labeling)
7. [The Two-Source Minimum](#the-two-source-minimum)

Cross-references: [anti-capture.md](./anti-capture.md), [register-schema.md](./register-schema.md).

## The Tier Rubric

Five tiers, ranked by default reliability for grounding a claim. The ranking is a default, not a law — see [Inversion Rules](#inversion-rules) for when it flips.

### T0 — Internal

Searched first, always, before any external gathering begins. A decision already recorded in the register, or an incident already written up as an artifact, outranks anything external on the question of "what do we already know."

Qualifies:
- Register notes and research artifacts under the research root (crew config key `research_root`, default `~/Research`).
- Our own ADRs, postmortems, and incident writeups, when captured as a note or artifact in `<research_root>`.
- Prior evaluation notes and decisions captured as a durable file in `<research_root>`.

Does not qualify:
- A vendor's public docs merely linked from a register note or artifact — that link is a pointer, not the source; tier the linked document on its own terms.
- A note that quotes a vendor blog post verbatim — tier the quote at its origin, tier only the surrounding internal commentary as T0.
- A note describing a system since replaced is still T0 as a historical record, but flag it as superseded rather than current.

**Scope on this machine.** The T0 sweep reaches the `<research_root>` tree only — there is no Confluence, Jira, Atlassian MCP, or work-repo clone this sweep can search. Report T0 coverage as PARTIAL in the provenance block whenever a fuller internal record (a wiki, an issue tracker, an institutional decision) plausibly exists outside this machine, and cap confidence accordingly rather than treating a thin or empty `<research_root>` sweep as a clean internal record.

Verification: confirm the artifact lives in `<research_root>` and reflects this organization's own decision, configuration, or experience — not a copy-paste of external material. When a note mixes internal commentary with pasted external content, split the tiering: internal framing is T0, pasted content is tiered at its origin.

Worked example, correct: a register note stating "we chose X over Y in 2024 because of latency requirement Z" is T0 — a record of our own decision and constraints.

Worked example, incorrect: treating a register note titled "Vendor X overview" as T0 when its body is a pasted-in vendor datasheet. The datasheet is T1 (or T4 if marketing copy) — the internal wrapper does not upgrade what it wraps.

### T1 — Primary Vendor

Qualifies:
- Official docs, API references, release notes, changelogs.
- Published pricing pages, status and incident history pages.
- SDK source code published by the vendor, official migration guides, terms of service and SLAs.

Does not qualify:
- Vendor blog posts framed as technical content but written to persuade ("Why Company X is the future of Y") — T4 regardless of technical vocabulary.
- A third-party tutorial hosted under a "community" or "guest post" section of the vendor's docs site — check byline and ownership, not domain.
- A vendor's claim about a COMPETITOR's product — never T1 for the competitor, it is T4 marketing about someone else.

Verification: confirm the page sits under the vendor's own documentation or reference domain/repo, is not a sponsored placement, and describes current behavior rather than roadmap or aspirational positioning ("coming soon" is not "exists"). A pricing page is T1 only if it is the live, current page — a cached or secondhand quote of pricing inherits the tier of whoever quoted it, not T1.

Worked example, correct: the vendor's public API reference documenting a rate limit is T1 evidence for "does this endpoint have a rate limit."

Worked example, incorrect: citing a vendor's "Customer Success Story" landing page as T1 evidence of a technical capability — it is marketing (T4) even though it lives on the docs domain and reads like a technical writeup.

### T2 — Behavioral Ground Truth

Qualifies:
- Source code, vendor's or a dependency's.
- GitHub issues and pull requests with concrete reproduction or resolution.
- Formal specs and RFCs that were actually adopted.
- Public incident writeups, including third-party postmortems of an outage.
- Independent benchmarks run by a party with no stake in the result.

Does not qualify:
- A GitHub issue whose only comment is the vendor's marketing account restating the docs — T1 at best, not new behavioral evidence.
- A benchmark published by a vendor or a company selling a competing product — a sponsored benchmark, tiered per the provenance rules below (often T4 for corroboration purposes even though it looks like ground truth).
- An RFC that was proposed but never adopted — tier as a proposal, not as evidence of current behavior.

Verification: for issues and PRs, confirm they show actual reported behavior, reproduction steps, or maintainer responses — not bare feature requests or drive-by comments. For benchmarks, run the provenance check before accepting T2 status; only an unfunded, methodology-transparent benchmark by a neutral party earns T2.

Worked example, correct: a closed GitHub issue showing a reproducible bug, the maintainer's diagnosis, and the fix commit is T2 — ground truth about actual behavior, independent of vendor claims about the same feature.

Worked example, incorrect: treating an open, unconfirmed issue with a single unverified report and no maintainer response as settled T2 evidence of a defect — it is a single-source, LOW-confidence signal, not established behavior.

### T3 — Operator Experience

Qualifies:
- Engineering blog posts from people who run the system in production, not sell it.
- Conference talks by practitioners on a non-sponsored track.
- Peer-reviewed papers.
- Detailed "postmortem of adopting X" writeups from independent teams, including migration retrospectives.

Does not qualify:
- A vendor employee's post describing "how we use our own product internally" — T1/T4 vendor voice, not independent operator experience, regardless of candor or technical depth.
- A conference talk sponsored by the vendor, or delivered by vendor staff on the vendor's own track.
- A "case study" co-written with the vendor's developer-relations team, even under a customer's byline.

Verification: confirm the author's employer has no commercial stake in the product's success — not the vendor, not a reseller, not a consultant currently engaged by the vendor. Check bio and employer, and search the author's name alongside the vendor's name for undisclosed consulting relationships.

Worked example, correct: an SRE at an unrelated company writing "six months running X in production: what broke and what we'd do differently" is T3.

Worked example, incorrect: a "customer" blog post co-authored with vendor developer-relations staff, published on the vendor's own blog under a customer's name. This is vendor content wearing a customer's byline — verify authorship AND publication venue together, since either alone can mislead.

### T4 — Weak

Qualifies:
- Vendor marketing copy.
- Analyst summaries and quadrant/wave reports.
- Listicle comparisons ("Top 10 X tools").
- Undated tutorials and SEO content-farm articles.
- Most "X vs Y" comparison pages and vendor-produced "state of the industry" reports.

Does not qualify for exclusion: T4 sources remain useful for discovery — finding candidate vendors, terminology, or leads to chase into higher tiers. The rule constrains what they can be the BASIS for, not whether they may be read or used to seed a search.

Verification: if a source's primary purpose is to persuade a reader to buy, adopt, or rank something, or it has no identifiable author, date, or methodology, it is T4 by default regardless of surface polish or technical vocabulary.

Worked example, correct: a "2024 Market Guide" from an analyst firm with no disclosed methodology, funded via vendor briefing fees, is T4.

Worked example, incorrect: discarding a T4 source entirely instead of using it to identify which vendors, claims, or search terms to verify in T1-T3 sources. T4 sources are legitimate leads and illegitimate proof — the error is treating them as neither, or as both.

## Inversion Rules

The default ranking (T0 > T1 > T2 > T3 > T4) governs which source to trust FIRST when sources conflict, in general. For specific question shapes it does not hold, and applying it anyway is a recurring failure mode. State the inversion explicitly in the register when it applies, with a one-line justification.

**"Does feature X exist" -> T1 wins.** The vendor's current docs are the authoritative statement of what the product does today. T2/T3 sources may be stale — a feature existed in an old version and was removed, or doesn't yet exist despite a roadmap post someone wrote about.
Failure example: citing a two-year-old conference talk claiming "X doesn't support Y" when current T1 docs show Y shipped since. The stale T3 source loses to current T1 on existence questions.

**"Does it hold up under load" -> T2/T3 win.** Vendor docs describe intended or designed behavior, not verified behavior under stress; only independent benchmarks, incident writeups, and operator reports show what actually happens.
Failure example: taking a vendor's stated "99.99% uptime" figure (T1) as evidence of load behavior instead of seeking T2 incident data or T3 operator reports of degradation under real traffic.

**"Is it still maintained" -> commit and release recency beats all prose.** A living changelog or commit history outranks any narrative claim about project health, no matter how recent that narrative is.
Failure example: accepting an 8-month-old T3 blog post asserting "actively maintained" over checking the actual commit and release timeline, which may show the project has since gone quiet.

**"What will it cost us" -> T1 pricing plus T3 operator reports, flag the gap.** List pricing (T1) is necessary but frequently understates real cost — overage tiers, mandatory support add-ons, migration effort, seat minimums. T3 operator writeups of actual bills are the corrective.
Rule: always report both the T1 list figure and the T3 real-world figure, with the delta stated explicitly, never the list price alone.

**"Is the vendor solvent / will it exist in three years" -> T2 and independent trade press beat T1 and T4.** Vendor-published claims of stability and analyst "leader" placements (often paid) are the least reliable inputs to this question. Prefer funding round data, disclosed layoffs, and for open-source-backed products, the health of the underlying open-source project independent of the commercial entity.

**"How hard is migration off it" -> T3 operator postmortems and T2 export-completeness evidence beat T1.** Vendor migration guides describe migrating IN; the vendor has no incentive to document exit friction, and rarely does.
Failure example: relying on a vendor's "easy migration" marketing page as evidence of low switching cost when no independent source has actually attempted an exit.

**"What is the security track record" -> T2 beats T1 marketing and T4 scorecards.** CVE databases, public incident disclosures, and security advisories outrank a vendor's "secure by design" page and any analyst security scorecard with undisclosed methodology. A vendor's security page is T1 for stated controls, not for track record; track record is measured by disclosed incidents and their handling, not stated intent.

## Provenance and Sponsorship Checks

For every benchmark, analyst report, case study, or comparison, identify who funded, ran, or commissioned it before assigning a tier — provenance is checked before tiering, not after.

What to look for:
- An explicit funding or sponsorship statement, often in small print at the top or bottom of the piece.
- "In partnership with," "sponsored by," or "commissioned by" language.
- An analyst firm's disclosed client list, or a "this report was commissioned by [vendor]" footnote.
- The author's employer, checked via bio, LinkedIn, or an "about the author" section.
- Which organization owns a benchmark's GitHub repo — the vendor, a competitor, or genuinely neutral.
- Conference track sponsorship — a talk on a "Vendor X Track" is vendor content regardless of who delivers it.

Where it hides: methodology appendices, footnotes and "disclosures" pages linked but not shown inline with the claim, terms-of-service pages for the report itself, the copyright holder named in the page footer, and commit history or org ownership on GitHub rather than the README's stated intent.

When funding cannot be determined: say so explicitly in the register entry (`funding disclosure: undetermined`) and treat the source as T4 for corroboration purposes — it can inform discovery but cannot satisfy the two-source minimum.

Hard rule: vendor-run benchmarks and vendor-sponsored analyst content are labeled inline wherever cited (e.g., "vendor-sponsored benchmark") and CANNOT satisfy the two-source minimum on any claim about that vendor, no matter how many such sources are stacked. Two vendor-funded benchmarks are still one source's worth of evidence, not two, because they share a funder.

## Independence Test

Two sources are independent only if they share none of: author, employer, funder, or upstream source. Before counting a second source toward the two-source minimum, check all four explicitly — never assume independence from surface differences like outlet name or publication date.

Procedure:
1. Identify the byline or author for each source.
2. Identify the author's employer for each.
3. Identify who funded or commissioned each, using the provenance procedure above.
4. Trace each source's claims back one hop — did either cite the other, or do both cite a common upstream document (a press release, a single benchmark, a single vendor statement)?

Common trap: two news outlets or blogs, different bylines and outlets, both restating one vendor press release, appear independent on the surface but collapse to a single source once traced to the shared press release. Treat this as one source, tiered at the press release's actual tier (usually T4), not as two sources satisfying the minimum.

## Recency Rules

Flag any source over 12 months old when the question concerns a fast-moving area: pricing, feature set, performance characteristics, maintenance status, or security posture. Attempt to locate the current equivalent before relying on the stale source. If the current equivalent confirms the stale claim, cite the current source and note continuity in the register. If it contradicts, the current source wins per the inversion rules above — recency of the artifact, not nominal tier, decides.

Establishing a publication date when the page shows none:
- Check the page's git history if it is a documentation site backed by a public repo.
- Check the Wayback Machine for the earliest capture and infer a window from surrounding captures.
- Cross-reference a changelog or release-notes entry that introduced the described feature or behavior.
- Inspect HTTP response headers (`Last-Modified`, `Date`) via a direct fetch when accessible.
- Check for an RSS feed or sitemap `lastmod` entry associated with the page.

When it genuinely cannot be established: say so explicitly in the register (`publication date: undetermined`) and treat the source as maximally stale for purposes of the recency flag — never assume freshness in the absence of evidence, and never silently drop the flag because a date could not be found.

## Claim Labeling

Every claim in the register carries exactly one of three labels, chosen by how it was established, not by how confident it feels.

**DOCUMENTED** — a source explicitly states the claim. Requires a locator (page, section, line, or timestamp) pointing to the exact statement, not merely to the document as a whole.

**OBSERVED** — the research process itself ran, measured, or reproduced the claim (an agent fetched an endpoint and recorded the actual response, or reproduced a reported bug). Requires the observation method and the exact result to be recorded alongside the claim, so a reader can distinguish "we saw this happen" from "someone told us this happens."

**INFERRED** — the claim was reasoned to from other evidence, not stated or observed directly (for example, "the release cadence implies an actively maintained project," inferred from commit frequency rather than any statement of maintenance status). Requires the inference chain to be stated explicitly, not left implicit.

Each label is carried in the register as an explicit `label` field on the claim's evidence record, never left implicit in prose. The full evidence record contract is nine fields:

```
claim | label | tier | source URL | locator | publication date | access date | confidence | funding disclosure
```

The `label` field is what makes this section's rule operative rather than aspirational: without a field to hold DOCUMENTED / OBSERVED / INFERRED, the distinction above has nowhere to live and cannot be checked later.

Rule: INFERRED claims can never be rated HIGH confidence, regardless of how many sources feed the inference. Inference introduces a reasoning step that direct documentation or observation does not carry, and that step caps the confidence ceiling at MEDIUM even when the underlying evidence is otherwise strong.

## The Two-Source Minimum

Exact scope: applies to any claim that drives a decision or a cost estimate — any claim appearing in the Positions phase (Phase 4) as a reason to prefer one option over another, and any number used in a cost or effort comparison. Claims used only for background color or discovery do not require it, but should still be labeled by tier so the evidentiary gap remains visible to the reader.

Composition: the two sources must pass the independence test above, and neither may be T4. A T4 source may supplement discovery but never substitutes for one of the two required non-T4 sources — three T4 sources still do not clear the bar.

**Carve-out.** A single T1 primary vendor document MAY support HIGH confidence for a pure existence, signature, quota, or documented-limit claim about that vendor's own product — the vendor is definitionally authoritative on what its own API does. This carve-out does NOT extend to performance, reliability, cost-in-practice, or maintenance claims, where the vendor's own statement is an interested one and the two-source minimum stands in full. This narrows the general rule that a single source scores LOW confidence — it does not weaken the two-source minimum above for decision-driving or cost claims, which still requires two independent non-T4 sources regardless of how authoritative the single source is.

Absolute rule: never state a version number, limit, quota, price, or API signature from model memory. Fetch the current value from a live source, or mark it `UNVERIFIED` in the register and in any output that surfaces it. Memory-recalled specifics are a leading cause of confidently wrong decision inputs, and are treated as unsourced regardless of how plausible or precise they sound.
