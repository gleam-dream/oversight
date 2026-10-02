# llm_wire: release API review

Reviewed 2 October 2026 against `/code/gleam-dream/llm_wire` (llm_wire 56d793d,
after the fix round), the [LLM design](../../llm-design.md), the
[API card](../composition/scan/llm_wire.md), the
[composition feedback](../composition/FEEDBACK.md) and app findings EXT-2,
EXT-3, EXT-4, EXT-7, SD-3, SD-4, SD-7, TH-7 and RA-7. A scratch consumer
(`scratchpad/llm_probe`, public imports only) confirmed that today's program
below compiles and reproduced the two defects marked "probe".

## 1. Verdict

The runtime model is sound (pure preparation, a caller-owned HTTP client, owned
streams and typed retry evidence), but llm_wire is not release-ready as an API,
because its stream defaults fail ordinary calls: an OpenAI reply over 16 KiB
fails on the SSE line limit (probe), the first visible token must arrive within
the 15 s idle window, and the 60 s whole-call budget is silently cut to
http_gun's 30 s. The largest API problems are the duplicated plain and
`_structured` execution families, string failure details where callers branch,
retry advice that needs a provider the failure omits, and no conversation codecs
or correlation in events. The common path spans four of ten modules and needs
four `let assert`s; the proposal reaches it with two llm_wire imports and two
asserts while keeping every capability.

## 2. First ten minutes

Main job: send one prompt and print the answer. Today (compiles; without the
record update, http_gun's 30 s default caps the LLM budget, and there is no
describe function, so Fabric also uses `string.inspect`, fabric/llm.gleam:200):

```gleam
import gleam/io
import gleam/string
import http_gun
import http_gun/config as http_config
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/types

pub fn main() -> Nil {
  let assert Ok(client) =
    http_gun.start(http_config.Config(..http_config.default(), deadline_ms: 120_000))
  let assert Ok(key) = types.api_key("sk-...")
  let assert Ok(model) = types.model_id("gpt-5")
  let settings = config.openai(openai.options(key))
  let request = types.new_request(model, [types.UserMessage("Hello")])
  let assert Ok(prepared) = session.prepare(settings, request)
  case session.run(client, prepared) {
    Ok(session.RunText(text, _)) -> io.println(text)
    Ok(other) -> io.println(string.inspect(other))
    Error(session.RunFailure(error, _)) -> io.println(string.inspect(error))
  }
  let _ = http_gun.stop(client)
  Nil
}
```

Proposed:

```gleam
import gleam/io
import http_gun
import http_gun/config as http_config
import llm_wire
import llm_wire/openai

pub fn main() -> Nil {
  let assert Ok(client) = http_gun.start(http_config.default())
  let config = openai.new("sk-...") |> openai.config
  let request = llm_wire.request("gpt-5", [llm_wire.user("Hello")])
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  case llm_wire.run(client, prepared) {
    Ok(llm_wire.Answer(text:, ..)) -> io.println(text)
    Ok(_) -> io.println("no final answer")
    Error(failure) -> io.println(llm_wire.describe_failure(failure))
  }
  let _ = http_gun.stop(client)
  Nil
}
```

Structured output today switches to `prepare_structured`/`run_structured` and a
second result family; proposed, the request gains
`|> llm_wire.with_output("invoice", codec)` and nothing else changes.

| Measure            | Today                                                                                                                  | Proposed                                                 |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| llm_wire imports   | 4 (`config`, `provider/openai`, `session`, `types`)                                                                    | 2 (`llm_wire`, `llm_wire/openai`)                        |
| Non-stdlib imports | 6                                                                                                                      | 4                                                        |
| Calls              | 11 (incl. `string.inspect`)                                                                                            | 10                                                       |
| `let assert`       | 4 (client, key, model, prepared)                                                                                       | 2 (client, prepared)                                     |
| llm_wire types met | 11 (ApiKey, ModelId, Options, Config, Request, Message, PreparedCall, RunResult, RunFailure, WireError, RetryEvidence) | 6 (Config, Request, Message, Prepared, Outcome, Failure) |
| Hidden trap        | http_gun client deadline caps the LLM budget                                                                           | none (R1)                                                |
| Structured variant | +2 functions, +4 types                                                                                                 | +1 call                                                  |

