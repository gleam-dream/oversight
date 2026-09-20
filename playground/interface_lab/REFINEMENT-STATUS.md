# Interface refinement status

## Working direction

- Keep package boundaries independent. Shared codecs and ordinary typed functions provide reuse without a universal operation type or global request context.
- Use one eventual Saga authoring model for local and durable workflows. Keep execution capabilities explicit rather than hiding persistence behind a local-looking call.
- Keep Fabric's tool-loop policy outside LLM provider continuations. Retain the originating provider with a pending continuation.
- Derive tool discovery from each package's registered input codec. Treat schema availability and protocol compatibility as explicit admission checks.
- Use Sinal-specific map fields at the telemetry boundary. Generic JSON codecs alone do not establish that boundary.

## Evidence map

| Boundary                    | Current evidence                                                                                                                     | Remaining interface work                                                                                            |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| Blueprint → tool catalogs   | Composed codecs, finite string enums, located schema requirements, runtime contracts, document loading, and finite native generation | Number policy, enum generation, actual provider profiles, broader generation, and complete 1.x migration            |
| Relay / Fabric → invocation | Contextual registries and codec-derived dispatch; Relay adds protected modern calls and shared exchange ownership                    | Relay transport and remaining protocol families; Fabric live policy ownership and approval persistence              |
| Fabric → LLM                | Buffered tool turns retain provider continuations; the independent LLM stream owner opens a second scripted stream                   | Fabric streaming composition, token/time budgets, provider profiles, and persisted continuation compatibility       |
| Saga → static graph         | One canonical definition, typed references, wire adapters, scoped metadata, and direct versus child ownership                        | Parallel execution, traversal, retry policy, and definition migration                                               |
| Saga → durable runner       | Unified definition signatures; child links, exact submission receipts, cancellation intent, and compensation claims                  | Local compensation authority, persisted unfinished commands, snapshot codecs, and journal admission                 |
| Grind alone                 | Typed admission, scoped uniqueness, local capacity planning, response resolution, and claim acknowledgement arbitration              | Processor lifecycle, broader uniqueness policies, worker registration, persisted history, and advanced job families |
| Sinal alone                 | Map-shaped fields, descriptor-aware callbacks, duplicate-name admission, and symbolic typed span events                              | Native name/map binding, registration, scoped cleanup, and span execution                                           |
| Warden alone                | Revision-bound consumption, configured scripted backend, strict identity binding, and one canonical identity owner                   | Raw callback/browser binding, provider configuration, token/session operations, and oidcc mapping                   |

- Graph entry points now name direct activity, approval, and independent-child ownership explicitly. Child completion still does not grant parent compensation capability.

- The shared laboratory `Value` algebra is a prototype convenience, not a settled production dependency graph. Native telemetry terms and transport-specific data still need their actual boundary adapters.

## Registration ergonomics

- Activity registration uses one typed factory and a reusable contract that keeps each codec with its version. Child contracts now retain definition and boundary codec versions. Approval registration and the remaining constructor ergonomics still need refinement.

## Verified checkpoint

- Gleam 1.18.1: fifty-three consumers compile with only their transitive source imports.
- Seventy-seven negative fixtures fail with their intended single compiler diagnostic.
- Forty-two interface probe groups execute successfully; no scheduler, database, protocol transport, or unfinished runtime boundary runs.
- Fourteen generated modules compile and run independent native consumers; two additional compiler-negative cases reject runtime values as native types.
- Sixty-one cases agree across static decoding, runtime validation, and independent Draft 2020-12 validation of original and normalized schemas.
- Each committed wave passes its coherent snapshot gate and targeted formatting. The host flake check also passed at `210b7a2`. These results do not include upstream conformance suites, benchmarks, or restart fault tests.

## Next integration priorities

- **Fabric:** Extend the pure policy controller with observed token/time budgets, durable approvals, streaming, and explicit child execution. Preserve provider origin and uncertain-effect handling.
- **Saga:** Extend the durable child contract with persisted unfinished commands. Exercise local compensation authority and local runner outcomes over the canonical definition separately.
- **Grind:** Extend processor lifecycle, management commands, and persisted history around typed uniqueness admission. Keep broader uniqueness policies and backend concurrency evidence separate.
- **Remaining scope:** Keep every unfinished family in [API coverage](../../API-COVERAGE.md), including provider profiles, protocol clients and servers, OAuth operations, dynamic graphs, and advanced job families.
- **Runtime evidence:** Run pinned native telemetry, oidcc, concurrent storage, and queue/workflow recovery oracles after the relevant interface contracts are constructible. These obligations remain distinct from interface completion.

