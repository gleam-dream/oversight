# Demonstrate financial recovery through public contracts

<a id="adr-0010"></a>

## Decision

- The owner approved implementation with TDD on 6 October 2026 after reviewing six financial-adoption findings. Retain the composition as `apps/financial_recovery`.
- Keep application financial records, Saga execution checkpoints and Grind delivery records independently authoritative. The consumer translates public results without adding a shared durability framework or bridge package.
- Use real disposable PostgreSQL and a scripted loopback provider. Keep native-runtime, database, scripted-provider and TLS qualification distinct.

## Rationale and alternatives

- An application payment record retains financial intent and evidence beyond queue receipt retention. Merging that record into a job would make business idempotency depend on pruning policy.
- A Saga checkpoint records workflow progress after an application effect. Sharing a pool does not make the business transaction and checkpoint atomic. A resolver over the existing posting record handles the interrupted interval without another generic transaction abstraction.
- Audited coordinator replay can recover an interrupted workflow without resubmitting its external action. A completed unresolved workflow has different semantics and must not be presented as a suspended interrupted action.
- A maintained executable recipe makes the ownership and failure transitions inspectable. A generalized financial runtime would impose domain policy and add dependencies before multiple consumers establish a common requirement.
- READ COMMITTED transactional enqueue remains a supported composition. Applications retaining SERIALIZABLE isolation can own an outbox; the example must not imply that ordered row locking preserves every invariant supported by SERIALIZABLE.

## Consequences

- The consumer proves its declared scenarios through public APIs. Package-owned cancellation and transport corrections remain in their owning repositories.
- Cancellation does not settle a payment. Retained cancellation intent forbids coordinator replay; attributed terminal evidence may still settle an operation.
- Business identity and payment evidence survive job pruning according to application retention policy. The example does not claim permanent provider deduplication.
- The original financial prototype was described in feedback but its source was not supplied. The retained consumer establishes its own executable evidence rather than claiming that the earlier prototype was rerun.
- HTTP Gun mTLS is qualified separately with native TLS fixtures. This consumer does not replace or qualify a production BaaS integration.

## Provenance

- The owner supplied a financial prototype report covering lost responses, suspended recovery, coordinator replay, transactional enqueue, local posting recovery and a pending mTLS requirement.
- The implementation instruction was “Let’s proceed and adopt TDD.” The chosen retained location was recommended in the same conversation after the owner asked for a recommendation.
- Grind's owning [ADR 0012](https://github.com/gleam-dream/grind/blob/fe810fb0277934dd8dde54cfa292f6ee6b177bc9/docs/adr/0012-preserve-uncertainty-through-cancellation.md) resolves the former cancellation ruling by preserving uncertainty and cancellation intent in either ordering, without a new shared state model.
- Initial qualification used uncommitted working trees and recorded their revisions and dirty state. The owner subsequently authorized commits and pushes. The delivery updates the existing sibling manifest to the committed Grind, Saga and HTTP Gun revisions; unrelated pins remain unchanged. Qualification of that set uses a separate clean checkout and the retained financial consumer.
- [ADR 0003](0003-use-core-ports-and-compiled-recipes.md) establishes compiled recipes and the nine-core-plus-two-adapter boundary. [ADR 0004](0004-retain-distinct-durable-authorities.md) preserves separate durable authorities. [ADR 0009](0009-retain-executable-evidence-with-scoped-claims.md) defines the evidence limits.
