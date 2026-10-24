import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/config as http_config
import http_gun/destination
import json/blueprint/codec
import json/blueprint/value
import llm_wire
import llm_wire/error as wire_error
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/tool as wire_tool
import relay/client
import relay/http
import relay/server
import relay/tool
import scripted_provider

pub type Lookup {
  Lookup(sku: String)
}

pub type InventoryItem {
  InventoryItem(sku: String, name: String, quantity: Int)
}

const inventory = [
  InventoryItem("A-100", "Ada Lovelace notebook", 7),
  InventoryItem("B-200", "Beam coffee mug", 3),
]

pub fn lookup_codec() -> codec.Codec(Lookup) {
  use sku <- codec.field(
    "sku",
    codec.describe(codec.string(), "Inventory SKU"),
    get: fn(input) { input.sku },
  )
  codec.success(Lookup(sku))
}

pub fn item_codec() -> codec.Codec(InventoryItem) {
  use sku <- codec.field("sku", codec.string(), get: fn(item) { item.sku })
  use name <- codec.field("name", codec.string(), get: fn(item) { item.name })
  use quantity <- codec.field("quantity", codec.int(), get: fn(item) {
    item.quantity
  })
  codec.success(InventoryItem(sku, name, quantity))
}

pub fn find(item: Lookup) -> Result(InventoryItem, String) {
  case list_find(inventory, item.sku) {
    Ok(found) -> Ok(found)
    Error(Nil) -> Error("inventory record not found")
  }
}

fn list_find(
  items: List(InventoryItem),
  sku: String,
) -> Result(InventoryItem, Nil) {
  case items {
    [] -> Error(Nil)
    [head, ..tail] ->
      case head.sku == sku {
        True -> Ok(head)
        False -> list_find(tail, sku)
      }
  }
}

/// One admitted native contract is shared by registration, calls, and the
/// application-owned provider declaration adapter.
pub fn inventory_definition() -> Result(
  tool.Definition(Lookup, InventoryItem),
  String,
) {
  tool.try_define("inventory_lookup", lookup_codec(), item_codec())
  |> result.map_error(tool.describe_define_error)
  |> result.map(fn(definition) {
    definition
    |> tool.with_title("Inventory lookup")
    |> tool.with_description("Look up one synthetic inventory record by SKU")
    |> tool.with_read_only_hint(True)
    |> tool.with_destructive_hint(False)
    |> tool.with_idempotent_hint(True)
    |> tool.with_open_world_hint(False)
  })
}

