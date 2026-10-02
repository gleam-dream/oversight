//// Scripted loopback services: a document server and one provider server
//// that speaks the OpenAI Responses, Anthropic Messages and Google
//// GenerateContent SSE wire formats. Each document names how the "LLM"
//// answers for it, so a batch can mix success, rate limits and bad output.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import mist

pub type Behavior {
  /// The provider answers with this text as the structured output.
  Answer(output: String)
  /// The first call gets 429 with `Retry-After`; later calls answer.
  RateLimitedOnce(retry_after_seconds: Int, output: String)
  /// Every call gets this HTTP status (429 carries `Retry-After: 2`).
  AlwaysStatus(status: Int)
}

pub type Body {
  /// Served with a content-length header.
  Fixed(text: String)
  /// Served chunked, with no content-length, so only the streaming cap
  /// can stop it.
  Streamed(chunk: String, count: Int)
}

pub type Document {
  Document(id: String, content_type: String, body: Body, behavior: Behavior)
}

pub type Services {
  Services(
    documents_port: Int,
    providers_port: Int,
    calls: Subject(CallsMessage),
  )
}

pub fn providers_base(services: Services) -> String {
  "http://127.0.0.1:" <> int.to_string(services.providers_port)
}

pub fn document_url(services: Services, host: String, id: String) -> String {
  "http://"
  <> host
  <> ":"
  <> int.to_string(services.documents_port)
  <> "/docs/"
  <> id
}

/// Number of provider calls seen for each document id.
pub fn provider_calls(services: Services, document_id: String) -> Int {
  process.call(services.calls, 1000, Count(document_id, _))
}

pub fn start(documents: List(Document)) -> Result(Services, String) {
  let table =
    list.fold(documents, dict.new(), fn(acc, doc) {
      dict.insert(acc, doc.id, doc)
    })
  use calls <- result.try(start_counter())
  use documents_port <- result.try(
    serve(fn(req) { documents_handler(table, req) }),
  )
  use providers_port <- result.try(
    serve(fn(req) { providers_handler(table, calls, req) }),
  )
  Ok(Services(documents_port:, providers_port:, calls:))
}

fn serve(
  handler: fn(Request(mist.Connection)) -> Response(mist.ResponseData),
) -> Result(Int, String) {
  let ports = process.new_subject()
  mist.new(handler)
  |> mist.bind("127.0.0.1")
  |> mist.port(0)
  |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
  |> mist.start
  |> result.replace_error("could not start a loopback server")
  |> result.try(fn(_) {
    process.receive(ports, 2000)
    |> result.replace_error("loopback server did not report its port")
  })
}

// Documents ---------------------------------------------------------------

fn documents_handler(
  table: Dict(String, Document),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case request.path_segments(req) {
    ["docs", id] ->
      case dict.get(table, id) {
        Ok(Document(content_type:, body: Fixed(text), ..)) ->
          response.new(200)
          |> response.set_header("content-type", content_type)
          |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
        Ok(Document(content_type:, body: Streamed(chunk, count), ..)) ->
          stream_document(req, content_type, chunk, count)
        Error(Nil) -> text_response(404, "no such document")
      }
    _ -> text_response(404, "not found")
  }
}

fn stream_document(
  req: Request(mist.Connection),
  content_type: String,
  chunk: String,
  count: Int,
) -> Response(mist.ResponseData) {
  mist.chunked(
    req,
    response.new(200) |> response.set_header("content-type", content_type),
    fn(subject) {
      process.send(subject, count)
      subject
    },
    fn(subject, left, connection) {
      case mist.send_chunk(connection, bit_array.from_string(chunk)) {
        Ok(Nil) if left > 1 -> {
          process.send(subject, left - 1)
          mist.chunk_continue(subject)
        }
        _ -> mist.chunk_stop()
      }
    },
  )
}

// Providers ---------------------------------------------------------------

fn providers_handler(
  table: Dict(String, Document),
  calls: Subject(CallsMessage),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let wire = case req.method, request.path_segments(req) {
    http.Post, ["openai", "v1", "responses"] -> Ok(OpenAiWire)
    http.Post, ["anthropic", "v1", "messages"] -> Ok(AnthropicWire)
    http.Post, ["google", "v1beta", "models", _] -> Ok(GoogleWire)
    _, _ -> Error(Nil)
  }
  case wire, mist.read_body(req, 1_048_576) {
    Ok(wire), Ok(req) -> {
      let text = bit_array.to_string(req.body) |> result.unwrap("")
      let document_id = marker(text)
      let attempt = process.call(calls, 1000, Record(document_id, _))
      case dict.get(table, document_id) {
        Error(Nil) -> provider_error(wire, 400, "unknown document")
        Ok(document) -> answer(wire, document.behavior, attempt)
      }
    }
    _, _ -> text_response(404, "not found")
  }
}

fn marker(body: String) -> String {
  case string.split_once(body, "[[doc:") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "]]") {
        Ok(#(id, _)) -> id
        Error(Nil) -> ""
      }
    Error(Nil) -> ""
  }
}

type Wire {
  OpenAiWire
  AnthropicWire
  GoogleWire
}

fn answer(
  wire: Wire,
  behavior: Behavior,
  attempt: Int,
) -> Response(mist.ResponseData) {
  case behavior {
    Answer(output) -> sse(wire, output)
    RateLimitedOnce(seconds, _) if attempt == 1 ->
      provider_error(wire, 429, "rate limited")
      |> response.set_header("retry-after", int.to_string(seconds))
    RateLimitedOnce(_, output) -> sse(wire, output)
    AlwaysStatus(429) ->
      provider_error(wire, 429, "rate limited")
      |> response.set_header("retry-after", "2")
    AlwaysStatus(status) -> provider_error(wire, status, "unavailable")
  }
}