## 3. Target surface

| Module               | Key types                                                                                                                                                                                                                                                                                                                                                                                                                                           | Key functions                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `llm_wire`           | opaque `Config`, `Request(o)`, `Prepared(o)`, `Stream(o)`; `Message`, `Content`, `AssistantTurn`, `ToolCall`, `Outcome(o)`, `Event(o)`, `Progress`, `Usage`, `Failure`, `Error`, `PrepareError`, `ValueFailure`, `Sent`, `RetryAdvice`, `RetryProspect`, `Limit`, `Timeout`, `ReadError`, `CloseOutcome`, `PromptCache`, `Provider`, `ToolCallChecks`, `PrepareError` detail enums (`Setting`, `RequestProblem`, `SchemaLocation`, `ResultProblem`) | `with_endpoint`, `with_limit`, `with_timeout`, `with_tool_call_checks`; `request`, `with_tools`, `with_max_tokens`, `with_temperature`, `with_top_p`, `with_stop_sequences`, `with_prompt_cache`, `with_output`, `messages`, `append`; `user`, `assistant`, `tool_result`; `prepare`, `run`, `stream`, `next`, `next_within`, `collect`, `close`, `request_json`; `advise`, `describe_failure`, `describe_prepare_error`; `message_to_json`, `message_decoder`, `turn_to_json`, `turn_decoder` |
| `llm_wire/tool`      | opaque `Tool`; `ToolError`, `ToolCallIssue`                                                                                                                                                                                                                                                                                                                                                                                                         | `new`, `from_contract`, `from_json_schema`, `name`, `decode_arguments`, `describe_issue`                                                                                                                                                                                                                                                                                                                                                                                                       |
| `llm_wire/openai`    | opaque `Options`                                                                                                                                                                                                                                                                                                                                                                                                                                    | `new`, `with_organization`, `with_project`, `config`                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `llm_wire/anthropic` | opaque `Options`                                                                                                                                                                                                                                                                                                                                                                                                                                    | `new`, `with_version`, `config`                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `llm_wire/google`    | opaque `Options`                                                                                                                                                                                                                                                                                                                                                                                                                                    | `new`, `with_api_version`, `config`                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `llm_wire/provider`  | opaque `Adapter`, `Reducer`; `SseEvent`, `EncodedRequest`, `OutputFormat`, `ProjectedTool`, `Terminal`                                                                                                                                                                                                                                                                                                                                              | `new`, `with_headers`, `with_tool_schema`, `with_output_schema`, `reducer`, `blueprint_schema`, `config`                                                                                                                                                                                                                                                                                                                                                                                       |
| `llm_wire/telemetry` | `Metadata`, `Stage`, `Outcome`                                                                                                                                                                                                                                                                                                                                                                                                                      | `event`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `llm_wire/testing`   | `Reply`, `ScriptedCall`                                                                                                                                                                                                                                                                                                                                                                                                                             | `config`, `text`, `tool_calls`, `refusal`, `output_limited`, `with_usage`, `exchange`, `events_for`                                                                                                                                                                                                                                                                                                                                                                                            |

Current modules: `config`, `types`, `session` and `retry` merge into `llm_wire`
(tool declarations go to `llm_wire/tool`); `provider/openai|anthropic|google`
move to `llm_wire/openai` etc. and return a `Config`; `provider` stays as the
extension seam with its 11 runtime accessors (`identity` … `retry_evidence`,
provider.gleam:108-175) made `@internal`; `telemetry` and `testing` stay. Shared
types live in an internal module and are aliased, since Gleam forbids the
`llm_wire` ↔ `llm_wire/tool` import cycle.

| Count               | Before | After |
| ------------------- | -----: | ----: |
| Public modules      |     10 |     8 |
| Public functions    |     79 |    64 |
| Public records      |     16 |    11 |
| Public unions       |     25 |    28 |
| Opaque types        |     16 |    10 |
| `_structured` twins |      7 |     0 |
| `ReadError` types   |      2 |     1 |

Removed: 7 twins, 11 runtime accessors, 9 id/string helpers, 2 default-record
constructors, `prepared_provider`. Unions grow by 3 because string details
become typed (`Limit`, `ValueFailure`, the `PrepareError` problem enums).

