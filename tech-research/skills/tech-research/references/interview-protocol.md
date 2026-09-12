# Interview Protocol

## Table of Contents

1. [Universal Question Rules](#universal-question-rules)
2. [Question Quality Bar](#question-quality-bar)
3. [Phase 1 Specifics — First Interview](#phase-1-specifics--first-interview)
4. [The CONSTRAINTS / PREFERENCES Split](#the-constraints--preferences-split)
5. [Phase 3 Specifics — Second Interview](#phase-3-specifics--second-interview)
6. [Forbidden Interview Behaviours](#forbidden-interview-behaviours)

Cross-references: [anti-capture.md](./anti-capture.md), [register-schema.md](./register-schema.md).

Governs both interview passes (Phase 1 and Phase 3). The interview is the mechanism by which a vague ask becomes a bounded, evidence-checkable decision — treat every question as spending part of a limited budget, not as small talk.

## Universal Question Rules

**One question at a time.** Never present a questionnaire. Batching corrupts the result two ways: the user answers cheaply and generically because nothing forces them to think through any single question in isolation, and later questions cannot build on earlier answers because none of the earlier answers were actually absorbed before the next was asked. Ask, wait for the answer, then decide the next question based on that answer — the next question is chosen AFTER hearing the previous one, not pre-planned as a batch.

**Always offer 2-4 candidate answers, each with what it implies downstream.** Never ask a bare open question. A candidate-answer list does two things a bare question cannot: it shows the user the shape of the decision space so they don't have to construct one from nothing, and it lets them correct a wrong candidate rather than free-associate. State the downstream implication of each candidate inline, in the same message as the question — not as a follow-up after the user answers.

**"I don't know" is always a valid answer, and is recorded, not treated as a blocker.** Procedure:
1. Log an OPEN QUESTION register entry naming what evidence would resolve it.
2. Offer a best guess with explicit reasoning for the record, so downstream work has something to proceed on.
3. Move on to the next question immediately.
Never stall on a single question, and never re-ask the same question reworded hoping for a different answer — that reads as not having listened, and burns the question budget for no gain.

**Surface considerations the user has not raised, when the register or general knowledge suggests they matter.** Exact phrasing pattern: "You haven't mentioned X — here's why it may decide this: [reason]." State the reason before asking whether it applies; never ask "have you considered X" with no justification attached, which forces the user to guess why it might matter before they can even answer.

**Distinguish hard requirements, strong preferences, and nice-to-haves — ask which, never infer.** A user stating a criterion does not by itself say how load-bearing it is; the same sentence ("it should support SSO") could be either a dealbreaker or a mild wish. Ask directly: "is that a hard requirement, a strong preference, or a nice-to-have if we get it?" and file the answer accordingly.

**Cap at roughly 5-8 questions per pass.** Depth over volume: a pass that asks three sharp, sequential questions and stops once the exit-gate content is populated beats one that pads to eight for its own sake. If the cap is reached and material gaps remain, log them as OPEN QUESTIONS rather than exceeding the cap.

### Worked Example — One Exchange, Correctly Sequenced

Question asked: "Which describes the budget reality: (a) a hard ceiling already set by finance, (b) a soft target we can exceed with a strong justification, (c) genuinely open until we see options?"

User answers: "(b), soft target, around $30k/year."

What the answer licenses next: because the answer was (b) and not (a), the following question can probe how much justification would be needed to exceed it, rather than pruning options outright:

Next question asked: "If an option at $45k/year were clearly the best technical fit, which would justify that gap to you: (a) meaningfully lower ongoing engineering effort, (b) materially better reliability track record, (c) neither — treat $30k as effectively hard unless we ask again explicitly?"

This is the batching failure avoided: a front-loaded questionnaire would have asked both questions at once, before the user's first answer revealed that a follow-up on justification even applied. Asking (c) as a live option also respects the "I don't know is valid" rule by giving the user an explicit way to say the soft target should be treated as hard for now.

## Question Quality Bar

Weak questions produce vague, unfalsifiable answers that cannot discriminate between options later. Sharpen every question before asking it, using this bar.

**Weak:** "What matters most to you in a solution?"
Why weak: unbounded, invites a generic answer ("reliability and cost"), gives the user nothing concrete to react to.
**Strong:** "Rank these three in priority order for this decision: (a) lowest ongoing operating cost even if it means more engineering effort to run, (b) lowest engineering effort to run even at higher cost, (c) fastest time to first production use even if it costs more to operate long-term. Each ordering points to a different shortlist."

**Weak:** "Do you have a budget?"
Why weak: yes/no framing collapses a continuous, decision-relevant variable into a non-answer.
**Strong:** "Which describes the budget reality: (a) a hard ceiling already set by finance, (b) a soft target we can exceed with a strong justification, (c) genuinely open until we see options. (a) prunes the shortlist immediately; (c) means cost comparisons should wait until Phase 4."

**Weak:** "How important is vendor lock-in to you?"
Why weak: "important" is not measurable, and the user cannot act on the answer they give.
**Strong:** "If switching away from this choice in two years would take (a) a weekend of config changes, (b) a quarter of migration work, or (c) a full rebuild — which of those would you still be comfortable choosing, given everything else being favorable? This sets the lock-in ceiling other criteria trade off against."

**Weak:** "What's your timeline?"
Why weak: produces a date with no attached consequence, so it cannot discriminate between options later.
**Strong:** "Which is true: (a) a hard external deadline exists and slipping it has a named cost, (b) there's a target date but slipping it is mildly annoying, (c) no real deadline, this is opportunistic. (a) rules out any option requiring a long ramp-up; (c) means depth of evaluation matters more than speed."

**Weak:** "Are you open to an open-source option?"
Why weak: binary framing hides the real variable, which is who bears support risk.
**Strong:** "If the strongest technical fit is open-source with no paid support tier, which describes your comfort level: (a) fine, we'll self-support, (b) fine only if a reputable third party offers paid support, (c) not acceptable, we need a vendor with a support contract. This determines whether self-hosted OSS options stay on the shortlist at all."

**Weak:** "Do you care about performance?"
Why weak: everyone says yes; it doesn't discriminate anything.
**Strong:** "Which failure mode would hurt more: (a) occasional slow responses under peak load, tolerable if rare, or (b) a hard capacity ceiling we'd hit and have to re-architect around. (a) points toward tuning existing options; (b) makes headroom a hard requirement, not a preference."

**Weak:** "Does it matter if the vendor is a small startup?"
Why weak: "matters" doesn't say what the user would actually do differently, so the answer changes nothing downstream.
**Strong:** "If the strongest fit is a small, recently-funded vendor, which is true: (a) fine, we'll design for an eventual switch and treat that cost as accepted, (b) fine only if there's a credible open-source or export path out, (c) not acceptable, we need an established vendor regardless of fit. This determines whether early-stage vendors stay on the shortlist at all, and feeds the solvency inversion in source-tiers.md."

## Phase 1 Specifics — First Interview

What Phase 1 extracts, in this order:
- **The real decision behind the stated one.** The stated ask is often a proxy for a narrower or broader question ("which database" may really be "how do we stop paging ourselves at 3am") — find which, and confirm it with the user rather than assuming.
- **Constraints already committed to.** Budget, timeline, existing infrastructure, compliance regime, team skills, prior contractual commitments — anything already fixed before this research begins.
- **The axes of variation that actually matter for this decision.** Not a generic checklist of every possible criterion — the specific handful that are live for THIS ask, surfaced by asking and by checking the register for prior related decisions.
- **What "good" would look like if the decision succeeds.** A concrete picture ("we ship this integration in a sprint and never think about it again") rather than a vague "it works well" — a concrete success picture is what later lets Phase 4 positions be checked against something real.

Exit gate — Phase 1 does not close until both of the following exist:
1. **`prior-post-sweep`, recorded verbatim**, including the literal statement "no prior" if the user has none. This is the SECOND of two sealed priors, not the only one. `prior-initial` is recorded earlier, at Phase -1, *before* the internal sweep runs — because Phase 0's internal sweep exposes the user to internal evidence and institutional framing, a prior recorded only after the sweep was never actually a pre-evidence baseline. `prior-post-sweep` captures the lean after the sweep and this first interview. Both priors are captured, then set aside — never passed to gathering or adversarial subagents (see [anti-capture.md](./anti-capture.md)) — and both are compared against the conclusion at the end of the run.
2. **The CONSTRAINTS and PREFERENCES split**, populated from everything surfaced in the interview, filed per the procedure below.

Do not proceed to Phase 2 gathering with either item missing or partially filled — an ungated Phase 1 propagates ambiguity into every subsequent phase.

**Storage for both priors.** `prior-initial.md` and `prior-post-sweep.md` are stored at `<research_state_dir>/<domain>/<YYYY-MM-DD>-<question-slug>/`, outside the research root (crew config key `research_root`, default `~/Research`), alongside `constraints.md` and `preferences.md` (see below). Neither prior file is ever passed to any subagent, gathering or adversarial.

## The CONSTRAINTS / PREFERENCES Split

**CONSTRAINTS** — hard requirements, real limits, and existing commitments. Passed to the four gathering lanes (`research-internal-sweep`, `research-vendor-docs`, `research-code-and-issues`, `research-operator-experience`) and to `research-framing-challenger`; these bound the search space and cannot be relaxed without going back to the user. CONSTRAINTS are never passed to `research-adversarial` or `research-rebuttal-judge` — see below.

**PREFERENCES** — leanings, hunches, what the user would like to be true, vendor relationships, prior enthusiasm. Withheld from every gathering and adversarial agent, without exception.

**What the two adversarial-stage agents receive instead.** `research-adversarial` receives **evidence records and candidate positions ONLY** — never CONSTRAINTS, never PREFERENCES, never the sealed prior. `research-rebuttal-judge` receives **objections, rebuttals, and evidence records ONLY** — also never CONSTRAINTS. Both agents judge the evidence on its own terms; handing either of them CONSTRAINTS would let the search-space boundary quietly become a thumb on the scale for or against a position.

Why a smuggled preference corrupts the run: subagents treat the constraints file as ground truth to search within. A preference disguised as a constraint gets treated as settled fact and steers every downstream search toward confirming it, which is precisely the capture this skill exists to prevent — the corruption is silent, since the subagent has no way to know the "constraint" it was handed was actually a hunch. See [anti-capture.md](./anti-capture.md) for the full mechanism.

**Where the two files live.** `constraints.md` and `preferences.md` are written to `<research_state_dir>/<domain>/<YYYY-MM-DD>-<question-slug>/` — the same run-state directory that holds both sealed priors — never into `<research_root>`, and never readable by the internal-sweep lane. `preferences.md` in particular is NEVER written into `<research_root>` and NEVER becomes a register note: the start-of-run sweep in Phase 0 reads every active register note in the domain, so a preference stored there would be re-ingested as evidence on the very next run and relayed to every lane, including the adversary — silently defeating the withholding this section exists to enforce.

**Strength gates what gets filed where.** An item classified `strong-preference` or `nice-to-have` goes in `preferences.md`, never the register, regardless of how firmly the user holds it — strength of feeling is not the same as being a constraint. Only items classified `hard-requirement` may become register constraint notes.

Classification procedure — primary test, authoritative, from [anti-capture.md](./anti-capture.md): a statement is a constraint when violating it has a **concrete, nameable consequence**. If the consequence reduces to "we wouldn't like it," it is a preference. Apply this test first, always.

Subordinate heuristic, useful for surfacing the answer to the primary test but never a substitute for it: ask "would violating this be a reason to reject an otherwise-excellent option outright, independent of who proposed it?" A "yes" here should always trace back to a nameable consequence — if it does not (the only reason is a vague discomfort with the option), the honest classification is still preference, regardless of how the heuristic question was answered. If the two ever appear to disagree, the primary test wins.

If it cannot be classified with confidence under the primary test, ASK the user directly rather than guess — and if the user's own answer is still ambiguous, default to preference: a wrongly-withheld constraint only costs a later correction, while a wrongly-passed preference costs the whole run's independence.

Worked examples:
- "It has to run in our existing Kubernetes cluster." -> Constraint (infrastructure commitment already made).
- "I've always liked how Company X does documentation." -> Preference (an aesthetic/brand lean, not a requirement).
- "We can't exceed a $50k/year budget, finance already signed off on that ceiling." -> Constraint (a real, externally enforced limit).
- "I'd rather not deal with another vendor relationship if we can avoid it." -> Preference (a leaning, not a rule — probe whether it hardens into "we will not sign a new vendor contract," which would be a constraint).
- "It must support SSO via our existing identity provider." -> Constraint (an integration requirement, testable and binary).
- "I have a good feeling about the open-source options." -> Preference (an unexamined lean — exactly what the sealed prior exists to capture and set aside).
- "Our compliance team requires SOC 2 Type II." -> Constraint (an externally imposed, non-negotiable requirement).
- "I'd like something that feels modern and well-designed." -> Preference (unmeasurable, subjective; if pressed the user may reveal a testable constraint underneath — ask what "modern" would actually mean in practice before filing).

## Phase 3 Specifics — Second Interview

Phase 3 is the important interview: it does not re-ask what Phase 1 already covered, it comes back with what the research CHANGED. Specifically:
- **Constraints the evidence revealed** that the user didn't know to specify — e.g., evidence shows the leading options all require a capability the user never mentioned needing.
- **Places where a stated requirement turns out to be unusually expensive, rare, or in tension with another stated requirement** — surface the tension explicitly and ask which side gives.
- **Tradeoffs that are now live decisions** because evidence has made two options genuinely close on the axes that matter.
- **Which Phase 1 OPEN QUESTIONS now matter** — evidence sharpened them into decision-relevant — **and which turned out moot** — evidence made them irrelevant regardless of the answer, so they can be closed without asking.

The same universal question rules apply in Phase 3: one at a time, candidate answers with implications, "I don't know" recorded not blocked, surface what the user hasn't raised, ask rather than infer hard/preference/nice-to-have status for anything new, cap at 5-8 questions.

Frame each Phase 3 question against the evidence that motivates it, not in the abstract: "the evidence shows [finding] — given that, which of these do you want: (a)... (b)... (c)..." This keeps the second pass grounded in what was actually learned rather than repeating Phase 1's structure with different words, and lets the user see exactly why their earlier answer is being revisited.

### Worked Example — Phase 3 Question Grounded in Evidence

Phase 1 recorded "SSO integration" as a hard requirement without further detail. Evidence gathering found that every option meeting the other constraints supports SSO only through a paid add-on tier, none through the base tier.

Question asked: "The evidence shows SSO support requires a paid add-on across every option that otherwise fits — the base-tier price comparisons from Phase 1 undercount actual cost. Given that, which do you want: (a) keep SSO as a hard requirement and compare fully-loaded prices including the add-on, (b) treat SSO as a phase-two rollout item and re-open the shortlist to base-tier-only options, (c) hold both open and see the fully-loaded comparison in Phase 4 before deciding?"

This is a Phase-3-shaped question, not a Phase-1 repeat: it exists only because the research surfaced a cost implication the user had no way to know when SSO was first filed as a constraint.

## Forbidden Interview Behaviours

**Agreement language.** "Great question," "you're right to focus on X," or any opening validation of the user's framing before evidence supports it. Failure mode: it signals the framing is already endorsed, which discourages the user from revising it even when later evidence contradicts it, and it spends the user's attention on flattery instead of substance. Instead: ask the next question with no preamble, or state the evidence-based reason a framing needs revisiting.

**Asking only about what the user raised.** Failure mode: any consideration the user didn't think to mention never enters the constraints/preferences split at all, and a materially relevant axis silently drops out of the whole research run with no record that it was ever missing. Instead: apply the "surface considerations not raised" rule from the universal question rules on every pass.

**Treating "I don't know" as a blocker.** Failure mode: stalling or re-asking in different words reads as not listening, burns the question budget, and delays the interview past its cap without producing anything the OPEN QUESTION register entry wouldn't have captured immediately. Instead: log it, offer a reasoned best guess, move on.

**Front-loading a questionnaire.** Failure mode: identical to violating "one question at a time" — cheap, generic answers, and no ability for later questions to build on earlier ones, but now for every question in the pass at once instead of just some. Instead: ask the single most decision-relevant question first and let the answer determine the next one.

**Leading questions that presuppose an answer.** E.g., "you'll want the option with the strongest ecosystem, right?" Failure mode: it manufactures agreement with an unstated assumption rather than surfacing the user's actual position, and the resulting answer cannot be trusted as evidence of what the user actually thinks. Instead: present the ecosystem tradeoff as one candidate among 2-4, with its downstream implication stated neutrally.

## Quick Reference

- One question, 2-4 candidates with implications, per turn — never a batch.
- "I don't know" -> OPEN QUESTION entry + reasoned guess + move on, never a stall.
- Surface unraised considerations with the "you haven't mentioned X, here's why" pattern.
- Ask hard/preference/nice-to-have explicitly; never infer it.
- Cap 5-8 questions per pass; log overflow as OPEN QUESTIONS instead of exceeding it.
- Phase 1 exit gate: `prior-post-sweep` verbatim (the second of two sealed priors, alongside `prior-initial` from Phase -1) + constraints/preferences split, both populated.
- Phase 3 questions are grounded in what the evidence changed, not a Phase 1 repeat.
- No agreement language, no leading questions, no questionnaires, ever.
