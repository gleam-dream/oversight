# llm_wire — API card

Scanned 2026-10-01 against `/code/gleam-dream/llm_wire` and sibling checkouts at
their current heads. Read-only scan; no package files changed.

## Health

- Git head: `1c0ad61 refactor!: migrate LLM Wire to shared HTTP Gun clients`
  (2026-09-30 21:43). Working tree clean.
- Repo gate: `nix develop -c sh dev/gate fast|full`. Its first step
  (`treefmt --fail-on-change`) rewrites files, so the scan ran the remaining
  steps individually in `nix develop`: format check, `gleam check`, `gleam build --warnings-as-errors`, `erlc -Werror`
  on test FFI and the HTTP boundary audit all **pass**. `gleam test`
  **fails: 175 passed, 48 failures.**

- **Cause of the failures:** the sibling `http_gun` changed after this migration.
  Its commit `b517725 feat: add destination policy and DNS pinning` (2026-10-01)
  makes `http_config.default()` allow public destinations only
  (`http_gun/src/http_gun/config.gleam:51`, `destination.default()`). LLM Wire's
  local-server tests use the default policy against loopback. 28 assertions fail
  with `HttpFailure(DestinationRejected)`; the remaining failures are knock-on
  `process.receive(..., 1000)` timeouts in fake servers waiting for connections
  that never arrive. Failing modules: integration (15), http_gun (10),
  pool (7), recording (5), google (4), session (4), external_provider (3).
  No test needs a real API key or a public provider. The fix belongs in LLM
  Wire's test and example policies (permit loopback); the README's
  `http_config.default()` examples now reject the documented loopback path too.
- Open items (`DESIGN-COVERAGE.md`, `CHANGELOG.md`): retry policy, embeddings,
  realtime, batch/background, remote cancellation ack deferred; Anthropic
  thinking, audio/video, full ReqLLM suite, fuzz/soak/leak, multi-OTP and
  release audit open. Path dependencies block hosted CI. No `TODO`/`FIXME`.
- Downstream break: Fabric still calls `session.run(prepared)`
  (`fabric/src/fabric/llm.gleam:58`); the current signature is
  `session.run(client, prepared)`, so Fabric does not type-check against this head.

## Purpose and scope delivered vs design

LLM Wire prepares one provider request purely, executes it over an
application-owned `http_gun.Client`, and normalizes the SSE response into a
buffered outcome or an owned semantic stream. It ships OpenAI Responses,
Anthropic Messages and Google GenerateContent adapters, a public custom-adapter
seam, Blueprint-admitted tool declarations and structured output, typed retry
evidence plus a pure retry assessment, bounded limits and three deadlines, and
fixed Sinal lifecycle observations. Conversation history, tool execution,
retry scheduling and persistence are the caller's (accepted 2026-09-29;
`docs/caller-owned-conversation.md`). Google is implemented, not missing.

Larger design capabilities still missing (`llm-design.md` line refs):

- Tool-argument progress events (`:106`); `StreamProgress` has only text,
  refusal, reasoning, extension and usage deltas (`types.gleam:529-535`).
- Request tool mode (sequential/parallel, tool choice) (`:40`); provider-hosted
  tools (`:43`); typed adapter-owned extension events (`:44`, today
  `ProviderExtension(String, String)`); model capability metadata (`:45`).
- Distinct rate-limit and unsupported-capability errors (`:150`); partial vs
  final usage (`:154`); audio, background responses, stream resumption,
  Anthropic thinking and cache breakpoints.
- Persistable turn envelope (`:100`) is reassigned to the caller, yet no public
  codec exists (see Composition seams).

## Public modules

| Module                        | Responsibility                                                                                                                          |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `llm_wire/config`             | Opaque `Config`: built-in provider constructors, `from_provider`, endpoint, limits, deadlines, tool-call checks                         |
| `llm_wire/provider/openai`    | Opaque OpenAI `Options` (key, organization, project)                                                                                    |
| `llm_wire/provider/anthropic` | Opaque Anthropic `Options` (key, version)                                                                                               |
| `llm_wire/provider/google`    | Opaque Google `Options` (key, API version)                                                                                              |
| `llm_wire/types`              | Request/message/content values, ids, `ToolDefinition`, `AssistantTurn`, limits, deadlines, `WireError`, retry evidence, stream progress |
| `llm_wire/session`            | `prepare`/`run`/`stream`/`next`/`collect`/`close` and their `_structured` twins; outcome and terminal types                             |
| `llm_wire/provider`           | Custom-adapter seam: `Spec`, `Reducer`, `Event`, `Terminal`, `blueprint_schema`                                                         |
| `llm_wire/retry`              | Pure `assess(provider, error) -> RetryProspect`                                                                                         |
| `llm_wire/telemetry`          | Sinal event `[:llm_wire, :observation]` with `Metadata(stage, provider, outcome)`                                                       |
| `llm_wire/testing`            | Scripted provider `config()`, semantic `Reply` builders, lowering to `http_gun/fixture.Exchange`                                        |

