//// HTTP adapters for the orders, payments and notification APIs, over one
//// caller-owned http_gun client. Each adapter turns http_gun's typed
//// failure (reason plus submission evidence) into the desk's own error,
//// keeping "definitely not done" apart from "may have happened".

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/result
import http_gun
import http_gun/error as http_error
import json/blueprint/codec
import support_desk/domain.{type Order, type RefundRequest}

pub type Shop {
  Shop(client: http_gun.Client, base_url: String)
}

pub type LookupError {
  NoSuchOrder(order_id: String)
  OrdersUnavailable(detail: String)
}

/// Why a refund step failed, as the saga's typed step error.
pub type RefundError {
  /// The provider answered and refused: nothing happened.
  PaymentDeclined(status: Int)
  /// The request never left: nothing happened.
  PaymentUnavailable(detail: String)
  /// The request may have reached the provider: the refund may exist.
  PaymentOutcomeUnknown(detail: String)
  /// The customer could not be told; the refund is rolled back.
  NotificationFailed(detail: String)
}

pub type UndoError {
  VoidFailed(detail: String)
  LedgerEntryMissing(entry: Int)
}

pub fn get_order(shop: Shop, order_id: String) -> Result(Order, LookupError) {
  use response <- result.try(
    call(shop, http.Get, "/orders/" <> order_id, "")
    |> result.map_error(fn(failure) {
      OrdersUnavailable(http_error.describe(failure))
    }),
  )
  case response.status {
    200 ->
      codec.decode_json(domain.order(), response.body)
      |> result.map_error(fn(error) {
        OrdersUnavailable(codec.describe_decode_error(error))
      })
    404 -> Error(NoSuchOrder(order_id))
    _ -> Error(OrdersUnavailable("orders API answered " <> status(response)))
  }
}

/// Refunds through the payment provider; the idempotency key is the order.
pub fn refund(
  shop: Shop,
  request: RefundRequest,
) -> Result(String, RefundError) {
  let body =
    json.object([
      #("order_id", json.string(request.order_id)),
      #("amount_cents", json.int(request.amount_cents)),
      #("idempotency_key", json.string("refund-" <> request.order_id)),
    ])
  case call(shop, http.Post, "/payments/refunds", json.to_string(body)) {
    Error(http_error.Failure(evidence: http_error.NotSubmitted, ..) as failure) ->
      Error(PaymentUnavailable(http_error.describe(failure)))
    Error(
      http_error.Failure(evidence: http_error.MayHaveBeenSent, ..) as failure,
    ) -> Error(PaymentOutcomeUnknown(http_error.describe(failure)))
    Ok(Reply(201, text)) ->
      json.parse(text, decode.at(["refund_id"], decode.string))
      |> result.replace_error(PaymentOutcomeUnknown(
        "provider accepted but sent no refund id",
      ))
    Ok(Reply(code, _)) if code >= 500 ->
      Error(PaymentOutcomeUnknown("provider answered " <> int.to_string(code)))
    Ok(Reply(code, _)) -> Error(PaymentDeclined(code))
  }
}

pub fn void(shop: Shop, refund_id: String) -> Result(Nil, UndoError) {
  case
    call(shop, http.Post, "/payments/refunds/" <> refund_id <> "/void", "{}")
  {
    Ok(Reply(200, _)) -> Ok(Nil)
    Ok(response) -> Error(VoidFailed("provider answered " <> status(response)))
    Error(failure) -> Error(VoidFailed(http_error.describe(failure)))
  }
}

pub fn notify(
  shop: Shop,
  order_id: String,
  message: String,
) -> Result(Nil, RefundError) {
  let body =
    json.object([
      #("order_id", json.string(order_id)),
      #("message", json.string(message)),
    ])
  case call(shop, http.Post, "/notify", json.to_string(body)) {
    Ok(Reply(202, _)) -> Ok(Nil)
    Ok(response) ->
      Error(NotificationFailed("notifier answered " <> status(response)))
    Error(failure) -> Error(NotificationFailed(http_error.describe(failure)))
  }
}

// Glue: http_gun speaks gleam/http requests over BitArray. ----------------

type Reply {
  Reply(status: Int, body: String)
}

fn call(
  shop: Shop,
  method: http.Method,
  path: String,
  body: String,
) -> Result(Reply, http_error.Failure) {
  let assert Ok(base) = request.to(shop.base_url <> path)
  let req =
    base
    |> request.set_method(method)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(bit_array.from_string(body))
  use http_gun.Buffered(response:, ..) <- result.map(http_gun.send(
    shop.client,
    req,
  ))
  Reply(
    response.status,
    bit_array.to_string(response.body) |> result.unwrap(""),
  )
}

fn status(reply: Reply) -> String {
  int.to_string(reply.status)
}
