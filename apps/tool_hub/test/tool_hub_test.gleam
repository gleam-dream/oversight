import fabric
import fabric/run
import gleam/bit_array
import gleam/erlang/process
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import gleeunit
import http_gun
import http_gun/telemetry as http_gun_telemetry
import json/blueprint/contract
import json/blueprint/value.{type Value}
import llm_wire/testing
import relay/client
import relay/content
import relay/transport/http
import tool_hub
import tool_hub/assistant
import tool_hub/inventory
import tool_hub/scripted_llm.{After, Hold, Reply, call}
import tool_hub/telemetry

pub fn main() -> Nil {
  gleeunit.main()
}

// --- helpers -----------------------------------------------------------------

fn ask(
  hub: tool_hub.Hub,
  question: String,
) -> client.ToolCallOutcome(assistant.Answer) {
  let assert Ok(mcp) = tool_hub.assistant_client(hub, 15_000)
  let outcome =
    client.call_definition(
      mcp,
      assistant.ask_assistant(),
      assistant.Question(question),
    )
  client.close(mcp)
  outcome
}

fn text_of(blocks: List(content.ContentBlock)) -> String {
  list.map(blocks, fn(block) {
    case block {
      content.TextContent(text, _) -> text
      _ -> ""
    }
  })
  |> string.concat
}

fn wait_for(
  notices: process.Subject(scripted_llm.Notice),
  wanted: scripted_llm.Notice,
  within: Int,
) -> Bool {
  case process.receive(notices, within) {
    Ok(notice) if notice == wanted -> True
    Ok(_) -> wait_for(notices, wanted, within)
    Error(Nil) -> False
  }
}

fn stream_closed_within(
  notices: process.Subject(scripted_llm.Notice),
  within: Int,
) -> Bool {
  wait_for(notices, scripted_llm.StreamClosed, within)
}

fn run_ids(records: List(telemetry.Record)) -> List(String) {
  list.filter_map(records, fn(record) {
    case record.package, record.event, record.key {
      "fabric", "run.start", telemetry.RunKey(id) -> Ok(id)
      _, _, _ -> Error(Nil)
    }
  })
}

fn events(records: List(telemetry.Record), package: String) -> List(String) {
  records
  |> list.filter(fn(record) { record.package == package })
  |> list.map(fn(record) { record.event <> " " <> record.detail })
}

/// The JSON Schema fabric sent to the model for `tool`, read back from the
/// provider request body.
fn schema_sent_to_model(body: String, tool: String) -> Value {
  let assert Ok(value.Object(fields)) =
    value.parse(body, value.default_limits())
  let assert Ok(value.Array(tools)) = list.key_find(fields, "tools")
  let assert Ok(value.Object(found)) =
    list.find(tools, fn(item) {
      case item {
        value.Object(f) -> list.key_find(f, "name") == Ok(value.String(tool))
        _ -> False
      }
    })
  let assert Ok(schema) = list.key_find(found, "schema")
  schema
}

fn contract_of(schema: Value) -> contract.Contract {
  let document = case schema {
    value.Object(fields) ->
      case list.key_find(fields, "$schema") {
        Ok(_) -> schema
        Error(Nil) ->
          value.Object([
            #(
              "$schema",
              value.String("https://json-schema.org/draft/2020-12/schema"),
            ),
            ..fields
          ])
      }
    _ -> schema
  }
  let assert Ok(loaded) = contract.load(document)
  loaded
}

/// Holds the inventory server so a script step (in the provider's process)
/// can stop it.
type Stopper {
  SetServer(http.HttpServer(Nil))
  StopServer(process.Subject(Nil))
}

fn stopper() -> process.Subject(Stopper) {
  let assert Ok(started) =
    actor.new(None)
    |> actor.on_message(fn(server, message) {
      case message, server {
        SetServer(server), _ -> actor.continue(Some(server))
        StopServer(reply), Some(server) -> {
          http.stop_http_server(server)
          process.send(reply, Nil)
          actor.continue(None)
        }
        StopServer(reply), None -> {
          process.send(reply, Nil)
          actor.continue(None)
        }
      }
    })
    |> actor.start
  started.data
}

// --- common path ------------------------------------------------------------------

