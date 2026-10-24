//// The scripted downstream "billing API": a plain-HTTP loopback service that
//// accepts only bearer tokens that `warden/resource` validates locally
//// against the provider's keys, minus a deny list the test can fill.
////
//// The deny list stays because validation is local: a JWT access token has
//// no revocation channel, so `testing.revoke_access_token` is seen by
//// introspection and userinfo but not by `resource.verify` until `exp`. The
//// list models an incident response (the API refuses a token the provider
//// and `exp` still call live). Introspection would replace it only if the
//// API called the provider per request, which is a different API.

import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/option.{None}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import sso_portal/server.{type Server}
import warden
import warden/resource
import wisp.{type Request, type Response}

pub type BillingApi {
  BillingApi(
    server: Server,
    base_url: String,
    /// A started resource-server client for the provider's issuer.
    warden: warden.Client,
    tokens: Subject(Message),
  )
}

pub type Message {
  /// Note a token that was accepted.
  Seen(String)
  /// Is this token denied?
  Denied(String, reply: Subject(Bool))
  /// Deny every token accepted so far.
  DenySeen
}

type Tokens {
  Tokens(seen: Set(String), denied: Set(String))
}

/// `warden` is a started `config.resource_server` client; `audience` is the
/// audience the provider puts in the portal's access tokens.
pub fn start(
  warden: warden.Client,
  audience audience: String,
) -> Result(BillingApi, String) {
  use tokens <- result.try(
    actor.new(Tokens(set.new(), set.new()))
    |> actor.on_message(track)
    |> actor.start
    |> result.map(fn(started) { started.data })
    |> result.replace_error("billing deny list did not start"),
  )
  let validator = resource.new(warden, audience:)
  use server <- result.try(server.start(
    handle(_, validator, tokens),
    wisp.random_string(64),
    None,
  ))
  Ok(BillingApi(
    server:,
    base_url: "http://127.0.0.1:" <> int.to_string(server.port),
    warden:,
    tokens:,
  ))
}

/// Take the API down (connections are refused afterwards).
pub fn stop(api: BillingApi) -> Nil {
  server.stop(api.server)
}

/// Refuse every token the API has accepted so far, though the provider and
/// the tokens' own `exp` still call them live.
pub fn deny_accepted_tokens(api: BillingApi) -> Nil {
  process.send(api.tokens, DenySeen)
}

fn track(state: Tokens, message: Message) -> actor.Next(Tokens, Message) {
  case message {
    Seen(token) ->
      actor.continue(Tokens(..state, seen: set.insert(state.seen, token)))
    Denied(token, reply) -> {
      process.send(reply, set.contains(state.denied, token))
      actor.continue(state)
    }
    DenySeen -> actor.continue(Tokens(..state, denied: state.seen))
  }
}

fn handle(
  request: Request,
  validator: resource.Validator,
  tokens: Subject(Message),
) -> Response {
  case request.method, wisp.path_segments(request) {
    http.Get, ["invoices"] ->
      case request.get_header(request, "authorization") {
        Ok("Bearer " <> token) ->
          case resource.verify(validator, token) {
            Ok(claims) ->
              case process.call(tokens, 1000, Denied(token, _)) {
                True -> unauthorized()
                False -> {
                  process.send(tokens, Seen(token))
                  invoices(resource.subject(claims))
                }
              }
            Error(error) ->
              case resource.error_kind(error) {
                resource.Unavailable -> wisp.response(503)
                _ -> unauthorized()
              }
          }
        _ -> unauthorized()
      }
    _, _ -> wisp.not_found()
  }
}

fn invoices(subject: String) -> Response {
  json.object([
    #("customer", json.string(subject)),
    #(
      "invoices",
      json.preprocessed_array([
        invoice("INV-1001", 4200, "paid"),
        invoice("INV-1002", 1999, "open"),
      ]),
    ),
  ])
  |> json.to_string
  |> wisp.json_response(200)
}

fn invoice(id: String, amount_cents: Int, status: String) -> json.Json {
  json.object([
    #("id", json.string(id)),
    #("amount_cents", json.int(amount_cents)),
    #("status", json.string(status)),
  ])
}

fn unauthorized() -> Response {
  wisp.response(401)
  |> wisp.set_header("www-authenticate", "Bearer error=\"invalid_token\"")
}
