//// tool_hub: MCP in both directions.
////
//// 1. The "inventory" Relay server exposes typed tools.
//// 2. A fabric agent mounts them through the Relay client and answers
////    questions with a scripted LLM provider (llm_wire over http_gun).
//// 3. A second Relay server exposes that agent as the tool `ask_assistant`.

import fabric/run
import fabric/store
import fabric/tool as fabric_tool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleam/time/duration.{type Duration}
import http_gun
import http_gun/config as http_config
import http_gun/destination
import llm_wire/testing
import relay/client
import relay/http
import tool_hub/assistant.{type Assistant}
import tool_hub/inventory
import tool_hub/remote_tools
import tool_hub/scripted_llm
import tool_hub/telemetry

/// How the agent gets its tools.
pub type Mounting {
  /// From the shared Relay definitions, with native types.
  Typed
  /// From `tools/list` at startup, without native types.
  Discovered
}

pub type Hub {
  Hub(
    catalog: inventory.Catalog,
    inventory: http.Handler(Nil),
    /// The agent's MCP client for the inventory server.
    peer: client.Client,
    provider: scripted_llm.Provider,
    notices: Subject(scripted_llm.Notice),
    http: http_gun.Client,
    store: store.Store,
    telemetry: telemetry.Telemetry,
    assistant: Assistant,
    assistant_server: http.Handler(Nil),
  )
}

pub type Settings {
  Settings(
    mounting: Mounting,
    /// Names the hub's run store; unique per hub.
    name: String,
    /// Relay settings of the `ask_assistant` server, over its defaults.
    assistant_http: fn(http.Config(Nil)) -> http.Config(Nil),
    /// How long one question may take.
    budget: Duration,
    /// How long the agent's client waits for one inventory call.
    inventory_timeout: Duration,
    /// Bridge Relay cancellation to the fabric run.
    cancel_with_caller: Bool,
  )
}

pub fn settings(name: String) -> Settings {
  Settings(
    mounting: Typed,
    name:,
    assistant_http: fn(config) { config },
    budget: duration.seconds(10),
    inventory_timeout: duration.seconds(2),
    cancel_with_caller: True,
  )
}

/// The HTTP client for the model provider. http_gun refuses loopback by
/// default, so the scripted provider needs an explicit policy. The label
/// tells this client's events from any other client's. Observations go
/// through `sinal.emit`, which the app's handlers read directly.
pub fn provider_client(label: String) -> Result(http_gun.Client, String) {
  http_config.default()
  |> http_config.with_destination(
    destination.loopback_only() |> destination.only_hosts(["127.0.0.1"]),
  )
  |> http_config.with_label(label)
  |> http_gun.start
  |> result_string
}

pub fn start(
  settings: Settings,
  script: List(scripted_llm.Step),
) -> Result(Hub, String) {
  let telemetry = telemetry.start()
  let catalog = inventory.demo_catalog()
  use inventory_server <- try(inventory.serve(catalog))
  use config <- try(
    client.http(inventory.url(inventory_server)) |> result_string,
  )
  use peer <- try(
    config
    |> client.with_timeout(settings.inventory_timeout)
    |> client.with_label("inventory_peer")
    |> client.connect
    |> result_string,
  )
  let notices = process.new_subject()
  use provider <- try(scripted_llm.start(script, notices))
  use http <- try(provider_client("tool_hub_provider"))
  let runs = store.in_memory(process.new_name(settings.name <> "_runs"))
  use Nil <- try(store.start(runs) |> result_string)
  let inventory_peer = fn(context: assistant.Context) { context.inventory }
  use tools <- try(case settings.mounting {
    Typed -> Ok(typed_tools(inventory_peer))
    Discovered -> remote_tools.discover(peer, inventory_peer) |> result_string
  })
  let assistant =
    assistant.Assistant(
      store: runs,
      http:,
      settings: scripted_llm.settings(provider),
      model_id: "scripted-1",
      tools:,
      context: assistant.Context(peer),
      budget: settings.budget,
      cancel_with_caller: settings.cancel_with_caller,
      on_run: fn(id, correlation) {
        telemetry.link(telemetry, run.id_to_string(id), correlation)
      },
    )
  use assistant_server <- try(assistant.serve(
    assistant,
    settings.assistant_http,
  ))
  Ok(Hub(
    catalog:,
    inventory: inventory_server,
    peer:,
    provider:,
    notices:,
    http:,
    store: runs,
    telemetry:,
    assistant:,
    assistant_server:,
  ))
}

pub fn typed_tools(
  peer: remote_tools.Peer(assistant.Context),
) -> List(fabric_tool.Tool(assistant.Context)) {
  [
    remote_tools.mount(inventory.search_products(), peer),
    remote_tools.mount(inventory.get_stock(), peer),
    remote_tools.mount(inventory.reserve_stock(), peer),
  ]
}