/// An MCP client calls `ask_assistant`; the agent searches, checks stock and
/// reserves on the inventory MCP server, then answers.
pub fn common_path_answers_through_both_mcp_servers_test() {
  let assert Ok(hub) =
    tool_hub.start(tool_hub.settings("common"), tool_hub.demo_script())
  let assert client.StructuredSuccess(answer, _) =
    ask(hub, tool_hub.demo_question)
  let assert True = string.contains(answer.answer, "reservation R-1")

  // The reservation really happened on the inventory server.
  let assert client.StructuredSuccess(stock, _) =
    client.call_definition(
      hub.peer,
      inventory.get_stock(),
      inventory.StockQuery("KB-101"),
    )
  let assert 10 = stock.on_hand

  // The model saw each typed result on its next turn.
  let requests = scripted_llm.requests(scripted_llm.drain(hub.notices))
  let assert [_, second, third, fourth] = requests
  let assert True = string.contains(second, "Ergonomic keyboard")
  let assert True = string.contains(third, "\\\"on_hand\\\":12")
  let assert True =
    string.contains(fourth, "\\\"reservation_id\\\":\\\"R-1\\\"")

  // Telemetry: fabric and http_gun join on the run; relay and llm_wire do not.
  let followed = telemetry.follow(hub.telemetry, answer.run_id)
  let assert True = telemetry.has(followed.joined, "fabric", "run.stop")
  // The scripted provider reports no usage: every turn says so, not zero.
  let turns =
    events(followed.joined, "fabric")
    |> list.filter(fn(event) { string.starts_with(event, "model.stop") })
  let assert 4 = list.length(turns)
  let assert True =
    list.all(turns, fn(event) { string.contains(event, "usage not reported") })
  let assert True =
    list.any(events(followed.joined, "fabric"), fn(event) {
      string.contains(event, "4 turns, 4 without usage")
    })
  let assert True = telemetry.count(followed.joined, "http_gun") >= 24
  let assert 0 = telemetry.count(followed.joined, "relay")
  let assert 0 = telemetry.count(followed.joined, "llm_wire")
  let assert True = telemetry.count(followed.unjoined, "llm_wire") >= 16
  // Relay's invocation event names the method, not the tool.
  let started =
    events(followed.unjoined, "relay")
    |> list.filter(fn(event) { string.starts_with(event, "invocation.started") })
  let assert 5 = list.length(started)
  let assert True =
    list.all(started, fn(event) {
      string.contains(event, "tool_name=tools/call")
    })
  tool_hub.stop(hub)
}

// --- advanced: one definition, three vocabularies ------------------------------------

/// The same Blueprint codec backs the Relay listing, the fabric tool and the
/// schema llm_wire sends to the model.
pub fn typed_tool_schema_is_identical_in_all_three_places_test() {
  let assert Ok(hub) =
    tool_hub.start(tool_hub.settings("schemas"), tool_hub.demo_script())
  let assert client.StructuredSuccess(_, _) = ask(hub, tool_hub.demo_question)
  let assert Ok(native) = contract.from_codec(inventory.search_query_codec())

  let assert Ok(listed) = client.list_tools(hub.peer)
  let assert Ok(declaration) =
    list.find(listed, fn(tool) { tool.name == "search_products" })
  let assert Ok(from_relay) =
    contract.parse(
      json.to_string(declaration.input_schema),
      value.default_limits(),
    )
  let assert True = contract.same_schema(native, from_relay)

  let assert [first, ..] =
    scripted_llm.requests(scripted_llm.drain(hub.notices))
  let from_model = contract_of(schema_sent_to_model(first, "search_products"))
  let assert True = contract.same_schema(native, from_model)
  // The description survives in both: Relay's metadata feeds fabric's define.
  let assert Some("Find products whose name contains the text.") =
    declaration.description
  let assert True =
    string.contains(first, "Find products whose name contains the text.")
  tool_hub.stop(hub)
}

// --- advanced: dynamic tools ---------------------------------------------------------

