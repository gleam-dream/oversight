# Commit queue resolution with application acknowledgment

<a id="adr-0012"></a>

## Decision

- On 7 October 2026, the owner approved the narrow borrowed-resolution capability and its financial consumer integration. Financial evidence, posting and attributed decision remain one application transaction; Grind resolution and the local acknowledgment become a second atomic transaction.
- Grind owns the generic transaction port, typed resolution and cancellation rules. Oversight's consumer owns provider investigation, financial evidence, application acknowledgment, authorization, transaction duration and recovery scheduling.
- Defer archival and general deletion hooks. They remain compatible mechanisms for other workflows, with separate failure, retry and retention contracts.

## Rationale and alternatives

- The previous queue commit followed by a local acknowledgment permitted process loss between them. Pruning could then remove the only queue receipt before the consumer saved its acknowledgment.
- A regression first reproduced that loss through the public APIs. The borrowed transaction closes the interval without coupling Grind to payment types or adding a new evidence lifetime.
- Independent receipts or transactional archival can recover an interval after job deletion. They require migration, lookup, retention and cleanup rules; external archival additionally needs durable delivery. None can reconstruct evidence already deleted.
- A transaction holds the job lock until the caller ends it. Provider calls and financial investigation therefore remain outside; only queue resolution and the local acknowledgment share the short transaction.

## Consequences and evidence

- A failed acknowledgment rolls back queue resolution while the previously committed financial settlement remains authoritative. An exact retry reads the same attributed decision and never performs another payment.
- A lost outer commit reply is explicitly uncertain until durable application readback. The local acknowledgment survives job pruning under application retention; a stale concurrent caller rereads that proof before reporting a queue-history error.
- The original Saga report stays immutable. Independent operators and old missing-history records remain explicit recovery cases; the new capability does not infer their attribution.
- The maintained financial tests reproduce the pruning failure before integration and pass afterward. They also force a real acknowledgment constraint failure, concurrent reconciliation, cancellation and process loss after commit.
- Grind's separate public consumer owns TCP COMMIT-reply suppression, process death before commit, scoped settings and same-job contention. Neither suite proves whole-VM restart, database failover, production load or live-provider behavior.
- No Grind migration or new financial schema column is required. The consumer remains a fresh-install fixture; production applications own versioned migrations and review of existing pending records.
