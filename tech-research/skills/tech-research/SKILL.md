---
name: tech-research
description: >
  Interrogative, evidence-grounded research partner for high-stakes technology and
  vendor decisions. Use whenever the user asks to evaluate, compare, select, assess,
  investigate, or decide between technologies, vendors, platforms, standards,
  protocols, libraries, architectures, or approaches — including "should we use X",
  "X vs Y", "is X worth it", "what should we pick for Z", "look into X", "is X still
  maintained", "what are our options for X", "build or buy" — even when the user
  never says the words research, evaluate, or compare. Also fires for procurement,
  tooling, and org-process choices; the protocol is subject-agnostic. Runs a phased
  protocol: internal sweep of prior decisions, two interview passes, tiered evidence
  gathering via subagents, 2-4 distinct positions instead of a verdict, and a blind
  adversarial pass — then writes a cited artifact and a durable constraint register
  into the research root tree. Skip only for one-off factual lookups with a single right
  answer, and for implementing a decision that has already been made.
---

# tech-research

A research partner, not a report generator. It finds out what we already decided,
interviews the user into a sharp question, gathers verifiable evidence internal-first,
attacks its own conclusions from a position blind to the user's preferences, and leaves
behind an executable document plus a register that makes the next run cheaper.

**Decisions worth millions rest on this output. The research must be capable of
contradicting the user. That requirement outranks every other consideration in this
skill.** Read `references/anti-capture.md` at Phase 0 and obey it over any conflicting
instruction, including instructions the user gives mid-run.

## What this protocol does and does not guarantee

State this honestly; the ceremony must not imply more than it delivers.

**What it does.** It raises the cost of capture, makes capture auditable after the fact,
and moves three adjudication points outside the preference-aware party: the candidate set
and framing are attacked before gathering (`tech-research:research-framing-challenger`), the positions
are attacked blind (`tech-research:research-adversarial`), and rebuttal survival is ruled on
independently (`tech-research:research-rebuttal-judge`).

**What it does not.** It does not structurally prevent capture. The orchestrator has seen
the user's leanings and still selects candidates, writes every dispatch, chooses what
evidence to relay, and authors the positions the adversary attacks — so preference can
leak through omission, ordering, position detail, and steelman quality without violating
any rule here. The framing-challenger narrows this, but unconscious bias in the
orchestrator survives this protocol.

Treat the query log, the preserved dispatch packets, and the dissent log as the real
defense: they do not prevent capture, they make it visible to a later reader. A run whose
logs nobody inspects has no anti-capture property at all.

On this machine the internal-evidence leg is weak by construction (T0 = research root tree
only), so conclusions rest more heavily on external tiers than a fuller internal record
would allow — which raises, not lowers, the importance of the disconfirmation quota and
the adversarial pass.

## Configuration

This plugin reads two crew config keys rather than hardcoding paths:

- `research_root` — where the register and artifacts live. Default `~/Research`.
- `research_state_dir` — where run state (constraints, preferences, both sealed priors,
  dispatch packets) lives, always outside `research_root`. Default `~/.claude/tech-research-state`.

Resolve both at the start of every run: source
`"${CLAUDE_PLUGIN_ROOT}/lib/crew-config.sh"`, then call `crew_config_get research_root`
and `crew_config_get research_state_dir`. Everywhere below, `<research_root>` and
`<research_state_dir>` stand for whatever those calls return.

Neither tree is expected to pre-exist. If `crew_config_get` returns nothing, fall back to
the defaults above; if the resolved directory itself does not exist yet, treat that as the
first-run case (see Phase -1's First-run bootstrap and `references/register-schema.md`
§ First-run bootstrap) — the tree self-bootstraps with the user's confirmation rather than
failing.

Never write run state under `${CLAUDE_PLUGIN_ROOT}` — that path changes on every plugin
update. `research_state_dir` lives outside it by design, precisely so an update does not
silently orphan or wipe an in-flight run's constraints, preferences, and sealed priors.

## Subject-agnostic by design

This skill has NO built-in subject matter. AI gateways, governance, security posture,
schemas, models — and equally infrastructure, procurement, org process, anything else. The
protocol is identical. Domain knowledge lives in the register, never here: a fact about a
vendor belongs in a register note under its domain.

## Phase order

