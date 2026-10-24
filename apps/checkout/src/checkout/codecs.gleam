//// JSON codecs for the domain, and the bridge from one JSON encoder/decoder
//// pair to both packages' codec types: grind's `worker.Codec` and saga's
//// `codec.Codec`. Both are built from gleam_json, so each bridge is one
//// expression. A step error carries http_gun's `Failure`, which persists
//// through `error.to_json` and `error.decoder`.

import checkout/domain.{
  type Booked, type Charged, type CheckoutError, type OrderRequest,
  type Provider, type Reserved, type UndoError, Booked, Charged, Declined,
  Interrupted, OrderRequest, OutOfStock, Payments, ProviderRejected,
  ProviderUnreachable, Reserved, Shipping, StockStoreFailed, UndoError,
}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
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

// --- domain values --------------------------------------------------------

pub fn order() -> JsonCodec(OrderRequest) {
  JsonCodec("order-1", encode_order, order_decoder())
}

pub fn encode_order(o: OrderRequest) -> Json {
  json.object([
    #("order_id", json.string(o.order_id)),
    #("sku", json.string(o.sku)),
    #("quantity", json.int(o.quantity)),
    #("card", json.string(o.card)),
    #("amount_cents", json.int(o.amount_cents)),
    #("address", json.string(o.address)),
    #("email", json.string(o.email)),
  ])
}

pub fn order_decoder() -> Decoder(OrderRequest) {
  use order_id <- decode.field("order_id", decode.string)
  use sku <- decode.field("sku", decode.string)
  use quantity <- decode.field("quantity", decode.int)
  use card <- decode.field("card", decode.string)
  use amount_cents <- decode.field("amount_cents", decode.int)
  use address <- decode.field("address", decode.string)
  use email <- decode.field("email", decode.string)
  decode.success(OrderRequest(
    order_id:,
    sku:,
    quantity:,
    card:,
    amount_cents:,
    address:,
    email:,
  ))
}

pub fn reserved() -> JsonCodec(Reserved) {
  JsonCodec("reserved-1", encode_reserved, reserved_decoder())
}

fn encode_reserved(r: Reserved) -> Json {
  json.object([#("order", encode_order(r.order))])
}

fn reserved_decoder() -> Decoder(Reserved) {
  use order <- decode.field("order", order_decoder())
  decode.success(Reserved(order))
}

pub fn charged() -> JsonCodec(Charged) {
  JsonCodec("charged-1", encode_charged, charged_decoder())
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
  JsonCodec("booked-1", encode_booked, booked_decoder())
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