## 4. Proposals

Ranked by user impact. "Breaks" means existing callers must change.

### LLM-R1 Stream defaults must not fail ordinary calls (breaks: yes; M)

- **SSE line limit (probe).** `line_bytes_limit` is 16 KiB (types.gleam:177) and
  applies to every line (sse.gleam:59, :116, :129). OpenAI's
  `response.output_text.done`, `response.output_item.done` and
  `response.completed` carry the full text on one `data:` line. The probe streams
  20,000 bytes in 200-byte deltas and fails with
  `ResourceLimitExceeded("line_bytes_limit", 16384, 19069)`; 8,000 bytes succeed.
  Tool arguments (1 MiB allowed) also arrive whole in
  `function_call_arguments.done`.
- **Idle doubles as a first-token deadline.** The idle timer starts with the
  owner (owner.gleam:173-181), before admission, connection and headers, and
  restarts only on text, refusal, reasoning or usage progress
  (owner.gleam:671-676, :1235-1243). Requests never ask OpenAI for reasoning
  summaries, the only reasoning event decoded (openai.gleam:128), so a reasoning
  model gets 15 s to its first visible token.
- **Tool arguments are not progress.** Argument deltas emit nothing
  (openai.gleam:733-743; Anthropic `input_json_delta` likewise), so a long tool
  call fails with `DeadlineExceeded(IdleDeadline)` while bytes flow. The design
  requires tool-argument progress (llm-design.md:106).
- **Whole-call budget silently capped.** 60 s, but http_gun applies the earlier
  of the request deadline and its 30 s client default (http_gun
  config.gleam:56), reported as the same `DeadlineExceeded(OverallDeadline)`
  (http_client.gleam:313). README.md:35 and extractor (clients.gleam:57) raise
  the client deadline by hand.
- **Read timeout is a poll, not a deadline.** `collect` loops on `ReadTimeout`
  (session.gleam:101); `ReadDeadline` is produced only by unreachable code
  (session.gleam:124).

```gleam
pub type Timeout { WholeCall  FirstToken  IdleGap }
pub fn with_timeout(config: Config, timeout: Timeout, ms: Int) -> Config
pub fn next(stream: Stream(o)) -> Result(Event(o), ReadError)       // bounded by FirstToken/IdleGap/WholeCall
pub fn next_within(stream: Stream(o), ms: Int) -> Result(Event(o), ReadError)  // TimedOut keeps the stream
pub type Progress { TextDelta(..)  ReasoningDelta(..)  RefusalDelta(..)
                    ToolArgumentsDelta(call_id: String, text: String)  UsageUpdate(..)  ProviderExtension(..) }
```

Defaults: WholeCall 600 s (the OpenAI and Anthropic SDK default), FirstToken
180 s from execution start to the first semantic event (covers admission,
response head and hidden reasoning), IdleGap 60 s between semantic events,
tool-argument deltas included. Line limit equals the event limit (1 MiB). Ask
http_gun to let an explicit request deadline replace, not be capped by, the
client default (open question 2).

### LLM-R2 One execution family, parameterized by output (breaks: yes; M)

`RunResult`, `ReadResult`, `Terminal` and `Stream` (session.gleam:19-48) are
duplicated as `Structured*` (:183-210), and `run`, `stream`, `next`, `collect`,
`close`, `request_json` and `exchange` each have a twin (session.gleam:212-334,
testing.gleam:336). The twins already drift: `prepared_provider` exists only for
the plain family, so extractor reads the provider from config internals
(extractor/llm.gleam:146, EXT-2). `TerminalConversionError` reports a completed
response as a read error (session.gleam:34-37), and `next` and `close` return
different `ReadError` types (session.gleam:163, types.gleam:585).

