//// The scripted downstream "billing API": a plain-HTTP loopback service that
//// accepts only live bearer tokens issued by the scripted provider.

import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/option.{None}
import gleam/result
import sso_portal/fake_idp.{type Idp}
import sso_portal/server.{type Server}
import wisp.{type Request, type Response}

pub type BillingApi {
  BillingApi(server: Server, base_url: String)
}

pub fn start(idp: Idp) -> Result(BillingApi, String) {
  use server <- result.try(server.start(
    handle(_, idp),
    wisp.random_string(64),
    None,
  ))
  Ok(BillingApi(
    server:,
    base_url: "http://127.0.0.1:" <> int.to_string(server.port),
  ))
}

/// Take the API down (connections are refused afterwards).
pub fn stop(api: BillingApi) -> Nil {
  server.stop(api.server)
}

fn handle(request: Request, idp: Idp) -> Response {
  case request.method, wisp.path_segments(request) {
    http.Get, ["invoices"] ->
      case request.get_header(request, "authorization") {
        Ok("Bearer " <> token) ->
          case fake_idp.check_access(idp, token) {
            Ok(subject) -> invoices(subject)
            Error(Nil) -> unauthorized()
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
