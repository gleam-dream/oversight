//// The scripted service's application protocol over HTTP Gun. A missing
//// lookup result is deliberately not authoritative proof of non-execution.

import financial_recovery/domain.{type OperationId, type Payment}
import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/json
import gleam/result
import gleam/uri
import http_gun
import http_gun/error

pub type Provider {
  Provider(client: http_gun.Client, base: String)
}

pub type Error {
  Transport(error.Failure)
  Status(Int)
  InvalidResponse
}

pub fn submit(provider: Provider, payment: Payment) -> Result(String, Error) {
  call(
    provider,
    http.Post,
    "/payments",
    domain.id(payment.id),
    json.to_string(domain.encode(payment)),
  )
}

pub fn lookup(provider: Provider, id: OperationId) -> Result(String, Error) {
  call(
    provider,
    http.Get,
    "/payments/" <> uri.percent_encode(domain.id(id)),
    domain.id(id),
    "",
  )
}

fn call(
  provider: Provider,
  method: http.Method,
  path: String,
  key: String,
  body: String,
) -> Result(String, Error) {
  let assert Ok(req) = request.to(provider.base <> path)
  let req =
    req
    |> request.set_method(method)
    |> request.set_header("idempotency-key", key)
    |> request.set_body(bit_array.from_string(body))
  use response <- result.try(
    http_gun.send(provider.client, req) |> result.map_error(Transport),
  )
  case response.response.status {
    200 ->
      bit_array.to_string(response.response.body)
      |> result.replace_error(InvalidResponse)
    status -> Error(Status(status))
  }
}
