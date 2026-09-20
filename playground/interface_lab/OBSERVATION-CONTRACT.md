# Sinal observation contract

## Decision

- Sinal should be a typed facade over `telemetry` rather than the actor-per-event runtime proposed in `sinal-design.md`.
- The current laboratory establishes only a pure typed field boundary and callback classification.
- Native maps, atoms, registry behavior, dispatch, isolation, and spans remain later Erlang-target work.
- Sinal remains observation infrastructure; it does not control jobs, workflows, approvals, retries, or durable resume.

## Implemented pure interface

- `sinal_fields.FieldMap` is a constructor containing `List(#(String, Value))`.
- Its strings are logical field labels rather than native BEAM map keys.
- `sinal_fields.field(name, codec)` creates one typed field.
- `sinal_fields.pair(left, right)` combines two field sets, rejects duplicate declared labels, and supports arbitrary nesting through pairs.
- `encode` preserves field encoding failures; `decode` distinguishes missing, duplicate, and invalid fields.
- `sinal.Event(measurements, metadata)` retains a logical `List(String)` name plus distinct `Fields` values.
- `Handler(measurements, metadata, error)` retains a typed callback.
- The implemented pure callback boundary is:

  ```gleam
  pub fn handler(
    run: fn(m, d) -> Result(Nil, e),
  ) -> Handler(m, d, e)

  pub fn deliver_foreign(
    event: Event(m, d),
    handler: Handler(m, d, e),
    measurements: FieldMap,
    metadata: FieldMap,
  ) -> Result(Nil, HandlerFailure(e))
  ```

- Measurement decode failure returns `MalformedMeasurements(FieldError)` before handler invocation.
- Metadata decode failure returns `MalformedMetadata(FieldError)` before handler invocation.
- A typed callback error returns `HandlerReturned(error)`.
- It is a pure probe, not `telemetry:execute/3`, and its result is not an emitter result.

## Planned runtime interface

- `emit`, `attach`, and `detach` exist as honest runtime `todo` boundaries.
- `attach` accepts a `Handler`, an attachment identifier, and `on_failure: fn(HandlerFailure(e)) -> Nil`.
- The planned bridge should report a declared decode or handler failure, then fail the raw callback so upstream detaches it and emits its standard handler-failure event.
- `emit` must not return attached-handler errors because upstream catches callback failures while continuing dispatch.
- An unexpected raise, exit, or throw cannot become the handler's typed `e`; it remains an upstream callback failure.
- An attachment is copyable, so the type cannot guarantee a single detach; a repeated detach remains a runtime `NotAttached` outcome.

## Map and atom boundary

- Upstream `telemetry:execute/3` expects an atom-list event name, a measurements map, and a metadata map.
- The former laboratory `Event(Int, String)` used scalar Blueprint codecs and therefore could not produce those maps.
- `Fields` corrects the structural mismatch without pretending that the laboratory `FieldMap` is a native Erlang map.
- A later FFI must bind logical descriptor fields and event segments to atoms already defined by trusted application or library code.
- Sinal must never create atoms from runtime strings such as request values, tenant names, provider names, or foreign metadata.
- The FFI must decode every callback because a foreign emitter or an independently created descriptor can publish another shape under the same raw name.

## Verification record

- Before the graph consumer was introduced, the laboratory passed 16 isolated consumers, 17 intended negative compilations, and 8 pure probe groups.
- `foreign_observation` passed valid delivery with an unrelated field, malformed-measurement classification, malformed-metadata classification, typed handler failure, pair roundtrip, duplicate declaration rejection, and duplicate raw-field rejection.
- `scalar_event_codec` proved that a Blueprint scalar codec is not a Sinal `Fields` value.
- `handler_metadata` proved that a handler with incompatible metadata cannot be delivered through the typed event.
- No test called upstream `telemetry`, used a native BEAM map, bound an atom, attached a callback, detached a callback, or established process identity.

## Acceptance matrix

- **Accepted by compilation:** event measurement and metadata types remain distinct; mismatched handlers and scalar event codecs fail for the intended type error.
- **Accepted by pure execution:** field encoding and decoding, unrelated-field tolerance, duplicate detection, pair composition, and the three `HandlerFailure` classifications behave as asserted.
- **Pending FFI acceptance:** logical fields become native maps with existing atom keys without dynamic atom creation.
- **Pending upstream acceptance:** handlers run in the emitter process and finish before `emit` returns.
- **Pending failure acceptance:** malformed payloads and declared handler errors cause reporting, upstream detachment, and `[telemetry, handler, failure]` without propagating through `emit`.
- **Pending registry acceptance:** duplicate handler identifiers and repeated detach map to the declared typed errors before and after `telemetry:persist/0`.
- **Pending span acceptance:** start, stop, exception, native time, reserved context, stop metadata, and re-raising match `telemetry:span/3`.

## Composition implications

- A package can eventually export one typed event descriptor beside its ordinary API.
- A consumer can then attach typed observations without importing that package's scheduler or persistence implementation.
- Raw Erlang and Elixir handlers remain interoperable only after Sinal emits through the shared upstream registry.
- Foreign BEAM events become typed only after callback-boundary decoding; the descriptor cannot constrain the foreign emitter.
- A slow handler delays the emitter under the intended synchronous contract.
- Buffering and asynchronous export belong in a separate forwarding adapter with an explicit queue, overload, and loss policy.
- Sinal events may describe any ecosystem package while never serving as their control feed.

## Upstream oracle

- The pinned oracle is Apache-2.0 [`telemetry` 1.4.2](https://hex.pm/packages/telemetry/1.4.2).
- The exact implementation is [`src/telemetry.erl` at `v1.4.2`](https://github.com/beam-telemetry/telemetry/blob/v1.4.2/src/telemetry.erl).
- The exact upstream tests are the [`v1.4.2` test tree](https://github.com/beam-telemetry/telemetry/tree/v1.4.2/test).
- The published API reference is [`telemetry` 1.4.2](https://telemetry.hexdocs.pm/1.4.2/telemetry.html).
- Upstream documents synchronous same-process dispatch, unspecified handler order, duplicate-ID rejection, absent-detach reporting, and detach-plus-failure-event isolation for callbacks that raise, exit, or throw.
- Those upstream facts define the oracle; they do not establish Sinal conformance until the FFI probe passes.