pub fn stop(hub: Hub) -> Nil {
  http.stop(hub.assistant_server)
  client.close(hub.peer)
  http.stop(hub.inventory)
  scripted_llm.stop(hub.provider)
  http_gun.stop(hub.http)
  telemetry.stop(hub.telemetry)
}

/// An MCP client for the `ask_assistant` server.
pub fn assistant_client(
  hub: Hub,
  timeout: Duration,
) -> Result(client.Client, String) {
  use config <- try(
    client.http(inventory.url(hub.assistant_server)) |> result_string,
  )
  config
  |> client.with_timeout(timeout)
  |> client.with_label("assistant_caller")
  |> client.connect
  |> result_string
}

/// The model turns of the demo question.
pub fn demo_script() -> List(scripted_llm.Step) {
  [
    scripted_llm.Reply(
      testing.tool_calls("", [
        scripted_llm.call(
          "c1",
          "search_products",
          "{\"text\":\"keyboard\",\"limit\":5}",
        ),
      ]),
    ),
    scripted_llm.Reply(
      testing.tool_calls("", [
        scripted_llm.call("c2", "get_stock", "{\"sku\":\"KB-101\"}"),
      ]),
    ),
    scripted_llm.Reply(
      testing.tool_calls("", [
        scripted_llm.call(
          "c3",
          "reserve_stock",
          "{\"sku\":\"KB-101\",\"quantity\":2}",
        ),
      ]),
    ),
    scripted_llm.Reply(testing.text(
      "The Ergonomic keyboard (KB-101) has 12 units in Lisbon; reservation R-1 holds 2 of them.",
    )),
  ]
}

pub const demo_question = "Is the ergonomic keyboard in stock? If so, reserve 2."

pub fn main() -> Nil {
  let assert Ok(hub) = start(settings("tool_hub_main"), demo_script())
  io.println("tool_hub: MCP in both directions")
  io.println(
    "- inventory MCP server on "
    <> inventory.url(hub.inventory)
    <> " exposes search_products, get_stock, reserve_stock",
  )
  io.println(
    "- assistant MCP server on "
    <> inventory.url(hub.assistant_server)
    <> " exposes ask_assistant (a fabric agent)",
  )
  let assert Ok(mcp) = assistant_client(hub, duration.seconds(15))
  let assert Ok(listed) = client.list_tools(mcp)
  io.println(
    "- an MCP client lists: "
    <> string.join(list.map(listed, fn(tool) { tool.name }), ", "),
  )
  io.println("- it asks: " <> demo_question)
  case
    client.call(
      mcp,
      assistant.ask_assistant(),
      assistant.Question(demo_question),
    )
  {
    Ok(client.Succeeded(answer, _)) -> {
      io.println("- answer: " <> answer.answer)
      io.println("- run " <> answer.run_id <> ", followed across packages:")
      let followed = telemetry.follow(hub.telemetry, answer.run_id)
      followed.joined
      |> list.filter(fn(record) { record.package == "fabric" })
      |> list.each(fn(record) { io.println("    " <> telemetry.render(record)) })
      let joined = fn(package) {
        int.to_string(telemetry.count(followed.joined, package))
      }
      io.println(
        "    + "
        <> joined("http_gun")
        <> " http_gun, "
        <> joined("llm_wire")
        <> " llm_wire and "
        <> joined("relay")
        <> " relay events joined through the question's correlation",
      )
      io.println(
        "  not joinable to the run (no shared key): "
        <> int.to_string(telemetry.count(followed.unjoined, "relay"))
        <> " relay and "
        <> int.to_string(telemetry.count(followed.unjoined, "llm_wire"))
        <> " llm_wire events",
      )
    }
    Ok(client.ToolFailed(_, structured)) ->
      io.println("- ask_assistant failed: " <> string.inspect(structured))
    Ok(client.InputRequired(..)) ->
      io.println("- ask_assistant asked for input")
    Error(error) ->
      io.println("- ask_assistant failed: " <> client.describe_error(error))
  }
  let requests = scripted_llm.requests(scripted_llm.drain(hub.notices))
  io.println(
    "- the scripted provider served "
    <> int.to_string(list.length(requests))
    <> " model turns",
  )
  client.close(mcp)
  stop(hub)
}

fn try(
  result: Result(a, String),
  next: fn(a) -> Result(b, String),
) -> Result(b, String) {
  case result {
    Ok(value) -> next(value)
    Error(error) -> Error(error)
  }
}

fn result_string(result: Result(a, e)) -> Result(a, String) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> Error(string.inspect(error))
  }
}