- The laboratory module names identify responsibilities, not new permanent packages. No package interface is promoted by these checks alone.
- `REFINEMENT-STATUS.md` and its linked refinements supersede the historical stress matrix where a later experiment changed the result.

## Sequencing rule

- Each wave starts from a concrete consumer that the current interface cannot express safely or simply.
- Implement only the constructive representation and pure checks needed to answer that question.
- Review the result independently; run consumer isolation, intended compiler failures, and relevant executable probes.
- Record remaining obligations in the same commit as the refinement.
- Do not count a typed placeholder as runtime evidence, or keep adding public types without a consumer that needs them.
- Move to operational prototypes only after the relevant lifecycle and composition contracts fit together. Do not promote the current playground as production packages.

## Exploration completion

- [API coverage](../../API-COVERAGE.md) retains the complete intended capability inventory. An open or partial in-scope family prevents a claim that full API exploration is complete.
- Each accepted family needs a constructive consumer using public contracts and a relevant compiler-negative fixture where the distinction is statically enforceable. A proposed signature or an unfinished runtime body alone does not establish the represented path.
- Each integration must name the owners of admission, execution, cancellation, suspension, persistence, and compensation where those responsibilities apply. Consumers must compose without private representation access or a universal operation type.
- A family may be split into bounded subfamilies without removing its unfinished capabilities. Runtime conformance, concurrency, recovery, performance, and independent package distribution remain separate acceptance obligations.

## Collection refinement

- [Collection and null codecs](COLLECTION-CODECS.md) retain indexed failures and explicit null representation. Object properties and independent schema validation are covered by the subsequent refinements below.

## Object refinement

- [Composable object properties](OBJECT-CODECS.md) distinguish missing, null, and present values and feed Relay discovery and invocation from one codec.

## Alternative and constraint refinement

- [Tagged alternatives and integer constraints](TAGGED-CODECS.md) retain branch payload types and reject out-of-range encoding. Located schema requirements and scripted provider admission are covered separately; actual provider profiles remain open.

## Independent schema evidence

- [Schema agreement oracle](SCHEMA-ORACLE.md) compares emitted documents and actual decoder outcomes. Floating-point normalization and duplicate-key parsing remain outside the corpus.

## Streaming grammar refinement

- [Stream progress and tool completion](STREAM-PROGRESS.md) preserves interleaved call identities and separates completed tools from partial arguments. The stream-owner refinement below adds pure terminal ownership; shared live ownership and actual provider adaptation remain open.

## Unified workflow refinement

- [One workflow definition](UNIFIED-WORKFLOWS.md) joins sequential, shared, and conditional authoring at the checkpoint and queue interfaces. Structured addresses retain repeated occurrences and nested choices.

## Schema admission refinement

- [Tool schema admission](SCHEMA-ADMISSION.md) retains exact structured schemas through typed policy rejection and admitted rendering. Real provider profiles and live transport resource ownership remain open.

## Child attachment and observation

- [Child attachment](CHILD-ATTACHMENT.md) retains output, error, and undo-error codecs in a typed handle and persists only a nongeneric routing link.
- The consumer rebuilds a compatible contract and observes the same historical output after compensation changes. Stored metadata is checked before the retained decoder executes.
- Strict link decoding rejects duplicate and unknown fields. Missing runs, pruned results, unavailable owners, and corrupt output remain distinct.
- Native output and undo-error mismatches are compiler failures. Definition and codec versions are runtime compatibility checks.
- [Child admission](CHILD-ADMISSION.md) adds scripted submission and cancellation intent. Durable compensation claims and redemption are exercised separately below. Local authority, durable journaling, and actual restart recovery remain open.

## Relay exchange ownership

