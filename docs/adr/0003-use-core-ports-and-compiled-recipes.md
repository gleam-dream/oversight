# Use core ports and compiled recipes

<a id="adr-0003"></a>

## Decision

- The intended package set contains nine core libraries and two PostgreSQL adapters.
- Classification belongs to LLM Wire; Fabric owns its classification operation and protocol-neutral invocation capability.
- Composition between Fabric, Saga, Relay, and Hellhound uses public ports and compiled consumer recipes. The former `fabric_typesafe`, `fabric_saga`, and `fabric_relay` packages are retired.
- Retain `saga_postgres` and `fabric_postgres` as separate packages because they isolate substantial external infrastructure and correctness obligations.

## Alternatives and consequences

- Keeping a package for every pair would add release and dependency coordination around small translations. Moving sibling protocol knowledge into core would create unnecessary coupling.
- A recipe is appropriate when it expresses application policy through stable public contracts. Substantial shared logic belongs to a dependency-neutral capability with one semantic owner.
- A recipe may become a package when multiple applications duplicate a growing mapping and maintaining it costs more than the package boundary. A line-count threshold alone is not the criterion.
- Compilation checks keep recipes honest, but failure evidence, authorization, cancellation, and resource ownership still need behavioral tests at the composed boundary.

## Provenance

- Accepted on 5 October 2026 in [package ownership decisions](https://github.com/gleam-dream/oversight/blob/3baff70/docs/release-api/DECISIONS.md).
- Current examples are represented by `apps/support_desk`, `apps/tool_hub`, `apps/extractor`, and Fabric's retained compiled recipes. Current package repositories own the detailed contracts.
