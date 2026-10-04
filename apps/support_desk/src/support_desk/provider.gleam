//// A scripted LLM provider on loopback that speaks the OpenAI Responses
//// SSE wire format, written by `llm_wire/testing.events_for`. It is stateless: each turn reads the conversation
//// llm_wire sent (the user's request, the function calls and their
//// outputs) and plays a careful support agent. Its final answer is the
//// JSON of a `Resolution`, as the system prompt asks.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import json/blueprint/codec
import llm_wire/message
import llm_wire/testing
import mist
import support_desk/domain.{
  type Outcome, Declined, NotEligible, RefundFailed, Refunded, Resolution,
  Unconfirmed,
}

pub type Provider {
  Provider(base_url: String, requests: Subject(Seen))
}

pub fn start() -> Result(Provider, String) {
  use requests <- result.try(start_recorder())
  let ports = process.new_subject()
  use _ <- result.try(
    mist.new(fn(req) {
      case req.method, request.path_segments(req) {
        http.Post, ["v1", "responses"] ->
          case mist.read_body(req, 1_048_576) {
            Ok(req) -> {
              let body = bit_array.to_string(req.body) |> result.unwrap("")
              process.send(requests, Saw(body))
              respond(body)
            }
            Error(_) -> status(400)
          }
        _, _ -> status(404)
      }
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
    |> result.replace_error("could not start the scripted provider"),
  )
  use port <- result.map(
    process.receive(ports, 2000)
    |> result.replace_error("scripted provider did not report a port"),
  )
  Provider("http://127.0.0.1:" <> int.to_string(port) <> "/v1", requests)
}

/// Request bodies received so far, oldest first.
pub fn requests(provider: Provider) -> List(String) {
  process.call(provider.requests, 1000, Requests)
}

// The agent's script --------------------------------------------------------

type Item {
  Said(role: String, text: String)
  Called(call_id: String, name: String, arguments: String)
  Returned(call_id: String, output: String)
  Other
}

type Turn {
  CallTool(name: String, arguments: json.Json)
  Answer(Outcome, refunded_cents: Int, message: String)
}

fn respond(body: String) -> Response(mist.ResponseData) {
  case json.parse(body, decode.at(["input"], decode.list(item_decoder()))) {
    Error(_) -> status(400)
    Ok(items) -> {
      let calls = list.count(items, is_call)
      let order_id = order_id(items)
      let refused = order_id == "A-600" && !corrected(items)
      case decide(order_id, results(items)) {
        CallTool(name, arguments) ->
          sse(
            testing.tool_calls("", [
              testing.ScriptedCall(
                "call_" <> int.to_string(calls + 1),
                name,
                json.to_string(arguments),
              ),
            ]),
          )
        // Order A-600 is where the model answers in prose until told why
        // that cannot be read.
        Answer(_, _, message) if refused -> sse(testing.text(message))
        Answer(outcome, refunded, message) -> {
          let assert Ok(text) =
            codec.encode_json(
              domain.resolution(),
              Resolution(order_id, outcome, refunded, message),
            )
          sse(testing.text(text))
        }
      }
    }
  }
}

fn decide(order_id: String, results: List(#(String, String))) -> Turn {
  let lookup = json.object([#("order_id", json.string(order_id))])
  case list.last(results) {
    Error(Nil) -> CallTool("lookup_order", lookup)
    Ok(#("lookup_order", output)) ->
      case error_kind(output) {
        Ok(_) -> Answer(RefundFailed, 0, "I could not find that order.")
        Error(Nil) -> CallTool("check_refund_eligibility", lookup)
      }
    Ok(#("check_refund_eligibility", output)) -> {
      let eligible =
        json.parse(output, {
          use eligible <- decode.field("eligible", decode.bool)
          use cents <- decode.field("refundable_cents", decode.int)
          use note <- decode.field("note", decode.string)
          decode.success(#(eligible, cents, note))
        })
      case eligible {
        Ok(#(True, cents, _)) -> {
          // Order A-500 is where the model fumbles the amount once.
          let amount = case order_id {
            "A-500" -> 0
            _ -> cents
          }
          CallTool(
            "issue_refund",
            json.object([
              #("order_id", json.string(order_id)),
              #("amount_cents", json.int(amount)),
              #("reason", json.string("customer requested a refund")),
            ]),
          )
        }
        Ok(#(False, _, note)) ->
          Answer(NotEligible, 0, "This order cannot be refunded: " <> note)
        Error(_) -> Answer(RefundFailed, 0, "Eligibility was unreadable.")
      }
    }
    Ok(#("issue_refund", output)) -> settle_refund(output)
    Ok(#(_, _)) -> Answer(RefundFailed, 0, "I lost track of the request.")
  }
}

fn settle_refund(output: String) -> Turn {
  let receipt = codec.decode_json(domain.refund_receipt(), output)
  let unconfirmed =
    result.is_ok(json.parse(output, decode.at(["unconfirmed"], decode.string)))
  case receipt, unconfirmed, error_kind(output) {
    Ok(receipt), _, _ ->
      Answer(
        Refunded,
        receipt.amount_cents,
        "Your refund "
          <> receipt.refund_id
          <> " was issued and you have been notified.",
      )
    _, True, _ ->
      Answer(
        Unconfirmed,
        0,
        "I sent the refund, but the payment provider did not confirm it. "
          <> "Our finance team is checking; I will not resubmit it.",
      )
    _, _, Ok(#("rejected", detail)) ->
      Answer(Declined, 0, "A supervisor declined this refund: " <> detail)
    _, _, Ok(#("invalid_arguments", _)) ->
      Answer(
        RefundFailed,
        0,
        "I could not submit the refund: the amount I gave was invalid.",
      )
    _, _, Ok(#(message, _)) ->
      Answer(RefundFailed, 0, "The refund did not go through: " <> message)
    _, _, Error(Nil) -> Answer(RefundFailed, 0, "The refund result is unclear.")
  }
}

/// `{"error": kind, "detail"?: detail}`, as Fabric shows failures.
fn error_kind(output: String) -> Result(#(String, String), Nil) {
  json.parse(output, {
    use kind <- decode.field("error", decode.string)
    use detail <- decode.optional_field("detail", "", decode.string)
    decode.success(#(kind, detail))
  })
  |> result.replace_error(Nil)
}

/// Whether Fabric already sent the corrective message for a refused answer.
fn corrected(items: List(Item)) -> Bool {
  list.any(items, fn(item) {
    case item {
      Said("user", text) ->
        string.starts_with(text, "Your final answer could not be read")
      _ -> False
    }
  })
}

fn is_call(item: Item) -> Bool {
  case item {
    Called(..) -> True
    _ -> False
  }
}

/// Tool name and output of every answered call, in order.
fn results(items: List(Item)) -> List(#(String, String)) {
  list.filter_map(items, fn(item) {
    case item {
      Returned(call_id, output) ->
        list.find_map(items, fn(other) {
          case other {
            Called(id, name, _) if id == call_id -> Ok(#(name, output))
            _ -> Error(Nil)
          }
        })
      _ -> Error(Nil)
    }
  })
}

fn order_id(items: List(Item)) -> String {
  let prompt =
    list.find_map(items, fn(item) {
      case item {
        Said("user", text) -> Ok(text)
        _ -> Error(Nil)
      }
    })
    |> result.unwrap("")
  case string.split_once(prompt, "A-") {
    Ok(#(_, rest)) -> "A-" <> string.slice(rest, 0, 3)
    Error(Nil) -> ""
  }
}

fn item_decoder() -> decode.Decoder(Item) {
  use kind <- decode.optional_field("type", "", decode.string)
  use role <- decode.optional_field("role", "", decode.string)
  use content <- decode.optional_field(
    "content",
    "",
    decode.one_of(decode.string, [decode.success("")]),
  )
  use call_id <- decode.optional_field("call_id", "", decode.string)
  use name <- decode.optional_field("name", "", decode.string)
  use arguments <- decode.optional_field("arguments", "", decode.string)
  use output <- decode.optional_field("output", "", decode.string)
  decode.success(case kind, role {
    "function_call", _ -> Called(call_id, name, arguments)
    "function_call_output", _ -> Returned(call_id, output)
    _, "" -> Other
    _, role -> Said(role, content)
  })
}

// OpenAI Responses SSE ------------------------------------------------------

/// The scripted reply as the OpenAI Responses stream llm_wire's own
/// `testing.events_for` writes, with the usage the old fixture reported.
fn wire(reply: testing.Reply) -> testing.Reply {
  testing.with_usage(reply, message.Usage(150, 40, 190))
  |> testing.events_for(message.OpenAI, _)
}

fn sse(reply: testing.Reply) -> Response(mist.ResponseData) {
  case wire(reply) {
    testing.Events(chunks) ->
      response.new(200)
      |> response.set_header("content-type", "text/event-stream")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(string.concat(chunks))),
      )
    testing.Interrupted(_) | testing.Status(..) -> status(500)
  }
}

fn status(code: Int) -> Response(mist.ResponseData) {
  response.new(code) |> response.set_body(mist.Bytes(bytes_tree.new()))
}

// Request recorder ----------------------------------------------------------

pub opaque type Seen {
  Saw(String)
  Requests(reply: Subject(List(String)))
}

fn start_recorder() -> Result(Subject(Seen), String) {
  actor.new([])
  |> actor.on_message(fn(seen: List(String), message) {
    case message {
      Saw(body) -> actor.continue([body, ..seen])
      Requests(reply) -> {
        process.send(reply, list.reverse(seen))
        actor.continue(seen)
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error("could not start the provider recorder")
}
