//// Scripted loopback services: an LLM provider that speaks the OpenAI
//// Responses wire (through llm_wire's testing module), a messaging
//// provider that sends a contact a text under an idempotency key and looks
//// a message up by that key, and an OpenID provider (Hellhound's test
//// provider) where the clinic's staff sign in, with a scripted browser
//// that walks a member of staff through the desk's login.
////
//// The LLM provider finds the contact's marker (`[[contact:...]]`) in the
//// request and plays that contact's script, one reply per call; the last
//// reply repeats. The messaging provider keeps every message it accepted,
//// so a lookup can settle a send whose answer was lost.

import clinic_registration/access
import clinic_registration/domain.{type Extraction}
import clinic_registration/owner.{type Owner}
import decisions/vocabulary.{type Validator}
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
import gleam/time/duration
import gleam/uri
import hellhound/testing as identity
import http_gun
import http_gun/config as http_config
import http_gun/destination
import http_gun/error as http_error
import llm_wire/message
import llm_wire/testing
import mist

/// How the provider answers one call.
pub type Reply {
  /// The structured answer.
  Answer(Extraction)
  /// Text that is not the structured answer.
  NotStructured(text: String)
  /// An end with a stop reason llm_wire does not know.
  UnrecognizedStop(reason: String)
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
    identity: identity.Provider,
    servers: Owner,
  )
}

/// The OpenID provider where the clinic's staff sign in.
pub fn identity_provider(services: Services) -> identity.Provider {
  services.identity
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
  use #(#(llm_port, messaging_port, identity), servers) <- result.try(
    owner.start(fn() {
      use llm_port <- result.try(serve(llm_handler(state, _)))
      use messaging_port <- result.try(serve(messaging_handler(state, _)))
      use provider <- result.try(
        identity.start_provider(identity.provider_options())
        |> result.replace_error("the OpenID provider did not start"),
      )
      Ok(#(llm_port, messaging_port, provider))
    }),
  )
  Ok(Services(state:, llm_port:, messaging_port:, identity:, servers:))
}

pub fn stop(services: Services) -> Nil {
  identity.stop_provider(services.identity)
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
    UnrecognizedStop(reason:) -> openai(testing.unrecognized_stop(reason, ""))
    Status(code:) ->
      openai(testing.http_status(message.OpenAI, code, "scripted failure"))
  }
}

fn openai(reply: testing.Reply) -> Response(mist.ResponseData) {
  testing.http_response(
    message.OpenAI,
    reply |> testing.with_usage(message.Usage(310, 90, 400, None)),
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

// -- A member of staff signing in --------------------------------------------------

/// A loopback port that was free a moment ago, for an application whose
/// callback address must be known before its listener binds.
@external(erlang, "clinic_registration_ffi", "free_port")
pub fn free_port() -> Int

/// The desk's sign-in at this provider, for a desk listening on `port`,
/// with each `#(subject, validator)` pair as a member of staff.
pub fn staff_sign_in(
  services: Services,
  port: Int,
  members: List(#(String, Validator)),
) -> Result(access.SignIn, String) {
  let issuer = identity.issuer(services.identity)
  use staff <- result.map(
    access.staff(
      list.map(members, fn(member) {
        access.Member(issuer:, subject: member.0, acts_as: member.1)
      }),
    ),
  )
  access.SignIn(
    relying_party: identity.config(
      services.identity,
      "http://127.0.0.1:" <> int.to_string(port) <> "/auth/callback",
    ),
    staff:,
  )
}

/// Walk a browser through the desk's login as `subject`: `GET /login` on
/// the application at `base_url`, the provider's login page, which signs
/// `subject` in, and the application's callback. Returns the `cookie`
/// header value that carries the desk session the callback set, or the
/// status and body of the step that did not go on.
pub fn sign_in(
  services: Services,
  base_url: String,
  subject: String,
) -> Result(String, String) {
  identity.set_login(services.identity, identity.SignIn(subject))
  let assert Ok(client) =
    http_config.default()
    |> http_config.with_trust(
      http_config.Anchors([identity.trust_anchor_der(services.identity)]),
    )
    |> http_config.with_destination(destination.loopback_only())
    |> http_gun.start
    |> result.map(http_gun.with_timeout(_, duration.seconds(10)))
  let walked = walk(client, base_url <> "/login", dict.new(), 4)
  http_gun.stop(client)
  use jar <- result.try(walked)
  dict.to_list(jar)
  |> list.find(fn(cookie) { cookie.0 == session_cookie })
  |> result.map(fn(cookie) { cookie.0 <> "=" <> cookie.1 })
  |> result.replace_error("the callback set no desk session")
}

/// The name of the application's session cookie.
pub const session_cookie = "clinic_session"

/// Follow redirects from `url`, keeping cookies, until a response that is
/// not a redirect. A 2xx or a redirect to a page of the application ends
/// the walk successfully.
fn walk(
  client: http_gun.Client,
  url: String,
  jar: Dict(String, String),
  hops: Int,
) -> Result(Dict(String, String), String) {
  let assert Ok(req) = request.to(url)
  let cookies =
    dict.to_list(jar)
    |> list.map(fn(cookie) { cookie.0 <> "=" <> cookie.1 })
    |> string.join("; ")
  let req = case cookies {
    "" -> req
    _ -> request.set_header(req, "cookie", cookies)
  }
  use reply <- result.try(
    http_gun.send(client, request.set_body(req, <<>>))
    |> result.map_error(http_error.describe),
  )
  let jar =
    list.fold(reply.response.headers, jar, fn(jar, header) {
      case header {
        #("set-cookie", value) -> keep_cookie(jar, value)
        _ -> jar
      }
    })
  let status = reply.response.status
  case list.key_find(reply.response.headers, "location") {
    Ok(next) if status >= 300 && status < 400 && hops > 0 ->
      case string.contains(url, "/auth/callback") {
        // The callback's redirect leads into the desk: signed in.
        True -> Ok(jar)
        False -> walk(client, resolve(url, next), jar, hops - 1)
      }
    _ if status >= 200 && status < 300 -> Ok(jar)
    _ ->
      Error(
        url
        <> " answered "
        <> int.to_string(status)
        <> ": "
        <> { bit_array.to_string(reply.response.body) |> result.unwrap("") },
      )
  }
}

fn keep_cookie(
  jar: Dict(String, String),
  header: String,
) -> Dict(String, String) {
  let parts = string.split(header, ";") |> list.map(string.trim)
  case parts {
    [pair, ..attributes] ->
      case string.split_once(pair, "=") {
        Ok(#(name, value)) -> {
          let expired =
            value == ""
            || list.any(attributes, fn(attribute) {
              string.lowercase(attribute) == "max-age=0"
            })
          case expired {
            True -> dict.delete(jar, name)
            False -> dict.insert(jar, name, value)
          }
        }
        Error(Nil) -> jar
      }
    [] -> jar
  }
}

fn resolve(base: String, target: String) -> String {
  case uri.parse(base), uri.parse(target) {
    Ok(base), Ok(relative) ->
      uri.merge(base, relative)
      |> result.map(uri.to_string)
      |> result.unwrap(target)
    _, _ -> target
  }
}
