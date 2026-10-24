# Demonstrate history-aware invocation with existing delivery

<a id="adr-0013"></a>

## Decision

- On 8 October 2026 the owner requested generic Fabric history-aware invocation with external consumer evidence and durable application composition. The research application gains an additional public consumer that combines Grind transactional admission, Fabric history-aware keyed invocation and the leased PostgreSQL store.
- Admission inserts the application turn and calls Grind's transactional submit inside one application transaction. A rollback removes both, and the handler runs only after commit.
- Delivery validates the accepted history, invokes Fabric with a stable principal and turn key, and retains the keyed outcome until an idempotent application transaction incorporates the answer and generated messages together with an applied marker.
- The applied marker outlives Fabric pruning. Pruning stays disabled until incorporation commits.
- Delivery maps the saved invocation observation to Grind outcomes: working and unattended observations snooze, ended failures and definite refusals keep distinct outcomes, and suspension and uncertain execution become Grind's uncertain state without classifying suspension as an unknown external effect.

## Rationale and alternatives

- Application acceptance and Fabric admission occur at different commits. Existing transactional delivery covers that interval, and Fabric's leased recovery owns an admitted run. The application adds no lease-renewal loop, abandoned-run scanner or separate execution queue.
- Retained execution identity alone cannot prevent a later delivery from creating a new run once the record is pruned. An age threshold cannot guarantee retention while incorporation is delayed indefinitely.
- An application graph can own incorporation as a declared operation when the application supplies truthful idempotency and interrupted-effect handling. It still needs the transactional admission bridge; neither pool sharing nor a borrowed connection makes admission atomic with application acceptance.
- Fabric owns the lossless message representation through its history codec, and the application owns the transaction and the marker.

## Consequences

- The consumer tests the second commit boundary and a lost incorporation acknowledgement independently of model quality, using a deterministic model callback and disposable PostgreSQL.
- The evidence is local process-recovery evidence, not live-provider or power-loss evidence.
