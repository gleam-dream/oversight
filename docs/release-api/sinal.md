# sinal — release API review

Reviewed 2 October 2026 against `/code/gleam-dream/sinal` at `8acec45`, the
[sinal design](../../sinal-design.md), the [API card](../composition/scan/sinal.md),
the [cross-package review](../composition/FEEDBACK.md) (theme 1 and the fix
round), every app finding that names sinal, and the sibling packages that
emit through it. Scratch consumers ran today's common path and a shim of
the proposed `fields` builder, `fields.enum`, decoder-based `fields.field`
and `sinal/correlation` over today's sinal; claims they checked say "probe".

## 1. Verdict

The runtime is release-quality, but the API is not ready: dispatch, failure
isolation, spans and the bounded forwarder are tested and composed in all
eight apps, while the surface still carries laboratory scaffolding that no
caller uses. The biggest problems are that sinal does not define the shared
correlation field theme 1 needs; that libraries choose among three emission
paths with two error types nobody acts on; and that constant descriptors,
encoders and handler ids are fallible or hand-made where they need not be
(102 `let assert` sites in the siblings, a handler-id helper in every app).

## 2. First ten minutes

The main job is to define an event, observe it, emit it and detach.

Today (probe: compiles against `8acec45` and prints `/users 42`):

```gleam
import gleam/erlang/atom
import sinal
import sinal/fields

let assert Ok(ev) =
  sinal.event(
    [atom.create("request"), atom.create("finished")],
    fields.int(atom.create("duration_ms")),
    fields.string(atom.create("route")),
  )
let assert Ok(id) = sinal.handler_id("request-finished")
let assert Ok(attachment) =
  sinal.observe(id, ev, fn(duration_ms, route) { todo })
let assert Ok(Nil) = sinal.emit(ev, 42, "/users")
let assert Ok(Nil) = sinal.detach(attachment)
```

Proposed:

```gleam
import sinal
import sinal/fields

let ev =
  sinal.event("request", ["finished"],
    fields.int("duration_ms"),
    fields.string("route"),
  )
let attachment = sinal.observe(ev, fn(duration_ms, route) { todo })
sinal.emit(ev, 42, "/users")
let _ = sinal.detach(attachment)
```

Today: 3 imports, 10 types (`Atom`, `Event`, `Fields`, `HandlerId`,
`Attachment` and 5 error types the asserts discard), 11 calls, 5 `let
assert`. Proposed: 2 imports, 3 types, 6 calls, no `let assert`.

A library author also defines a metadata record that carries the
correlation. Today that takes `pair` chains over nested tuples plus `imap`
(README.md:89-182: 94 lines for 5 fields). The proposed builder (probe)
takes one line per field:

```gleam
pub fn request_metadata() -> fields.Fields(RequestMetadata) {
  fields.record({
    use method <- fields.parameter
    use route <- fields.parameter
    use correlation <- fields.parameter
    RequestMetadata(method:, route:, correlation:)
  })
  |> fields.and(fields.enum("method", [Get, Post], method_name), fn(m: RequestMetadata) { m.method })
  |> fields.and(fields.string("route"), fn(m) { m.route })
  |> fields.and(correlation.field(), fn(m) { m.correlation })
  |> fields.build
}
```

Only the first getter needs a type annotation (probe: without it the
record type is unknown until `build`).

## 3. Target surface

