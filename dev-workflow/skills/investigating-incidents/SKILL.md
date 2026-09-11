---
name: investigating-incidents
description: >
  Orchestrates a root-cause investigation of a production problem, failure, or
  alert on any platform — job failures, monitoring problems, cloud faults,
  Kubernetes issues, CI and infrastructure breakage. Owns the method only:
  ticket gate, evidence ordering, hypothesis refutation, confidence gates,
  artifact production, close-out. Holds no query knowledge — routes every
  platform lookup to the skill that owns it. Use when the user says
  "investigate", "root cause", "why did X fail", "RCA this", "troubleshoot", or
  pastes an alert, job-run, or problem URL. Skip when the cause is known and the
  task is implementing the fix (plan-implementation), when the request is a data
  lookup rather than a diagnosis (use the platform skill directly), and when
  triaging an alert queue rather than root-causing one problem (use a
  dedicated alert-triage skill or agent if your workspace has one).
---

# Investigating incidents

Determine the **root cause** of a problem, failure, or alert — and prove it, or say plainly that you could not.

This skill is a spine, not a cookbook. It contains no query language, CLI syntax, or platform specifics. Every lookup routes to the skill that owns it.

## When to Use This Skill

- "investigate", "root cause", "why did X fail", "RCA this", "troubleshoot", "debug this failure"
- A pasted alert URL, job-run URL, problem ID, or forwarded failure email
- A fix is being proposed for a failure whose cause was never established

## When *Not* to Use This Skill

- Cause known, implementing the fix → `[[plan-implementation]]`
- Data lookup, not a diagnosis ("what's our spend on X") → the platform skill directly
- Triaging an alert *queue* → a dedicated alert-triage skill or agent, if your workspace has one
- Writing the documents once the investigation concluded → `[[authoring-incident-docs]]` (this skill invokes it)

## Gate 0 — Ticket, before any evidence

**If no ticket was provided, stop and ask.** An investigation normally opens against your tracker's incident record — ask for its id, or offer to open one. Filing is a write: propose it, never do it unasked, and take a decline as an answer.

- Ask the user for the ticket key, or for permission to open one.
- To open one, use your workspace's ticket-creation skill or process, with an Incident-shaped issue type.
- If there is a key, it belongs in every artifact's first metadata line and every commit subject.
- If the user declines a ticket, record `**Ticket:** none — <their reason>` so the absence is visible rather than looking forgotten.
- **The ticket's Priority sets the RCA severity tier** — capture it now. `[[authoring-incident-docs]]` maps `(P1)`–`(P5)` to `rca/sev1`–`sev4`. Without a ticket the tier is inferred and must be labelled as such.

Do not defer this to the end. A ticket opened after the fact loses the timeline.

## Gate 1 — Find the real failure

The thing the alert names is rarely the thing that failed.

- Walk the ownership chain to the innermost failing unit — orchestrator → child job → task → notebook/pod/query. Alerts fire at the top; causes live at the bottom.
- **A container's SUCCESS hides a repaired child's failure.** Enumerate attempts, not just final states. A run that was repaired reports success at the run level while attempt 0 failed.
- Capture the exact failing artifact: error string, stack frame, file and line, commit SHA, host/cluster/pod identity, and timestamps.
- Record the timezone once and convert everything to one consistent local zone. Cloud APIs return UTC; schedules and humans usually think in local time.

## Gate 2 — Prior art, before gathering any evidence

The repo already knows about most failure classes. Search it before querying anything.

Search the incident-docs layout (`rca/sev*/`, `findings/`, `runbooks/` by default — see `[[authoring-incident-docs]]` for the configurable version) for the failing component, its parent job or service name, the numeric job/resource id, and the error signature. Search your tracker for prior incidents on the same component. Delegate this — it is a bounded search, so it belongs in a cheap read lane (e.g. `claude-crew:claude-scout`), not the main loop.

⚠️ **Search the parent, not just the innermost unit.** Gate 1 hands you the most specific failing thing, and that name is usually too narrow to match prior art — earlier documents were written about the job or service, not the individual task. Verified against one repo: the orchestrating job name and the numeric job id each matched two prior documents; the failing notebook's own name matched nothing.

What each hit changes:

- **A prior RCA for the same failure class → this is a recurrence, and that reframes the investigation.** The question is no longer "what broke" but "why did the previous remediation not hold". That answer is usually the more valuable finding. Say "recurrence of <file>" in the executive summary, not as a footnote.
- **An existing runbook → follow it rather than re-deriving.** Note anywhere it was wrong, stale, or incomplete; Gate 8 updates it.
- **An existing finding for the same gap → record a recurrence on that file.** Never file a second finding for a gap already documented. Two findings for one gap means neither gets fixed.

