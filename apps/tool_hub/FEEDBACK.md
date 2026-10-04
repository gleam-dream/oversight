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

- **Status (wave 4):** the probe is gone. The 23-line hand-built
  `notifications/cancelled` POST and the test's second http_gun client
  (`mcp_wire`) are one `http.handle` call on the running handler with a
  `relay_testing.request("notifications/cancelled", ..)`
  (test/tool_hub_test.gleam:577-582). Relay still answers 202 and changes
  nothing, which is the spec behavior.

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

- **Status (wave 4):** resolved by relay ffb6d37. A client timeout closes
  that call's connection, so the server cancels the run without
  `client.close`: `relay_client_timeout_cancels_the_run_test`
  (test/tool_hub_test.gleam:640) gets `Error(TimedOut(MaybeSent))` after
  300 ms, then sees the model stream close and the run end `Cancelled`. A
  per-call `client.with_cancellation(token)` cancels one call and leaves the
  client usable: `cancelling_one_call_keeps_the_client_open_test` (:603)
  gets `Error(Cancelled(MaybeSent))`, the run is cancelled, and the same
  client then answers `tools/list`. No glue was needed. New friction:
  `client.close` on a client with a call in flight blocks for about 5 s
  before the call fails, because an owned client closes through
  `http_gun.stop`, which drains for its default 5 s shutdown timeout
  (relay/src/relay/client.gleam:854-858). The doc says it closes "every
  request and stream on it"; it should cancel them.

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

- **Status (wave 4):** not resolved; relay defect. `tool.cancelled(call)`
  fires, but over HTTP the worker is killed in the same step. On a client
  disconnect the buffered path calls `runtime.exchange_closed` and then
  `finish`, which stops the request's runtime
  (relay/src/relay/http.gleam:1336-1340); `Stop` kills every cancelling
  worker at once instead of waiting out the 5 s grace
  (relay/src/relay/runtime.gleam:521-527). A trial handler that selected on
  `tool.cancelled` and then called `fabric.cancel` was killed before the
  call returned: the run kept going and the provider stream stayed open. The
  same cancel from a `spawn_unlinked` process succeeded. So the 11-line
  monitor bridge stays (src/tool_hub/assistant.gleam:168-178), and the
  selector cannot replace it. A second gap would remain even with the grace:
  `fabric.await` blocks and offers no selector, so a handler must start a
  waiter process to select on both the run and `tool.cancelled` (about 12
  lines). Proposals: relay keeps the runtime until cancelled workers exit or
  their grace ends; fabric adds a selector for a run's status (owners: relay,
  fabric).

- **Status (round 5):** the waiter is resolved by fabric fd60851.
  `fabric.await_with(running, within: assistant.budget, or:
relay_tool.cancelled(call))` waits for the run and for the cancellation in
  one receive, so `await_or_cancel` (33 lines: the waiter, its
  `spawn_unlinked` trap, the kill and the nested `Result(Result(..))`) is
  gone. The handler is one `case` on `Interrupted(Nil)` (cancel the run,
  return `Cancelled`) and `Reached(status)`; the call and its arms add 5
  lines to `ask`. The cancellation tests pass unchanged, including the
  negative one (`cancel_with_caller: False` passes an empty selector, so
  `Interrupted` never arrives).

- **Status (wave 5):** resolved by fabric_relay. `fabric_relay.serve`
  cancels a run its call owns (no idempotency key) when the call is cancelled,
  through `relay_tool.cancelled` and `fabric.await_with`; the app has no
  handler code for it. The disconnect test passes unchanged
  (`disconnecting_mcp_client_cancels_run_and_model_stream_test`), three runs
  in a row. The wave 4 concern, that Relay kills the worker before the
  handler returns from `fabric.cancel`, did not show; I did not look for why.
  The brief's rule is now the behavior: a keyed call does not cancel its run
  (`keyed_call_outlives_its_disconnect_test`), so `Settings.cancel_with_caller`
  and the negative test with its empty selector are gone, and so is the dead
  `Interrupted` arm. `fabric.cancel_when_down` is not needed here.

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

