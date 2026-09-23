import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/json_text
import json/blueprint/parser
import json/blueprint/value
import llm_wire/config
import llm_wire/provider/openai as openai_provider
import llm_wire/session
import llm_wire/types
import relay/client
import relay/server
import relay/tool
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
  let assert Ok(item) =
    codec.record3(
      codec.required("sku", codec.string()),
      codec.required("name", codec.string()),
      codec.required("quantity", codec.int()),
      InventoryItem,
      fn(item) { item.sku },
      fn(item) { item.name },
      fn(item) { item.quantity },
    )
  item
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
  use name <- result.try(
    tool.tool_name("inventory_lookup")
    |> result.map_error(fn(_) { "tool name admission failed" }),
  )
  let annotations =
    tool.ToolAnnotations(
      ..tool.empty_annotations(),
      title: Some("Inventory lookup"),
    )
    |> tool.with_read_only_hint(Some(True))
    |> tool.with_destructive_hint(Some(False))
    |> tool.with_idempotent_hint(Some(True))
    |> tool.with_open_world_hint(Some(False))
  tool.definition(name, lookup_codec(), item_codec())
  |> result.map_error(fn(_) { "tool admission failed" })
  |> result.map(fn(definition) {
    definition
    |> tool.with_description("Look up one synthetic inventory record by SKU")
    |> tool.with_annotations(annotations)
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
) -> tool.ContextTool(Nil) {
  tool.handle(definition, fn(input) {
    observed_find(input, invocations, application_errors)
  })
}

pub fn rendered_relay_tool(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> tool.ContextTool(Nil) {
  tool.handle_with_error_renderer(
    definition,
    fn(input) { observed_find(input, invocations, application_errors) },
    fn(reason) { reason },
  )
}

pub fn json_text_error_relay_tool(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> tool.ContextTool(Nil) {
  tool.handle_with_error_renderer(
    definition,
    fn(input) { observed_find(input, invocations, application_errors) },
    fn(reason) { json.to_string(json.string(reason)) },
  )
}

/// Relay and LLM Wire have separate name admission. The declaration is derived
/// from the same Relay definition without adding a package dependency.
pub fn llm_tool(
  definition: tool.Definition(Lookup, InventoryItem),
) -> Result(types.ToolDefinition, types.WireError) {
  let relay_name =
    definition |> tool.definition_name |> tool.tool_name_to_string
  use name <- result.try(types.tool_name(relay_name))
  let metadata = tool.definition_metadata(definition)
  let description = case metadata.description {
    Some(description) -> description
    None -> ""
  }
  types.tool_from_codec(
    name,
    description,
    tool.definition_input_codec(definition),
  )
}

/// Admits a remote declaration only when Blueprint supports its finite schema.
pub fn llm_discovered_tool(
  declaration: client.ToolDeclaration,
) -> Result(types.ToolDefinition, String) {
  use name <- result.try(
    types.tool_name(declaration.name)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use contract <- result.try(
    parser.parse_schema_document_from_string(
      parser.default_limits(),
      json.to_string(declaration.input_schema),
    )
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  Ok(types.tool_from_contract(
    name,
    option.unwrap(declaration.description, ""),
    contract,
  ))
}

fn serve_tool(
  registered: tool.ContextTool(Nil),
) -> Result(http.HttpServer(Nil), String) {
  use registry <- result.try(
    tool.registry([registered])
    |> result.map_error(fn(_) { "registry admission failed" }),
  )
  server.server(registry)
  |> http.listener(fn() { Nil })
  |> http.start()
}

pub fn start_relay_server_observed(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> Result(http.HttpServer(Nil), String) {
  serve_tool(relay_tool(definition, invocations, application_errors))
}

pub fn start_rendered_relay_server(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> Result(http.HttpServer(Nil), String) {
  serve_tool(rendered_relay_tool(definition, invocations, application_errors))
}

pub fn start_json_text_error_relay_server(
  definition: tool.Definition(Lookup, InventoryItem),
  invocations: process.Subject(String),
  application_errors: process.Subject(String),
) -> Result(http.HttpServer(Nil), String) {
  serve_tool(json_text_error_relay_tool(
    definition,
    invocations,
    application_errors,
  ))
}

pub fn connect_relay(
  relay_server: http.HttpServer(Nil),
) -> Result(client.Client, client.ClientError) {
  let url =
    "http://127.0.0.1:"
    <> int.to_string(http.http_server_port(relay_server))
    <> "/"
  use settings <- result.try(client.http_config(url))
  settings
  |> client.with_timeout(2000)
  |> client.with_max_response_bytes(1_048_576)
  |> client.connect_http()
}

pub fn execute_lookup(
  relay_client: client.Client,
  definition: tool.Definition(Lookup, InventoryItem),
  input: Lookup,
) -> client.ToolCallOutcome(InventoryItem) {
  client.call_definition(relay_client, definition, input)
}

pub fn prepare_openai(
  definition: tool.Definition(Lookup, InventoryItem),
  endpoint: String,
  prompt: String,
) -> Result(session.PreparedCall, types.WireError) {
  use api_key <- result.try(types.api_key("local-scripted-provider-key"))
  use provider_endpoint <- result.try(types.endpoint(endpoint))
  use model <- result.try(types.model_id("local-scripted-model"))
  use declaration <- result.try(llm_tool(definition))
  let settings =
    config.openai(openai_provider.options(api_key))
    |> config.with_endpoint(provider_endpoint)
    |> config.with_limits(
      types.Limits(
        ..types.default_limits(),
        response_body_bytes_limit: 1_048_576,
      ),
    )
    |> config.with_deadlines(
      types.Deadlines(..types.default_deadlines(), read_timeout_ms: 3000),
    )
  let request =
    types.new_request(model, [types.UserMessage(prompt)])
    |> types.with_tools([declaration])
  session.prepare(settings, request)
}

pub fn prepare_discovered_openai(
  declaration: client.ToolDeclaration,
  endpoint: String,
) -> Result(session.PreparedCall, String) {
  use api_key <- result.try(
    types.api_key("local-scripted-provider-key")
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use provider_endpoint <- result.try(
    types.endpoint(endpoint)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use model <- result.try(
    types.model_id("local-scripted-model")
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use tool <- result.try(llm_discovered_tool(declaration))
  let settings =
    config.openai(openai_provider.options(api_key))
    |> config.with_endpoint(provider_endpoint)
  let request =
    types.new_request(model, [types.UserMessage("Find SKU A-100")])
    |> types.with_tools([tool])
  session.prepare(settings, request)
  |> result.map_error(fn(error) { string.inspect(error) })
}

pub fn call_discovered_value(
  relay_client: client.Client,
  declaration: client.ToolDeclaration,
  arguments: value.Value,
) -> Result(String, String) {
  case client.call_discovered(relay_client, declaration, arguments) {
    client.StructuredSuccess(value, _) -> Ok(json_text.render_value(value))
    client.ContentOnlySuccess(_) ->
      Error("tool returned content without structured output")
    client.InputRequired(_, _) -> Error("tool requested additional input")
    client.ToolFailure(_) -> Error("tool reported an application failure")
    client.ProtocolFailure(reason) -> Error(reason)
    client.TransportFailure(reason) -> Error(string.inspect(reason))
    client.InputEncodingFailure -> Error("tool arguments could not be encoded")
    client.InvalidInputResponses -> Error("tool input responses were invalid")
  }
}

pub fn provider_run(
  prepared: session.PreparedCall,
) -> Result(session.RunResult, session.RunFailure) {
  session.run(prepared)
}

pub fn provider_continue(
  continuation: session.Continuation,
  result: types.ToolResult,
) -> Result(session.PreparedCall, types.WireError) {
  session.prepare_continue(continuation, [result])
}

pub fn encode_item(
  definition: tool.Definition(Lookup, InventoryItem),
  item: InventoryItem,
) -> Result(String, codec.EncodeError) {
  codec.encode_json(tool.definition_output_codec(definition), item)
}

pub fn decode_lookup(
  definition: tool.Definition(Lookup, InventoryItem),
  source: String,
) -> Result(Lookup, codec.JsonDecodeError) {
  codec.decode_json(tool.definition_input_codec(definition), source)
}

pub fn decode_item(
  definition: tool.Definition(Lookup, InventoryItem),
  source: String,
) -> Result(InventoryItem, codec.JsonDecodeError) {
  codec.decode_json(tool.definition_output_codec(definition), source)
}

pub fn main() -> Nil {
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
  let answer = run_lookup_example(definition, prepared, relay_client)
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
  definition: tool.Definition(Lookup, InventoryItem),
  prepared: session.PreparedCall,
  relay_client: client.Client,
) -> Result(String, String) {
  use run_result <- result.try(
    provider_run(prepared)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  case run_result {
    session.RunToolCalls(_, [call], continuation, _) -> {
      use input <- result.try(
        decode_lookup(definition, call.arguments_json)
        |> result.map_error(fn(error) { string.inspect(error) }),
      )
      case execute_lookup(relay_client, definition, input) {
        client.StructuredSuccess(item, _) -> {
          use encoded <- result.try(
            encode_item(definition, item)
            |> result.map_error(fn(error) { string.inspect(error) }),
          )
          use follow_up <- result.try(
            provider_continue(continuation, types.ToolResult(call.id, encoded))
            |> result.map_error(fn(error) { string.inspect(error) }),
          )
          use final_result <- result.try(
            provider_run(follow_up)
            |> result.map_error(fn(error) { string.inspect(error) }),
          )
          case final_result {
            session.RunText(text, _) -> Ok(text)
            _ -> Error("provider did not return a final text answer")
          }
        }
        client.ToolFailure(_) -> Error("inventory lookup failed")
        client.ContentOnlySuccess(_) ->
          Error("inventory lookup returned no typed structured output")
        client.ProtocolFailure(reason) -> Error(reason)
        client.TransportFailure(reason) -> Error(string.inspect(reason))
        client.InputEncodingFailure -> Error("Relay input could not be encoded")
        client.InputRequired(_, _) -> Error("Relay lookup requires input")
        client.InvalidInputResponses ->
          Error("Relay input responses were invalid")
      }
    }
    session.RunToolCalls(_, _, _, _) ->
      Error("provider returned multiple calls for the single-tool example")
    session.RunText(text, _) -> Ok(text)
    session.RunOutputLimited(_, _, _) ->
      Error("provider output reached the configured limit")
    session.RunRefusal(reason, _) -> Error(reason)
  }
}