**Why this gate exists:** a prior RCA and a prior finding existed for the same job family, filed four months earlier. Neither was found at the start. The finding surfaced only by accident much later, while checking something unrelated — by which point the investigation had been framed as a novel failure rather than a known-but-unfixed gap, which was the actual story.

Repo documents are the durable memory here. Session transcripts roll off in weeks; `rca/`, `findings/`, and `runbooks/` do not. Treat them as the first source, not the last.

## Gate 3 — Gather evidence (route, don't improvise)

Pick the owning skill and use it. Never hand-roll a query this repo already documents.

Route each platform lookup to the skill that owns it in your workspace:

| Platform | What to ask | Where the query knowledge lives |
|---|---|---|
| Application monitoring / observability platform | Problems, spans, logs, metrics | Your platform's query-language and dashboards skill(s) |
| Cloud provider monitoring (e.g. Azure Monitor, CloudWatch) | Metrics, logs, resource health | Your cloud monitoring / query-language skill(s) |
| Cloud resource inventory | Orphans, health, ownership | Your cloud resource-graph or inventory skill |
| Kubernetes / container platform | Workload state, rightsizing, restarts | Your Kubernetes-ops skill(s) |
| Distributed traces | Cross-service causal chains | Your tracing skill |
| Data platform authoring (pipelines, warehouses, bundles) | Job/pipeline definitions and deploys | Your data-platform authoring skills |
| Ticket / wiki system | Reads and writes | Your tracker-conventions skill |

**Known gap — some platforms have authoring skills but no failure-diagnosis skill.** If every skill for a platform is authoring, deploy, or usage focused and none covers diagnosing a failed job/task/cluster, route to any existing runbook for that failure class and check for a newer post-mortem procedure. Until a diagnosis skill exists, note the gap (Gate 8 turns it into one).

Missing route? Note it — Gate 8 turns that into a skill.

**Cheap lanes.** Bulk reading and searching do not belong in the main loop. Before the third consecutive read-only `grep`/`cat`/`find`, delegate:

- Locate/inventory → a cheap read/locate lane (e.g. `claude-crew:claude-scout`)
- Digest long logs, CI transcripts, prior sessions → a cheap read/digest lane (e.g. `claude-crew:claude-reader`)

Their raw output never enters the orchestrator's context, so it is not re-read every turn. **Stays in the main loop:** live cloud reads (data platform CLIs, cloud CLIs, Kubernetes CLIs, infrastructure-as-code CLIs), any mutating command, and judgment-dependent collection.

**Stale auth is not absent auth.** A rejected token means find the other credential path — service principal env blocks, `~/.netrc`, `~/.config` — before concluding a tool is unavailable. Say which identity produced each piece of evidence.

**Evidence expires.** Cluster logs die with the cluster, session transcripts roll off in weeks, telemetry retention is finite. Collect the perishable first and note the horizon in the artifact.

## Gate 4 — Refute before asserting

This is the gate that makes the difference between an RCA and a guess.

- **Enumerate candidate causes, then attack each one.** Report what you *excluded* and how, not only what you landed on.
- **Resolve every identifier before believing a correlation.** An event naming a node, pod, or resource ID must be resolved to *which* one. A correlation that dissolves on lookup was never evidence.
- **Temporal adjacency is not a mechanism.** "X happened 30s before Y" is a lead. Without a causal path it stays a lead and is labelled one.
- **Distinguish cause from impact amplifier.** Missing retries, absent alerting, and slow detection change the blast radius; they are contributing factors, not the root cause. Keep them in separate sections.
- **Rule out regression explicitly** — compare the deployed commit/version against the last known-good run.
- **Rule out scope** — was this one unit, or everything? An isolated failure amid healthy peers is task-local.
- **Establish recurrence** — scan history far enough back to say "first occurrence in N runs" with a number.

**Every claim is tagged.** Carry these labels into the artifact:

- **Proven live** — a command was run against the real environment; name the query or API call.
- **Inspected only** — read from a repo, config, or doc; states intent, not reality.
- **Not established** — could not be determined, and why.

Repo files state intent. Only the environment states truth.

## Gate 5 — Confidence gate

**Ask the user rather than assert.** Use AskUserQuestion whenever any of these hold:

- The mechanism is a hypothesis, and promoting it to "cause" would change what someone does next
- Two plausible causes remain and the evidence to separate them is gone or expensive
- The next step mutates anything, costs money, or touches production
- Remediation depends on ownership, retention, or cost that is the user's call, not yours
- Evidence is unreachable and a credential, access grant, or a person is needed to proceed

State what you know, what you cannot determine, and what each option implies. **Never round a hypothesis up to a conclusion to avoid asking.** An RCA that says "leading hypothesis, alternatives excluded" is more useful than a confident wrong answer.

## Gate 6 — Verify the fix target actually deploys