```gleam
pub fn request(model: String, messages: List(Message)) -> Request(String)
pub fn with_output(request: Request(a), name: String, codec: codec.Codec(o)) -> Request(o)
pub fn prepare(config: Config, request: Request(o)) -> Result(Prepared(o), PrepareError)
pub fn run(client: http_gun.Client, prepared: Prepared(o)) -> Result(Outcome(o), Failure)
pub fn stream(client: http_gun.Client, prepared: Prepared(o)) -> Result(Stream(o), Failure)
pub type Outcome(o) {
  Answer(output: o, text: String, usage: Option(Usage))
  NeedsTools(turn: AssistantTurn, usage: Option(Usage))
  OutputLimited(partial_text: String, partial_calls: List(ToolCall), usage: Option(Usage))
  Refused(reason: String, usage: Option(Usage))
}
pub type Event(o) { Progress(Progress)  Done(Result(Outcome(o), Failure)) }
pub type ReadError { Closed  ConcurrentRead  OwnerGone  TimedOut }
pub fn close(stream: Stream(o)) -> CloseOutcome                     // Closed | AlreadyFinished
```

`ProviderCancellationConfirmed` is never produced (types.gleam:594); drop it
until remote cancellation exists. Adapters see an untyped request view, so
`provider.Spec` gains no type parameter.

### LLM-R3 Retry advice from the failure alone (breaks: yes; S–M)

`retry.assess(provider, error)` (retry.gleam:29) needs the provider that
`RunFailure` omits (session.gleam:52); Fabric keeps the prepared call only to
recover it (fabric/llm.gleam:76, :177). It returns `Unknown` for every
`HttpFailure` (retry.gleam:39) although http_gun's `Reason` is typed, gives no
delay with `MayHelp`, and leaves an HTTP-date `Retry-After` as a string
(types.gleam:579-583). Extractor's mapping is 78 lines (outcome.gleam:52-138,
EXT-2).

```gleam
// before
pub type RunFailure { RunFailure(error: WireError, retry: RetryEvidence) }
pub fn assess(provider: Provider, error: WireError) -> RetryProspect
// after
pub type Failure {
  Failure(error: Error, sent: Sent, partial_output: Bool, provider: Provider, usage: Option(Usage))
}
pub type Sent { NotSent  MaybeSent  Completed }                     // theme 3
pub type RetryAdvice { RetryAdvice(prospect: RetryProspect, after_ms: Option(Int)) }
pub fn advise(failure: Failure) -> RetryAdvice
```

Connection, request, admission and deadline reasons are `MayHelp`;
`DestinationRejected`, `InvalidRequest`, `CertificateRejected` and limits are
`WillNotHelpUnchanged`. The runtime converts an HTTP-date to milliseconds on
receipt, when it has a clock. `MaybeSent` absorbs `response_bytes_observed`
(either way the provider may have acted). Usage on failure keeps token
accounting for late failures.

### LLM-R4 Typed failure detail (breaks: yes; M)

Callers branch on `ResourceLimitExceeded(limit_name: String, ..)`
(types.gleam:569), `InvalidArguments(reason: String)` built with
`string.inspect` (types.gleam:414, :463) and `OutputValidationError(String)`,
which also drops the raw output and reports `EffectUnknown` for a completed
response (schema.gleam:317-330, session.gleam:106-110; EXT-3). Preparation
returns the full `WireError`, whose network variants cannot occur there, hiding
45 `PreparationError` and 15 `ConfigurationError` strings; the design asks it to
distinguish invalid input and invalid, unavailable or unsupported schemas
(llm-design.md:51). `call_id("")` reports a `ProtocolError` for a local value
(types.gleam:31-37), and a failed HTTP worker start a `ConfigurationError`
(http_client.gleam:134).

```gleam
pub type Limit { RequestBytes  EventBytes  ChunkBytes  QueueCount  QueueBytes  TotalTextBytes  ... }  // one per Limits field
pub type ValueFailure { InvalidJson  SchemaRejected(runtime.ValidationError)  DecodeRejected(codec.DecodeError) }
pub type Error {
  Http(http_error.Reason)
  Status(code: Int, body: String, retry_after_ms: Option(Int))
  Provider(code: Option(String), message: String)
  Protocol(detail: String)                                         // diagnostic only
  LimitExceeded(limit: Limit, limit_value: Int, measured: Int)
  DeadlineExceeded(Timeout)
  Cancelled
  InvalidOutput(raw_output: String, failure: ValueFailure)
}
pub type PrepareError {
  InvalidSetting(setting: Setting, reason: String)                 // key, model, endpoint, header
  InvalidRequest(problem: RequestProblem)                          // max_tokens, top_p, cache name …
  UnsupportedSchema(location: SchemaLocation, reason: String)
  ToolResultMismatch(call_id: String, problem: ResultProblem)      // missing | duplicate | unknown | orphan
  RequestTooLarge(limit_value: Int, measured: Int)
}
pub fn describe_failure(failure: Failure) -> String
pub fn describe_prepare_error(error: PrepareError) -> String
// llm_wire/tool
pub type ToolCallIssue { UnknownTool(call_id: String)  InvalidArguments(call_id: String, failure: ValueFailure) }
pub fn describe_issue(issue: ToolCallIssue) -> String              // text for the model's error result
```

