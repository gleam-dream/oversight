import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import scripted_provider/tcp

pub type Mode {
  Lookup(sku: String)
  InvalidArguments
  Slow
  Disconnect
}

pub opaque type Provider {
  Provider(
    port: Int,
    listener: tcp.ListenSocket,
    worker: process.Pid,
    requests: process.Subject(String),
    response_started: process.Subject(Nil),
    disconnects: process.Subject(String),
  )
}

pub fn start(mode: Mode) -> Result(Provider, String) {
  use #(listener, port) <- result.try(tcp.listen(0))
  let requests = process.new_subject()
  let response_started = process.new_subject()
  let disconnects = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      serve(listener, mode, requests, response_started, disconnects)
    })
  Ok(Provider(port, listener, worker, requests, response_started, disconnects))
}

pub fn port(provider: Provider) -> Int {
  provider.port
}

pub fn next_request(
  provider: Provider,
  timeout_ms: Int,
) -> Result(String, Nil) {
  process.receive(provider.requests, timeout_ms)
}

pub fn await_response_started(
  provider: Provider,
  timeout_ms: Int,
) -> Result(Nil, Nil) {
  process.receive(provider.response_started, timeout_ms)
}

pub fn await_disconnect(
  provider: Provider,
  timeout_ms: Int,
) -> Result(String, Nil) {
  process.receive(provider.disconnects, timeout_ms)
}

pub fn worker_alive(provider: Provider) -> Bool {
  process.is_alive(provider.worker)
}

pub fn await_worker_stopped(provider: Provider, timeout_ms: Int) -> Bool {
  await_worker_stopped_loop(provider, timeout_ms / 10)
}

fn await_worker_stopped_loop(provider: Provider, remaining: Int) -> Bool {
  case process.is_alive(provider.worker) {
    False -> True
    True if remaining <= 0 -> False
    True -> {
      process.sleep(10)
      await_worker_stopped_loop(provider, remaining - 1)
    }
  }
}

pub fn stop(provider: Provider) -> Nil {
  tcp.close_listener(provider.listener)
  case process.is_alive(provider.worker) {
    True -> process.kill(provider.worker)
    False -> Nil
  }
  Nil
}

/// Checks the decoded Responses request, including the Blueprint-derived tool schema.
pub fn is_initial_request(body: String, expected_sku: String) -> Bool {
  case parse_json(body) {
    Error(_) -> False
    Ok(request) ->
      case
        at_value(request, ["model"], decode.string),
        at_value(request, ["stream"], decode.bool),
        first_value(request, "input"),
        first_value(request, "tools")
      {
        Ok("local-scripted-model"), Ok(True), Ok(input), Ok(tool) ->
          is_user_input(input, "Find SKU " <> expected_sku)
          && is_inventory_tool(tool)
        _, _, _, _ -> False
      }
  }
}

/// Checks the continuation envelope and the result correlated to the function call.
pub fn is_continuation_request(body: String, expected_sku: String) -> Bool {
  case parse_json(body) {
    Error(_) -> False
    Ok(request) ->
      case
        at_value(request, ["model"], decode.string),
        at_value(request, ["stream"], decode.bool),
        at_value(request, ["input"], decode.list(decode.dynamic))
      {
        Ok("local-scripted-model"), Ok(True), Ok(input) -> {
          let outputs =
            list.filter(input, fn(item) {
              at_value(item, ["type"], decode.string)
              == Ok("function_call_output")
            })
          case outputs {
            [output] -> is_correlated_result(output, expected_sku)
            _ -> False
          }
        }
        _, _, _ -> False
      }
  }
}

fn is_user_input(input: Dynamic, prompt: String) -> Bool {
  at_value(input, ["role"], decode.string) == Ok("user")
  && at_value(input, ["content"], decode.string) == Ok(prompt)
}

fn is_inventory_tool(tool: Dynamic) -> Bool {
  at_value(tool, ["type"], decode.string) == Ok("function")
  && at_value(tool, ["name"], decode.string) == Ok("inventory_lookup")
  && at_value(tool, ["parameters", "type"], decode.string) == Ok("object")
  && at_value(tool, ["parameters", "properties", "sku", "type"], decode.string)
  == Ok("string")
  && at_value(tool, ["parameters", "required"], decode.list(decode.string))
  == Ok(["sku"])
  && at_value(tool, ["parameters", "additionalProperties"], decode.bool)
  == Ok(False)
}