/// Tools discovered with `tools/list` are mounted without native types; the
/// advertised schema still rejects bad arguments before any MCP call.
pub fn discovered_tools_work_without_native_types_test() {
  let script = [
    Reply(
      testing.tool_calls("", [
        call("c1", "search_products", "{\"text\":\"mouse\",\"limit\":50}"),
      ]),
    ),
    Reply(
      testing.tool_calls("", [
        call("c2", "search_products", "{\"text\":\"mouse\",\"limit\":5}"),
      ]),
    ),
    Reply(
      testing.tool_calls("", [call("c3", "get_stock", "{\"sku\":\"MS-300\"}")]),
    ),
    Reply(testing.text("The Wireless mouse (MS-300) has 40 units in Porto.")),
  ]
  let settings =
    tool_hub.Settings(
      ..tool_hub.settings("dynamic"),
      mounting: tool_hub.Discovered,
    )
  let assert Ok(hub) = tool_hub.start(settings, script)
  let assert client.StructuredSuccess(answer, _) =
    ask(hub, "How many wireless mice are there?")
  let assert True = string.contains(answer.answer, "40 units")

  let assert [_, second, third, _] =
    scripted_llm.requests(scripted_llm.drain(hub.notices))
  // limit 50 is outside the advertised 1..10 range: rejected locally.
  let assert True = string.contains(second, "limit")
  let assert True = string.contains(second, "integer outside range 1 to 10")
  // The discovered tool forwards the structured result unchanged.
  let assert True = string.contains(third, "Wireless mouse")
  // Two inventory calls reached Relay (plus ask_assistant), not three.
  let started =
    events(telemetry.records(hub.telemetry), "relay")
    |> list.filter(fn(event) { string.starts_with(event, "invocation.started") })
  let assert 3 = list.length(started)
  tool_hub.stop(hub)
}

// --- failure paths ---------------------------------------------------------------------

/// The remote tool answers `isError: true`: the model sees the text and the
/// run continues.
pub fn remote_tool_error_is_shown_to_the_model_test() {
  let script = [
    Reply(
      testing.tool_calls("", [call("c1", "get_stock", "{\"sku\":\"ZZ-999\"}")]),
    ),
    Reply(testing.text("There is no product ZZ-999.")),
  ]
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("is_error"), script)
  let assert client.StructuredSuccess(answer, _) = ask(hub, "Stock of ZZ-999?")
  let assert "There is no product ZZ-999." = answer.answer
  let assert [_, second] =
    scripted_llm.requests(scripted_llm.drain(hub.notices))
  let assert True = string.contains(second, "unknown SKU ZZ-999")
  let assert True =
    list.contains(
      events(telemetry.records(hub.telemetry), "fabric"),
      "tool.stop get_stock ModelVisible",
    )
  tool_hub.stop(hub)
}

/// The inventory server goes away mid-run before a reservation. Relay cannot
/// say whether the call was sent, so the effect is uncertain: the run stops
/// for reconciliation and `ask_assistant` reports that as `isError` text.
pub fn unreachable_server_mid_run_makes_a_reservation_uncertain_test() {
  let stopper = stopper()
  let script = [
    Reply(
      testing.tool_calls("", [
        call("c1", "search_products", "{\"text\":\"keyboard\",\"limit\":5}"),
      ]),
    ),
    After(
      fn() { process.call(stopper, 2000, StopServer) },
      testing.tool_calls("", [
        call("c2", "reserve_stock", "{\"sku\":\"KB-101\",\"quantity\":1}"),
      ]),
    ),
    Reply(testing.text("unreachable")),
  ]
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("unreachable"), script)
  process.send(stopper, SetServer(hub.inventory))
  let assert client.ToolFailure(blocks) = ask(hub, "Reserve a keyboard.")
  let text = text_of(blocks)
  let assert True = string.starts_with(text, "outcome unknown: reserve_stock")
  let assert True = string.contains(text, "call lost: connection closed")
  // The model was never asked again: the run waits for a person.
  let assert 2 =
    list.length(scripted_llm.requests(scripted_llm.drain(hub.notices)))
  let assert True =
    list.contains(
      events(telemetry.records(hub.telemetry), "fabric"),
      "tool.stop reserve_stock EffectUncertain",
    )
  tool_hub.stop(hub)
}