- **Status (wave 4):** resolved by relay ffb6d37. `client.Error` carries
  `Evidence`, and the client reconnects on the next call. The server stopped
  before `reserve_stock` now fails with `ConnectFailed` (`NotSent`), so the
  reservation is a definite failure the model sees:
  `unreachable_server_before_a_reservation_is_explained_test`
  (test/tool_hub_test.gleam:351) replaces the old "uncertain" test, and the
  model reads `the inventory is unavailable: … (connect_failed)`. The
  uncertain path is now shown by a call that may have arrived:
  `timed_out_reservation_is_uncertain_test` (:387) stalls the catalog past a
  300 ms client timeout and gets `timed_out.maybe_sent`. The mapping is
  `evidence × effect` with one `Uncertain` arm (`MaybeSent`, may change),
  instead of seven transport and protocol arms
  (src/tool_hub/remote_tools.gleam:127-178, 63 → 58 lines).
  `readOnlyHint` is still needed for a `MaybeSent` read-only call.

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

- **Status (wave 4):** open. FABRIC-R10 replaces fabric_mcp with a Relay
  adapter in wave 5. The app's adapter is 123 lines (typed 24, dynamic 41,
  failure mapping 58).

- **Status (wave 5):** resolved by `integrations/fabric_relay`.
  `src/tool_hub/remote_tools.gleam` (204 lines) is deleted: `mount` is
  `fabric_relay.tool(definition, peer:)` (3 lines in `typed_tools`),
  `discover` is `fabric_relay.discover(peer, peer: ..)` and `classify` is
  built in with the same evidence rule. All 15 tests pass, including the
  three failure-mapping tests, with one wording change: the model now reads
  `the MCP call failed: ... (connect_failed)` where the app said `the
inventory is unavailable`. The listing's names are now checked
  (`UnsupportedName`), which the app never did.
  Exposing the agent: `ask`, `render`, `tool_error` and `AskError` (about
  120 lines) are `fabric_relay.serve(ask_assistant(), service)`; see
  `assistant.serve` (18 lines, the same size as before). The `outcome_unknown`
  facts carry the same `run_id` and `uncertain` list as the app's own
  structured error. The answer is typed: `agent.with_answer(answer_codec())`.
  The answer has little structure, so `Answer` is one field, `{"answer":
string}`. It had to be an object for the provider, and the definition
  needs it as the agent's answer. `Answer.run_id` is gone.

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

- **Status (wave 4):** resolved by relay ffb6d37. `tool.Declaration` holds
  `input_schema: Value`, and `tool.input_contract(declaration)` loads it
  (src/tool_hub/remote_tools.gleam:100). The `json.to_string` then
  `contract.parse` round trip and the `gleam/json` import are gone from
  remote_tools, and the schema test uses the same call. The line count does
  not change (41) because `gleam format` wraps the new error mapping.

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

- **Status (wave 4):** mostly resolved by relay ffb6d37 and llm_wire
  177ad50. The assistant server gives each request a correlation
  (`http.with_correlation(fn(_) { Some(correlation.unique()) })`,
  src/tool_hub/assistant.gleam:251). The handler reads it with
  `tool.correlation(call)` (:243) and puts it on the provider's HTTP Gun
  view, which llm_wire now reads, and on the inventory client's Relay view
  (:131). For the demo question `gleam run` now joins 42 http_gun, 20
  llm_wire and 6 relay events to the run (before: 24, 0 and 0). All
  llm_wire events join. Relay events name the tool (`tool=ask_assistant`)
  and the server (`http.with_label("assistant")`/`"inventory"`). Still
  unjoined: 17 relay events. A Relay client's correlation stays local; it
  does not reach the server, so the inventory server's own events carry
  none, and `ExchangeClosedMeta` has no correlation field (owner: relay).
  The `Link` and the per-question agent stay (~35 lines): fabric events
  carry only the run id, and `llm.model` binds its client before the run
  exists (owner: fabric).