```text
sinal               Event, Subscription, SubscriptionPlan, Attachment
                    event(first, rest, measurements, metadata) -> Event(m, d)   // total
                    name(event) -> List(String)
                    emit(event, m, d) -> Nil                                     // route-aware
                    observe(event, fn(m, d) -> Nil) -> Attachment                // automatic id
                    subscription(event, fn(m, d) -> Nil) -> Subscription
                    handler(first, rest, run, on_failure) -> Subscription        // fallible, multi-event
                    with_id(Subscription, String) -> Subscription
                    attach(Subscription) -> Result(Attachment, AttachError)
                    detach(Attachment) -> Result(Nil, Nil)                       // Error = not attached
                    subscriptions(List(Subscription)) -> SubscriptionPlan
                    with_exception_cleanup_reporter(plan, reporter) -> SubscriptionPlan
                    with_subscriptions(plan, work) -> Result(SubscriptionCompletion(a), SubscriptionScopeError)
                    AttachError, HandlerFailure(e), CleanupFailure,
                    describe_attach_error, describe_handler_failure, describe_cleanup_failure
sinal/fields        Fields(a), Record(r, f), FieldError
                    string, int, float, bool, empty, enum, optional
                    field(key, encode: fn(a) -> Dynamic, decoder: decode.Decoder(a))
                    record, parameter, and, build, describe_error
sinal/correlation   Correlation, CorrelationError                                // new
                    from_string, unique, to_string, field, describe_error
sinal/span          Span, SpanEvents, Completion, timing and exception wrappers
                    define(first, rest, start_metadata:, stop_measurements:, stop_metadata:) // total
                    events, run, duration_in, system_time_in, monotonic_time_in,
                    reason_to_dynamic, stacktrace_to_dynamic
sinal/forwarder     Forwarder, Message, Refusal, Dropped, DroppedMetadata
                    new(name) -> Forwarder, with_capacity, supervised -> ChildSpecification(Forwarder),
                    emit(forwarder, event, m, d) -> Result(Nil, Refusal),
                    route(List(String), forwarder), unroute, dropped_event, describe_refusal
sinal/internal/*    ffi, exception (was public sinal/exception), encode, route table
```

| Count                                          | Before                                                                                                                   | After                                                                    |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| Public modules                                 | 5                                                                                                                        | 5 (`exception` internal, `correlation` new)                              |
| Public functions                               | 53 (one of them `@internal`)                                                                                             | 49                                                                       |
| Public types                                   | 50                                                                                                                       | 37                                                                       |
| Opaque types                                   | 17                                                                                                                       | 16                                                                       |
| Public records                                 | 15                                                                                                                       | 12 (8 are span event records, read in handlers)                          |
| Public unions                                  | 18                                                                                                                       | 9                                                                        |
| Ways to emit                                   | 3 (`emit`, `forwarder.emit`, `emit_routed`)                                                                              | 2 (`emit` for libraries, `forwarder.emit` for owners)                    |
| Ways to register a handler                     | 7 (`observe`, `attach`, `attach_many`, `with_attachments`, `subscription`, `handler_subscription`, `with_subscriptions`) | 3 (`observe`, `attach`, `with_subscriptions`) over 1 `Subscription` type |
| Fallible constructors for constant definitions | 7 (`event`, `handler_id`, `pair`, `optional`, `event_prefix`, `define_span`, `forwarder.new`)                            | 0                                                                        |

The function count barely drops because `sinal/correlation` and the
`describe_*` functions add 10, but 18 types go, among them `HandlerId`,
`EventPrefix`, `EmitError`, `ForwardError` (now `Refusal`), both codec
string errors, `SpanOutcome`, `ScopedCompletion`, the construction errors
(`EventError`, `IdentityError`, `PrefixError`, `SpanDefinitionError`,
`ConfigError`) and the public `BeamException`. `pair`/`imap` give way to
`record`/`and`/`build`, and `encode_event`, `fields.encode`/`decode` and
`declared_*` go internal. Across the 7 siblings and 8 apps, `attach`,
`attach_many`, `with_attachments`, `with_subscriptions`,
`handler_subscription`, `sinal/span` and `sinal/exception` have zero
callers; `observe`, `pair` (75 lines) and `imap` (87) carry the ecosystem.

## 4. Proposals

Sibling paths are relative to the package's `src/`; app paths to
`apps/<app>/src/<app>/`.

### SINAL-R1 Define the correlation value and field (theme 1)

