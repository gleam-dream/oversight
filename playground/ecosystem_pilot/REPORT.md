# Integration pilot report

## Result

The consumer runs a complete synthetic inventory lookup through the public
Blueprint, Relay, LLM Wire, and Sinal APIs. `gleam run` executes the successful
roundtrip against ephemeral loopback servers, and the five-scenario consumer
suite passes. Relay now puts the exact JSON serialization of a successfully
encoded application error in standard MCP `isError` text content. The public
client retains that text, and the consumer decodes it with the same Blueprint
error codec before continuing the LLM Wire call under `call_1`. An error-codec
failure remains a generic JSON-RPC internal error.

## Dependency heads observed

The consumer uses sibling path dependencies in `manifest.toml`; those paths do
not pin Git commits. These are the observed heads, including the committed
Relay follow-up:

| Package                      | Git head observed                          | Version |
| ---------------------------- | ------------------------------------------ | ------- |
| Relay                        | `098417b03d7d984cbe556f21062c190ebbec08e0` | `0.1.0` |
| LLM Wire                     | `cdfb38af290619a6fba890141b0701990691ba87` | `0.1.0` |
| Blueprint (`json_blueprint`) | `d3f0708b61eddb4a4789c0476ab5384267814a51` | `1.7.1` |
| Sinal                        | `dd09933e5466628f7d46fa896c389f31ba7d4cb6` | `0.1.0` |

## Composition and scenario evidence

The consumer defines one `Lookup` codec and one `InventoryItem` codec with
Blueprint. Relay admits the lookup schema and dispatches typed input over its
real HTTP client/server boundary. LLM Wire derives its OpenAI function schema
from the same lookup codec, returns the provider's tool call to the host, and
validates the call ID when preparing a continuation. The consumer encodes the
typed Relay result with the item codec before sending it back. Sinal handlers
capture only typed lifecycle fields: stage, provider, outcome, duration, and
status. The test-owned invocation subject carries the SKU only for proving
whether the handler ran; it is not telemetry.

| Scenario            | Result | Evidence                                                                                                                                                                                                                                                                                                                                |
| ------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Valid lookup        | Pass   | `A-100` decodes as typed input; Relay returns the checked-in Ada Lovelace notebook record with quantity `7`; the provider validates the generated schema and continuation output for `call_1`; the final answer is captured. Relay reports `success`; LLM Wire reports `completed_tools` then `completed_text`.                         |
| Invalid arguments   | Pass   | The scripted provider returns a function call with `{"sku":42}`; LLM Wire rejects it during tool-schema validation, and the Blueprint codec also rejects the payload. A direct malformed MCP call receives JSON-RPC invalid-params code `-32602`; the handler subject remains empty.                                                    |
| Missing record      | Pass   | Relay invokes the handler with `MISSING`; the declared error codec returns `inventory record not found`. The client receives its exact JSON string representation in `isError` content, the host decodes it with the same codec, and the provider accepts the decoded error under `call_1` before returning its final not-found answer. |
| Cancellation        | Pass   | The provider sends an in-progress response containing an incomplete function call and a text delta. The host reads the delta, closes LLM Wire, observes the provider socket close, and sees Sinal cleanup and cancellation events. Relay's handler subject remains empty and the provider worker exits.                                 |
| Provider disconnect | Pass   | The provider accepts one valid request and closes the connection. LLM Wire returns a typed `TransportError`; the server observes no retry over 1.6 seconds, no tool invocation occurs, and the test-owned provider worker is stopped.                                                                                                   |

The local provider validates decoded request JSON, model, prompt, tool schema,
continuation `call_id`, and the result content. It also checks the actual
Responses route, JSON content type, and local placeholder authorization header.
Provider and Relay traffic stay on loopback.

## Fixture provenance

Relay's protocol subset is backed by its existing frozen MCP 2026-07-28 schema
fixture: upstream tag `2026-07-28`, commit
`5f5440bb26a62e2cf3440b92da5a667efa03b267`, MIT, SHA-256
`ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203`. The
provenance is recorded in
[`relay/test/fixtures/mcp_2026/README.md`](../../../relay/test/fixtures/mcp_2026/README.md).
The pilot does not copy that schema or implement a second MCP envelope.

The scripted Responses event sequence follows the local OpenAI reducer and
loopback interaction contracts in
[`llm_wire/test/llm_wire_openai_test.gleam`](../../../llm_wire/test/llm_wire_openai_test.gleam)
and
[`llm_wire/test/llm_wire_integration_test.gleam`](../../../llm_wire/test/llm_wire_integration_test.gleam).
The continuation shape also aligns with the selected ReqLLM v1.24.0
`function_call_output` comparator documented in
[`llm_wire/test/oracle/README.md`](../../../llm_wire/test/oracle/README.md):
tagged commit `fd9e079fddf253e9b719b2d2c6920f4306592809`, Apache-2.0. The pilot
uses synthetic payloads encoded with `gleam/json`; it does not copy provider
fixtures or claim upstream suite parity.

## Friction and avoided work

Relay already encodes handler errors through the declared application-error
codec. The server keeps that complete JSON value in standard MCP text content
as exact JSON text, so a consumer can recover it with the same codec. No new
renderer API is needed. Error-encoding failures still produce a sanitized
JSON-RPC internal error.

The rest of the path composes without internal imports, foreign casts, copied
production modules, duplicated JSON Schemas, a custom JSON parser, a provider
SDK, or a new workflow framework. The consumer uses Blueprint codecs for
schema-bearing values, ordinary Gleam JSON for protocol envelopes, package
clients for transport and continuation, and the host for tool execution. The
local provider fixture does its own small TCP/HTTP framing because it is the
external service boundary; it uses Gleam's JSON parser and encoder for payloads.

## Limits and validation

Cancellation verifies stream and socket closure, but does not run a host
dispatch loop after cancellation. The disconnect occurs before tool execution;
its 1.6-second no-retry observation does not establish duplicate-effect
protection after a tool has run. Test teardown follows assertions, so an early
assertion failure can skip provider-worker and telemetry cleanup. Independent
review accepted the focused error-propagation fix with these pilot limits.

No real provider, credentials, paid request, external data, TLS certificate, or
live OpenAI behavior was exercised. The placeholder key and synthetic provider
events establish only the local request/response contract. Live authentication,
model-specific behavior, provider-side schema acceptance, rate limits, and
network failure modes remain unproved.

Synchronous checks completed from this directory:

- `nix develop --command gleam format --check src/ecosystem_pilot.gleam src/scripted_provider.gleam test/ecosystem_pilot_test.gleam` — pass.
- `nix develop --command gleam check --target erlang` — pass.
- `nix develop --command gleam run` — pass; printed `A-100 has 7 Ada Lovelace notebooks.`
- `nix develop --command gleam test --target erlang` — pass; 5 tests, 0 failures.

Relay follow-up checks from its repository:

- `nix develop --command gleam format --check src/relay/server.gleam test/relay/client_test.gleam` — pass.
- `nix develop --command gleam test --target erlang` — pass; 107 tests, 0 failures.

From the Oversight root, `nix flake check` passed its treefmt check on
`aarch64-darwin`. Nix omitted `aarch64-linux`, `x86_64-darwin`, and
`x86_64-linux` as incompatible with the current host; that check preceded the
Relay follow-up.
