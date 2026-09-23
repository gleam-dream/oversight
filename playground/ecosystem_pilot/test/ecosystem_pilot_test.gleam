import ecosystem_pilot
import fourth_provider
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import json/blueprint/codec
import json/blueprint/parser
import llm_wire/config
import llm_wire/session
import llm_wire/telemetry as llm_telemetry
import llm_wire/types
import relay/client
import relay/content as relay_content
import relay/telemetry as relay_telemetry
import relay/tool
import relay/transport/http
import scripted_provider
import sinal

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn discovered_schema_composes_with_mixed_scoped_observation_test() {
  let assert Ok(definition) = ecosystem_pilot.inventory_definition()
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.Lookup("A-100"))
  let invocations = process.new_subject()
  let errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(definition, invocations, errors)
  let assert Ok(relay_client) = ecosystem_pilot.connect_relay(relay_server)
  let assert Ok([declaration]) = client.list_tools(relay_client)
  let relay_events = process.new_subject()
  let llm_events = process.new_subject()
  let relay_observer =
    sinal.subscription(
      relay_telemetry.invocation_completed_event(),
      fn(measurements, metadata) {
        process.send(relay_events, #(measurements.duration_ms, metadata.status))
      },
    )
  let llm_observer =
    sinal.subscription(llm_telemetry.observation_event(), fn(_, metadata) {
      process.send(llm_events, metadata.stage)
    })
  let assert Ok(sinal.SubscriptionCompletion(answer, [])) =
    sinal.with_subscriptions(
      sinal.subscriptions([relay_observer, llm_observer]),
      fn() {
        let assert Ok(prepared) =
          ecosystem_pilot.prepare_discovered_openai(
            declaration,
            provider_endpoint(provider),
          )
        let assert Ok(session.RunToolCalls(_, [call], continuation, _)) =
          ecosystem_pilot.provider_run(prepared)
        let assert Ok(arguments) =
          parser.parse_value_from_string(
            parser.default_limits(),
            call.arguments_json,
          )
        let assert Ok(output) =
          ecosystem_pilot.call_discovered_value(
            relay_client,
            declaration,
            arguments,
          )
        let assert Ok(next) =
          ecosystem_pilot.provider_continue(
            continuation,
            types.ToolResult(call.id, output),
          )
        let assert Ok(session.RunText(answer, None)) =
          ecosystem_pilot.provider_run(next)
        answer
      },
    )
  answer |> should.equal("A-100 has 7 Ada Lovelace notebooks.")
  process.receive(relay_events, 3000) |> should.be_ok
  process.receive(llm_events, 3000) |> should.be_ok
  process.receive(invocations, 3000) |> should.equal(Ok("A-100"))
  client.close(relay_client)
  http.stop_http_server(relay_server)
  scripted_provider.stop(provider)
}

fn fourth_settings(provider: scripted_provider.Provider) -> config.Config {
  let assert Ok(endpoint) =
    types.endpoint(
      "http://127.0.0.1:" <> int.to_string(scripted_provider.port(provider)),
    )
  config.from_provider(fourth_provider.adapter(endpoint))
}

fn fourth_request(with_tool: Bool) -> types.Request {
  let assert Ok(model) = types.model_id("fourth-model")
  let base = types.new_request(model, [types.UserMessage("Find SKU A-100")])
  case with_tool {
    False -> base
    True -> {
      let assert Ok(definition) = ecosystem_pilot.inventory_definition()
      let assert Ok(tool) = ecosystem_pilot.llm_tool(definition)
      types.with_tools(base, [tool])
    }
  }
}

