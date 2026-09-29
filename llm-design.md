# LLM — standalone provider interaction

## Current ownership — 29 September 2026

The owner assigned conversation state, pause/resume and durable continuation to Fabric or the caller. LLM Wire returns assistant response data; the caller appends it and tool results, then prepares a fresh request. No provider replay closure, checkpoint schema or retained output codec belongs in a continuation handle here. This supersedes the older continuation laboratory sections below; required signed provider data remains part of the response message.

The [HTTP Gun design](http-gun-design.md) assigns generic HTTP/TLS, pooling, byte-stream ownership and cassette record/playback to an independent package. LLM Wire retains provider authentication and endpoint policy, expected status/media type, SSE reduction, tool/schema admission, usage and semantic retry assessment. Its current local Gun transport is the extraction donor; this document does not claim that HTTP Gun exists or that migration has occurred. See the [construction prompt](docs/implementation/http-gun-prompt.md) and [oracle ledger](research/http-gun-oracles.md).

The historical API-control and prototype descriptions below remain evidence for their named experiments. They do not override this ownership decision.

The current public API cleanup follows the [pre-release contract](docs/implementation/pre-release-api/contract.md#llm-wire). It supersedes older facade and compatibility descriptions below.

The additive application API changes are specified in the
[API ergonomics contract](docs/implementation/api-ergonomics/contract.md#llm-configured-interaction).

The [current API control contract](docs/implementation/api-control/contract.md#llm-provider-and-session-boundary)
defines pure provider settings, application-owned HTTP/SSE adapters, and
schema-only tool admission through the infallible `types.tool_from_contract`
after Blueprint admits a `RuntimeContract`. Built-in settings
start with provider options, such as `config.openai(openai.options(key))`, then
accept common limits and deadlines. `provider.Spec`, `Reducer`, and `Replay`
let a fourth provider own its wire format and assistant turn while the session
runtime retains admission, bounds, cleanup, and exact continuation coverage.
Buffered `session.run` failures carry retry evidence; absent provider usage
remains unknown. The [pilot](playground/ecosystem_pilot/README.md) compiles an
application-defined fourth provider and a discovered Relay tool. Older
laboratory excerpts below are design evidence.

## Purpose and ownership

- LLM provides typed buffered and streamed provider interactions for direct callers and Fabric. One interaction returns an outcome or stream; subsequent interactions remain a host decision.
- This design receives `fabric/llm_wire` from the Fabric baseline at `9194f02`. OpenAI, Anthropic, and Google remain required provider targets; selecting a smaller first implementation does not remove the remaining targets.
- LLM owns requests, outcomes, provider adapters, assistant response data, and semantic streaming. [HTTP Gun](http-gun-design.md) owns generic transport after extraction. [Fabric](fabric-design.md) owns tool execution, action policy, approval, and agent budgets; [Blueprint](blueprint-design.md) owns JSON Schema-aware contracts and validation for tool declarations and structured output. Ordinary provider envelopes and persisted continuations prefer standard Gleam JSON encoders/decoders; an optional reusable codec abstraction must remain schema-independent.
- LLM must not import Fabric, Saga, or Grind. A standalone structured-extraction caller must not require an agent loop, workflow runner, or persistence backend.
- Provider constructors return the LLM public contract. This resolves the baseline's conflicting declarations that `llm_wire` defines its own model port but exports an `agent.model.Model`; Fabric adapts the independent contract.
- Sinal receives package-owned provider observations after transitions. Observations must not control provider interaction or substitute for authoritative state.

## Requests, configuration, and outcomes

- A common request retains roles, content blocks, model selection, output limits, application tool declarations, and sequential or parallel tool mode. The demonstrated text subset does not remove richer content or completion outcomes from the contract backlog.
- A configured adapter retains typed native options and model selection. Unsupported features and incompatible options must return explicit outcomes rather than be silently discarded.
- A response distinguishes final output, application tool requests, output-limited content, refusal, and failure. Output-limited content must not manufacture complete tool calls from partial arguments.
- Provider-hosted tools require a distinct representation because their actions may already have occurred. They must not enter application tool dispatch as unexecuted calls.
- Provider-specific options and extension events use adapter-owned types. Heterogeneous callers may map those types into a caller-owned sum; the portable contract must not require inspecting unbounded raw JSON.
- Optional injected model descriptions support known capability checks and explicit unknown-model outcomes. A continuously maintained model catalog remains optional; its provider owns freshness and provenance.
- Reasoning streams, audio, images, prompt caching, background responses, and interrupted-stream resumption remain extension or later-consumer scope from the streaming research. Their exclusion from the initial experiment must not be read as demonstrated support or permanent rejection.

## Schema admission and structured output

- Tool declarations derive names, descriptions, and schema ASTs from Blueprint-backed contracts. Admission examines the complete schema at its location; a feature summary or already-rendered JSON value cannot replace that evidence.
- Preparation validates local request limits and schema availability before transport. It distinguishes invalid local input, invalid schema, unavailable schema, and a valid schema unsupported by the configured profile.
- The configured adapter owns admission for its selected model, tool inputs, and output contract. Known streaming and parallel-tool restrictions must be checked before opening a stream.
- A prepared interaction retains the admitted schemas, native output codec, and originating adapter. Starting it must transmit the actual admitted tool and output contracts.
- Final structured output must pass runtime schema validation before native decoding, including after tool continuation. Schema-invalid output must not reach the codec's mapping callback.
- Capability metadata cannot guarantee remote acceptance. A remote capability rejection remains an explicit call failure even when local admission succeeded.
- Production provider schema profiles and streamed structured output remain backlog. Scripted profile acceptance establishes no commercial provider capability.

### Current configured-turn declarations

- Code below is a current prototype declaration excerpt: constructor definitions and function signatures retain the linked source module’s names and aliases; function bodies and unrelated declarations are omitted. These excerpts are not standalone modules or published package signatures, and no new compilation or runtime claim follows from this documentation pass.
- The [structured-turn module](playground/interface_lab/src/lab/llm_structured.gleam) retains output type `o`, continuation `c`, and admission reason separately. [The constructive consumer](playground/interface_lab/src/consumers/provider_structured.gleam) exercises preparation and multiple tool rounds; [the negative consumer](playground/interface_lab/negative/structured_provider_output.gleam) rejects replacing a prepared string output with an integer output.
- Blueprint is relevant here because this operation admits tool and output schemas. The laboratory's JSON values elsewhere do not impose Blueprint on ordinary provider-envelope serialization.

```gleam
pub type SchemaLocation {
  StructuredOutput
  ToolInput(llm_turn.ToolName)
}

pub fn prepare(
  provider: Provider(c, reason),
  request: llm.Request,
  catalog: llm_catalog.Catalog,
  output: blueprint.Codec(o),
) -> Result(PreparedTurn(o, c, reason), PrepareError(reason))

pub type StartedTurn(output, continuation, reason) {
  Finished(output)
  NeedsTools(PendingTurn(output, continuation, reason))
}

pub fn start(
  prepared: PreparedTurn(o, c, reason),
) -> Result(StartedTurn(o, c, reason), TurnError)

pub fn resume(
  pending: PendingTurn(o, c, reason),
  results: List(llm_turn.ToolResult),
) -> Result(StartedTurn(o, c, reason), TurnError)
```

## Tool identity and continuation

- Application call identity is separate from provider decoder routing identity. OpenAI item IDs and output indices route deltas to `call_id`; Anthropic block indices route deltas to `tool_use.id`.
- Tool requests must reject empty batches, duplicate identities, and names outside the admitted catalog before returning a pending turn. Exact result coverage must reject missing, duplicate, or unknown call identities before continuation contacts the provider.
- Completed calls remain dispatch candidates. LLM does not grant application registry membership, execution permission, or authorization by returning them.
- A pending turn retains its originating configured adapter, admitted contracts, native output codec, expected call identities, and provider continuation. Continuation accepts correlated results without accepting a replacement provider, including when two adapters share a native continuation type.
- Provider continuation preserves required response identifiers, reasoning state, assistant content, and ordering according to its adapter. A normalized transcript alone does not establish cross-provider continuation compatibility.
- Stream continuation prepares a second stream through the originating callback without opening it during validation. Opening occurs separately and must retain the same resource ownership rules.
- Persistable continuation requires an optional provider-owned envelope with identity, version, codec, and compatibility outcomes. Restoration must preserve required provider state or reject incompatibility; secrets and live sockets must not enter that envelope.
- Copyable prepared or pending values do not enforce single use. Replay rejection, continuation consumption, and durable duplicate-effect protection require an owner or host store contract.
- Final and output-limited continuation remain retained streaming requirements beyond the demonstrated tool-turn path. Failure or local close must not manufacture a resumable continuation.

## Stream grammar

- Public progress reports semantic text and tool-argument events rather than SSE frames. Text block identity remains distinct from tool call identity.
- The adapter retains routing maps and assembles arbitrary argument fragments under each call identity. It decodes arguments only after the corresponding block completes.
- Completing one argument block does not publish executable work. A terminal tool-request turn requires every declared call to complete and decode; declaration order survives interleaving.
- The grammar rejects duplicate starts, unknown calls, deltas after completion, malformed arguments, incomplete terminal calls, and events after termination. Unknown provider events follow an explicit ignore or typed-extension policy and never default to application tool calls.
- A protocol error must terminate the owned stream and request cleanup. Returning the old immutable reducer state is insufficient runtime behavior.
- Terminal precedence prevents late progress, completion, or failure from replacing a closed or completed outcome. Local close is idempotent and preserves an existing terminal outcome.
- Rich content-block transcripts, provider routing fixtures, actual JSON decoding, and bounded assembly remain obligations beyond the current concatenated-text scripted grammar.

### Current deferred stream continuation

- These declarations come from the [pure stream-owner experiment](playground/interface_lab/src/lab/llm_stream_owner.gleam), where `turn` aliases `lab/llm_turn`. [The stream-ownership consumer](playground/interface_lab/src/consumers/stream_ownership.gleam) prepares and opens a second scripted source through the retained provider.
- `prepare_continue` validates result identity without invoking the provider, while `open` invokes the retained callback. `source` is an adapter-owned generic value, not proof of a socket owner; live shared ownership, deadlines, usage, and cleanup remain unimplemented requirements.

```gleam
pub type ContinueError {
  UnknownToolResult(turn.CallId)
  DuplicateToolResult(turn.CallId)
  MissingToolResult(turn.CallId)
}

pub fn prepare_continue(
  pending: Pending(c, source),
  results: List(turn.ToolResult),
) -> Result(PreparedContinuation(source), ContinueError)

pub fn open(
  prepared: PreparedContinuation(source),
) -> Result(source, llm.CallError)
```

## Resource ownership and transport

- A stream capability names one authoritative owner shared by every copied handle or cursor. The owner serializes reads, decoder transitions, and terminal closure; conflicting reads, closed reads, and owner unavailability require explicit outcomes.
- Every cursor shares idempotent resource close. Cleanup must cover success, error, cancellation, and panic without requiring manual close on every consumer exit path.
- A pure cleanup command proves intent only. Runtime tests must establish cleanup under caller termination, owner loss, supported panic paths, and cancellation races; abrupt process loss must not be concealed by an exactly-once cleanup claim.
- Local close reports local resource closure. Provider cancellation confirmation requires explicit provider acknowledgement; ordinary SSE disconnect must not claim remote work stopped.
- Transport must reuse connections and bound buffering against slow or malformed peers. Streaming must use credit-based backpressure and incremental SSE reconstruction across chunk and line boundaries, without buffering the entire response before parsing.
- TLS peer and hostname verification must remain enabled by default with no silent fallback. Tests use an explicit trusted-CA override rather than global verification bypass.
- HTTP/TLS and foreign runtime interaction belong behind one named transport boundary. Wire JSON decoding remains at named adapter boundaries; native callers retain typed values.
- The selected transport direction is the independent Gun-backed [HTTP Gun package](http-gun-design.md). Preserve the boundedness and cleanup requirements through its public client contract; unverified upstream parser limits remain release gates. Any patched dependency requires recorded provenance and a reproducible reason.
- Fabric termination must reach LLM cleanup through the public contract. Fabric must not acquire independent provider networking ownership to achieve it.

## Errors, retries, usage, and deadlines

- Error outcomes distinguish transport failure, rate limit, cancellation, deadline, refusal, unsupported capability, and invalid output. Adapter detail and retry metadata must remain bounded and preserve the portable classification.
- Stream failure distinguishes before and after accepted progress. Accepted progress is a conservative retry boundary, because it does not prove whether a caller observed output.
- Failure before progress is only potentially retryable. Retry eligibility must account for provider-side effects, declared retry ownership, hints, and the remaining deadline; the client must never silently restart after observed partial output.
- Provider interaction retry remains distinct from agent, workflow, or queue retry. A composed effect must assign retry ownership explicitly so nested policies do not multiply ambiguous calls.
- Usage is optional rather than zero when unavailable. Partial and final totals remain distinguishable; cumulative Anthropic updates replace the previous total rather than being summed, while provider-specific detail remains an extension.
- Transport deadlines require a trusted clock and interruption behavior across opening, reads, retries, and cleanup. Deadline enforcement, retry policy, and normalized usage remain runtime backlog rather than consequences of the current error sum.

## Adapter reuse and validation evidence

- The [provider boundary research](research/llm-provider-boundary.md) inspected ReqLLM `v1.24.0` and Jido AI `v2.3.0`. Jido AI's release lockfile pins ReqLLM `1.17.1`; the newer research snapshots must not be presented as an upstream-tested pairing.
- ReqLLM is a behavioral oracle and optional backend, not a blanket parity commitment. Adapt relevant host, continuation, stream-response, streaming-retry, and streaming-orchestration scenarios linked in the research; record exact source revisions and license notices before reuse.
- The upstream suite was not run during that research. Differential tests must distinguish portable common laws from provider-specific fixtures, including malformed responses, rate limits, retry before output, and rejection of restart after partial output.
- Jido's separate agent/client/catalog architecture and LangChain's common callback with provider options are reference designs. Jido's provider-specific continuation and WebSocket handling are evidence that package separation alone does not prove a fully portable advanced host path.
- First attempt narrow reuse of `anthropic_gleam` `0.1.1` through its public sans-I/O and incremental streaming APIs. Accept it only if common Anthropic fixtures pass without internal imports; its buffering convenience API must not define this streaming contract.
- A failed reuse experiment selects a narrow native adapter without weakening the contract. `claude_gleam` remains a behavior comparator; its integrated loop and string tool handler do not establish compatibility with the typed public contract.
- Optional ReqLLM reuse must prove clean Gleam consumer builds, application startup, release packaging, foreign exception translation, and buffered/streamed ownership. Its Elixir build dependency must remain explicit.
- OpenAI Responses and Anthropic Messages are the researched contrasting protocol families. Their [streaming contract](research/llm-streaming-contract.md) records protocol references and scenarios; exact API/fixture revisions remain to be pinned before production conformance claims.
- Google remains a baseline provider target without an established oracle or fixture pin in the reviewed notes. Its implementation must obtain its own recorded protocol evidence rather than inherit OpenAI or Anthropic parity claims.
- Runtime acceptance must cover real chunk fragmentation, interleaved routing, bounded buffering, backpressure, deadline interruption, TLS failures, connection reuse, errors after HTTP success, and cleanup on every exit. An OTP probe must additionally establish shared copied-handle state, conflicting reads, owner death, and caller termination.

## Capability disposition and friction

| Capability                                                    | Disposition and evidence                                                                                                        | Remaining friction or proof                                                                         |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Independent typed call and structured output                  | Retained; partial scripted direct-call evidence                                                                                 | Full roles/content/outcomes, request limits, and real provider fixtures                             |
| Configured admission and correlated buffered turns            | Retained; [configured turns](playground/interface_lab/PROVIDER-STRUCTURED-TURNS.md)                                             | Production schema profiles, stale capability rejection, provider-hosted tools, partial batch policy |
| Tool-turn origin retention                                    | Retained; buffered and second scripted stream demonstrated                                                                      | Persistent envelopes, version compatibility, replay/consumption semantics                           |
| Stream grammar and terminal cleanup intent                    | Retained; [progress](playground/interface_lab/STREAM-PROGRESS.md) and [ownership](playground/interface_lab/STREAM-OWNERSHIP.md) | Copyable reducer state cannot establish shared ownership or successful cleanup                      |
| OpenAI, Anthropic, Google                                     | Reassigned from Fabric without removal                                                                                          | Real adapters and provider-specific conformance remain open                                         |
| TLS, reuse, SSE, credits, shared close including panic        | Reassigned from Fabric without weakening                                                                                        | Transport selection and live runtime tests remain open                                              |
| Errors, retry, usage, deadlines, cancellation                 | Retained; error alternatives and progress classification are partial                                                            | Policy, clocks, usage accounting, remote acknowledgement, and fault tests                           |
| Optional model metadata and advanced extensions               | Retained as optional growth                                                                                                     | Catalog freshness and provider-specific consumers                                                   |
| Tool execution, authorization, loop budgets, durable recovery | Reassigned to Fabric or another host                                                                                            | Compose through public LLM continuation and cleanup contracts                                       |
| Blueprint schemas and codecs                                  | Reused through public contracts                                                                                                 | Provider admission must not silently narrow the data contract                                       |

## Evidence boundary and freeze

- [PUBLIC-API](PUBLIC-API.md) freezes the intended initial facade; [API-COVERAGE](API-COVERAGE.md#standalone-llm-client) records partial and open obligations. Neither document certifies published packages, real provider conformance, or completed runtime behavior.
- The refinement evidence comprises [provider-bound turns](playground/interface_lab/PROVIDER-STRUCTURED-TURNS.md), [stream progress](playground/interface_lab/STREAM-PROGRESS.md), [stream terminal transitions](playground/interface_lab/STREAM-OWNERSHIP.md), and the [live ownership work order](research/llm-stream-ownership-contract.md). Pure transitions and scripted callbacks must not be reported as live HTTP or OTP ownership evidence.
- This consolidation preserves baseline provider and transport requirements while incorporating the admitted package boundary. No baseline capability is removed because it lacks a prototype or falls outside the initial facade.
- Remaining work is implementation backlog. Do not start another interface-refinement wave; reopen a frozen public API only when real implementation produces a concrete caller mismatch.
