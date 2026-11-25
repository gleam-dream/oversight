//// `gleam run` (with DATABASE_URL set, e.g. via ../scripts/with-postgres.sh):
//// starts the order API against scripted providers and narrates a handful
//// of orders, including failures, a durable run, and their telemetry.

import checkout/app
import checkout/codecs
import checkout/customers
import checkout/db
import checkout/domain.{type CheckoutRequest, CheckoutRequest}
import checkout/gateway
import checkout/providers
import checkout/telemetry
import envoy
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import http_gun
import http_gun/error
import wisp

pub fn main() -> Nil {
  case envoy.get("DATABASE_URL") {
    Error(Nil) ->
      io.println(
        "DATABASE_URL is not set; run with ../scripts/with-postgres.sh gleam run",
      )
    Ok(url) -> demo(url)
  }
}

fn demo(url: String) -> Nil {
  wisp.set_logger_level(wisp.ErrorLevel)
  // Two demo customers, each with a bearer token minted for this run.
  let shopper = wisp.random_string(32)
  let someone_else = wisp.random_string(32)
  let config =
    app.Config(
      ..app.default_config(url),
      customers: customers.from_list([
        #(shopper, "shopper"),
        #(someone_else, "someone-else"),
      ]),
    )
  let assert Ok(application) = app.start(config)
  let assert Ok(port) = app.port(application)
  // The demo's own customer client, separate from the app's provider client.
  let assert Ok(customer) = http_gun.start(gateway.customer_config())
  let pool = application.services.pool
  let assert Ok(Nil) =
    db.set_product(pool, "kettle", unit_price_cents: 4999, available: 5)
  let base = "http://127.0.0.1:" <> int.to_string(port)
  io.println(
    "Order API listening on " <> base <> "; kettle at 4999 cents, stock = 5",
  )

  // The customer tokenises each card with the payment provider; the order
  // carries only the token and no price.
  let payments_url = providers.payments_url(application.providers)
  let order = fn(id, card, address) {
    let assert Ok(token) = tokenise(customer, payments_url, card)
    CheckoutRequest(id, "kettle", 1, token, address, id <> "@example.test")
  }
  let _ =
    narrate(
      customer,
      shopper,
      base,
      order("ord-happy", providers.card_ok, "10 Main St"),
    )
  let _ =
    narrate(
      customer,
      shopper,
      base,
      order("ord-declined", providers.card_declined, "10 Main St"),
    )
  let _ =
    narrate(
      customer,
      shopper,
      base,
      order("ord-slow-ship", providers.card_ok, providers.address_slow),
    )
  let _ =
    narrate(
      customer,
      shopper,
      base,
      order("ord-lost-answer", providers.card_first_answer_lost, "10 Main St"),
    )
  let _ =
    narrate(
      customer,
      shopper,
      base,
      order("ord-black-hole", providers.card_black_hole, "10 Main St"),
    )
  let _ =
    narrate(
      customer,
      shopper,
      base,
      order("ord-durable", providers.card_ok, "10 Main St"),
    )

  // The order id is the shopper's own idempotency key: repeating the
  // placement returns the order without charging again. Another customer
  // using the same id places a separate order of their own, so the answer
  // says nothing about the shopper's order, which they cannot read.
  let _ =
    narrate(
      customer,
      shopper,
      base,
      order("ord-happy", providers.card_ok, "10 Main St"),
    )
  let _ =
    narrate(
      customer,
      someone_else,
      base,
      order("ord-happy", providers.card_ok, "10 Main St"),
    )
  show(customer, someone_else, base, "ord-happy")

  let assert Ok(stock) = db.stock_level(pool, "kettle")
  io.println("\nkettle stock now " <> int.to_string(stock))
  list.each(["ord-happy", "ord-durable"], fn(id) {
    io.println(
      "receipt for "
      <> id
      <> " sent: "
      <> string.inspect(db.receipt_sent(pool, "shopper", id)),
    )
  })

  io.println("\nTelemetry for ord-happy (saga + http_gun + grind):")
  telemetry.trace(
    application.services.collector,
    telemetry.order(domain.order_key("shopper", "ord-happy")),
  )
  |> list.each(fn(e) { io.println("  " <> telemetry.render(e)) })
  io.println("\nTelemetry for ord-durable:")
  telemetry.trace(
    application.services.collector,
    telemetry.order(domain.order_key("shopper", "ord-durable")),
  )
  |> list.each(fn(e) { io.println("  " <> telemetry.render(e)) })
  let stray = telemetry.unattributed(application.services.collector)
  io.println("\nUnattributed events: " <> int.to_string(list.length(stray)))
  http_gun.stop(customer)
  app.stop(application)
}

