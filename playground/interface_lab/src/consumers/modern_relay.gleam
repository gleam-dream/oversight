// THROWAWAY: Can Relay route a parsed modern MCP request through protected tools?
import lab/blueprint
import lab/relay
import lab/relay_authorization as authorization
import lab/relay_exchange as exchange
import lab/relay_protocol_2026 as protocol
import lab/relay_server_2026 as modern
import lab/value.{type Value}

pub type AppContext {
  AppContext(
    tenant: String,
    private_visible: Bool,
    private_allowed: Bool,
    panic_on_policy: Bool,
  )
}

type Principal {
  Principal(String)
}

type Fixture {
  Fixture(
    server: modern.Server(AppContext, Principal),
    grant: authorization.GrantedRequest(Principal),
    tenant_a: AppContext,
    tenant_b: AppContext,
    private_hidden: AppContext,
    private_denied: AppContext,
  )
}

type Maybe(a) {
  NoValue
  Some(a)
}

// The probe covers modern discovery, authorization-filtered listing, typed
// dispatch, per-exchange stream ownership, and request/response classification.
pub fn probe() -> Nil {
  let fixture = fixture()
  let Fixture(server, grant, tenant_a, tenant_b, private_hidden, private_denied) =
    fixture

  let #(after_discover, discovery) =
    immediate(
      server,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      discover_message(value.Text("discover")),
    )
  let discover_result = required_field(discovery, "result")
  let assert value.Text("complete") =
    required_field(discover_result, "resultType")
  let assert value.Int(0) = required_field(discover_result, "ttlMs")
  let assert value.Text("private") =
    required_field(discover_result, "cacheScope")
  let assert value.Array([value.Text("2026-07-28")]) =
    required_field(discover_result, "supportedVersions")

  let list_exchange = exchange.fresh_exchange()
  let #(after_list, listing) =
    immediate(
      after_discover,
      list_exchange,
      tenant_a,
      grant,
      list_message(
        value.Text("list"),
        metadata_with_capabilities(
          "2026-07-28",
          object([
            #("roots", object([])),
            #("sampling", object([#("tools", object([]))])),
          ]),
          [
            #(
              "io.modelcontextprotocol/clientInfo",
              object([
                #("name", value.Text("probe-client")),
                #("version", value.Text("1")),
              ]),
            ),
            #("io.modelcontextprotocol/logLevel", value.Text("debug")),
          ],
        ),
        [],
      ),
    )
  let list_result = required_field(listing, "result")
  let assert value.Text("complete") = required_field(list_result, "resultType")
  let assert value.Int(0) = required_field(list_result, "ttlMs")
  let tools = required_field(list_result, "tools")
  let assert True = has_tool(tools, "echo")
  let assert True = has_tool(tools, "fail")
  let assert False = has_tool(tools, "vault-read")

  // A duplicate list request cannot run even its visibility policy.
  let panic_policy = AppContext("tenant-a", False, False, True)
  let #(after_list_replay, no_second_list) =
    modern.step(
      after_list,
      modern.RequestReceived(
        list_exchange,
        panic_policy,
        grant,
        list_message(
          value.Text("duplicate-list"),
          metadata("2026-07-28", []),
          [],
        ),
      ),
    )
  let assert [] = no_second_list

  // Two exchanges deliberately reuse both caller-owned wire identifiers.
  let #(after_call_a, exchange_a, invocation_a) =
    start_call(
      fixture,
      after_list_replay,
      tenant_a,
      "shared-id",
      "echo",
      object([#("input", value.Text("first"))]),
      exchange.Present(exchange.ProgressString("shared-progress")),
      [
        #("io.example/trace", value.Text("trace-a")),
        #(
          "io.modelcontextprotocol/clientInfo",
          object([
            #("name", value.Text("probe-client")),
            #("version", value.Text("1")),
          ]),
        ),
        #("io.modelcontextprotocol/logLevel", value.Text("debug")),
      ],
    )
  let assert exchange.Present(value.Text("trace-a")) =
    protocol.metadata_extension(
      modern.invocation_metadata(invocation_a),
      "io.example/trace",
    )
  let expected_client_info =
    object([
      #("name", value.Text("probe-client")),
      #("version", value.Text("1")),
    ])
  let assert exchange.Present(expected_client_info) =
    protocol.metadata_extension(
      modern.invocation_metadata(invocation_a),
      "io.modelcontextprotocol/clientInfo",
    )
  let #(after_call_b, exchange_b, invocation_b) =
    start_call(
      fixture,
      after_call_a,
      tenant_b,
      "shared-id",
      "echo",
      object([#("input", value.Text("second"))]),
      exchange.Present(exchange.ProgressString("shared-progress")),
      [],
    )
  let assert True =
    modern.invocation_id(invocation_a) != modern.invocation_id(invocation_b)

  let #(after_progress_a, progress_a) =
    modern.step(
      after_call_b,
      modern.ToolProgress(modern.invocation_id(invocation_a), 0),
    )
  let assert [modern.SendProgress(sent_exchange_a, progress_body_a)] =
    progress_a
  let assert True = sent_exchange_a == exchange_a
  let assert value.Text("shared-progress") =
    nested_field(progress_body_a, ["params", "progressToken"])
  let #(after_progress_b, progress_b) =
    modern.step(
      after_progress_a,
      modern.ToolProgress(modern.invocation_id(invocation_b), 0),
    )
  let assert [modern.SendProgress(sent_exchange_b, _)] = progress_b
  let assert True = sent_exchange_b == exchange_b

  let #(after_close_a, cancelled_a) =
    modern.step(after_progress_b, modern.ResponseStreamClosed(exchange_a))
  let assert [
    modern.CancelInvocation(cancelled_id),
    modern.CloseResponseStream(closed_exchange),
  ] = cancelled_a
  let assert True = cancelled_id == modern.invocation_id(invocation_a)
  let assert True = closed_exchange == exchange_a
  let #(after_late_a, late_a) =
    modern.step(after_close_a, modern.perform(invocation_a))
  let assert [] = late_a
  let #(after_late_progress, late_progress) =
    modern.step(
      after_late_a,
      modern.ToolProgress(modern.invocation_id(invocation_a), 1),
    )
  let assert [] = late_progress
  let #(after_b_complete, complete_b) =
    modern.step(after_late_progress, modern.perform(invocation_b))
  let assert [
    modern.Response(response_exchange_b, response_b),
    modern.CloseResponseStream(_),
  ] = complete_b
  let assert True = response_exchange_b == exchange_b
  let assert value.Text("tenant-b:second") =
    nested_field(response_b, ["result", "structuredContent"])
  let #(after_b_replay, no_second_response) =
    modern.step(after_b_complete, modern.perform(invocation_b))
  let assert [] = no_second_response

  // A typed business error is a successful JSON-RPC call with isError=true.
  let #(after_business_failure, business_response) =
    completed_call(
      fixture,
      after_b_replay,
      tenant_a,
      "business-failure",
      "fail",
      object([#("input", value.Text("x"))]),
      exchange.Absent,
      [],
    )
  let business_result = required_field(business_response, "result")
  let assert value.Text("complete") =
    required_field(business_result, "resultType")
  let assert value.Bool(True) = required_field(business_result, "isError")
  let assert value.Text("expected-business-failure") =
    required_field(business_result, "structuredContent")

  // Invalid typed arguments also stay in CallToolResult rather than becoming
  // a JSON-RPC error response.
  let #(after_invalid_arguments, invalid_arguments_response) =
    completed_call(
      fixture,
      after_business_failure,
      tenant_a,
      "bad-arguments",
      "echo",
      object([]),
      exchange.Absent,
      [],
    )
  let invalid_arguments_result =
    required_field(invalid_arguments_response, "result")
  let assert value.Bool(True) =
    required_field(invalid_arguments_result, "isError")
  let assert value.Text("complete") =
    required_field(invalid_arguments_result, "resultType")
  let missing_arguments_exchange = exchange.fresh_exchange()
  let missing_arguments_request =
    request(
      value.Text("missing-arguments"),
      "tools/call",
      params_with_meta_and_fields(metadata("2026-07-28", []), [
        #("name", value.Text("echo")),
      ]),
    )
  let #(missing_arguments_started, missing_arguments_effects) =
    modern.step(
      after_invalid_arguments,
      modern.RequestReceived(
        missing_arguments_exchange,
        tenant_a,
        grant,
        missing_arguments_request,
      ),
    )
  let assert [
    modern.OpenResponseStream(_),
    modern.Invoke(missing_arguments_invocation),
  ] = missing_arguments_effects
  let #(after_missing_arguments, missing_arguments_completion) =
    modern.step(
      missing_arguments_started,
      modern.perform(missing_arguments_invocation),
    )
  let assert [
    modern.Response(_, missing_arguments_response),
    modern.CloseResponseStream(_),
  ] = missing_arguments_completion
  let assert value.Bool(True) =
    nested_field(missing_arguments_response, ["result", "isError"])

  // Hidden, denied, and unknown names share the same external error. The
  // private decoder and handler are panic sentinels and must remain untouched.
  let #(after_hidden, hidden_response) =
    completed_call(
      fixture,
      after_missing_arguments,
      private_hidden,
      "same-error-id",
      "vault-read",
      object([#("input", value.Text("secret"))]),
      exchange.Absent,
      [],
    )
  let #(after_denied, denied_response) =
    completed_call(
      fixture,
      after_hidden,
      private_denied,
      "same-error-id",
      "vault-read",
      object([#("input", value.Text("secret"))]),
      exchange.Absent,
      [],
    )
  let #(after_unknown, unknown_response) =
    completed_call(
      fixture,
      after_denied,
      tenant_a,
      "same-error-id",
      "does-not-exist",
      object([#("input", value.Text("secret"))]),
      exchange.Absent,
      [],
    )
  let assert True = hidden_response == denied_response
  let assert True = hidden_response == unknown_response

  // Admission rejects malformed protocol data before creating an invocation.
  let #(after_unsupported, unsupported) =
    immediate(
      after_unknown,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      discover_message_with_version(value.Text("unsupported"), "2025-11-25"),
    )
  let unsupported_error = required_field(unsupported, "error")
  let assert value.Int(-32_022) = required_field(unsupported_error, "code")
  let assert value.Array([value.Text("2026-07-28")]) =
    required_field(required_field(unsupported_error, "data"), "supported")
  let #(after_missing_meta, missing_meta) =
    immediate(
      after_unsupported,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      request(value.Text("missing-meta"), "server/discover", object([])),
    )
  let assert value.Int(-32_602) = nested_field(missing_meta, ["error", "code"])
  let duplicate_params =
    object([
      #("_meta", metadata("2026-07-28", [])),
      #("name", value.Text("echo")),
      #("arguments", object([])),
      #("name", value.Text("fail")),
    ])
  let #(after_duplicate, duplicate_response) =
    immediate(
      after_missing_meta,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      request(value.Text("duplicate"), "tools/call", duplicate_params),
    )
  let assert value.Int(-32_602) =
    nested_field(duplicate_response, ["error", "code"])
  let bad_capabilities =
    metadata_with_capabilities(
      "2026-07-28",
      object([#("roots", value.Bool(False))]),
      [],
    )
  let #(after_bad_capabilities, capabilities_response) =
    immediate(
      after_duplicate,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      request(
        value.Text("bad-capabilities"),
        "server/discover",
        params_with_meta(bad_capabilities),
      ),
    )
  let assert value.Int(-32_602) =
    nested_field(capabilities_response, ["error", "code"])
  let unsupported_continuation =
    object([
      #("_meta", metadata("2026-07-28", [])),
      #("name", value.Text("echo")),
      #("arguments", object([#("input", value.Text("x"))])),
      #("requestState", value.Text("resume")),
    ])
  let #(after_continuation, continuation_response) =
    immediate(
      after_bad_capabilities,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      request(
        value.Text("continuation"),
        "tools/call",
        unsupported_continuation,
      ),
    )
  let assert value.Int(-32_602) =
    nested_field(continuation_response, ["error", "code"])
  let #(after_unknown_method, unknown_method_response) =
    immediate(
      after_continuation,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      request(
        value.Text("unknown-method"),
        "sampling/createMessage",
        object([]),
      ),
    )
  let assert value.Int(-32_601) =
    nested_field(unknown_method_response, ["error", "code"])
  let #(after_cursor, cursor_response) =
    immediate(
      after_unknown_method,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      list_message(
        value.Text("unsupported-cursor"),
        metadata("2026-07-28", []),
        [#("cursor", value.Text("page-2"))],
      ),
    )
  let assert value.Int(-32_602) =
    nested_field(cursor_response, ["error", "code"])
  let bad_client_info =
    metadata("2026-07-28", [
      #("io.modelcontextprotocol/clientInfo", value.Bool(False)),
    ])
  let #(after_bad_client_info, client_info_response) =
    immediate(
      after_cursor,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      request(
        value.Text("bad-client-info"),
        "server/discover",
        params_with_meta(bad_client_info),
      ),
    )
  let assert value.Int(-32_602) =
    nested_field(client_info_response, ["error", "code"])
  let bad_log_level =
    metadata("2026-07-28", [
      #("io.modelcontextprotocol/logLevel", value.Text("verbose")),
    ])
  let #(after_bad_log_level, log_level_response) =
    immediate(
      after_bad_client_info,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      request(
        value.Text("bad-log-level"),
        "server/discover",
        params_with_meta(bad_log_level),
      ),
    )
  let assert value.Int(-32_602) =
    nested_field(log_level_response, ["error", "code"])
  let unsupported_input_responses =
    object([
      #("_meta", metadata("2026-07-28", [])),
      #("name", value.Text("echo")),
      #("arguments", object([#("input", value.Text("x"))])),
      #("inputResponses", object([])),
    ])
  let #(after_input_responses, input_responses_response) =
    immediate(
      after_bad_log_level,
      exchange.fresh_exchange(),
      tenant_a,
      grant,
      request(
        value.Text("input-responses"),
        "tools/call",
        unsupported_input_responses,
      ),
    )
  let assert value.Int(-32_602) =
    nested_field(input_responses_response, ["error", "code"])
  // Valid notifications and valid incoming responses are non-wire outcomes.
  let notification_exchange = exchange.fresh_exchange()
  let notification =
    object([
      #("jsonrpc", value.Text("2.0")),
      #("method", value.Text("notifications/cancelled")),
      #("params", object([#("requestId", value.Text("unhandled"))])),
    ])
  let #(after_notification, notification_effects) =
    modern.step(
      after_input_responses,
      modern.RequestReceived(
        notification_exchange,
        tenant_a,
        grant,
        notification,
      ),
    )
  let assert [
    modern.UnhandledMessage(
      unhandled_exchange,
      protocol.UnsupportedNotificationReason,
    ),
  ] = notification_effects
  let assert True = unhandled_exchange == notification_exchange
  let #(after_notification_replay, no_notification_response) =
    modern.step(
      after_notification,
      modern.RequestReceived(
        notification_exchange,
        tenant_a,
        grant,
        discover_message(value.Text("replay")),
      ),
    )
  let assert [] = no_notification_response
  let response_exchange = exchange.fresh_exchange()
  let incoming_response =
    object([
      #("jsonrpc", value.Text("2.0")),
      #("id", value.Text("server-originated")),
      #("result", object([#("resultType", value.Text("complete"))])),
    ])
  let #(after_response_message, response_message_effects) =
    modern.step(
      after_notification_replay,
      modern.RequestReceived(
        response_exchange,
        tenant_a,
        grant,
        incoming_response,
      ),
    )
  let assert [
    modern.UnhandledMessage(
      response_exchange_out,
      protocol.UnexpectedResponseReason,
    ),
  ] = response_message_effects
  let assert True = response_exchange_out == response_exchange
  let error_exchange = exchange.fresh_exchange()
  let incoming_error =
    object([
      #("jsonrpc", value.Text("2.0")),
      #("id", value.Int(42)),
      #(
        "error",
        object([
          #("code", value.Int(-32_000)),
          #("message", value.Text("remote failure")),
        ]),
      ),
    ])
  let #(after_incoming_error, incoming_error_effects) =
    modern.step(
      after_response_message,
      modern.RequestReceived(error_exchange, tenant_a, grant, incoming_error),
    )
  let assert [
    modern.UnhandledMessage(
      error_exchange_out,
      protocol.UnexpectedResponseReason,
    ),
  ] = incoming_error_effects
  let assert True = error_exchange_out == error_exchange
  let malformed_response =
    object([
      #("jsonrpc", value.Text("2.0")),
      #("result", value.Int(7)),
    ])
  let #(after_malformed_response, malformed_response_effects) =
    modern.step(
      after_incoming_error,
      modern.RequestReceived(
        exchange.fresh_exchange(),
        tenant_a,
        grant,
        malformed_response,
      ),
    )
  let assert [modern.Response(_, invalid_response)] = malformed_response_effects
  let assert value.Int(-32_600) =
    nested_field(invalid_response, ["error", "code"])
  let malformed_result_object =
    object([
      #("jsonrpc", value.Text("2.0")),
      #("id", value.Int(8)),
      #("result", object([])),
    ])
  let #(after_malformed_result_object, malformed_result_effects) =
    modern.step(
      after_malformed_response,
      modern.RequestReceived(
        exchange.fresh_exchange(),
        tenant_a,
        grant,
        malformed_result_object,
      ),
    )
  let assert [modern.Response(_, invalid_result_object)] =
    malformed_result_effects
  let assert value.Int(-32_600) =
    nested_field(invalid_result_object, ["error", "code"])

  // Every exchange owns exactly one request outcome, including immediate ones.
  let immediate_exchange = exchange.fresh_exchange()
  let #(after_first_immediate, first_immediate) =
    immediate(
      after_malformed_result_object,
      immediate_exchange,
      tenant_a,
      grant,
      discover_message(value.Text("once")),
    )
  let assert value.Text("2.0") = required_field(first_immediate, "jsonrpc")
  let #(after_duplicate_immediate, no_duplicate_immediate) =
    modern.step(
      after_first_immediate,
      modern.RequestReceived(
        immediate_exchange,
        tenant_a,
        grant,
        discover_message(value.Text("twice")),
      ),
    )
  let assert [] = no_duplicate_immediate
  let #(after_immediate_then_call, no_call_after_immediate) =
    modern.step(
      after_duplicate_immediate,
      modern.RequestReceived(
        immediate_exchange,
        tenant_a,
        grant,
        call_message(
          value.Text("same-exchange"),
          "echo",
          object([#("input", value.Text("late"))]),
          exchange.Absent,
          [],
        ),
      ),
    )
  let assert [] = no_call_after_immediate

  let call_first_exchange = exchange.fresh_exchange()
  let #(after_call_first, call_first_effects) =
    modern.step(
      after_immediate_then_call,
      modern.RequestReceived(
        call_first_exchange,
        tenant_a,
        grant,
        call_message(
          value.Text("call-first"),
          "echo",
          object([#("input", value.Text("first"))]),
          exchange.Absent,
          [],
        ),
      ),
    )
  let assert [modern.OpenResponseStream(_), modern.Invoke(call_first_task)] =
    call_first_effects
  let #(after_call_then_immediate, no_immediate_after_call) =
    modern.step(
      after_call_first,
      modern.RequestReceived(
        call_first_exchange,
        tenant_a,
        grant,
        discover_message(value.Text("same-exchange")),
      ),
    )
  let assert [] = no_immediate_after_call
  let #(after_call_first_complete, call_first_completion) =
    modern.step(after_call_then_immediate, modern.perform(call_first_task))
  let assert [modern.Response(_, _), modern.CloseResponseStream(_)] =
    call_first_completion

  let closed_exchange = exchange.fresh_exchange()
  let #(after_early_close, no_close_effect) =
    modern.step(
      after_call_first_complete,
      modern.ResponseStreamClosed(closed_exchange),
    )
  let assert [] = no_close_effect
  let #(after_close_then_discover, no_response_after_close) =
    modern.step(
      after_early_close,
      modern.RequestReceived(
        closed_exchange,
        tenant_a,
        grant,
        discover_message(value.Text("closed")),
      ),
    )
  let assert [] = no_response_after_close
  let _ = after_close_then_discover
  Nil
}

// These are encoded responses returned by the server façade, not hand-written
// schema fixtures. The JSON Schema oracle checks these values independently.
pub fn wire_examples() -> List(#(String, String, Value)) {
  let fixture = fixture()
  let Fixture(server, grant, tenant, _, _, _) = fixture
  let #(after_discover, discovery) =
    immediate(
      server,
      exchange.fresh_exchange(),
      tenant,
      grant,
      discover_message(value.Text("schema-discover")),
    )
  let #(after_list, listing) =
    immediate(
      after_discover,
      exchange.fresh_exchange(),
      tenant,
      grant,
      list_message(value.Text("schema-list"), metadata("2026-07-28", []), []),
    )
  let #(after_success, success) =
    completed_call(
      fixture,
      after_list,
      tenant,
      "schema-success",
      "echo",
      object([#("input", value.Text("ok"))]),
      exchange.Absent,
      [],
    )
  let #(after_failure, failure) =
    completed_call(
      fixture,
      after_success,
      tenant,
      "schema-failure",
      "fail",
      object([#("input", value.Text("x"))]),
      exchange.Absent,
      [],
    )
  let #(_after_unsupported, unsupported) =
    immediate(
      after_failure,
      exchange.fresh_exchange(),
      tenant,
      grant,
      discover_message_with_version(
        value.Text("schema-unsupported"),
        "future-version",
      ),
    )
  [
    #("discover", "DiscoverResultResponse", discovery),
    #("list", "ListToolsResultResponse", listing),
    #("call-success", "CallToolResultResponse", success),
    #("call-tool-error", "CallToolResultResponse", failure),
    #("unsupported-version", "UnsupportedProtocolVersionError", unsupported),
  ]
}

fn fixture() -> Fixture {
  let assert Ok(resource) = authorization.resource("https://relay.example/mcp")
  let assert Ok(scope) = authorization.scope("tools:invoke")
  let principal = Principal("service-client")
  let config = authorization.protection_config(resource, [scope])
  let verifier =
    authorization.trust_verifier(
      authorization.VerifierDeclaration(
        "modern-relay-fixture",
        "test-1",
        authorization.TestOnlyVerifier,
      ),
      fn(_) {
        Ok(authorization.VerifierAttestation(principal, [resource], [scope]))
      },
    )
  let assert Ok(token) = authorization.bearer_token("fixture-token")
  let assert Ok(grant) = authorization.admit(verifier, token, config)

  let echo_tool =
    relay.context_tool(
      "echo",
      blueprint.field("input", blueprint.text()),
      blueprint.text(),
      blueprint.text(),
      fn(context, input) {
        let AppContext(tenant, _, _, _) = context
        Ok(tenant <> ":" <> input)
      },
    )
  let business_failure =
    relay.context_tool(
      "fail",
      blueprint.field("input", blueprint.text()),
      blueprint.text(),
      blueprint.text(),
      fn(_, _) { Error("expected-business-failure") },
    )
  let panic_input =
    blueprint.imap(
      blueprint.text(),
      fn(_) {
        todo as "hidden or denied calls must not decode private arguments"
      },
      fn(_) { "" },
    )
  let private_tool =
    relay.context_tool(
      "vault-read",
      blueprint.field("input", panic_input),
      blueprint.text(),
      blueprint.text(),
      fn(_, _) {
        todo as "hidden or denied calls must not invoke private handlers"
      },
    )
  let assert Ok(registry) =
    relay.registry([echo_tool, business_failure, private_tool])
  let protected =
    authorization.protect_registry(
      config,
      registry,
      authorization.tool_policy(
        fn(context, _, declaration) {
          let AppContext(_, _, _, panic_on_policy) = context
          case panic_on_policy {
            True ->
              todo as "duplicate exchange must skip application visibility policy"
            False ->
              case declaration {
                relay.Declaration("vault-read", _) -> {
                  let AppContext(_, visible, _, _) = context
                  case visible {
                    True -> authorization.Visible
                    False -> authorization.Hidden
                  }
                }
                _ -> authorization.Visible
              }
          }
        },
        fn(context, _, declaration) {
          let AppContext(_, _, _, panic_on_policy) = context
          case panic_on_policy {
            True ->
              todo as "duplicate exchange must skip application execution policy"
            False ->
              case declaration {
                relay.Declaration("vault-read", _) -> {
                  let AppContext(_, _, allowed, _) = context
                  case allowed {
                    True -> authorization.ExecutionAuthorized
                    False -> authorization.ExecutionUnauthorized
                  }
                }
                _ -> authorization.ExecutionAuthorized
              }
          }
        },
      ),
    )
  Fixture(
    modern.server(protected),
    grant,
    AppContext("tenant-a", False, False, False),
    AppContext("tenant-b", False, False, False),
    AppContext("tenant-a", False, False, False),
    AppContext("tenant-a", True, False, False),
  )
}

fn immediate(
  server: modern.Server(AppContext, Principal),
  exchange_id: exchange.ExchangeId,
  context: AppContext,
  grant: authorization.GrantedRequest(Principal),
  message: Value,
) -> #(modern.Server(AppContext, Principal), Value) {
  let #(next, effects) =
    modern.step(
      server,
      modern.RequestReceived(exchange_id, context, grant, message),
    )
  case effects {
    [modern.Response(response_exchange, body)] -> {
      let assert True = response_exchange == exchange_id
      #(next, body)
    }
    _ -> todo as "probe expected one immediate response effect"
  }
}

fn start_call(
  fixture: Fixture,
  server: modern.Server(AppContext, Principal),
  context: AppContext,
  request_id: String,
  name: String,
  arguments: Value,
  token: exchange.Optional(exchange.ProgressToken),
  extra_meta: List(#(String, Value)),
) -> #(
  modern.Server(AppContext, Principal),
  exchange.ExchangeId,
  modern.Invocation(AppContext, Principal),
) {
  let Fixture(_, grant, _, _, _, _) = fixture
  let exchange_id = exchange.fresh_exchange()
  let #(next, effects) =
    modern.step(
      server,
      modern.RequestReceived(
        exchange_id,
        context,
        grant,
        call_message(value.Text(request_id), name, arguments, token, extra_meta),
      ),
    )
  case effects {
    [modern.OpenResponseStream(opened), modern.Invoke(invocation)] -> {
      let assert True = opened == exchange_id
      #(next, exchange_id, invocation)
    }
    _ -> todo as "probe expected an admitted call and owned invocation"
  }
}

fn completed_call(
  fixture: Fixture,
  server: modern.Server(AppContext, Principal),
  context: AppContext,
  request_id: String,
  name: String,
  arguments: Value,
  token: exchange.Optional(exchange.ProgressToken),
  extra_meta: List(#(String, Value)),
) -> #(modern.Server(AppContext, Principal), Value) {
  let #(started, _, invocation) =
    start_call(
      fixture,
      server,
      context,
      request_id,
      name,
      arguments,
      token,
      extra_meta,
    )
  let #(finished, effects) = modern.step(started, modern.perform(invocation))
  case effects {
    [modern.Response(_, body), modern.CloseResponseStream(_)] -> #(
      finished,
      body,
    )
    _ -> todo as "probe expected one terminal response for the admitted call"
  }
}

fn discover_message(id: Value) -> Value {
  discover_message_with_version(id, "2026-07-28")
}

fn discover_message_with_version(id: Value, version: String) -> Value {
  request(id, "server/discover", params_with_meta(metadata(version, [])))
}

fn list_message(
  id: Value,
  meta: Value,
  other: List(#(String, Value)),
) -> Value {
  request(id, "tools/list", params_with_meta_and_fields(meta, other))
}

fn call_message(
  id: Value,
  name: String,
  arguments: Value,
  token: exchange.Optional(exchange.ProgressToken),
  other_meta: List(#(String, Value)),
) -> Value {
  let meta = metadata("2026-07-28", meta_fields(token, other_meta))
  request(
    id,
    "tools/call",
    params_with_meta_and_fields(meta, [
      #("name", value.Text(name)),
      #("arguments", arguments),
    ]),
  )
}

fn meta_fields(
  token: exchange.Optional(exchange.ProgressToken),
  extensions: List(#(String, Value)),
) -> List(#(String, Value)) {
  let token_fields = case token {
    exchange.Absent -> []
    exchange.Present(exchange.ProgressString(token)) -> [
      #("progressToken", value.Text(token)),
    ]
    exchange.Present(exchange.ProgressInteger(token)) -> [
      #("progressToken", value.Int(token)),
    ]
  }
  append(token_fields, extensions)
}

fn metadata(version: String, extensions: List(#(String, Value))) -> Value {
  metadata_with_capabilities(version, object([]), extensions)
}

fn metadata_with_capabilities(
  version: String,
  capabilities: Value,
  extensions: List(#(String, Value)),
) -> Value {
  object([
    #("io.modelcontextprotocol/protocolVersion", value.Text(version)),
    #("io.modelcontextprotocol/clientCapabilities", capabilities),
    ..extensions
  ])
}

fn params_with_meta(meta: Value) -> Value {
  object([#("_meta", meta)])
}

fn params_with_meta_and_fields(
  meta: Value,
  fields: List(#(String, Value)),
) -> Value {
  object([#("_meta", meta), ..fields])
}

fn request(id: Value, method: String, params: Value) -> Value {
  object([
    #("jsonrpc", value.Text("2.0")),
    #("id", id),
    #("method", value.Text(method)),
    #("params", params),
  ])
}

fn object(members: List(#(String, Value))) -> Value {
  value.Object(members)
}

fn has_tool(tools: Value, name: String) -> Bool {
  case tools {
    value.Array(values) -> contains_tool(values, name)
    _ -> False
  }
}

fn contains_tool(tools: List(Value), name: String) -> Bool {
  case tools {
    [] -> False
    [value.Object(members), ..rest] ->
      case member(members, "name") {
        Some(value.Text(actual)) -> actual == name || contains_tool(rest, name)
        _ -> contains_tool(rest, name)
      }
    [_, ..rest] -> contains_tool(rest, name)
  }
}

fn required_field(value: Value, name: String) -> Value {
  case member_of_value(value, name) {
    Some(found) -> found
    NoValue -> todo as "probe expected a required encoded field"
  }
}

fn nested_field(value: Value, path: List(String)) -> Value {
  case path {
    [] -> value
    [name, ..rest] -> nested_field(required_field(value, name), rest)
  }
}

fn member_of_value(value: Value, name: String) -> Maybe(Value) {
  case value {
    value.Object(members) -> member(members, name)
    _ -> NoValue
  }
}

fn member(members: List(#(String, Value)), name: String) -> Maybe(Value) {
  case members {
    [] -> NoValue
    [#(key, found), ..rest] ->
      case key == name {
        True -> Some(found)
        False -> member(rest, name)
      }
  }
}

fn append(first: List(a), second: List(a)) -> List(a) {
  case first {
    [] -> second
    [item, ..rest] -> [item, ..append(rest, second)]
  }
}