- **Problem.** No app could follow one request across packages without join
  tables or emitting-pid tricks (CHK-5, EXT-4, WHK-5, SSO-7, SMCP-9, SD-3,
  TH-7, RA-7). The only correlation type in the ecosystem, http_gun's
  `telemetry.Id`, is VM-local and created only by `new_id()`
  (http_gun/telemetry.gleam:19-28), so no application value can
  be the key. Sinal is the one dependency every emitter shares, and it has no
  field for this.
- **Proposal** (probe: `next/correlation.gleam`). A new `sinal/correlation`
  module:

  ```gleam
  pub opaque type Correlation
  pub type CorrelationError { EmptyCorrelation  CorrelationTooLong(max_bytes: Int) }
  pub const max_bytes = 128
  pub fn from_string(value: String) -> Result(Correlation, CorrelationError)
  pub fn unique() -> Correlation  // 128 random bits, hex; unique across nodes
  pub fn to_string(correlation: Correlation) -> String
  /// Key `correlation`, a UTF-8 binary; `None` omits the key; nil/undefined decode as None.
  pub fn field() -> fields.Fields(Option(Correlation))
  pub fn describe_error(error: CorrelationError) -> String
  ```

- **Ecosystem rule.** Every package with work-scoped events puts
  `correlation: Option(Correlation)` in its metadata records, encoded with
  `correlation.field()`. It accepts the value where work starts
  (`with_correlation` on a config, client view or request) and copies it
  into every event of that work, including events from helper processes
  such as llm_wire's stream owner. It passes the value to every package it
  calls for the caller (fabric → llm_wire → http_gun). http_gun replaces
  `telemetry.Id` with `Correlation` and keeps its per-invocation
  `request_id`. Spans carry it in start and stop metadata
  (sinal-design.md:288-289). One native key, representation and absence
  encoding mean an Erlang or Elixir handler reads `metadata.correlation`
  without knowing the package.
- **Why this shape.** The process dictionary does not cross the forwarder
  hop (forwarder.gleam:28-32) or llm_wire's owner processes (EXT-4), and
  `telemetry_span_context` is per span. The opaque type gives signatures "a
  correlation" rather than one more `String`. The 128-byte bound keeps
  metadata small when the value comes from an untrusted header; the docs
  must also forbid using it as a metric tag.
- **Second step (M).** Add
  `correlation.observe(names: List(List(String)), run: fn(List(String), Option(Correlation)) -> Nil) -> Attachment`,
  which decodes only the `correlation` key of any event. One call would
  replace the webhooks collector's 19 `observe` calls (WHK-10), once each
  package exports `telemetry.event_names()`.
- **Breaks callers.** No; the module is additive. Sibling metadata records
  gain a field. **Effort.** S in sinal, M across the ecosystem.

### SINAL-R2 One library emission path: `sinal.emit` follows routes and returns `Nil`

- **Problem.** Siblings chose three paths. relay, llm_wire, saga and warden
  call `sinal.emit`; grind and http_gun call `forwarder.emit`; only fabric
  calls `emit_routed`. http_gun emits nothing until the app supervises a
  forwarder for it (SD-9, TH-11, WHK-10). The paths return different errors
  (`EmitError` at sinal.gleam:81-83, `ForwardError` at forwarder.gleam:131-135),
  so a switch to routing changes a library's types. No caller acts on either
  result: relay/telemetry.gleam:197-207 matches `_ -> Nil`, and
  saga/internal/coordinator.gleam:2151, llm_wire/telemetry.gleam:24,
  warden/internal/transport.gleam:500, http_gun/telemetry.gleam:245 and
  fabric/internal/observe.gleam:377 discard it. Routing is cheap: an
  unrouted `emit_routed` costs 113 ns per event against 99 ns for
  `sinal.emit` (probe, benchmark in a scratch copy).