## Common path

```gleam
let assert Ok(client) = http_gun.start(http_config.Config(..http_config.default(), deadline_ms: 120_000))
let assert Ok(key) = types.api_key("sk-...")
let assert Ok(model) = types.model_id("gpt-...")
let settings = config.openai(openai.options(key))
let assert Ok(name) = types.tool_name("lookup")
let assert Ok(tool) = types.tool_from_codec(name, "Look up", codec.field("q", codec.string()))
let request = types.new_request(model, [types.UserMessage("Find X")]) |> types.with_tools([tool])
// Stream deltas (session.run(client, prepared) is the buffered form).
let assert Ok(prepared) = session.prepare(settings, request)
let assert Ok(stream) = session.stream(client, prepared)
case session.next(stream) {   // loop until StreamTerminal
  Ok(session.NextProgress(types.TextDelta(_, text))) -> io.print(text)
  Ok(session.StreamTerminal(session.Finished(session.RunToolCalls(turn, _)))) -> {
    let results = list.map(turn.calls, fn(c) { types.ToolResultMessage(c.id, "X is 42") })
    let next = types.Request(..request, messages: list.flatten([request.messages, [types.AssistantTurnMessage(turn)], results]))
    // Continue with structured output for the final answer.
    let assert Ok(p2) = session.prepare_structured(settings, next, "answer", codec.field("answer", codec.int()))
    let assert Ok(session.StructuredValue(answer, _raw, _usage)) = session.run_structured(client, p2)
    io.println(int.to_string(answer))
  }
  _ -> { let _ = session.close(stream) Nil }
}
```

## Configuration and advanced paths

- **Provider options** are opaque value-first builders per provider
  (`openai.options(key) |> openai.with_project(..)`), then `config.openai(opts)`.
- **Limits/deadlines**: public records with defaults
  (`types.default_limits()`, 14 byte/count fields; `types.default_deadlines()`:
  overall 60 s, idle 15 s, read 5 s), attached with `config.with_limits` /
  `with_deadlines`; validated in `session.prepare`, before any I/O.
  `read_timeout_ms` is the `session.next` poll timeout, fixed per config.
- **Tool-call checks**: `config.with_tool_call_checks(types.ReportInvalidToolCalls)`
  keeps invalid calls in `turn.calls` and reports `turn.issues` instead of failing.
- **Custom providers**: `provider.adapter(provider.Spec(identity, endpoint,
headers, encode, project_tool_schema, project_output_schema, new_reducer))`
  then `config.from_provider`. `provider.reducer(state, step, terminal, retry)`
  hides reducer state in closures so no type parameter leaks into `Config` or
  `Stream`. `provider.ToolCalls(.., provider_data: Option(String), ..)` carries
  adapter-owned replay data back through `AssistantTurnMessage`. There is no
  `provider.Replay` anymore (removed with continuations; the design text at
  llm-design.md:21 is stale). Tested by `test/external_provider.gleam`.
- **Endpoint override**: `config.with_endpoint(config, types.endpoint(..))`.
- **Prompt cache**: `types.with_prompt_cache(OpenAiPromptCacheKey | GoogleCachedContent)`.
- **HTTP client injection**: every execution function takes `http_gun.Client`;
  trust (`http_config.CustomCa`), protocol, pool, client deadline ceiling and
  (now) destination policy are HTTP Gun startup settings.
- **Testing**: `testing.config()` (scripted provider) plus
  `testing.text/tool_calls/refusal/output_limited/with_usage`,
  `testing.exchange(prepared, reply)` → `http_gun/testing.start(policy, exchanges)`.
  Built-in providers use `testing.Events(sse_chunks)` / `Interrupted` / `Status`.
- **Cassettes**: owned entirely by HTTP Gun (`cassette.load`, `cassette.playback`,
  `cassette.record`, `recording.finish_wait`); LLM Wire supplies no cassette code.