fn is_correlated_result(item: Dynamic, expected_sku: String) -> Bool {
  case
    at_value(item, ["type"], decode.string),
    at_value(item, ["call_id"], decode.string),
    at_value(item, ["output"], decode.string)
  {
    Ok("function_call_output"), Ok("call_1"), Ok(output) ->
      case expected_sku {
        "A-100" -> is_expected_inventory_item(output)
        "MISSING" -> output == "inventory record not found"
        _ -> False
      }
    _, _, _ -> False
  }
}

fn is_expected_inventory_item(output: String) -> Bool {
  case parse_json(output) {
    Error(_) -> False
    Ok(item) ->
      at_value(item, ["sku"], decode.string) == Ok("A-100")
      && at_value(item, ["name"], decode.string) == Ok("Ada Lovelace notebook")
      && at_value(item, ["quantity"], decode.int) == Ok(7)
  }
}

fn parse_json(source: String) -> Result(Dynamic, Nil) {
  json.parse(source, decode.dynamic)
  |> result.map_error(fn(_) { Nil })
}

fn at_value(
  value: Dynamic,
  path: List(String),
  decoder: decode.Decoder(a),
) -> Result(a, Nil) {
  decode.run(value, decode.at(path, decoder))
  |> result.map_error(fn(_) { Nil })
}

fn first_value(value: Dynamic, key: String) -> Result(Dynamic, Nil) {
  case at_value(value, [key], decode.list(decode.dynamic)) {
    Ok([first, ..]) -> Ok(first)
    Ok([]) -> Error(Nil)
    Error(_) -> Error(Nil)
  }
}

fn serve(
  listener: tcp.ListenSocket,
  mode: Mode,
  requests: process.Subject(String),
  response_started: process.Subject(Nil),
  disconnects: process.Subject(String),
) -> Nil {
  case tcp.accept(listener, 5000) {
    Error(_) -> Nil
    Ok(socket) ->
      case read_request(socket, "") {
        Error(_) -> tcp.close(socket)
        Ok(#(headers, body)) -> {
          process.send(requests, body)
          case mode {
            Lookup(sku) ->
              serve_lookup(listener, socket, headers, body, sku, requests)
            InvalidArguments -> {
              case
                valid_provider_headers(headers)
                && is_initial_request(body, "MISSING")
              {
                True -> {
                  let _ = send_function_call_arguments(socket, "{\"sku\":42}")
                  tcp.close(socket)
                }
                False -> {
                  let _ =
                    send_http_error(socket, 400, "invalid Responses request")
                  tcp.close(socket)
                }
              }
            }
            Slow ->
              serve_slow(socket, headers, body, response_started, disconnects)
            Disconnect -> {
              tcp.close(socket)
              monitor_retries(listener, requests, 0)
            }
          }
        }
      }
  }
  Nil
}

fn serve_lookup(
  listener: tcp.ListenSocket,
  socket: tcp.Socket,
  headers: String,
  body: String,
  sku: String,
  requests: process.Subject(String),
) -> Nil {
  case valid_provider_headers(headers) && is_initial_request(body, sku) {
    True -> {
      let _ = send_function_call(socket, sku)
      tcp.close(socket)
      serve_continuation(listener, sku, requests)
    }
    False -> {
      let _ = send_http_error(socket, 400, "invalid Responses request")
      tcp.close(socket)
    }
  }
}

fn serve_continuation(
  listener: tcp.ListenSocket,
  sku: String,
  requests: process.Subject(String),
) -> Nil {
  case tcp.accept(listener, 4000) {
    Error(_) -> Nil
    Ok(socket) ->
      case read_request(socket, "") {
        Error(_) -> tcp.close(socket)
        Ok(#(headers, body)) -> {
          process.send(requests, body)
          case
            valid_provider_headers(headers)
            && is_continuation_request(body, sku)
          {
            True -> {
              let _ = send_final(socket, sku)
              Nil
            }
            False -> {
              let _ = send_http_error(socket, 422, "invalid continuation")
              Nil
            }
          }
          tcp.close(socket)
          monitor_retries(listener, requests, 0)
        }
      }
  }
}

