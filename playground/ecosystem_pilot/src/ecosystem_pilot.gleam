import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import llm_wire
import llm_wire/api
import llm_wire/types
import relay
import relay/client
import relay/server
import relay/transport/http
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
  codec.imap(codec.field("sku", codec.string()), Lookup, fn(value) {
    let Lookup(sku) = value
    sku
  })
}

pub fn item_codec() -> codec.Codec(InventoryItem) {
  let assert Ok(sku_and_name) =
    codec.combine(
      codec.required("sku", codec.string()),
      codec.required("name", codec.string()),
    )
  let assert Ok(properties) =
    codec.combine(sku_and_name, codec.required("quantity", codec.int()))
  codec.imap(
    codec.object(properties),
    fn(value) {
      let #(#(sku, name), quantity) = value
      InventoryItem(sku, name, quantity)
    },
    fn(item) { #(#(item.sku, item.name), item.quantity) },
  )
}

pub fn lookup_error_codec() -> codec.Codec(String) {
  codec.string()
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

pub fn relay_tool(
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> Result(relay.ContextTool(Nil), String) {
  use name <- result.try(
    relay.tool_name("inventory_lookup")
    |> result.map_error(fn(_) { "tool name admission failed" }),
  )
  let annotations =
    relay.tool_annotations(
      Some("Inventory lookup"),
      Some(True),
      Some(False),
      Some(True),
      Some(False),
    )
  let metadata =
    relay.tool_metadata("Look up one synthetic inventory record by SKU")
    |> relay.tool_metadata_with_annotations(annotations)
  relay.context_tool(
    name,
    metadata,
    lookup_codec(),
    item_codec(),
    lookup_error_codec(),
    fn(_context, input) {
      process.send(invocations, input.sku)
      let outcome = find(input)
      case outcome {
        Ok(_) -> Nil
        Error(reason) -> process.send(application_errors, reason)
      }
      outcome
    },
  )
  |> result.map_error(fn(_) { "tool admission failed" })
}

pub fn llm_tool() -> Result(llm_wire.ToolDefinition, llm_wire.WireError) {
  use name <- result.try(types.tool_name("inventory_lookup"))
  types.tool_from_codec(
    name,
    "Look up one synthetic inventory record by SKU",
    lookup_codec(),
  )
}

pub fn relay_server(
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> Result(server.Server(Nil), String) {
  use tool <- result.try(
    relay_tool(invocations, application_errors)
    |> result.map_error(fn(_) { "tool admission failed" }),
  )
  use registry <- result.try(
    relay.registry([tool])
    |> result.map_error(fn(_) { "registry admission failed" }),
  )
  Ok(server.server(registry))
}

pub fn start_relay_server() -> Result(http.HttpServer(Nil), String) {
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  start_relay_server_observed(invocations, application_errors)
}

pub fn start_relay_server_observed(
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> Result(http.HttpServer(Nil), String) {
  use relay_server <- result.try(relay_server(invocations, application_errors))
  http.start_http_server(
    relay_server,
    http.HttpOptions(port: 0, host: "127.0.0.1"),
  )
}

pub fn connect_relay(
  relay_server: http.HttpServer(Nil),
) -> Result(client.Client, client.ClientError) {
  client.connect(client.ClientConfig(
    host: "127.0.0.1",
    port: http.http_server_port(relay_server),
    path: "/",
    secure: False,
    timeout_ms: 2000,
    max_response_bytes: 1_048_576,
  ))
}

pub fn execute_lookup(
  relay_client: client.Client,
  input: Lookup,
) -> client.ToolCallOutcome(InventoryItem) {
  let assert Ok(name) = relay.tool_name("inventory_lookup")
  client.call_tool(relay_client, name, input, lookup_codec(), item_codec())
}

pub fn prepare_openai(
  endpoint: String,
  prompt: String,
) -> Result(api.PreparedCall, llm_wire.WireError) {
  use api_key <- result.try(types.api_key("local-scripted-provider-key"))
  use provider_endpoint <- result.try(types.endpoint(endpoint))
  use model <- result.try(types.model_id("local-scripted-model"))
  use tool <- result.try(llm_tool())
  let config = types.openai_config(api_key, provider_endpoint, None, None)
  let request =
    types.new_request(model, [types.UserMessage(prompt)])
    |> types.with_tools([tool])
  api.prepare(config, request, types.default_limits())
}

pub fn provider_run(
  prepared: api.PreparedCall,
) -> Result(llm_wire.RunResult, llm_wire.WireError) {
  llm_wire.run(prepared, types.default_limits(), types.default_deadlines())
}

pub fn provider_continue(
  prepared: api.PreparedCall,
  continuation: llm_wire.Continuation,
  result: llm_wire.ToolResult,
) -> Result(api.PreparedCall, llm_wire.WireError) {
  llm_wire.prepare_continue(
    prepared,
    continuation,
    [result],
    types.default_limits(),
  )
}

pub fn encode_item(item: InventoryItem) -> Result(String, codec.EncodeError) {
  codec.encode_json(item_codec(), item)
}

pub fn decode_lookup(source: String) -> Result(Lookup, codec.JsonDecodeError) {
  codec.decode_json(lookup_codec(), source)
}

pub fn decode_lookup_error(
  source: String,
) -> Result(String, codec.JsonDecodeError) {
  codec.decode_json(lookup_error_codec(), source)
}

pub fn decode_item(
  source: String,
) -> Result(InventoryItem, codec.JsonDecodeError) {
  codec.decode_json(item_codec(), source)
}

pub fn main() -> Nil {
  let invocations = process.new_subject()
  let application_errors = process.new_subject()
  let assert Ok(provider) =
    scripted_provider.start(scripted_provider.Lookup("A-100"))
  let assert Ok(relay_server) =
    start_relay_server_observed(invocations, application_errors)
  let assert Ok(relay_client) = connect_relay(relay_server)
  let endpoint =
    "http://127.0.0.1:"
    <> int.to_string(scripted_provider.port(provider))
    <> "/v1"
  let assert Ok(prepared) = prepare_openai(endpoint, "Find SKU A-100")
  let answer = run_lookup_example(prepared, relay_client)
  client.close(relay_client)
  http.stop_http_server(relay_server)
  scripted_provider.stop(provider)
  let assert True = scripted_provider.await_worker_stopped(provider, 1000)
  case answer {
    Ok(text) -> io.println(text)
    Error(reason) -> {
      io.println("ecosystem pilot failed: " <> reason)
      panic as reason
    }
  }
}

fn run_lookup_example(
  prepared: api.PreparedCall,
  relay_client: client.Client,
) -> Result(String, String) {
  use run_result <- result.try(
    provider_run(prepared)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  case run_result {
    llm_wire.RunToolCalls([call], continuation, _) -> {
      use input <- result.try(
        decode_lookup(call.arguments_json)
        |> result.map_error(fn(error) { string.inspect(error) }),
      )
      case execute_lookup(relay_client, input) {
        client.StructuredSuccess(item, _) -> {
          use encoded <- result.try(
            encode_item(item)
            |> result.map_error(fn(error) { string.inspect(error) }),
          )
          use follow_up <- result.try(
            provider_continue(
              prepared,
              continuation,
              llm_wire.ToolResult(call.id, encoded),
            )
            |> result.map_error(fn(error) { string.inspect(error) }),
          )
          use final_result <- result.try(
            provider_run(follow_up)
            |> result.map_error(fn(error) { string.inspect(error) }),
          )
          case final_result {
            llm_wire.RunText(text, _) -> Ok(text)
            _ -> Error("provider did not return a final text answer")
          }
        }
        client.ToolFailure(_) -> Error("inventory lookup failed")
        client.ContentOnlySuccess(_) ->
          Error("inventory lookup returned no typed structured output")
        client.ProtocolFailure(reason) -> Error(reason)
        client.TransportFailure(reason) -> Error(reason)
        client.Cancelled -> Error("Relay lookup was cancelled")
        client.InputEncodingFailure -> Error("Relay input could not be encoded")
      }
    }
    llm_wire.RunToolCalls(_, _, _) ->
      Error("provider returned multiple calls for the single-tool example")
    llm_wire.RunText(text, _) -> Ok(text)
    llm_wire.RunOutputLimited(_, _, _) ->
      Error("provider output reached the configured limit")
    llm_wire.RunRefusal(reason) -> Error(reason)
  }
}
