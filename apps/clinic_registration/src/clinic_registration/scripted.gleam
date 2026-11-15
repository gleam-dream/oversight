//// Scripted loopback services: an LLM provider that speaks the OpenAI
//// Responses wire (through llm_wire's testing module), and a messaging
//// provider that sends a contact a text under an idempotency key and looks
//// a message up by that key.
////
//// The LLM provider finds the contact's marker (`[[contact:...]]`) in the
//// request and plays that contact's script, one reply per call; the last
//// reply repeats. The messaging provider keeps every message it accepted,
//// so a lookup can settle a send whose answer was lost.

import clinic_registration/domain.{type Extraction}
import clinic_registration/owner.{type Owner}
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import llm_wire/message
import llm_wire/testing
import mist

/// How the provider answers one call.
pub type Reply {
  /// The structured answer.
  Answer(Extraction)
  /// Text that is not the structured answer.
  NotStructured(text: String)
  /// An HTTP error status.
  Status(code: Int)
  /// Wait this long, then reply.
  Stall(milliseconds: Int, then: Reply)
}

/// How the messaging provider treats a recipient.
pub type Recipient {
  /// Accept and answer at once.
  Deliver
  /// Accept the first send, then hold its answer this long; later sends
  /// and lookups answer at once.
  SlowFirstAnswer(milliseconds: Int)
  /// Refuse every send with 422.
  Refuse(reason: String)
}

/// A message the messaging provider accepted.
pub type Sent {
  Sent(id: String, key: String, to: String, text: String)
}

pub opaque type Services {
  Services(
    state: Subject(Message),
    llm_port: Int,
    messaging_port: Int,
    servers: Owner,
  )
}

/// The root of the LLM provider.
pub fn llm_base(services: Services) -> String {
  "http://127.0.0.1:" <> int.to_string(services.llm_port)
}

/// The root of the messaging provider.
pub fn messaging_base(services: Services) -> String {
  "http://127.0.0.1:" <> int.to_string(services.messaging_port)
}

/// The two ports, for a client's destination policy.
pub fn ports(services: Services) -> List(Int) {
  [services.llm_port, services.messaging_port]
}

/// Script the LLM's replies for a contact, replacing an earlier script.
pub fn script(
  services: Services,
  contact: String,
  replies: List(Reply),
) -> Nil {
  process.call(services.state, 1000, Script(contact, replies, _))
}

/// How a recipient is treated from now on.
pub fn recipient(
  services: Services,
  phone: String,
  treatment: Recipient,
) -> Nil {
  process.call(services.state, 1000, Treat(phone, treatment, _))
}

/// How many calls the LLM provider received for a contact.
pub fn llm_calls(services: Services, contact: String) -> Int {
  process.call(services.state, 1000, LlmCalls(contact, _))
}

/// Every message the messaging provider accepted, oldest first.
pub fn sent(services: Services) -> List(Sent) {
  process.call(services.state, 1000, AllSent)
}

/// How many send requests carried this idempotency key.
pub fn sends(services: Services, key: String) -> Int {
  process.call(services.state, 1000, SendCount(key, _))
}

pub fn start() -> Result(Services, String) {
  use state <- result.try(start_state())
  use #(#(llm_port, messaging_port), servers) <- result.try(
    owner.start(fn() {
      use llm_port <- result.try(serve(llm_handler(state, _)))
      use messaging_port <- result.try(serve(messaging_handler(state, _)))
      Ok(#(llm_port, messaging_port))
    }),
  )
  Ok(Services(state:, llm_port:, messaging_port:, servers:))
}

pub fn stop(services: Services) -> Nil {
  owner.stop(services.servers)
  process.send(services.state, Stop)
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
    |> result.replace_error("the loopback server did not report its port")
  })
}

fn body_of(req: Request(mist.Connection)) -> String {
  case mist.read_body(req, 1_048_576) {
    Ok(read) -> bit_array.to_string(read.body) |> result.unwrap("")
    Error(_) -> ""
  }
}

fn text_response(status: Int, text: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}

// -- The LLM provider ----------------------------------------------------------

fn llm_handler(
  state: Subject(Message),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case req.method, request.path_segments(req) {
    http.Post, ["openai", "v1", "responses"] -> {
      let body = body_of(req)
      let contact = marker(body)
      let reply = process.call(state, 1000, NextReply(contact, _))
      answer(reply)
    }
    _, _ -> text_response(404, "{\"error\":\"not found\"}")
  }
}

fn answer(reply: Reply) -> Response(mist.ResponseData) {
  case reply {
    Stall(milliseconds:, then:) -> {
      process.sleep(milliseconds)
      answer(then)
    }
    Answer(extraction) ->
      openai(
        testing.text(domain.to_text(domain.extraction_codec(), extraction)),
      )
    NotStructured(text:) -> openai(testing.text(text))
    Status(code:) ->
      openai(testing.http_status(message.OpenAI, code, "scripted failure"))
  }
}

fn openai(reply: testing.Reply) -> Response(mist.ResponseData) {
  testing.http_response(
    message.OpenAI,
    reply |> testing.with_usage(message.Usage(310, 90, 400)),
  )
  |> response.map(fn(body) { mist.Bytes(bytes_tree.from_string(body)) })
}

/// The JSON string escapes nothing inside the marker, which is a phone.
fn marker(body: String) -> String {
  case string.split_once(body, "[[contact:") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "]]") {
        Ok(#(contact, _)) -> contact
        Error(Nil) -> ""
      }
    Error(Nil) -> ""
  }
}

// -- The messaging provider ----------------------------------------------------

