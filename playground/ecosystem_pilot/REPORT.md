# Integration pilot report

## Result

The consumer runs a synthetic inventory lookup through public Blueprint,
Relay, LLM Wire, and Sinal APIs. `gleam run` prints
`A-100 has 7 Ada Lovelace notebooks.` after real loopback Relay HTTP and
scripted Responses traffic. Ten integration tests pass: the original seven
scenarios plus discovery, mixed scoped observation, and fourth-provider
behavior.

## Source state

The pilot uses sibling path dependencies. Their Git heads are the authorized
baselines below; the API changes exercised here are uncommitted worktree changes
on top of those heads. The path dependencies do not pin the uncommitted state.

| Package                      | Baseline Git head                          | Uncommitted API used by this pilot                                                |
| ---------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------- |
| Blueprint (`json_blueprint`) | `d3f0708b61eddb4a4789c0476ab5384267814a51` | `codec.record3`, `codec.schema_json`                                              |
| Sinal                        | `dd09933e5466628f7d46fa896c389f31ba7d4cb6` | typed observations, `SubscriptionPlan`, explicit native time units                |
| Relay                        | `098417b03d7d984cbe556f21062c190ebbec08e0` | definitions, discovered dynamic calls, typed transport errors, HTTP listener      |
| LLM Wire                     | `cdfb38af290619a6fba890141b0701990691ba87` | configured sessions, schema-only tool admission, external provider adapter/replay |
| Oversight pilot              | `8db2b008095507ddf7499f2dcdb823b3d0c27a3f` | this uncommitted consumer, tests, and report                                      |

## Composition

The application owns `Lookup`, `InventoryItem`, the lookup handler, and the
continuation decision. Blueprint constructs the three-field inventory codec
with `record3`; the test exports the complete input and output schemas with
`schema_json`. One Relay `Definition(Lookup, InventoryItem)` is passed to
handler binding, typed client calls, local decode/encode helpers, and the
application's LLM declaration adapter. That adapter reads Relay's name,
description, and input codec, then separately admits the LLM Wire tool name.
There is no Relay-to-LLM dependency or recovered native type from remote JSON
Schema.

Relay's listener binds an ephemeral local port using the local Host/Origin
policy. Its client derives the endpoint from a URL and applies explicit bounded
timeout and response-size settings. LLM Wire's configured session carries
provider endpoint, limits, and deadlines from preparation through the
self-contained continuation. The host supplies a `types.ToolResult` with the
exact `types.ToolCall.id`; it does not reconstruct history or reapply settings.
Sinal observers receive typed Relay and LLM lifecycle fields. The new mixed
scope binds unlike event shapes into a single `SubscriptionPlan` and removes
both registrations after work.

The dynamic path lists the remote Relay declaration, admits its advertised
finite input schema through Blueprint's document parser, and passes the
resulting `RuntimeContract` to `types.tool_from_contract`. It parses the LLM
tool arguments into exact Blueprint `Value`, invokes `client.call_discovered`
without field-specific decoding, and forwards its structured result through the LLM
continuation. The separate consumer's `fourth_provider` module owns its
request encoding, SSE reduction, and assistant-turn replay, while LLM Wire
retains execution limits and continuation checks.

## Scenario evidence

| Scenario                                | Observation                                                                                                                                                                                                                      |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Successful lookup                       | `A-100` becomes typed input; Relay returns the Ada Lovelace notebook record with quantity 7. The scripted provider validates the schema, call ID, and correlated result, then returns the expected sentence.                     |
| Invalid arguments                       | The provider emits `{"sku":42}`. LLM Wire rejects the call during schema validation; Blueprint also rejects it. A direct malformed MCP request receives JSON-RPC `-32602`, with no handler invocation.                           |
| Rendered application error              | A missing SKU invokes the handler. The explicit renderer publishes `inventory record not found` in MCP `isError` text; the host sends that text under `call_1`, and the provider returns its not-found answer.                   |
| Generic application error               | The same admitted definition with the ordinary handler publishes the stable `Tool execution failed.` message over real Relay HTTP. The private reason stays on the test-owned observation subject.                               |
| JSON-text application error             | An explicit error renderer publishes the JSON string `"inventory record not found"` over real Relay HTTP. The consumer parses the text as a JSON string.                                                                         |
| Cancellation                            | The host reads a partial text delta, closes the configured stream, observes provider socket closure and Sinal cancellation/cleanup, and never invokes the Relay handler.                                                         |
| Provider disconnect                     | The provider closes after one request. LLM Wire returns `TransportError`; no retry appears during the 1.6-second observation window and no Relay handler runs.                                                                   |
| Discovered schema and mixed observation | The listed input schema becomes a Blueprint runtime contract and schema-only LLM tool. A dynamic Relay call returns structured content; the result completes the OpenAI continuation while mixed Sinal observers receive events. |
| Fourth HTTP/SSE provider                | The app-owned reducer produces text and a tool turn. Its replay retains assistant text and call ID in the next request, which the local server verifies before returning a final answer.                                         |
| Fourth-provider bound                   | A scripted text event exceeds `text_bytes_per_block_limit`; the shared runtime returns `RunFailure(ResourceLimitExceeded, retry)` with response evidence.                                                                        |

Only the external provider is scripted. The pilot uses package-owned clients,
server, codec admission, stream owner, and telemetry implementations through
real local transports.

## Verification and limits

From `playground/ecosystem_pilot` on `aarch64-darwin`:

- `gleam format --check src test` — pass.
- `gleam check` — pass.
- `gleam run` — pass; printed the sentence above.
- `gleam build` — pass.
- `gleam test` — pass; 10 tests, 0 failures.

The pilot does not use real provider credentials, paid requests, external data,
or live OpenAI behavior. It does not prove remote schema acceptance, production
Host/Origin policy, authorization, or TLS for the pilot route. Cancellation
covers closure before tool execution; it does not prove duplicate-effect
protection after a handler runs. An early assertion failure can skip the
scenario's explicit teardown. The disconnect test's bounded observation does
not establish behavior after that window. The discovered schema is within
Blueprint's finite subset; arbitrary remote JSON Schema remains unsupported.
Relay's dynamic call checks that arguments are an object and leaves full
input-schema enforcement to the remote server; the LLM declaration performs
its own admitted schema validation before the pilot forwards arguments.
