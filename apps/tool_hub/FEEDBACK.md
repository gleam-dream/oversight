# tool_hub — composition feedback

## Verdict

The combination works through public imports in both directions. A fabric
agent calls typed tools on a Relay MCP server, answers through a scripted
provider over llm_wire and http_gun, and is itself served as the MCP tool
`ask_assistant` on a second Relay server. 11 tests pass and `gleam run`
prints the demo question, its answer and the run's telemetry trail.

- The common path is short. One Blueprint codec per wire shape produces the
  same JSON Schema in the Relay listing, in fabric's tool and in the request
  llm_wire sends to the model. fabric's new
  `llm.model(client, settings, model_id)` took the app's loopback
  `http_gun.Client` without friction.
- Cancellation is the weak seam (TH-1, TH-2, TH-3). Over Relay's HTTP
  transport, the MCP way to cancel (`notifications/cancelled`) never reaches
  the running call. Relay's own client cannot cancel at all. A disconnect
  kills Relay's worker, but the fabric run keeps going unless the app adds a
  monitor. With that 11-line bridge, a disconnect stops the run and closes
  the provider stream in under a second.
- Errors cross the boundary only as app policy (TH-4, TH-9). Relay does not
  say whether a failed call was sent, so a server that was already down looks
  like a lost reservation.
- No package offers the Relay ↔ fabric adapter (TH-5). The app wrote it:
  about 180 lines for typed and dynamic mounting plus failure mapping, and
  about 80 lines to expose the agent. fabric_mcp, the integration that
  exists, cannot be used here.

## Answers to the brief's questions

- **One tool vocabulary or three?** Three nominal vocabularies over one
  schema source. Relay has `Definition`, `ToolName`, `ContextTool` and two
  different `ToolDeclaration`s; fabric has `Definition`, `Tool` and
  `model.ToolSpec`; llm_wire has `ToolName` and `ToolDefinition`. The
  Blueprint codec is shared, and the test
  `typed_tool_schema_is_identical_in_all_three_places_test`
  (test/tool_hub_test.gleam:210) shows `runtime.same_schema` holds for the
  native codec, Relay's `tools/list` output and the schema in the model
  request. llm_wire's vocabulary never appears in app code, because fabric
  derives it. The name and description are restated in fabric unless the app
  derives fabric's definition from Relay's (TH-8).
- **Can fabric tools be exposed over relay with public APIs?** A fabric
  _agent_ can: `ask_assistant` is an ordinary `handle_with_error_renderer`
  over a function that starts and awaits a run
  (src/tool_hub/assistant.gleam:205-222). A fabric _tool_ cannot: its name,
  description, schema and invoke function are `@internal`
  (fabric/src/fabric/tool.gleam:379-418). This is the fabric card's known
  concern. The app therefore treats the Relay definition as the source of
  truth and derives the fabric definition from it
  (src/tool_hub/remote_tools.gleam:55-65); the reverse direction has no
  public path.
- **Do errors and uncertainty map across MCP ↔ fabric?**
  - MCP to fabric: `isError` maps cleanly to `tool.Explain`; the model saw
    `unknown SKU ZZ-999` and the run continued
    (test/tool_hub_test.gleam:288). Transport failures need app policy.
    Relay reports no submission evidence, so a lost call to `reserve_stock`
    must be `Uncertain`, and a lost call to a read-only tool can be
    `Explain` only if the app trusts the peer's `readOnlyHint` (TH-4).
  - fabric to MCP: `Completed` becomes structured output. `Suspended` with
    uncertain effects, `Cancelled` and `Refused` can only become `isError`
    text, because MCP has no "outcome unknown" result and Relay's error
    renderer returns a `String` (TH-9).
  - fabric_mcp maps the same `isError` to `UncertainEffect` (TH-5), so the
    ecosystem has two contradictory mappings.

## Findings

### TH-1 `notifications/cancelled` never reaches a running call over Relay HTTP

- **Packages**: relay. **Kind**: defect. **Severity**: major.
- **Evidence**:
  - Every POST gets its own runtime with `max_live_exchanges: 1`, both in
    the buffered and the SSE path
    (relay/src/relay/transport/http.gleam:785-797, :856-876).
  - A cancellation notification is looked up only among that runtime's own
    exchanges (relay/src/relay/server.gleam:678-679, :1250-1257). The new
    POST's runtime knows no call, closes the notification exchange and
    answers 202.
  - App test `cancelled_notification_does_not_reach_the_running_call_test`
    (test/tool_hub_test.gleam:473) sends `tools/call` id 41 and then
    `notifications/cancelled` for id 41. It gets 202, but no
    `[relay, invocation, cancelled]` event follows, the fabric run keeps
    working, and the provider stream stays open for the 800 ms window. Only
    `fabric.cancel_stored` stops it.
  - Glue: `src/tool_hub/mcp_wire.gleam` (68 lines) builds the raw requests,
    because Relay's client has no cancel operation (TH-2).
- **Proposal** (relay): keep an in-flight request table in the listener's
  hub, keyed by request id (and by session once sessions exist), and route
  `notifications/cancelled` to the runtime that owns the call. Add a test
  that cancels a `tools/call` from a second POST.
