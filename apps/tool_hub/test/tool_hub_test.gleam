import fabric
import fabric/run
import fabric_relay
import gleam/erlang/process
import gleam/http as gleam_http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import gleam/time/duration
import gleeunit
import http_gun
import http_gun/cancellation
import http_gun/error
import json/blueprint/contract
import json/blueprint/value.{type Value}
import llm_wire/testing
import relay/client
import relay/content
import relay/http
import relay/testing as relay_testing
import relay/tool as relay_tool
import sinal/correlation.{type Correlation}
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
) -> Result(client.ToolResult(assistant.Answer), client.Error) {
  let assert Ok(mcp) = tool_hub.assistant_client(hub, duration.seconds(15))
  let outcome =
    client.call(mcp, assistant.ask_assistant(), assistant.Question(question))
  client.close(mcp)
  outcome
}

/// The question under a correlation the caller chose, to follow it.
fn ask_as(
  hub: tool_hub.Hub,
  correlation: Correlation,
  question: String,
) -> Result(client.ToolResult(assistant.Answer), client.Error) {
  let assert Ok(mcp) = tool_hub.assistant_client(hub, duration.seconds(15))
  let outcome =
    client.call(
      client.with_correlation(mcp, correlation),
      assistant.ask_assistant(),
      assistant.Question(question),
    )
  client.close(mcp)
  outcome
}

