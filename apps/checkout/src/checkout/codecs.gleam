//// JSON codecs for the domain, and the bridge from one JSON encoder/decoder
//// pair to both packages' codec types: grind's `worker.Codec` and saga's
//// `codec.Codec`. Both are built from gleam_json, so each bridge is one
//// expression. A step error carries http_gun's `Failure`, which persists
//// through `error.to_json` and `error.decoder`.

import checkout/domain.{
  type Booked, type Charged, type CheckoutError, type CheckoutRequest,
  type Order, type Provider, type Reserved, type UndoError, Booked, Charged,
  CheckoutRequest, Declined, Interrupted, Order, OutOfStock, Payments,
  ProviderRejected, ProviderUnreachable, Reserved, Shipping, StockStoreFailed,
  UndoError,
}
import gleam/dict
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import grind/worker
import http_gun/error
import saga/codec

// --- bridge ---------------------------------------------------------------

/// One JSON definition, two package codecs.
pub type JsonCodec(a) {
  JsonCodec(version: String, encode: fn(a) -> Json, decoder: Decoder(a))
}

pub fn to_grind(c: JsonCodec(a)) -> worker.Codec(a) {
  worker.codec(worker.infallible(c.encode), c.decoder)
  |> worker.with_codec_version(c.version)
}

pub fn to_saga(c: JsonCodec(a)) -> codec.Codec(a) {
  codec.json(c.version, fn(value) { Ok(c.encode(value)) }, c.decoder)
}

// --- the request body -------------------------------------------------------

const request_fields = [
  "order_id", "sku", "quantity", "payment_token", "address", "email",
]

/// The `POST /orders` body. Strict: a field outside the request shape, such
/// as a client-chosen `amount_cents` or a raw `card`, fails the decode
/// instead of being ignored, so a client cannot believe it set a price.
pub fn checkout_request_decoder() -> Decoder(CheckoutRequest) {
  use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
  case
    list.filter(dict.keys(fields), fn(f) { !list.contains(request_fields, f) })
  {
    [] -> {
      use order_id <- decode.field("order_id", decode.string)
      use sku <- decode.field("sku", decode.string)
      use quantity <- decode.field("quantity", quantity_decoder())
      use payment_token <- decode.field("payment_token", decode.string)
      use address <- decode.field("address", decode.string)
      use email <- decode.field("email", decode.string)
      decode.success(CheckoutRequest(
        order_id:,
        sku:,
        quantity:,
        payment_token:,
        address:,
        email:,
      ))
    }
    _unknown -> decode.failure(placeholder_request(), "CheckoutRequest")
  }
}

fn quantity_decoder() -> Decoder(Int) {
  use quantity <- decode.then(decode.int)
  case quantity >= 1 && quantity <= domain.max_quantity {
    True -> decode.success(quantity)
    False -> decode.failure(0, "quantity from 1 to max_quantity")
  }
}

fn placeholder_request() -> CheckoutRequest {
  CheckoutRequest("", "", 0, "", "", "")
}

/// The body a client sends; the demo and the tests use it.
pub fn encode_checkout_request(r: CheckoutRequest) -> Json {
  json.object([
    #("order_id", json.string(r.order_id)),
    #("sku", json.string(r.sku)),
    #("quantity", json.int(r.quantity)),
    #("payment_token", json.string(r.payment_token)),
    #("address", json.string(r.address)),
    #("email", json.string(r.email)),
  ])
}

// --- domain values --------------------------------------------------------

/// The priced order as grind's job input and saga's durable input. It holds
/// the payment token, never a card number.
pub fn order() -> JsonCodec(Order) {
  JsonCodec("order-2", encode_order, order_decoder())
}

pub fn encode_order(o: Order) -> Json {
  json.object([
    #("order_id", json.string(o.order_id)),
    #("sku", json.string(o.sku)),
    #("quantity", json.int(o.quantity)),
    #("amount_cents", json.int(o.amount_cents)),
    #("payment_token", json.string(o.payment_token)),
    #("address", json.string(o.address)),
    #("email", json.string(o.email)),
  ])
}