Before recommending any configuration change, prove the thing you are pointing at reaches production.

- Is the resource actually managed by the file you would edit? Check for deployment markers, not just the file's existence.
- Does the pipeline that deploys it trigger on the branch that promotes to production?
- Does the checked-in definition match live state — sizes, counts, names, membership? Divergence means the file is stale.

**Why this gate exists:** a prior finding recommended editing workflow YAML that had no deployment path to production. It read as actionable for months and could never have worked. A remediation aimed at a file nothing deploys is worse than none — it looks done.

If Gate 2 surfaced a prior finding for this gap, this is where its recommendation gets audited: **a remediation that was never actionable explains the recurrence.** That explanation belongs in the RCA, and the correction belongs on the original finding — not in a new one.

## Gate 7 — Produce artifacts and ship

Two steps, and **the order is load-bearing** — the conclusion is reviewed before any document exists
(per this plugin's README § Review policy).

### 7a. Refute the conclusion — before you write anything

Dispatch `codex-adversary` in **task mode** with the causal claim and the evidence behind it, mandated to refute it. This runs regardless of tier — it reviews reasoning, not a diff, so there is deliberately nothing to diff yet.

- If the pass **refutes** the conclusion, you are back at **Gate 5**, not here. A revised conclusion is changed input and earns a fresh pass; re-passing an *unchanged* conclusion is the forbidden same-input re-score, and the three-pass cap counts these.
- If the pass **holds**, record its verdict in the RCA under `## Root Cause`, beside the claim it examined.

⛔ **Do not invoke `[[authoring-incident-docs]]` until this pass returns.** Drafting first defeats the whole split — the point is to catch a wrong root cause *before* it propagates into the RCA, the runbook, and the remediation.

### 7b. Write the artifacts and ship

Invoke `[[authoring-incident-docs]]` for the RCA, findings, and runbook. It owns file placement, naming, severity tiers, and section structure.

**The artifact text is reviewed by the team on the PR, not by the chain.** Do not dispatch `fresh-verifier` or `codex-adversary` on the RCA, findings, or runbook prose.

The split exists because team review reliably catches a claim that *reads* wrong and reliably misses a causal chain that reads plausible and is not. The second failure is what a different model family is good at.

Deterministic gates still run, and are not optional — they are what replaces the review chain:

1. Branch from `main` in a worktree; never commit to `main`.
2. `gitleaks detect` — and distinguish hits inside your diff from pre-existing ones in history. Report both; only the former blocks.
3. Scan every new document for credential and identifier leaks: tokens, keys, PATs, connection strings, secret values. RCAs and runbooks are typically the highest-risk leak surface in a repo because they paste live output. Variable *names* are fine; values never are.
4. Verify every relative link resolves: run the repo's link checker (e.g. `python3 scripts/check-doc-links.py`) from the repo root, which must exit 0. Run it against the **complete repo tree** — a checker fed only the directories you changed reports links into sibling directories as broken and produces false failures.
5. If any check compares against a remote, **confirm the fetch actually succeeded first.** A silently failed fetch leaves the local ref stale, so the comparison runs against the wrong tree and can report merged work as missing. If a fetch or push fails with `Repository not found`, suspect credential routing — the wrong helper or token — rather than a missing repo; re-run with an explicit `-c credential.helper='!gh auth git-credential'`.
6. Ticket key in the commit subject and PR title; ticket as a hyperlink on the PR body's first line — or `**Ticket:** none — <reason>` there if the user declined one at the Gate 0 ticket check.

Then `[[opening-pull-requests]]` for branch hygiene and PR mechanics — skipping its review-chain gates only.

## Gate 8 — Close out and improve

Invoke `[[skill-retrospective]]` in CAPTURE mode. Route each learning to its one canonical home:

- Durable repo-scoped rule → a per-repo overlay file in your workspace (if you keep one)
- Reusable procedure → the owning skill, or a new one
- Volatile state (ticket status, open follow-ups) → memory
- A missing evidence route noticed at Gate 2 → propose the skill

Also feed back into this skill when an investigation surfaces a **method** failure — a gate that did not fire, a trap with no home, an ordering that cost rework. Method learnings belong here; platform learnings never do.

Finally: comment the artifact links onto the ticket, so the investigation and the ticket can find each other later.

## References

- `[[authoring-incident-docs]]` — produces the RCA, findings, and runbook
- `[[opening-pull-requests]]` — branch and PR mechanics
- `[[skill-retrospective]]` — Gate 8 capture
- This plugin's README § Review policy — tier table; the investigation **artifact text** is exempted from the chain, while the root-cause **conclusion** gets one adversarial pass (Gate 7a)
- `rca/`, `findings/`, `runbooks/` (or the repo's configured equivalent) — searched at Gate 2, updated at Gate 8; the repo's durable incident memory