fn serve_slow(
  socket: tcp.Socket,
  headers: String,
  body: String,
  response_started: process.Subject(Nil),
  disconnects: process.Subject(String),
) -> Nil {
  case valid_provider_headers(headers) && is_initial_request(body, "A-100") {
    False -> {
      let _ = send_http_error(socket, 400, "invalid Responses request")
      tcp.close(socket)
    }
    True -> {
      let _ = send_slow_partial(socket)
      process.send(response_started, Nil)
      await_peer_close(socket, disconnects)
    }
  }
}

fn monitor_retries(
  listener: tcp.ListenSocket,
  requests: process.Subject(String),
  accepted: Int,
) -> Nil {
  case accepted >= 4 {
    True -> Nil
    False ->
      case tcp.accept(listener, 1500) {
        Error(_) -> Nil
        Ok(socket) ->
          case read_request(socket, "") {
            Error(_) -> tcp.close(socket)
            Ok(#(_headers, body)) -> {
              process.send(requests, body)
              tcp.close(socket)
              monitor_retries(listener, requests, accepted + 1)
            }
          }
      }
  }
}

fn await_peer_close(
  socket: tcp.Socket,
  disconnects: process.Subject(String),
) -> Nil {
  case tcp.recv(socket, 0, 3000) {
    Error(reason) -> {
      process.send(disconnects, reason)
      tcp.close(socket)
    }
    Ok(_bytes) -> await_peer_close(socket, disconnects)
  }
}

fn valid_provider_headers(headers: String) -> Bool {
  let normalized = string.lowercase(headers)
  string.starts_with(normalized, "post /v1/responses http/1.1\r\n")
  && string.contains(normalized, "content-type: application/json")
  && string.contains(
    normalized,
    "authorization: bearer local-scripted-provider-key",
  )
}

fn send_function_call(socket: tcp.Socket, sku: String) -> Result(Nil, String) {
  let arguments = json.to_string(json.object([#("sku", json.string(sku))]))
  send_function_call_arguments(socket, arguments)
}

fn send_function_call_arguments(
  socket: tcp.Socket,
  arguments: String,
) -> Result(Nil, String) {
  let item_added =
    json.object([
      #("output_index", json.int(0)),
      #(
        "item",
        json.object([
          #("id", json.string("item_1")),
          #("type", json.string("function_call")),
          #("call_id", json.string("call_1")),
          #("name", json.string("inventory_lookup")),
        ]),
      ),
    ])
  let arguments_delta =
    json.object([
      #("output_index", json.int(0)),
      #("item_id", json.string("item_1")),
      #("delta", json.string(arguments)),
    ])
  let item_done =
    json.object([
      #("output_index", json.int(0)),
      #("item", json.object([#("id", json.string("item_1"))])),
    ])
  send_sse_events(socket, [
    #("response.output_item.added", item_added),
    #("response.function_call_arguments.delta", arguments_delta),
    #("response.output_item.done", item_done),
    #(
      "response.completed",
      json.object([
        #(
          "response",
          json.object([
            #("id", json.string("resp_1")),
            #("status", json.string("completed")),
          ]),
        ),
      ]),
    ),
  ])
}

fn send_final(socket: tcp.Socket, sku: String) -> Result(Nil, String) {
  let item_added =
    json.object([
      #("output_index", json.int(0)),
      #(
        "item",
        json.object([
          #("id", json.string("msg_2")),
          #("type", json.string("message")),
          #("role", json.string("assistant")),
        ]),
      ),
    ])
  let text = case sku {
    "A-100" -> "A-100 has 7 Ada Lovelace notebooks."
    _ -> "I couldn't find " <> sku <> "."
  }
  let text_delta =
    json.object([
      #("output_index", json.int(0)),
      #("item_id", json.string("msg_2")),
      #("delta", json.string(text)),
    ])
  let item_done =
    json.object([
      #("output_index", json.int(0)),
      #(
        "item",
        json.object([
          #("id", json.string("msg_2")),
          #("type", json.string("message")),
          #("role", json.string("assistant")),
        ]),
      ),
    ])
  send_sse_events(socket, [
    #("response.output_item.added", item_added),
    #("response.output_text.delta", text_delta),
    #("response.output_item.done", item_done),
    #(
      "response.completed",
      json.object([
        #(
          "response",
          json.object([
            #("id", json.string("resp_2")),
            #("status", json.string("completed")),
          ]),
        ),
      ]),
    ),
  ])
}