pub fn order_decoder() -> Decoder(Order) {
  use order_id <- decode.field("order_id", decode.string)
  use sku <- decode.field("sku", decode.string)
  use quantity <- decode.field("quantity", decode.int)
  use amount_cents <- decode.field("amount_cents", decode.int)
  use payment_token <- decode.field("payment_token", decode.string)
  use address <- decode.field("address", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(Order(
    order_id:,
    sku:,
    quantity:,
    amount_cents:,
    payment_token:,
    address:,
    email:,
  ))
}

pub fn reserved() -> JsonCodec(Reserved) {
  JsonCodec("reserved-2", encode_reserved, reserved_decoder())
}

fn encode_reserved(r: Reserved) -> Json {
  json.object([#("order", encode_order(r.order))])
}

fn reserved_decoder() -> Decoder(Reserved) {
  use order <- decode.field("order", order_decoder())
  decode.success(Reserved(order))
}

pub fn charged() -> JsonCodec(Charged) {
  JsonCodec("charged-2", encode_charged, charged_decoder())
}

fn encode_charged(c: Charged) -> Json {
  json.object([
    #("reserved", encode_reserved(c.reserved)),
    #("charge_id", json.string(c.charge_id)),
  ])
}

fn charged_decoder() -> Decoder(Charged) {
  use reserved <- decode.field("reserved", reserved_decoder())
  use charge_id <- decode.field("charge_id", decode.string)
  decode.success(Charged(reserved, charge_id))
}

pub fn booked() -> JsonCodec(Booked) {
  JsonCodec("booked-2", encode_booked, booked_decoder())
}

fn encode_booked(b: Booked) -> Json {
  json.object([
    #("charged", encode_charged(b.charged)),
    #("shipment_id", json.string(b.shipment_id)),
  ])
}

fn booked_decoder() -> Decoder(Booked) {
  use charged <- decode.field("charged", charged_decoder())
  use shipment_id <- decode.field("shipment_id", decode.string)
  decode.success(Booked(charged, shipment_id))
}

// --- errors ---------------------------------------------------------------

pub fn checkout_error() -> JsonCodec(CheckoutError) {
  JsonCodec("checkout-error-1", encode_error, error_decoder())
}

pub fn undo_error() -> JsonCodec(UndoError) {
  JsonCodec(
    "undo-error-1",
    fn(u: UndoError) {
      json.object([
        #("step", json.string(u.step)),
        #("cause", encode_error(u.cause)),
      ])
    },
    {
      use step <- decode.field("step", decode.string)
      use cause <- decode.field("cause", error_decoder())
      decode.success(UndoError(step, cause))
    },
  )
}

fn encode_error(e: CheckoutError) -> Json {
  case e {
    OutOfStock(sku, requested) ->
      json.object([
        #("kind", json.string("out_of_stock")),
        #("sku", json.string(sku)),
        #("requested", json.int(requested)),
      ])
    StockStoreFailed(detail) ->
      json.object([
        #("kind", json.string("stock_store")),
        #("detail", json.string(detail)),
      ])
    Declined(reason) ->
      json.object([
        #("kind", json.string("declined")),
        #("reason", json.string(reason)),
      ])
    ProviderRejected(provider, status) ->
      json.object([
        #("kind", json.string("rejected")),
        #("provider", encode_provider(provider)),
        #("status", json.int(status)),
      ])
    ProviderUnreachable(provider, failure) ->
      json.object([
        #("kind", json.string("unreachable")),
        #("provider", encode_provider(provider)),
        #("failure", error.to_json(failure)),
      ])
    Interrupted(step) ->
      json.object([
        #("kind", json.string("interrupted")),
        #("step", json.string(step)),
      ])
  }
}

fn error_decoder() -> Decoder(CheckoutError) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "out_of_stock" -> {
      use sku <- decode.field("sku", decode.string)
      use requested <- decode.field("requested", decode.int)
      decode.success(OutOfStock(sku, requested))
    }
    "stock_store" -> {
      use detail <- decode.field("detail", decode.string)
      decode.success(StockStoreFailed(detail))
    }
    "declined" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(Declined(reason))
    }
    "rejected" -> {
      use provider <- decode.field("provider", provider_decoder())
      use status <- decode.field("status", decode.int)
      decode.success(ProviderRejected(provider, status))
    }
    "interrupted" ->
      decode.field("step", decode.string, decode.success)
      |> decode.map(Interrupted)
    _ -> {
      use provider <- decode.field("provider", provider_decoder())
      use failure <- decode.field("failure", error.decoder())
      decode.success(ProviderUnreachable(provider, failure))
    }
  }
}

fn encode_provider(p: Provider) -> Json {
  json.string(domain.provider_name(p))
}

fn provider_decoder() -> Decoder(Provider) {
  use name <- decode.then(decode.string)
  case name {
    "payments" -> decode.success(Payments)
    _ -> decode.success(Shipping)
  }
}