Document `Error` and `Progress` as growing: rate-limit and
unsupported-capability errors are design scope (llm-design.md:150).

### LLM-R5 Callers construct only opaque values (breaks: yes; M)

`Request` is a public 8-field record (types.gleam:475) that README.md:121
updates by hand, and the design adds tool mode, tool choice, native options and
reasoning controls (llm-design.md:40-41). `Limits` (14 fields) and `Deadlines`
(types.gleam:155, :223) break positional builders when a field is added, the
failure the fix round hit across packages; every custom adapter constructs the
7-field `provider.Spec` (provider.gleam:15-28). `api_key`, `model_id` and
`endpoint` each cost a `let assert`. **Secret leak (probe):** `string.inspect`
of a `Config` or `ApiKey` prints the key, because the adapter stores a finished
auth header (api.gleam:505-523), and public `provider.headers`
(provider.gleam:116) returns it.

```gleam
pub fn messages(request: Request(o)) -> List(Message)
pub fn append(request: Request(o), messages: List(Message)) -> Request(o)
pub fn with_limit(config: Config, limit: Limit, value: Int) -> Config
// llm_wire/openai
pub fn new(api_key: String) -> Options
pub fn config(options: Options) -> Config
// llm_wire/provider
pub fn new(name: String, endpoint: String, encode: Encode, reducer: NewReducer) -> Adapter
pub fn with_headers(adapter: Adapter, headers: List(#(String, String))) -> Adapter
```

Key, model and endpoint are validated by `prepare` (`InvalidSetting`). Secrets
live in a redacting wrapper or closure, absent from inspect output and crash
reports. One enum-keyed `with_limit` replaces 14 fields, and `LimitExceeded`
reports the same `Limit`.

### LLM-R6 One root module and one assistant message (breaks: yes; M)

The common path spans `config`, `types` and `session` (`retry` for failures);
only `retry` and `testing` have a module doc. Five variants express one
assistant turn (`AssistantMessage`, `AssistantContent`, `AssistantToolCalls`,
`AssistantToolCallsWithText`, `AssistantTurnMessage`; types.gleam:288-298).
`types.ToolResult` is public but taken by no public function (types.gleam:466).
Names collide: `Terminal` (session, provider), `ReadError` (session, types),
`Cancelled` (session terminal, telemetry stage).

```gleam
pub type Message {
  System(text: String)
  User(parts: List(Content))
  Assistant(turn: AssistantTurn)
  ToolResult(call_id: String, content: String)
}
pub fn user(text: String) -> Message
pub fn assistant(text: String) -> Message          // AssistantTurn without provider data
pub fn tool_result(call: ToolCall, content: String) -> Message
```

Add `////` docs to every public module; rename `provider.Event` to `SseEvent`.

### LLM-R7 Public conversation codecs (breaks: no; M)

The design gives persistence to the caller (llm-design.md:3-5, :100), yet
`Message`, `AssistantTurn` and `ToolCall` have no serialized form. Fabric keeps
a private 120-line `"llm_wire.turn.v1"` envelope (fabric/llm.gleam:210-324);
every other durable consumer must write its own (research_agent, theme 6).

```gleam
pub fn message_to_json(message: Message) -> json.Json
pub fn message_decoder() -> decode.Decoder(Message)
pub fn turn_to_json(turn: AssistantTurn) -> json.Json
pub fn turn_decoder() -> decode.Decoder(AssistantTurn)
```

Values carry a format tag (`llm_wire.message.v1`); `provider_data` is stored
verbatim; unknown tags fail to decode. `Tool` holds a decode closure and stays
unpersisted.

### LLM-R8 Correlation and typed telemetry metadata (breaks: yes; S, plus http_gun)