- **Status (round 5):** the app-side join is resolved by fabric fd60851;
  the relay half is not. `ask` passes the request's correlation to
  `fabric.start(.., id: run.new_id(), correlation: Some(correlation))`. Fabric
  then puts it on every run event, on each model turn's HTTP Gun view
  (`fabric/llm` applies `request.correlation`) and in every `tool.Call`, so:
  the agent is built once (`assistant.build_agent`, in `tool_hub.start`;
  `agent_for` and its 18 lines are gone); the question's `Context` is no
  longer rebuilt with a correlated inventory client (the tools read
  `call.correlation`, `remote_tools.inbound`, 8 lines); `Link`, `link`, the
  `on_run` callback and `State.links` are gone (~35 lines). `follow` still
  needs the run id to name the question, but takes the correlation from the
  run's own events (`RunKey` now carries both), not from an app-side table.
  `gleam run` joins the same 12 fabric, 42 http_gun, 20 llm_wire and 6 relay
  events, and 17 relay events stay unjoined (see round 5 below).

- **Status (wave 5):** resolved. The caller owns the correlation
  (`client.with_correlation(mcp, question)`); Relay carries it in `_meta` and
  `x-correlation-id`, so the assistant server's events carry it, with no
  `http.with_correlation` builder (deleted, which hid it).
  `fabric_relay.serve` starts the run under it, and `fabric_relay.tool` puts
  the run's correlation on the inventory client, so the inventory server's
  events and the closed exchanges carry it too. For the demo question
  `gleam run` joins 12 fabric, 48 http_gun, 20 llm_wire and 20 relay events;
  unattributed events of the question: **0** (before: 17 relay). 3 relay
  events remain unjoined, and they are the caller's own `tools/list`
  (a different request: its `client.call`, `request.admitted` and
  `exchange.closed`). The http_gun count is higher because the caller's
  client (label `assistant_caller`) now joins. `follow` takes the
  `Correlation`, not a run id, which `Answer` no longer needs to carry.
  `lazy_unwrap` (assistant.gleam:221) is gone because `tool.correlation` is
  not an `Option`; `ExchangeKey` and the `Option` fallback in `key_of`
  remain only for `frame.rejected`.

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

- **Status (wave 4):** unchanged in substance. `tool.output_codec` now
  returns `Option(Codec(o))` (`None` for a content tool), so the derivation
  needs `let assert Some(output)` for a structured definition
  (src/tool_hub/remote_tools.gleam:50).

- **Status (wave 5):** the derivation (11 lines) went with `remote_tools`:
  `fabric_relay.tool` derives the fabric definition from the Relay one, and
  the `let assert Some(output)` is a documented panic inside it. The reverse
  direction (a fabric tool served over MCP) is still absent, which no longer
  matters here: `serve` publishes the agent, not a tool.

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

- **Status (wave 4):** resolved by relay ffb6d37. The renderer returns
  `tool.ToolError`. `assistant.tool_error` (src/tool_hub/assistant.gleam:203)
  sends the same text plus `structuredContent` such as
  `{"error":"outcome_unknown","run_id":…,"uncertain":[{"tool":…,"evidence":…}]}`.
  The client receives `ToolFailed(content, Some(structured))`, and
  `timed_out_reservation_is_uncertain_test` reads the run id from the data.
  `Uncertain` now carries the run id, so `render` no longer takes it from the
  first effect, with a `"?"` fallback. The data costs about 30 lines; this
  is a new capability, not glue.

- **Status (wave 5):** resolved by fabric_relay. The `isError` result and its
  structured content are `serve`'s: `error` is one of `working`, `timed_out`,
  `outcome_unknown`, `awaiting_approval`, `cancelled`, `failed` and others,
  with `run_id`. `timed_out_reservation_is_uncertain_test` now reads the
  evidence (`timed_out.maybe_sent`) from the `uncertain` list in the data
  instead of the text; the text is the library's ("the run stopped on effects
  of unknown status"), not the app's.

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