- **Status (2 Oct 2026):** resolved by relay 5caff50, with the proposal
  withdrawn. MCP 2026-07-28 makes closing the connection the Streamable HTTP
  cancellation signal and says no `notifications/cancelled` message is
  required or expected there; request ids are not session-scoped either, so
  a second POST cannot name the caller's own call. The defect was that a
  buffered (`application/json`) call ignored its client's disconnect. Relay
  now cancels it: the worker is killed and `invocation.cancelled` is
  emitted. The app deleted `src/tool_hub/mcp_wire.gleam` (68 glue lines, 87
  in the file). The test is now
  `cancelled_notification_is_ignored_and_disconnect_cancels_test`
  (test/tool_hub_test.gleam:483): the notification gets 202 and changes
  nothing, then `client.close` on Relay's own client cancels the
  invocation, the fabric run and the model stream. The notification is
  built in a 23-line test probe (:511-533), because no MCP client needs to
  send it over HTTP.

### TH-2 Relay's client cannot cancel, and its timeout leaves the server working

- **Packages**: relay. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - `relay/client` exports no cancel or cancellation-token call
    (relay/src/relay/client.gleam:882-925). Tool calls send
    `accept: application/json` only (relay/src/relay_gun_ffi.erl:54-58), so
    the server takes the buffered path, which notices neither a client
    timeout nor a disconnect. It waits `request_timeout_ms`
    (relay/src/relay/transport/http.gleam:785-850).
  - App test `relay_client_timeout_leaves_the_run_going_test`
    (test/tool_hub_test.gleam:514): the client returns
    `TransportFailure(RequestTimedOut)` after 300 ms, while the agent and its
    model stream keep running. With the default local policy the server
    stops the worker only after 30 s.
  - Only an SSE request is cancelled by disconnect. The app had to send it
    with http_gun (`mcp_wire.tools_call(.., stream: True)`,
    src/tool_hub/mcp_wire.gleam:16).
- **Proposal** (relay): add `client.call_definition_with(client, definition,
input, CallOptions(cancellation: Option(Token), deadline: Option(Int)))`.
  On cancel or timeout it sends `notifications/cancelled` (after TH-1) and
  closes the stream. Alternatively, ask for SSE responses so that a closed
  connection cancels the call. The relay card already recommends moving the
  client to http_gun, whose `cancellation.Token` would fit this directly.
- **Status (2 Oct 2026):** partially resolved by relay 5caff50. Relay's
  client no longer needs SSE for cancellation: closing it cancels a buffered
  call, so every cancellation test now uses `client.call_definition` and
  `client.close` instead of raw http_gun requests (`mcp_wire.tools_call`
  removed with the module). What remains: the client still has no per-call
  cancel, and its timeout does not disconnect. On timeout it calls
  `gun:cancel` on the stream (relay/src/relay_gun_ffi.erl:84-86, :108-110),
  which on HTTP/1.1 keeps the connection open, so the server keeps working.
  `relay_client_timeout_leaves_the_run_going_until_close_test`
  (test/tool_hub_test.gleam:538) shows the model stream still open 800 ms
  after `RequestTimedOut`, and closing only after `client.close`, which also
  drops every other call on that client. Revised proposal (relay): on
  timeout or a per-call cancellation token, close that call's connection
  (one connection per in-flight call, or close and reconnect), since the
  spec's only HTTP cancellation is the disconnect.

### TH-3 A cancelled Relay invocation does not cancel work the handler started elsewhere

- **Packages**: relay, fabric. **Kind**: composition. **Severity**: major.
- **Evidence**:
  - Relay cancels an invocation by `process.kill` on its worker
    (relay/src/relay/runtime.gleam:583-593). The handler gets no
    cancellation signal or invocation id; `HandlerCallContext` has only
    `application`, `input_responses` and `report_progress`
    (relay/src/relay/tool.gleam:447-452).
  - A fabric run lives in a runner that `fabric.start` launches under the
    store (fabric/src/fabric.gleam:213); it does not die with the caller.
  - App test `disconnect_without_the_bridge_leaves_the_run_running_test`
    (test/tool_hub_test.gleam:437): Relay records `invocation.cancelled`, but
    no `fabric run.cancel` follows and the provider stream stays open.
  - Glue: `cancel_when_caller_dies` (src/tool_hub/assistant.gleam:167-177,
    11 lines) monitors the handler process and calls `fabric.cancel`. With
    it, `disconnecting_mcp_client_cancels_run_and_model_stream_test`
    (test/tool_hub_test.gleam:401) sees the run end `Cancelled` and the
    provider see its stream close.
- **Proposal**: relay owns the signal. Add `cancelled: fn() -> Bool` or a
  `Subject` notified on cancellation to `HandlerCallContext`, and document
  that a kill is the only stop for synchronous handlers. fabric could add an
  owner option to start (`fabric.start_owned(.., owner: Pid)` cancels the
  run when `owner` exits), mirroring llm_wire's stream owner, which already
  closes HTTP when its consumer dies.

### TH-4 Relay transport failures carry no submission evidence

- **Packages**: relay (http_gun as the model). **Kind**: composition.
  **Severity**: major.
