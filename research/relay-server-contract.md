# Relay first server contract

## Question and status

- The experiment asks how Relay can turn its local heterogeneous tool registry into one framework-neutral MCP server slice without claiming an HTTP transport, authorization system, or conforming runtime.
- The pinned first revision remains MCP `2026-07-28`. This revision is modern and sessionless; it does not use `initialize` or `notifications/initialized`.
- The first compatibility revision remains `2025-11-25`. That legacy revision does require `initialize`, an `initialized` notification, and session capability state.
- The two revisions may share tool declarations and handler adapters. They must not share one lifecycle that silently accepts messages from the wrong era.
- This note proposes interfaces and consumer work. No server behavior is implemented.

## Pinned protocol evidence

- The authority remains the MCP [`2026-07-28` tag](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/2026-07-28), commit [`5f5440bb26a62e2cf3440b92da5a667efa03b267`](https://github.com/modelcontextprotocol/modelcontextprotocol/commit/5f5440bb26a62e2cf3440b92da5a667efa03b267), under MIT. The tag's [TypeScript schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/2026-07-28/schema/2026-07-28/schema.ts) is authoritative.
- Modern requests carry protocol version and client capabilities in per-request `_meta`; unsupported versions produce the defined `-32022` response. Servers must implement `server/discover`, while clients may call another method directly and handle version rejection. [Versioning](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning) and [discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)
- Modern Streamable HTTP uses one POST per request, no GET endpoint, and no protocol session. Every POST carries `MCP-Protocol-Version` and `Mcp-Method`; `tools/call` also carries `Mcp-Name`, and the corresponding header and body values must agree. [Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
- `tools/list` is paginated. Tool execution errors belong in a successful `CallToolResult` with `isError: true`, while malformed parameters, unknown tools, and exceptional server conditions are JSON-RPC errors. [Tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
- Progress uses a caller-supplied token and must stop after request completion. Modern HTTP cancellation is the client closing that request's SSE response stream; `notifications/cancelled` is the stdio signal. [Progress](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/progress) and [cancellation](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation)
- The later `2025-11-25` compatibility path must receive `initialize` first, return its chosen version and capabilities, then receive `notifications/initialized` before normal operation. [Legacy lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)

## Ownership boundary

| Owner                 | Responsibility                                                                                                                                                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| HTTP adapter          | A fresh exchange identity per POST, socket and stream lifetime, body limit, HTTP method, media types, header parsing, case-insensitive header names, Origin and Host policy, disconnect detection, backpressure, and response writes |
| Authorization adapter | Bearer extraction, caller-supplied verification, resource and scope checks, and construction of an opaque request context                                                                                                            |
| Protocol core         | JSON-RPC message classification, revision-specific decoding, header/body agreement after parsing, version admission, method routing, response/error construction, and pure in-flight state                                           |
| Tool registry         | Valid declarations, deterministic authorization-sensitive listing, cursor resolution, typed argument decoding, handler selection, and application result adaptation                                                                  |
| Handler runtime       | One owned invocation, timeout, cooperative cancellation observation, progress callback execution, crash isolation, and cleanup                                                                                                       |

- The HTTP adapter passes a verified or explicitly anonymous application context into the protocol core. The core never parses a bearer token or manufactures a principal.
- The HTTP adapter allocates an `ExchangeId` before body parsing, so every parse failure and response still has one unambiguous transport destination.
- The protocol core allocates a separate `InvocationId` only after admitting an executable call. It never uses the client-supplied JSON-RPC identifier as a process, stream, or invocation key.
- The registry receives that request context for both listing and invocation. A tool may be hidden by authorization without making visibility connection-local state.
- Progress is an observation emitted from an owned invocation. It never drives registry or application state.

## Framework-neutral HTTP boundary

The exact names are provisional. The first type experiment should keep raw wire admission distinct from method dispatch.

```gleam
pub opaque type ExchangeId
pub opaque type InvocationId

pub type HttpRequest(context) {
  HttpRequest(
    method: HttpMethod,
    path: String,
    headers: RequestHeaders,
    body: BitArray,
    context: context,
  )
}

pub type ResponseBody {
  EmptyBody
  JsonBody(BitArray)
  EventStream
}

pub type HttpResponse {
  HttpResponse(status: Int, headers: ResponseHeaders, body: ResponseBody)
}

type InvocationStatus {
  InvocationOpen
  InvocationTerminal
}

type InvocationRecord {
  InvocationRecord(
    invocation: InvocationId,
    exchange: ExchangeId,
    wire_request: RequestId,
    progress_token: Option(ProgressToken),
    status: InvocationStatus,
  )
}

pub type ServerInput(context) {
  HttpReceived(ExchangeId, HttpRequest(context))
  ToolFinished(InvocationId, ToolOutcome)
  ToolProgress(InvocationId, ProgressUpdate)
  ResponseStreamClosed(ExchangeId)
}

pub type ServerEffect(context) {
  SendResponse(ExchangeId, HttpResponse)
  SendStreamMessage(ExchangeId, RpcMessage)
  InvokeTool(InvocationId, InvocationContext(context), ToolName, Value)
  CancelInvocation(InvocationId)
  CloseResponseStream(ExchangeId)
}

pub fn step(
  server: Server(context),
  input: ServerInput(context),
) -> #(Server(context), List(ServerEffect(context)))
```

- `HttpRequest` is framework-neutral, while it is not transport-free. A Mist adapter or test adapter constructs it after applying a configured body limit and obtaining authorization context.
- The core retains an admitted invocation record from `InvocationId` to `ExchangeId`, the wire `RequestId`, optional progress token, and open or terminal status.
- Wire request identifiers may repeat across clients, concurrent POSTs, and later POSTs. They are echoed only in the response carried by their own exchange.
- An immediate JSON response and an SSE response stream are different plans. A progress-capable invocation needs the stream plan so progress notifications can precede the final response.
- The pure model may emit `CancelInvocation` after a stream closes. Only the runtime can interrupt a process or signal a handler.
- The runtime must stop sending messages after cancellation. Neither the effect nor an opaque cancellation token proves that an already-started external side effect stopped or was undone.
- A late progress or completion input for a terminal or unknown `InvocationId` is discarded and cannot resolve a newer invocation that reused the same wire identifier.

## JSON-RPC and era admission

- Decode JSON-RPC request, notification, response, and error envelopes as distinct types. The server endpoint accepts client requests and revision-permitted client notifications; it rejects inbound responses rather than treating them as requests.
- A request has a string or integer identifier and always receives one result or error unless its response stream is cancelled.
- A notification has no identifier and never receives a JSON-RPC result. An accepted HTTP notification returns `202` with an empty body; an HTTP admission failure may return an HTTP error with a JSON-RPC error that has no identifier.
- Parse failure, invalid JSON-RPC envelope, unsupported method, invalid method parameters, protocol version rejection, and header mismatch remain separate errors.
- A parse failure has no trustworthy wire request identifier. Its MCP JSON-RPC error omits the optional identifier while `ExchangeId` still selects the HTTP response destination.

The revision strategy should be explicit:

```gleam
pub type AdmittedMessage(context) {
  Modern20260728(ModernRequest(context))
  Legacy20251125(LegacySession, LegacyMessage(context))
}

pub type ModernRequest(context) {
  Discover(RequestEnvelope(context))
  ListTools(RequestEnvelope(context), Option(Cursor))
  CallTool(RequestEnvelope(context), ToolName, Value)
}

pub type LegacyPhase {
  AwaitingInitialize
  AwaitingInitialized
  Ready
  Closed
}
```

- Modern admission requires `2026-07-28` in both `_meta` and the HTTP header, required client capabilities in `_meta`, matching `Mcp-Method`, and matching `Mcp-Name` for `tools/call`.
- Every successful modern result in this slice, including a `tools/call` result with `isError: true`, encodes `resultType: "complete"`.
- Modern admission creates no `LegacySession`, does not rely on or return `Mcp-Session-Id`, and does not require `server/discover` before `tools/list` or `tools/call`.
- A modern `initialize` or `notifications/initialized` message is not a hidden compatibility handshake. It follows modern unknown-method or unsupported-notification rules.
- Legacy compatibility is a later adapter strategy. It creates session state only through `initialize`, records the negotiated version and capabilities, accepts `notifications/initialized` only in the next phase, and gates normal requests on `Ready`.
- The legacy `2025-11-25` result codec omits `resultType`; sharing native result models does not permit reusing the modern wire encoder.
- A dual-era HTTP endpoint selects an era from a valid modern envelope or the legacy initialization path. It never infers modern support merely from a malformed `400` request.

## Tool listing and invocation

The local `Registry(context)` remains the source of tool-handler agreement. The server slice needs a page and invocation adapter rather than a second registry.

```gleam
pub type Page(a) {
  Page(items: List(a), next: Option(Cursor))
}

pub fn list_page(
  registry: Registry(context),
  context: context,
  cursor: Option(Cursor),
) -> Result(Page(Declaration), ListError)

pub fn begin_invocation(
  registry: Registry(context),
  context: InvocationContext(context),
  name: ToolName,
  arguments: Value,
) -> Result(Invocation, DispatchError)
```

- Registry construction continues to reject duplicate names and unavailable input schemas before serving.
- Listing uses deterministic order for one visible catalog. The opaque cursor must bind the catalog revision and authorization-visible view or return `InvalidParams` when that view no longer matches.
- The initial declaration contains a validated name and object input schema. Description, output schema, annotations, icons, `x-mcp-header`, and cache policy enter only with their own Blueprint and protocol consumers.
- A wrong JSON shape for `tools/call.params` is a protocol `InvalidParams` error. A well-shaped argument object rejected by the tool's domain codec becomes an actionable tool result with `isError: true`.
- Unknown tool is a protocol error. An encoded application failure is a tool error. Output encoding failure, handler crash, and unmapped runtime failure are sanitized server errors rather than fabricated tool results.

## Progress and cancellation

- `InvocationContext(context)` retains the application context, core-owned invocation identity, wire request identifier, optional progress token, and a runtime-owned cancellation view.
- A handler can request a progress effect only when the request supplied a token. The core rejects a notification for an inactive token, enforces increasing progress in its pure state, and stops progress after a terminal response or stream close.
- The initial `ProgressUpdate` surface accepts integer progress and optional integer total values. The protocol permits fractional JSON numbers, which remain outside this subset until Relay has a wire-number type that does not conflate integer and floating-point semantics.
- Modern HTTP sends request-scoped progress only on that request's SSE response stream. It does not use `subscriptions/listen`.
- Closing the response stream records that the result will be unused, emits `CancelInvocation`, and suppresses later wire output. The handler runtime should stop work as soon as practical.
- Cancellation does not promise rollback, remote cancellation, or absence of an external effect. A side-effecting tool must expose its own idempotency, receipt, or reconciliation contract when that distinction matters.

## Decisive consumers

The first consumer is modern-only:

1. Admit a `server/discover` POST with matching version, method header, and required `_meta`; return supported version and the tools capability without creating a session.
2. Request `tools/list` through two pages and reject an unknown, stale, or authorization-mismatched cursor without invoking a tool.
3. Call one typed tool successfully, return one application failure as `isError: true`, require `resultType: "complete"` on both results, and return an unknown tool as a JSON-RPC error.
4. Start two concurrent calls from different exchanges with the same wire request identifier. Give each a distinct invocation identity, route integer progress and terminal result to its own exchange, and echo the repeated wire identifier only inside that exchange.
5. Finish one call, admit a later call that reuses its wire identifier, then deliver late progress and completion for the old invocation. Require both late inputs to be ignored without changing the replacement call.
6. Start another call, close its SSE response, map that exchange to one cancellation effect for its invocation, suppress a late progress/result event, and leave the fixture's external-effect status explicitly unknown.
7. Deliver malformed JSON on a fresh exchange and require the parse error response to target that exchange without allocating an invocation.
8. Reject missing or disagreeing version, method, and tool-name headers before dispatch. Reject an unsupported version with the pinned supported-version payload.

The later compatibility consumer uses the same registry through a fresh legacy state:

1. Accept `initialize` for `2025-11-25`, return the selected version and tools capability, and enter `AwaitingInitialized`.
2. Reject a normal tool request before the `notifications/initialized` notification.
3. Accept that notification as `202` with no JSON-RPC body, enter `Ready`, then serve the same paginated list and typed tool call with the legacy result codec that omits `resultType`.
4. Reject a second `initialize`, a stale or unknown session, and a post-initialization version mismatch through legacy-specific outcomes.

## Work order and evidence boundary

1. Add revision-specific JSON-RPC values and codecs for modern discovery, list, call, results, protocol errors, progress, and the request `_meta` subset.
2. Add the framework-neutral HTTP envelope, transport-owned exchange identity, core-owned invocation identity, admission function, pure server inputs/effects, and a scripted request-stream owner.
3. Add registry paging and request-scoped invocation context without changing the registry's ownership of typed handlers.
4. Compile and run the modern consumer against pure parsed values. Add negative type fixtures only for method/result or context mismatches; malformed JSON, header values, cursors, and revisions are runtime decode or admission cases.
5. Add actual JSON byte fixtures from the pinned schema and validate encoder output against that schema. Assert modern `resultType` and legacy omission separately. Fuzz malformed JSON, duplicate or missing members, repeated request identifiers, extension fields, and size boundaries.
6. Add a real HTTP adapter only after the model settles. Test body limits before parse, media negotiation, case-insensitive header names, Base64 header values, Origin and Host policy, `202` empty bodies, JSON versus SSE responses, disconnects, backpressure, task cleanup, and exact HTTP status plus JSON-RPC error combinations.
7. Run the frozen `2026-07-28` server requirements without an expected-failures claim before calling the slice conforming.
8. Add `2025-11-25` initialize, initialized, session registry, legacy Streamable HTTP behavior, and its frozen requirement run as a separate compatibility wave.

- Pure tests can establish exhaustive message routing, era separation, pagination outcomes, error classification, and effect ordering for scripted inputs.
- Only wire tests establish JSON parsing, HTTP framing, header semantics, SSE behavior, disconnect handling, and resource cleanup.
- Only the official frozen requirement run establishes MCP conformance for the pinned revision.
- The initial server may run on loopback or behind a caller-supplied verifier. A public protected deployment remains pending Relay's resource-server authorization contract.
