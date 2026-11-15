# Answer a gated agent call from the decision point, not from approval expiry

<a id="adr-0035"></a>

Recorded on 2026-11-15.

## Decision

- In `payout_desk`, the Fabric agent's `propose_payout` tool call waits on a Fabric approval that never expires (`run.Infinity`).
- The call is admitted as an occurrence of the `payout` decision point. The occurrence key names the run and the action.
- Only the decision point answers the approval:
  - The Fabric approver accepts the occurrence id as its credential and refuses until the record states the payout's outcome. A payout whose reported effect is uncertain has no stated outcome yet, so the approver still refuses. A record the approver cannot read is reported as unavailable, not as a refusal.
  - A gated tool that could not tell, such as a guard whose query failed, answers `Unsure`. The release rolls back and nothing is recorded, so the parked call stays unanswered until a later delivery releases or refuses the payout.
  - A paid or unpaid payout approves the parked call. Any other outcome rejects it with the recorded outcome as the reason.
- The application resumes the same parked run. The tool body returns the recorded outcome, never its own arguments.
- A reply reaches the seller only when its outcome and amount equal the recorded ones.
  - Otherwise the application sends its own message built from the record and keeps the agent's text.
  - Nothing is sent before the record states an outcome, and the seller is told once per occurrence.

## Rationale and alternatives

- Fabric answers an expired approval itself: it rejects the call and gives the model its next turn. A model that reads any answer as success then tells the seller the payout is done, although nobody decided or finance corrected the amount. `truth_test.gleam` shows a run whose approval expired after one second answering "paid 80.00" while the occurrence still waits.
- A tool outcome that ends a run would remove the open approval: the gated call would end its run when it is admitted, and the outcome would start a run of its own. Fabric has no such outcome. The `decisions` repository records a request for it to Fabric's maintainers in its own ADR 0017.
- The `decisions` repository describes two ways to answer a parked call. Its laboratory recipe ends the parked run and starts a fresh run as the follow-on. `payout_desk` resumes the same parked run from the record. Neither makes Fabric end a run from a tool call. A run kept parked for hours needs durable storage, so the application keeps Fabric runs in `fabric_postgres`.

## Consequences

- A model's claim never reaches a customer on the strength of an approval, an expiry or the model's own text. The record is the only source of what the seller is told.
- An approval that never expires keeps a parked run open until the occurrence settles. A deadline on the occurrence still settles it as expired, and the seller is told that outcome.