## Lifecycle and supervision

- `prepare*` is pure; it starts nothing and spends no deadline.
- Each `stream`/`run` starts a per-call semantic owner process (actor in
  `internal/owner.gleam`) that monitors the creating process and links the
  HTTP worker. Copied `Stream` handles share one cursor; conflicting reads
  return `ConcurrentReadConflict`. Consumer death closes HTTP. `close` is
  idempotent; it reports `ConsumerClosed`/`AlreadyTerminal` and never claims
  provider cancellation.
- No library supervisor or hidden pool. The caller starts and owns one shared
  `http_gun.Client` (`http_gun.start` or `http_gun.child(policy)` under its own
  supervisor) and stops it at shutdown; client stop unblocks calls with typed
  failures. A restart yields a new client the application must republish.
- The caller must `close` an abandoned stream on early exit; buffered `run`
  consumes to a terminal itself.

## Failure model

- Preparation: `Result(_, types.WireError)` (`ConfigurationError(String)`,
  `PreparationError(String)`, `ResourceLimitExceeded(limit_name: String, limit, measured)`).
- Execution: `session.RunFailure(error: WireError, retry: RetryEvidence)`.
  `RetryEvidence(classification: NoRequestSent | RequestMayHaveReachedProvider |
EffectUnknown, response_bytes_observed, semantic_progress_observed)` tells
  reachability and progress.
- Distinguishing classes from `WireError`: transport — `HttpFailure(http_gun/error.Reason)`
  (typed) or `TransportError(String)` (stream-closed/owner-unavailable only);
  HTTP status — `HttpStatusError(status, body, Option(RetryHint))`; provider —
  `ProviderError(code: Option(String), message)`; limit — `ResourceLimitExceeded`;
  deadline — `DeadlineExceeded(OverallDeadline | IdleDeadline | ReadDeadline)`;
  local close — `CancelledLocally`; protocol/output — `ProtocolError(String)`,
  `OutputValidationError(String)`.
- Retryability: `retry.assess(provider, error)` → `MayHelp | WillNotHelpUnchanged |
Unknown`, using status and exact provider codes; combine with `RetryEvidence`.
  No automatic retry.
- `RunOutputLimited`, `RunRefusal`, `RunToolCalls` are successes, not failures.
- Streams: `session.next` returns `Error(StreamReadError(types.ReadError))` —
  `ReadTimeout` (stream still usable), `StreamClosed`, `ConcurrentReadConflict`,
  `OwnerUnavailable` — or `Error(TerminalConversionError(WireError))`.

## Composition seams

- **json_blueprint (hard dependency, JSON Schema paths).** Tools come from
  `types.tool_from_codec(name, desc, codec.Codec(a))` or
  `types.tool_from_contract(name, desc, runtime.RuntimeContract)`; structured
  output takes `codec.Codec(output)`. A plain JSON Schema document (e.g. an MCP
  `inputSchema`) is possible via `json/blueprint/document.load(value)` →
  `RuntimeContract` → `tool_from_contract`, but there is no tool path without
  importing Blueprint. This is within the guideline (tool schemas are JSON
  Schema paths). Custom adapters also see `codec.Schema` in `provider.Spec`
  and project via `provider.blueprint_schema`.
- **relay (no dependency).** README shows an application adapter:
  `tool.definition_name` / `definition_metadata` / `definition_input_codec` →
  `types.tool_name` + `types.tool_from_codec`. The `ToolNameError` must be
  mapped into a stringly `PreparationError` because `tool_from_codec` returns
  `WireError`. Relay's `input_schema_document` (relay `tool.gleam:796`) would
  serve the `document.load` path for discovered remote tools.
- **http_gun (hard dependency, public types in signatures).** `http_gun.Client`
  on every execution call; `HttpFailure(http_gun/error.Reason)` inside
  `WireError`; `testing` returns `http_gun/fixture.Exchange`. HTTP Gun's new
  default destination policy currently breaks LLM Wire's loopback tests and
  examples (see Health). LLM Wire also keeps its own plaintext rule
  (remote `http://` rejected) on top of HTTP Gun's policy.
- **sinal (hard dependency).** Emits only `[:llm_wire, :observation]`, metadata
  `Metadata(stage: String, provider: String, outcome: String)`, measurements
  empty; stages `prepared`, `request_sent`, `first_progress`, `terminal`,
  `cancelled`, `deadline`, `cleanup`. No content, no durations, no token counts.
  HTTP Gun observations are separate and opt-in via the HTTP policy.
