import ecosystem_pilot
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
import llm_wire
import llm_wire/telemetry as llm_telemetry
import llm_wire/types
import relay/client
import relay/content as relay_content
import relay/telemetry as relay_telemetry
import relay/transport/http
import scripted_provider
import sinal

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn valid_typed_lookup_composes_all_four_packages_test() {
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.Lookup("A-100"))
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(invocations, application_errors)
  let assert Ok(relay_client) = ecosystem_pilot.connect_relay(relay_server)
  let relay_events = process.new_subject()
  let llm_events = process.new_subject()
  let relay_attachment = attach_relay_events(relay_events, "pilot-valid-relay")
  let llm_attachment = attach_llm_events(llm_events, "pilot-valid-llm")

  client.discover(relay_client) |> should.be_ok
  let assert Ok(declarations) = client.list_tools(relay_client)
  list.length(declarations) |> should.equal(1)

  let endpoint = provider_endpoint(provider)
  let assert Ok(prepared) =
    ecosystem_pilot.prepare_openai(endpoint, "Find SKU A-100")
  let assert Ok(llm_wire.RunToolCalls([call], continuation, _)) =
    ecosystem_pilot.provider_run(prepared)
  llm_wire.call_id_to_string(call.id) |> should.equal("call_1")
  call.arguments_json |> should.equal("{\"sku\":\"A-100\"}")
  let assert Ok(input) = ecosystem_pilot.decode_lookup(call.arguments_json)
  input |> should.equal(ecosystem_pilot.Lookup("A-100"))

  let assert client.StructuredSuccess(item, content) =
    ecosystem_pilot.execute_lookup(relay_client, input)
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

  let assert Ok(encoded) = ecosystem_pilot.encode_item(item)
  let assert Ok(next_prepared) =
    ecosystem_pilot.provider_continue(
      prepared,
      continuation,
      llm_wire.ToolResult(call.id, encoded),
    )
  ecosystem_pilot.provider_run(next_prepared)
  |> should.equal(
    Ok(llm_wire.RunText("A-100 has 7 Ada Lovelace notebooks.", None)),
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
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.InvalidArguments)
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(invocations, application_errors)
  let assert Ok(relay_client) = ecosystem_pilot.connect_relay(relay_server)
  let relay_events = process.new_subject()
  let attachment = attach_relay_events(relay_events, "pilot-invalid-relay")
  let invalid_arguments = json.object([#("sku", json.int(42))])
  let assert Ok(prepared) =
    ecosystem_pilot.prepare_openai(
      provider_endpoint(provider),
      "Find SKU MISSING",
    )
  let assert Error(types.ProtocolError(reason)) =
    ecosystem_pilot.provider_run(prepared)
  string.contains(reason, "Tool call arguments failed schema validation")
  |> should.be_true
  ecosystem_pilot.decode_lookup("{\"sku\":42}") |> should.be_error

  let assert Ok(response) =
    client.raw_json_call(relay_client, "tools/call", Some("inventory_lookup"), [
      #("name", json.string("inventory_lookup")),
      #("arguments", invalid_arguments),
    ])
  let assert Ok(response_text) = bit_array.to_string(response)
  json.parse(response_text, decode.at(["error", "code"], decode.int))
  |> should.equal(Ok(-32_602))
  ecosystem_pilot.decode_lookup("{\"sku\":42}") |> should.be_error

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
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.Lookup("MISSING"))
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(invocations, application_errors)
  let assert Ok(relay_client) = ecosystem_pilot.connect_relay(relay_server)
  let relay_events = process.new_subject()
  let llm_events = process.new_subject()
  let relay_attachment =
    attach_relay_events(relay_events, "pilot-missing-relay")
  let llm_attachment = attach_llm_events(llm_events, "pilot-missing-llm")

  let assert Ok(prepared) =
    ecosystem_pilot.prepare_openai(
      provider_endpoint(provider),
      "Find SKU MISSING",
    )
  let assert Ok(llm_wire.RunToolCalls([call], continuation, _)) =
    ecosystem_pilot.provider_run(prepared)
  llm_wire.call_id_to_string(call.id) |> should.equal("call_1")
  let assert Ok(input) = ecosystem_pilot.decode_lookup(call.arguments_json)
  input |> should.equal(ecosystem_pilot.Lookup("MISSING"))

  let assert client.ToolFailure(content) =
    ecosystem_pilot.execute_lookup(relay_client, input)
  content
  |> should.equal([relay_content_text("\"inventory record not found\"")])
  let assert Ok("MISSING") = process.receive(invocations, 3000)
  let assert Ok("inventory record not found") =
    process.receive(application_errors, 3000)

  let result_text = tool_failure_text(content)
  let assert Ok(application_error) =
    ecosystem_pilot.decode_lookup_error(result_text)
  application_error |> should.equal("inventory record not found")
  let assert Ok(next_prepared) =
    ecosystem_pilot.provider_continue(
      prepared,
      continuation,
      llm_wire.ToolResult(call.id, application_error),
    )
  ecosystem_pilot.provider_run(next_prepared)
  |> should.equal(Ok(llm_wire.RunText("I couldn't find MISSING.", None)))

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

pub fn cancellation_closes_partial_response_before_tool_execution_test() {
  let assert Ok(provider) = scripted_provider.start(scripted_provider.Slow)
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(invocations, application_errors)
  let llm_events = process.new_subject()
  let llm_attachment = attach_llm_events(llm_events, "pilot-cancel-llm")

  let assert Ok(prepared) =
    ecosystem_pilot.prepare_openai(
      provider_endpoint(provider),
      "Find SKU A-100",
    )
  let assert Ok(stream) =
    llm_wire.stream(prepared, types.default_limits(), types.default_deadlines())
  await_provider_request(provider, fn(body) {
    scripted_provider.is_initial_request(body, "A-100")
  })
  scripted_provider.await_response_started(provider, 3000) |> should.be_ok
  let assert Ok(types.NextProgress(types.TextDelta("msg_slow", delta))) =
    llm_wire.next(stream, 3000)
  delta |> should.equal("Searching inventory")
  llm_wire.close(stream) |> should.equal(Ok(types.ConsumerClosed))
  llm_wire.next(stream, 0) |> should.equal(Error(types.StreamClosed))

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
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.Disconnect)
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(relay_server) =
    ecosystem_pilot.start_relay_server_observed(invocations, application_errors)
  let llm_events = process.new_subject()
  let llm_attachment = attach_llm_events(llm_events, "pilot-disconnect-llm")
  let assert Ok(prepared) =
    ecosystem_pilot.prepare_openai(
      provider_endpoint(provider),
      "Find SKU A-100",
    )

  let assert Error(types.TransportError(_)) =
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
  let handler =
    sinal.handler(
      fn(
        _event,
        measurements: relay_telemetry.InvocationCompletedMeasurements,
        metadata: relay_telemetry.InvocationCompletedMeta,
      ) {
        process.send(subject, #(measurements.duration_ms, metadata.status))
        Ok(Nil)
      },
    )
  let assert Ok(attachment) =
    sinal.attach(handler_id, event, handler, fn(_, _) { Nil })
  attachment
}

fn attach_llm_events(
  subject: process.Subject(#(String, String, String)),
  id: String,
) -> sinal.Attachment {
  let assert Ok(handler_id) = sinal.handler_id(id)
  let event = llm_telemetry.observation_event()
  let handler =
    sinal.handler(
      fn(_event, _measurements: Nil, metadata: llm_telemetry.Metadata) {
        process.send(subject, #(
          metadata.stage,
          metadata.provider,
          metadata.outcome,
        ))
        Ok(Nil)
      },
    )
  let assert Ok(attachment) =
    sinal.attach(handler_id, event, handler, fn(_, _) { Nil })
  attachment
}