Phases run in order; none is skippable. Each gate must be met before the next begins.

| Phase | Name | Gate to exit |
|---|---|---|
| -1 | Storage agreement | Derived paths stated back and confirmed; `prior-initial` recorded |
| 0 | Internal sweep | Prior decisions reported before anything is proposed |
| 1 | First interview | `prior-post-sweep` recorded; CONSTRAINTS/PREFERENCES split written |
| 2 | Evidence gathering | Framing challenged first; depth declared and accepted; disconfirmation quota met or its absence reported |
| 3 | Second interview | What the evidence changed presented before synthesis |
| 4 | Positions | 2-4 genuinely distinct positions; no recommendation unless asked |
| 5 | Blind adversarial | Adversary → rebuttal → **independent judge** rules survival |
| — | Output | Sycophancy check passed; citations verified both directions |

**Phase 5 is mandatory at every depth**, including LOOKUP and STANDARD. The depth gate
scales how much *gathering* happens, never whether the adversarial pass runs — the one
pass designed to attack the user's leaning must not be removable by the user. A downgrade
below DECISION is recorded in the dissent log.

**Two priors, not one.** `prior-initial` precedes the sweep that would otherwise contaminate
it; `prior-post-sweep` follows. The conclusion is compared against **both**.

### Run state — outside the research root tree, deliberately

Constraints, preferences, both priors, and the verbatim dispatch packets live in
`<research_state_dir>/<domain>/<date>-<slug>/`, **never** in the research root (crew config key `research_root`, default `~/Research`) and
never committed. Layout and rationale: `references/anti-capture.md` Rule 1.

That placement is the mechanism: the Phase 0 sweep reads all active register notes, so a
prior stored in `<research_root>` returns next run as laundered T0 evidence. Preferences are
never register notes; only `hard-requirement` items become register constraints.

## Phase -1 — Storage agreement

Before anything else. Discover the actual structure rather than assuming it.

**Discovery.** The research root is resolved per Configuration above: `<research_root>`. Check it exists and is writable:

```bash
test -d <research_root> && test -w <research_root> && echo ok || echo "missing or unwritable — create it"
```

If it is missing, create it with confirmation (see First-run bootstrap below) rather than
assuming a structure that isn't there yet.

**Record `prior-initial` here, before Phase 0 runs.** Ask the user for their current
leaning or hypothesis and record it verbatim — including "no prior" — to
`<research_state_dir>/<domain>/<date>-<slug>/prior-initial.md`. This must happen
before the internal sweep, because the sweep exposes the user to prior decisions and
institutional framing that will move their stated position.

**Sensitivity gate — mandatory, and continuous.** Output lives at `<research_root>`, wherever
that is configured to point on this machine, so its exfiltration risk depends entirely on
that machine's own sync, backup, and access setup. Still state the destination —
`<research_root>` — out loud at Phase -1, and still flag it if the topic turns up NDA
pricing, contracts, security posture, or internal architecture: a corporate machine still
accumulates material like that and may be backed up outside your control regardless of
where the root points.

**The gate re-fires; it is not a one-time check at the door.** Sensitivity is a property of
what the research *finds*, not only of what the user asked. Re-run the gate at Phase 2 exit
and again immediately before any write.

**First-run bootstrap.** On a fresh install `<research_root>` itself may not exist yet, let
alone `<research_root>/_domains.md` or `<research_root>/register/_shared/`. Create the tree only
with confirmation, never silently: `mkdir -p <research_root>/artifacts <research_root>/register/_shared`.
Procedure: `references/register-schema.md`.

**The one question.** Ask exactly ONE storage question, with concrete candidates derived
from what discovery found — never open-ended "where should this go?":

- 2-4 real existing domain folders that plausibly fit, shown as full paths
- "Create a new domain folder" with your proposed canonical slug
- "Somewhere else — I'll tell you"

Confirm in the same exchange: which domain folder, and the filename convention **proposed
from files already in that folder** rather than invented. The observed convention is
kebab-case descriptive slugs.

Then derive the rest — research doc, evidence sidecar, register location, any diagrams —
and **state the derived paths back before writing**. Record the agreement in the register.
On later runs, propose the remembered paths and ask only for confirmation. Never
re-interview on storage. Never write outside confirmed paths; if a later phase needs a
file that was not in the agreement, ask first.