pub fn fourth_provider_text_and_replay_over_http_test() {
  let assert Ok(text_provider) =
    scripted_provider.start(scripted_provider.FourthText)
  let assert Ok(prepared) =
    session.prepare(fourth_settings(text_provider), fourth_request(False))
  session.run(prepared)
  |> should.equal(Ok(session.RunText("Hello fourth.", None)))
  scripted_provider.stop(text_provider)

  let assert Ok(tool_provider) =
    scripted_provider.start(scripted_provider.FourthTool)
  let assert Ok(tool_prepared) =
    session.prepare(fourth_settings(tool_provider), fourth_request(True))
  let assert Ok(session.RunToolCalls(
    "Checking inventory",
    [call],
    pending,
    None,
  )) = session.run(tool_prepared)
  session.prepare_continue(pending, []) |> should.be_error
  let assert Ok(next) =
    session.prepare_continue(pending, [
      types.ToolResult(call.id, "Ada Lovelace notebook"),
    ])
  session.prepared_request_json(next)
  |> string.contains("\"replay_text\":\"Checking inventory\"")
  |> should.be_true
  session.run(next)
  |> should.equal(Ok(session.RunText("Inventory confirmed.", None)))
  let assert Ok(initial_body) =
    scripted_provider.next_request(tool_provider, 3000)
  scripted_provider.is_fourth_initial_request(initial_body) |> should.be_true
  let assert Ok(replay_body) =
    scripted_provider.next_request(tool_provider, 3000)
  scripted_provider.is_fourth_continuation_request(replay_body)
  |> should.be_true
  scripted_provider.stop(tool_provider)
}

pub fn fourth_provider_obeys_common_text_bound_test() {
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.FourthBounded)
  let limits =
    types.Limits(..types.default_limits(), text_bytes_per_block_limit: 5)
  let assert Ok(prepared) =
    session.prepare(
      fourth_settings(provider) |> config.with_limits(limits),
      fourth_request(False),
    )
  let assert Error(session.RunFailure(
    types.ResourceLimitExceeded("text_bytes_per_block_limit", _, _),
    retry,
  )) = session.run(prepared)
  retry.response_bytes_observed |> should.be_true
  scripted_provider.stop(provider)
}

