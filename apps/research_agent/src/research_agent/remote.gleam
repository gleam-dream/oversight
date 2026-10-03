//// Small HTTP helpers over http_gun for the scripted APIs.

import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/result
import http_gun
import http_gun/error
import sinal/correlation

pub type Failure {
  /// The request never produced a response.
  Unreachable(failure: error.Failure)
  /// The service answered with a status we did not expect.
  Status(code: Int, body: String)
}

pub fn describe(failure: Failure) -> String {
  case failure {
    Unreachable(failure) -> "unreachable: " <> error.describe(failure)
    Status(code, _) -> "HTTP " <> int.to_string(code)
  }
}

/// A client whose requests carry the research id as their correlation.
pub fn correlated(
  client: http_gun.Client,
  research: String,
) -> http_gun.Client {
  http_gun.with_correlation(client, correlation.from_key(research))
}

pub fn call(
  client: http_gun.Client,
  method: http.Method,
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), Failure) {
  let assert Ok(base) = request.to(url)
  let req =
    base
    |> request.set_method(method)
    |> request.set_body(bit_array.from_string(body))
  let req = case body {
    "" -> req
    _ -> request.set_header(req, "content-type", "application/json")
  }
  let req =
    list.fold(headers, req, fn(req, h) { request.set_header(req, h.0, h.1) })
  use buffered <- result.try(
    http_gun.send(client, req) |> result.map_error(Unreachable),
  )
  let text = bit_array.to_string(buffered.response.body) |> result.unwrap("")
  Ok(#(buffered.response.status, text))
}

/// Expects one of `ok` statuses.
pub fn expect(
  outcome: Result(#(Int, String), Failure),
  ok: List(Int),
) -> Result(String, Failure) {
  use #(status, body) <- result.try(outcome)
  case list.contains(ok, status) {
    True -> Ok(body)
    False -> Error(Status(status, body))
  }
}
