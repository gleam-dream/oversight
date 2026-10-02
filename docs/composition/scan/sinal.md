# sinal — API card

Typed facade over native BEAM `:telemetry` 1.4.2. Repo: `/code/gleam-dream/sinal`.
Design: [sinal-design.md](../../../sinal-design.md).

## Health

| Gate step (CI `.github/workflows/ci.yml`, run via `nix develop --command`) | Result                                                                    |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `gleam format --check src test`                                            | pass                                                                      |
| `gleam build --warnings-as-errors`                                         | pass                                                                      |
| `gleam test`                                                               | pass, 93 passed, no failures                                              |
| `python3 dev/check_forwarder.py` (restart probe on disposable copies)      | pass (exit 0; startup capacity and delayed-sender restart scenarios hold) |

- Git head: `8acec45 fix: preserve forwarder capacity across restarts`. Worktree clean.
- No `TODO`/`FIXME` in `src/`. `test/oracle/telemetry-1.4.2.md` records zero `todo` sites left.
- Version stays `0.1.0` and unreleased. The CHANGELOG already marks a breaking change
  (`Dropped` gained `unavailable`).
- Open item: the design doc's capability table and its "native adapter pending" prose
  (sinal-design.md:44-47, 368-381) are stale. The native adapter, spans, and scopes ship and are tested.
- The dependencies are `gleam_stdlib`, `gleam_erlang`, `gleam_otp`, and `telemetry == 1.4.2`.
  Sinal depends on no sibling package and only runs on Erlang.

## Purpose and scope delivered vs design

Sinal wraps native `:telemetry` with typed descriptors. `Event(m, d)` binds a trusted atom
name to two map-shaped `Fields` codecs. Handlers receive decoded `m` and `d` synchronously
in the emitting process. A decode failure or a handler `Error` goes to a typed failure
observer, then raises so that native telemetry detaches the handler and emits
`[telemetry, handler, failure]`. Delivered features: attach, attach_many, and detach;
scoped subscriptions with indexed cleanup failures and an exact re-raise; native spans
with typed start, stop, and exception descriptors and timing in an explicit unit; and a
bounded, supervised forwarder with per-prefix routing for libraries. The design's core
scope is delivered. Missing or adapter-owned items:

- No public `persist/0` wrapper and no handler introspection (`list_handlers`), although the
  README describes `persist`.
- No test-helper analogue of `:telemetry_test.attach_event_handlers` (forwarding events to a
  pid). `with_subscriptions` covers part of that need.
- Primitive field codecs cover only `string`, `int`, and `bool`. There are no `float`, list,
  or atom-valued fields, so float durations need a custom codec.
- No span context or trace parentage control. OpenTelemetry, metrics export, and
  `opentelemetry_telemetry` compatibility belong to adapters that do not exist yet.
- Detach removes by public ID only, with no generation-safe removal. This is an upstream limit.

## Public modules

| Module            | Responsibility                                                                                                                                                         |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sinal`           | `Event` descriptors, `HandlerId`, `emit`, `attach`/`observe`/`attach_many`/`detach`, scoped `with_attachments`, `Subscription`/`SubscriptionPlan`/`with_subscriptions` |
| `sinal/fields`    | `Fields(a)` native-map codecs: `field`, `string`, `int`, `bool`, `optional`, `pair`, `imap`, `empty`, `encode`/`decode`, the error types                               |
| `sinal/span`      | `EventPrefix`, `define_span`, `events` (start/stop/exception descriptors), `run_span`/`run_span_result`, opaque time/context/exception wrappers, `TimeUnit`            |
| `sinal/forwarder` | `Forwarder` (`new`, `supervised`), `emit`, `route`/`unroute`/`emit_routed`, `dropped_event`, `ForwardError`, `Dropped`                                                 |
| `sinal/exception` | Opaque `BeamException`, `exception_class`, `reraise`                                                                                                                   |

`sinal/internal/ffi` is internal. `sinal.encode_event` is marked `@internal`, yet it is
`pub` because `forwarder` uses it.

## Common path

Taken from `README.md:64-79` and `src/sinal.gleam` signatures.

```gleam
import gleam/erlang/atom
import sinal
import sinal/fields

