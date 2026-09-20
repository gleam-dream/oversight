# Interface refinement status

## Working direction

- Keep package boundaries independent. Shared codecs and ordinary typed functions provide reuse without a universal operation type or global request context.
- Use one eventual Saga authoring model for local and durable workflows. Keep execution capabilities explicit rather than hiding persistence behind a local-looking call.
- Keep Fabric's tool-loop policy outside LLM provider continuations. Retain the originating provider with a pending continuation.
- Derive tool discovery from each package's registered input codec. Treat schema availability and protocol compatibility as explicit admission checks.
- Use Sinal-specific map fields at the telemetry boundary. Generic JSON codecs alone do not establish that boundary.

## Evidence map

| Boundary                    | Current evidence                                                                                                  | Next decisive question                                                         |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Blueprint → tool catalogs   | Supported schemas, unknown custom schemas, closed input field, registry consistency                               | General records, tagged unions, refinements, and independent schema validation |
| Relay / Fabric → invocation | Contextual registries, duplicate names, typed dispatch                                                            | Protocol name rules, visibility policy, transport conformance                  |
| Fabric → LLM                | Registry-derived declarations; provider-owned pending continuations                                               | Explicit provider schema subsets and streaming resource ownership              |
| Saga → static graph         | Typed references, codec-backed joins, copied-builder membership, orphan rejection, and closed conditional routing | One lowered definition model                                                   |
| Saga → durable runner       | Snapshot/restore/approval/child contract signatures                                                               | Restart behavior and usable compensation receipt issuance                      |
| Grind alone                 | Typed workers, payload codecs, injected dependencies                                                              | Schedule/cancel lifecycle and persistence transactions                         |
| Sinal alone                 | Map-shaped fields and foreign callback error classification                                                       | Native atom/map bridge and pinned telemetry behavior tests                     |
| Warden alone                | Pending versus verified identities                                                                                | Configured clients and caller-owned concurrent login transactions              |

## Sequencing rule

- Each wave starts from a concrete consumer that the current interface cannot express safely or simply.
- Implement only the constructive representation and pure checks needed to answer that question.
- Review the result independently; run consumer isolation, intended compiler failures, and relevant executable probes.
- Record remaining obligations in the same commit as the refinement.
- Do not count a typed placeholder as runtime evidence, or keep adding public types without a consumer that needs them.
- Move to operational prototypes only after the relevant lifecycle and composition contracts fit together. Do not promote the current playground as production packages.
