# Claim ownership and acknowledgement

## Question

- Can a worker acknowledge its typed proposed outcome after lease renewal while stale workers and cancellation races remain explicit?
- This experiment models transitions over supplied current records. It does not make those reads and writes atomic in a database.

## Ownership and accounting

- Retry accounting does not identify an execution. Snooze may cause two distinct executions to use the same attempt number.
- A claim therefore carries ownership identity separately from its accounting. Lease renewal preserves that identity; takeover changes it.
- Renewal refreshes accounting from the current record rather than trusting a supplied snapshot ordinal.
- A record revision protects renewal updates. An old revision from the same owner must not make acknowledgement stale after a valid renewal.
- Acknowledgement consults the current record's expiry. The claim's earlier expiry observation is insufficient after renewal.
- Reaching expiry rejects acknowledgement. Renewal after expiry must not revive the old owner.

- Acknowledging an attempt does not necessarily finish its job. Retry and snooze leave further scheduling work; reconciliation remains unresolved. Job-state projection is a separate obligation.

## Outcome evidence

- The submitted value is an existing typed `AttemptResolution`, not a second worker-result algebra.
- Rejection retains the exact proposed outcome. A successful receipt or reconciliation evidence must remain available even when cancellation or stale ownership prevents acknowledgement.
- Cancellation requested, cancellation committed, and worker-directed cancellation are different facts. This experiment lets an acknowledgement from a matching live owner commit requested cancellation instead of its proposal. Expiry is checked first. A separate administrative cancellation transition may commit independently of the worker lease.
- An acknowledged-attempt record does not prove that the caller's command committed. Recognizing a particular replay requires a durable command receipt.
- The public acknowledgement command carries identity and the proposed outcome. The store owns reading its current record and clock, deciding, and committing together; the caller cannot supply a prechecked record.
- An unknown commit is an adapter observation. It retains the command identity and proposed outcome for reconciliation instead of claiming a known new record or authorizing execution again.

## Acceptance cases

- Acknowledge through the original claim after same-owner renewal.
- Reject the original claim after takeover, including reuse of the retry ordinal.
- Reject acknowledgement at exact expiry and renewal after expiry.
- Preserve a typed successful output and uncertainty evidence when committed cancellation wins first.
- Preserve an acknowledged successful receipt when acknowledgement wins before the attempt cancellation command.
- Distinguish a rejected transition, a missing or pruned record, unavailable storage, unknown commit, and an already acknowledged attempt.

- Compiler-negative consumers reject an attempt identifier as an ownership epoch and reject a changed native output type in an acknowledgement command.
- The fixture store supplies its own record and clock through a one-shot callback. It does not establish shared mutable storage or concurrent transactions.

## Remaining work

- Establish transactional storage, claim uniqueness, compare-and-set updates, durable command receipts, and reconciliation against actual persisted records.
- Exercise process and node loss, renewal races, rescue, cancellation delivery, and shutdown with OTP and PostgreSQL.
- Establish downstream effect idempotency or fencing independently. Queue ownership does not fence an external service automatically.