## Re-run after wave 4

Package heads: relay 3f88ef1 (API at ffb6d37), fabric 556abc3, llm_wire
9f35183 (API at 177ad50), http_gun 4a6eeb0, json_blueprint 74a9a7d, sinal
44c5395. The app adds `gleam_time >= 1.11.0 and < 2.0.0`. 14 tests pass,
three runs in a row, each in about 29 s. Before there were 12: the uncertain
reservation test became two (one `NotSent`, one `MaybeSent`), and the
per-call cancellation test is new. `gleam run` prints the answer and joins
42 http_gun, 20 llm_wire and 6 relay events to the run. Before, it joined 24
http_gun and 0 of the other two. 17 relay events stay unjoined.

Relay was the heavy break: every call site and every telemetry handler
changed. llm_wire and fabric changed only types (`llm_wire.Config`,
`String` model ids, `with_endpoint(String)`, `telemetry.event()`). The
public API of the app now takes `Duration`: `Settings.budget`,
`Settings.inventory_timeout` (new; it was a hard-coded 2000) and
`assistant_client(hub, timeout)`. `Settings.assistant_policy`
(`http.HttpPolicy`, removed) is now
`assistant_http: fn(http.Config(Nil)) -> http.Config(Nil)`. Nothing is
stored durably (the run store is in memory), and the `ask_assistant`
input and output codecs are unchanged. So no fixture needed re-decoding,
and the `isError` text for every failure is the same as before.

| Seam                                                        | Before | After | Change                                                                                                    |
| ----------------------------------------------------------- | ------ | ----- | --------------------------------------------------------------------------------------------------------- |
| MCP call outcome → fabric failure                           | 63     | 58    | seven transport/protocol arms become `evidence × effect`; a never-sent reservation is `Explain` (TH-4)    |
| Dynamic mounting from `tools/list`                          | 41     | 41    | `tool.input_contract` replaces render-to-text and re-parse; same count after `gleam format` (TH-6)        |
| Typed mounting from a Relay definition                      | 24     | 24    | `tool.name`/`input_codec`/`declaration`; `let assert Some` on the now-optional output codec               |
| Relay cancellation → fabric cancellation                    | 11     | 11    | unchanged: `tool.cancelled` fires, but the HTTP worker is killed in the same step (TH-3)                  |
| Cancelling one MCP call / on timeout                        | n/a    | 0     | `client.with_cancellation` and the client timeout close that call's connection (TH-2)                     |
| `notifications/cancelled` test probe                        | 23     | 6     | `relay/testing.request` plus `http.handle`; the test's second http_gun client is gone                     |
| fabric run → MCP result                                     | 22     | 48    | `render` drops the run-id lookup; `tool_error` adds the outcome as `structuredContent` (TH-9, capability) |
| Telemetry correlation (agent per question, link, follow)    | ~35    | ~35   | the same code now joins http_gun, llm_wire and relay; the correlation comes from Relay's request (TH-7)   |
| Relay telemetry handlers                                    | 7      | 8     | new `client_call_event`; each record names the server (`listener`) and the tool                           |
| `src/tool_hub_ffi.erl` (stop the scripted provider quietly) | 0      | 10    | restored: wave 3 deleted it while `scripted_llm.stop` still called it (see below)                         |

Net source diff: src +328 −224 plus the restored 10-line FFI file, and
test +208 −134. The relay call sites are
about as long as before. What wave 4 bought is correct behavior with less
reasoning: `client.call` returns `Result` with an `Evidence`, `tool.define`
needs no `let assert`, and both servers are `server.new(..) |> http.new |>
http.with_label(..) |> http.start`.

Seams that still need glue, and who owns them:

- The Relay ↔ fabric adapter (123 lines): fabric, in wave 5 (FABRIC-R10,
  TH-5).