- [Relay exchanges](RELAY-EXCHANGES.md) reuse the existing registry through an opaque invocation that retains each request context.
- Server-owned exchange and invocation identities prevent repeated wire request identifiers and progress tokens from merging calls.
- The pure consumer checks close-before-admission, cancellation, duplicate completion, late callbacks, tokenless progress, and monotonic integer progress.
- Protected registry authorization is exercised separately below. Protocol codecs, HTTP admission, pagination, protected exchange integration, transport cleanup, and bounded owner retention remain open.

## Runtime schema values

- [Runtime schema values](RUNTIME-SCHEMAS.md) retain normalized structural contracts and accepted wire values without creating native Gleam types.
- The consumer checks reordered property/tag equivalence, preserved tuple and nullable structure, invalid-schema rejection, exact validation paths, and missing/null distinctions.
- Static codecs supply contracts only when their schemas are available. Runtime contracts and witnesses cannot substitute for native codecs or application records.
- The independent schema oracle compares all four acceptance paths on its existing corpus.
- Finite document loading and source generation are covered by subsequent refinements. Dynamic graph publication, numeric normalization, limits, and schema migration remain open.

## Finite schema document loading

- [Finite schema documents](SCHEMA-DOCUMENTS.md) enter the existing runtime-contract boundary through a strict parser for Blueprint's rendered forms.
- Unsupported constraints are rejected explicitly. Duplicate keys, malformed supported forms, dialect failures, and schema invariants remain located failures.
- The independent corpus reloads every emitted document and checks normalized contract equality before comparing value acceptance.
- Finite native source generation is covered below. JSON byte parsing, general schema syntax, resource limits, and recursive references remain open.

## Typed span events

- [Typed span events](SPAN-EVENTS.md) compose domain records and empty field sets into distinct start, stop, and exception descriptors.
- Reserved labels prevent application fields from replacing time, context, or exception fields. Ordinary `Result.Error` values remain on the stop-shaped completion path.
- Symbolic layout probes establish logical field composition only. Native emission, timing, context identity, exception re-raising, and scoped attachment remain separate obligations.

## Native source generation

- [Generated codecs](GENERATED-CODECS.md) compile finite object contracts into ordinary native records and composed codecs. Runtime contracts remain distinct from native types.
- Downstream consumers check schema equality, missing/null distinctions, bounded encoding, empty objects, nested nullable values, and exact unusual wire names without importing the generator.
- Broader schema support, application-facing naming, committed-output tooling, compatibility adapters, and independent package distribution remain open.

## Worker response resolution

- [Worker outcomes](WORKER-OUTCOMES.md) keep ordinary typed functions reusable while resolving scheduling responses with explicit accounting, clock, and retry policy.
- Unknown effects request reconciliation without invoking retry policy. Worker cancellation and proposed completion do not arbitrate an external cancellation race.
- Current-attempt ownership below adds claim identity, renewal, and a scripted atomic acknowledgement port. Actual atomic storage, committed history, and runtime scheduling remain open.

## Stream terminal ownership

- [Stream ownership](STREAM-OWNERSHIP.md) composes the progress grammar with terminal transitions, late-event suppression, protocol failure, and cleanup commands for one sequenced history.
- A pending tool turn retains its original continuation callback. Preparation validates exact result identifiers without opening; opening yields an adapter-owned source that can stream the next turn.
- The consumer opens and consumes a second scripted stream through two providers sharing the same continuation and source types.
- Copied live handles, concurrent reads, process loss, transport cleanup, backpressure, and continuation replay still require runtime evidence.

## Current-attempt ownership

- [Claim ownership](CLAIM-OWNERSHIP.md) separates retry accounting from ownership identity and renewal revision. Acknowledgement checks the current lease while permitting the original owner after renewal.
- The injected store owns current-record lookup, clock selection, decision, and commit. Missing records, unavailability, and unknown commit preserve the submitted command without inventing a winner.
- Cancellation intent, committed cancellation, and acknowledged attempt outcomes remain distinct. Retry and snooze acknowledgements do not finish the job.
- Atomic storage, command receipts, renewal liveness, and job-state projection remain open.

## Login consumption