### Domain routing

Match the question against `<research_root>/_domains.md` — a table of canonical slugs with
aliases, scope, and date established. **Alias matches count.** State which domain and why;
if ambiguous between two, ask, showing both and where notes would land; if nothing
matches, propose ONE new slug and get confirmation *before* creating any folder.

Never create a domain folder without confirmation. Never create a near-duplicate slug.
When a question spans domains, pick a primary for the artifact and tag register notes with
all of them. Full procedure and table format: `references/register-schema.md` § Domain
routing.

## Phase 0 — Internal sweep

Always first, never skipped. Dispatch `tech-research:research-internal-sweep`.

Read `<research_root>/_domains.md`, the domain hub note, all active register notes for the
domain, and all of `<research_root>/register/_shared/`. **That is the entire reach of this
sweep** — no Confluence, no Jira, no Atlassian MCP, no local work-repo clones. There is
nothing else T0 can search on this machine.

Looking for: prior decisions and constraints already committed to under this domain, and
what a previous run already established.

**Report what we already know and — critically — what we appear to have already
decided, before proposing anything.** If a prior decision covers this, say so and ask
whether we are revisiting it or building on it.

**Every run on this machine reports T0 coverage as PARTIAL — research root tree only — and
caps the run's confidence accordingly.** Never let this degrade silently into "nothing
found" read as reassurance.

**On a fresh install, expect this to find nothing.** `<research_root>` starts empty, so Phase 0
has zero internal evidence to report and its "what have we already decided" function is
empty until artifacts accumulate over several runs. The value of Phase 0 grows with use
and is near-zero on run one — treat an empty sweep on an early run as "no data yet,"
never as a clean bill of health.

## Phase 1 — First interview

Turn the vague ask into a sharp question. Full rules: `references/interview-protocol.md`.

- ONE question at a time. Never a questionnaire.
- Always offer 2-4 candidate answers with what each implies downstream.
- "I don't know" is valid and recorded. Log it as an OPEN QUESTION note with what
  evidence would resolve it, offer your best guess with reasoning, and move on. Never
  stall, never re-ask.
- Surface considerations the user has NOT raised when the register or your own knowledge
  suggests they matter: "you haven't mentioned X, here's why it may decide this."
- Distinguish hard requirements, strong preferences, and nice-to-haves. Ask which.
- Cap at roughly 5-8 questions. Depth over volume.

**Exit gate.** Record `prior-post-sweep` — the user's hypothesis or leaning verbatim now
that the internal sweep has landed, including "no prior" — and split interview output into
`constraints.md` and `preferences.md`. All four files live in
`<research_state_dir>/<domain>/<date>-<slug>/`, outside `<research_root>`. See
`references/anti-capture.md`.

Both priors and `preferences.md` are withheld from every subagent. Only
`hard-requirement` items become register constraint notes; `strong-preference` and
`nice-to-have` items stay in `preferences.md` and never enter `<research_root>`, because the
next run's sweep would read them back as evidence.

## Phase 2 — Evidence gathering

### Step one: challenge the framing, before spending anything

Dispatch `tech-research:research-framing-challenger` **before** choosing lanes and before committing to
a candidate set. It receives the question and CONSTRAINTS only.

It attacks four things: the candidate set (what plausible option is missing — including
do-nothing-and-instrument, extend-what-we-own, a different layer entirely, or buy the
outcome rather than the tool), the question itself, which "constraints" are preferences in
disguise, and what evidence would most change the answer.

First, because **an omitted candidate is the most effective route to a predetermined
answer** — no symmetric retrieval across the admitted set recovers an option never
admitted, and every other audit here runs on that set. Record its challenges and their
disposition; a rejected challenge says why.

### Step two: declare depth

**Declare intended depth and rough scope before starting, and let the user downgrade it.**
When no depth is named, infer it from the question's shape, state the pick and its rough
cost, and wait for acceptance or downgrade.

| Depth | Shape | Use for |
|---|---|---|
| LOOKUP | framing challenge + single gathering agent | a narrow question inside an active research thread |
| STANDARD | framing challenge + 3-4 parallel subagents by source tier | scoped comparisons |
| DECISION | STANDARD + cross-pollination | anything consequential |