/// The same outage on a read-only tool is a definite failure the model sees.
pub fn unreachable_server_on_a_read_only_tool_is_explained_test() {
  let stopper = stopper()
  let script = [
    After(
      fn() { process.call(stopper, 2000, StopServer) },
      testing.tool_calls("", [call("c1", "get_stock", "{\"sku\":\"KB-101\"}")]),
    ),
    Reply(testing.text("The inventory is down; try later.")),
  ]
  let assert Ok(hub) =
    tool_hub.start(tool_hub.settings("read_only_down"), script)
  process.send(stopper, SetServer(hub.inventory))
  let assert client.StructuredSuccess(answer, _) = ask(hub, "Stock of KB-101?")
  let assert "The inventory is down; try later." = answer.answer
  let assert [_, second] =
    scripted_llm.requests(scripted_llm.drain(hub.notices))
  let assert True = string.contains(second, "the inventory is unavailable")
  tool_hub.stop(hub)
}

/// The model sends `{"sku": 42}`: fabric rejects it against the shared codec,
/// the inventory server is never called for it, and the model retries.
pub fn invalid_model_arguments_never_reach_the_server_test() {
  let script = [
    Reply(testing.tool_calls("", [call("c1", "get_stock", "{\"sku\":42}")])),
    Reply(
      testing.tool_calls("", [call("c2", "get_stock", "{\"sku\":\"KB-101\"}")]),
    ),
    Reply(testing.text("KB-101: 12 units.")),
  ]
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("invalid_args"), script)
  let assert client.StructuredSuccess(answer, _) = ask(hub, "Stock of KB-101?")
  let assert "KB-101: 12 units." = answer.answer
  let assert [_, second, _] =
    scripted_llm.requests(scripted_llm.drain(hub.notices))
  let assert True = string.contains(second, "c1")
  let assert True = string.contains(second, "sku")
  // ask_assistant and one get_stock: two Relay invocations, not three.
  let started =
    events(telemetry.records(hub.telemetry), "relay")
    |> list.filter(fn(event) { string.starts_with(event, "invocation.started") })
  let assert 2 = list.length(started)
  tool_hub.stop(hub)
}

// --- advanced: cancellation --------------------------------------------------------------

/// Starts `ask_assistant` on Relay's own client in another process, waits
/// until the model stream is held open, and returns the client and the
/// caller's outcome.
fn ask_in_background(
  hub: tool_hub.Hub,
) -> #(client.Client, process.Subject(client.ToolCallOutcome(assistant.Answer))) {
  let assert Ok(mcp) = tool_hub.assistant_client(hub, 15_000)
  let caller = process.new_subject()
  process.spawn(fn() {
    process.send(
      caller,
      client.call_definition(
        mcp,
        assistant.ask_assistant(),
        assistant.Question("Anything in stock?"),
      ),
    )
  })
  let assert True = wait_for(hub.notices, scripted_llm.StreamHeld, 5000)
  #(mcp, caller)
}

fn cancelled_run(hub: tool_hub.Hub) -> run.Status {
  let assert [id] = run_ids(telemetry.records(hub.telemetry))
  let assert Ok(parsed) = run.parse_id(id)
  let assert Ok(desk) =
    assistant.agent_for(hub.assistant, http_gun_telemetry.new_id())
  let assert Ok(handle) =
    fabric.open(hub.store, desk, hub.assistant.context, parsed)
  let assert Ok(status) = fabric.await(handle, 2000)
  status
}

/// An MCP client on Relay's own client (a buffered `application/json` call)
/// disconnects mid-answer. Relay kills the invocation's worker, the app's
/// monitor cancels the fabric run, fabric kills the model call, and the
/// provider's stream closes.
pub fn disconnecting_mcp_client_cancels_run_and_model_stream_test() {
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("cancel_close"), [Hold])
  let #(mcp, caller) = ask_in_background(hub)
  // The MCP client goes away.
  client.close(mcp)
  let assert True = stream_closed_within(hub.notices, 3000)
  let assert Ok(client.TransportFailure(_)) = process.receive(caller, 2000)

  process.sleep(100)
  let records = telemetry.records(hub.telemetry)
  let assert True = telemetry.has(records, "relay", "invocation.cancelled")
  let assert True = telemetry.has(records, "fabric", "run.cancel")
  let assert run.Finished(run.Cancelled) = cancelled_run(hub)
  tool_hub.stop(hub)
}