- **Evidence**:
  - `TransportError` is `ConnectionClosed | RequestCancelled | RequestTimedOut
| ResponseLimitExceeded | TransportFault(String)`
    (relay/src/relay/client.gleam:433-439). Every gun failure maps to
    `connection_closed` (relay/src/relay_gun_ffi.erl:409), and the client
    opens gun with `retry => 0` (:20), so a stopped server permanently
    closes the `Client`.
  - App test `unreachable_server_mid_run_makes_a_reservation_uncertain_test`
    (test/tool_hub_test.gleam:312) stops the inventory server _before_ the
    model asks for `reserve_stock`. Nothing could have been sent, yet Relay
    reports `ConnectionClosed`. The app must classify it as `Uncertain`, so
    the run suspends and `ask_assistant` answers
    `outcome unknown: reserve_stock (call lost: connection closed); a person must reconcile run …`.
  - http_gun already separates `NotSubmitted` from `MayHaveBeenSent`
    (http_gun/src/http_gun/error.gleam:4-7). The fabric card's relay seam
    notes that `TransportFailure(RequestTimedOut)` must be `Uncertain`; this
    app shows that the converse (definitely not sent) cannot be expressed.
  - Glue: the failure mapping and classification
    (src/tool_hub/remote_tools.gleam:23-48, :188-250, 69 lines), which also
    reads `readOnlyHint` to downgrade lost read-only calls to `Explain`
    (`unreachable_server_on_a_read_only_tool_is_explained_test`,
    test/tool_hub_test.gleam:346).
- **Proposal** (relay): add `evidence: NotSent | MaybeSent` to
  `TransportFailure`, or reuse `http_gun/error.Evidence` when the client
  moves to http_gun. Reconnect on the next call instead of keeping a dead
  connection.

### TH-5 No package adapts Relay tools to fabric tools; fabric_mcp cannot serve this app

- **Packages**: fabric (fabric_mcp), relay. **Kind**: composition.
  **Severity**: major.
- **Evidence**:
  - The app's adapter is about 180 lines: typed mounting 24, failure
    mapping 69, dynamic mounting 89 (src/tool_hub/remote_tools.gleam). The
    relay card's llm_wire/fabric seam predicted this adapter "belongs in
    fabric or the application; no package provides it yet".
  - fabric_mcp cannot replace it:
    - It speaks stdio only, through its own JSON-RPC client
      (fabric/integrations/fabric_mcp/src/fabric_mcp/client.gleam:17-25,
      :57); this app's peer is Relay over HTTP.
    - It binds MCP tools only as graph operations
      (fabric_mcp.gleam:215-221), never as agent `tool.Tool`s.
    - It requires a native codec whose schema equals the remote one
      (fabric_mcp.gleam:223-229), so it has no dynamic mounting.
    - It maps a remote `isError: true` to `UncertainEffect`
      (fabric_mcp.gleam:318 then :274), while this app (and fabric's own
      `Explain` doc, fabric/src/fabric/tool.gleam:64-71) treats `isError` as a
      definite failure the model sees.
    - Its facade returns `Result(_, String)` built with `string.inspect`.
  - Adding fabric_mcp would also give the app a second MCP client next to
    Relay's, with a different protocol version check and error vocabulary.
- **Proposal** (fabric): replace fabric_mcp's client with `relay/client` in
  an optional `fabric_relay` package that offers `mount(relay_definition,
peer: fn(context) -> client.Client)` and `discover(client, peer)` for agent
  tools, plus the existing graph binding. It should own the isError →
  `Explain` and lost-call → `Uncertain` mapping (after TH-4) and fix
  fabric_mcp's isError mapping.

### TH-6 Mounting a discovered schema needs a hand-built `Codec(Value)` and an error-vocabulary map

- **Packages**: json_blueprint, relay. **Kind**: ergonomics. **Severity**:
  major.