pub fn valid_typed_lookup_composes_all_four_packages_test() {
  let assert Ok(definition) = ecosystem_pilot.inventory_definition()
  let metadata = tool.definition_metadata(definition)
  let assert Some(annotations) = metadata.annotations
  annotations.read_only_hint |> should.equal(Some(True))
  annotations.destructive_hint |> should.equal(Some(False))
  annotations.idempotent_hint |> should.equal(Some(True))
  annotations.open_world_hint |> should.equal(Some(False))
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.Lookup("A-100"))
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(
      definition,
      invocations,
      application_errors,
    )
  let assert Ok(relay_client) = ecosystem_pilot.connect_relay(relay_server)
  let relay_events = process.new_subject()
  let llm_events = process.new_subject()
  let relay_attachment = attach_relay_events(relay_events, "pilot-valid-relay")
  let llm_attachment = attach_llm_events(llm_events, "pilot-valid-llm")

  client.discover(relay_client) |> should.be_ok
  let assert Ok(declarations) = client.list_tools(relay_client)
  list.length(declarations) |> should.equal(1)
  let assert Ok(declaration) = ecosystem_pilot.llm_tool(definition)
  declaration
  |> types.tool_name_of
  |> types.tool_name_to_string
  |> should.equal("inventory_lookup")
  types.tool_description(declaration)
  |> should.equal("Look up one synthetic inventory record by SKU")
  let assert Ok(input_schema) =
    codec.schema_json(tool.definition_input_codec(definition))
  string.contains(input_schema, "https://json-schema.org/draft/2020-12/schema")
  |> should.be_true
  let assert Ok(item_schema) =
    codec.schema_json(tool.definition_output_codec(definition))
  string.contains(item_schema, "\"quantity\"") |> should.be_true

  let endpoint = provider_endpoint(provider)
  let assert Ok(prepared) =
    ecosystem_pilot.prepare_openai(definition, endpoint, "Find SKU A-100")
  let assert Ok(session.RunToolCalls(_, [call], continuation, _)) =
    ecosystem_pilot.provider_run(prepared)
  types.call_id_to_string(call.id) |> should.equal("call_1")
  call.arguments_json |> should.equal("{\"sku\":\"A-100\"}")
  let assert Ok(input) =
    ecosystem_pilot.decode_lookup(definition, call.arguments_json)
  input |> should.equal(ecosystem_pilot.Lookup("A-100"))

  let assert client.StructuredSuccess(item, content) =
    ecosystem_pilot.execute_lookup(relay_client, definition, input)
  item
  |> should.equal(ecosystem_pilot.InventoryItem(
    "A-100",
    "Ada Lovelace notebook",
    7,
  ))
  content
  |> should.equal([
    relay_content_text(
      "{\"sku\":\"A-100\",\"name\":\"Ada Lovelace notebook\",\"quantity\":7}",
    ),
  ])
  let assert Ok("A-100") = process.receive(invocations, 3000)
  process.receive(application_errors, 0) |> should.be_error

  let assert Ok(encoded) = ecosystem_pilot.encode_item(definition, item)
  let assert Ok(next_prepared) =
    ecosystem_pilot.provider_continue(
      continuation,
      types.ToolResult(call.id, encoded),
    )
  ecosystem_pilot.provider_run(next_prepared)
  |> should.equal(
    Ok(session.RunText("A-100 has 7 Ada Lovelace notebooks.", None)),
  )

  await_provider_request(provider, fn(body) {
    scripted_provider.is_initial_request(body, "A-100")
  })
  await_provider_request(provider, fn(body) {
    scripted_provider.is_continuation_request(body, "A-100")
  })
  scripted_provider.next_request(provider, 500) |> should.be_error
  await_relay_status(relay_events, "success")
  await_llm_terminals(llm_events, 2)
  |> should.equal(["completed_tools", "completed_text"])

  sinal.detach(relay_attachment) |> should.be_ok
  sinal.detach(llm_attachment) |> should.be_ok
  client.close(relay_client)
  http.stop_http_server(relay_server)
  scripted_provider.stop(provider)
  scripted_provider.await_worker_stopped(provider, 1000) |> should.be_true
}

