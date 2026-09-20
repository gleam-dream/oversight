# `sinal` — typed native telemetry

## Scope and runtime ownership

Sinal is a typed facade over BEAM `telemetry`. It preserves synchronous dispatch,
the shared handler registry, native event names and maps, callback isolation,
and span semantics. Typed descriptors constrain cooperating Gleam producers and
subscribers; foreign emitters still require decoding at every callback boundary.

The original actor-per-event design is replaced by the native registry. An actor
would change process identity, ordering, backpressure, failure, and interoperability.
A descriptor is immutable configuration, not a live channel requiring startup
under a supervisor. Event definition therefore allocates no event process.

| Concern                                 | Sinal contract                                                  | Runtime owner                             |
| --------------------------------------- | --------------------------------------------------------------- | ----------------------------------------- |
| Event name                              | Typed descriptor with a logical name and trusted native binding | Native adapter binds an atom list         |
| Measurements and metadata               | Distinct native types described by map-shaped fields            | Descriptor encoders and callback decoders |
| Handler configuration                   | Ordinary typed values captured by closures                      | Private adapter configuration             |
| Registration and lookup                 | Shared native registry; identifiers are global keys             | `telemetry`                               |
| Callback execution                      | Synchronous in the emitting process; no order guarantee         | `telemetry`                               |
| Callback failure removal                | Report typed failure, then invoke native failure behavior       | Adapter and `telemetry`                   |
| Export, buffering, metrics, supervision | Explicit downstream integration                                 | Separate adapter or application           |

The [initial public API freeze](PUBLIC-API.md) includes typed descriptors,
fields, emit, attach, attach-many, detach, scoped lifetime, and typed span
shapes. It does not claim that the native adapter or span runtime is implemented.
Full handler, span, concurrency, and interoperability requirements remain backlog.

## Core pieces and native map boundary

`Event(m, d)` is the canonical typed descriptor. It retains event identity and
separate `Fields(m)` and `Fields(d)` contracts. This replaces the original split
between a live `EventDefinition` and an event envelope; callback arguments carry
the selected descriptor and the decoded measurements and metadata explicitly.
`Handler(m, d, e)` retains a callback returning `Result(Nil, e)`.

`Fields` composes reusable map-shaped field groups, including empty groups,
pairs, and bidirectional mappings into domain records. Composition rejects
duplicate declared labels. Encoding retains failures; decoding distinguishes
missing, duplicate, and invalid fields while tolerating unrelated foreign fields.
Mappings retain labels but require their own inverse-law evidence.

The production boundary is a native BEAM map with trusted atom keys. Event names
are native atom lists, not dotted runtime strings. Logical string labels in the
laboratory are diagnostic identities; their binding to trusted existing atoms
must be injective. No FFI may allocate atoms from request values, tenant names,
provider names, or other untrusted runtime strings. The original dot-free label
convention is not a native telemetry restriction or a substitute for atom safety.

The laboratory `FieldMap` uses string/value pairs and Blueprint codecs to test
structure. It is not a native Erlang map and does not make JSON Blueprint a
production dependency of Sinal. Telemetry does not require JSON Schema; any
ordinary JSON export belongs to an adapter using standard Gleam JSON facilities,
not a mandatory Blueprint dependency. Native references, exception reasons, stacktraces,
and other BEAM terms must survive the intended native boundary without JSON
serialization. Dynamic foreign terms remain confined to the adapter and are
decoded before entering typed handlers.

Two independently defined descriptors can share a raw event name with different
shapes. A descriptor cannot constrain a foreign emitter or establish global type
agreement. Every callback must resolve its selected descriptor and decode both
maps, even when emission normally comes from a typed Sinal library.

## How a library emits events

A library exports a descriptor beside the API it observes. A request-stop
descriptor can pair a native duration and response-byte count with method, URL,
and status metadata. Producers and subscribers reuse that descriptor without
importing a scheduler or persistence implementation.

`emit` takes a configured backend, descriptor, measurements, and metadata.
Encoding completes before the backend receives the event; encoding failure
invokes no backend. Backend availability or rejection is separate from encoding
failure. The emission result never contains a subscriber's typed handler error,
because native telemetry isolates callback failures while continuing dispatch.