- The cancellation bridge (11 lines): relay must keep a disconnected
  request's runtime alive until its cancelled workers exit or their grace
  ends; fabric must offer a selector for a run's status, so a handler can
  wait on the run and on `tool.cancelled` without a second process (TH-3).
- The per-question agent and the run ↔ correlation `Link` (~35 lines):
  fabric, which has to carry a correlation on its events or pass the run to
  the model function (TH-7).
- The inventory server's relay events (17 unjoined): relay. The client's
  correlation does not cross the wire, and `ExchangeClosedMeta` has no
  correlation field (TH-7).

`testing.events_for` does not apply. The app's provider speaks llm_wire's
scripted wire (`testing.config()`), which `events_for` returns unchanged,
and no SSE in the app was ever hand-written. `scripted_llm.respond` still
re-implements the now-private `testing.http_reply` (8 lines) to serve a
`Reply` from mist; a public `testing.body(reply) -> #(Int, String)` would
remove that.

**Status (round 6):** resolved by llm_wire 36c341c. `respond` now reads
`testing.status(reply)` and `testing.chunks(reply)` (no re-implemented
lowering), and the held stream takes its first event from
`testing.chunks(testing.text(..))`. `Reply` and `ScriptedCall` are opaque, so
the app builds them with `testing.tool_call(id:, name:, arguments_json:)` and
`testing.http_status(message.Custom("scripted"), 500, ..)`; the other 19
`testing.*` call sites (`text`, `tool_calls`) compiled unchanged.

New friction:

- **`tool.cancelled` is useless over HTTP (relay, major).** This is the
  TH-3 defect: the selector fires and the worker dies at once, so the
  documented "stop work you started elsewhere" path does not work for the
  transport most apps use. Before the trial run showed it, nothing
  suggested this. The guide's example
  (`process.selector_receive(tool.cancelled(call) |> await(run), ..)`) would
  silently leak the run.

  **Status (wave 4 fixes):** resolved in relay 6a75b6b and 0b7dfea (local,
  not pushed). The 11-line monitor bridge is gone. `ask` takes
  `relay_tool.cancelled(call)`, and `await_or_cancel`
  (src/tool_hub/assistant.gleam:167-195) selects on it and on the run's
  answer. On the signal it calls `fabric.cancel` inside the grace and the
  handler returns `Cancelled`. The test
  `disconnecting_mcp_client_cancels_run_and_model_stream_test` is unchanged
  and passes without the bridge: the run ends `Cancelled` and the provider
  stream closes. So do the other three cancellation tests; the negative
  test (`cancel_with_caller: False`) still leaves the run going. `fabric.await`
  still has no selector, so a waiter process is still needed: the handler
  cannot select on `tool.cancelled` while blocked in `await`. That makes
  `await_or_cancel` 29 lines (9 are the waiter), plus 4 to gate it on
  `cancel_with_caller`, against 11 for the bridge, so the glue grew in
  lines though it no longer works around a defect. A selector for a run's
  status in fabric would cut it to about 12 (owner: fabric). One trap: the
  waiter must be `spawn_unlinked`. A linked waiter that the handler kills
  after the signal takes the handler down with it (exit reason `killed`),
  before `fabric.cancel` runs. The suite is faster: 14 tests in about 15 s
  (15.4, 14.9, 15.0 s) against about 29 s, because `client.close` no longer
  drains for 5 s per in-flight call.

- **`client.close` waits about 5 s per in-flight call (relay).** The three
  tests that close a client mid-call spend 15 s of the 29 s suite in
  `http_gun.stop`'s drain. The `[relay, client, call]` event then reports
  `CallFailed in 5497 ms`, which counts the drain as the call's duration.
- **The Relay client's correlation is local (relay).** `with_correlation`
  tags the client's events and its HTTP Gun view, but no header or `_meta`
  key carries it. The receiving server must invent its own correlation
  (`http.with_correlation`), so a call cannot be followed across two Relay
  peers even inside one VM.