- **Proposal.**

  ```gleam
  /// Synchronous unless the application routed a prefix of this name; a refused
  /// routed event is counted in the forwarder's `dropped_event`.
  pub fn emit(event: Event(m, d), measurements: m, metadata: d) -> Nil                  // sinal
  pub type Refusal { CapacityExceeded  ForwarderUnavailable }                          // closed
  pub fn emit(forwarder: Forwarder, event: Event(m, d), m, d) -> Result(Nil, Refusal)  // forwarder
  ```

  `forwarder.emit` remains the owner's path (grind's per-`Database`
  forwarder): it targets one forwarder and shows the refusal. `emit_routed`
  is deleted. Sinal's drop report and native spans still bypass routes. The
  route table moves to `sinal/internal/route`, so `sinal` does not import
  `forwarder`.

- **Breaks callers.** Yes, one line in each sibling's emit wrapper.
  **Effort.** M.

### SINAL-R3 Infallible encoding; `fields.field` takes a `decode.Decoder`

- **Problem.** `field(key, encode: fn(a) -> Result(Dynamic, FieldEncodeError), decode: fn(Dynamic) -> Result(a, FieldDecodeError))`
  (fields.gleam:50-54) makes every caller hand-write a `Dynamic` decoder and a
  `FieldDecodeError(String)` (fields.gleam:15-21), and it drops `decode`'s
  structured errors. Four of the 7 sibling `field` calls are the same
  15-line string enum (fabric/observation.gleam:677,
  grind/internal/observation/wire.gleam:21, saga/observation.gleam:216,
  http_gun/telemetry.gleam:143). The other three are tagged tuples and an
  atom enum (http_gun/telemetry.gleam:89, warden/observation.gleam:80, :107). No sibling encoder can fail, yet fallible
  encoding is the only reason for `EmitError`, `ForwardEncodingFailed`,
  `SpanOutcome`, `CompletionEncodeError`, `run_span_result` and the
  panicking `run_span` (span.gleam:258-343).
- **Proposal** (probe):

  ```gleam
  pub fn field(key: String, encode: fn(a) -> Dynamic, decoder: decode.Decoder(a)) -> Fields(a)
  pub fn enum(key: String, values: List(a), name: fn(a) -> String) -> Fields(a)
  pub fn float(key: String) -> Fields(Float)
  pub type FieldError { NotAMap  MissingField(key: String)  InvalidField(key: String, errors: List(decode.DecodeError)) }
  pub fn run(span: Span(s, x, t), start_metadata: s, work: fn() -> Completion(a, x, t)) -> a  // span
  ```

  `Dynamic` stays on the encode side only, built with `gleam/dynamic`'s
  constructors. It is the native-term currency and never reaches a handler.
  `enum` and the primitives cover the common cases without it.

- **Breaks callers.** Yes, 7 sibling `field` calls, which get shorter.
  **Effort.** M.

### SINAL-R4 Constant descriptors are total

- **Problem.** Seven constructors return `Result` for inputs that are
  literals at every call site: `event` rejects only `[]`
  (sinal.gleam:25-34), `pair` duplicate keys (fields.gleam:175-178),
  `optional` a non-single-key field (fields.gleam:132), plus
  `span.event_prefix`, `define_span` (span.gleam:18, 176-208), `handler_id`
  (sinal.gleam:56-61) and `forwarder.new` (forwarder.gleam:205-213). The
  siblings hold 102 `let assert Ok(..)` sites on them (grind 44, saga 26,
  relay 14, fabric 5, http_gun 5, warden 5, llm_wire 3). Sinal asserts on its
  own constructors (forwarder.gleam:307-322, span.gleam:229-241).
- **Proposal.** Prevent each error by construction where that is cheap;
  otherwise check at definition and panic naming the key.
  - `event(first: String, rest: List(String), ..)` cannot be empty.
  - The applicative `record`/`and`/`build` builder (section 2) replaces
    `pair` and `imap`. Keys are known before any value exists, so `build`
    still rejects a duplicate key.
  - `optional` and `span.define(first, rest, start_metadata:, stop_measurements:, stop_metadata:)`
    panic on a wrong inner field or a reserved key.
  - Names and keys are `String`; sinal creates the atoms after checking
    `^[a-z][a-z0-9_]{0,62}$`, so a URL or email address fails at definition
    instead of growing the atom table (open question 1).