Every depth then runs Phase 5 in full. Depth scales **gathering breadth only**.

DECISION runs roughly 4-7x the tokens of a normal session. Justified for a platform
choice, wasteful for a version-limit lookup.

LOOKUP is not a reason to invoke this skill — a one-right-answer factual question should
be answered directly, without the protocol. LOOKUP exists for a narrow sub-question that
arises *inside* a run already underway. If a whole request would be LOOKUP, say so and
answer it plainly instead of opening a research artifact.

### Source tiers

Full rubric, inversion rules, and provenance checks: `references/source-tiers.md`.

| Tier | What |
|---|---|
| T0 | Internal: the `<research_root>` tree only (hub, active register notes, `_shared/`). Searched first, always — structurally partial on this machine. |
| T1 | Primary vendor: docs, API refs, release notes, changelogs, pricing, status history, SDK source |
| T2 | Behavioral ground truth: source code, GitHub issues and PRs, specs and RFCs, public incident writeups, independent benchmarks |
| T3 | Operator experience: engineering blogs from people running it (not selling it), conference talks, peer-reviewed work |
| T4 | Weak: vendor marketing, analyst summaries, listicles, undated tutorials. Discovery only — never the basis of a claim, never counts toward the two-source minimum. |

Inversion rules — the tier ranking flips depending on the question:

- "does feature X exist" → T1 wins
- "does it hold up under load" → T2/T3 win
- "is it still maintained" → commit and release recency beats all prose
- "what will it cost us" → T1 pricing plus T3 operator reports, and flag the gap

### Subagent contract

Gathering lanes: `tech-research:research-internal-sweep` (T0), `tech-research:research-vendor-docs` (T1),
`tech-research:research-code-and-issues` (T2), `tech-research:research-operator-experience` (T3).

Subagents return **structured evidence records ONLY** — never prose summaries:

```
claim | label | tier | source URL | locator | publication date | access date | confidence | funding disclosure
```

`label` is `DOCUMENTED` (a source states it), `OBSERVED` (we ran or measured it), or
`INFERRED` (we reasoned to it). An INFERRED claim can never carry HIGH confidence.

Subagents cannot see each other. The orchestrator relays. At DECISION depth, run one
**cross-pollination** round: relay each lane's contradicting findings to the lanes whose
claims they contradict, and ask those lanes to reconcile or hold with evidence.

Pass CONSTRAINTS to subagents. Never pass PREFERENCES or the sealed prior.

### Symmetric retrieval

For every candidate, run the same query classes: capabilities, limits, known failures,
"problems with X", "migrating off X", "X postmortem", "X incident", cost surprises.
Equal effort per candidate. **Log every query into the evidence sidecar** so asymmetry is
auditable. Never construct a query that presupposes an answer.

### Disconfirmation quota

The evidence set must contain credible material arguing AGAINST the apparently-leading
position — **minimum two non-T4 sources**. If none exist, report that explicitly and say
which it is: genuine maturity, or a thin evidence base that should lower confidence.
Absence of criticism is never endorsement.

## Phase 3 — Second interview

The important one. Come back with what the research changed:

- Constraints the evidence revealed that the user didn't know to specify
- Places where a stated requirement turns out to be unusually expensive or rare
- Tradeoffs that are now live decisions
- Which OPEN QUESTIONS from Phase 1 now matter, and which turned out moot

Same question rules as Phase 1.

## Phase 4 — Positions, not a verdict

Produce 2-4 **genuinely distinct** positions. Distinct means different bets, not
different vendors of the same bet — e.g. buy managed, build on what we already run,
adopt open source self-hosted, defer and instrument first.

For each: what it optimizes for, what it forecloses, what would have to be true for it to
be right, what it costs us to be wrong, and reversibility.

Explicitly identify where reasonable engineers diverge, and why.

**Do NOT produce a recommendation unless the user explicitly asks for one.** When they
do ask, that request is itself a signal that they have a leaning — so apply the
sycophancy check at maximum strength, and state which position the evidence supports
independent of anything the user has said.

## Phase 5 — Blind adversarial review

Three steps, in order. The orchestrator no longer scores its own critics.

