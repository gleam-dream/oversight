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
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import llm_wire/message.{type Provider}
import llm_wire/testing
import mist

pub type Behavior {
  /// The provider answers with this text as the structured output.
  Answer(output: String)
  /// The first call gets 429 with `Retry-After`; later calls answer.
  RateLimitedOnce(retry_after_seconds: Int, output: String)
  /// Every call gets this HTTP status (429 carries `Retry-After: 2`).
  AlwaysStatus(status: Int)
  /// The provider's content filter stops the output after `partial_text`.
  ContentFiltered(partial_text: String)
  /// The provider's content filter blocks the prompt. Only Gemini's wire
  /// carries this as a stop; OpenAI and Anthropic reject such a prompt with
  /// HTTP 400, which is a plain status error.
  PromptBlocked
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
    http.Post, ["openai", "v1", "responses"] -> Ok(message.OpenAI)
    http.Post, ["anthropic", "v1", "messages"] -> Ok(message.Anthropic)
    http.Post, ["google", "v1beta", "models", _] -> Ok(message.Google)
    _, _ -> Error(Nil)
  }
  case wire, mist.read_body(req, 1_048_576) {
    Ok(wire), Ok(req) -> {
      let text = bit_array.to_string(req.body) |> result.unwrap("")
      let document_id = marker(text)
      let attempt = process.call(calls, 1000, Record(document_id, _))
      case dict.get(table, document_id) {
        Error(Nil) ->
          serve_reply(wire, testing.http_status(wire, 400, "unknown document"))
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

fn answer(
  wire: Provider,
  behavior: Behavior,
  attempt: Int,
) -> Response(mist.ResponseData) {
  case behavior {
    Answer(output) -> serve_reply(wire, text_reply(output))
    RateLimitedOnce(seconds, _) if attempt == 1 ->
      rate_limited(wire, duration.seconds(seconds))
    RateLimitedOnce(_, output) -> serve_reply(wire, text_reply(output))
    ContentFiltered(partial_text) ->
      serve_reply(wire, testing.content_filtered(partial_text))
    PromptBlocked ->
      case wire {
        message.Google -> serve_reply(wire, testing.prompt_blocked())
        message.OpenAI | message.Anthropic | message.Custom(_) ->
          serve_reply(wire, testing.http_status(wire, 400, "prompt rejected"))
      }
    AlwaysStatus(429) -> rate_limited(wire, duration.seconds(2))
    AlwaysStatus(status) ->
      serve_reply(wire, testing.http_status(wire, status, "unavailable"))
  }
}

fn rate_limited(
  wire: Provider,
  delay: Duration,
) -> Response(mist.ResponseData) {
  testing.http_response(wire, testing.rate_limited(wire))
  |> testing.with_retry_after_header(delay)
  |> to_mist
}

fn text_reply(output: String) -> testing.Reply {
  testing.text(output) |> testing.with_usage(message.Usage(120, 80, 200))
}

/// A reply in `wire`'s own format, lowered by llm_wire's testing module:
/// status, content type and body for a success, an error status or a stream.
fn serve_reply(
  wire: Provider,
  reply: testing.Reply,
) -> Response(mist.ResponseData) {
  to_mist(testing.http_response(wire, reply))
}

fn to_mist(http: Response(String)) -> Response(mist.ResponseData) {
  response.map(http, fn(body) { mist.Bytes(bytes_tree.from_string(body)) })
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
