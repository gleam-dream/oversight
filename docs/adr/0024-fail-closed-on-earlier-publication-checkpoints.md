# Fail closed on publication checkpoints written under an earlier step version

<a id="adr-0024"></a>

## Decision

- On 8 October 2026 the research application changed publication to preserve uncertain outcomes. Publication carries step version 2 and a versioned error codec that retains effect evidence.
- A checkpoint written under step version 1 is incompatible and fails closed, including a finished failure. The compatibility test creates such a checkpoint with the frozen earlier consumer, then verifies that reconnecting leaves its bytes and revision unchanged and sends no further publisher request.
- Operators reconcile these records from provider evidence before an explicit operational migration. They are not deleted and not relabeled as safely retryable.

## Rationale and alternatives

- The earlier error type dropped effect evidence, and that evidence cannot be recovered from its text. Treating an old failure as retryable could repeat a mutation that already happened.
- Records that Grind already discarded under the earlier version are not repaired retroactively.

## Consequences

- The scripted publisher guarantees that a conflict response rejects before mutation. Other unexpected responses, malformed success bodies and requests that may have been sent keep their uncertainty through Saga's unknown-effect rule into Grind.
- The tests use real local HTTP, temporary PostgreSQL and peer VM termination, and make no live-provider claim.
