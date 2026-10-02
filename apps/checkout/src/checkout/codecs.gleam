//// JSON codecs for the domain, and the bridge from one JSON encoder/decoder
//// pair to both packages' codec types: grind's `worker.Codec` (gleam_json
//// plus a decoder) and saga's `codec.Codec` (String in, String out).
////
//// Composition glue: saga and grind each own a codec type, and http_gun's
//// `error.Failure` has no serialised form at all, so persisting a step error
//// that carries it needs the hand-written `failure` codec below.

import checkout/domain.{
  type Booked, type Charged, type CheckoutError, type OrderRequest,
  type Provider, type Reserved, type UndoError, Booked, Charged, Declined,
  Interrupted, OrderRequest, OutOfStock, Payments, ProviderRejected,
  ProviderUnreachable, Reserved, Shipping, StockStoreFailed, UndoError,
}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import grind/worker
import http_gun/error
import saga/codec

// --- bridge ---------------------------------------------------------------

/// One JSON definition, two package codecs.
pub type JsonCodec(a) {
  JsonCodec(version: String, encode: fn(a) -> Json, decoder: Decoder(a))
}

pub fn to_grind(c: JsonCodec(a)) -> worker.Codec(a) {
  let assert Ok(grind_codec) = worker.codec(c.version, c.encode, c.decoder)
  grind_codec
}

pub fn to_saga(c: JsonCodec(a)) -> codec.Codec(a) {
  codec.new(
    c.version,
    fn(value) { Ok(json.to_string(c.encode(value))) },
    fn(text) {
      json.parse(text, c.decoder)
      |> result.map_error(fn(e) { string.inspect(e) })
    },
  )
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
        #("failure", encode_failure(failure)),
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
      use failure <- decode.field("failure", failure_decoder())
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

// --- http_gun failure (no serialised form upstream) -------------------------

fn encode_failure(f: error.Failure) -> Json {
  let #(tag, detail) = case f.reason {
    error.InvalidConfig(text) -> #("invalid_config", json.string(text))
    error.InvalidRequest(text) -> #("invalid_request", json.string(text))
    error.ConnectionFailed(cause) -> #(
      "connection_failed",
      json.string(name_of(transport_causes(), cause)),
    )
    error.RequestFailed(cause) -> #(
      "request_failed",
      json.string(name_of(transport_causes(), cause)),
    )
    error.LimitExceeded(kind, limit, observed) -> #(
      "limit_exceeded",
      json.array(
        [
          json.string(name_of(limit_kinds(), kind)),
          json.int(limit),
          json.int(observed),
        ],
        fn(x) { x },
      ),
    )
    error.FixtureVersion(n) -> #("fixture_version", json.int(n))
    error.FixtureMismatch(n) -> #("fixture_mismatch", json.int(n))
    error.CaptureFailed(text) -> #("capture_failed", json.string(text))
    // File-level fixture detail is dropped: lossy on purpose.
    error.FixtureIo(_, _) -> #("fixture_io", json.null())
    plain -> #(name_of(plain_reasons(), plain), json.null())
  }
  json.object([
    #("reason", json.string(tag)),
    #("detail", detail),
    #("may_have_been_sent", json.bool(f.evidence == error.MayHaveBeenSent)),
  ])
}

fn failure_decoder() -> Decoder(error.Failure) {
  use tag <- decode.field("reason", decode.string)
  use sent <- decode.field("may_have_been_sent", decode.bool)
  let evidence = case sent {
    True -> error.MayHaveBeenSent
    False -> error.NotSubmitted
  }
  let text = decode.at(["detail"], decode.string)
  let int = decode.at(["detail"], decode.int)
  let cause =
    decode.at(["detail"], decode.string)
    |> decode.map(fn(name) {
      value_of(transport_causes(), name, error.UnknownTransport)
    })
  let reason = case tag {
    "invalid_config" -> decode.map(text, error.InvalidConfig)
    "invalid_request" -> decode.map(text, error.InvalidRequest)
    "connection_failed" -> decode.map(cause, error.ConnectionFailed)
    "request_failed" -> decode.map(cause, error.RequestFailed)
    "limit_exceeded" ->
      decode.at(["detail"], {
        use kind <- decode.field(0, decode.string)
        use limit <- decode.field(1, decode.int)
        use observed <- decode.field(2, decode.int)
        decode.success(error.LimitExceeded(
          value_of(limit_kinds(), kind, error.CollectedBodyBytes),
          limit,
          observed,
        ))
      })
    "fixture_version" -> decode.map(int, error.FixtureVersion)
    "fixture_mismatch" -> decode.map(int, error.FixtureMismatch)
    "capture_failed" -> decode.map(text, error.CaptureFailed)
    "fixture_io" ->
      decode.success(error.FixtureIo(error.ReadFile, error.UnknownIoFailure))
    other -> decode.success(value_of(plain_reasons(), other, error.Closed))
  }
  decode.map(reason, fn(reason) { error.Failure(reason, evidence) })
}

fn plain_reasons() -> List(#(String, error.Reason)) {
  [
    #("client_closed", error.ClientClosed),
    #("admission_full", error.AdmissionFull),
    #("destination_rejected", error.DestinationRejected),
    #("resolution_failed", error.ResolutionFailed),
    #("deadline_exceeded", error.DeadlineExceeded),
    #("read_timeout", error.ReadTimeout),
    #("read_conflict", error.ReadConflict),
    #("wrong_owner", error.WrongOwner),
    #("closed", error.Closed),
    #("cancelled", error.Cancelled),
    #("fixture_missing", error.FixtureMissing),
    #("fixture_corrupt", error.FixtureCorrupt),
    #("fixture_exhausted", error.FixtureExhausted),
  ]
}

fn transport_causes() -> List(#(String, error.TransportCause)) {
  [
    #("name_resolution_failed", error.NameResolutionFailed),
    #("connection_refused", error.ConnectionRefused),
    #("certificate_rejected", error.CertificateRejected),
    #("tls_failed", error.TlsFailed),
    #("connection_reset", error.ConnectionReset),
    #("peer_closed", error.PeerClosed),
    #("peer_draining", error.PeerDraining),
    #("protocol_error", error.ProtocolError),
    #("header_limit_reached", error.HeaderLimitReached),
    #("transport_timeout", error.TransportTimeout),
    #("unexpected_protocol", error.UnexpectedProtocol),
    #("unknown_transport", error.UnknownTransport),
  ]
}

fn limit_kinds() -> List(#(String, error.LimitKind)) {
  [
    #("request_body_bytes", error.RequestBodyBytes),
    #("request_header_bytes", error.RequestHeaderBytes),
    #("request_header_count", error.RequestHeaderCount),
    #("response_header_bytes", error.ResponseHeaderBytes),
    #("response_header_count", error.ResponseHeaderCount),
    #("response_chunk_bytes", error.ResponseChunkBytes),
    #("response_queue_bytes", error.ResponseQueueBytes),
    #("collected_body_bytes", error.CollectedBodyBytes),
    #("fixture_bytes", error.FixtureBytes),
  ]
}

fn name_of(table: List(#(String, a)), value: a) -> String {
  case list.find(table, fn(pair) { pair.1 == value }) {
    Ok(#(name, _)) -> name
    Error(Nil) -> "unknown"
  }
}

fn value_of(table: List(#(String, a)), name: String, fallback: a) -> a {
  list.key_find(table, name) |> result.unwrap(fallback)
}