- **Breaks callers.** Yes, every descriptor definition. **Effort.** M.

### SINAL-R5 Automatic handler ids; `observe` is total

- **Problem.** All 8 apps wrote a helper that fabricates a unique
  `HandlerId`: checkout telemetry.gleam:293, extractor :145, research_agent
  :369, secure_mcp :304-306 (with an FFI `unique_integer`), sso_portal
  :95-97, support_desk :302, tool_hub :217, webhooks :306. Sinal already mints
  private ids for subscriptions (sinal.gleam:166-170). A public id is
  registered as `{public_handler_id, <<"name">>}` (sinal.gleam:304), so a
  foreign `:telemetry.detach("name")` cannot reach it anyway.
- **Proposal.** `observe(event: Event(m, d), run: fn(m, d) -> Nil) -> Attachment`.
  With a fresh id it cannot fail (`BackendNotAvailable` is dead, R8), so it
  returns no `Result`. `with_id(Subscription, String)` keeps a stable native
  id, registered as a plain binary. Delete `HandlerId`, `handler_id` and
  `IdentityError`. Also attach `fun sinal_ffi:handle/4` with the closure in
  `Config`: today every closure makes telemetry log "is a local function"
  and take its slow path (telemetry.erl:456), and lands in the
  `[telemetry, handler, failure]` config (sinal-design.md:199-204).
- **Breaks callers.** Yes, 10 app call sites, each simpler. **Effort.** S.

### SINAL-R6 One `Subscription` type for every registration

- **Problem.** Seven entry points register handlers. `with_attachments` takes
  6 positional arguments (sinal.gleam:388-395) and duplicates
  `with_subscriptions` with parallel result types (`ScopedCompletion` and
  `ScopeCleanupFailure` against `SubscriptionCompletion` and
  `SubscriptionCleanupFailure`, sinal.gleam:91-135). No advanced form has an
  external caller.
- **Proposal.**

  ```gleam
  pub fn subscription(event: Event(m, d), run: fn(m, d) -> Nil) -> Subscription
  /// Several same-shaped names, a fallible handler, a typed failure observer.
  pub fn handler(first: Event(m, d), rest: List(Event(m, d)),
    run: fn(Event(m, d), m, d) -> Result(Nil, e),
    on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil) -> Subscription
  pub fn attach(subscription: Subscription) -> Result(Attachment, AttachError) // long-lived
  ```

  Delete `attach_many`, `with_attachments`, `handler_subscription`,
  `ScopedCompletion` and `ScopeCleanupFailure`; `with_subscriptions` stays the
  scoped form. `AttachError` becomes
  `AlreadyExists(id: String) | DuplicateEventName(List(String))`. Every
  capability stays: fallible handlers, typed failure observers,
  multi-name registration, scopes with indexed cleanup failures, and the
  exception-time reporter.

- **Breaks callers.** Yes, with no external caller affected. **Effort.** S.

### SINAL-R7 Forwarder configuration follows the convention

- **Problem.** `forwarder.new(name, capacity) -> Result(Forwarder, ConfigError)`
  (forwarder.gleam:205-213) has no default capacity and a one-variant error,
  and `supervised` returns `ChildSpecification(Nil)` (:217-219). Each `new`
  allocates its own counters, so two values for one name split the drop
  accounting (:48-50).
- **Proposal.** `new(name) -> Forwarder` with capacity 1024;
  `with_capacity(forwarder, Int) -> Forwarder`, where a value below 1 fails
  start with `InitFailed`; `supervised(forwarder) -> ChildSpecification(Forwarder)`;
  `route(prefix: List(String), forwarder)` to match R4 (`[]` still means
  every event). Keep the drop counters in a `persistent_term` keyed by name,
  which removes the one-value-per-name footgun.
