//// Payment and shipping API clients over one shared http_gun `Client`.
////
//// Every call takes the client view to use, so the caller can pass
//// `http_gun.with_correlation(client, order)` for per-order observation.
//// Transport failures stay typed: `ProviderUnreachable(provider, failure)`
//// keeps http_gun's `Failure`, including its `MaybeSent` evidence.

import checkout/domain.{
  type CheckoutError, type OrderRequest, type Provider, Declined, Payments,
  ProviderRejected, ProviderUnreachable, Shipping,
}
import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{type Method, Get, Post}
import gleam/http/request
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import gleam/uri
import http_gun
import http_gun/config
import http_gun/deadline
import http_gun/destination
import sinal/forwarder

pub type Gateway {
  Gateway(
    client: http_gun.Client,
    payments_url: String,
    shipping_url: String,
    payment_deadline: Duration,
    shipping_deadline: Duration,
  )
}

/// The provider client: loopback only, pinned to the providers' exact
/// `host:port` entries, so it cannot reach a public host or another local
/// port. Its lifecycle events go to the app's forwarder.
pub fn client_config(
  observations: forwarder.Forwarder,
  hosts: List(String),
) -> config.Config {
  config.default()
  |> config.with_request_timeout(config.After(duration.seconds(5)))
  |> config.with_destination(
    destination.loopback_only() |> destination.only_hosts(hosts),
  )
  |> config.with_observations(observations)
}

/// A local client that emits nothing (the demo's and tests' customer).
pub fn customer_config() -> config.Config {
  config.default()
  |> config.with_destination(destination.loopback_only())
  |> config.without_observations
}

/// The `host:port` of a provider base URL, for `client_config`.
pub fn authority(url: String) -> String {
  let assert Ok(parsed) = uri.parse(url)
  let assert Some(host) = parsed.host
  let assert Some(port) = parsed.port
  host <> ":" <> int.to_string(port)
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
    gateway.payment_deadline,
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
    gateway.payment_deadline,
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
    gateway.payment_deadline,
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
    gateway.shipping_deadline,
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
    gateway.shipping_deadline,
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
    gateway.shipping_deadline,
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
  limit: Duration,
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
  client
  |> http_gun.with_deadline(deadline.after(limit))
  |> http_gun.send(req)
  |> result.map(fn(buffered) {
    #(buffered.response.status, buffered.response.body)
  })
  |> result.map_error(ProviderUnreachable(provider, _))
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
