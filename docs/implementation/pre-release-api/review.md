# Public API review after cleanup

This review treats the application as the caller. Shared definitions should carry derivable values, configuration should compose before effects, and an advanced capability should justify every additional entry point. The accompanying [contract](contract.md), declaration audits, and [acceptance evidence](acceptance.md) record the implemented scope. Blueprint is released; the other three packages have no compatibility requirement.

## Ranked decisions

| Rank | Decision                                                                                                                                                                                                                                                  | Impact / confidence | Capability preserved                                                                                                                                  | Caller and migration effect                                                                                                                                                                                           |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | [Relay tools](/code/gleam-dream/relay/src/relay/tool.gleam) admit input/output codecs once in a `Definition`, then bind an input-only handler with a generic error type.                                                                                  | High / high         | Typed input/output, schema discovery, heterogeneous registration, deliberate public error text, per-invocation context through advanced handlers.     | Removes unused error codecs and ordinary context placeholders. Delete old three-codec calls and root imports; migrate explicit JSON errors to a renderer.                                                             |
| 2    | [LLM sessions](/code/gleam-dream/llm_wire/src/llm_wire/session.gleam) expose configured calls, retained continuations, and one set of business types.                                                                                                     | High / high         | Incremental and buffered reading, structured output, exact continuation coverage, provider replay, cancellation, retry evidence, pools, verified TLS. | Callers supply settings and request once. Old root/API/runtime workflows migrate to `config` and `session`; raw transport/provider implementation is unsupported application API.                                     |
| 3    | [Relay clients](/code/gleam-dream/relay/src/relay/client.gleam), [listeners](/code/gleam-dream/relay/src/relay/transport/http.gleam), and [LLM settings](/code/gleam-dream/llm_wire/src/llm_wire/config.gleam) use defaults plus immutable configuration. | High / high         | Explicit listener policy, TLS/CA, response limits, deadlines, optional services, process ownership.                                                   | Deletes startup variants. Ordinary HTTP clients supply a URL; stdio clients supply executable/arguments. LLM callers modify only the limits or deadlines they need.                                                   |
| 4    | Relay annotations remain independent optional fields with named modifiers.                                                                                                                                                                                | Medium / high       | Omission versus false, and read-only plus open-world together.                                                                                        | Removes positional annotation and metadata constructor families. Use the default value with named modifiers or labeled record updates.                                                                                |
| 5    | [Sinal](/code/gleam-dream/sinal/src/sinal.gleam) observes infallible callbacks directly and takes fallible callbacks without a nominal wrapper.                                                                                                           | Medium / high       | Native telemetry identity, synchronous execution, failure isolation, multi-event attachment, scoped cleanup.                                          | Remove `sinal.handler(...)`; ordinary observers omit selected-event and failure callbacks. Primitive field helpers remove repeated native conversions.                                                                |
| 6    | [Blueprint codecs](/code/gleam-dream/json_blueprint/src/json/blueprint/codec.gleam) supply direct schema JSON and record helpers while retaining released capabilities.                                                                                   | Medium / high       | Exact numbers, runtime/generated codecs, recursive Decoder, existing legacy schema representation, inexpensive Value aliases.                         | Ordinary records use one codec. The fragile migration adapter is removed; retained recursive decoders need no rewrite. See the [planned 2.0 migration guide](/code/gleam-dream/json_blueprint/docs/migration-2.0.md). |

## Register and call one tool

The former constructor required a codec for an application error even though discovery did not advertise an error schema. Returning JSON text does not require dedicated error-codec machinery: an explicit renderer preserves that behavior. The constructor also required a context argument when the handler did not use it:

```gleam
relay.context_tool(name, metadata, input_codec, output_codec, error_codec,
  fn(_context, input) { lookup(input) },
)
```

The ordinary path now separates checked admission from handler binding:

```gleam
let assert Ok(definition) = tool.definition(name, input_codec, output_codec)
let registered = tool.handle(definition, lookup)
let outcome = client.call_definition(connection, definition, input)
```

