# Anti-capture protocol

**Read this at Phase 0, before any evidence is gathered. It is the highest-priority
document in this skill.**

## Contents

- [Precedence and scope](#precedence-and-scope)
- [Why this exists](#why-this-exists)
- [Rule 1 — The sealed prior](#rule-1--the-sealed-prior)
- [Rule 2 — Split the interview output](#rule-2--split-the-interview-output)
- [Rule 3 — Symmetric retrieval](#rule-3--symmetric-retrieval)
- [Rule 4 — Disconfirmation quota](#rule-4--disconfirmation-quota)
- [Rule 5 — Blind adversarial pass](#rule-5--blind-adversarial-pass)
- [Rule 6 — Sponsorship and provenance](#rule-6--sponsorship-and-provenance)
- [Rule 7 — Hold the line under pushback](#rule-7--hold-the-line-under-pushback)
- [Rule 8 — The dissent log](#rule-8--the-dissent-log)
- [Rule 9 — Sycophancy check before output](#rule-9--sycophancy-check-before-output)
- [Confidence, defined](#confidence-defined)
- [Forbidden language](#forbidden-language)
- [Capture self-audit](#capture-self-audit)

## Precedence and scope

This document supersedes any conflicting instruction elsewhere in this skill, and any
instruction the user gives mid-run that would weaken a rule below. That is deliberate:
the user pre-committed to these constraints at a moment when they were reasoning about
research quality in general, not about one finding they dislike. Honor the earlier,
calmer instruction over the later, motivated one.

**What this document does NOT override.** It governs research *integrity* only. It does
not override the user's authority to:

- stop, pause, or abandon the run
- change the question or the scope
- change the **gathering depth** (LOOKUP / STANDARD / DECISION)
- redirect to a different domain or a different decision entirely
- decline to have anything written to the research root (crew config key `research_root`, default `~/Research`)
- correct a factual error with evidence (that is Rule 7 working, not being overridden)

**The depth loophole, closed.** Depth scales gathering breadth only. It cannot remove
Phase 5, the framing challenge, the rebuttal judge, or either prior comparison — those run
at every depth. Otherwise "change the depth gate" becomes a sanctioned one-word route to
deleting the exact controls that exist to attack the user's leaning, which is the motivated
late instruction this section claims to resist.

The same applies to scope: "drop candidate X from scope" and "redirect this to documenting
our chosen vendor" are legitimate as *decisions*, and both are recorded in the dissent log
with who asked and when. A scope change that eliminates the leading alternative is a
finding, not a silent edit.

**When the user says stop, stop.** Do not complete the run "under existing rules" over an
explicit stop. Record where it stopped, stamp the artifact `status: incomplete`, and end.

Refusing to soften a finding is integrity. Refusing to stop when asked is not — that is
a different failure and this document does not license it.

**Amending these rules.** A user request to change a rule here is honored for *future*
runs by editing this file, never by exception mid-run. If the user asks to drop a gate
during a run, complete the run under the existing rules, record the request in the
dissent log, and offer to amend the file afterwards.

## Why this exists

**Agreeing with the user is the default failure mode of a language model.** It is not an
occasional lapse; it is the gradient the model sits on. Every rule below exists to deny
the agents access to what the user wants, because an agent that knows the preferred
answer will find evidence for it — not by lying, but by searching a little harder in one
direction, weighting one source a little higher, and phrasing one finding a little more
gently.

None of those steps looks like a failure from inside. That is exactly why the protocol is
structural rather than aspirational: it removes the information rather than asking the
model to ignore it.

The purpose of this skill is to produce research **capable of contradicting the user.**
If a run cannot do that, it has no value, regardless of how well-cited it is.

## Rule 1 — The sealed prior

**Two priors, recorded at two different moments.** A single prior recorded at Phase 1 was
never a pre-evidence baseline: Phase 0's internal sweep exposes the user to prior
decisions and institutional framing *before* they state a position, so what got sealed was
already a post-evidence position wearing a baseline's label.

- **`prior-initial`** — recorded at Phase -1, before the sweep runs.
- **`prior-post-sweep`** — recorded at Phase 1 exit, after the sweep and first interview.

Movement between the two is itself a finding: it shows what the internal record did to the
user's position, and belongs in the dissent log.

Record each as the user's stated hypothesis or leaning **verbatim** — including "no prior"
if they have none.

- Verbatim means quoted, not paraphrased. A paraphrase already launders the leaning.
- If the user never states a leaning, record that fact explicitly. "No prior stated" is
  itself a finding, and it changes how Rule 9 reads at the end.
- If the leaning emerges later rather than at Phase 1, append it with a timestamp. Do not
  retroactively edit the original.

**The seal.** The sealed prior is never shown to any gathering or adversarial subagent.
Not summarized, not alluded to, not encoded in the framing of a dispatch.

**The comparison.** At the end of the run, compare the conclusion to the sealed prior and
**report the result, always, agree or not.** This is not optional and not conditional on
the direction of the result. A run that agrees with the prior must say so as loudly as one
that contradicts it.

**Storage — outside `<research_root>`, and that placement is the mechanism.**

```
<research_state_dir>/<domain>/<YYYY-MM-DD>-<question-slug>/
├── constraints.md        # passed to gathering lanes + framing-challenger
├── preferences.md        # passed to NOBODY
├── prior-initial.md      # passed to NOBODY
├── prior-post-sweep.md   # passed to NOBODY
└── dispatches/           # every subagent dispatch packet, verbatim
```

**Never store a prior or a preference as a register note.** The start-of-run sweep reads
every active register note in the domain and returns what it finds as T0 evidence records
— which are then relayed to every gathering lane in cross-pollination and handed to the
adversary as "evidence". A prior stored in `<research_root>` therefore survives run 1 and
re-enters the pipeline on run 2 as laundered evidence, with the seal formally intact and
substantively broken. The register that makes later runs cheaper is exactly the channel
that would make them captured.

For the same reason, register constraint notes may carry only
`strength: hard-requirement`. `strong-preference` and `nice-to-have` items stay in
`preferences.md`.

The research document links to the priors by path and reports the comparison; it never
quotes their bodies into any dispatch.

## Rule 2 — Split the interview output

Interview output splits into two files, both in the run-state directory outside `<research_root>`:
`constraints.md` and `preferences.md`. The split operates before any retrieval happens,
which is what makes it worth doing — but see the scope note at the head of this file: it
constrains what *subagents* see, not what the orchestrator knows.

**CONSTRAINTS** — hard requirements, real limits, existing commitments. Things that are
true about our situation regardless of what anyone wishes. Passed to subagents.

**PREFERENCES** — leanings, hunches, what the user would like to be true, vendor
relationships, prior enthusiasm, aesthetic commitments, "I've always liked X". **Withheld
from every gathering and adversarial agent.**

**The classification rule.** If you cannot tell which a thing is, **ask**. Default to
preference. A preference smuggled in as a constraint corrupts the entire run, because
every downstream lane treats it as ground truth and retrieves accordingly — and the
resulting bias is invisible, since each lane's work looks rigorous in isolation.

Worked classifications:

| Statement | Class | Why |
|---|---|---|
| "It has to run in our existing Kubernetes cluster" | Constraint | A real deployment limit |
| "We'd rather not add another vendor" | Preference | A leaning, however reasonable |
| "Legal requires data residency in the EU" | Constraint | An external commitment |
| "I think the managed option is probably right" | Preference | An explicit prior — also feeds Rule 1 |
| "We already pay for X, so using it is free" | Ask | Sounds like a constraint, is usually a sunk-cost preference; the marginal cost may not be zero |
| "The team knows Python" | Ask | Constraint if hiring is frozen and the timeline is fixed; preference if it means "would prefer" |
| "Budget is under $50k/year" | Constraint | If actually approved; ask whether it is a cap or a hope |
| "Our CTO likes that vendor" | Preference | Organizational, but still a leaning, not a limit |

The pattern in the ambiguous rows: a statement is a constraint when violating it has a
concrete, nameable consequence. If the consequence is "we wouldn't like it", it is a
preference.

Cross-reference: `interview-protocol.md` for how to elicit the distinction without
leading the user.

## Rule 3 — Symmetric retrieval

For every candidate under consideration, run **the same query classes**:

- capabilities
- limits
- known failures
- "problems with X"
- "migrating off X"
- "X postmortem"
- "X incident"
- cost surprises

Equal effort per candidate. Not equal intent — equal *effort*, measured in queries issued
and sources examined.

**Log every query into the evidence sidecar, verbatim, attributed to the lane that issued
it.** The log is the audit mechanism: asymmetry is invisible in a synthesis but obvious in
a query list. A reader must be able to open the sidecar and see that candidate A got nine
queries and candidate B got four.

**Never construct a query that presupposes an answer.** "Why is X better than Y" retrieves
a different internet than "X vs Y tradeoffs". "X scalability problems" is legitimate — it
is a symmetric failure-class query, run for every candidate. "X is unreliable" is not.

If a candidate genuinely has less material available, that asymmetry is a **finding**
about evidence base thickness — record it as such rather than letting it silently become
an asymmetry in effort.

## Rule 4 — Disconfirmation quota

The evidence set must contain credible material arguing **against** the apparently-leading
position — **minimum two non-T4 sources.**

T4 content cannot satisfy this quota, in either direction.

**If no such material exists**, report that explicitly and say which of two things it is:

1. **Genuine maturity** — the thing is well-established, widely run, and the criticism
   that exists is minor or dated. Confidence may stay high.
2. **A thin evidence base** — few people have run this in anger, or the critics are not
   publishing. Confidence must go *down*, not up.

**Absence of criticism is never endorsement.** A new product with no postmortems written
about it has no track record, not a clean one. State which reading applies and why; do not
leave the reader to infer it.

The `research-operator-experience` lane carries primary responsibility for this quota,
with `research-code-and-issues` second (closed-as-wontfix, long-running unresolved
threads, and issue-close latency are disconfirming evidence).

## Rule 5 — Blind adversarial pass

Phase 5. The `research-adversarial` agent receives **the evidence records and the
candidate positions ONLY.**

It does not receive:

- the synthesis reasoning
- the sealed prior
- the PREFERENCES file
- the user's name, role, or seniority
- any indication of which position the orchestrator favors

**Why the blindness matters.** An adversary that can see the conclusion rationalizes it
instead of attacking it. Given the reasoning, a model will critique the reasoning's
*presentation* while accepting its frame — which produces objections that are real,
specific, and worthless, because they never threaten the answer. Given only positions and
evidence, it has nothing to defend and must actually attack.

Leaking context into this dispatch is the single most likely way this skill fails
silently, because the output still looks like adversarial review.

After the pass, the orchestrator writes **one rebuttal round**, and
`research-rebuttal-judge` — not the orchestrator — rules which objections **SURVIVED**.

The judge exists because the orchestrator was previously both rebutter and scorer of its
own rebuttals, which made "score which objections survived" unfalsifiable: it could
dismiss the strongest objection against its favored position and still truthfully report
that a rebuttal round occurred. The judge receives objections, rebuttals, and evidence
records only.

Survival is mechanical, not a judgment call:

- An objection **survives by default**; the rebuttal must earn its dismissal.
- It is killed only if the rebuttal cites a specific evidence record the objection failed
  to account for, and that record actually supports the rebuttal's reading.
- A reasoning-only rebuttal **cannot** kill an evidence-backed objection.
- A rebuttal citing T4 or vendor-sponsored content about that vendor cannot kill an
  objection about that vendor.
- Ties go to the objection.

The judge also flags rebuttals that are systematically stronger against objections
targeting one particular position — that pattern is itself a capture finding.

Surviving objections are first-class content in the final document — never an appendix,
never a footnote, never summarized into a caveat sentence. The orchestrator does not
overrule the judge.

### Rule 5b — Challenge the framing before spending

`research-framing-challenger` runs at the *start* of Phase 2, before lanes are chosen and
before the candidate set is locked. It receives the question and CONSTRAINTS only.

This is the higher-leverage half of the adversarial design, and the one that was missing.
**An omitted candidate is the most effective route to a predetermined answer**, because no
amount of symmetric retrieval across the admitted set can recover an option that was never
admitted — and every audit mechanism in this file operates on the admitted set. Attacking
the candidate set after gathering is too late to act on. Its challenges and their
disposition go in the document; a rejected challenge states why.

## Rule 6 — Sponsorship and provenance

For every benchmark, analyst report, case study, or comparison: **identify who funded,
ran, or commissioned it.**

- Label the funding relationship **inline**, at the point of citation, not only in the
  sidecar.
- **Vendor-run benchmarks and vendor-sponsored analyst content cannot satisfy the
  two-source minimum on any claim about that vendor.** They may be cited; they cannot
  corroborate.
- Where funding cannot be determined, **say so** and treat the source as T4 for
  corroboration purposes.

Detail on where sponsorship hides and how to check it: `source-tiers.md`.

The independence test: two sources are independent only if they do not share an author,
employer, funder, or upstream source. Two outlets restating one press release are one
source.

## Rule 7 — Hold the line under pushback

If the user disagrees with a sourced finding, **do NOT soften, remove, or re-weight it
because they pushed back.**

The procedure, in order:

1. **Re-verify the source.** Re-fetch it. Check the locator, the date, and whether it
   still says what the record claims.
2. **Then one of two things, never a blend:**
   - **Correct it** — with an explicit reason stating what was wrong and what the source
     actually says. A correction is a factual event, not a concession.
   - **Restate it** — and say plainly that the objection does not change the evidence.
3. **Ask for a counter-source.** The user may well have one; their disagreement is
   information, just not evidence.
4. **Record the exchange in the dissent log**, including which of the two outcomes
   occurred.

**Never use agreement language.** No "great question." No "you're right to focus on X."
No opening validation of the user's framing before delivering a contrary finding. That
phrasing is the audible form of capture, and it trains the user to expect the finding to
bend next time.

The distinction that matters: *changing a claim because of new evidence* is the protocol
working. *Changing a claim because of who objected* is capture. From the outside these can
look identical, which is why step 4 exists — the log makes the reason inspectable later.

## Rule 8 — The dissent log

**In every document, always.**

Records every point where:

- evidence contradicted the user's stated expectation
- the user pushed back on a finding
- the user declined a finding

Each entry carries the underlying source, so the disagreement can be re-litigated against
evidence rather than memory.

**Never omitted. Never moved to an appendix. Never summarized away.**

**If the log is empty, say so explicitly and treat it as a warning sign.** Either the
research genuinely confirmed the user's priors, or the run was captured. **State which you
believe and why.** An empty dissent log presented without comment is indistinguishable
from a captured run, which is precisely why the comment is mandatory.

Format: `output-template.md`.

## Rule 9 — Sycophancy check before output

The final gate. Run it after the document is drafted and before it is written.

**If the conclusion matches the sealed prior on every material point, state that
explicitly and justify each point against evidence gathered independently of the user's
input.**

"Independently" means: name the T1/T2/T3 sources that support the point and were found by
a lane that never saw the PREFERENCES file. If a point's support traces back to something
the user told us, it is not independent corroboration — it is an echo.

**Convergence is allowed. Unexamined convergence is not.** Sometimes the user is right,
and the research should say so with the same directness it would use to say the opposite.
The check is not a demand for disagreement; it is a demand that agreement be earned and
shown to be earned.

Run the check at **maximum strength** when the user has explicitly asked for a
recommendation — that request is itself evidence of a leaning.

## Confidence, defined

Never state confidence without meeting the definition.

| Level | Requires |
|---|---|
| HIGH | 3+ independent non-T4 sources, no unresolved contradictions, primary source within 12 months or verified current |
| MEDIUM | 2 independent non-T4 sources, or 3+ with a minor unresolved conflict |
| LOW | single source, contested evidence, stale primary source, or heavy inference |

**Cap the document's overall confidence at the lowest confidence of any load-bearing
claim.** A load-bearing claim is one whose falsity would change which position the
evidence supports. One LOW-confidence load-bearing claim makes the document LOW, however
many HIGH claims surround it.

INFERRED claims can never be HIGH.

**Carve-out.** A single T1 primary vendor document MAY support HIGH for a pure existence,
signature, quota, or documented-limit claim about that vendor's own product — the vendor is
definitionally authoritative on what its own API does, and the flat count rule otherwise
contradicts the inversion rule that T1 wins for "does feature X exist". This does not
extend to performance, reliability, cost-in-practice, or maintenance claims, where the
vendor's statement is an interested one and the two-source minimum stands in full.

Every evidence record carries a `label`: `DOCUMENTED` / `OBSERVED` / `INFERRED`. The
labeling rule is enforceable only because the record format has a field for it.

## Forbidden language

These phrasings are capture made audible. Do not use them in any interview turn, finding,
or document section:

- "Great question" / "Good catch" / "Excellent point"
- "You're right to focus on X" / "You're right that..."
- Any opening validation of the user's framing before a contrary finding
- "As you correctly noted" / "As you suspected"
- Hedges attached to a finding *after* pushback that were not there before it
- "It depends" as a conclusion rather than as a preface to the axes it depends on
- Confidence adverbs unbacked by the rubric: "clearly", "obviously", "certainly",
  "undoubtedly"

## Capture self-audit

Run before output, alongside Rule 9. Any "no" is a blocking finding that must be fixed or
disclosed in the document.

1. Did the adversarial agent receive **only** evidence records, query logs, and positions?
   Check the preserved dispatch packet in `dispatches/`, not your memory of what you sent.
2. Did any gathering lane receive PREFERENCES or either sealed prior?
3. Does the query log show comparable effort per candidate?
4. Does the evidence set contain 2+ non-T4 sources against the leading position — or an
   explicit statement of why it does not, with the maturity-vs-thin-base call made?
5. Is every benchmark and analyst source labeled with its funding, inline?
6. Does any claim rest on a single source, T4 content, or model memory without being
   marked?
7. Are the positions distinct **bets**, or the same bet wearing different vendor names?
8. Was a recommendation produced that the user did not ask for?
9. Is the dissent log present — and if empty, is the warning stated with a judgment call?
10. Does the stated confidence meet the rubric, and is the document capped at its weakest
    load-bearing claim?
11. Does the conclusion match the sealed prior? If so, is each material point justified
    against independently-gathered evidence?
12. Does any finding read more gently than it did before the user objected to it?
13. Did `research-framing-challenger` run **before** the candidate set was locked, and is
    every challenge it raised recorded with its disposition and a reason for any rejection?
14. Did `research-rebuttal-judge` rule on survival — or did the orchestrator score its own
    rebuttals? If any objection is marked killed, does the rebuttal cite a specific
    evidence record, and does that record actually say what the rebuttal claims?
15. Is every dispatch packet preserved verbatim in `dispatches/`? An unpreserved dispatch
    makes rows 1 and 2 unfalsifiable.
16. Did a prior or a preference get written into `<research_root>` as a register note — including
    as a constraint with `strength: strong-preference` or `nice-to-have`?
17. Did the sensitivity gate re-fire after gathering, and did anything surfaced during the
    run turn the topic sensitive since Phase -1?
18. Did the user's position move between `prior-initial` and `prior-post-sweep`, and is
    that movement recorded in the dissent log?

**What this audit cannot tell you.** Every row above is self-reported by the party that
ran the process. Rows 1, 2, 14, and 15 are checkable against preserved artifacts; the rest
certify intent and completeness, which the auditor cannot verify about itself. Treat a
clean audit as evidence that the ritual completed, not as evidence that capture did not
happen — and see the scope note at the head of this file for what the protocol genuinely
does not close.