pub fn request_finished() -> sinal.Event(Int, String) {
  let assert Ok(ev) =
    sinal.event(
      [atom.create("request"), atom.create("finished")],
      fields.int(atom.create("duration_ms")),
      fields.string(atom.create("route")),
    )
  ev
}

pub fn run() {
  let ev = request_finished()
  let assert Ok(id) = sinal.handler_id("request-finished-observer")
  let assert Ok(attachment) =
    sinal.observe(id, ev, fn(_duration_ms, _route) { Nil })
  let assert Ok(Nil) = sinal.emit(ev, 42, "/users")  // Result(Nil, EmitError)
  let assert Ok(Nil) = sinal.detach(attachment)      // Result(Nil, DetachError)
}
```

A library that should not choose sync or forwarded delivery calls
`forwarder.emit_routed(ev, m, d) -> Result(Nil, ForwardError)`. The application then
calls `forwarder.route(prefix, fwd)` once at startup.

## Configuration and advanced paths

- **There is no global configuration.** Descriptors are pure values built from `List(Atom)`
  and `Fields`. The constructors `event`, `fields.pair`, `fields.optional`,
  `span.event_prefix`, `span.define_span`, and `handler_id` validate at construction and
  return `Result`.
- **Custom codecs.** The extension point is
  `fields.field(key: Atom, encode: fn(a) -> Result(Dynamic, FieldEncodeError), decode: fn(Dynamic) -> Result(a, FieldDecodeError))`
  (`src/sinal/fields.gleam:50`). Callers compose fields with `pair` and map them to records
  with `imap(fields, from, to)`.
- **Handler forms**:
  - `observe(id, ev, fn(m, d) -> Nil)` is the infallible form and discards failures.
  - `attach(id, ev, handler, on_failure)` is the fallible form. The handler has type
    `fn(Event, m, d) -> Result(Nil, e)`, and `on_failure` receives `HandlerFailure(e)`.
  - `attach_many(id, first, rest, ...)` attaches one handler to several same-shaped events.
- **Scoped forms**:
  - `with_attachments(first, rest, handler, on_failure, on_exception_cleanup_failure, run)`
    is the older same-shaped form.
  - `with_subscriptions(plan, run)` takes heterogeneous `Subscription` values built by
    `subscription` or `handler_subscription`. A plan comes from `subscriptions(list)`.
    Callers can change it with `with_exception_cleanup_reporter`.
- **Spans.** `define_span(prefix, start_meta_fields, extra_measurement_fields, stop_meta_fields)`
  rejects reserved native keys. `run_span` panics on an encoding failure.
  `run_span_result` returns `SpanOutcome(a)` and keeps the completed result.
- **Forwarder.** `forwarder.new(name: process.Name(forwarder.Message), capacity: Int)`
  returns `Result(Forwarder, ConfigError)`. The call allocates atomics but starts no
  process. Routing uses `route(List(Atom), Forwarder)` and `unroute`, and stores routes
  node-wide in `persistent_term`.
- **No behaviour or adapter interface exists.** Extension happens through closures
  (handlers, codecs) and by attaching native handlers.

## Lifecycle and supervision

- The core API (`emit`, `attach`, and spans) starts no processes. Handlers live in
  telemetry's ETS registry. The caller owns each `Attachment` and must call `detach`. Scoped
  forms detach on normal return and on catchable exceptions, but not on `kill`. Detach does
  not wait for callbacks already in flight.
- `forwarder.supervised(fwd) -> supervision.ChildSpecification(Nil)`
  (`src/sinal/forwarder.gleam:217`) returns a gleam_otp worker child spec. The caller's
  supervisor owns restarts.
  - Each incarnation owns a named ETS row that holds its direct subject and fresh admission
    counters.
  - Drop diagnostics live in atomics inside the `Forwarder` value, so they survive restarts.
  - The forwarder does not drain on shutdown.
  - Callers should `unroute` before stopping a routed forwarder.
- `route` writes `persistent_term`, which costs a global GC pass. Callers should route only
  at startup and shutdown.

## Failure model

- `EventError.EmptyEventName`, `IdentityError.EmptyHandlerId`, `fields.FieldError`
  (`MissingField`/`DuplicateField`/`InvalidField(name, FieldDecodeError)`/`InvalidOptionalInner`),
  `span.PrefixError.EmptyPrefix`, `span.SpanDefinitionError` (`Reserved*Field(String)`), and
  `forwarder.ConfigError.InvalidCapacity` are construction errors.
- `EmitError.EncodingFailed(FieldEncodeError)` is the only emit failure. Handler errors
  never reach the emitter.
- `AttachError` has the variants `AlreadyExists`, `DuplicateEventName(List(String))`, and
  `BackendNotAvailable`. `DetachError` has `NotAttached` and `DetachBackendNotAvailable`.
- `HandlerFailure(e)` has the variants `MalformedMeasurements(FieldError)`,
  `MalformedMetadata(FieldError)`, and `HandlerReturned(e)`. It reaches only `on_failure`,
  after which native telemetry removes the handler.
- Scoped results:
  - `ScopedCompletion(work_result, cleanup_result: Result(Nil, ScopeCleanupFailure))`
  - `SubscriptionCompletion(work_result, cleanup_failures: List(SubscriptionCleanupFailure{index, failure}))`
  - `SubscriptionScopeError.SubscriptionAttachFailed(index, error, rollback_failures)`

  Catchable exceptions are re-raised exactly through `BeamException`.

- Span outcomes are `SpanCompleted(a)`, `StartEncodingFailed(FieldEncodeError)`, and
  `CompletionEncodingFailed(result, CompletionEncodeError)`.
- `ForwardError` has the variants `ForwardEncodingFailed(FieldEncodeError)`,
  `CapacityExceeded`, and `ForwarderUnavailable`. Drops are reported asynchronously as
  `Dropped(rejected, lost, unavailable)`.
- Codec errors are strings: `FieldDecodeError(message: String)` and
  `FieldEncodeError(message: String)`.

## Composition seams

- **Sinal is a leaf package.** It depends on no sibling, and every sibling except
  json_blueprint depends on it. The siblings are fabric, grind, http_gun, llm_wire, relay,
  saga, and warden, each through `sinal = { path = "../sinal" }`.
- **Siblings export typed descriptors.** Each sibling returns `sinal.Event(m, d)` values
  built with `sinal/fields`, for example `warden/src/warden/observation.gleam:48`
  `http_request() -> sinal.Event(HttpMeasurements, HttpRequest)`. Consumers subscribe with
  `sinal.observe`/`attach`.
  - The sibling module names differ: `observation` in fabric, saga, grind, and warden, and
    `telemetry` in http_gun, relay, and llm_wire.
- **Siblings use three emission paths**, so delivery policy is not uniform across the
  ecosystem:
  - Synchronous `sinal.emit`: relay (`relay/telemetry.gleam:197+`),
    llm_wire (`llm_wire/telemetry.gleam:25`), saga (`saga/internal/coordinator.gleam:2152`),
    and warden (`warden/internal/transport.gleam:501`).
  - `forwarder.emit` to an injected or owned `Forwarder`: grind creates one per `Database`
    (`grind/postgres.gleam:387`, supervised at `:500`). http_gun's config takes
    `observations: Option(forwarder.Forwarder)` (`http_gun/config.gleam:46`).
  - `forwarder.emit_routed`: only fabric (`fabric/internal/observe.gleam:348`).
- **Sinal's own events**:
  - It emits `[sinal, forwarder, dropped]` with measurements `rejected`/`lost`/`unavailable`
    (Int) and metadata `forwarder` (String). The event is always synchronous and never routed.
  - Spans emit `prefix ++ [start|stop|exception]` through native `telemetry:span/3`.
  - Native telemetry emits `[telemetry, handler, failure]` when it removes a handler.
- **Ecosystem fit**:
  - The native atom names and maps work with any Erlang or Elixir `:telemetry` consumer,
    such as `telemetry_metrics` or reporters, without an adapter. Sinal can also decode
    foreign events through descriptors.
  - The forwarder plugs into `static_supervisor` directly.
  - Sinal does not touch gleam_http, mist, wisp, or pog. No shared HTTP event vocabulary
    exists, so warden's and http_gun's HTTP observations are separate shapes.
  - Sinal has no logging integration of its own. Telemetry itself logs failures and local
    handler functions through OTP `logger`.

## Ergonomics concerns

1. **Custom codecs are stringly typed and bypass `gleam/dynamic/decode`.**
   - `FieldDecodeError(message: String)` and `FieldEncodeError(message: String)` are
     defined at `src/sinal/fields.gleam:15-21`. `field` takes a raw
     `fn(Dynamic) -> Result(a, FieldDecodeError)` (`fields.gleam:53`) instead of a
     `decode.Decoder(a)`. The structured `List(DecodeError)` is lost, and every custom field
     repeats a `case decode.run(..) { Error(_) -> FieldDecodeError("...") }` block.
     README.md:106-162 does this 4 times, and the siblings build `FieldDecodeError(...)` 13 times.
   - Encoding is fallible on every field even though primitive encoders cannot fail.
   - There is no `fields.float`.
2. **Static descriptors are fallible, so callers `let assert`.**
   - `event` returns `Result` only to reject `[]` (`src/sinal.gleam:25-34`). `fields.pair`
     (`fields.gleam:175-178`), `span.event_prefix` (`span.gleam:18`), and `define_span`
     (`span.gleam:176`) also return `Result` for constant inputs.
   - Sinal asserts on its own constructors at `forwarder.gleam:307-322` and
     `span.gleam:229-241`. The sibling packages contain about 92 `let assert Ok(..) = sinal.event | fields.pair` sites.
   - A non-empty head/tail name (`event(first: Atom, rest: List(Atom), ..)`) or a builder
     would make these descriptors total.
3. **The scoped and attach families overlap.**
   - `with_attachments` has 6 positional arguments, including a required
     `on_exception_cleanup_failure` (`sinal.gleam:388-395`). It duplicates
     `with_subscriptions` (`sinal.gleam:431`) but uses parallel types: `ScopedCompletion`
     and `ScopeCleanupFailure` against `SubscriptionCompletion` and
     `SubscriptionCleanupFailure` (`sinal.gleam:91-135`).
   - A multi-event `Subscription` constructor would subsume it.
   - Five entry points register a handler: `observe`, `attach`, `attach_many`, `subscription`,
     and `handler_subscription`.
4. **Two error variants come from the old laboratory backend and are unreachable.**
   `AttachError.BackendNotAvailable` and `DetachError.DetachBackendNotAvailable`
   (`sinal.gleam:73,78`) map `NativeAttachOther(_)` and `NativeDetachOther(_)` and discard
   the detail (`sinal.gleam:319,325`). Telemetry 1.4.2's spec returns only
   `ok | {error, already_exists}` and `ok | {error, not_found}` (`telemetry.erl:126,164`).
   Callers must still match these dead variants.
5. **Native interop leaks Gleam representations.**
   - `ffi.to_dynamic(id)` (`sinal.gleam:304`) registers the opaque `HandlerId` as
     `{public_handler_id, <<"name">>}`, so `:telemetry.list_handlers` and a foreign
     `detach("name")` do not see the string the caller chose.
   - Every attach passes a closure, so `telemetry.erl:133-142` logs a local-function `LOG_INFO`
     and takes the documented slow path. A `fun sinal_ffi:handle/4` that receives the closure
     through `Config` would avoid both.
6. **Prefix and error types are inconsistent across emit paths.**
   - `forwarder.route` takes a raw `List(Atom)`, and `[]` means "all"
     (`forwarder.gleam:372`). `span` instead requires a validated `EventPrefix` that rejects
     `[]` (`span.gleam:9-18`).
   - `sinal.emit` returns `EmitError` (one variant, `sinal.gleam:81`).
     `forwarder.emit` and `emit_routed` return `ForwardError` (`forwarder.gleam:131`). A
     library that moves from sync to routed emission therefore changes its error type,
     which partly explains why siblings chose different emission paths.