- **A latent wave 3 bug surfaced.** Wave 3 deleted `src/tool_hub_ffi.erl`
  ("nothing else used it"), but `scripted_llm.stop` calls
  `tool_hub_ffi:stop_process`. The suite kept passing only because the old
  `.beam` stayed in `build/`. A clean build would have crashed every
  `tool_hub.stop`. Gleam does not check `@external` targets at compile
  time, so no tool caught it. The file is restored.
- **Relay's HTTP Gun events now join without effort, but read as noise.**
  The agent's Relay client runs on HTTP Gun under the client's label
  (`inventory_peer`). Its lifecycle events join the run through the view
  correlation, so http_gun's joined count rose from 24 to 42. That is
  correct, but a reader of the trail now needs the label to tell model
  traffic from MCP traffic.
- **fabric still takes milliseconds.** `fabric.await(run, within: Int)` is
  the only millisecond conversion left in the app
  (`duration.to_milliseconds(assistant.budget)`); fabric owns it.

  **Status (round 5):** resolved. `fabric.await` and `await_with` take a
  `Duration`, and the app has no millisecond conversion left.

### After round 5

Package heads: fabric fd60851/409f1a7 (local, not pushed); the others are
unchanged from wave 4. 14 tests pass, three runs in a row, 14.4, 14.2 and
14.4 s (15.0 s before). `gleam run` prints the same trail. `gleam format`
is clean.

| Seam                                                    | Before | After | Change                                                                                                   |
| ------------------------------------------------------- | ------ | ----- | -------------------------------------------------------------------------------------------------------- |
| Waiter and selector for cancel (`await_or_cancel`)      | 33     | 0     | `fabric.await_with(.., or: relay_tool.cancelled(call))`; the `case` in `ask` is 5 lines longer (TH-3)    |
| Agent per question (`agent_for`)                        | 18     | 0     | `build_agent` runs once in `tool_hub.start` (11 lines); `Assistant` holds `agent` instead of four fields |
| Run ↔ correlation link (`Link`, `link`, `follow` table) | ~35    | 0     | the correlation goes to `fabric.start`; fabric's events carry it; `follow` reads it from `run.start`     |
| Correlated inventory client per question                | 3      | 0     | `Context` is shared; `remote_tools.inbound` reads `call.correlation` per call (8 lines, two call sites)  |
| `fabric.await` milliseconds                             | 1      | 0     | `within: assistant.budget` (a `Duration`); the test's `await(handle, 2000)` is `duration.seconds(2)`     |

Lines: src +102 −143 (net −41), test +3 −5. The cancellation glue and the
correlation glue are the two things that shrank. The test changes are the
`RunKey` pattern, `hub.assistant.agent` in place of `agent_for` and a
`Duration`.

Remaining unattributed events for the demo question: **17 relay events**
(unchanged), and 8 http_gun events that the old count did not report.

- 12 relay events are the inventory server's: `request.admitted`,
  `invocation.started`, `invocation.completed`, `exchange.closed` for each of
  the three calls. The agent's Relay client carries the question's
  correlation, but a client's correlation does not cross the wire, so the
  server invents none of its own (it has no `http.with_correlation` here).
  `tool.Call.correlation` made the _client-side_ events join (the three
  `client.call` records and their http_gun traffic), not these.
- 5 relay events are the external caller's: its `tools/list` request, that
  exchange's `exchange.closed`, the `ask_assistant` `exchange.closed` (the
  closed-exchange metadata has no correlation field) and the two
  `client.call` records of the `assistant_caller` client, which runs outside
  the question.
- The 8 http_gun events belong to `assistant_caller`'s two requests. They are
  outside the question by design; earlier rounds counted only relay and
  llm_wire among the unjoined.

Neither remaining gap is fixable in the app. Relay owns both: it has to
carry the client's correlation to the server (or let the inventory server
derive one from a header) and put a correlation on `ExchangeClosedMeta`.