fn text_of(blocks: List(content.ContentBlock)) -> String {
  list.map(blocks, fn(block) {
    case block {
      content.TextContent(text, ..) -> text
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
      "fabric", "run.start", telemetry.RunKey(id, _) -> Ok(id)
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

/// Holds an action on the hub, set once the hub exists, so that a script
/// step (in the provider's process) can run it.
type Later {
  SetAction(fn() -> Nil)
  RunAction(process.Subject(Nil))
}

fn later() -> process.Subject(Later) {
  let assert Ok(started) =
    actor.new(None)
    |> actor.on_message(fn(action, message) {
      case message, action {
        SetAction(action), _ -> actor.continue(Some(action))
        RunAction(reply), Some(action) -> {
          action()
          process.send(reply, Nil)
          actor.continue(None)
        }
        RunAction(reply), None -> {
          process.send(reply, Nil)
          actor.continue(None)
        }
      }
    })
    |> actor.start
  started.data
}

fn run_later(action: process.Subject(Later)) -> fn() -> Nil {
  fn() { process.call(action, 3000, RunAction) }
}

// --- common path ------------------------------------------------------------------

/// An MCP client calls `ask_assistant`; the agent searches, checks stock and
/// reserves on the inventory MCP server, then answers.
pub fn common_path_answers_through_both_mcp_servers_test() {
  let assert Ok(hub) =
    tool_hub.start(tool_hub.settings("common"), tool_hub.demo_script())
  let question = correlation.unique()
  let assert Ok(result) = ask_as(hub, question, tool_hub.demo_question)
  let assert client.Succeeded(answer, _) = result
  let assert True = string.contains(answer.answer, "reservation R-1")
  // The result names its run, so a caller needs no side channel.
  let assert [run_id] = run_ids(telemetry.records(hub.telemetry))
  let assert Some(named) = fabric_relay.run_of(result)
  let assert True = run.id_to_string(named) == run_id

  // The reservation really happened on the inventory server.
  let assert Ok(client.Succeeded(stock, _)) =
    client.call(hub.peer, inventory.get_stock(), inventory.StockQuery("KB-101"))
  let assert 10 = stock.on_hand

  // The model saw each typed result on its next turn.
  let requests = scripted_llm.requests(scripted_llm.drain(hub.notices))
  let assert [_, second, third, fourth] = requests
  let assert True = string.contains(second, "Ergonomic keyboard")
  let assert True = string.contains(third, "\\\"on_hand\\\":12")
  let assert True =
    string.contains(fourth, "\\\"reservation_id\\\":\\\"R-1\\\"")

  // Telemetry: fabric joins on the run id; http_gun, llm_wire and the
  // assistant server's relay events join on the question's correlation.
  let followed = telemetry.follow(hub.telemetry, question)
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
  // The client labels say which HTTP events came from the MCP caller, the
  // model provider and the agent's Relay client for the inventory, which all
  // run on HTTP Gun and carry the same correlation.
  let labels =
    followed.joined
    |> list.filter(fn(record) { record.package == "http_gun" })
    |> list.map(fn(record) { list.first(string.split(record.detail, ": ")) })
    |> list.unique
  let assert [
    Ok("assistant_caller"),
    Ok("tool_hub_provider"),
    Ok("inventory_peer"),
  ] = labels
  // Every llm_wire event reads the correlation from the HTTP Gun view.
  let assert True = telemetry.count(followed.joined, "llm_wire") >= 16
  let assert 0 = telemetry.count(followed.unjoined, "llm_wire")
  // Relay: the caller's correlation crosses the wire to the assistant
  // server, and the agent's inventory client carries the run's on to the
  // inventory server, so every Relay event of the question joins, on the
  // client and server side alike.
  let started = fn(records) {
    events(records, "relay")
    |> list.filter(fn(event) { string.starts_with(event, "invocation.started") })
  }
  let assert [
    "invocation.started assistant: tools/call tool=ask_assistant",
    "invocation.started inventory: tools/call tool=search_products",
    "invocation.started inventory: tools/call tool=get_stock",
    "invocation.started inventory: tools/call tool=reserve_stock",
  ] = started(followed.joined)
  let calls =
    events(followed.joined, "relay")
    |> list.filter(fn(event) { string.starts_with(event, "client.call") })
    |> list.map(fn(event) {
      string.split(event, " CallCompleted") |> list.first |> unwrap_text
    })
  let assert [
    "client.call inventory_peer: tools/call tool=search_products",
    "client.call inventory_peer: tools/call tool=get_stock",
    "client.call inventory_peer: tools/call tool=reserve_stock",
    "client.call assistant_caller: tools/call tool=ask_assistant",
  ] = calls
  // What does not join is the test's own stock check on the hub's peer,
  // which mints a correlation of its own.
  let assert ["client.call inventory_peer: tools/call tool=get_stock"] =
    events(followed.unjoined, "relay")
    |> list.filter(fn(event) { string.starts_with(event, "client.call") })
    |> list.map(fn(event) {
      string.split(event, " CallCompleted") |> list.first |> unwrap_text
    })
  let assert ["invocation.started inventory: tools/call tool=get_stock"] =
    started(followed.unjoined)
  let assert 0 = telemetry.count(followed.unjoined, "llm_wire")
  tool_hub.stop(hub)
}

fn unwrap_text(found: Result(String, Nil)) -> String {
  case found {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

// --- advanced: one definition, three vocabularies ------------------------------------

/// The same Blueprint codec backs the Relay listing, the fabric tool and the
/// schema llm_wire sends to the model.
pub fn typed_tool_schema_is_identical_in_all_three_places_test() {
  let assert Ok(hub) =
    tool_hub.start(tool_hub.settings("schemas"), tool_hub.demo_script())
  let assert Ok(client.Succeeded(_, _)) = ask(hub, tool_hub.demo_question)
  let assert Ok(native) = contract.from_codec(inventory.search_query_codec())

  let assert Ok(listed) = client.list_tools(hub.peer)
  let assert Ok(declaration) =
    list.find(listed, fn(tool) { tool.name == "search_products" })
  let assert Ok(from_relay) = relay_tool.input_contract(declaration)
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
    Reply(scripted_llm.answer(
      "The Wireless mouse (MS-300) has 40 units in Porto.",
    )),
  ]
  let settings =
    tool_hub.Settings(
      ..tool_hub.settings("dynamic"),
      mounting: tool_hub.Discovered,
    )
  let assert Ok(hub) = tool_hub.start(settings, script)
  let assert Ok(client.Succeeded(answer, _)) =
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
    Reply(scripted_llm.answer("There is no product ZZ-999.")),
  ]
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("is_error"), script)
  let assert Ok(client.Succeeded(answer, _)) = ask(hub, "Stock of ZZ-999?")
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

/// The inventory server goes away mid-run before a reservation. The client
/// reports that nothing was sent, so the failure is definite: the model sees
/// it and answers, and nothing waits for reconciliation.
pub fn unreachable_server_before_a_reservation_is_explained_test() {
  let stop = later()
  let script = [
    Reply(
      testing.tool_calls("", [
        call("c1", "search_products", "{\"text\":\"keyboard\",\"limit\":5}"),
      ]),
    ),
    After(
      run_later(stop),
      testing.tool_calls("", [
        call("c2", "reserve_stock", "{\"sku\":\"KB-101\",\"quantity\":1}"),
      ]),
    ),
    Reply(scripted_llm.answer("The inventory is down; nothing was reserved.")),
  ]
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("unreachable"), script)
  process.send(stop, SetAction(fn() { http.stop(hub.inventory) }))
  let assert Ok(client.Succeeded(answer, _)) = ask(hub, "Reserve a keyboard.")
  let assert "The inventory is down; nothing was reserved." = answer.answer
  let assert [_, _, third] =
    scripted_llm.requests(scripted_llm.drain(hub.notices))
  let assert True = string.contains(third, "the MCP call failed")
  // `ConnectFailed`, whose evidence is `NotSent`.
  let assert True = string.contains(third, "(connect_failed)")
  let assert True =
    list.contains(
      events(telemetry.records(hub.telemetry), "fabric"),
      "tool.stop reserve_stock ModelVisible",
    )
  tool_hub.stop(hub)
}

/// A reservation that outlives the client's timeout may have happened, so
/// the effect is uncertain: the run stops for reconciliation, and
/// `ask_assistant` says so as text and as structured data.
pub fn timed_out_reservation_is_uncertain_test() {
  let stall = later()
  let script = [
    Reply(
      testing.tool_calls("", [
        call("c1", "search_products", "{\"text\":\"keyboard\",\"limit\":5}"),
      ]),
    ),
    After(
      run_later(stall),
      testing.tool_calls("", [
        call("c2", "reserve_stock", "{\"sku\":\"KB-101\",\"quantity\":1}"),
      ]),
    ),
    Reply(scripted_llm.answer("unreachable")),
  ]
  let settings =
    tool_hub.Settings(
      ..tool_hub.settings("timed_out"),
      inventory_timeout: duration.milliseconds(300),
    )
  let assert Ok(hub) = tool_hub.start(settings, script)
  process.send(
    stall,
    SetAction(fn() { inventory.stall(hub.catalog, duration.milliseconds(1500)) }),
  )
  let assert Ok(client.ToolFailed(blocks, Some(facts))) =
    ask(hub, "Reserve a keyboard.")
  let assert True = string.contains(text_of(blocks), "unknown status")
  // The run to reconcile is data, not only prose.
  let assert [run_id] = run_ids(telemetry.records(hub.telemetry))
  let assert value.Object(fields) = facts
  let assert Ok(value.String("outcome_unknown")) =
    list.key_find(fields, "error")
  let assert Ok(value.String(found)) = list.key_find(fields, "run_id")
  let assert True = found == run_id
  let assert Ok(value.Array([value.Object(effect)])) =
    list.key_find(fields, "uncertain")
  let assert Ok(value.String("reserve_stock")) = list.key_find(effect, "tool")
  let assert Ok(value.String(evidence)) = list.key_find(effect, "evidence")
  let assert True = string.contains(evidence, "timed_out.maybe_sent")
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
  let stop = later()
  let script = [
    After(
      run_later(stop),
      testing.tool_calls("", [call("c1", "get_stock", "{\"sku\":\"KB-101\"}")]),
    ),
    Reply(scripted_llm.answer("The inventory is down; try later.")),
  ]
  let assert Ok(hub) =
    tool_hub.start(tool_hub.settings("read_only_down"), script)
  process.send(stop, SetAction(fn() { http.stop(hub.inventory) }))
  let assert Ok(client.Succeeded(answer, _)) = ask(hub, "Stock of KB-101?")
  let assert "The inventory is down; try later." = answer.answer
  let assert [_, second] =
    scripted_llm.requests(scripted_llm.drain(hub.notices))
  let assert True = string.contains(second, "the MCP call failed")
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
    Reply(scripted_llm.answer("KB-101: 12 units.")),
  ]
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("invalid_args"), script)
  let assert Ok(client.Succeeded(answer, _)) = ask(hub, "Stock of KB-101?")
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

/// Starts `ask_assistant` on Relay's own client in another process, through
/// `view` of it, waits until the model stream is held open, and returns the
/// client and the caller's outcome.
fn ask_in_background(
  hub: tool_hub.Hub,
  view: fn(client.Client) -> client.Client,
) -> #(
  client.Client,
  process.Subject(Result(client.ToolResult(assistant.Answer), client.Error)),
) {
  let assert Ok(mcp) = tool_hub.assistant_client(hub, duration.seconds(15))
  let caller = process.new_subject()
  process.spawn(fn() {
    process.send(
      caller,
      client.call(
        view(mcp),
        assistant.ask_assistant(),
        assistant.Question("Anything in stock?"),
      ),
    )
  })
  let assert True = wait_for(hub.notices, scripted_llm.StreamHeld, 5000)
  #(mcp, caller)
}

fn same(mcp: client.Client) -> client.Client {
  mcp
}

fn cancelled_run(hub: tool_hub.Hub) -> run.Status(assistant.Answer) {
  let assert [id] = run_ids(telemetry.records(hub.telemetry))
  let assert Ok(parsed) = run.parse_id(id)
  let assert Ok(handle) =
    fabric.open(hub.store, hub.assistant.agent, hub.assistant.context, parsed)
  let assert Ok(status) = fabric.await(handle, within: duration.seconds(2))
  status
}

/// An MCP client disconnects mid-answer. Relay fires the handler's
/// `tool.cancelled` selector, the handler cancels the fabric run, fabric
/// kills the model call, and the provider's stream closes.
pub fn disconnecting_mcp_client_cancels_run_and_model_stream_test() {
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("cancel_close"), [Hold])
  let #(mcp, caller) = ask_in_background(hub, same)
  // The MCP client goes away.
  client.close(mcp)
  let assert True = stream_closed_within(hub.notices, 3000)
  let assert Ok(Error(_)) = process.receive(caller, 2000)

  process.sleep(100)
  let records = telemetry.records(hub.telemetry)
  let assert True = telemetry.has(records, "relay", "invocation.cancelled")
  let assert True = telemetry.has(records, "fabric", "run.cancel")
  let assert run.Finished(run.Cancelled) = cancelled_run(hub)
  tool_hub.stop(hub)
}

