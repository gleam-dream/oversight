//// Mounts a Relay MCP server at a path inside the app's wisp router.
////
//// GLUE (SMCP-2): Relay's Streamable HTTP handler is private and owns its own
//// mist listener (`relay/transport/http.start`), and its context builder is
//// `fn() -> context`, blind to the request. This module re-implements the
//// buffered half of that handler on Relay's public custom-transport runtime:
//// one `relay/runtime` actor per POST, a per-request context, and a sink that
//// collects frames until the JSON-RPC response arrives. Relay's Host/Origin
//// policy, `MCP-Method`/`MCP-Name` header checks, custom-parameter header
//// checks, HTTP status mapping and SSE streaming are not reproduced: their
//// routing helpers live in `relay/internal/protocol`.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import relay/runtime
import relay/server.{type ExchangeId, type Server}
import wisp

pub type MountLimits {
  MountLimits(max_body_bytes: Int, request_timeout_ms: Int)
}

pub fn default_limits() -> MountLimits {
  MountLimits(max_body_bytes: 1_048_576, request_timeout_ms: 10_000)
}

/// Handles one Streamable HTTP POST with an already-authenticated context.
/// `on_exchange` reports the Relay exchange id chosen for this request, so
/// the caller can correlate it with Relay's telemetry.
pub fn handle(
  req: wisp.Request,
  mcp: Server(context),
  context: context,
  limits: MountLimits,
  on_exchange: fn(ExchangeId) -> Nil,
) -> wisp.Response {
  use <- wisp.require_method(req, http.Post)
  use <- wisp.require_content_type(req, "application/json")
  let req = wisp.set_max_body_size(req, limits.max_body_bytes)
  use body <- wisp.require_bit_array_body(req)
  // Relay's one public HTTP admission helper: required client capabilities.
  use <- admission(mcp, body)
  let frames = process.new_subject()
  let config =
    runtime.RuntimeConfig(
      max_live_exchanges: 1,
      max_frame_bytes: limits.max_body_bytes,
      invocation_timeout_ms: limits.request_timeout_ms,
      tombstone_retention_ms: 1000,
    )
  let sink = fn(output) {
    case output {
      runtime.OutputWrite(_, bytes) -> process.send(frames, bytes)
      runtime.OutputClose(_) -> Nil
    }
    Ok(Nil)
  }
  case runtime.start(mcp, config, sink) {
    Error(_) -> plain(500, "MCP runtime failed to start")
    Ok(instance) -> {
      let exchange = server.fresh_exchange()
      on_exchange(exchange)
      let sent =
        runtime.send_frame(
          instance,
          exchange,
          context,
          body,
          limits.request_timeout_ms,
        )
      let response = case sent, has_request_id(body) {
        Error(_), _ -> plain(400, "MCP frame rejected")
        Ok(Nil), False -> wisp.response(202) |> protocol_header
        Ok(Nil), True ->
          case collect(frames, limits.request_timeout_ms) {
            Ok(frame) ->
              wisp.response(200)
              |> wisp.set_header("content-type", "application/json")
              |> wisp.set_header("cache-control", "no-store")
              |> protocol_header
              |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(frame)))
            Error(Nil) -> plain(504, "MCP response timed out")
          }
      }
      runtime.stop(instance, 1000)
      response
    }
  }
}

fn protocol_header(response: wisp.Response) -> wisp.Response {
  wisp.set_header(response, "mcp-protocol-version", "2026-07-28")
}

/// Waits for the JSON-RPC response frame; progress notifications that the
/// runtime writes first are dropped (no SSE here).
fn collect(
  frames: process.Subject(BitArray),
  timeout_ms: Int,
) -> Result(BitArray, Nil) {
  use frame <- result.try(process.receive(frames, timeout_ms))
  case is_response(frame) {
    True -> Ok(frame)
    False -> collect(frames, timeout_ms)
  }
}

// GLUE: `v2026.is_response_frame` and `http_route` are internal to Relay.
fn has_request_id(body: BitArray) -> Bool {
  keys(body) |> list.contains("id")
}

fn is_response(frame: BitArray) -> Bool {
  let keys = keys(frame)
  list.contains(keys, "id")
  && { list.contains(keys, "result") || list.contains(keys, "error") }
}

fn keys(bytes: BitArray) -> List(String) {
  bit_array.to_string(bytes)
  |> result.try(fn(text) {
    json.parse(string.trim(text), decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(Nil)
  })
  |> result.map(dict.keys)
  |> result.unwrap([])
}

fn admission(
  mcp: Server(context),
  body: BitArray,
  next: fn() -> wisp.Response,
) -> wisp.Response {
  case server.http_admission_failure(mcp, body) {
    None -> next()
    Some(#(status, bytes)) ->
      wisp.response(status)
      |> wisp.set_header("content-type", "application/json")
      |> protocol_header
      |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(bytes)))
  }
}

fn plain(status: Int, message: String) -> wisp.Response {
  wisp.response(status)
  |> wisp.set_header("content-type", "text/plain; charset=utf-8")
  |> wisp.string_body(message)
}