fn messaging_handler(
  state: Subject(Message),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case req.method, request.path_segments(req) {
    http.Post, ["messages"] -> {
      let key = request.get_header(req, "idempotency-key") |> result.unwrap("")
      let parsed =
        json.parse(body_of(req), {
          use to <- decode.field("to", decode.string)
          use text <- decode.field("text", decode.string)
          decode.success(#(to, text))
        })
      case key, parsed {
        "", _ | _, Error(_) -> text_response(400, "{\"error\":\"bad request\"}")
        key, Ok(#(to, text)) ->
          case process.call(state, 1000, Accept(key, to, text, _)) {
            Accepted(sent, hold) -> {
              process.sleep(hold)
              text_response(201, json.to_string(sent_json(sent)))
            }
            Turned(reason) ->
              text_response(
                422,
                json.to_string(json.object([#("error", json.string(reason))])),
              )
          }
      }
    }
    http.Get, ["messages", key] ->
      case process.call(state, 1000, Lookup(key, _)) {
        Some(sent) -> text_response(200, json.to_string(sent_json(sent)))
        None -> text_response(404, "{\"error\":\"no message under this key\"}")
      }
    _, _ -> text_response(404, "{\"error\":\"not found\"}")
  }
}

fn sent_json(sent: Sent) -> json.Json {
  json.object([
    #("id", json.string(sent.id)),
    #("key", json.string(sent.key)),
    #("to", json.string(sent.to)),
  ])
}

// -- State ---------------------------------------------------------------------

type State {
  State(
    scripts: Dict(String, List(Reply)),
    calls: Dict(String, Int),
    recipients: Dict(String, Recipient),
    messages: List(Sent),
    sends: Dict(String, Int),
  )
}

type Acceptance {
  Accepted(sent: Sent, hold: Int)
  Turned(reason: String)
}

type Message {
  Script(contact: String, replies: List(Reply), reply: Subject(Nil))
  NextReply(contact: String, reply: Subject(Reply))
  LlmCalls(contact: String, reply: Subject(Int))
  Treat(phone: String, treatment: Recipient, reply: Subject(Nil))
  Accept(key: String, to: String, text: String, reply: Subject(Acceptance))
  Lookup(key: String, reply: Subject(option.Option(Sent)))
  AllSent(reply: Subject(List(Sent)))
  SendCount(key: String, reply: Subject(Int))
  Stop
}

fn start_state() -> Result(Subject(Message), String) {
  actor.new(State(dict.new(), dict.new(), dict.new(), [], dict.new()))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error("could not start the scripted services' state")
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Script(contact:, replies:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(
        State(..state, scripts: dict.insert(state.scripts, contact, replies)),
      )
    }
    NextReply(contact:, reply:) -> {
      let calls = dict.get(state.calls, contact) |> result.unwrap(0)
      let #(next, rest) = case dict.get(state.scripts, contact) {
        Ok([only]) -> #(only, [only])
        Ok([first, ..rest]) -> #(first, rest)
        _ -> #(Status(400), [])
      }
      process.send(reply, next)
      actor.continue(
        State(
          ..state,
          scripts: dict.insert(state.scripts, contact, rest),
          calls: dict.insert(state.calls, contact, calls + 1),
        ),
      )
    }
    LlmCalls(contact:, reply:) -> {
      process.send(reply, dict.get(state.calls, contact) |> result.unwrap(0))
      actor.continue(state)
    }
    Treat(phone:, treatment:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(
        State(
          ..state,
          recipients: dict.insert(state.recipients, phone, treatment),
        ),
      )
    }
    Accept(key:, to:, text:, reply:) -> {
      let sends =
        dict.insert(
          state.sends,
          key,
          { dict.get(state.sends, key) |> result.unwrap(0) } + 1,
        )
      let existing = list.find(state.messages, fn(sent) { sent.key == key })
      let treatment = dict.get(state.recipients, to) |> result.unwrap(Deliver)
      case treatment, existing {
        Refuse(reason), _ -> {
          process.send(reply, Turned(reason))
          actor.continue(State(..state, sends:))
        }
        _, Ok(sent) -> {
          process.send(reply, Accepted(sent, 0))
          actor.continue(State(..state, sends:))
        }
        _, Error(Nil) -> {
          let sent =
            Sent(
              id: "msg-" <> int.to_string(list.length(state.messages) + 1),
              key:,
              to:,
              text:,
            )
          let hold = case treatment {
            SlowFirstAnswer(milliseconds:) -> milliseconds
            _ -> 0
          }
          process.send(reply, Accepted(sent, hold))
          actor.continue(
            State(
              ..state,
              sends:,
              messages: list.append(state.messages, [sent]),
            ),
          )
        }
      }
    }
    Lookup(key:, reply:) -> {
      process.send(
        reply,
        list.find(state.messages, fn(sent) { sent.key == key })
          |> option.from_result,
      )
      actor.continue(state)
    }
    AllSent(reply:) -> {
      process.send(reply, state.messages)
      actor.continue(state)
    }
    SendCount(key:, reply:) -> {
      process.send(reply, dict.get(state.sends, key) |> result.unwrap(0))
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}

/// A plausible answer for a contact, for scripts.
pub fn extraction(
  name name: String,
  birth_date birth_date: option.Option(String),
  phone phone: String,
  insurer insurer: option.Option(String),
  plan plan: option.Option(String),
  confidence confidence: Float,
) -> Extraction {
  let missing =
    [#("birth_date", birth_date), #("insurer", insurer)]
    |> list.filter_map(fn(field) {
      case field.1 {
        None -> Ok(field.0)
        Some(_) -> Error(Nil)
      }
    })
  domain.Extraction(
    name:,
    birth_date:,
    phone: Some(phone),
    insurer:,
    plan:,
    consent: True,
    confidence:,
    missing:,
  )
}