- **Evidence**:
  - fabric's `tool.define` needs a `Codec(input)` with a schema
    (fabric/src/fabric/tool.gleam:132-139). Blueprint can load a discovered
    schema as a `RuntimeContract`, but offers no codec over it. The app
    builds one with `codec.from_parts` and `runtime.validate`
    (src/tool_hub/remote_tools.gleam:135-145).
  - Validation errors (`runtime.ValidationReason`,
    json_blueprint/src/json/blueprint/runtime.gleam:52-69) parallel decode
    errors (`codec.DecodeReason`, codec.gleam:33-53). Wrapped as
    `CustomDecodeReason`, they render as `custom validation failed`
    (codec.gleam:351). With that wrapping (the app's first version), the
    model in `discovered_tools_work_without_native_types_test` saw
    `$: custom validation failed` for `limit: 50`. After the app's 37-line
    mapping (src/tool_hub/remote_tools.gleam:147-184), it sees
    `$["limit"]: integer outside range 1 to 10`, the same text as the typed
    path.
  - Relay's `client.ToolDeclaration.input_schema` is `json.Json`, so the app
    renders it to text and parses it again
    (src/tool_hub/remote_tools.gleam:107-110). This adds evidence to the
    json_blueprint card's concern 5 (no `gleam/json` interop).
- **Proposal** (json_blueprint): add `runtime.value_codec(contract) ->
Codec(Value)`, which decodes by validating and reports `DecodeError`s
  rendered like native ones, or at least a public
  `runtime.to_decode_error(ValidationError) -> DecodeError`. Relay could
  also expose the listed schema as a Blueprint `Value` or contract next to
  the `json.Json`.
- **Status (wave 2):** resolved by json_blueprint `contract.value_codec` (head f55ec09;
  the proposal, verbatim). `contract.ValidationError` now carries
  `codec.PathSegment` and `codec.Reason`, the same types decode errors use,
  so `value_codec` reports `$["limit"]: integer outside range 1 to 10`
  with no mapping. The app deleted `contract_codec`, `decode_error` and
  `decode_reason` (48 lines, remote_tools.gleam) and calls
  `contract.value_codec(remote)` (src/tool_hub/remote_tools.gleam:118).
  `discovered_tools_work_without_native_types_test` still asserts the model
  sees that text. Not resolved: Relay's `ToolDeclaration.input_schema` is
  still `json.Json`, so the app still renders it to text and parses it again
  (:105-109). The output side of the mount, a pass-through `Codec(Value)`,
  still needs a hand-built `codec.custom` (:120).

- **Status (wave 3):** resolved by json_blueprint 60c0dfb. The output
  side of the mount, the pass-through `Codec(Value)`, is `codec.value()`
  (src/tool_hub/remote_tools.gleam:117); it replaces
  `codec.custom(encode: Ok, decode: Ok, schema: None, placeholder: Null)`.
  1 line and the `Null` and `None` imports removed; the placeholder is no
  longer the app's concern. The `Json` to text to contract round trip on the
  input side remains (Relay's `ToolDeclaration.input_schema` is still
  `json.Json`; relay is unchanged in wave 3).

### TH-7 One question cannot be followed across relay, fabric, llm_wire and http_gun

- **Packages**: llm_wire, relay, fabric, http_gun. **Kind**: composition.
  **Severity**: major.
- **Evidence** (`gleam run`, and `common_path_answers_through_both_mcp_servers_test`,
  test/tool_hub_test.gleam:163):
  - fabric events carry the run id; http_gun events join through a
    correlation id. For one question, 12 fabric and 24 http_gun events join;
    18 relay and 17 llm_wire events do not.
  - llm_wire's observation metadata is only `stage`, `provider` and
    `outcome` (llm_wire/src/llm_wire/telemetry.gleam:17-19), so its events
    cannot be tied to the run or to the HTTP request that carried them.
  - Relay events carry a per-POST exchange id and an invocation id, but no
    server identity and no tool name. The inventory and assistant servers in
    one VM are indistinguishable, and all five `invocation.started` events
    say `tool_name=tools/call` (test/tool_hub_test.gleam:197-202). This adds
    evidence to the relay card's sinal seam. A handler cannot learn its
    invocation id (relay/src/relay/tool.gleam:447-452), so the app cannot
    link the `ask_assistant` invocation to the run it starts.
  - Joining http_gun to the run needs glue. `llm.model` binds its client
    when the agent is built (fabric/src/fabric/llm.gleam:42-50), and the run
    id exists only after `fabric.start`, so the app rebuilds the agent per
    question with `http_gun.with_correlation(client, new_id())` and records
    the pair after start (src/tool_hub/assistant.gleam:100-120, :128-138;
    src/tool_hub/telemetry.gleam:146-177). http_gun's `Id` comes only from
    `new_id()`, so the run id itself cannot be the correlation.
- **Proposal**:
  - llm_wire: add the http_gun request id and correlation to the
    observation metadata.
  - relay: add `tool` and a listener name to invocation events, and the
    invocation id to `HandlerCallContext`.
  - fabric: pass the run id and turn to the model function
    (`model.Request.run`), so `fabric/llm` can call `with_correlation` per
    turn.
  - http_gun: add `telemetry.correlation_from(String) -> Id`.
- **Status (wave 2):** unchanged; `sinal/correlation` exists, but no package
  carries it yet. The app emits no Sinal events of its own, so the only
  correlation keys it holds are the packages': the fabric run id, http_gun's
  `Id`, Relay's integers. http_gun's `with_correlation` still takes its own
  `telemetry.Id` and `Metadata.correlation` is still `Option(Id)`
  (http_gun/src/http_gun/telemetry.gleam:66-67), so the per-question
  `new_id()`, the rebuilt agent and `telemetry.link` stay (~35 lines). When
  http_gun adopts `Correlation` (wave 3, HTTPGUN-R8), the run id (36 bytes,
  inside the 128-byte limit) can serve as the correlation and `link` and
  `Link` can go; the agent still has to be rebuilt per question until fabric
  passes the run id to the model function.
- **Status (follow-up):** partially resolved by http_gun c45adfe;
  `with_correlation` takes a `sinal/correlation.Correlation` and the event's
  `correlation` key carries it, so `telemetry.new_id()` and the `Id` type are
  gone from the app (`correlation.unique()`, `Correlation`; 0 lines removed,
  the import swapped). The join does not shrink: `llm.model` still binds its
  client when the agent is built and the run id exists only after
  `fabric.start` (fabric/src/fabric/llm.gleam:42-50), so the app cannot use
  the run id as the correlation and still rebuilds the agent per question and
  keeps `Link`, `link` and the `follow` lookup (~35 lines, unchanged). The
  correlation also does not follow a question further: only http_gun writes
  the `correlation` key. No relay, llm_wire or fabric event carries one
  (grep of `correlation` in their `src` finds only fabric/graph.gleam), so
  the same 24 http_gun events join and the same 18 relay and 17 llm_wire
  events do not. The new type is correct for when they adopt it, and the
  per-question correlation is then the only key an app needs.

- **Status (wave 3):** partially resolved by http_gun 1a5f5ef (the
  client label). `config.with_label` puts the client's name in
  `Metadata.client`, so the telemetry handler now tells the provider client
  (`tool_hub_provider`) from the test's second client (`mcp_wire`) without
  a correlation: the handler prints the label and
  `common_path_answers_through_both_mcp_servers_test` asserts that every
  http_gun event joined to the run is the provider's. This is a way to
  filter, not a join. The join itself is unchanged: `llm.model` still binds
  its client when the agent is built and the run id exists only after
  `fabric.start`, so the app rebuilds the agent per question and keeps
  `Link`, `link` and `follow` (~35 lines, no change). The same 24 http_gun
  events join and the same 18 relay and 17 llm_wire events do not.

### TH-8 One schema, but name and description are declared twice unless derived one way

- **Packages**: fabric, relay. **Kind**: ergonomics. **Severity**: minor.
- **Evidence**: per typed tool, Relay needs two codecs, `tool_name` and
  `definition` (two `let assert`s) plus metadata modifiers
  (src/tool_hub/inventory.gleam:146-153), and the server binds it once
  (:265-286). fabric's `tool.define(String, String, Codec, Codec)` would
  restate the name and description. The app avoids that with an 11-line
  derivation (src/tool_hub/remote_tools.gleam:55-65) and mounts each tool
  in one line (src/tool_hub.gleam:152-160). The derivation works only Relay
  → fabric; see the fabric card's relay seam for the `@internal` accessors.
- **Proposal** (fabric): make `tool.definition_name`, `definition_description`,
  `definition_input` and `definition_output` public on `tool.Definition`, so
  a library-defined fabric tool can be published over MCP.
- **Status (wave 2):** not affected. The Blueprint codecs under it moved to
  the `use` builder (see `## Re-run after wave 2`); the derivation is
  unchanged.

### TH-9 An MCP error result can carry only text, so "outcome unknown" is prose

- **Packages**: relay. **Kind**: flexibility. **Severity**: minor.
- **Evidence**: `handle_with_error_renderer` renders an application error
  to a `String` (relay/src/relay/tool.gleam:508-512), and
  `DispatchError.PublicApplicationFailure(String)` (:487-494) is the only
  failure shape. MCP allows `structuredContent` alongside `isError`, but
  the app cannot attach the run id and uncertain actions as data. An MCP
  client has to parse `assistant.render` text (src/tool_hub/assistant.gleam:181-202)
  to find the run to reconcile.
- **Proposal** (relay): let the renderer return
  `ToolError(content: List(ContentBlock), structured: Option(Value))`, or
  add a `HandlerResult.Failed(content, structured)` variant for advanced
  handlers.

### TH-10 fabric's `model.stop` event reports unreported usage as zero

- **Packages**: fabric. **Kind**: defect. **Severity**: minor.
- **Evidence**: the scripted provider reports no usage, and every
  `[fabric, model, stop]` event carries `Usage(0, 0)` (`gleam run` output).
  The event emits the difference of the run's totals
  (fabric/src/fabric/internal/observe.gleam:93-100). fabric's own docs say
  a missing report is never zero, and `Snapshot.usage` counts
  `unreported_replies` (fabric/src/fabric/run.gleam:233-235).
- **Proposal** (fabric): make the measurement `Option(Usage)` or add an
  `unreported` flag to `ModelTurn`.
- **Status (2 Oct 2026):** resolved by fabric db81b79 (c60bc1c).
  `observation.model_turn()` is now `Event(Option(Usage), ModelTurn)`. The
  app's `usage_text` handles `None` (src/tool_hub/telemetry.gleam:367-372,
  +4 lines), and `run.stop` prints `RunTotals.unreported_replies`. `gleam
run` now shows `turn 1 ToolRequest (usage not reported)` and `Completed
after 4 turns, 4 without usage`;
  `common_path_answers_through_both_mcp_servers_test` asserts both
  (test/tool_hub_test.gleam:189-199).