- **fabric (consumer).** `fabric/src/fabric/llm.gleam` builds tools through
  `runtime.from_schema` + `tool_from_contract`, forces `ReportInvalidToolCalls`,
  maps `RunFailure` via `retry.assess`, and hand-rolls a persistence envelope
  `"llm_wire.turn.v1"` for `AssistantTurn` (`llm.gleam:202-300`). It still
  uses the pre-HTTP-Gun `session.run(prepared)` and must be migrated.
- **Persistence (grind/saga).** `Message`, `AssistantTurn`, `ToolCall`, `Request`
  fields are public records and ids round-trip through `*_to_string`, so a
  caller can write a codec, but LLM Wire ships no `to_json`/decoder for any of
  them. `provider_data` is an opaque adapter string that must be stored
  verbatim. `ToolDefinition` holds a decode closure and cannot be persisted;
  it must be rebuilt from codecs on resume. Every durable consumer will
  duplicate Fabric's envelope.
- **Independence.** Coupling to Blueprint, Sinal and HTTP Gun is justified by
  owned decisions. The tightest avoidable coupling is `testing` and
  `session.fixture_exchange` exposing `http_gun/fixture` types, and
  `WireError` embedding `http_gun/error.Reason` (acceptable typed detail).
  No dependency on fabric, saga, grind or relay.

## Ergonomics concerns

1. **Two parallel execution families.** `session.gleam:19-48` (`RunResult`,
   `ReadResult`, `Terminal`, `Stream`) are duplicated as `StructuredRunResult`,
   `StructuredReadResult`, `StructuredTerminal`, `StructuredStream`
   (`session.gleam:183-210`) with `run/stream/collect/next/close` repeated as
   `*_structured` (`:229-328`). Text is the `String` case of a structured
   result; one family parameterized by an output decoder would halve the
   surface (guideline: one ordinary path, no overlapping families).
2. **Retry assessment asks for a fact the library owns.** `retry.assess(provider,
error)` (`retry.gleam:29-32`) requires the provider, but `RunFailure`
   (`session.gleam:52-54`) omits it, so callers must keep the `PreparedCall`
   and call `session.prepared_provider` (Fabric does exactly this,
   `fabric/src/fabric/llm.gleam:68`). Carry provider in `RunFailure` or
   precompute the prospect.
3. **Stringly errors where callers branch.** `ConfigurationError`,
   `PreparationError`, `ProtocolError`, `TransportError`,
   `OutputValidationError` all carry `String` (`types.gleam:560-577`);
   `ResourceLimitExceeded.limit_name` is a `String` naming a `Limits` field
   (`types.gleam:569-573`); `ToolCallIssue.InvalidArguments.reason` is a string
   built with `string.inspect` (`types.gleam:463`, `:414`). Rate limit and
   unsupported capability (design :150) have no alternative. `tool_from_codec`
   returns `PreparationError("Codec has no schema")` (`types.gleam:336`) while
   `tool_name` has a typed error, forcing the string mapping in the README's
   Relay adapter.
4. **Overlapping message constructors and a dead public type.**
   `AssistantToolCalls`, `AssistantToolCallsWithText`, `AssistantMessage`,
   `AssistantContent` and `AssistantTurnMessage` all express an assistant turn
   (`types.gleam:288-298`). `types.ToolResult` (`types.gleam:466-468`) is public
   but no public function takes it; callers use `ToolResultMessage`.
5. **Two `ReadError` types, inconsistent returns.** `types.ReadError`
   (`types.gleam:585`) and `session.ReadError` (`session.gleam:34`); `next`
   returns the session one, `close` returns the types one (`session.gleam:163`).
6. **Telemetry loses its own enum.** `telemetry.Stage` is public
   (`telemetry.gleam:7-15`) but subscribers receive `Metadata(stage: String,
provider: String, outcome: String)` (`:17-19`); the only producer is
   `@internal`. Siblings grind, saga, warden and fabric name this module
   `observation`; llm_wire, http_gun and relay use `telemetry`.
7. **Constructor errors are miscategorized.** `types.call_id("")` returns
   `ProtocolError` for application-authored ids (`types.gleam:31-37`);
   `types.endpoint` admits any `http://` URL (`:131-141`) that execution later
   rejects for non-loopback hosts.