`Metadata(stage: String, provider: String, outcome: String)`
(telemetry.gleam:17-19) has no call or correlation id: 23 extractor, 100
support_desk, 17 tool_hub and 15 research_agent events were unattributable
(EXT-4, SD-3, TH-7, RA-7). `Stage` is public but arrives as a string, and the
descriptor is named `observation_event()`.

```gleam
pub type Metadata {
  Metadata(call: String, correlation: Option(String), stage: Stage, provider: String, outcome: Outcome)
}
pub fn event() -> sinal.Event(Nil, Metadata)
```

`call` is minted per execution; `correlation` comes from the `http_gun.Client`
view passed to `run`/`stream`, which needs an `http_gun.correlation(client)`
accessor and a string form (theme 1).

### LLM-R9 Tool declarations without Blueprint ceremony (breaks: partly; S)

A codec tool takes two Results with different error types (`types.tool_name`,
then `tool_from_codec` returning `WireError`), so the README's Relay adapter
maps a typed error into a `PreparationError` string (README.md:398-401). A JSON
Schema tool (an MCP `inputSchema`) needs three Blueprint calls (`document.load`,
`runtime.from_schema`, `tool_from_contract`). The validated arguments are
discarded (types.gleam:324-333), so callers decode `arguments_json` again.

```gleam
pub fn new(name: String, description: String, input: codec.Codec(a)) -> Result(Tool, ToolError)
pub fn from_json_schema(name: String, description: String, schema: json.Json) -> Result(Tool, ToolError)
pub fn decode_arguments(call: ToolCall, input: codec.Codec(a)) -> Result(a, ValueFailure)  // runtime bounds
pub type ToolError { InvalidName(ToolNameError)  SchemaUnavailable  SchemaRejected(String) }
```

json_blueprint stays a package dependency (the schema engine), but neither the
plain path nor the JSON Schema tool path imports it.

### LLM-R10 Plaintext policy belongs to the destination decision (breaks: no; S, cross-package)

llm_wire admits `http://` only for the host strings `localhost` and `127.0.0.1`
(api.gleam:1472), on top of http_gun's resolved-address policy. A second check
also admits `::1` (api.gleam:160), and neither parses `[::1]:port`.
`types.endpoint` accepts any `http://` URL (types.gleam:131-141) and rejection
comes later. A plain-HTTP model server on a private network is refused even when
the client allows private destinations (EXT-7, theme 10). Delete the host-string
checks and ask http_gun for a fail-closed plaintext rule (plain HTTP only to
loopback or private addresses the policy admits) that every secret-sending
package inherits; until then, use http_gun's address classification.

### LLM-R11 Test fakes for each built-in wire (breaks: no; M)

`testing` lowers semantic replies only into its own scripted wire
(testing.gleam:63-90), so apps and Fabric hand-write about 100 lines of OpenAI
SSE (SD-7). Add `events_for(provider: Provider, reply: Reply) -> Reply` for the
three wires. After R2, `exchange` covers every `Prepared(o)`, so
`structured_exchange` goes; `http_reply` becomes `@internal`.

## 5. Defaults table