fn observed_find(
  input: Lookup,
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> Result(InventoryItem, String) {
  process.send(invocations, input.sku)
  let outcome = find(input)
  case outcome {
    Ok(_) -> Nil
    Error(reason) -> process.send(application_errors, reason)
  }
  outcome
}

pub fn relay_tool(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> tool.Tool(Nil) {
  tool.handle(definition, fn(input) {
    observed_find(input, invocations, application_errors)
  })
}

pub fn rendered_relay_tool(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> tool.Tool(Nil) {
  tool.handle_with_error_renderer(
    definition,
    fn(input) { observed_find(input, invocations, application_errors) },
    tool.error_message,
  )
}

pub fn json_text_error_relay_tool(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> tool.Tool(Nil) {
  tool.handle_with_error_renderer(
    definition,
    fn(input) { observed_find(input, invocations, application_errors) },
    fn(reason) { tool.error_message(json.to_string(json.string(reason))) },
  )
}

/// Relay and LLM Wire have separate name admission. The declaration is derived
/// from the same Relay definition without adding a package dependency.
pub fn llm_tool(
  definition: tool.Definition(Lookup, InventoryItem),
) -> wire_tool.Tool {
  let metadata = tool.declaration(definition)
  wire_tool.new(
    tool.name(definition),
    option.unwrap(metadata.description, ""),
    tool.input_codec(definition),
  )
}

/// Admits a remote declaration only when Blueprint supports its finite schema.
pub fn llm_discovered_tool(
  declaration: tool.Declaration,
) -> Result(wire_tool.Tool, String) {
  use contract <- result.try(
    tool.input_contract(declaration) |> result.map_error(string.inspect),
  )
  wire_tool.from_contract(
    declaration.name,
    option.unwrap(declaration.description, ""),
    contract,
  )
  |> result.map_error(string.inspect)
}

fn serve_tool(registered: tool.Tool(Nil)) -> Result(http.Handler(Nil), String) {
  server.new([registered])
  |> http.new
  |> http.start
  |> result.map_error(http.describe_start_error)
}

pub fn start_relay_server_observed(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> Result(http.Handler(Nil), String) {
  serve_tool(relay_tool(definition, invocations, application_errors))
}

pub fn start_rendered_relay_server(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> Result(http.Handler(Nil), String) {
  serve_tool(rendered_relay_tool(definition, invocations, application_errors))
}

pub fn start_json_text_error_relay_server(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> Result(http.Handler(Nil), String) {
  serve_tool(json_text_error_relay_tool(
    definition,
    invocations,
    application_errors,
  ))
}

pub fn connect_relay(
  relay_server: http.Handler(Nil),
) -> Result(client.Client, client.Error) {
  let url = "http://127.0.0.1:" <> int.to_string(http.port(relay_server)) <> "/"
  use settings <- result.try(client.http(url))
  settings
  |> client.with_timeout(duration.seconds(2))
  |> client.with_max_response_bytes(1_048_576)
  |> client.connect()
}

pub fn execute_lookup(
  relay_client: client.Client,
  definition: tool.Definition(Lookup, InventoryItem),
  input: Lookup,
) -> Result(client.ToolResult(InventoryItem), client.Error) {
  client.call(relay_client, definition, input)
}

// The application keeps the conversation and settings for the next tool turn.
pub type Conversation {
  Conversation(
    config: llm_wire.Config,
    request: llm_wire.Request(String),
    prepared: llm_wire.Prepared(String),
  )
}

pub fn prepare(
  config: llm_wire.Config,
  request: llm_wire.Request(String),
) -> Result(Conversation, wire_error.PrepareError) {
  use prepared <- result.try(llm_wire.prepare(config, request))
  Ok(Conversation(config, request, prepared))
}

pub fn prepare_openai(
  definition: tool.Definition(Lookup, InventoryItem),
  endpoint: String,
  prompt: String,
) -> Result(Conversation, wire_error.PrepareError) {
  let settings =
    openai.new("local-scripted-provider-key")
    |> openai.config
    |> llm_wire.with_endpoint(endpoint)
    |> llm_wire.with_limit(limit.ResponseBodyBytes, 1_048_576)
    |> llm_wire.with_idle_timeout(llm_wire.After(duration.seconds(3)))
  let request =
    llm_wire.request("local-scripted-model", [llm_wire.user(prompt)])
    |> llm_wire.with_tools([llm_tool(definition)])
  prepare(settings, request)
}

pub fn prepare_discovered_openai(
  declaration: tool.Declaration,
  endpoint: String,
) -> Result(Conversation, String) {
  use tool <- result.try(
    llm_discovered_tool(declaration) |> result.map_error(string.inspect),
  )
  let settings =
    openai.new("local-scripted-provider-key")
    |> openai.config
    |> llm_wire.with_endpoint(endpoint)
  let request =
    llm_wire.request("local-scripted-model", [llm_wire.user("Find SKU A-100")])
    |> llm_wire.with_tools([tool])
  prepare(settings, request) |> result.map_error(string.inspect)
}

pub fn call_discovered_value(
  relay_client: client.Client,
  declaration: tool.Declaration,
  arguments: value.Value,
) -> Result(String, String) {
  case client.call_discovered(relay_client, declaration, arguments) {
    Ok(client.Succeeded(Some(value), _)) -> Ok(value.to_string(value))
    Ok(client.Succeeded(None, _)) ->
      Error("tool returned content without structured output")
    Ok(client.InputRequired(_, _)) -> Error("tool requested additional input")
    Ok(client.ToolFailed(_, _)) -> Error("tool reported an application failure")
    Error(problem) -> Error(client.describe_error(problem))
  }
}

pub fn provider_run(
  client: http_gun.Client,
  conversation: Conversation,
) -> Result(llm_wire.Outcome(String), llm_wire.Failure) {
  llm_wire.run(client, conversation.prepared)
}

pub fn provider_continue(
  conversation: Conversation,
  turn: message.AssistantTurn,
  results: List(message.Message),
) -> Result(Conversation, wire_error.PrepareError) {
  prepare(
    conversation.config,
    llm_wire.append(conversation.request, [message.Assistant(turn), ..results]),
  )
}

pub fn encode_item(
  definition: tool.Definition(Lookup, InventoryItem),
  item: InventoryItem,
) -> Result(String, codec.EncodeError) {
  codec.encode_json(structured_codec(definition), item)
}

pub fn decode_lookup(
  definition: tool.Definition(Lookup, InventoryItem),
  source: String,
) -> Result(Lookup, codec.DecodeError) {
  codec.decode_json(tool.input_codec(definition), source)
}

pub fn decode_item(
  definition: tool.Definition(Lookup, InventoryItem),
  source: String,
) -> Result(InventoryItem, codec.DecodeError) {
  codec.decode_json(structured_codec(definition), source)
}

pub fn main() -> Nil {
  let assert Ok(http_client) =
    http_gun.start(
      http_config.default()
      |> http_config.with_destination(destination.loopback_only()),
    )
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(definition) = inventory_definition()
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.Lookup("A-100"))
  let assert Ok(relay_server) =
    start_relay_server_observed(definition, invocations, application_errors)
  let assert Ok(relay_client) = connect_relay(relay_server)
  let endpoint =
    "http://127.0.0.1:"
    <> int.to_string(scripted_provider.port(provider))
    <> "/v1"
  let assert Ok(prepared) =
    prepare_openai(definition, endpoint, "Find SKU A-100")
  let answer =
    run_lookup_example(http_client, definition, prepared, relay_client)
  client.close(relay_client)
  http.stop(relay_server)
  scripted_provider.stop(provider)
  let assert True = scripted_provider.await_worker_stopped(provider, 1000)
  http_gun.stop(http_client)
  case answer {
    Ok(text) -> io.println(text)
    Error(reason) -> {
      io.println("ecosystem pilot failed: " <> reason)
      panic as reason
    }
  }
}

fn run_lookup_example(
  http_client: http_gun.Client,
  definition: tool.Definition(Lookup, InventoryItem),
  prepared: Conversation,
  relay_client: client.Client,
) -> Result(String, String) {
  use run_result <- result.try(
    provider_run(http_client, prepared)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  case run_result {
    llm_wire.NeedsTools(
      turn: message.AssistantTurn(calls: [call], ..) as turn,
      ..,
    ) -> {
      use input <- result.try(
        decode_lookup(definition, call.arguments_json)
        |> result.map_error(fn(error) { string.inspect(error) }),
      )
      case execute_lookup(relay_client, definition, input) {
        Ok(client.Succeeded(item, _)) -> {
          use encoded <- result.try(
            encode_item(definition, item)
            |> result.map_error(fn(error) { string.inspect(error) }),
          )
          use follow_up <- result.try(
            provider_continue(prepared, turn, [
              llm_wire.tool_result(call, encoded),
            ])
            |> result.map_error(fn(error) { string.inspect(error) }),
          )
          use final_result <- result.try(
            provider_run(http_client, follow_up)
            |> result.map_error(fn(error) { string.inspect(error) }),
          )
          case final_result {
            llm_wire.Answer(text:, ..) -> Ok(text)
            _ -> Error("provider did not return a final text answer")
          }
        }
        Ok(client.ToolFailed(_, _)) -> Error("inventory lookup failed")
        Ok(client.InputRequired(_, _)) -> Error("Relay lookup requires input")
        Error(problem) -> Error(client.describe_error(problem))
      }
    }
    llm_wire.NeedsTools(..) ->
      Error("provider returned multiple calls for the single-tool example")
    llm_wire.Answer(text:, ..) -> Ok(text)
    llm_wire.OutputLimited(..) ->
      Error("provider output reached the configured limit")
    llm_wire.Refused(reason:, ..) -> Error(reason)
  }
}

fn structured_codec(definition: tool.Definition(i, o)) -> codec.Codec(o) {
  let assert Some(codec) = tool.output_codec(definition)
  codec
}