fn send_slow_partial(socket: tcp.Socket) -> Result(Nil, String) {
  let call_added =
    json.object([
      #("output_index", json.int(0)),
      #(
        "item",
        json.object([
          #("id", json.string("item_slow")),
          #("type", json.string("function_call")),
          #("call_id", json.string("call_slow")),
          #("name", json.string("inventory_lookup")),
        ]),
      ),
    ])
  let call_arguments =
    json.object([
      #("output_index", json.int(0)),
      #("item_id", json.string("item_slow")),
      #("delta", json.string("{\"sku\":\"A-")),
    ])
  let message_added =
    json.object([
      #("output_index", json.int(1)),
      #(
        "item",
        json.object([
          #("id", json.string("msg_slow")),
          #("type", json.string("message")),
          #("role", json.string("assistant")),
        ]),
      ),
    ])
  let text_delta =
    json.object([
      #("output_index", json.int(1)),
      #("item_id", json.string("msg_slow")),
      #("delta", json.string("Searching inventory")),
    ])
  send_sse_events(socket, [
    #(
      "response.created",
      json.object([
        #(
          "response",
          json.object([
            #("id", json.string("resp_slow")),
            #("status", json.string("in_progress")),
          ]),
        ),
      ]),
    ),
    #("response.output_item.added", call_added),
    #("response.function_call_arguments.delta", call_arguments),
    #("response.output_item.added", message_added),
    #("response.output_text.delta", text_delta),
  ])
}

fn send_sse_events(
  socket: tcp.Socket,
  events: List(#(String, json.Json)),
) -> Result(Nil, String) {
  use Nil <- result.try(tcp.send(
    socket,
    bit_array.from_string(
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n",
    ),
  ))
  list.fold(events, Ok(Nil), fn(acc, event) {
    use Nil <- result.try(acc)
    let #(name, data) = event
    tcp.send(
      socket,
      bit_array.from_string(
        "event: " <> name <> "\ndata: " <> json.to_string(data) <> "\n\n",
      ),
    )
  })
}

fn send_http_error(
  socket: tcp.Socket,
  status: Int,
  message: String,
) -> Result(Nil, String) {
  let body = json.to_string(json.object([#("error", json.string(message))]))
  tcp.send(
    socket,
    bit_array.from_string(
      "HTTP/1.1 "
      <> int.to_string(status)
      <> " Error\r\nContent-Type: application/json\r\nContent-Length: "
      <> int.to_string(string.byte_size(body))
      <> "\r\nConnection: close\r\n\r\n"
      <> body,
    ),
  )
}

fn read_request(
  socket: tcp.Socket,
  buffer: String,
) -> Result(#(String, String), String) {
  case string.split_once(buffer, "\r\n\r\n") {
    Error(Nil) ->
      case tcp.recv(socket, 0, 2000) {
        Ok(chunk) ->
          case bit_array.to_string(chunk) {
            Ok(text) -> read_request(socket, buffer <> text)
            Error(Nil) -> Error("provider request was not UTF-8")
          }
        Error(reason) -> Error(reason)
      }
    Ok(#(headers, body_prefix)) -> {
      let length = content_length(headers)
      read_body(socket, headers, body_prefix, length)
    }
  }
}

fn content_length(headers: String) -> Int {
  case
    list.find(string.split(headers, "\r\n"), fn(line) {
      string.starts_with(string.lowercase(line), "content-length:")
    })
  {
    Error(Nil) -> 0
    Ok(line) ->
      case string.split_once(line, ":") {
        Error(Nil) -> 0
        Ok(#(_, value)) ->
          case int.parse(string.trim(value)) {
            Ok(length) -> length
            Error(Nil) -> 0
          }
      }
  }
}

fn read_body(
  socket: tcp.Socket,
  headers: String,
  body: String,
  length: Int,
) -> Result(#(String, String), String) {
  case string.byte_size(body) >= length {
    True -> Ok(#(headers, string.slice(body, at_index: 0, length: length)))
    False ->
      case tcp.recv(socket, 0, 2000) {
        Ok(chunk) ->
          case bit_array.to_string(chunk) {
            Ok(text) -> read_body(socket, headers, body <> text, length)
            Error(Nil) -> Error("provider body was not UTF-8")
          }
        Error(reason) -> Error(reason)
      }
  }
}
