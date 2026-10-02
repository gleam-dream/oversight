//// Payment and shipping API clients over one shared http_gun `Client`.
////
//// Every call takes the client view to use, so the caller can pass
//// `http_gun.with_correlation(client, order)` for per-order observation.
//// Transport failures stay typed: `ProviderUnreachable(provider, failure)`
//// keeps http_gun's `Failure`, including its `MayHaveBeenSent` evidence.

import checkout/domain.{
  type CheckoutError, type OrderRequest, type Provider, Declined, Payments,
  ProviderRejected, ProviderUnreachable, Shipping,
}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{type Method, Get, Post}
import gleam/http/request
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import http_gun
import http_gun/config
import http_gun/deadline
import http_gun/destination
import http_gun/request_options
import sinal/forwarder

pub type Gateway {
  Gateway(
    client: http_gun.Client,
    payments_url: String,
    shipping_url: String,
    payment_deadline_ms: Int,
    shipping_deadline_ms: Int,
  )
}

/// http_gun's default destination policy refuses loopback; the scripted
/// providers live on 127.0.0.1, so the app must opt in, and pins the
/// allowlist to that one host while it is at it.
pub fn client_config(
  observations: Option(forwarder.Forwarder),
) -> config.Config {
  let defaults = config.default()
  config.Config(
    ..defaults,
    deadline_ms: 5000,
    observations:,
    destination: destination.Policy(
      ..defaults.destination,
      allow_public: False,
      allow_loopback: True,
      allowed_hosts: Some(["127.0.0.1"]),
    ),
  )
}

pub type ChargeLookup {
  ChargeFound(id: String, voided: Bool)
  NoCharge
}

pub type ShipmentLookup {
  ShipmentFound(id: String, cancelled: Bool)
  NoShipment
}

pub fn charge(
  gateway: Gateway,
  client: http_gun.Client,
  order: OrderRequest,
  key: String,
) -> Result(String, CheckoutError) {
  let body =
    json.object([
      #("card", json.string(order.card)),
      #("amount_cents", json.int(order.amount_cents)),
    ])
  use #(status, bytes) <- result.try(call(
    client,
    Payments,
    Post,
    gateway.payments_url <> "/charges",
    Some(key),
    Some(body),
    gateway.payment_deadline_ms,
  ))
  case status {
    200 -> decode_id(Payments, status, bytes)
    402 ->
      json.parse_bits(bytes, decode.at(["reason"], decode.string))
      |> result.unwrap("declined")
      |> Declined
      |> Error
    _ -> Error(ProviderRejected(Payments, status))
  }
}

pub fn void(
  gateway: Gateway,
  client: http_gun.Client,
  charge_id: String,
) -> Result(Nil, CheckoutError) {
  use #(status, _) <- result.try(call(
    client,
    Payments,
    Post,
    gateway.payments_url <> "/charges/" <> charge_id <> "/void",
    None,
    None,
    gateway.payment_deadline_ms,
  ))
  case status {
    200 -> Ok(Nil)
    _ -> Error(ProviderRejected(Payments, status))
  }
}

pub fn find_charge(
  gateway: Gateway,
  client: http_gun.Client,
  key: String,
) -> Result(ChargeLookup, CheckoutError) {
  use #(status, bytes) <- result.try(call(
    client,
    Payments,
    Get,
    gateway.payments_url <> "/charges/by-key/" <> key,
    None,
    None,
    gateway.payment_deadline_ms,
  ))
  case status {
    200 -> {
      use #(id, state) <- result.map(decode_record(Payments, status, bytes))
      ChargeFound(id, state == "voided")
    }
    404 -> Ok(NoCharge)
    _ -> Error(ProviderRejected(Payments, status))
  }
}

pub fn book(
  gateway: Gateway,
  client: http_gun.Client,
  order: OrderRequest,
  key: String,
) -> Result(String, CheckoutError) {
  let body = json.object([#("address", json.string(order.address))])
  use #(status, bytes) <- result.try(call(
    client,
    Shipping,
    Post,
    gateway.shipping_url <> "/shipments",
    Some(key),
    Some(body),
    gateway.shipping_deadline_ms,
  ))
  case status {
    201 -> decode_id(Shipping, status, bytes)
    _ -> Error(ProviderRejected(Shipping, status))
  }
}

pub fn cancel_shipment(
  gateway: Gateway,
  client: http_gun.Client,
  key: String,
) -> Result(Nil, CheckoutError) {
  use #(status, _) <- result.try(call(
    client,
    Shipping,
    Post,
    gateway.shipping_url <> "/shipments/by-key/" <> key <> "/cancel",
    None,
    None,
    gateway.shipping_deadline_ms,
  ))
  case status {
    200 | 404 -> Ok(Nil)
    _ -> Error(ProviderRejected(Shipping, status))
  }
}

pub fn find_shipment(
  gateway: Gateway,
  client: http_gun.Client,
  key: String,
) -> Result(ShipmentLookup, CheckoutError) {
  use #(status, bytes) <- result.try(call(
    client,
    Shipping,
    Get,
    gateway.shipping_url <> "/shipments/by-key/" <> key,
    None,
    None,
    gateway.shipping_deadline_ms,
  ))
  case status {
    200 -> {
      use #(id, state) <- result.map(decode_record(Shipping, status, bytes))
      ShipmentFound(id, state == "cancelled")
    }
    404 -> Ok(NoShipment)
    _ -> Error(ProviderRejected(Shipping, status))
  }
}

fn call(
  client: http_gun.Client,
  provider: Provider,
  method: Method,
  url: String,
  idempotency_key: Option(String),
  body: Option(json.Json),
  deadline_ms: Int,
) -> Result(#(Int, BitArray), CheckoutError) {
  let assert Ok(base) = request.to(url)
  let req =
    base
    |> request.set_method(method)
    |> request.set_body(case body {
      Some(json) -> bit_array.from_string(json.to_string(json))
      None -> <<>>
    })
    |> request.set_header("content-type", "application/json")
  let req = case idempotency_key {
    Some(key) -> request.set_header(req, "idempotency-key", key)
    None -> req
  }
  let unreachable = fn(failure) { ProviderUnreachable(provider, failure) }
  use budget <- result.try(
    deadline.after(deadline_ms) |> result.map_error(unreachable),
  )
  let options =
    request_options.Options(..request_options.default(), deadline: Some(budget))
  http_gun.send_with_options(client, req, options)
  |> result.map(fn(buffered) {
    #(buffered.response.status, buffered.response.body)
  })
  |> result.map_error(unreachable)
}

fn decode_id(
  provider: Provider,
  status: Int,
  bytes: BitArray,
) -> Result(String, CheckoutError) {
  decode_record(provider, status, bytes) |> result.map(fn(pair) { pair.0 })
}

fn decode_record(
  provider: Provider,
  status: Int,
  bytes: BitArray,
) -> Result(#(String, String), CheckoutError) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use state <- decode.field("status", decode.string)
    decode.success(#(id, state))
  }
  json.parse_bits(bytes, decoder)
  |> result.replace_error(ProviderRejected(provider, status))
}