### TH-11 http_gun's observations require a supervised forwarder

- **Packages**: http_gun, sinal. **Kind**: ergonomics. **Severity**: nit.
- **Evidence**: relay and llm_wire emit synchronously and fabric through
  `emit_routed`, but http_gun delivers events only through
  `config.observations: Option(forwarder.Forwarder)`. The app's telemetry
  module starts a static supervisor just for that forwarder
  (src/tool_hub/telemetry.gleam:92-99), 8 lines. This adds evidence to the
  sinal card's "three emission paths" seam.
- **Proposal** (http_gun): use `forwarder.emit_routed` when
  `observations` is `None`, so routing stays the application's choice as in
  fabric.
- **Status (wave 2):** partially resolved by sinal 1ff1c18. `forwarder.new`
  no longer takes a capacity or returns a `Result`, so the two-line
  `let assert Ok(..) = forwarder.new(.., 1024)` is one line
  (src/tool_hub/telemetry.gleam:92). The supervisor and the
  `config.observations` plumbing remain (7 lines instead of 8): http_gun
  still emits only through its own forwarder, not `sinal.emit`, and
  `forwarder.emit_routed` is gone, so the proposal now reads "use
  `sinal.emit` when `observations` is `None`".

- **Status (wave 3):** resolved by http_gun e55fa1d. Observations go
  through `sinal.emit` when the client has no forwarder, which was the
  proposal. The app's handlers only send to its collector, so they run in
  the emitting process and the forwarder is gone: the supervisor and
  forwarder in telemetry.gleam (7 lines), `http_forwarder` (3), the two
  fields of `Telemetry` that held them (2), the `forwarder.dropped_event`
  handler that watched them (8), the `with_observations` plumbing in
  `provider_client`, and `src/tool_hub_ffi.erl` (10 lines, which existed
  only to stop that supervisor without a crash report) are all deleted:
  about 30 lines. An app whose handlers do real work would route
  `["http_gun"]` to a forwarder once; this one does not need to.

