# Initial public API freeze

This freeze selects the smallest typed, composable surface that supports the
demonstrated package roles. It does not declare every API-COVERAGE row complete.
Open and Partial rows remain backlog. This inventory describes intended package
facades from the prototypes; it does not claim that production packages or
versions have been published. Laboratory protocol machinery and unfinished
bodies are evidence for later implementation, not accepted public API.

## HTTP Gun addition — 29 September 2026

The [HTTP Gun design](http-gun-design.md#public-interface-direction) adds an independent HTTP client, owned byte body, bounded collection, scripts and cassette record/playback. Reuse standard Gleam HTTP values; keep client/body/session handles opaque and lifecycle effects explicit. This is a candidate facade, not an addition to the frozen implemented APIs. The [facade probe](research/http-gun-interface-probe.md) records compiler-only evidence; runtime acceptance and independent consumers remain required.

The current ownership decision also places conversation and durable continuation in Fabric or the caller. LLM Wire retains provider response data and per-request validation; generic transport moves to HTTP Gun when implemented. Earlier continuation laboratory excerpts remain historical evidence.

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
  Native type/codec generation and the narrower codec-schema materialization
  experiment remain test/dev tooling outside this facade. Materialized schema
  accessors reconstruct the schema already stored by a codec; they do not parse
  external JSON Schema into native domain types or codecs.
- **Standalone LLM:** provider-neutral requests and outcomes, tool declarations,
  calls and results, exact call-result correlation, configured capability
  admission, streamed progress and terminal events, and caller-owned
  assistant response data. Provider decoding and semantic limits remain LLM
  responsibilities; generic HTTP resources move to HTTP Gun. Fabric or another
  caller owns conversation, persistence and subsequent requests.
- **Fabric:** typed contextual tools and registries; the bounded action
  controller with explicit policy, approval, report acceptance, host failure,
  and uncertain-effect reconciliation. Fabric consumes LLM contracts and does
  not own provider networking, workflow journals, queues, or a second child
  runtime. Durable controller storage and streamed execution remain
  implementation work.
- **Saga:** the first local-execution release, delivered and tested against
  [`saga-design.md`](saga-design.md) and recorded capability-by-capability in
  [`saga/CAPABILITIES.md`](https://github.com/gleam-dream/saga/blob/main/CAPABILITIES.md).
  Local, in-memory execution only — no durable journals, persistence, or
  distributed coordination yet; see "Deferred and future Saga capabilities"
  below for what those durable/runtime-graph capabilities looked like as
  originally scoped, and for where they now live.

  - `saga`: typed workflow authoring. `Workflow(i, o, e, u)` (opaque, built
    once by `define` and never re-evaluated by a run); `Port(a, e, u)`
    (opaque, a typed reference to a value produced somewhere in the graph);
    `Step(i, o, e, u)` (opaque) via `step`, `undo`, `compensate`, `timeout`,
    `map_step_errors`; combinators `perform`, `map`, `both`,
    `all(first: Port(a, e, u), rest: List(Port(a, e, u))) -> Port(List(a), e, u)`
    (no empty-list case — a caller with zero ports has no `first` to pass);
    `embed` (sequential composition, nested scope addressing); `define`,
    `name`, `describe`, `map_errors`. Recovery/undo vocabulary: `Recovery(o, e,
u)` (`Retry`, `RetryAfter`, `Continue`, `Abort`, `AbortAfterCleanupFailure`,
    `Hold`), `Undo(u)` (`NoUndo`, `UndoWith`). Definition-time types:
    `DefinitionError` (`EmptyWorkflowName`, `EmptyStepName`,
    `InvalidMaxAttempts`, `InvalidTimeout`, `ForeignPort`, `OrphanStep`),
    `StepDescriptor`, `StepAddress` (with `address_to_string`), `Attempt`,
    `AttemptFailure(e)`, `Crash`, `CrashClass`, `CrashOrTimeout`.
  - `saga/execution`: run lifecycle. `Config` (`max_concurrency`, `deadline:
Option(Int)`, `step_timeout: Option(Int)` — defaults to `Some(60_000)`
    via `config()`, `settle_timeout`, `cleanup_timeout`), `config`, `validate`,
    `ConfigError`; `run`, `start`, `await`, `cancel`, `progress`, `pid`,
    `run_id`; `Execution(o, e, u)` (opaque); `RunError`, `AwaitError`,
    `ProgressError`; `Outcome(o, e, u)` — `Completed`,
    `CompletedWithUnknownEffects(output, unknown_effects)` (the case a step's
    attempt was killed by its own timeout but a recovery decision let the run
    reach a normal output anyway), `Failed`, `Cancelled`, `Unresolved`;
    `Cause(e)` — `StepFailed`, `StepCrashed`, `StepTimedOut`,
    `RetryLimitReached`, `RetrySuperseded` (a retry refused only because
    settling had already begun, distinct from an exhausted attempt budget),
    `OutputCrashed`, `DeadlineExceeded`; `Settlement(e, u)`, `UndoFailure(u)`,
    `CompensationFailure(u)`, `CancelReason`, `Phase`, `StepState`,
    `StepProgress`, `Progress`.
  - `saga/observation`: package-owned Sinal event descriptors —
    `run_started`, `run_stopped`, `step_started`, `step_stopped`,
    `compensation_stopped`, `undo_stopped` — with their typed measurement and
    metadata records (`RunStartMeasurements`, `RunMetadata`,
    `RunStopMeasurements`, `OutcomeKind`, `RunStopMetadata`,
    `StepStartMeasurements`, `StepMetadata`, `StepStopMeasurements`,
    `AttemptKind`, `StepStopMetadata`, `DecisionKind`, `CompensationMetadata`,
    `UndoKind`, `UndoMetadata`).
  - `saga/testing`: one helper, `wait_until(execution, matching:, within:)`,
    polling `execution.progress` until a caller predicate accepts a snapshot
    or a deadline elapses; `WaitError` (`WaitTimedOut`, `RunEnded`). Saga
    ships no step-blocking gate itself (generic BEAM concurrency, not
    Saga-specific); see `saga`'s README for the recipe.

  ### Deferred and future Saga capabilities

  The original design's durable-execution and runtime-authored-graph surface
  is retained scope, not cancelled, and is not part of this release's public
  API: durable PostgreSQL journals, checkpoints, freeze/thaw, snapshot
  codecs, restore, migration; `saga_grind` durable integration and outbox;
  durable approvals, approval signals, and command dedup/revision checks;
  process-loss resume; independent children and child compensation
  authority; post-success undo; value-dependent `and_then` and bounded
  traversal; runtime-authored schema graphs, registry/publication, and
  parametric runtime nodes (`Identity`, `Delay`, `Choose`, `Collect`,
  `Constant`, `Validate`, `Map`, `LLM`); visual editors and graph export.
  Closure serialization and unrestricted heterogeneous runtime steps are
  **excluded**, not deferred — a deliberate design decision, not backlog. See
  [`saga/CAPABILITIES.md`](https://github.com/gleam-dream/saga/blob/main/CAPABILITIES.md)
  for the full delivered/deferred/excluded inventory and the rationale for
  each entry.

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