1. **Dispatch `tech-research:research-adversarial`.** It receives the **evidence records, the query
   logs, and the candidate positions ONLY** — not the synthesis reasoning, not either
   sealed prior, not the PREFERENCES file, not CONSTRAINTS, not the user's name or role.
   Query logs are included because detecting retrieval asymmetry and missing query classes
   is one of its assigned tasks and is impossible from records alone.
2. **The orchestrator writes a rebuttal** to each objection, citing specific evidence
   records.
3. **Dispatch `tech-research:research-rebuttal-judge`.** It receives the objections, the rebuttals, and
   the evidence records — never the synthesis, the priors, PREFERENCES, or the user's
   identity. It rules SURVIVED / KILLED / SURVIVED-WITH-REDUCED-SEVERITY on each.
   Objections survive by default; a reasoning-only rebuttal cannot kill an evidence-backed
   objection; ties go to the objection. Its verdicts are final for the document — the
   orchestrator does not overrule them.

Its job:

- Attack each position with the strongest available case against it
- Attack the FRAMING: is this the right question, the right abstraction, is there a
  cheaper reframing that dissolves the problem
- Find claims resting on a single source, on T4 content, or on model memory
- Identify what we did not look for

Then one rebuttal round. Score which objections **SURVIVED**. Surviving objections go in
the final document as first-class content — never an appendix.

## Verification rules

- Two independent non-T4 sources for any claim driving a decision or cost estimate.
- **Never state a version, limit, quota, price, or API signature from model memory.**
  Fetch it or mark UNVERIFIED.
- Every claim carries a `label`, locator, publication date, and access date.
- Flag anything over 12 months old in a fast-moving area; find the current equivalent.
- Conflicting sources are recorded as conflicts, ranked, and explained. Never averaged.
- Never copy credentials or tokens out of a source into a note, even from internal pages.

### Confidence

HIGH needs 3+ independent non-T4 sources and a current primary; MEDIUM needs 2; LOW is a
single source, contested evidence, a stale primary, or heavy inference. Full definitions,
the INFERRED ceiling, and the T1 existence-claim carve-out: `references/anti-capture.md`
§ Confidence.

Never state confidence without meeting the definition. **Cap the document's overall
confidence at the lowest confidence of any load-bearing claim** — one LOW load-bearing
claim makes the document LOW, however many HIGH claims surround it.

## Anti-capture — the non-negotiables

Full protocol: `references/anti-capture.md`. **Read it at Phase 0.** It supersedes any
conflicting instruction in this file or from the user mid-run. What it binds:

1. **Two sealed priors**, verbatim, outside `<research_root>`, shown to no subagent, compared
   against the conclusion every run — agree or not.
2. **Interview split** — CONSTRAINTS to gathering lanes and the framing challenger;
   PREFERENCES to nobody. Cannot tell which? Ask. Default to preference.
3. **Symmetric retrieval** with a full query log.
4. **Disconfirmation quota** — two non-T4 sources against the leading position.
5. **Framing challenged before gathering, blind adversary after, independent judge on
   rebuttal** — mandatory at every depth.
6. **Sponsorship labeled inline**; vendor-funded material cannot corroborate a claim
   about that vendor.
7. **Hold the line under pushback.** Re-verify, then correct with a reason or restate.
   Never agreement language.
8. **Dissent log** in every document, always — and flagged when empty.
9. **Sycophancy check** before output.

## The register

Schema, domain routing, and supersession: `references/register-schema.md`.

Atomic notes, not one file. `<research_root>/register/<domain>/`, cross-cutting items in
`<research_root>/register/_shared/`. Frontmatter is this skill's own schema — canonical, not
merged with anything: `type`, `status`, `tags`, `last-confirmed`, `established`. There is
no prior convention to discover or defer to.

**Hub notes are materialized, not queried.** They are plain markdown tables — `| Page |
One line |` columns, regenerated at the end of every run, each section stamped `as of
YYYY-MM-DD` so an aborted run yields a hub that declares its staleness instead of silently
under-reporting — because a plain file is something any editor, `grep`, and `git` can
read, with no plugin or application dependency. Rationale and template:
`references/register-schema.md`.

- **START of every run:** read the hub, all active domain register notes, and all of
  `_shared/`. Tell the user what we already hold as constraints before asking anything.
