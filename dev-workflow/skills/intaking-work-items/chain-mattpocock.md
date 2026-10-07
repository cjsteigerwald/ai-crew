# mattpocock chain — step 6 of intaking-work-items

Read only after the mattpocock chain is chosen in SKILL.md step 6; it ends by returning to SKILL.md
step 6's **Ship** stage.

## Why the user types each command

`mattpocock-skills` marks `to-spec`, `to-tickets` and `implement` with
`disable-model-invocation: true`. Claude cannot launch them: a `Skill` call to
`mattpocock-skills:to-spec` returns "cannot be used with Skill tool due to
disable-model-invocation. Ask the user to run /mattpocock-skills:to-spec themselves … Do not
replicate this skill's workflow by other means".

So at each stage intake prints the exact command and the context to give it, stops, and resumes
when the user reports back. Typing the command is the user's confirmation for the issues that
command creates. **Never replicate these skills' workflows by other means** — intake does not
write the spec, break down tickets, or implement in their place.

## Stages

1. **Spec.**
   - *GitHub ticket:* no `to-spec` — the issue is the spec. Offer, as a confirmed writeback under
     SKILL.md step 5's per-action rule, a comment on the issue carrying or linking the
     requirements doc. Record the issue as the spec issue in the doc's **Chain artifacts**.
   - *Jira ticket:* the user runs `/mattpocock-skills:to-spec`. First state what the spec must
     carry: the requirements doc path, the Jira key and link, and that its user stories and
     out-of-scope must match the settled AC list (SKILL.md step 6). After it publishes, read the
     issue back (`gh issue view <N> --repo owner/repo`) and record it as the spec issue in
     **Chain artifacts**. Offer, as a confirmed writeback under step 5's rule, a Jira remote link
     to it.
2. **Tickets — the plan stage.** The user runs `/mattpocock-skills:to-tickets`. First state the
   constraints: every ticket cites the `AC-n` it satisfies and links the spec issue as its parent;
   only active AC get tickets. After it publishes, list the tickets (`gh issue list` /
   `gh issue view`) and check coverage:
   - every active AC is cited by at least one ticket;
   - no ticket cites a deferred, skipped, or out-of-scope AC.

   Take any gap back to the user before implementation. Record the ticket list
   (`owner/repo#N` — `AC-n` each) in **Chain artifacts**.
3. **Implement.** The user runs `/mattpocock-skills:implement`, pointed at the spec issue and its
   tickets. Its `tdd` seam confirmation and `/code-review` run as that skill defines.

After stage 3, return to SKILL.md step 6 for the **Ship** stage.

## Controls on this path

The **Controls** in SKILL.md apply, with these specifics:

- **Skip** at a stage checkpoint follows the whole-step skip rules (warn once, record, continue).
  Skipping `to-tickets` is the plan-skip rule: explicit go-ahead, implement against the settled AC
  list, and the PR body states "Intake: plan skipped".
- **Cancel:** stop, and do not prompt the user to type any further command. Issues already created
  by commands the user ran are reported (`owner/repo#N` each), not deleted.
- **Resume:** the doc's `Chain:` field and **Chain artifacts** (spec issue, ticket list, last
  completed stage) record where the chain stopped. After the usual refetch-and-diff, restart at
  the first incomplete stage.
