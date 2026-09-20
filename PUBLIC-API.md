# Initial public API freeze

This freeze selects the smallest typed, composable surface that supports the
demonstrated package roles. It does not declare every API-COVERAGE row complete.
Open and Partial rows remain backlog. This inventory describes intended package
facades from the prototypes; it does not claim that production packages or
versions have been published. Laboratory protocol machinery and unfinished
bodies are evidence for later implementation, not accepted public API.

## Intended initial facades

- **Blueprint:** `Value`, `Codec`, schema derivation, finite runtime contracts,
  validation, and checked encode/decode combinators. One canonical exact
  `Number` represents every numeric value within Blueprint’s schema/value model.
  Native `Int` and `Float` use explicit checked construction and projection, not
  parallel JSON `Value` cases. In particular, `from_int` returns
  `Result(Number, IntegerConstructionError)`: JavaScript rejects nonfinite,
  noninteger, and unsafe native inputs, while Erlang retains exact bignums.
  Integer projection also observes a caller-supplied digit limit and the target's
  native range. The current integer-only `Value.Int` migration is deferred.
  Native source generation, including positional enums and planned application
  naming, remains experimental tooling outside this facade.
- **Standalone LLM:** provider-neutral requests and outcomes, tool declarations,
  calls and results, exact call-result correlation, configured capability
  admission, streamed progress and terminal events, and provider-origin
  continuation. Provider transports, live stream ownership, persistence
  envelopes, retries, usage, and deadline enforcement remain adapter/runtime
  work.
- **Fabric:** typed contextual tools and registries; the bounded action
  controller with explicit policy, approval, report acceptance, host failure,
  and uncertain-effect reconciliation. Fabric consumes LLM contracts and does
  not own provider networking, workflow journals, queues, or a second child
  runtime. Durable controller storage and streamed execution remain
  implementation work.
- **Saga:** typed static workflow authoring through definitions, activities,
  approvals, child contracts, codecs, and implemented local transitions. The
  intended durable facade exposes opaque run/child handles and typed status,
  result, signal, cancellation, and compensation outcomes. `saga_checkpoint`
  and `saga_grind` store ports, commands, receipts, snapshots, compatibility
  records, and unfinished functions are internal design evidence until a
  runner validates them.
- **Grind:** typed workers, queue routes and configuration, immediate and
  scheduled admission, opaque job handles, uniqueness policy, and implemented
  pure job/claim transitions. The intended facade keeps typed status, result,
  cancellation, and management outcomes. Storage engines, claim ledgers,
  processor protocols, callback receipts, and every `todo`-backed operation
  stay internal until runtime implementation.
- **Sinal:** typed event descriptors and fields; emit, attach, attach-many,
  detach, scoped lifetime, and typed span shapes; package-owned Fabric, Saga,
  and Grind observation descriptors. Backend injection is an adapter seam.
  Native telemetry maps/names, callback concurrency, failure forwarding, and
  span execution remain runtime work. Observations report completed
  transitions and never control them.
- **Relay:** typed contextual tools, registries, declarations and dispatch;
  protected grants/policy; the current sans-I/O discovery/list/call exchange
  for its pinned revision. HTTP, stdio, client flows, remaining protocol
  families, and conformance behavior remain separate adapters or later slices.
- **Warden:** validated login inputs, login planning/callback outcomes, opaque
  verified identity and session, and typed session-operation outcomes. Web
  identity remains distinct from Relay bearer authorization. Transaction-store
  ports, custody and refresh commands/receipts, scripted ledgers, and unfinished
  provider operations remain internal evidence; oidcc, cryptography, storage,
  refresh, and logout require runtime validation.

## Package seams

Blueprint is required only for JSON Schema-aware paths (schema declaration, schema-derived validation, or runtime schema contracts). Ordinary JSON serialization should use standard Gleam JSON encoders and decoders. Any optional reusable codec abstraction must remain independent of Blueprint and schema support; no new codec package or API is prescribed. Schema availability is an explicit capability, not a universal serialization constraint.

Blueprint supplies schema-aware contracts without owning transports. LLM owns provider
interaction; Fabric owns tool policy and the agent loop. Saga owns workflow
state and compensation; Grind owns delivery. Warden owns web identity; Relay
owns resource grants and protocol authorization. Sinal receives package-owned
facts after state transitions. No universal operation, identity, request
context, lifecycle event, retry policy, or persistence protocol is introduced.

## Resolved decisions and stop rule

The three decisions are settled: exact numbers within Blueprint’s schema/value model
with checked native construction and projection; source generation excluded from
the initial facade; and durable Saga, Grind, and Warden protocol machinery kept
internal.
Lab constructors for those runtime protocols may remain visible where prototype
consumers need them to compile; this freeze requires no source visibility
change and does not promote them to package API.

After this inventory and the already-gated package-observation refinement,
start no new interface-refinement wave. Remaining Open and Partial
API-COVERAGE rows are implementation backlog. Reopen a public API only when a
real implementation yields a concrete caller mismatch. Coverage backlog does
not block the freeze, and `todo` bodies never count as implemented public
behavior.