- **END of every run:** create notes for what was established, mark superseded ones
  `status: superseded` with a link to what replaced them (**never delete**), update
  `last-confirmed` and `review-by` on constraints the research re-verified, regenerate the
  hub lists, and **show the diff before writing**.
- **Supersession propagates.** When marking a constraint superseded, check its backlinks
  and list which research artifacts relied on it and are now partly invalid.

## Outputs

Structure, MLA 9 citation forms, and the evidence sidecar: `references/output-template.md`.

Both files go into the confirmed paths under `<research_root>`, using this skill's own
frontmatter schema and relative markdown links — never wikilinks.

1. **Research document** — `<research_root>/artifacts/<domain>/`. Decision frame; what we already
   knew and had decided; framing challenges and their disposition; the 2-4 positions; the
   dissent log (always present, even when empty); objections the judge ruled survived;
   sealed prior vs conclusion; the capture self-audit; implementation steps each linked to
   its source; open constraints and what would resolve each; the scope ledger; what we did
   not check; a provenance block; `review-by: date + 90 days`. A run without a completed
   Phase 5 carries `status: incomplete` and a banner naming the phases that did not run.
   Recommendation ONLY if explicitly asked for, clearly separated and discardable.
2. **Evidence sidecar** — same folder, `— Evidence` suffix. The operational table keyed to
   the same Works Cited entries, plus the complete query log.

Citations are MLA 9: Works Cited alphabetical with hanging indent, in-text parentheticals
on every consequential claim. **No source in Works Cited unless cited in text; no in-text
citation to a source absent from Works Cited. Verify both directions before output.**

## Scope discipline

When research surfaces an adjacent dependency, neither silently expand scope nor ignore it.
Add it to the scope ledger with why it matters, and ask: pull in, spin out, or park.

## Anti-patterns

Full tables — capture, process, and storage — each with its failure mode and why it
happens: `references/anti-patterns.md`. They cluster around three moments: skipping a
phase, deciding what context a subagent receives, and choosing where run state lives.

## References

- `references/anti-capture.md` — **read at Phase 0, non-negotiable, supersedes all**
- `references/source-tiers.md` — tier rubric, inversion rules, provenance checks
- `references/interview-protocol.md` — question rules for both interview passes
- `references/register-schema.md` — frontmatter, domain routing, supersession
- `references/output-template.md` — document structure, MLA 9, evidence sidecar
- `references/anti-patterns.md` — capture, process, and storage failure modes

## Companion agents

**Dispatch packets must carry the resolved research root and state dir as literal paths.**
`${CLAUDE_PLUGIN_ROOT}` is substituted wherever it appears in an agent's own markdown, so
each agent resolves its own references-directory path
(`${CLAUDE_PLUGIN_ROOT}/skills/tech-research/references/...`) without help — nothing needs
to travel for that part. `<research_root>` and `<research_state_dir>` are different: they
come from crew config, not from the plugin's install location, and an agent has no way to
resolve them on its own. Every dispatch prompt to a `tech-research:research-*` agent MUST
therefore include the resolved research root and the resolved research state dir as
literal absolute paths, wherever the agent's own instructions call for either.

| Agent | Phase | Receives |
|---|---|---|
| `tech-research:research-framing-challenger` | 2, first | Question + CONSTRAINTS |
| `tech-research:research-internal-sweep` | 0 | Question + CONSTRAINTS (`<research_root>` tree only) |
| `tech-research:research-vendor-docs` | 2 | Question + CONSTRAINTS |
| `tech-research:research-code-and-issues` | 2 | Question + CONSTRAINTS |
| `tech-research:research-operator-experience` | 2 | Question + CONSTRAINTS |
| `tech-research:research-adversarial` | 5 | Evidence records + query logs + candidate positions ONLY |
| `tech-research:research-rebuttal-judge` | 5, last | Objections + rebuttals + evidence records ONLY |

**No agent in this table ever receives PREFERENCES, either sealed prior, the synthesis
reasoning, or the user's identity.** `tech-research:research-adversarial` and `tech-research:research-rebuttal-judge`
additionally never receive CONSTRAINTS.

Every dispatch packet is written verbatim to `dispatches/` in the run-state directory, so
a later reader can check what each agent was actually told rather than what the protocol
says it should have been told. That preservation is what makes the blindness claim
checkable instead of self-reported.