- [Login consumption](LOGIN-CONSUMPTION.md) keeps stored revisions and terminal records in the existing transaction owner. Binding checks produce typed code or denial outcomes without deciding expiry.
- The injected store owns current-record lookup, authoritative clock sampling, and consumption. Terminal records take precedence over stale revisions; unknown commit never grants exchange authority.
- Public consumption returns no secret-bearing capability. Private backend-to-identity orchestration is covered by the verified-login experiment; concurrent storage remains open.

## Protected tool authorization contract

- The [Relay resource authorization contract](../../research/relay-resource-authorization-contract.md) defines the protected registry configuration, grant reuse checks, visibility filtering, and authorization exercised below.
- Application context remains explicit and application-owned. Warden identity and independently verified bearer grants cannot substitute for one another.
- The [resource authorization experiment](RESOURCE-AUTHORIZATION.md) now exercises the protected registry and grant checks. Protected transport integration, protocol responses, token verification, anonymous access, and pagination remain open.

## Verified login composition

- [Verified login](VERIFIED-LOGIN.md) keeps consumption, backend invocation, attestation acceptance, and identity construction in one owner. The Warden facade shares that identity with existing request-scoped tools.
- Configuration mismatch fails before store access; rejected consumption prevents exchange. Failed exchange and rejected attestations cannot restore pending state or issue identity.
- The configured adapter remains a trust boundary. Live token verification, exception containment, atomic storage, and the full token/session lifecycle remain open.

## Resource grant composition

- [Resource authorization](RESOURCE-AUTHORIZATION.md) reuses existing Relay registries with explicit application context. Endpoint scopes and per-tool scopes remain separate checks.
- Grants retain all accepted scopes; protected entry points reject wrong-resource and insufficient grants before policy or decoding. Hidden and denied named calls cannot invoke the tool handler.
- The web-account policy compiles against both Warden identity and the independent API grant. Verifier provenance, protected transport routing, and runtime authorization remain explicit obligations.

## Descriptor-aware observation

- [Descriptor-aware observation](SCOPED-OBSERVATION.md) delivers the selected event through one configured handler and preserves typed decoding failures. Nonempty attachment signatures require shared measurement and metadata types.
- Duplicate logical names fail before either global or scoped registration reaches its runtime boundary. The invalid scoped case cannot invoke its work callback.
- Valid attachment and scoped calls compile only. Private identifier allocation, native failure reporting, cleanup, and callback lifetime remain subject to the [pinned native oracle](../../research/sinal-lifetime-contract.md). Scope exit does not imply callback quiescence.

## Child admission and cancellation

- [Child admission](CHILD-ADMISSION.md) retains encoded input and native codecs through new admission, command replay, and ambiguous replies. Exact accepted-request and stored-metadata checks precede handle construction.
- Uncertain submission retains its original owner route. Invalid successful replies remain recoverable because admission may already have committed.
- Cancellation records intent separately from eventual outcome and preserves historical child completion.
- Immutable consumer receipts exercise replay and conflict without claiming shared storage, transaction isolation, or process recovery. The compensation refinement below adds owner-issued claims and request admission.

## Agent policy and bounded model turns

- [Agent policy](AGENT-POLICY.md) composes contextual tools and the existing provider continuation through explicit inspection, approval, invocation, and report acceptance.
- Host-issued incarnations distinguish separate controller starts of the same logical run. Freshness, approval authenticity, and shared live ownership remain host or runtime obligations.
- Model-visible business outcomes remain separate from policy or codec failures and uncertain effects. Host failures and unresolved effects block continuation.
- Positive model-turn limits include attempted continuations and preserve terminal failure state. Token/time accounting, streamed progress, persistence, and child execution remain open.

## Typed uniqueness admission

- [Typed uniqueness](UNIQUE-JOBS.md) keeps versioned projected keys separate from stable submission commands. Recovery retains the original route, exact request, and actual native codecs.
- Existing jobs retain their actual queue route. Checked worker binding precedes typed result-handle construction; scheduled replacement preserves the prior job and payload.
- Immutable records exercise candidate matching and command replay. Database concurrency, durable ledgers, broad replacement, bulk policies, and worker execution remain open.

## Durable child compensation authority