pub fn invalid_tool_arguments_are_rejected_before_handler_test() {
  let assert Ok(definition) = ecosystem_pilot.inventory_definition()
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.InvalidArguments)
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(
      definition,
      invocations,
      application_errors,
    )
  let assert Ok(relay_client) = ecosystem_pilot.connect_relay(relay_server)
  let relay_events = process.new_subject()
  let attachment = attach_relay_events(relay_events, "pilot-invalid-relay")
  let invalid_arguments = json.object([#("sku", json.int(42))])
  let assert Ok(prepared) =
    ecosystem_pilot.prepare_openai(
      definition,
      provider_endpoint(provider),
      "Find SKU MISSING",
    )
  let assert Error(session.RunFailure(types.ProtocolError(reason), _)) =
    ecosystem_pilot.provider_run(prepared)
  string.contains(reason, "Tool call arguments failed schema validation")
  |> should.be_true
  ecosystem_pilot.decode_lookup(definition, "{\"sku\":42}") |> should.be_error

  let assert Ok(response) =
    client.raw_json_call(relay_client, "tools/call", Some("inventory_lookup"), [
      #("name", json.string("inventory_lookup")),
      #("arguments", invalid_arguments),
    ])
  let assert Ok(response_text) = bit_array.to_string(response)
  json.parse(response_text, decode.at(["error", "code"], decode.int))
  |> should.equal(Ok(-32_602))
  ecosystem_pilot.decode_lookup(definition, "{\"sku\":42}") |> should.be_error

  process.receive(invocations, 0) |> should.be_error
  process.receive(application_errors, 0) |> should.be_error
  await_relay_status(relay_events, "error")
  await_provider_request(provider, fn(body) {
    scripted_provider.is_initial_request(body, "MISSING")
  })

  sinal.detach(attachment) |> should.be_ok
  client.close(relay_client)
  http.stop_http_server(relay_server)
  scripted_provider.stop(provider)
  scripted_provider.await_worker_stopped(provider, 1000) |> should.be_true
}

pub fn missing_record_error_continues_with_correlated_tool_result_test() {
  let assert Ok(definition) = ecosystem_pilot.inventory_definition()
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.Lookup("MISSING"))
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_rendered_relay_server(
      definition,
      invocations,
      application_errors,
    )
  let assert Ok(relay_client) = ecosystem_pilot.connect_relay(relay_server)
  let relay_events = process.new_subject()
  let llm_events = process.new_subject()
  let relay_attachment =
    attach_relay_events(relay_events, "pilot-missing-relay")
  let llm_attachment = attach_llm_events(llm_events, "pilot-missing-llm")

  let assert Ok(prepared) =
    ecosystem_pilot.prepare_openai(
      definition,
      provider_endpoint(provider),
      "Find SKU MISSING",
    )
  let assert Ok(session.RunToolCalls(_, [call], continuation, _)) =
    ecosystem_pilot.provider_run(prepared)
  types.call_id_to_string(call.id) |> should.equal("call_1")
  let assert Ok(input) =
    ecosystem_pilot.decode_lookup(definition, call.arguments_json)
  input |> should.equal(ecosystem_pilot.Lookup("MISSING"))

  let assert client.ToolFailure(content) =
    ecosystem_pilot.execute_lookup(relay_client, definition, input)
  content
  |> should.equal([relay_content_text("inventory record not found")])
  let assert Ok("MISSING") = process.receive(invocations, 3000)
  let assert Ok("inventory record not found") =
    process.receive(application_errors, 3000)

  let result_text = tool_failure_text(content)
  let application_error = result_text
  application_error |> should.equal("inventory record not found")
  let assert Ok(next_prepared) =
    ecosystem_pilot.provider_continue(
      continuation,
      types.ToolResult(call.id, application_error),
    )
  ecosystem_pilot.provider_run(next_prepared)
  |> should.equal(Ok(session.RunText("I couldn't find MISSING.", None)))

  await_provider_request(provider, fn(body) {
    scripted_provider.is_initial_request(body, "MISSING")
  })
  await_provider_request(provider, fn(body) {
    scripted_provider.is_continuation_request(body, "MISSING")
  })
  scripted_provider.next_request(provider, 500) |> should.be_error
  await_relay_status(relay_events, "error")
  await_llm_terminals(llm_events, 2)
  |> should.equal(["completed_tools", "completed_text"])

  sinal.detach(relay_attachment) |> should.be_ok
  sinal.detach(llm_attachment) |> should.be_ok
  client.close(relay_client)
  http.stop_http_server(relay_server)
  scripted_provider.stop(provider)
  scripted_provider.await_worker_stopped(provider, 1000) |> should.be_true
}

pub fn generic_application_failure_is_stable_over_http_test() {
  let assert Ok(definition) = ecosystem_pilot.inventory_definition()
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(
      definition,
      invocations,
      application_errors,
    )
  let assert Ok(relay_client) = ecosystem_pilot.connect_relay(relay_server)
  let assert client.ToolFailure(content) =
    ecosystem_pilot.execute_lookup(
      relay_client,
      definition,
      ecosystem_pilot.Lookup("MISSING"),
    )
  content |> should.equal([relay_content_text("Tool execution failed.")])
  process.receive(invocations, 3000) |> should.equal(Ok("MISSING"))
  process.receive(application_errors, 3000)
  |> should.equal(Ok("inventory record not found"))
  client.close(relay_client)
  http.stop_http_server(relay_server)
}

