# LLM streaming contract exploration

## Question and status

- The experiment asks whether one standalone LLM contract can stream text and application tool calls for direct callers and Fabric without hiding provider differences.
- This note proposes a type and consumer work order.
- The proposed names and signatures are not implemented or compiled.
- Runtime ownership, cleanup, buffering, and protocol conformance remain unverified.

## Protocol evidence

| Concern        | OpenAI Responses                                                                                                                                                                                                                                                                                                                                                                                               | Anthropic Messages                                                                                                                                                                                                                                                                                                               |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Stream grammar | Responses emits typed semantic events such as `response.output_text.delta`, `response.completed`, and `error`. The completed event contains the final Response and token usage. [Streaming guide](https://developers.openai.com/api/docs/guides/streaming-responses), [create-response reference](https://developers.openai.com/api/reference/typescript/resources/beta/subresources/responses/methods/create) | Messages emits `message_start`, indexed content-block start/delta/stop events, one or more `message_delta` events, and `message_stop`. `message_delta.usage` is cumulative, and an `error` event can arrive after the HTTP request succeeded. [Streaming guide](https://platform.claude.com/docs/en/build-with-claude/streaming) |
| Tool routing   | A function-call item starts with an item `id`, a distinct `call_id`, a name, and an `output_index`. Argument deltas carry the item ID and output index, while the later function result is correlated by `call_id`. [Function-calling guide](https://developers.openai.com/api/docs/guides/function-calling#streaming)                                                                                         | A `tool_use` block starts with its result-correlation `id`, name, and content-block index. Later `input_json_delta` events carry partial JSON for that index, and the JSON is complete only at content-block stop. [Streaming guide](https://platform.claude.com/docs/en/build-with-claude/streaming#input-json-delta)           |
| Continuation   | A stored turn can continue with `previous_response_id` plus `function_call_output` items keyed by `call_id`. Stateless reasoning turns can require the returned reasoning items as well. [Function-calling guide](https://developers.openai.com/api/docs/guides/function-calling#handling-function-calls)                                                                                                      | A client-tool turn continues by retaining the assistant content and adding a user message of `tool_result` blocks keyed by `tool_use_id`. Message ordering is part of the contract. [Tool-call guide](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls)                                           |
| Early stop     | The API cancellation endpoint confirms cancellation only for Responses created with `background: true`. Closing an ordinary SSE response is therefore not evidence of provider-confirmed cancellation. [Cancellation reference](https://developers.openai.com/api/reference/go/resources/beta/subresources/responses/methods/cancel)                                                                           | The official TypeScript SDK supports breaking iteration or aborting the stream controller. The cited API does not describe that local abort as a provider cancellation acknowledgement. [SDK streaming reference](https://platform.claude.com/docs/en/cli-sdks-libraries/sdks/typescript#streaming-responses)                    |

- The OpenAI item ID and output index are decoder routing keys.
- The OpenAI `call_id` is the application result-correlation identity.
- The Anthropic content-block index is a decoder routing key.
- The Anthropic `tool_use.id` is the application result-correlation identity.
- A common adapter must keep a routing-key-to-`CallId` table for each live stream.
- A text block identity must remain distinct from `CallId`, because a text delta is not a tool request.
- Provider-hosted tools remain outside the initial application-tool contract, because the provider may already have executed them.

## Recommended initial boundary

- The initial request subset contains user and assistant text, an output-token limit, application tool declarations, and an explicit sequential or parallel tool mode.
- The initial response subset contains text deltas, application-tool argument deltas, a terminal turn, an optional normalized usage total, provider failure, and consumer close.
- The adapter validates locally known model, streaming, parallel-tool, and schema-subset requirements before opening the transport.
- Tool admission consumes a catalog derived from the registry's Blueprint codecs, not the current declaration's rendered `Value`.
- A remote rejection remains a call failure because capability metadata can be stale.
- Buffered structured output remains on the existing path during this experiment.
- Reasoning streams, audio, images, prompt caching, provider-hosted tools, background responses, and interrupted-stream resumption require adapter extensions or later common consumers.

The smallest useful conceptual surface is:

```gleam
pub type ToolMode { SequentialTools ParallelTools }

pub type Feature {
  Streaming
  ApplicationTools
  ParallelApplicationTools
}

pub type SchemaRequirement {
  RequiresObject
  RequiresOptionalProperty
  RequiresArray
  RequiresTuple
  RequiresNullable
  RequiresTaggedUnion
  RequiresIntegerRange
}

pub type AdmissionError {
  UnknownModel(String)
  UnsupportedFeature(Feature)
  UnsupportedSchemaFeature(
    tool: llm_turn.ToolName,
    requirement: SchemaRequirement,
  )
  IncompatibleFeatures(List(Feature))
}

pub opaque type StreamingProvider(continuation, extension)
pub opaque type ToolCatalog
pub opaque type PreparedStream(continuation, extension)
pub opaque type Stream(continuation, extension)

pub fn prepare_stream(
  provider: StreamingProvider(c, extension),
  request: llm.Request,
  tools: ToolCatalog,
  tool_mode: ToolMode,
) -> Result(PreparedStream(c, extension), AdmissionError)

pub fn open(
  prepared: PreparedStream(c, extension),
) -> Result(Stream(c, extension), llm.CallError)
```

- `prepare_stream` derives required features from the real request and tool schemas.
- `ToolCatalog` retains each name, description, codec-derived `blueprint.Schema` AST, and requirements derived from that AST.
- The adapter renders provider wire schema only after it admits the retained AST and requirements.
- A feature list is a diagnostic summary, not a complete provider policy. Admission examines the full AST for positional, optional-property, and combined constraints.
- The current `llm_turn.ToolDeclaration.input_schema: Value` cannot supply this evidence without adding an independent schema parser.
- Fabric can derive `ToolCatalog` from its existing registry, while a standalone caller can build the same catalog from Blueprint-backed tool contracts.
- A caller does not supply a disconnected capability checklist.
- Adapter-specific configuration remains in the adapter constructor.
- `PreparedStream` records successful local admission without claiming that the remote service will accept the call.

The stream reports semantic progress rather than raw SSE frames:

```gleam
pub type OutputBlockId { OutputBlockId(String) }

pub type StreamProgress(extension) {
  TextDelta(block: OutputBlockId, text: String)
  ToolCallStarted(id: llm_turn.CallId, name: llm_turn.ToolName)
  ToolArgumentsDelta(id: llm_turn.CallId, fragment: String)
  ToolArgumentsEnded(id: llm_turn.CallId)
  Extension(extension)
}

pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int)
}

pub type UsageSnapshot {
  PartialUsage(Usage)
  FinalUsage(Usage)
}

pub opaque type Continuation(continuation, extension)
pub opaque type PendingToolTurn(continuation, extension)

pub type ContinueError {
  MissingToolResult(llm_turn.CallId)
  DuplicateToolResult(llm_turn.CallId)
  UnknownToolResult(llm_turn.CallId)
  StaleContinuation
}

pub type Turn(continuation, extension) {
  Final(
    output: value.Value,
    continuation: Continuation(continuation, extension),
    usage: Option(Usage),
  )
  RequestsTools(
    pending: PendingToolTurn(continuation, extension),
    calls: List(llm_turn.ToolCall),
    usage: Option(Usage),
  )
  OutputLimited(
    partial: value.Value,
    continuation: Continuation(continuation, extension),
    usage: Option(Usage),
  )
}

pub type StreamFailure {
  FailedBeforeOutput(llm.CallError)
  FailedAfterOutput(llm.CallError, last_usage: Option(UsageSnapshot))
}

pub type StreamStep(continuation, extension) {
  Progress(StreamProgress(extension))
  Finished(Turn(continuation, extension))
  Failed(StreamFailure)
}

pub fn prepare_continue(
  pending: PendingToolTurn(c, extension),
  results: List(llm_turn.ToolResult),
) -> Result(PreparedStream(c, extension), ContinueError)
```

- `ToolArgumentsDelta` carries arbitrary text fragments rather than JSON values.
- The adapter decodes accumulated arguments only after the provider closes that tool block.
- `ToolArgumentsEnded` is progress and does not authorize tool execution.
- `RequestsTools` contains the validated `ToolCall` values that Fabric may submit to policy.
- `OutputLimited` is a successful terminal outcome with partial content rather than a transport failure.
- Each terminal turn owns an origin-bound provider continuation and optional final usage.
- This terminal shape deliberately revises the current `Reply(c)`, which loses `c` on `Final`.
- The live stream handle is not a continuation and cannot enter `fabric_turn.Pending`.
- `PendingToolTurn` retains the originating `StreamingProvider`, provider state, admitted catalog, and expected call IDs, as `fabric_turn.Pending` retains its provider today.
- `prepare_continue` does not accept a replacement provider, so an application cannot resume an Anthropic turn through an OpenAI adapter.
- A lower-level adapter API that accepts provider plus continuation must validate immutable provider identity and version before opening a stream.
- `prepare_continue` rejects missing, duplicate, or unknown result IDs before transport open.
- Gleam cannot enforce one-time consumption of the copyable pending value, so repeated continuation needs runtime stale-use rejection where duplicate calls matter.
- Failure or consumer close does not manufacture a continuation.
- A retry may be eligible only for `FailedBeforeOutput`; the contract makes no automatic retry promise.
- Anthropic cumulative usage updates are replaced in adapter state rather than summed.
- OpenAI terminal usage and the final Anthropic cumulative usage become the common final total.
- Provider-specific usage detail belongs in the extension type.
- The extension parameter is an adapter-owned closed type rather than unbounded raw JSON.
- An application that selects heterogeneous adapters can map their extensions into its own sum type.

## Resource ownership

```gleam
pub type ReadError { StreamClosed ConcurrentRead }

pub type CloseError { CloseOwnerUnavailable }

pub type CloseOutcome {
  ConsumerClosed
  ProviderCancellationConfirmed
  AlreadyTerminal
}

pub fn next(
  stream: Stream(c, extension),
) -> Result(StreamStep(c, extension), ReadError)

pub fn close(
  stream: Stream(c, extension),
) -> Result(CloseOutcome, CloseError)
```

- The stream owner serializes reads, decoder state, transport closure, and one terminal outcome.
- `ConsumerClosed` means that the local stream resource has closed.
- `ProviderCancellationConfirmed` requires an explicit provider acknowledgement and is unavailable for the initial ordinary SSE adapters.
- `close` is idempotent from the caller's perspective.
- Gleam values are copyable, so an opaque `Stream` cannot enforce linear use.
- The runtime owner must reject concurrent reads and reads after close or terminal completion.
- A type-only prototype can exercise these outcomes through an injected fake owner, while it cannot prove socket cleanup, bounded buffering, backpressure, or crash cleanup.

## Consumer-led work order

1. Add a standalone scripted consumer that renders text, records two interleaved tool calls, and waits for `Finished(RequestsTools(...))` before executing either call.
2. Feed an OpenAI-shaped fixture whose argument deltas route by `item_id` and `output_index`, while its final results require the distinct `call_id` values.
3. Feed an Anthropic-shaped fixture whose argument deltas route by content-block index, while its final results require the `tool_use.id` values.
4. Assert that both fixtures yield the same common event meaning and preserve two distinct `CallId` values.
5. Return results for both calls through `prepare_continue(pending, results)`, open the second stream, and consume its final text while retaining the same origin provider.
6. Add a Fabric consumer that converts only the terminal `RequestsTools` turn into pending policy work and uses the same origin-bound continuation path.
7. Add early-close consumers before output, after one text delta, and during fragmented tool arguments.
8. Require each early-close path to return a close outcome, no terminal continuation, and no executable partial tool call.
9. Add failures before and after the first public progress event, and require the caller to treat only the former as retry-eligible.
10. Add one registry-derived catalog whose adapter rejects parallel tools and one codec-derived schema requirement during `prepare_stream`.
11. Add one typed extension event through a scripted third adapter without changing the common progress constructors.

## Acceptance and limits

- Positive consumers use only public standalone LLM types, except for the separate Fabric adapter consumer.
- Negative fixtures reject a text block ID where a tool `CallId` is required and reject a `Stream` where a continuation is required.
- A negative fixture cannot supply another provider to `prepare_continue`, and runtime fixtures reject a copied stale pending continuation.
- Pure reducer tests cover unknown events, deltas before block start, duplicate block start, mismatched done events, malformed final JSON, duplicate terminal events, and an error after partial output.
- Unknown provider events are ignored or preserved as a typed adapter extension according to adapter policy; they are never decoded as application tool calls by default.
- Passing the interface experiment establishes the common semantic boundary only.
- Production evidence still requires real transport tests for ordering, capacity bounds, cancellation races, socket and actor cleanup, provider errors after HTTP success, and exact wire fixtures at pinned API revisions.