The definition is shared; the codecs are not repeated at call time. `handle_with_error_renderer` explicitly chooses public error text. A renderer can produce JSON text when the application needs it; a dedicated encoded-error constructor adds no separate capability. Advanced handlers receive `HandlerCallContext` and can retain per-invocation application data, report progress, return rich content, or request client input. A separate `ContentDefinition` admits only an input codec; its client result does not pretend to decode structured output.

Annotations express independent facts:

```gleam
let annotations =
  tool.empty_annotations()
  |> tool.with_read_only_hint(Some(True))
  |> tool.with_open_world_hint(Some(True))
  |> tool.with_destructive_hint(Some(False))
```

The remaining hint stays unspecified. A mutually exclusive effect enum would lose valid combinations, and a set of positive tags alone would lose explicit false.

## Configure, call, and continue

Relay derives host, port, path, and TLS mode from a URL. Modifiers return a new configuration; connection checks the completed settings:

```gleam
let assert Ok(connection_settings) = client.http_config("http://127.0.0.1:8080/mcp")
connection_settings
|> client.with_timeout(10_000)
|> client.connect_http
```

A listener similarly composes with TLS, bind options, and explicit policy before `http.start`. Server resource, prompt, and completion services have named modifiers. Changing the bind options does not silently widen the Host/Origin policy.

LLM Wire retains settings in prepared calls and continuations:

```gleam
let settings =
  config.openai(key)
  |> config.with_deadlines(
    types.Deadlines(..types.default_deadlines(), overall_timeout_ms: 30_000),
  )
let assert Ok(prepared) = session.prepare(settings, request)
let assert Ok(outcome) = session.run(prepared)
```

A `RunToolCalls` result includes the continuation. `session.prepare_continue(continuation, results)` restores the originating provider, request, configuration, and replay state. Structured continuations also retain their output codec. A continuation starts a fresh execution budget with the retained timeout durations. Streaming reads derive their timeout from the stream; buffered collection remains available after partial progress reads, before consuming the terminal. Provider-specific settings remain fallible and compose through `Result`, because applying an OpenAI project to an Anthropic configuration is invalid.

## Blueprint and Sinal in the application

When a JSON Schema string is required, use `codec.schema_json(codec)` instead of separately extracting a schema, building its document, and rendering it. Unknown custom schemas still fail explicitly. `record2`/`record3` avoid nested tuple mapping; larger records retain the general `Properties` composition path.

The released Decoder is not redundant: it supports recursive decoding and schema constructs outside the modern finite codec profile. Its legacy renderer labels output Draft-07 while also using `$defs`; retaining that behavior is not a new strict-dialect interoperability guarantee. Modern object codecs are closed, and their tagged-union envelope differs from the released union helpers. The 2.0 guide documents those differences rather than promising a drop-in conversion.

For observation, the ordinary Sinal path is:

```gleam
sinal.observe(id, event, fn(measurements, metadata) {
  record_observation(measurements, metadata)
})
```

Fallible callbacks use `attach` directly, without `sinal.handler`; scoped and multi-event attachment remain distinct operations. Sinal retains native BEAM field encoding, so Blueprint JSON codecs are not imposed on telemetry.

## Composition evidence and limits

The [ecosystem pilot](/code/gleam-dream/oversight/playground/ecosystem_pilot/src/ecosystem_pilot.gleam) uses one admitted Relay definition for registration, typed calls, and its application-owned LLM tool-declaration adapter. Blueprint supplies its codecs and schemas; Sinal observes the LLM and Relay transitions. The adapter remains in the application because Relay and LLM Wire have distinct name admission and protocol responsibilities. The pilot covers success, invalid arguments, rendered errors, generic errors, deliberate JSON-text errors, cancellation, and disconnects using local transports.

The useful uncertainties were tested with concrete usage: generic handler errors need no codec; content-only tools need no output codec; continuation settings and structured codecs can be retained; and both annotation hints coexist. Actual provider acceptance outside the frozen supported profiles still requires separate evidence. Internal module metadata identifies unsupported implementation APIs but does not prohibit imports; opaque types enforce their construction boundaries.