pub fn json_text_application_failure_survives_http_test() {
  let assert Ok(definition) = ecosystem_pilot.inventory_definition()
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_json_text_error_relay_server(
      definition,
      invocations,
      application_errors,
    )
  let assert Ok(relay_client) = ecosystem_pilot.connect_relay(relay_server)
  let assert client.ToolFailure(content) =
    ecosystem_pilot.execute_lookup(
      relay_client,
      definition,
      ecosystem_pilot.Lookup("MISSING"),
    )
  content
  |> should.equal([relay_content_text("\"inventory record not found\"")])
  let assert Ok(decoded) = json.parse(tool_failure_text(content), decode.string)
  decoded |> should.equal("inventory record not found")
  process.receive(invocations, 3000) |> should.equal(Ok("MISSING"))
  process.receive(application_errors, 3000)
  |> should.equal(Ok("inventory record not found"))
  client.close(relay_client)
  http.stop_http_server(relay_server)
}

pub fn cancellation_closes_partial_response_before_tool_execution_test() {
  let assert Ok(definition) = ecosystem_pilot.inventory_definition()
  let assert Ok(provider) = scripted_provider.start(scripted_provider.Slow)
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(
      definition,
      invocations,
      application_errors,
    )
  let llm_events = process.new_subject()
  let llm_attachment = attach_llm_events(llm_events, "pilot-cancel-llm")

  let assert Ok(prepared) =
    ecosystem_pilot.prepare_openai(
      definition,
      provider_endpoint(provider),
      "Find SKU A-100",
    )
  let assert Ok(stream) = session.stream(prepared)
  await_provider_request(provider, fn(body) {
    scripted_provider.is_initial_request(body, "A-100")
  })
  scripted_provider.await_response_started(provider, 3000) |> should.be_ok
  let assert Ok(session.NextProgress(types.TextDelta("msg_slow", delta))) =
    session.next(stream)
  delta |> should.equal("Searching inventory")
  session.close(stream) |> should.equal(Ok(types.ConsumerClosed))
  session.next(stream)
  |> should.equal(Error(session.StreamReadError(types.StreamClosed)))

  scripted_provider.await_disconnect(provider, 3000)
  |> should.equal(Ok("closed"))
  process.receive(invocations, 0) |> should.be_error
  process.receive(application_errors, 0) |> should.be_error
  let cancellation_events = await_llm_cancellation(llm_events, False, False, [])
  list.contains(cancellation_events, #("first_progress", "received"))
  |> should.be_true
  list.contains(cancellation_events, #("cleanup", "transport_closed"))
  |> should.be_true
  list.contains(cancellation_events, #("cancelled", "consumer_closed"))
  |> should.be_true

  sinal.detach(llm_attachment) |> should.be_ok
  http.stop_http_server(relay_server)
  scripted_provider.stop(provider)
  scripted_provider.await_worker_stopped(provider, 1000) |> should.be_true
}

pub fn provider_disconnect_returns_error_without_retry_or_tool_effect_test() {
  let assert Ok(definition) = ecosystem_pilot.inventory_definition()
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.Disconnect)
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(
      definition,
      invocations,
      application_errors,
    )
  let llm_events = process.new_subject()
  let llm_attachment = attach_llm_events(llm_events, "pilot-disconnect-llm")
  let assert Ok(prepared) =
    ecosystem_pilot.prepare_openai(
      definition,
      provider_endpoint(provider),
      "Find SKU A-100",
    )

  let assert Error(session.RunFailure(types.TransportError(_), _)) =
    ecosystem_pilot.provider_run(prepared)
  await_provider_request(provider, fn(body) {
    scripted_provider.is_initial_request(body, "A-100")
  })
  scripted_provider.next_request(provider, 1600) |> should.be_error
  process.receive(invocations, 0) |> should.be_error
  process.receive(application_errors, 0) |> should.be_error
  let llm_observations = collect_llm_observations(llm_events)
  has_llm_stage(llm_observations, "request_sent") |> should.be_true

  sinal.detach(llm_attachment) |> should.be_ok
  http.stop_http_server(relay_server)
  scripted_provider.stop(provider)
  scripted_provider.await_worker_stopped(provider, 1000) |> should.be_true
}

fn provider_endpoint(provider: scripted_provider.Provider) -> String {
  "http://127.0.0.1:"
  <> int.to_string(scripted_provider.port(provider))
  <> "/v1"
}

fn relay_content_text(text: String) -> relay_content.ContentBlock {
  relay_content.text_content(text)
}

fn tool_failure_text(blocks: List(relay_content.ContentBlock)) -> String {
  case blocks {
    [relay_content.TextContent(text, _)] -> text
    _ -> ""
  }
}

fn await_provider_request(
  provider: scripted_provider.Provider,
  predicate: fn(String) -> Bool,
) -> Nil {
  let assert Ok(body) = scripted_provider.next_request(provider, 3000)
  predicate(body) |> should.equal(True)
}

fn await_relay_status(
  subject: process.Subject(#(Int, String)),
  expected: String,
) -> Nil {
  let assert Ok(#(_duration, status)) = process.receive(subject, 3000)
  status |> should.equal(expected)
}

fn await_llm_terminals(
  subject: process.Subject(#(String, String, String)),
  remaining: Int,
) -> List(String) {
  let assert Ok(#(stage, provider, outcome)) = process.receive(subject, 3000)
  provider |> should.equal("openai")
  case stage {
    "terminal" if remaining <= 1 -> [outcome]
    "terminal" -> [outcome, ..await_llm_terminals(subject, remaining - 1)]
    _ -> await_llm_terminals(subject, remaining)
  }
}

fn collect_llm_observations(
  subject: process.Subject(#(String, String, String)),
) -> List(#(String, String, String)) {
  case process.receive(subject, 250) {
    Error(Nil) -> []
    Ok(observation) -> [observation, ..collect_llm_observations(subject)]
  }
}

fn has_llm_stage(
  observations: List(#(String, String, String)),
  expected: String,
) -> Bool {
  list.any(observations, fn(observation) {
    let #(stage, _provider, _outcome) = observation
    stage == expected
  })
}

fn await_llm_cancellation(
  subject: process.Subject(#(String, String, String)),
  saw_cleanup: Bool,
  saw_cancelled: Bool,
  seen: List(#(String, String)),
) -> List(#(String, String)) {
  let assert Ok(#(stage, provider, outcome)) = process.receive(subject, 3000)
  provider |> should.equal("openai")
  let saw_cleanup = saw_cleanup || stage == "cleanup"
  let saw_cancelled = saw_cancelled || stage == "cancelled"
  let seen = [#(stage, outcome), ..seen]
  case saw_cleanup && saw_cancelled {
    True -> seen
    False -> await_llm_cancellation(subject, saw_cleanup, saw_cancelled, seen)
  }
}

fn attach_relay_events(
  subject: process.Subject(#(Int, String)),
  id: String,
) -> sinal.Attachment {
  let assert Ok(handler_id) = sinal.handler_id(id)
  let event = relay_telemetry.invocation_completed_event()
  let assert Ok(attachment) =
    sinal.observe(
      handler_id,
      event,
      fn(
        measurements: relay_telemetry.InvocationCompletedMeasurements,
        metadata: relay_telemetry.InvocationCompletedMeta,
      ) {
        process.send(subject, #(measurements.duration_ms, metadata.status))
      },
    )
  attachment
}

fn attach_llm_events(
  subject: process.Subject(#(String, String, String)),
  id: String,
) -> sinal.Attachment {
  let assert Ok(handler_id) = sinal.handler_id(id)
  let event = llm_telemetry.observation_event()
  let assert Ok(attachment) =
    sinal.observe(
      handler_id,
      event,
      fn(_measurements: Nil, metadata: llm_telemetry.Metadata) {
        process.send(subject, #(
          metadata.stage,
          metadata.provider,
          metadata.outcome,
        ))
      },
    )
  attachment
}
