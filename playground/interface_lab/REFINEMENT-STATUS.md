# Interface refinement status

## Working direction

- Keep package boundaries independent. Shared codecs and ordinary typed functions provide reuse without a universal operation type or global request context.
- Use one eventual Saga authoring model for local and durable workflows. Keep execution capabilities explicit rather than hiding persistence behind a local-looking call.
- Keep Fabric's tool-loop policy outside LLM provider continuations. Retain the originating provider with a pending continuation.
- Derive tool discovery from each package's registered input codec. Treat schema availability and protocol compatibility as explicit admission checks.
- Use Sinal-specific map fields at the telemetry boundary. Generic JSON codecs alone do not establish that boundary.

## Evidence map

| Boundary                    | Current evidence                                                                                                   | Next decisive question                                                       |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| Blueprint → tool catalogs   | Supported schemas, unknown custom schemas, closed records, optional fields, lists, nulls, and registry consistency | Provider feature admission, numbers, and broader schema corpus               |
| Relay / Fabric → invocation | Contextual registries, duplicate names, typed dispatch                                                             | Protocol name rules, visibility policy, transport conformance                |
| Fabric → LLM                | Registry-derived declarations; provider-owned pending continuations                                                | Explicit provider schema subsets and streaming resource ownership            |
| Saga → static graph         | One canonical definition, typed references, wire adapters, scoped metadata, and explicit operation ownership       | Child lifecycle, local execution, and definition migration                   |
| Saga → durable runner       | Snapshot/restore/approval/child contract signatures                                                                | Restart behavior and usable compensation receipt issuance                    |
| Grind alone                 | Typed immediate/scheduled admission, handles, and cancellation transitions                                         | Transactional storage, leases, running cancellation observation, and retries |
| Sinal alone                 | Map-shaped fields and foreign callback error classification                                                        | Native atom/map bridge and pinned telemetry behavior tests                   |
| Warden alone                | Configured transactions, callback checks, and checked versus verified identities                                   | Atomic consumption and oidcc token-verification integration                  |

- Graph entry points now name direct activity, approval, and independent-child ownership explicitly. Child completion still does not grant parent compensation capability.

- The shared laboratory `Value` algebra is a prototype convenience, not a settled production dependency graph. Native telemetry terms and transport-specific data still need their actual boundary adapters.

## Registration ergonomics

- Activity registration uses one typed factory and a reusable contract that keeps each codec with its version. Approval and child boundary metadata still need their corresponding refinement.

## Verified checkpoint

- Gleam 1.18.1: thirty-four consumers compile with only their transitive source imports.
- Thirty-six negative fixtures fail with their intended single compiler diagnostic.
- Twenty-six interface probe groups execute successfully; no scheduler, database, protocol transport, or unfinished runtime boundary runs.
- Fourteen generated modules compile and run independent native consumers; two additional compiler-negative cases reject runtime values as native types.
- Thirty-eight cases agree across static decoding, runtime validation, and independent Draft 2020-12 validation of original and normalized schemas.
- Each committed wave passes its coherent snapshot gate and targeted formatting. The most recent host flake check passed at `aad31c2`. These results do not include upstream conformance suites, benchmarks, or restart fault tests.

## Next integration priorities

1. Exercise the local runner contract over the canonical Saga definition.
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

## Object refinement

- [Composable object properties](OBJECT-CODECS.md) distinguish missing, null, and present values and feed Relay discovery and invocation from one codec.

## Alternative and constraint refinement

- [Tagged alternatives and integer constraints](TAGGED-CODECS.md) retain branch payload types and reject out-of-range encoding. Provider feature admission remains separate.

## Independent schema evidence

- [Schema agreement oracle](SCHEMA-ORACLE.md) compares emitted documents and actual decoder outcomes. Floating-point normalization and duplicate-key parsing remain outside the corpus.

## Streaming grammar refinement

- [Stream progress and tool completion](STREAM-PROGRESS.md) preserves interleaved call identities and separates completed tools from partial arguments. Live ownership and provider adaptation remain open.

## Unified workflow refinement

- [One workflow definition](UNIFIED-WORKFLOWS.md) joins sequential, shared, and conditional authoring at the checkpoint and queue interfaces. Structured addresses retain repeated occurrences and nested choices.

## Schema admission refinement

- [Tool schema admission](SCHEMA-ADMISSION.md) retains exact structured schemas through typed policy rejection and admitted rendering. Real provider profiles and resource ownership remain open.

## Child attachment and observation

- [Child attachment](CHILD-ATTACHMENT.md) retains output, error, and undo-error codecs in a typed handle and persists only a nongeneric routing link.
- The consumer rebuilds a compatible contract and observes the same historical output after compensation changes. Stored metadata is checked before the retained decoder executes.
- Strict link decoding rejects duplicate and unknown fields. Missing runs, pruned results, unavailable owners, and corrupt output remain distinct.
- Native output and undo-error mismatches are compiler failures. Definition and codec versions are runtime compatibility checks.
- Submission, cancellation, compensation receipts, durable journaling, and actual restart recovery remain open.

## Relay exchange ownership

- [Relay exchanges](RELAY-EXCHANGES.md) reuse the existing registry through an opaque invocation that retains each request context.
- Server-owned exchange and invocation identities prevent repeated wire request identifiers and progress tokens from merging calls.
- The pure consumer checks close-before-admission, cancellation, duplicate completion, late callbacks, tokenless progress, and monotonic integer progress.
- Protocol codecs, HTTP admission, pagination, authorization, transport cleanup, and bounded owner retention remain open.

## Runtime schema values

- [Runtime schema values](RUNTIME-SCHEMAS.md) retain normalized structural contracts and accepted wire values without creating native Gleam types.
- The consumer checks reordered property/tag equivalence, preserved tuple and nullable structure, invalid-schema rejection, exact validation paths, and missing/null distinctions.
- Static codecs supply contracts only when their schemas are available. Runtime contracts and witnesses cannot substitute for native codecs or application records.
- The independent schema oracle compares all four acceptance paths on its existing corpus.
- Document loading, source generation, dynamic graph publication, numeric normalization, limits, and schema migration remain open.

## Finite schema document loading

- [Finite schema documents](SCHEMA-DOCUMENTS.md) enter the existing runtime-contract boundary through a strict parser for Blueprint's rendered forms.
- Unsupported constraints are rejected explicitly. Duplicate keys, malformed supported forms, dialect failures, and schema invariants remain located failures.
- The independent corpus reloads every emitted document and checks normalized contract equality before comparing value acceptance.
- JSON byte parsing, general schema syntax, source generation, resource limits, and recursive references remain open.

## Typed span events

- [Typed span events](SPAN-EVENTS.md) compose domain records and empty field sets into distinct start, stop, and exception descriptors.
- Reserved labels prevent application fields from replacing time, context, or exception fields. Ordinary `Result.Error` values remain on the stop-shaped completion path.
- Symbolic layout probes establish logical field composition only. Native emission, timing, context identity, exception re-raising, and scoped attachment remain separate obligations.

## Native source generation

- [Generated codecs](GENERATED-CODECS.md) compile finite object contracts into ordinary native records and composed codecs. Runtime contracts remain distinct from native types.
- Downstream consumers check schema equality, missing/null distinctions, bounded encoding, empty objects, nested nullable values, and exact unusual wire names without importing the generator.
- Broader schema support, application-facing naming, committed-output tooling, compatibility adapters, and independent package distribution remain open.