/// A call with an idempotency key names its run, so the run outlives the
/// call: the same disconnect that cancels an unkeyed call leaves this one
/// going, and the model stream open.
pub fn keyed_call_outlives_its_disconnect_test() {
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("cancel_keyed"), [Hold])
  let #(mcp, _caller) =
    ask_in_background(hub, client.with_idempotency_key(_, "question-1"))
  client.close(mcp)
  let assert False = stream_closed_within(hub.notices, 1000)
  let records = telemetry.records(hub.telemetry)
  let assert True = telemetry.has(records, "relay", "invocation.cancelled")
  let assert False = telemetry.has(records, "fabric", "run.cancel")
  // The key names the run, so the application can find it.
  let id =
    fabric_relay.run_id(
      assistant.ask_assistant(),
      principal: fabric_relay.anonymous,
      key: "question-1",
    )
  let assert [started] = run_ids(records)
  let assert True = started == run.id_to_string(id)
  let assert Ok(_) = fabric.cancel_stored(hub.store, id)
  let assert True = stream_closed_within(hub.notices, 3000)
  tool_hub.stop(hub)
}

/// The caller disconnects while the model is still answering and calls again
/// with the same key: the retry reaches the same run, which the provider
/// served once.
pub fn retried_keyed_call_reaches_the_same_run_test() {
  let script = [
    After(fn() { process.sleep(600) }, scripted_llm.answer("KB-101: 12 units.")),
  ]
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("retry_keyed"), script)
  let keyed = client.with_idempotency_key(_, "question-2")
  let assert Ok(first) = tool_hub.assistant_client(hub, duration.seconds(15))
  let caller = process.new_subject()
  process.spawn(fn() {
    process.send(
      caller,
      client.call(
        keyed(first),
        assistant.ask_assistant(),
        assistant.Question("Stock of KB-101?"),
      ),
    )
  })
  process.sleep(200)
  client.close(first)
  let assert Ok(Error(_)) = process.receive(caller, 2000)
  let assert Ok(second) = tool_hub.assistant_client(hub, duration.seconds(15))
  let assert Ok(client.Succeeded(answer, _)) =
    client.call(
      keyed(second),
      assistant.ask_assistant(),
      assistant.Question("Stock of KB-101?"),
    )
  let assert "KB-101: 12 units." = answer.answer
  client.close(second)
  let assert [_] = run_ids(telemetry.records(hub.telemetry))
  let assert 1 =
    list.length(scripted_llm.requests(scripted_llm.drain(hub.notices)))
  tool_hub.stop(hub)
}