- [Child compensation](CHILD-COMPENSATION.md) keeps successful completion separate from an owner-issued compensation claim. Persisted references require owner-record validation and the actual undo-error codec before rebinding.
- Claim and request recovery preserve original routing and commands. One claim admits one operation even if a caller copies the receipt and changes its command identifier.
- Historical success remains representable after output pruning. Journal retention and compensation progress remain separate owner facts.
- Immutable ledgers exercise replay, competing claims, lost replies, expiry, pruning, and typed undo observation. Concurrent storage, compensator execution, durable restart, and local authority remain open.

## Published Blueprint compatibility

- The [separate compatibility playground](../blueprint_compatibility/README.md) runs actual pinned JSON Blueprint 1.7.1 and 1.1.0 dependencies without adding dependencies to this laboratory.
- An explicit encoder adapts the current upstream decoder into the existing codec representation. Legacy message envelopes remain caller-owned; schema discovery remains unavailable.
- Historical empty-constructor acceptance differs between the two releases. Independent validation exposes 1.7.1 empty-object and tuple schema disagreements; the adapter does not claim to correct them.
- Two additional compiler negatives reject an upstream decoder as a native codec and an encoder for a different native type. These separate-project checks are not included in the laboratory counts above.
- Complete source migration, recursive schemas, numeric support, error-path compatibility, generation integration, and the final package API remain open.

## Finite string enums

- The [finite enum experiment](ENUM-CODECS.md) retains one checked label/value table through native encoding, decoding, schema rendering, document loading, and runtime validation. Duplicate labels and native values are construction errors.
- A Relay consumer uses the same nested enum codec for declaration and dispatch. Runtime-validated wire values remain distinct from native enum values.
- Independent schema checks include exact labels, empty strings, quotes, Unicode, unknown labels, and nested enum collections. The published JSON Blueprint compatibility probes remain valid after the core extension.
- Source generation explicitly rejects enum schemas. Generated constructors, aliases, number policy, and broader legacy migration remain separate work.

## Modern Relay server composition

- [Modern Relay](MODERN-RELAY.md) joins parsed-value admission with the protected registry and existing exchange owner. Discovery, listing, and calls share exchange identity; immediate responses cannot bypass a previous completion or close.
- Calls retain the actual grant, application context, and request metadata through explicit invocation effects. Domain failures, malformed requests, unsupported versions, and internal encoding failures remain distinct.
- Five actual responses match the frozen upstream schema; fourteen malformed mutations fail validation. These checks establish response structure for this slice, not complete protocol conformance.
- HTTP transport, byte parsing, general JSON numbers, pagination, cache ownership, remaining method families, and revision compatibility remain open.

## Local queue configuration

- [Queue configuration](QUEUE-CONFIGURATION.md) validates positive local concurrency, nonnegative occupancy, and duplicate full routes. Public configuration records support ordinary pause, resume, and scale updates.
- A two-owner maintenance consumer admits a typed unique job while processing is paused and acknowledges existing work through the unchanged claim owner. Scaling below occupancy proposes no new claims until work drains.
- Dispatch plans are advisory. Processor ownership, atomic reservation, management commands, global limits, and live configuration remain open.

## Serial local workflow execution

- [Local execution](LOCAL-EXECUTION.md) interprets direct activities, shared dependencies, and adapters from the canonical definition. Callback work remains separate from reducer transitions.
- Successful activities retain native compensation closures before output encoding. Failure and cancellation preserve reverse completion order, located undo failures, and uncompensated successes.
- Correlated completions protect the current state from foreign or repeated delivery. They do not prevent replaying copied state or repeating effects.
- Approval, child, and choice nodes reject admission before callbacks. Retry policy, parallel scheduling, post-success compensation authority, and durable recovery remain open.

## Configured structured model turns

- [Structured turns](PROVIDER-STRUCTURED-TURNS.md) retain configured model options, schema policy, tool declarations, native output codecs, and the originating continuation through multiple buffered tool rounds.
- Two scripted adapters exercise distinct native options and located policies. Unsupported schema, invalid request, and result identity failures reject before transport or continuation.
- Output schema validation precedes native mapping. LLM and Fabric share call/result correlation without sharing application tool policy.
- Real provider profiles, streaming admission, persisted continuation, usage accounting, and transport ownership remain open.
