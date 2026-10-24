# Record evidence before an irreversible send and retain the erasure findings

<a id="adr-0020"></a>

## Decision

- On 7 October 2026 the repository retained a synthetic erasure campaign. Saga owns reversible preparation, Grind owns durable per-target delivery and attributed resolution, and HTTP Gun owns transport.
- The application commits a pending evidence row with a unique domain identity before each irreversible send. Only the insertion winner sends. A later delivery reads confirmed, rejected or pending evidence and returns the receipt, declines, or reports uncertainty.
- An authoritative lookup must return the exact expected receipt. An absence, a malformed receipt or a failed lookup does not authorize replay.
- Application confirmation precedes attributed queue resolution. No borrowed resolution transaction, archive or deletion hook is needed for this obligation.
- Final deletion stays outside Saga's undo journal.

## Rationale and alternatives

- Compensation cannot restore deleted data, so an undo journal for final deletion adds concepts without restoring anything. Forward reconciliation with application evidence answers the actual obligation.
- The evidence table costs one small table, one commit before each first deletion and a lookup on every delivery. Queue identifiers and pruning cannot decide whether a domain operation already happened, so the domain identity is the key.

## Consequences

- A worker that stops after committing the pending marker and before sending requires investigation. The protocol sacrifices automatic progress rather than inferring non-execution from absence, and distinguishing that condition from an in-flight effect needs provider evidence.
- Observed results: the ordinary campaign deleted each target once; a known preparation failure undid only the completed freeze; a lost deletion reply left two deliveries uncertain while the service counted one deletion; cancellation after one deletion kept the partial erasure; a fresh runtime after pruning used application evidence without another deletion; the rejection policy stopped or continued as configured; bounded concurrency admitted exactly the configured handlers.
- Findings recorded with their corrections: a policy helper that panicked on uncertainty was replaced by a result that retains prior results, the job handle and the unprocessed remainder; reusing one resolution identity for two jobs produced a resolution conflict, so the consumer derives the command identity from the job identity. This was incorrect caller identity reuse and not a Grind defect, and Grind's package documentation states the installation-wide scope of a decision identity.
- No package defect was found. Sinal adapters and Blueprint runtime schema contracts were not needed for these static values, and the experiment makes no claim about them.
