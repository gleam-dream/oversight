# Sinal for Gleam — Design Doc

A strongly-typed take on [`beam-telemetry/telemetry`](https://github.com/beam-telemetry/telemetry),
built for Gleam's generics instead of Erlang's dynamic maps and atoms.

## Why not just port `:telemetry` as-is?

`:telemetry` is dynamic almost everywhere because Erlang has no compile-time
generics: one global ETS table has to hold handlers for _every_ event in the
VM, regardless of shape. Concretely:

| Concept         | Erlang `:telemetry`          | This library                                              |
| --------------- | ---------------------------- | --------------------------------------------------------- |
| Event name      | `[atom()]`                   | `EventName` — validated, non-dotted segments              |
| Measurements    | `map()`                      | a concrete record, generic on the event                   |
| Metadata        | `map()`                      | a concrete record, generic on the event                   |
| Handler config  | `term()`                     | captured in the handler closure                           |
| Handler storage | one global ETS table         | one actor per event, mailbox pinned to that event's types |
| Handler shape   | `{Module, Function, Config}` | `fn(Event(measurements, metadata)) -> Nil`                |

Gleam can express "measurements for the `http.request.stop` event are
exactly this record" at compile time, so an emitter and a handler that
disagree on shape simply won't compile — no `KeyError` on a misspelled atom
at 3am.

**The trade-off:** you lose `:telemetry.attach/4`'s ability to point one
handler at several _differently-shaped_ events at once — Gleam can't express
"a handler for any of these" without smuggling in `Dynamic`. In exchange you
get full type checking on every event you define yourself. The one place
`Dynamic` is unavoidable is bridging to _real_ BEAM libraries that call the
actual `:telemetry.execute/3` (Cowboy, etc.) — see [Interop](#interop-with-real-telemetry) below.

## Core pieces

```
EventName            — validated, dot-free segments: event_name(["http","request","stop"])
Event(m, d)           — the envelope: name, measurements: m, metadata: d, emitted_at
EventDefinition(m, d) — a live, typed channel; one per event you emit
Handler(m, d)         — { id, run: fn(Event(m, d)) -> Nil }
SpanEvents(s, e, x)   — three EventDefinitions for span start/stop/exception
```

An `EventDefinition` is backed by a small actor that owns the handler list
for _that event only_. Since every handler in that actor's list already
shares one shape, there's no heterogeneity to smuggle past the type system —
unlike the global ETS table, this registry never needs `Dynamic`.

## How a library emits events

A library author defines the event's shape once, usually in a module the
library exposes, and calls `execute` (or `span`) wherever the real work
happens. This is the same shape as `:telemetry.execute/3`, just typed.

```gleam
// my_http_client/sinal.gleam
import sinal.{type EventDefinition}

pub type RequestStopMeasurements {
  RequestStopMeasurements(duration: duration.Duration, response_bytes: Int)
}

pub type RequestMetadata {
  RequestMetadata(method: String, url: String, status: Int)
}

/// Library consumers hold onto this value to attach handlers.
pub fn requests_stop_event() -> EventDefinition(RequestStopMeasurements, RequestMetadata) {
  // In practice you'd start this once at application startup (e.g. under
  // a supervisor) and expose the resulting EventDefinition, rather than
  // creating a fresh actor per call.
  let assert Ok(name) = sinal.event_name(["my_http_client", "request", "stop"])
  let assert Ok(def) = sinal.define_event(name)
  def
}
```

Then, at the call site inside the library:

```gleam
pub fn get(url: String) -> Result(Response, HttpError) {
  let events = my_http_client_registry.requests_stop_event()
  let started = timestamp.system_time()

  use response <- result.try(do_request(url))

  sinal.execute(
    events,
    measurements: RequestStopMeasurements(
      duration: timestamp.difference(started, timestamp.system_time()),
      response_bytes: byte_size(response.body),
    ),
    metadata: RequestMetadata(method: "GET", url: url, status: response.status),
  )
  Ok(response)
}
```

For request/response pairs where you want automatic start/stop/exception
events and accurate timing, use `span` instead of hand-rolling the
before/after calls:

```gleam
pub fn get(url: String) -> Result(Response, HttpError) {
  sinal.span(
    events: my_http_client_registry.request_span_events(),
    start_metadata: StartMetadata(method: "GET", url: url),
    work: fn() {
      case do_request(url) {
        Ok(response) ->
          Ok(#(response, StopMetadata(status: response.status)))
        Error(err) ->
          Error(sinal.SpanException(
            metadata: ExceptionMetadata(reason: err),
            message: http_error_to_string(err),
          ))
      }
    },
  )
}
```

`span` emits `start` immediately, then either `stop` or `exception` with a
`SpanMeasurements(duration: ...)` computed for you — mirroring
`:telemetry.span/3`, but every metadata payload is a typed record instead of
a map you have to remember the keys of.

## How a consumer attaches a handler

Since routing is by holding a reference to the same `EventDefinition` value
(not by string-matching a name at runtime), a consuming application needs
that value — typically exported by the library, the same way you'd import a
type or a function.

```gleam
import my_http_client/sinal as http_events
import sinal.{attach}
import gleam/io

pub fn install_logging() {
  let events = http_events.requests_stop_event()

  attach(to: events, run: fn(event) {
    io.println(
      event.metadata.method
      <> " " <> event.metadata.url
      <> " -> " <> int.to_string(event.metadata.status)
      <> " (" <> duration.to_string(event.measurements.duration) <> ")",
    )
  })
  Nil
}
```

The compiler checks `event.metadata.method` and `event.measurements.duration`
exist and are the right types — a handler for one event can't accidentally
be attached to a differently-shaped one, because `attach` requires an
`EventDefinition(measurements, metadata)` whose type parameters match the
handler function you pass it.

Detaching works the same way `:telemetry.detach/1` does, just with a typed
handle instead of a raw term:

```gleam
let id = attach(to: events, run: log_handler)
// ...later
sinal.detach(from: events, id)
```

### Consuming several related events with one handler

If a consumer wants one function to react to a _family_ of same-shaped
events (e.g. every span's stop event, which all share `SpanMeasurements`),
that's just attaching the same function to each `EventDefinition` — no
special API needed, since Gleam functions are ordinary values:

```gleam
let log = fn(event: sinal.Event(sinal.SpanMeasurements, meta)) {
  io.println("span finished in " <> duration.to_string(event.measurements.duration))
}

attach(to: db_events.query_span.stop, run: log)
attach(to: cache_events.lookup_span.stop, run: log)
```

This covers the common "attach one handler to many events" use case from
`:telemetry.attach_many/4` for the case that matters most in practice:
events that already share a shape. Events with genuinely different shapes
need genuinely different handler functions — which the type checker was
going to require anyway.

## Interop with real `:telemetry`

Some BEAM libraries you don't control (Cowboy, and most Erlang/Elixir
instrumentation) call the _actual_ `:telemetry.execute/3` with atom event
names and a raw `map()`. Observing those requires one unavoidable
`Dynamic`-touching boundary — decode the map the moment it crosses in, and
it's fully typed on the Gleam side from then on:

```gleam
import gleam/dynamic/decode

pub fn attach_to_real_telemetry(
  erlang_event_name: List(String),
  decode_measurements: decode.Decoder(measurements),
  decode_metadata: decode.Decoder(metadata),
  on_event: fn(sinal.Event(measurements, metadata)) -> Nil,
) -> Nil {
  // FFI call to :telemetry.attach/4. The handler function registered
  // there decodes the raw Erlang map with decode_measurements /
  // decode_metadata and only calls on_event() on a successful decode -
  // a malformed payload from a misbehaving library is dropped (and
  // logged), not a crash.
  todo
}
```

This keeps `Dynamic` confined to a single named module (`sinal/bridge`),
rather than letting it leak into every event definition the way it does in
a direct 1:1 port of the Erlang API.
