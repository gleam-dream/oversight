# Sinal span and handler-lifetime contract

## Question and status

- The experiment asks how Sinal can expose typed spans and bounded handler lifetimes while preserving native `telemetry` behavior.
- The current laboratory constructs typed events and classifies foreign callback failures. Its `emit`, `attach`, and `detach` functions remain unfinished runtime boundaries, and it has no span types.
- The original Sinal draft routes events through one actor per event and converts an ordinary returned error into a span exception. Both choices conflict with the selected native-facade direction.
- This note proposes one constructive type probe followed by one native FFI oracle. It does not claim that `run_span`, attachment cleanup, timing, process identity, or crash propagation works before the native oracle passes.

## Pinned native contract

- The oracle is Apache-2.0 [`telemetry` 1.4.2](https://hex.pm/packages/telemetry/1.4.2), with the exact [`telemetry.erl`](https://github.com/beam-telemetry/telemetry/blob/v1.4.2/src/telemetry.erl) implementation and [`telemetry_SUITE.erl`](https://github.com/beam-telemetry/telemetry/blob/v1.4.2/test/telemetry_SUITE.erl) tests.
- `execute/3` invokes handlers synchronously in the emitting process. A slow handler delays the emitter, handler order is unspecified, and a handler may run concurrently when separate processes emit the same event.
- A handler raise, exit, or throw removes the handler, emits `[telemetry, handler, failure]`, and does not propagate through `execute/3`. The failure event records the event name, handler identifier, configuration, failure class, reason, and stacktrace.
- `span/3` emits `prefix ++ [start]`, runs the supplied function, and emits `prefix ++ [stop]` for every ordinary return. A raise, exit, or throw instead emits `prefix ++ [exception]` and is re-raised with its original class, reason, and stacktrace.
- A returned Gleam `Result.Error` is an ordinary Erlang term. It therefore belongs to the stop path unless the caller deliberately raises, exits, or throws.
- Start measurements contain native `system_time` and `monotonic_time`. Stop and exception measurements contain native `duration` and `monotonic_time`; caller-supplied stop measurements cannot replace the two owned fields.
- Start and stop metadata are independent maps. Exception metadata extends start metadata with `kind`, `reason`, and `stacktrace`.
- Native `span/3` supplies one `telemetry_span_context` to the start and terminal event when caller metadata omits that key. Each invocation receives a new default context.
- Native handlers remain attached until explicit detachment or callback failure. Handler identifiers are global registry keys, and `detach/1` removes by identifier without an ownership generation or compare-and-delete token.

## Two error boundaries

- Span work and telemetry handlers use `Result` for different contracts. A span-work `Result.Error` is an ordinary business result and selects the stop path.
- The existing [observation contract](../playground/interface_lab/OBSERVATION-CONTRACT.md) treats a typed handler error as `HandlerReturned(error)`. The native adapter first calls `on_failure` with that `HandlerFailure`, then deliberately fails the raw telemetry callback so upstream removes it and emits `[telemetry, handler, failure]`.
- Measurement and metadata decode failures follow the same adapter policy after classification. An unexpected handler raise, exit, or throw bypasses the typed handler error while remaining an upstream callback failure.
- The adapter's deliberate callback failure does not convert a span-work domain error into a span exception. These paths meet only when instrumentation callback code itself fails during a start, stop, or exception event.

## Constructive span types

- The first slice constructs three event descriptors whose measurement and metadata types cannot be interchanged.

```gleam
pub opaque type Span(start_metadata, extra_measurements, stop_metadata)
pub opaque type SystemTime
pub opaque type MonotonicTime
pub opaque type NativeDuration
pub opaque type SpanContext
pub opaque type ExceptionReason
pub opaque type ExceptionStacktrace

pub type ExceptionKind {
  ExceptionError
  ExceptionExit
  ExceptionThrow
}

pub type StartMeasurements {
  StartMeasurements(
    system_time: SystemTime,
    monotonic_time: MonotonicTime,
  )
}

pub type StopMeasurements(extra) {
  StopMeasurements(
    duration: NativeDuration,
    monotonic_time: MonotonicTime,
    extra: extra,
  )
}

pub type ExceptionMeasurements {
  ExceptionMeasurements(
    duration: NativeDuration,
    monotonic_time: MonotonicTime,
  )
}

pub type StartMetadata(metadata) {
  StartMetadata(metadata: metadata, context: SpanContext)
}

pub type StopMetadata(metadata) {
  StopMetadata(metadata: metadata, context: SpanContext)
}

pub type ExceptionMetadata(metadata) {
  ExceptionMetadata(
    metadata: metadata,
    context: SpanContext,
    kind: ExceptionKind,
    reason: ExceptionReason,
    stacktrace: ExceptionStacktrace,
  )
}

pub type SpanEvents(sm, xm, tm) {
  SpanEvents(
    start: Event(StartMeasurements, StartMetadata(sm)),
    stop: Event(StopMeasurements(xm), StopMetadata(tm)),
    exception: Event(ExceptionMeasurements, ExceptionMetadata(sm)),
  )
}

pub type Completion(result, measurements, metadata) {
  Completion(result: result, measurements: measurements, metadata: metadata)
}
```

- `ExceptionReason` and `ExceptionStacktrace` hide foreign terms without describing them as application errors. Public construction waits for the native bridge.
- The pure laboratory map cannot retain native references, exception reasons, or stacktraces. The first probe therefore uses private symbolic codecs and private stand-ins to exercise layout only.
- The stand-ins never enter the public API. The experiment adds neither `Dynamic` nor a universal native-value case to the laboratory `Value` algebra.
- `SpanContext` identifies the events of one span invocation. It does not describe trace parentage, and nested spans receive distinct contexts under the initial contract.
- Start metadata and stop metadata remain separate type parameters because native telemetry does not copy one into the other. A caller repeats correlation fields in stop metadata when stop-only handlers require them.

- The descriptor and proposed runtime operation are:

```gleam
pub fn define_span(
  prefix: EventPrefix,
  start_metadata: Fields(sm),
  stop_measurements: Fields(xm),
  stop_metadata: Fields(tm),
) -> Result(Span(sm, xm, tm), SpanDefinitionError)

pub fn events(span: Span(sm, xm, tm)) -> SpanEvents(sm, xm, tm)

pub fn run_span(
  span: Span(sm, xm, tm),
  start_metadata: sm,
  work: fn() -> Completion(a, xm, tm),
) -> a
```

- `define_span` appends the static `start`, `stop`, and `exception` atoms to one validated atom-list prefix. It does not allocate an actor or a private registry.
- `EventPrefix` must come from static atom-backed declarations or another bounded native-name registry. Sinal never creates BEAM atoms from arbitrary runtime strings.
- The descriptor rejects stop-measurement fields named `duration` or `monotonic_time`. It reserves `telemetry_span_context` in all user metadata and reserves `kind`, `reason`, and `stacktrace` in start metadata because the exception event owns them.
- The initial API does not accept a caller-defined `SpanContext`. Native telemetry creates the context and Sinal decodes the same value from both events.
- `Completion` represents only an ordinary return. Its `a` may be `Result(ok, error)`, so `Completion(Error(error), measurements, metadata)` remains a stop result.
- `run_span` is only a proposed runtime signature until an FFI implementation delegates to native `span/3`. A `todo` body would prove no timing, exception, or re-raise behavior.

## First constructive probe

- Construct one HTTP-like span with distinct start metadata, extra stop measurements, and stop metadata.
- Attach compile-time handlers to each event descriptor. Negative fixtures must reject a start handler used for stop, stop metadata used for exception, and a stop-extra type used as start measurements.
- Feed symbolic times and one symbolic context through private pure event builders. Verify the three map layouts and verify that start and stop carry the same symbol.
- Build `Completion(Ok(response), ...)` and `Completion(Error(http_error), ...)` through the same pure normal-completion path. Both must return their original result and construct a stop observation.
- Construct a symbolic exception observation separately. This proves field placement only; it does not prove native-term retention, native-map compatibility, crash selection, or runtime rethrow.
- Compose an outer and inner span value to show that nested typed descriptors require no ecosystem package. Do not claim event order or parentage from this compilation probe.
- Keep `Fields` native to Sinal's map boundary. The laboratory's reuse of Blueprint values does not establish a production dependency on JSON Blueprint.

## Attachment lifetime

- Global `attach` and `detach` remain necessary for application-lifetime instrumentation. An `Attachment` is copyable, so explicit detachment cannot be statically single-use and repeated detachment remains a runtime `NotAttached` result.
- A scoped bracket is useful for tests, request-local observation, and temporary plugins. It must not accept a caller-owned global handler identifier.

```gleam
pub fn with_attachment(
  event: Event(m, d),
  handler: Handler(m, d, e),
  on_failure: fn(HandlerFailure(e)) -> Nil,
  use: fn() -> a,
) -> Result(a, AttachError)
```

- `with_attachment` allocates a fresh private native identifier for this attachment generation. It never returns that identifier or an `Attachment`, so another Sinal call cannot replace the registration under the same key.
- After successful attachment, the native implementation detaches in an Erlang `after` path. It then returns an ordinary result or re-raises the original catchable error, exit, or throw.
- An untrappable kill, VM loss, or process loss before `after` runs may skip cleanup. The scoped API cannot promise a terminal span event or handler detachment for those terminations.
- A cleanup `not_found` means the registration is already absent, usually because the handler failed and native telemetry removed it. It satisfies the scoped registration goal without proving that the handler remained installed for the whole scope.
- A bracket that accepts a reusable public identifier is unsafe. If the original handler fails, another process can attach a replacement under the same identifier before cleanup, and the stale cleanup detaches the replacement.
- The private-generation rule prevents that race among Sinal callers. Raw Erlang or Elixir code can inspect native handlers and deliberately reuse the private term, so safe cleanup assumes foreign code does not replace Sinal-owned scoped identifiers.
- Upstream exposes no conditional detach operation. A list-then-detach check cannot close the race, and Sinal must not claim ownership-safe cleanup against arbitrary raw registry mutation.
- Detachment prevents later registry lookups from selecting the handler. It does not wait for a callback that another emitting process already selected, so scope exit is not callback quiescence.
- A scoped handler must not capture a resource that becomes invalid immediately after `with_attachment` returns unless the application separately excludes concurrent emission or joins its callback work.

## Native FFI oracle

- Implement the bridge as a static Erlang callback whose configuration retains the Gleam field decoders and closure. Do not add actor-per-event dispatch.
- Compare Sinal with `telemetry` 1.4.2 for caller PID, synchronous completion, slow-handler blocking, unspecified order, concurrent emitters, duplicate identifiers, repeated detach, callback failure removal, failure-event content, and behavior before and after `persist/0`.
- Compare start, stop, and exception atom names; exact native map keys; native time values; context equality within one invocation; context uniqueness across invocations; independent stop metadata; and owned-key collision behavior.
- Return `Result.Error` normally and require a stop event. Raise, exit, and throw from supervised probe processes; require one exception event and the same class, reason, and stacktrace after re-raise.
- Return a typed handler error and require `on_failure` reporting followed by upstream detachment and one handler-failure event. Keep this probe separate from the span-work `Result.Error` case.
- Nest a successful span and a crashing span. Require outer start, inner start, inner terminal, and outer terminal order; require distinct default contexts; and avoid a parent-child trace claim.
- Attach a raw Erlang handler to a Sinal span and attach a Sinal handler to raw `telemetry:span/3`. Both directions must observe the same event names and maps.
- Exercise normal scoped return, scoped crash, handler self-removal, and the public-ID replacement race. The first three establish intended cleanup; the last demonstrates why a caller-owned identifier is excluded from `with_attachment`.
- Run a concurrent emitter across scope cleanup and record whether a previously selected callback finishes afterward. The result constrains documentation and resource-lifetime examples rather than creating a quiescence promise.

## Acceptance boundary

- The constructive slice proves that one span definition supplies three distinct typed event shapes and that an ordinary `Completion(Result.Error(...))` stays on the normal completion path.
- Injected symbolic observations prove pure layout and composition only. They do not prove native-term retention, native clocks, caller-process execution, crash capture, re-raise fidelity, registration cleanup, concurrency, or raw telemetry interoperability.
- The native slice is required before `run_span` or `with_attachment` counts as exercised behavior. Publication of the event-and-span API waits for the pinned differential oracle.
- Sinal remains an independently usable telemetry facade. Span export, trace parent propagation, asynchronous forwarding, metrics aggregation, handler supervision, and ecosystem workflow control remain outside this contract.