| Operation                                     | Current default                                                                                                                                                                   | Proposed default                                                        |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Whole call (admission to terminal)            | 60 s, capped by http_gun's 30 s client default, so 30 s in effect, same error                                                                                                     | 600 s (`WholeCall`); not capped by the client default                   |
| Connect                                       | 5 s (http_gun `connect_ms`)                                                                                                                                                       | Keep (http_gun)                                                         |
| Pool admission wait                           | 128 waiting slots, spends the whole-call budget (http_gun)                                                                                                                        | Keep                                                                    |
| First byte (response head)                    | No own timer; bounded by the 15 s idle timer, which starts before admission                                                                                                       | Covered by `FirstToken`                                                 |
| First semantic event                          | 15 s (same idle timer); hidden reasoning, pings and tool arguments do not count                                                                                                   | 180 s (`FirstToken`)                                                    |
| Idle gap between events                       | 15 s; tool-argument deltas, pings and extensions do not reset it                                                                                                                  | 60 s (`IdleGap`); tool-argument deltas reset it                         |
| `next` wait                                   | 5 s per call (`read_timeout_ms`) then `ReadTimeout`; `run` loops                                                                                                                  | Until an event, bounded by the timers above; `next_within(ms)` explicit |
| Owner start / worker hand-off / `close` reply | 5 s (owner.gleam:161) / 1 s (http_client.gleam:127, reported as `ConfigurationError`) / 5 s (owner.gleam:320)                                                                     | Keep; typed internal failure with `NotSent`                             |
| SSE line                                      | 16 KiB; fails OpenAI replies over about 16 KB (probe)                                                                                                                             | Equal to the event limit (1 MiB)                                        |
| Stream bounds                                 | Event 1 MiB, chunk 64 KiB, queue 500 items / 2 MiB, active blocks 64                                                                                                              | Keep                                                                    |
| Content bounds                                | Request 1 MiB; text 1 MiB per block / 4 MiB; tool arguments 1 MiB per call / 4 MiB (unreachable above 16 KiB until the line fix); provider metadata 1 MiB; extension event 16 KiB | Keep                                                                    |
| Non-200 body                                  | min(64 KiB, `response_body_bytes_limit` 8 MiB)                                                                                                                                    | Keep; document                                                          |
| Output and argument JSON parse                | Text or argument byte bound plus Blueprint depth and number bounds                                                                                                                | Keep                                                                    |
| Automatic retries / tool rounds               | None; advice only / caller-owned loop                                                                                                                                             | Keep; `advise` adds `after_ms`                                          |
| TLS / destinations                            | System trust with hostname check; public destinations only (http_gun)                                                                                                             | Keep                                                                    |
| Plaintext                                     | Loopback host-string checks (two inconsistent lists)                                                                                                                              | http_gun policy: loopback or private only (R10)                         |
| Secrets                                       | API key visible to `string.inspect` and `provider.headers` (probe)                                                                                                                | Redacted (R5)                                                           |

Nothing is unbounded today: validation rejects zero and negative values
(types.gleam:194-246). Defaults are scattered through README prose
(README.md:59-64, :253-259) and two `default_*` functions; the README needs this
one table.

## 6. Convention feedback

1. **Opaque config** fits, but 14 `with_<limit>` setters are noise: allow an
   enum-keyed setter (`with_limit(config, Limit, Int)`) when the error reports
   the same key.
2. **Returned records** stay safe only with shipped codecs, because callers
   rebuild `AssistantTurn` from storage (R7).
3. **`kind`** would duplicate `Error`'s already coarse variants. Callers decide
   on retry, so require a decision function (`advise`) plus `describe_*`.
4. **Bounded by default** must cover composed bounds: an explicit per-request
   deadline is never silently capped by another package's client default.
5. **Lifecycle names** do not apply (no long-lived process). Add a per-call
   owner rule: the owner monitors the caller, `close` is idempotent, caller
   death releases the resource.
6. **One error per boundary** yields `PrepareError` (pure) and a `Failure`
   envelope (error, sent, provider, usage); allow `<Thing>Failure` for theme 3.
7. **JSON currency** fits conversation codecs; tool and output schemas stay on
   Blueprint codecs, which `decode.Decoder` cannot replace.
8. **One ordinary path**: `prepare` then `run` is one path; `prepare` adds pure
   admission before I/O and reuse (design :51-53).

## 7. Open questions

1. Deadline defaults: WholeCall 600 s, FirstToken 180 s, IdleGap 60 s? Should
   OpenAI requests ask for reasoning summaries so hidden reasoning shows
   progress?
2. http_gun ownership: should an explicit request deadline replace its client
   default, and should http_gun own a fail-closed plaintext rule for every
   package (R10)?
3. Theme 3 names (`NotSent`, `MaybeSent`, `Completed`), and may
   `response_bytes_observed` fold into `MaybeSent`?
4. Invalid structured output: a `Failure` (proposed) or an `Outcome` variant
   that keeps usage but adds a dead branch to the plain path?
5. Correlation from the `http_gun.Client` view (proposed) or an explicit request
   field? Fabric binds one client per agent (SD-3).
6. Should `CallId`, `ToolName` and `ModelId` become validated strings
   (proposed), and must tool mode, tool choice and native options (design
   :40-41) land before 1.0? Opaque `Request` makes them additive either way.
