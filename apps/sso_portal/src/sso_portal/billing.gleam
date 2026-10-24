//// Billing API client: http_gun requests carrying the user's Hellhound access
//// token.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/request
import gleam/json
import gleam/result
import hellhound
import http_gun
import http_gun/error

pub type Invoice {
  Invoice(id: String, amount_cents: Int, status: String)
}

pub type BillingError {
  /// The API refused the token (401): refresh and retry once.
  Unauthorized
  /// The request did not complete; `error.Failure` keeps the reason and
  /// whether it may have been sent.
  Unavailable(error.Failure)
  UnexpectedStatus(Int)
  MalformedBody
}

pub fn invoices(
  client: http_gun.Client,
  base_url: String,
  token: hellhound.AccessToken,
) -> Result(List(Invoice), BillingError) {
  let assert Ok(base) = request.to(base_url <> "/invoices")
  let req =
    base
    |> hellhound.authorize(token)
    |> request.set_header("accept", "application/json")
    |> request.set_body(<<>>)
  use buffered <- result.try(
    http_gun.send(client, req) |> result.map_error(Unavailable),
  )
  case buffered.response.status {
    200 ->
      bit_array.to_string(buffered.response.body)
      |> result.replace_error(MalformedBody)
      |> result.try(fn(text) {
        json.parse(
          text,
          decode.at(["invoices"], decode.list(invoice_decoder())),
        )
        |> result.replace_error(MalformedBody)
      })
    401 -> Error(Unauthorized)
    status -> Error(UnexpectedStatus(status))
  }
}

fn invoice_decoder() -> decode.Decoder(Invoice) {
  use id <- decode.field("id", decode.string)
  use amount_cents <- decode.field("amount_cents", decode.int)
  use status <- decode.field("status", decode.string)
  decode.success(Invoice(id:, amount_cents:, status:))
}