### TH-12 Dependency resolution

- **Packages**: relay. **Kind**: ecosystem-interop. **Severity**: nit.
- **Evidence**: resolution succeeded on the first try. Relay pins
  `mist = "== 6.0.2"` and `gun = "== 2.6.0"` (relay/gleam.toml:18-19);
  http_gun pins the same gun. The app's `mist >= 6.0.2 and < 7.0.0`
  resolved to 6.0.2 only because of Relay's exact pin, so any app on a
  newer mist 6.x (or wisp pulling one) will conflict.
- **Proposal** (relay): widen to `mist >= 6.0.2 and < 7.0.0`.
- **Status (2 Oct 2026):** resolved by relay c62bc29 (head 5caff50). Relay
  now allows `mist >= 6.0.2 and < 7.0.0`, `gun >= 2.6.0 and < 3.0.0` and
  `gleam_stdlib < 2.0.0`. After widening the app's own `gleam_stdlib` range
  to `< 2.0.0` (gleam.toml:7), `gleam update` resolved gleam_stdlib 1.0.5,
  mist 6.0.3, glisten 9.0.1, gramps 6.0.1 and gleeunit 1.11.0; gun stays at
  2.6.0.

## Glue measure

Lines of adapter code per seam, excluding blank lines and comments.

| Seam                                                        | Lines   | Location                                                                                                                         |
| ----------------------------------------------------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------- |
| MCP call outcome → fabric failure (typed and dynamic)       | 69      | remote_tools.gleam:23-48, :188-250                                                                                               |
| Dynamic mounting from `tools/list`                          | 89 → 38 | remote_tools.gleam:81-129 (wave 2: the 48 lines that built `Codec(Value)` and mapped errors are one `contract.value_codec` call) |
| Typed mounting from a Relay definition                      | 24      | remote_tools.gleam:55-80                                                                                                         |
| fabric run → MCP result (`ask_assistant` status and render) | 70      | assistant.gleam:58-66, :124-163, :181-202                                                                                        |
| Relay cancellation → fabric cancellation                    | 11      | assistant.gleam:167-177                                                                                                          |
| Cancelling an MCP call (raw wire, Relay client cannot)      | 68      | mcp_wire.gleam (deleted 2 Oct 2026; now `client.close`, see TH-1)                                                                |
| Telemetry correlation (agent per question, link, follow)    | ~35     | assistant.gleam:100-120, :128-138; telemetry.gleam:146-177                                                                       |
| http_gun forwarder supervisor for observations              | 8 → 7   | telemetry.gleam:90-97                                                                                                            |
| http_gun loopback client (destination policy)               | 6       | tool_hub.gleam:79-94 (configuration, not adapter code)                                                                           |

The Sinal handlers themselves (about 11 lines per event across 7 relay, 6
fabric, 1 llm_wire, 1 http_gun and 1 sinal events) and the scripted
provider (scripted_llm.gleam, 205 lines) are test infrastructure, not glue.
Exposing the agent over Relay (`assistant.serve`, 18 lines) is ordinary
Relay use.

## What worked well

- **One codec, one schema.** The Blueprint codecs in inventory.gleam drive
  Relay listing, server decoding, typed client calls, fabric's argument
  check and llm_wire's tool schema. `runtime.same_schema` confirms all three
  match (test/tool_hub_test.gleam:210).
- **Relay's public definition accessors** (`definition_name`,
  `definition_metadata`, `definition_input_codec`,
  `definition_output_codec`) made the Relay → fabric derivation a plain
  11-line function.
- **`client.call_discovered` with Blueprint `Value`** forwards discovered
  tool arguments and results without a native type; the dynamic agent
  answered the same question as the typed one.
