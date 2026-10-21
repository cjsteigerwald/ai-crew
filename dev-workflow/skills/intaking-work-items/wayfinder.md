# Wayfinder escalation — step 3 of intaking-work-items

Read when step 3's signals say the remaining uncertainty is more than one agent session can hold.
Never call wayfinder by default.

## Escalate

Load `sdlc-process:wayfinder` (through the entry, see [chain-sdlc-process.md](chain-sdlc-process.md))
to chart the map; publication is an outward action under SKILL.md step 5's per-action rule. Before
stopping, write the requirements doc (Status `Draft`) with the Chain artifacts field
`Wayfinding: active <map URL>`, then **STOP** the run. Wayfinder resolves one decision ticket per
session; later runs resume it through the map row of SKILL.md step 1's stage table.

## Complete

The map is complete only when all of these hold: the map issue shows no remaining in-scope fog;
every decision ticket's resolution has been read; and no ticket was closed with "new tickets to
follow" still pending. Zero open decision tickets alone is not enough. Then re-rate the gap table
(step 2), update the requirements doc and get the user's OK (step 4) so the settled AC list
reflects the decisions, mark `Wayfinding: complete` in Chain artifacts, and continue at `to-spec`
in step 6.

## Hold

If the predicate is unmet but no decision ticket is selectable (all closed, with fog or follow-ups
pending, including a manual closure with no resolution), do not loop on wayfinder. Inspect the
closures and restore missing resolutions from the closed tickets where recorded there. Otherwise
write `Wayfinding: hold — <what's missing>` and ask the user whether to create the follow-up
decision tickets (an outward action under step 5's per-action rule) or declare the fog out of
scope. A `hold` resumes by asking that question first.