/// MCP 2026-07-28 cancels a Streamable HTTP request by closing its
/// connection; `notifications/cancelled` is neither required nor expected
/// there. Relay answers such a notification 202 and leaves the call alone;
/// closing the caller's connection cancels it.
pub fn cancelled_notification_is_ignored_and_disconnect_cancels_test() {
  let assert Ok(hub) =
    tool_hub.start(tool_hub.settings("cancel_notify"), [Hold])
  let #(mcp, _caller) = ask_in_background(hub, same)
  let accepted =
    http.handle(
      hub.assistant_server,
      relay_testing.request("notifications/cancelled", [
        #("requestId", json.int(1)),
      ]),
    )
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
  tool_hub.stop(hub)
}

/// Cancelling one call through a token view closes that call's connection,
/// so the server cancels the run, and the client stays usable.
pub fn cancelling_one_call_keeps_the_client_open_test() {
  let assert Ok(hub) = tool_hub.start(tool_hub.settings("cancel_token"), [Hold])
  use token <- cancellation.with_token
  let #(mcp, caller) =
    ask_in_background(hub, client.with_cancellation(_, token))
  cancellation.cancel(token)
  let assert True = stream_closed_within(hub.notices, 3000)
  let assert Ok(Error(client.Cancelled(client.MaybeSent))) =
    process.receive(caller, 2000)
  process.sleep(100)
  let assert run.Finished(run.Cancelled) = cancelled_run(hub)
  // The same client still answers.
  let assert Ok([listed]) = client.list_tools(mcp)
  let assert "ask_assistant" = listed.name
  client.close(mcp)
  tool_hub.stop(hub)
}