The configured backend supplies emission and attachment operations. The
[injected observation experiment](playground/interface_lab/INJECTED-OBSERVATION.md)
executes this boundary over an independently keyed process-local test registry.
It demonstrates producer/subscriber composition, failure classification, late
selection, and originating detach callbacks. It does not establish synchronous
native dispatch, real concurrent registry behavior, or raw BEAM interoperability.

Under the required native contract, a slow handler delays the emitter and every
selected synchronous callback finishes before that emission returns. Separate
processes may invoke the same handler concurrently. Buffering changes these
semantics and belongs in a forwarding adapter with explicit capacity, overload,
loss, and shutdown policy.

## How a consumer attaches a handler

The typed callback receives the selected `Event(m, d)`, decoded `m`, and decoded
`d`. Its closure can retain arbitrary typed application configuration. An event
name accessor exposes the logical name without comparing codec closures or
claiming a native atom binding.

`attach` and `attach_many` require a handler identifier and failure observer.
The latter accepts one first descriptor and a list of further descriptors,
making the set nonempty. All descriptors share measurement and metadata types,
but may have different field decoders. The selected event reaches both the
handler and its failure observer.

Duplicate logical names fail before backend registration, including duplicates
among the remaining descriptors. Native name selection cannot distinguish two
descriptors for the same name, even if their generic types match. Comparing
closures would not prove codec equivalence and is not an admission rule.
Differently shaped events require separate typed handlers; a heterogeneous
attach-many callback is not introduced through type erasure.

An accepted `Attachment` retains its originating detach callback. Detach needs
no replacement backend, so it cannot accidentally target another configured
registry. Attachments remain copyable. Repeated detach returns the backend's
absence outcome, and a stale attachment has no generation-safe removal guarantee
when an application reuses a public identifier. Native `detach/1` removes by
identifier, not by compare-and-delete ownership token.

## Callback errors and removal

`MalformedMeasurements`, `MalformedMetadata`, and `HandlerReturned(e)` remain
separate typed failures. Invalid decoding invokes no typed handler. The failure
observer receives the selected descriptor and classified failure. Backend
failures and unexpected BEAM exceptions are not members of the handler's `e`.

The native adapter must report a declared decode or handler failure, then fail
the raw callback so telemetry removes the registration and emits
`[telemetry, handler, failure]`. Unexpected error, exit, or throw follows the
upstream callback-failure path directly. Dropping and logging malformed payloads
while leaving the registration installed, as proposed originally, is replaced
by this explicit native-compatible removal policy.

The upstream failure event includes event name, handler ID, configuration,
exception class, reason, and stacktrace. Adapter configuration may contain
captured Gleam closures and application data. Native tests must establish that
exposure and either disclose it or use an appropriate indirection before claiming
captured configuration is private. Scripted failure observers do not establish
native forwarding or removal.

## Scoped attachment lifetime

`with_attachments` accepts a backend, nonempty descriptor set, handler, typed
failure observer, exceptional-cleanup reporter, and work callback. It allocates
a private scoped identity and returns neither that identity nor an attachment.
Nested scopes receive distinct runtime-local identities; duplicate names and
backend rejection skip work.

Ordinary completion returns `ScopedCompletion(a)` containing the work value and
a separate cleanup result. A returned `Result.Error` from work is still that
ordinary value. Detach errors and detach exceptions become separate cleanup
failures; neither discards completed work.

A catchable work error, exit, or throw triggers one cleanup attempt and re-raises
the original BEAM class, reason, and stacktrace. Cleanup failures reach the
exceptional-cleanup reporter. A reporter exception must not replace the original
work exception. The [scoped lifetime probe](playground/interface_lab/SCOPED-LIFETIME.md)
executes this control path in the current process through an Erlang shim and a
scripted attachment backend.

If callback failure already removed the registration, cleanup returns
`NotAttached` inside `DetachReturnedError`. Absence satisfies the scope's
registration-removal ownership goal, but the cleanup outcome remains visible.
It does not prove the handler remained attached throughout the scope.