/// Without the app's monitor, the same disconnect stops only the Relay
/// worker: the fabric run and its model stream keep going.
pub fn disconnect_without_the_bridge_leaves_the_run_running_test() {
  let settings =
    tool_hub.Settings(
      ..tool_hub.settings("cancel_unbridged"),
      cancel_with_caller: False,
    )
  let assert Ok(hub) = tool_hub.start(settings, [Hold])
  let #(mcp, _caller) = ask_in_background(hub)
  client.close(mcp)
  let assert False = stream_closed_within(hub.notices, 1000)
  let records = telemetry.records(hub.telemetry)
  let assert True = telemetry.has(records, "relay", "invocation.cancelled")
  let assert False = telemetry.has(records, "fabric", "run.cancel")
  let assert [id] = run_ids(records)
  let assert Ok(parsed) = run.parse_id(id)
  let assert Ok(_) = fabric.cancel_stored(hub.store, parsed)
  let assert True = stream_closed_within(hub.notices, 3000)
  tool_hub.stop(hub)
}

/// MCP 2026-07-28 cancels a Streamable HTTP request by closing its
/// connection; `notifications/cancelled` is neither required nor expected
/// there. Relay answers such a notification 202 and leaves the call alone;
/// closing the caller's connection cancels it.
pub fn cancelled_notification_is_ignored_and_disconnect_cancels_test() {
  let assert Ok(hub) =
    tool_hub.start(tool_hub.settings("cancel_notify"), [Hold])
  let #(mcp, _caller) = ask_in_background(hub)
  let assert Ok(wire) = tool_hub.provider_client(hub.telemetry)
  let port = http.http_server_port(hub.assistant_server)
  let assert Ok(http_gun.Buffered(response: accepted, ..)) =
    http_gun.send(wire, cancelled_notification(port, 1))
  let assert 202 = accepted.status
  let assert False = stream_closed_within(hub.notices, 800)
  let assert False =
    telemetry.has(
      telemetry.records(hub.telemetry),
      "relay",
      "invocation.cancelled",
    )
  // The spec's cancellation: the caller closes its connection.
  client.close(mcp)
  let assert True = stream_closed_within(hub.notices, 3000)
  process.sleep(100)
  let records = telemetry.records(hub.telemetry)
  let assert True = telemetry.has(records, "relay", "invocation.cancelled")
  let assert True = telemetry.has(records, "fabric", "run.cancel")
  let _ = http_gun.stop(wire)
  tool_hub.stop(hub)
}

/// A `notifications/cancelled` POST, which Relay's client cannot send.
fn cancelled_notification(port: Int, id: Int) -> request.Request(BitArray) {
  let meta =
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ])
  let body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("method", json.string("notifications/cancelled")),
      #("params", json.object([#("requestId", json.int(id)), #("_meta", meta)])),
    ])
  request.new()
  |> request.set_method(gleam_http.Post)
  |> request.set_scheme(gleam_http.Http)
  |> request.set_host("127.0.0.1")
  |> request.set_port(port)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("accept", "application/json")
  |> request.set_header("mcp-protocol-version", "2026-07-28")
  |> request.set_header("mcp-method", "notifications/cancelled")
  |> request.set_body(bit_array.from_string(json.to_string(body)))
}

/// Relay's client gives up after its timeout but keeps its connection open
/// (gun cancels only the stream), so the server keeps working until the
/// caller closes the whole client.
pub fn relay_client_timeout_leaves_the_run_going_until_close_test() {
  let assert Ok(hub) =
    tool_hub.start(tool_hub.settings("cancel_timeout"), [Hold])
  let assert Ok(mcp) = tool_hub.assistant_client(hub, 300)
  let assert client.TransportFailure(client.RequestTimedOut) =
    client.call_definition(
      mcp,
      assistant.ask_assistant(),
      assistant.Question("Anything in stock?"),
    )
  let assert True = wait_for(hub.notices, scripted_llm.StreamHeld, 2000)
  let assert False = stream_closed_within(hub.notices, 800)
  let assert False =
    telemetry.has(telemetry.records(hub.telemetry), "fabric", "run.cancel")
  client.close(mcp)
  let assert True = stream_closed_within(hub.notices, 3000)
  let assert run.Finished(run.Cancelled) = cancelled_run(hub)
  tool_hub.stop(hub)
}
