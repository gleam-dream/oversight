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
| Blueprint → tool catalogs   | Supported schemas, unknown custom schemas, closed input field, lists, nulls, and registry consistency             | General records, tagged unions, refinements, and independent schema validation |
| Relay / Fabric → invocation | Contextual registries, duplicate names, typed dispatch                                                            | Protocol name rules, visibility policy, transport conformance                  |
| Fabric → LLM                | Registry-derived declarations; provider-owned pending continuations                                               | Explicit provider schema subsets and streaming resource ownership              |
| Saga → static graph         | Typed references, codec-backed joins, copied-builder membership, orphan rejection, and closed conditional routing | One lowered definition model preserving explicit activity/child ownership      |
| Saga → durable runner       | Snapshot/restore/approval/child contract signatures                                                               | Restart behavior and usable compensation receipt issuance                      |
| Grind alone                 | Typed immediate/scheduled admission, handles, and cancellation transitions                                        | Transactional storage, leases, running cancellation observation, and retries   |
| Sinal alone                 | Map-shaped fields and foreign callback error classification                                                       | Native atom/map bridge and pinned telemetry behavior tests                     |
| Warden alone                | Configured transactions, callback checks, and checked versus verified identities                                  | Atomic consumption and oidcc token-verification integration                    |

- Graph entry points now name direct activity, approval, and independent-child ownership explicitly. Child completion still does not grant parent compensation capability.

- The shared laboratory `Value` algebra is a prototype convenience, not a settled production dependency graph. Native telemetry terms and transport-specific data still need their actual boundary adapters.

## Registration ergonomics

- Activity registration now uses a reusable typed contract that keeps each codec with its version. Approval and child boundary metadata still need their corresponding refinement.

## Verified checkpoint

- Gleam 1.18.1: twenty-three consumers compile with only their transitive source imports.
- Twenty-three negative fixtures fail with their intended single compiler diagnostic.
- Fifteen interface probe groups execute successfully; no scheduler, database, protocol transport, or unfinished runtime boundary runs.
- Repository formatting and the host flake check pass. These results do not include upstream conformance suites, benchmarks, or restart fault tests.

## Next integration priorities

1. Lower sequential composition, shared references, and closed choices into one Saga definition model while retaining activity, approval, and child ownership and versioned boundaries.
2. Complete child attachment, reattachment, cancellation, typed completion, and compensation-receipt issuance. Completion alone is not parent compensation authority.
3. Connect the schema vocabulary to each protocol/provider capability check, then establish streaming resource ownership.
4. Test actual boundaries against pinned oracles: native telemetry, oidcc with atomic transaction consumption, and transactional queue/workflow recovery.

- The laboratory module names identify responsibilities, not new permanent packages. No package interface is promoted by these checks alone.
- `REFINEMENT-STATUS.md` and its linked refinements supersede the historical stress matrix where a later experiment changed the result.

## Sequencing rule

- Each wave starts from a concrete consumer that the current interface cannot express safely or simply.
- Implement only the constructive representation and pure checks needed to answer that question.
- Review the result independently; run consumer isolation, intended compiler failures, and relevant executable probes.
- Record remaining obligations in the same commit as the refinement.
- Do not count a typed placeholder as runtime evidence, or keep adding public types without a consumer that needs them.
- Move to operational prototypes only after the relevant lifecycle and composition contracts fit together. Do not promote the current playground as production packages.

## Collection refinement

- [Collection and null codecs](COLLECTION-CODECS.md) retain indexed failures and explicit null representation. Optional properties and independent schema validation remain pending.