Private identities prevent Sinal callers from replacing a scoped registration
under its key. Raw Erlang or Elixir code can inspect and deliberately reuse the
native key; upstream has no conditional detach to defeat that race. A
list-then-detach check is not atomic. Cleanup safety therefore does not extend
to arbitrary foreign replacement of Sinal-owned registrations.

Detachment prevents later lookup from selecting the callback; already selected
callbacks may finish after scope exit. Scope exit is not callback quiescence.
Captured resources must remain valid until independently running callback work
finishes or concurrent emission is excluded. An untrappable kill, process loss,
or VM loss can skip cleanup. No opaque type guarantees linear ownership,
exactly-once cleanup, or cleanup under every termination mode.

## Typed spans

A span descriptor retains separate start metadata, extra stop measurements,
and stop metadata. It derives distinct start, stop, and exception event
descriptors under one native prefix. Native telemetry owns execution; Sinal
must not create a private span registry or actor.

Start measurements contain native system and monotonic time. Stop and exception
measurements contain native duration and monotonic time. User stop fields cannot
replace `duration` or `monotonic_time`. All metadata reserves
`telemetry_span_context`; start metadata also reserves `kind`, `reason`, and
`stacktrace` because exception metadata extends it with those native fields.

Start and stop metadata are independent maps and type parameters. Correlation
fields needed by stop-only handlers must be supplied in stop metadata explicitly.
Native telemetry provides one context shared by start and terminal events when
absent; different invocations receive distinct contexts. The initial typed
surface reserves context creation for the adapter and claims no trace parentage.

`Completion(result, extra_measurements, stop_metadata)` represents ordinary
work completion. Its result can itself be `Result`; a business `Error` emits
stop and returns unchanged. Only an actual BEAM error, exit, or throw emits an
exception event and re-raises the original exception triple. This corrects the
original example that converted ordinary HTTP failure into `SpanException`.
Handler failures during span observations still follow handler isolation, not
the span-work business-error path.

[Typed span evidence](playground/interface_lab/SPAN-EVENTS.md) proves descriptor
roles, reserved fields, record mappings, ordinary completion, and symbolic map
layouts. Private stand-ins for times, context, reason, and stacktrace are not
public native constructors. `run_span`, real clocks, context identity, crash
selection, and raw telemetry span interoperability remain native runtime work;
the scoped exception shim does not establish them.

## Package-owned facts and forwarding

Fabric, Saga, and Grind own their lifecycle decisions and event descriptors.
Sinal transports observations after those decisions. No universal lifecycle
event, retry policy, durable state, or command callback is introduced.

The [package observation probe](playground/interface_lab/PACKAGE-OBSERVATIONS.md)
emits Fabric report acceptance only after successful acceptance, Saga terminal
local reports with uncompensated/undo-failure counts, and Grind's already-computed
cancellation decision. Rejected emission leaves the source result unchanged.
Fabric's observed turn/call subset is not a globally unique action identity;
Grind's pure transition does not prove persisted job state.

OpenTelemetry export, trace-parent propagation, metrics aggregation, buffering,
and handler supervision remain explicit adapters or application responsibilities.
Compatibility with `opentelemetry_telemetry` follows only after real native events
exist. No event may become the control source for workflow resume, approval,
queue progress, or compensation.

## Native oracle and acceptance requirements

