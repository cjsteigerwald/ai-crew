# Superpowers chain — step 6 of intaking-work-items

Read only after the superpowers chain is chosen in SKILL.md step 6; it ends by returning to SKILL.md
step 7 (Verify).

1. **Design — `superpowers:brainstorming`.** What you hand it depends on what intake produced:
   - **Gate passed:** the requirements doc path, and say plainly: *requirements and AC are settled;
     brainstorm the design and approach only — do not re-open scope or AC.*
   - **Gap analysis or the requirements doc was skipped:** the ticket link, the stub doc (or, with
     "no doc at all", the skip summary), and the note *requirements not gap-checked — treat AC as
     unverified*. Do not tell it requirements are settled.

   Its "write back your understanding" step should be a short summary of the doc for the user to
   confirm, not a second interview. Brainstorming picks a path itself, and on two of them it chains
   onward on its own — so give it these instructions up front, with the plan instructions from
   stage 2, plus intake's controls: *on cancel, stop and return to intake and write or post nothing
   further; on skip at your spec-review gate, record "Intake: design review skipped" and proceed
   (to writing-plans on the architectural path); on skip at any other gate of yours, return to
   intake.*
   - **Architectural** → it writes a design doc (default
     `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`; ask it to link the requirements doc),
     runs its own spec-review gate, then invokes writing-plans itself. That is allowed: **its
     spec-review gate is this stage's checkpoint**, and the stage-2 instructions **and intake's
     skip/cancel controls** must reach writing-plans through it. At that gate, "skip" means the
     design is accepted unreviewed: record it ("Intake: design review skipped") and continue to
     stage 2. "cancel" follows **Controls** in SKILL.md.
   - **Bounded** → it presents an in-chat design, and after approval its default is to implement
     directly. Instruct it instead: **after design approval, STOP and return to intake** — do not
     implement. Intake then runs stage 2b.
   - **Spike** → the output is a recommendation; come back to SKILL.md step 3 if it changes
     requirements.
   - If design surfaces a genuine requirements gap, stop, return to SKILL.md step 3 for that row,
     and update the requirements doc and its decision log. Don't patch requirements inside the
     design.
2. **Plan.** Tasks cite `AC-n` from the **settled AC list** and cover only active AC — see the
   **Settled AC list** rule in SKILL.md step 6.
   - **Plan approval.** In unattended mode, the approval question states the gate mapping from
     [run-modes.md](run-modes.md) § What the sitting settles and that approval `pre-authorizes`
     the two outward actions (commit/push and the draft PR). Run Preflight (same file) before
     asking.
   - **(a) Architectural — `superpowers:writing-plans`.** Every task cites the AC numbers it
     satisfies, and every AC is covered by at least one task; the plan's **Spec** line lists both
     the design doc and the requirements doc, plus every skipped intake step (e.g. "Intake: gap
     analysis skipped — requirements not gap-checked"). Tell it up front that execution will be
     `dev-workflow:plan-implementation`, so its handoff asks only for plan review. Its plan header
     hardcodes a *REQUIRED SUB-SKILL* line naming other executors: have that line in the saved plan
     replaced with `dev-workflow:plan-implementation`, then verify the saved file carries no
     contradictory executor directive —
     `grep -nE 'subagent-driven-development|executing-plans' <plan-file>` must print nothing.
   - **(b) Bounded — intake writes a short task list.** Each task maps to the AC numbers it
     satisfies, every AC is covered, any skipped intake step is stated at the top, and the list
     goes to the user for approval. That approved list is the plan stage 3 executes. Don't skip it
     even for small changes — it is what makes the AC traceable into the PR — unless the user
     explicitly skips the plan (see below).
   - **Plan skipped by the user** (either path): follow the plan-skip rule in **Controls** in
     SKILL.md — warn once, record it, get an explicit go-ahead, and go to stage 3 without a plan.
3. **Implement — `[[plan-implementation]]`**, only after the user approves the plan from stage 2 —
   **except when the user skipped the plan**: then, after the explicit go-ahead, implement directly
   against the settled AC list, covering only active AC (SKILL.md step 6's **Settled AC list**
   rule), without plan-implementation's approved-plan prerequisite, and the PR body states
   "Intake: plan skipped". A single small edit doesn't need the orchestrator either. Either way,
   work to the same standard (tests, verification evidence per AC).

   In unattended mode `plan-implementation` runs `without its stage checkpoints`, stopping only
   on the [run-modes.md](run-modes.md) stop conditions. Every implementer it dispatches receives
   the AC→test table as the `confirmed seam list` for its `tdd` call; a seam not in the table is a stop (report it, never ask or invent).

After stage 3, return to SKILL.md step 7 (Verify).
