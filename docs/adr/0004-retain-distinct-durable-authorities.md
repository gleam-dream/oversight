# ADR 0004: Retain distinct durable authorities

<a id="adr-0004"></a>

## Decision and unresolved scope

- Fabric's graph runtime remains in Fabric and shares its package versioning promise. This was accepted on 3 October 2026.
- Grind owns job admission and delivery. Saga owns workflow compensation and effect settlement. Fabric owns conversation, graph, approval, and managed-child state.
- A common durability substrate and a general Grind-driven composition runtime remain undecided. This cleanup does not accept them or recreate a bridge package.

## Context and alternatives

- The research-agent consumer crosses three durable authorities. Its application logic must join job identity, Fabric agent-run identity, Saga effect evidence, cancellation, and restart recovery. It does not exercise Fabric graphs.
- Moving graphs into a proposed `fabric_graph` package was considered and rejected by the graph placement decision. Keeping graphs in core makes later graph API changes part of Fabric's semver contract.
- A common store/lease/sweeper abstraction was considered but not accepted. Queue claims, single-run ownership, and compare-and-set graph records do not automatically share invariants.
- Explicit consumer wiring retains honest authority boundaries. Its cost remains evidence for a future design decision rather than proof that a new framework is needed.

## Consequences

- Retrying delivery does not prove that an effect did not happen. A lost reply, cancellation intent, and completed compensation remain distinct facts.
- Applications must choose one active driver arrangement for each run and define recovery when the driver disappears.
- Known cancellation/evidence conflicts remain visible in the owning package design; this ADR does not legitimize information loss.

## Provenance

- [Release decisions 1 and 2](https://github.com/gleam-dream/oversight/blob/3baff70/docs/release-api/DECISIONS.md) distinguish accepted graph placement from deferred durability ownership.
- [Earlier workflow research](https://github.com/gleam-dream/oversight/blob/3baff70/research/workflow-boundaries.md) and [composition exploration](https://github.com/gleam-dream/oversight/blob/3baff70/research/composition-contracts.md) are proposals, not evidence that their suggested integration was shipped.
- `apps/research_agent` is the retained consumer boundary for jobs, durable agents, publication compensation, and VM restart. Fabric's own graph consumers provide the separate graph evidence.
