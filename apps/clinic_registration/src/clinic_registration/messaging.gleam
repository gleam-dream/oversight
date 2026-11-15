//// The messaging provider, as the clinic calls it: send a contact a text
//// under an idempotency key, and look a message up by that key. The key is
//// the release key of the registration, so one registration sends at most
//// one confirmation however often the job runs.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import http_gun
import http_gun/config
import http_gun/error

/// Where the provider is and how long one request may take.
pub type Messaging {
  Messaging(client: http_gun.Client, base_url: String, deadline: Duration)
}

/// What became of a send.
pub type Sending {
  /// The provider accepted it; `receipt` is its message id.
  Delivered(receipt: String)
  /// The provider refused it and sent nothing.
  Turned(reason: String)
  /// Nothing reached the provider. Sending again is safe.
  Unreachable(reason: String)
  /// The request may have reached the provider and no answer arrived. Only
  /// a lookup by the key can tell.
  Unknown(reason: String)
}

/// The message the provider holds under `key`, if any.
pub fn lookup(
  messaging: Messaging,
  key: String,
) -> Result(Option(String), String) {
  let assert Ok(req) = request.to(messaging.base_url <> "/messages/" <> key)
  case http_gun.send(view(messaging), request.set_body(req, <<>>)) {
    Ok(buffered) ->
      case buffered.response.status {
        200 ->
          receipt(buffered.response.body)
          |> result.map(Some)
        404 -> Ok(None)
        status -> Error("the lookup answered " <> int_text(status))
      }
    Error(failure) -> Error(error.describe(failure))
  }
}

/// Send `text` to `to` under `key`.
pub fn send(
  messaging: Messaging,
  key key: String,
  to to: String,
  text text: String,
) -> Sending {
  let assert Ok(req) = request.to(messaging.base_url <> "/messages")
  let body =
    json.object([#("to", json.string(to)), #("text", json.string(text))])
    |> json.to_string
    |> bit_array.from_string
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("idempotency-key", key)
    |> request.set_body(body)
  case http_gun.send(view(messaging), req) {
    Ok(buffered) ->
      case buffered.response.status {
        status if status >= 200 && status < 300 ->
          case receipt(buffered.response.body) {
            Ok(id) -> Delivered(id)
            Error(reason) -> Unknown(reason)
          }
        status if status >= 400 && status < 500 ->
          Turned("the provider answered " <> int_text(status))
        status -> Unknown("the provider answered " <> int_text(status))
      }
    Error(failure) ->
      case error.evidence(failure) {
        error.NotSent -> Unreachable(error.describe(failure))
        error.MaybeSent -> Unknown(error.describe(failure))
      }
  }
}

fn view(messaging: Messaging) -> http_gun.Client {
  http_gun.with_timeout(messaging.client, config.After(messaging.deadline))
}

fn receipt(body: BitArray) -> Result(String, String) {
  json.parse_bits(body, decode.at(["id"], decode.string))
  |> result.replace_error("the provider's answer names no message")
}

fn int_text(n: Int) -> String {
  int.to_string(n)
}