The pinned oracle is Apache-2.0 [`telemetry` 1.4.2](https://hex.pm/packages/telemetry/1.4.2),
its [implementation](https://github.com/beam-telemetry/telemetry/blob/v1.4.2/src/telemetry.erl),
and its [test suite](https://github.com/beam-telemetry/telemetry/blob/v1.4.2/test/telemetry_SUITE.erl).
Source inspection establishes the reference contract, not Sinal conformance.
The native adapter and upstream parity suite have not run in these experiments.

Retain differential tests for caller PID, synchronous completion, slow-handler
blocking, unspecified handler order, concurrent emitters, duplicate IDs,
repeated detach, failure removal, failure-event configuration, and behavior
before/after `persist/0`. Test two same-shaped descriptors with different decoders,
independent captured configurations, overlapping subscriptions, and selected
callbacks completing after detach.

Compare native atom names and exact maps in both directions: raw handlers on
Sinal emissions and Sinal handlers on raw telemetry emissions. Verify trusted
atom bindings, native terms, field roundtrips, unknown-field tolerance, malformed
maps, and failure forwarding. Scalar event codecs and mismatched native handler
types must remain intended compiler failures.

For spans, compare native time units, owned-key collisions, context equality
within an invocation and distinctness across invocations, and independent stop
metadata. Ordinary `Result.Error` must stop normally. Supervised error/exit/throw
probes must emit one exception event and preserve the re-raised triple. Nested
spans must preserve outer-start, inner-start, inner-terminal, outer-terminal
order without inferring trace parentage.

Repeat normal scoped return, exceptional work, cleanup failures, handler
self-removal, public-ID replacement, and concurrent selection against the native
registry. The existing scripted current-process probe does not prove native
registry cleanup, uncertain attachment recovery, cross-process cleanup,
quiescence, or survival under uncatchable termination.

## Capability disposition

The baseline is `sinal-design.md` at commit `9194f02`. The selected native-facade
semantics replace incompatible mechanisms while retaining typed instrumentation
and the full native span/handler goals.

| Original capability                                  | Disposition and owner                                                          | Evidence and remaining obligation                                          |
| ---------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| Typed measurements, metadata, and event identity     | Retained through descriptors and map-shaped fields                             | Pure field/negative probes; native atoms/maps pending                      |
| Actor per event and live `EventDefinition`           | Mechanism replaced by shared native telemetry registry                         | Preserves intended interoperability; requires synchronous/process oracle   |
| Library-owned descriptor and consumer attachment     | Retained with configured backend and descriptor-aware handler                  | Injected test registry; native registration pending                        |
| Typed closure configuration                          | Retained                                                                       | Scripted consumers; native failure-event exposure unresolved               |
| Same-shaped multi-event subscription                 | Expanded to nonempty `attach_many` with duplicate-name admission               | Pure selected-descriptor evidence; native matching and concurrency pending |
| Typed detach handle                                  | Retained with originating callback                                             | Copyable value; no linearity or public-ID generation guarantee             |
| Foreign telemetry decoding                           | Retained native boundary; malformed-event dropping replaced by failure/removal | Pure classification; actual native maps and forwarding pending             |
| Automatic start/stop/exception and timing            | Retained; ordinary business errors corrected to stop                           | Symbolic shapes only; full native span oracle required                     |
| Native context, exception terms and interoperability | Expanded explicit requirements                                                 | No JSON substitution; native reference and re-raise tests pending          |
| Scoped handler lifetime                              | Expanded with private identity and separate cleanup result                     | Catchable current-process scripted evidence; no quiescence guarantee       |
| Ecosystem observations                               | Expanded as package-owned facts after transitions                              | Concrete package probes; ordering/native delivery pending                  |
| Asynchronous forwarding and export                   | Adapter-owned, outside core                                                    | Queue/overload/loss/shutdown and native interoperability must be explicit  |

## Sources and unresolved friction

The current contract follows [PUBLIC-API](PUBLIC-API.md),
[Sinal coverage](API-COVERAGE.md#sinal),
[shared foundations](research/shared-foundations.md),
[handler and span lifetime](research/sinal-lifetime-contract.md), and the
[refinement record](playground/interface_lab/REFINEMENT-STATUS.md).
Earlier experiment notes describe their own historical scope; later injected
and scoped probes refine it without supplying the missing native adapter.

The remaining implementation risks are the binding of logical labels to native
atoms, retention of arbitrary native terms, failure-configuration exposure, and
registry races. `NotAttached` can meet removal ownership while remaining a
reported cleanup failure. Neither private scoped identity nor an opaque handle
makes callbacks linear or scope exit quiescent. These limits preserve the full
native contract rather than replacing it with the laboratory's JSON-shaped data.
