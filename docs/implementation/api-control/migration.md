# API control migration

This guide accompanies the [implementation contract](contract.md). Blueprint
has a released API, so compatible additions remain additive; its corrected
parser acceptance is a 2.0 behavior change. Sinal, Relay, and LLM Wire were
pre-release and remove superseded public forms without aliases.

## Blueprint 2.0

| Consumer use                                                  | Update                                                                                                                                                                                                             |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Fallible native projection from a known wire shape            | Use `codec.try_imap(base, from, to)` and handle located mapping failures in either direction. `imap` remains for total mappings.                                                                                   |
| Optional property represented as `Option(a)`                  | Use `codec.optional_option(name, codec)`. With a nullable codec, `None`, `Some(Null)`, and `Some(NonNull)` preserve absence, present null, and present value. `codec.optional` and `Optional(a)` remain available. |
| Caller-selected JSON bounds                                   | Use `codec.decode_json_with_limits(codec, limits, source)` with `parser.ParserLimits`.                                                                                                                             |
| Generated native JSON parser as a performance choice          | Call `codec.decode_json_native` explicitly. Ordinary `decode_json` now uses Blueprint's strict parser for interpreted, generated, and mapped codecs.                                                               |
| Hand-written assumptions about default numeric rejection      | Recheck them. Default parsing admits exact finite binary64 constructions, including subnormals, within finite byte, depth, token, and exponent bounds. Configure stricter parser limits when required.             |
| Native integer projection or document loading at large bounds | Recheck old 24-digit assumptions. Capacity now derives from admitted bounds while JavaScript safe-integer checks still apply.                                                                                      |
| Legacy JavaScript map lookups                                 | Recheck tests involving missing keys and keys present with `undefined`; these cases are preserved distinctly where the decoder requires it.                                                                        |

The parser still rejects duplicate object keys and unsupported JSON Schema
documents. A `try_imap` native restriction can be stricter than its unchanged
wire schema. Consumers needing that extra rule on the wire must express it in
their own admission policy.

## Sinal

| Earlier use                                                                            | Current use                                                                                                                                                                                                                   |
| -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `EmitError.BackendFailed`                                                              | Remove this unreachable match arm. Encoding errors remain typed; native telemetry callback behavior is separate.                                                                                                              |
| Decode native timing fields as `Dynamic` or select among raw-unit and per-unit helpers | Use `span.duration_in`, `span.system_time_in`, and `span.monotonic_time_in` with `span.TimeUnit` (`Native`, `Nanosecond`, `Microsecond`, `Millisecond`, `Second`). Native context and exception terms remain dynamic.         |
| Raise on any span instrumentation encoding failure                                     | Use `span.run_span_result` and handle `StartEncodingFailed` or `CompletionEncodingFailed(result, error)`. The latter preserves completed application work. `run_span` remains the explicit raising policy.                    |
| Manually group unlike event shapes into one scope                                      | Build typed `sinal.subscription` values, collect them with `sinal.subscriptions`, and call `sinal.with_subscriptions(plan, work)`. Configure `with_exception_cleanup_reporter` only when exception cleanup needs an observer. |

Native `attach_many` remains the distinct same-shaped grouped registration
path. `with_attachments` scopes an acquired attachment. Heterogeneous
subscriptions acquire sequentially; an acquisition error skips work and rolls
back prior registrations.

## Relay