fn sse(wire: Wire, output: String) -> Response(mist.ResponseData) {
  let events = case wire {
    OpenAiWire -> [
      event(
        "response.output_item.added",
        json.object([
          #("output_index", json.int(0)),
          #(
            "item",
            json.object([
              #("id", json.string("msg_1")),
              #("type", json.string("message")),
            ]),
          ),
        ]),
      ),
      event(
        "response.output_text.delta",
        json.object([
          #("output_index", json.int(0)),
          #("item_id", json.string("msg_1")),
          #("delta", json.string(output)),
        ]),
      ),
      event(
        "response.output_item.done",
        json.object([
          #("output_index", json.int(0)),
          #(
            "item",
            json.object([
              #("id", json.string("msg_1")),
              #("type", json.string("message")),
              #("role", json.string("assistant")),
            ]),
          ),
        ]),
      ),
      event(
        "response.completed",
        json.object([
          #(
            "response",
            json.object([
              #("id", json.string("resp_1")),
              #("status", json.string("completed")),
              #("usage", usage("input_tokens", "output_tokens", "total_tokens")),
            ]),
          ),
        ]),
      ),
    ]
    AnthropicWire -> [
      event(
        "message_start",
        json.object([
          #("type", json.string("message_start")),
          #(
            "message",
            json.object([
              #("id", json.string("msg_1")),
              #(
                "usage",
                json.object([
                  #("input_tokens", json.int(120)),
                  #("output_tokens", json.int(1)),
                ]),
              ),
            ]),
          ),
        ]),
      ),
      event(
        "content_block_start",
        json.object([
          #("type", json.string("content_block_start")),
          #("index", json.int(0)),
          #(
            "content_block",
            json.object([
              #("type", json.string("text")),
              #("text", json.string("")),
            ]),
          ),
        ]),
      ),
      event(
        "content_block_delta",
        json.object([
          #("type", json.string("content_block_delta")),
          #("index", json.int(0)),
          #(
            "delta",
            json.object([
              #("type", json.string("text_delta")),
              #("text", json.string(output)),
            ]),
          ),
        ]),
      ),
      event(
        "content_block_stop",
        json.object([
          #("type", json.string("content_block_stop")),
          #("index", json.int(0)),
        ]),
      ),
      event(
        "message_delta",
        json.object([
          #("type", json.string("message_delta")),
          #("delta", json.object([#("stop_reason", json.string("end_turn"))])),
          #("usage", json.object([#("output_tokens", json.int(80))])),
        ]),
      ),
      event(
        "message_stop",
        json.object([#("type", json.string("message_stop"))]),
      ),
    ]
    GoogleWire -> [
      data(
        json.object([
          #("responseId", json.string("resp_1")),
          #(
            "candidates",
            json.preprocessed_array([candidate([text_part(output)], [])]),
          ),
        ]),
      ),
      data(
        json.object([
          #(
            "candidates",
            json.preprocessed_array([
              candidate([], [#("finishReason", json.string("STOP"))]),
            ]),
          ),
          #(
            "usageMetadata",
            usage("promptTokenCount", "candidatesTokenCount", "totalTokenCount"),
          ),
        ]),
      ),
    ]
  }
  response.new(200)
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(string.concat(events))),
  )
}

fn candidate(
  parts: List(json.Json),
  extra: List(#(String, json.Json)),
) -> json.Json {
  json.object([
    #(
      "content",
      json.object([
        #("role", json.string("model")),
        #("parts", json.preprocessed_array(parts)),
      ]),
    ),
    ..extra
  ])
}

fn text_part(text: String) -> json.Json {
  json.object([#("text", json.string(text))])
}

fn usage(input: String, output: String, total: String) -> json.Json {
  json.object([
    #(input, json.int(120)),
    #(output, json.int(80)),
    #(total, json.int(200)),
  ])
}

fn event(name: String, payload: json.Json) -> String {
  "event: " <> name <> "\ndata: " <> json.to_string(payload) <> "\n\n"
}

fn data(payload: json.Json) -> String {
  "data: " <> json.to_string(payload) <> "\n\n"
}

fn provider_error(
  wire: Wire,
  status: Int,
  message: String,
) -> Response(mist.ResponseData) {
  let body = case wire {
    OpenAiWire ->
      json.object([
        #(
          "error",
          json.object([
            #("message", json.string(message)),
            #("type", json.string("rate_limit_error")),
          ]),
        ),
      ])
    AnthropicWire ->
      json.object([
        #("type", json.string("error")),
        #(
          "error",
          json.object([
            #("type", json.string("rate_limit_error")),
            #("message", json.string(message)),
          ]),
        ),
      ])
    GoogleWire ->
      json.object([
        #(
          "error",
          json.object([
            #("code", json.int(status)),
            #("message", json.string(message)),
            #("status", json.string("RESOURCE_EXHAUSTED")),
          ]),
        ),
      ])
  }
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}

fn text_response(status: Int, text: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}

// Call counter ------------------------------------------------------------

pub opaque type CallsMessage {
  Record(document_id: String, reply: Subject(Int))
  Count(document_id: String, reply: Subject(Int))
}

fn start_counter() -> Result(Subject(CallsMessage), String) {
  actor.new(dict.new())
  |> actor.on_message(fn(counts: Dict(String, Int), message) {
    case message {
      Record(id, reply) -> {
        let next = { dict.get(counts, id) |> result.unwrap(0) } + 1
        process.send(reply, next)
        actor.continue(dict.insert(counts, id, next))
      }
      Count(id, reply) -> {
        process.send(reply, dict.get(counts, id) |> result.unwrap(0))
        actor.continue(counts)
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error("could not start the call counter")
}