/// The provider client admits loopback only: a public address is refused
/// before anything is sent, and the failure kind says so.
pub fn provider_client_refuses_public_hosts_test() {
  let assert Ok(client) = tool_hub.provider_client("policy_check")
  let assert Error(failure) =
    request.new()
    |> request.set_host("203.0.113.9")
    |> request.set_scheme(gleam_http.Http)
    |> request.set_body(<<>>)
    |> http_gun.send(client, _)
  let assert error.Refused = error.kind(failure)
  let assert error.NotSent = error.evidence(failure)
  let assert False = error.is_retryable(failure, idempotent: True)
  http_gun.stop(client)
}

/// Relay's client gives up after its timeout and closes that call's
/// connection, which MCP defines as cancellation: the server cancels the run
/// without the caller closing the client.
pub fn relay_client_timeout_cancels_the_run_test() {
  let assert Ok(hub) =
    tool_hub.start(tool_hub.settings("cancel_timeout"), [Hold])
  let assert Ok(mcp) =
    tool_hub.assistant_client(hub, duration.milliseconds(300))
  let assert Error(client.TimedOut(client.MaybeSent)) =
    client.call(
      mcp,
      assistant.ask_assistant(),
      assistant.Question("Anything in stock?"),
    )
  let assert True = stream_closed_within(hub.notices, 3000)
  process.sleep(100)
  let assert True =
    telemetry.has(telemetry.records(hub.telemetry), "fabric", "run.cancel")
  let assert run.Finished(run.Cancelled) = cancelled_run(hub)
  client.close(mcp)
  tool_hub.stop(hub)
}