- **fabric's argument check** stops invalid model arguments before any MCP
  call: `{"sku":42}` never reached the inventory server
  (test/tool_hub_test.gleam:368), and the model got a precise reason and
  retried.
- **fabric's `Explain`/`Uncertain` split** expresses exactly what MCP lacks.
  An uncertain reservation suspends the run without another model turn
  (test/tool_hub_test.gleam:312).
- **The cancellation chain below Relay is sound.** `fabric.cancel` kills
  the model task, llm_wire's owner closes the HTTP stream, and the provider
  observes the close within the test's 3 s window, every time.
- **The new `fabric/llm.model(client, settings, model_id)`** accepted a
  caller-owned client with a loopback policy and per-question correlation
  views (`http_gun.with_correlation`) with no adapter.
- **http_gun's loopback policy** was a four-line record update. Its default
  refusal is explicit (`DestinationRejected`) and easy to diagnose.
  **Status (2 Oct 2026):** http_gun a2869b7's `config.allow_loopback`
  replaced it: `provider_client` (src/tool_hub.gleam:78-89) now pipes the
  config through one call. The helper keeps every other destination rule,
  so the provider client still refuses private and reserved addresses.
  **Status (wave 3):** `allow_loopback` alone still admits public hosts, so
  the provider client is now
  `with_destination(destination.loopback_only() |> destination.only_hosts(["127.0.0.1"]))`
  (http_gun e55fa1d). It refuses everything but the scripted provider's
  host, and `provider_client_refuses_public_hosts_test` pins that
  (`error.kind` is `Refused`, evidence `NotSent`).
- **llm_wire's scripted provider** (`testing.config()` plus the reply
  builders) let a 205-line mist server stand in for a real provider,
  including a held stream for cancellation tests.

## Re-run after fixes (2 Oct 2026)

Package heads: relay 5caff50, fabric db81b79, http_gun a2869b7,
json_blueprint and llm_wire at their current heads. Resolved gleam_stdlib
1.0.5 (after widening the app's own range to `< 2.0.0`), mist 6.0.3.
11 tests pass, three runs in a row; `gleam run` prints the answer and the
telemetry trail, now with `usage not reported` on every model turn.

| Seam                                            | Before | After | Change                                                                                   |
| ----------------------------------------------- | ------ | ----- | ---------------------------------------------------------------------------------------- |
| Cancelling an MCP call (raw wire)               | 68     | 0     | `mcp_wire.gleam` deleted; Relay's client plus `client.close` (TH-1, TH-2)                |
| http_gun loopback client (destination policy)   | 6      | 1     | `config.allow_loopback` replaces the nested `destination.Policy` update                  |
| fabric usage in telemetry                       | 3      | 7     | `Option(Usage)` handled, unreported replies printed (TH-10; correctness, not glue)       |
| Relay cancellation → fabric cancellation (TH-3) | 11     | 11    | unchanged: a disconnect kills Relay's worker, but the fabric run needs the app's monitor |

The four cancellation tests were rewritten on Relay's own client:
`disconnecting_mcp_client_cancels_run_and_model_stream_test` (a buffered
call, cancelled by `client.close`), `disconnect_without_the_bridge_leaves_the_run_running_test`
(TH-3 still holds), `cancelled_notification_is_ignored_and_disconnect_cancels_test`
(TH-1, spec behavior) and `relay_client_timeout_leaves_the_run_going_until_close_test`
(TH-2 remainder).

New friction:

- fabric's `model_turn()` change broke the app's build (one type mismatch
  in telemetry.gleam). The fix was 4 lines and the new type is the right
  one.
- Cancellation by disconnect makes TH-2's remainder sharper. Relay's client
  shares one gun connection across calls, and its timeout cancels only the
  gun stream, so the only way for a Relay client to cancel one call is to
  close the client and every other call on it.

Package heads for this section: sinal 5aef827, json_blueprint f55ec09.

## Re-run after the follow-up fixes

Package heads: json_blueprint bb4da39, sinal 6de2b69 (required_field f9cca37),
http_gun c45adfe. 11 tests pass; `gleam run` prints the same trail (12 fabric
and 24 http_gun events joined, 18 relay and 17 llm_wire not).

The app emits no events of its own, so the sinal builder and
`required_field()` do not apply: it only reads other packages' events, and
http_gun's `Metadata.correlation` is still `Option(Correlation)` (the key is
absent when a view has none), so the handler keeps its `None -> NoKey` arm.
grind is not used.

| Seam                                                    | Before | After | Change                                                                                                                      |
| ------------------------------------------------------- | ------ | ----- | --------------------------------------------------------------------------------------------------------------------------- |
| Codec getter annotations (inventory, assistant)         | 18     | 0     | every `fn(x: T)` is `get: fn(x)`; 4 fewer lines in inventory.gleam after `gleam format`, 0 in assistant.gleam               |
| One-field codec (`stock_query_codec`)                   | 1      | 1     | stays one line; `question_codec` and `search_result_codec` keep three-line calls because the arguments do not fit           |
| Handler getter annotation (`get_stock`)                 | 1      | 0     | `fn(query: StockQuery) {..}` is `fn(query) {..}` (3 lines to 1); the `StockQuery` type is inferred from the definition      |
| http_gun correlation (agent per question, link, follow) | ~35    | ~35   | `Id`/`new_id()` are `Correlation`/`correlation.unique()`; no join table can go because the run id is unknown at agent build |