- **Breaks callers.** Yes: grind and the 5 apps that start forwarders.
  **Effort.** S.

### SINAL-R8 Remove dead variants; add `describe_*`

- **Problem.** `AttachError.BackendNotAvailable` and
  `DetachError.DetachBackendNotAvailable` (sinal.gleam:73,78) map error shapes
  that telemetry 1.4.2 never returns (its specs at telemetry.erl:126,164 allow
  only `already_exists` and `not_found`), and the mapping discards the detail
  (sinal.gleam:318-325). No error type has a `describe` function.
- **Proposal.** `detach(Attachment) -> Result(Nil, Nil)`, where `Error(Nil)`
  means "was not attached"; a scope reports it as
  `CleanupFailure.AlreadyDetached`. Add `describe_attach_error`,
  `describe_handler_failure(failure, describe_e)`, `describe_cleanup_failure`,
  `fields.describe_error`, `correlation.describe_error` and
  `forwarder.describe_refusal`. Document `HandlerFailure`, `Refusal` and
  `FieldError` as closed.
- **Breaks callers.** Only exhaustive matches; none exist outside sinal.
  **Effort.** S.

### SINAL-R9 Trim `sinal/span`; make `sinal/exception` internal

- **Problem.** `system_time_to_dynamic`, `monotonic_time_to_dynamic` and
  `duration_to_dynamic` (span.gleam:74-87) return an `Int` as `Dynamic` beside
  the typed `*_in(unit)` readers. `span.ExceptionKind` (span.gleam:68-72)
  duplicates `exception.ExceptionClass` (exception.gleam:5-9). `EventPrefix`
  exists only to reject `[]`. `BeamException` is public only so a cleanup
  failure can carry it.
- **Proposal.** Delete those three functions, `span_context_to_dynamic` (a
  `SpanContext` already compares with `==`), `EventPrefix` and
  `ExceptionClass`. Keep `reason_to_dynamic` and `stacktrace_to_dynamic` as
  the native escape hatch for arbitrary BEAM terms. Move `sinal/exception` to
  internal and report a detach crash as
  `CleanupFailure.DetachCrashed(kind: span.ExceptionKind, description: String)`;
  work exceptions still re-raise exactly.
- **Breaks callers.** No external caller. **Effort.** S.

### SINAL-R10 Docs and dependency range

- **Docs.** Only `forwarder` has a module doc. The README opens with
  architecture, builds primitive fields with `fields.field` where
  `fields.int`/`fields.string` exist (README.md:106-162), promises
  `:telemetry.persist/0` without a wrapper (README.md:451) and has no
  defaults table. sinal-design.md:44-47 and :368-381 still call the native
  adapter pending. State that the `telemetry` OTP application must run
  (`gleam run` starts it, probe; sso_portal starts it by hand, SSO-7).
- **Dependency.** `telemetry == 1.4.2` (gleam.toml) will conflict in mixed
  Elixir and Erlang applications once Hex has a 1.4.x patch. Sinal uses only
  telemetry's documented API (`attach_many`, `detach`, `execute`, `span`,
  failure detachment), so the range can be `>= 1.4.2 and < 2.0.0` with CI
  kept on the oracle version.
- **Breaks callers.** No. **Effort.** S.

## 5. Defaults table

