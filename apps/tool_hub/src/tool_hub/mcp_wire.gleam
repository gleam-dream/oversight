//// Glue: raw MCP requests over http_gun, for what the Relay client cannot
//// do: cancel a call. Relay's HTTP client has no cancel operation and
//// never asks for an SSE response, so a test that needs either speaks the
//// wire protocol itself.

import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/json
import gleam/list

const protocol = "2026-07-28"

/// A `tools/call` POST. With `stream`, the client accepts an SSE response,
/// which is the only kind whose disconnect Relay notices.
pub fn tools_call(
  port: Int,
  id: Int,
  name: String,
  arguments: json.Json,
  stream stream: Bool,
) -> Request(BitArray) {
  let accept = case stream {
    True -> "application/json, text/event-stream"
    False -> "application/json"
  }
  post(port, "tools/call", accept, [#("Mcp-Name", name)], {
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.int(id)),
      #("method", json.string("tools/call")),
      #(
        "params",
        json.object([
          #("name", json.string(name)),
          #("arguments", arguments),
          #("_meta", meta()),
        ]),
      ),
    ])
  })
}

/// The MCP way to cancel request `id`.
pub fn cancelled(port: Int, id: Int) -> Request(BitArray) {
  post(port, "notifications/cancelled", "application/json", [], {
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("method", json.string("notifications/cancelled")),
      #(
        "params",
        json.object([#("requestId", json.int(id)), #("_meta", meta())]),
      ),
    ])
  })
}

fn meta() -> json.Json {
  json.object([
    #("io.modelcontextprotocol/protocolVersion", json.string(protocol)),
    #("io.modelcontextprotocol/clientCapabilities", json.object([])),
  ])
}

fn post(
  port: Int,
  method: String,
  accept: String,
  extra: List(#(String, String)),
  body: json.Json,
) -> Request(BitArray) {
  let base =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_scheme(http.Http)
    |> request.set_host("127.0.0.1")
    |> request.set_port(port)
    |> request.set_path("/")
    |> request.set_header("content-type", "application/json")
    |> request.set_header("accept", accept)
    |> request.set_header("mcp-protocol-version", protocol)
    |> request.set_header("mcp-method", method)
    |> request.set_body(bit_array.from_string(json.to_string(body)))
  list.fold(extra, base, fn(req, header) {
    request.set_header(req, header.0, header.1)
  })
}