Net diff for the app: 4 files, +34 -40 lines, all from annotations and the
type swap. No logic changed.

New friction:

- The 1-to-4-line one-field codec from wave 2 only shrinks where the whole
  call fits in 80 columns. `get:` adds 5 characters, so `price_cents` and
  `warehouse` still wrap after `gleam format` (3 lines each, as before).
  The annotation friction is gone; the label costs about what it saved in
  the narrowest calls.
- `with_correlation` removes the app's reason for `Id`, but not for the join.
  A Correlation is what the app wants to key a question by, yet the app must
  still learn the run id after start and link the two. fabric passing the run
  id (or a caller-supplied correlation) to the model function is now the only
  thing between this app and zero join glue (TH-7).
- http_gun still emits through its own forwarder (TH-11), so a correlation
  handler cannot be written once for every package: `sinal.observe` on
  `http_telemetry.event()` matches only http_gun, and the other packages
  have no `correlation` key to match.

## Re-run after wave 3

Package heads: http_gun 1a5f5ef, json_blueprint 74a9a7d (`codec.value` at
60c0dfb), sinal 44c5395 (`observe_labelled` at 42dd684), relay 6ee2ae9
(unchanged API), fabric d10635f, llm_wire 576482e. 12 tests pass, three runs
in a row (11 before, plus `provider_client_refuses_public_hosts_test`);
`gleam run` prints the same trail (12 fabric and 24 http_gun events joined,
18 relay and 17 llm_wire not).

| Seam                                               | Before | After | Change                                                                                                                            |
| -------------------------------------------------- | ------ | ----- | --------------------------------------------------------------------------------------------------------------------------------- |
| http_gun forwarder and supervisor for observations | 7      | 0     | `sinal.emit` is the default path (TH-11); also `http_forwarder`, the dropped handler, two `Telemetry` fields: ~30 lines in all    |
| `tool_hub_ffi.erl` (stop the forwarder supervisor) | 10     | 0     | file deleted; nothing else used it                                                                                                |
| Pass-through output codec                          | 1      | 1     | `codec.custom(.., placeholder: Null)` is `codec.value()`; two imports and the invented placeholder go (TH-6)                      |
| http_gun loopback client                           | 7      | 7     | `Config(..)` update with a 60 s ceiling and observations is `loopback_only() \|> only_hosts(..)` and a label; stricter, same size |
| Per-call 60 s deadline on the client               | 1      | 0     | llm_wire's view carries its own budget; no ceiling to raise                                                                       |
| Sinal handler labels                               | 0      | 15    | `sinal.observe` is `sinal.observe_labelled(.., "tool_hub_relay_..", ..)`: same line count, a name in `list_handlers`              |
| Telemetry correlation (agent per question, link)   | ~35    | ~35   | unchanged (TH-7): the run id is unknown when the agent is built                                                                   |

Net diff of the app source: 189 added and 164 removed, of which
telemetry.gleam alone is +175 -139 because the labels re-wrap 15 handler
calls (see the new friction below). The deleted glue is about 40 lines
(forwarder 7, `http_forwarder` 3, fields 2, dropped handler 8, FFI 10, codec
1, the 60 s ceiling and its imports); the labels add back about 55.

Seams that still need glue, and who owns them:

- Relay ↔ fabric adapter (~150 lines), failure mapping and cancellation
  bridge (11 lines): relay and fabric (TH-3, TH-4, TH-5). Wave 3 did not
  touch them.
- The per-question agent and the `Link` join (~35 lines): fabric, which has
  to pass the run id or a caller-supplied correlation to the model function
  (TH-7).
- `ToolDeclaration.input_schema` as `json.Json`, rendered to text and parsed
  again: relay (TH-6).

New friction:

- `observe_labelled` makes every handler call longer without making the app
  simpler. `sinal.observe(relay_telemetry.invocation_completed_event(), fn(measured, m) {`
  is now 106 columns and `gleam format` wraps it onto four lines, so
  telemetry.gleam grew by about 36 net lines for 15 labels that nothing in
  the app reads. The label is worth it only for an app that
  inspects `telemetry:list_handlers`. A helper that derives the label from
  the event (`sinal.observe_named(event, run)`, naming the handler after the
  event) would give the same result without the repetition; sinal owns it.
- `provider_client` had to change its signature: it took the app's
  `Telemetry` for the forwarder and now takes the client label. A test that
  starts a second client must pick a second label, or its events read as the
  provider's. That is the point of the label, but nothing warns when two
  clients share one.
- http_gun's `Metadata.client` is `Option(String)`, so the handler keeps a
  `None -> "unlabelled"` arm for a case this app never produces.
- `http_gun.start` returns an unsupervised client linked to the caller; the
  hub still stops it by hand. `supervised(config, name)` and `named(name)`
  would remove that, but the hub has no supervisor of its own to put it
  under, and adding one only for that is more code than the `stop` call.