| Operation                               | Current default                                                              | Proposed default                                                                |
| --------------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Synchronous handler run inside `emit`   | **none / infinite**: handlers run inline, a slow handler blocks the emitter  | Unchanged (native contract). Documented per library: "route `[pkg]` to isolate" |
| `emit` of a routed event                | `emit_routed` only; never waits                                              | `sinal.emit`; never waits, drops and counts on refusal                          |
| Forwarder capacity (queued + executing) | required argument, no default; mailbox bounded by it                         | 1024; `with_capacity(n)`; below 1 fails start                                   |
| Forwarder initialisation                | 1000 ms, hard-coded (forwarder.gleam:226)                                    | Unchanged; documented                                                           |
| Forwarder shutdown                      | no drain; in-flight events lost and reported as `Dropped(lost:)`             | Unchanged; documented                                                           |
| Drop reporting                          | coalesced per drain; counters in atomics                                     | Unchanged; counters shared per name (R7)                                        |
| Routes                                  | unbounded count in `persistent_term`; each change triggers a global GC       | Unchanged; documented as setup-time values                                      |
| `attach` / `detach`                     | telemetry `gen_server:call`, 5 s default timeout                             | Unchanged; documented                                                           |
| Atom creation for names and keys        | caller calls `atom.create`; nothing bounds it                                | Sinal creates atoms; grammar `^[a-z][a-z0-9_]{0,62}$` checked at definition     |
| Correlation size                        | n/a                                                                          | 1 to 128 bytes, checked by `from_string`                                        |
| Foreign map decoding                    | declared keys only; unknown keys ignored; no size bound (terms by reference) | Unchanged                                                                       |

The README should carry this table. The only unbounded default is
synchronous dispatch, which sinal cannot bound; the bound is the
application's `route`, which R2 extends from fabric to every library.

## 6. Convention feedback

- **1 and 6.** Sinal has almost no configuration; only the forwarder fits
  convention 1 (R7). Its descriptors are definitions built once from
  literals. The conventions should treat definitions apart from config:
  total constructors that panic on a definition bug. A `Result` that every
  caller unwraps with `let assert` is a panic with a worse message (102
  sites).
- **6 (`describe_error`).** One module holds several error types
  (`AttachError`, `HandlerFailure`, `CleanupFailure`), so the name collides.
  Use `describe_<type>`.
- **3 and 8.** Every sinal union is small and closed, so `kind` and
  `is_retryable` do not apply. JSON is not sinal's currency: native terms
  are built with `gleam/dynamic` and read with `decode.Decoder` (R3).
- **4 (bounded by default).** Sinal cannot time-box a synchronous native
  handler. Each emitting package should document that its handlers run
  inline unless the application routes its prefix, instead of owning a
  forwarder only to get a bound.
- **5 (lifecycle).** `supervised` fits the forwarder; a standalone
  `start`/`stop` adds nothing over `static_supervisor`. Allow "supervised
  only".
- **7 (glossary).** A field name alone does not join events. The convention
  must fix the type (`Option(sinal/correlation.Correlation)`), key
  (`correlation`), representation (UTF-8 binary) and absence (omitted key),
  as R1 does. `<pkg>/telemetry` should also export `event_names()`.
- **2 (returned records).** `forwarder.Dropped` already gained a field once
  (CHANGELOG). Tell callers to match read records as
  `Dropped(rejected:, ..)` and never construct them.

## 7. Open questions

1. **`String` or `Atom` names and keys (R4)?** Strings remove an import and
   the `atom.create` calls, but hide atom creation; the grammar check stops
   accidents, not a deliberate `"tenant_" <> id`.
2. **Panic or `Result` for definition bugs** (duplicate key, reserved span
   key, bad name, empty `with_id`)? The proposal panics; the conventions
   favor typed errors.
3. **Correlation shape.** Is an opaque string of at most 128 bytes enough, or
   should it follow W3C `traceparent` for an OpenTelemetry adapter? Should
   sinal also define a `causation` (parent) field?
4. **Route-aware `emit` (R2)** costs about 14 ns per event with no routes.
   Does any caller need an emit that ignores routes?
5. **Default isolation.** Should sinal ship an OTP application with a
   default forwarder, so that isolating a library is one `route` call with
   no supervisor?
6. **Fallible handlers.** `Result(Nil, e)` handlers, typed failure observers
   and the exception-cleanup reporter have no external caller. R6 keeps
   them. Keep, or reduce `HandlerFailure` to decode failures and send
   cleanup reports to OTP `logger`?
7. **`correlation.observe` (R1, second step):** ship now, or after the
   siblings adopt the field and export `event_names()`?