/// Places an order and, when the API admitted it, waits until its checkout
/// job has recorded an outcome and prints the order.
fn narrate(
  customer: http_gun.Client,
  bearer: String,
  base: String,
  order: CheckoutRequest,
) -> String {
  let body =
    orders_body(order)
    |> bit_array.from_string
  let assert Ok(req) = request.to(base <> "/orders")
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("authorization", "Bearer " <> bearer)
    |> request.set_body(body)
  io.println("\nPOST /orders  " <> order.order_id)
  case http_gun.send(customer, req) {
    Ok(buffered) -> {
      let body =
        bit_array.to_string(buffered.response.body) |> result.unwrap("")
      io.println(
        "  -> " <> int.to_string(buffered.response.status) <> " " <> body,
      )
      case buffered.response.status {
        202 -> {
          await_outcome(customer, bearer, base, order.order_id, 200)
          show(customer, bearer, base, order.order_id)
        }
        _ -> Nil
      }
      body
    }
    Error(failure) -> {
      io.println("  -> " <> error.describe(failure))
      ""
    }
  }
}

/// Waits, `tries` times 50 ms at most, until the order is no longer
/// pending.
fn await_outcome(
  customer: http_gun.Client,
  bearer: String,
  base: String,
  id: String,
  tries: Int,
) -> Nil {
  let assert Ok(req) = request.to(base <> "/orders/" <> id)
  let req =
    req
    |> request.set_header("authorization", "Bearer " <> bearer)
    |> request.set_body(<<>>)
  let status =
    http_gun.send(customer, req)
    |> result.replace_error(Nil)
    |> result.try(fn(buffered) {
      json.parse_bits(
        buffered.response.body,
        decode.at(["status"], decode.string),
      )
      |> result.replace_error(Nil)
    })
  case status, tries {
    Ok("pending"), n if n > 0 -> {
      process.sleep(50)
      await_outcome(customer, bearer, base, id, n - 1)
    }
    _, _ -> Nil
  }
}

fn show(
  customer: http_gun.Client,
  bearer: String,
  base: String,
  id: String,
) -> Nil {
  let assert Ok(req) = request.to(base <> "/orders/" <> id)
  let req =
    req
    |> request.set_header("authorization", "Bearer " <> bearer)
    |> request.set_body(<<>>)
  case http_gun.send(customer, req) {
    Ok(buffered) ->
      io.println(
        "GET /orders/"
        <> id
        <> " -> "
        <> int.to_string(buffered.response.status)
        <> " "
        <> bit_array.to_string(buffered.response.body) |> result.unwrap(""),
      )
    Error(failure) -> io.println(error.describe(failure))
  }
}

pub fn orders_body(order: CheckoutRequest) -> String {
  json.to_string(codecs.encode_checkout_request(order))
}

/// Exchanges a card number for an opaque payment token at the payment
/// provider, as the customer's browser would. The order API accepts only
/// the token, so the card number never reaches it.
pub fn tokenise(
  customer: http_gun.Client,
  payments_url: String,
  card: String,
) -> Result(String, Nil) {
  let assert Ok(req) = request.to(payments_url <> "/tokens")
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(
      json.object([#("card", json.string(card))])
      |> json.to_string
      |> bit_array.from_string,
    )
  case http_gun.send(customer, req) {
    Ok(buffered) if buffered.response.status == 201 ->
      json.parse_bits(
        buffered.response.body,
        decode.at(["token"], decode.string),
      )
      |> result.replace_error(Nil)
    _ -> Error(Nil)
  }
}