New friction:

- **No caller run id here.** The brief's idempotent start does not apply:
  `ask` is a request, not a job. Relay does not give a handler its invocation
  id (`HandlerCallContext`), and a retried `tools/call` arrives as a new POST
  with a new correlation, so `run.new_id()` is the only honest id and a
  client retry starts a second run. If Relay exposed the request's
  idempotency key or invocation id, `run.parse_id` could derive the run id
  from it and a retry would find `AlreadyStarted`.
- **`follow` still takes the run id.** `Answer.run_id` is the only handle an
  MCP client has, so the telemetry join keeps one lookup: find the
  correlation on the run's events, then join everything under it. That is
  four lines, but it means the answer does not carry the correlation. Putting
  the correlation in `Answer` would be an output-schema change for a
  diagnostic, so it was not done.
- **`await_with` leaves a dead branch.** With `cancel_with_caller: False`
  the selector is empty and `Interrupted(Nil)` cannot arrive, yet the type
  still demands the arm. That is what `process.new_selector()` costs; a
  `Never`-typed variant would be exact but is not worth a second function.
- **`Assistant` lost its model fields, and `tool_hub.start` gained them.**
  Building the agent once moves the provider client, settings, model id and
  tools from the record into `start`. The test helper `cancelled_run` reopens
  a run with `hub.assistant.agent`, so the agent is now a public field of the
  record rather than something the caller can rebuild.
- **`remote_tools.inbound` is needed twice.** The typed and the discovered
  mount both wrap the peer with `call.correlation`. A fabric helper that
  applied the call's correlation to any package's handle would not help, as
  each package has its own `with_correlation`; the 8 lines stay in the app.
- **The suite is slightly faster** (14.3 s against 15.0 s). The drain in
  `client.close` (about 5 s per in-flight call) still dominates.

### After wave 5

Package heads: fabric and `fabric_relay` (local wave 5), relay b83486b,
llm_wire 2c32d5e. 15 tests pass (14 before: the `cancel_with_caller: False`
negative test became `keyed_call_outlives_its_disconnect_test`, and
`retried_keyed_call_reaches_the_same_run_test` is new), three runs in a row,
about 17 s each with the `nix develop` start. `gleam format --check` and
`gleam build --warnings-as-errors` are clean; `gleam run` prints the trail.

| Seam                                                       | Before | After | Change                                                    |
| ---------------------------------------------------------- | ------ | ----- | --------------------------------------------------------- |
| `remote_tools.gleam` (mount, discover, classify)           | 204    | 0     | `fabric_relay.tool`, `discover`                           |
| `assistant.gleam` (`ask`, `render`, `tool_error`)          | 233    | 114   | `fabric_relay.serve` + `with_wait` + `agent.with_answer`  |
| `lazy_unwrap`, `with_correlation(Some(unique))`            | 2      | 0     | `tool.correlation` is a `Correlation`; the builder hid it |
| `Settings.cancel_with_caller`, `AskError`, `Answer.run_id` | 6      | 0     | the key rule; typed `Answer`                              |

Lines: src +74 −398 (net −324), test +128 −48 (new assertions on the joined
relay events, two keyed-call tests, JSON final replies). The scripted
provider gained `scripted_llm.answer` (6 lines): its final replies must be
the answer's JSON now. Telemetry changed by its import and by
`follow(telemetry, correlation)`.

Unattributed events per question: **0** (17 relay before). The only
unjoined relay events in `gleam run` are the 3 of the caller's `tools/list`.

Remaining gaps:

- **`working` returns after `with_wait` (default 25 s; here `budget`).** The
  wait must stay below Relay's invocation timeout (30 s) by hand; the app's
  `budget` setting has no guard for that and `with_wait` only checks its own
  range.

New friction in the new APIs:

- **The typed answer is a wrapper here.** The agent's answer is prose, but
  `with_answer` needs an object schema for OpenAI and Anthropic, so `Answer`
  is `{"answer": string}`, every scripted final reply is JSON, and a model
  that answers in prose gets a corrective turn and then `AnswerInvalid`. The
  guide says so for the root type, but nothing says that this also doubles a
  failing scripted run's model calls (`with_answer_attempts`).
- **`invocation.cancelled` for a keyed call.** Relay still emits it when the
  caller disconnects, though the run goes on; the event reads as the call's
  end, so a trail reader sees `invocation.cancelled` and no `run.cancel`. It is
  correct, but it needs the key to be read.
- **The error wording is the library's.** `the MCP call failed: ...` replaced
  the app's `the inventory is unavailable`. It is generic by design; an app
  that wants the peer named has no hook short of its own `tool.bind`.

#### Catch-up: fabric F6 and relay ca38f75

`fabric_relay.service(ask_assistant(), runs:, agent:, start:) |> serve` and
relay's plain `Correlation` compile with small edits (`assistant.serve` is 3
lines shorter; `start` is one expression). 15 tests pass twice in a row,
format and `--warnings-as-errors` are clean, `gleam run` prints the same
trail (0 unjoined for the question, 3 for the caller's `tools/list`).

Resolved friction (struck from the list above):

- **The `start:` annotation is gone.** The definition comes first, so
  `fn(_, question) { question.question }` infers. Resolved.
- **`start`'s constant principal and its `Ok` are gone.** `fabric_relay.start(context,
prompt:)` is the whole closure; the principal is `anonymous`, which suits
  this single-client app (the test reads the keyed run with
  `fabric_relay.anonymous`). Resolved.
- **A success names its run.** The result's text block carries
  `io.github.gleam-dream/run-id` in `_meta`; the common path test reads it
  and matches the run from telemetry. Replaces the lost `Answer.run_id`.
- **Relay's `correlation` is a `Correlation`.** The seven relay handlers
  use `CorrelationKey(m.correlation)`; `InvocationKey` and the `key_of`
  fallback for relay are deleted (`key_of` stays for http_gun and llm_wire,
  which still type it `Option`; `ExchangeKey` stays for `frame.rejected`).
- **A keyed run nobody retries** is bounded by the agent's limits and the
  7-day approval expiry, as `serve` now documents (a run held for an
  uncertain effect waits for a person, by design).

New:

- **`_meta` is read by key.** The run id is one `list.key_find` on a text
  block with the string `"io.github.gleam-dream/run-id"`; fabric_relay
  exports no accessor (the constant `run_id_meta` is private) and relay's
  client result has no helper for a block's `_meta`. A
  `fabric_relay.run_id_of(blocks)` would remove a string the caller must
  copy.
- **The remaining gaps are unchanged:** `working`, `timed_out`, `key_reused`
  and `awaiting_approval` are untested here; the `with_wait` against Relay's
  30 s invocation timeout still needs a manual check.

#### Catch-up: fabric 3d4b840 and llm_wire 36c341c (round 6)

Two edits, three lines of app code each at most. `fabric_relay.serve` returns
`Result(Tool, List(ConfigError))`, so `assistant.serve` maps the error with
`fabric_relay.describe_config_errors` into its existing `String` error
(`with_wait` only stores; `budget` is range-checked there now). The opaque
`Reply` replaced the `ScriptedCall` constructor, the `Status(500, ..)` reply
and the three-way `case` in `scripted_llm.respond` (now two accessors).
15 tests pass, format and `--warnings-as-errors` are clean, `gleam run`
prints the same trail.

New friction:

- **A scripted HTTP status needs a provider name.** `testing.http_status`
  takes a `message.Custom("scripted")` provider even though the app's reply
  is only the "script exhausted" 500; one more import (`llm_wire/message`)
  for a value the scripted wire ignores.
- **`serve`'s error has no home in this app's `String` errors.** The
  `with_wait` range is now reported at `serve` and the app's `budget` still
  has no guard against Relay's 30 s invocation timeout (unchanged gap).