| Earlier use                                                                | Current use                                                                                                                                                                                                                                                                                         |
| -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Client `TransportFailure(String)` or separate `Cancelled` outcome          | Match `TransportFailure(TransportError)`, including `ConnectionClosed`, `RequestCancelled`, `RequestTimedOut`, `ResponseLimitExceeded`, and `TransportFault(detail)`.                                                                                                                               |
| Content call result through `ContentCallError`                             | Handle `ContentCallOutcome`, including success, failure, transport, protocol, and input-required cases.                                                                                                                                                                                             |
| Parse a discovered tool response as raw JSON-RPC                           | Parse tool arguments to exact Blueprint `Value` and use `client.call_discovered(client, declaration, arguments)` for structured `Value`, content blocks, and distinct outcomes. Keep raw JSON-RPC only for unsupported methods.                                                                     |
| Treat a tool input request as an automatic response                        | Configure supported methods with `with_input_methods`, then handle `InputRequired` and call `resume_tool` with exactly one JSON object per requested key. Defaults advertise no input methods.                                                                                                      |
| Unbounded aggregate listing                                                | Configure `with_listing_limits`; defaults bound pages and items. Use `raw_json_call` with explicit cursor handling only if the typed aggregate bound is unsuitable.                                                                                                                                 |
| Direct construction of `StdioConfig`                                       | Add `input_methods` and `listing_limits` fields, or start with `client.stdio_config(executable, args)` and update its public record. Defaults are `[]` and `default_listing_limits()`.                                                                                                              |
| `server.server_with_dispatch`                                              | Create `server.server(registry)` and apply `server.with_dispatch(server, handler)`. Registry updates preserve the custom handler and supply it the current registry.                                                                                                                                |
| `runtime.start_with_status_sink` or output bytes without exchange identity | Use the current runtime start and `runtime.OutputWrite(exchange, bytes)` / `runtime.OutputClose(exchange)`. Report closure with `runtime.exchange_closed(runtime, exchange)`.                                                                                                                       |
| Invalid runtime/stdio settings discovered after startup                    | Handle startup validation errors before actors or stdio are allocated. The failing setting and value are retained.                                                                                                                                                                                  |
| Advanced content handler returning bare blocks                             | Return `tool.ContentComplete(blocks)` or `tool.ContentNeedsInput(requests)` from `handle_content_advanced`; no dummy structured output codec is needed.                                                                                                                                             |
| Direct construction or record update of `ContextResourceTemplate`          | Call fallible `resources.resource_template(uri_template, name, read)` for supported syntax or `resource_template_with_matcher` for application matching. Apply `with_template_title`, `with_template_description`, `with_template_mime_type`, and `with_template_annotations` to the opaque result. |
| Direct construction of `HttpPolicy`                                        | Supply the new positive `sse_keepalive_ms` field; `local_http_policy(host)` retains the 250 ms default.                                                                                                                                                                                             |

Content-only definitions now support input schema overrides and advanced
input rounds. Resource templates with unsupported matching syntax fail before
advertisement; use an explicit matcher for broader patterns. HTTP SSE keepalive
is an admitted setting.

## LLM Wire

| Earlier use                                                                                                   | Current use                                                                                                                                                                                                                               |
| ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `config.openai(key)`, `config.anthropic(key)`, `config.google(key)`                                           | Construct provider options first, for example `config.openai(openai.options(key))`, then apply common settings with `config.with_limits`, `with_deadlines`, and `with_endpoint`. Provider-specific modifiers live on the options modules. |
| `config.with_openai_organization`, `with_openai_project`, `with_anthropic_version`, `with_google_api_version` | Use the matching provider options builders before common `Config` construction.                                                                                                                                                           |
| `session.run` or `session.collect` returning `WireError` directly                                             | Match `session.RunFailure(error, retry)`; `session.prepare` still returns a separate `WireError`. Stream terminal failures carry the same retry evidence.                                                                                 |
| `session.stream` returning `WireError` on an open failure                                                     | Match `session.RunFailure(error, retry)` so a buffered or manual stream caller retains the same typed retry evidence.                                                                                                                     |
| `RunToolCalls(calls, continuation, usage)`                                                                    | Match `RunToolCalls(text, calls, continuation, usage)`. Assistant text is retained along with provider-authored replay state.                                                                                                             |
| A native codec invented solely to register a remote schema                                                    | Parse and admit the supported finite Blueprint schema as `RuntimeContract`, then use the infallible `types.tool_from_contract`. Unsupported schema documents and provider projections fail at their own boundaries.                       |
| Built-in provider switch edit for a fourth HTTP/SSE service                                                   | Build `provider.Spec`, `Reducer`, and `Replay`; pass its `Adapter` to `config.from_provider`. The common session runtime retains bounds, deadlines, cancellation, and exact tool-result coverage.                                         |

Direct `types.Limits` constructors must now supply both `request_bytes_limit`
and `provider_metadata_bytes_limit`; updating `types.default_limits()` is the
shortest route. Outgoing request bytes and provider metadata have independent
bounds from incoming SSE. Tool argument and structured-output parsing derive
byte bounds from the relevant admitted execution limits. Missing usage remains
`None` rather than a fabricated zero. A custom provider's opaque `Replay`
closure retains application-owned assistant state in memory until the
continuation is released; keep it bounded and avoid capturing unrelated
resources.

The [pilot](../../../playground/ecosystem_pilot/README.md) contains a separate
consumer package with both the simple built-in path and these extension paths.
