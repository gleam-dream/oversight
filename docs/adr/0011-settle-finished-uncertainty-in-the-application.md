# Settle finished uncertainty in the application

<a id="adr-0011"></a>

## Decision

- On 7 October 2026, the owner selected the reconciliation follow-up from the financial adoption review. Extend the existing financial recovery consumer with TDD.
- Keep the original Saga execution report immutable. Record later evidence, posting and an attributed reconciliation decision in application tables before resolving the queue through its public API.
- Define the coordinator's application obligation as a confirmed payment and its local posting. A later attributed confirmation records fulfillment through reconciliation without claiming that the original Saga completed normally.
- Keep authentication, operator authorization, reconciliation scheduling and financial retention application-owned. Add no runtime dependency or public library facade.

## Rationale and alternatives

- A finished Unresolved report describes the execution's result. Reopening it would require continuation, cancellation and compatibility decisions that this consumer does not need.
- Keeping reconciliation entirely manual leaves the transaction and duplicate-handling procedure untested. The executable procedure demonstrates how existing public capabilities compose.
- The application commit contains evidence, posting and decision together. A queue resolution follows in a separate transaction because the two authorities retain separate contracts.
- A retained pending decision permits recovery after either commit boundary. It adds one application audit record and a caller-driven recovery operation; it does not remove the operational responsibility for recovery.
- The provider can confirm an operation but cannot establish that a missing operation will never execute. Non-execution settlement and reservation release remain excluded rather than inferring absence from HTTP 404.

## Consequences and evidence

- Stable decision identity binds job, operation, actor, reason and accepted confirmation. Conflicting identities or evidence are refused; identical concurrent calls reuse the committed decision.
- Provider failure and malformed confirmation retain the financial hold. Cancellation does not suppress recording an already executed payment and never implies a refund.
- The retained tests cover native process death after application commit and queue confirmation, actual PostgreSQL insert contention, an identical decision completing during a delayed lookup, posting rollback, cancellation, evidence conflict and queue pruning.
- If queue pruning removes the resolution receipt before local acknowledgment, the recipe reports missing history and retains the pending record. Financial completion remains authoritative; the recipe does not fabricate a queue acknowledgment. Deployments must own retention and investigation of that condition.
- The application schema remains a fresh-install consumer fixture. Existing deployments require versioned migrations. No whole-VM restart, live-provider certification or PostgreSQL commit-reply loss is claimed by these tests.
- The provider adapter's existing acceptance of an empty HTTP 200 body was exposed by a failing reconciliation test. The adapter now requires a nonempty payment reference.

## Subsequent decision

- On 7 October 2026, the owner approved closing the queue-confirmation/local-acknowledgment gap after transactional and retained-receipt experiments. [ADR 0012](0012-commit-queue-resolution-with-application-acknowledgment.md#adr-0012) supersedes that separate-commit boundary while preserving application-owned settlement and the immutable Saga report.
