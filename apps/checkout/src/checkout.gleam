//// `gleam run` (with DATABASE_URL set, e.g. via ../scripts/with-postgres.sh):
//// starts the order API against scripted providers and narrates a handful
//// of orders, including failures, a durable run, and their telemetry.

import checkout/app
import checkout/codecs
import checkout/db
import checkout/domain.{type OrderRequest, OrderRequest}
import checkout/gateway
import checkout/providers
import checkout/telemetry
import checkout/web
import envoy
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun
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
  let assert Ok(application) = app.start(app.default_config(url))
  let assert Ok(#(_, port)) = web.start(application)
  // The demo's own customer client, separate from the app's provider client.
  let assert Ok(customer) = http_gun.start(gateway.client_config(None))
  let pool = application.services.pool
  let assert Ok(Nil) = db.set_stock(pool, "kettle", 5)
  let base = "http://127.0.0.1:" <> int.to_string(port)
  io.println("Order API listening on " <> base <> "; kettle stock = 5")

  let order = fn(id, card, address) {
    OrderRequest(id, "kettle", 1, card, 4999, address, id <> "@example.test")
  }
  narrate(
    customer,
    base,
    order("ord-happy", providers.card_ok, "10 Main St"),
    "",
  )
  narrate(
    customer,
    base,
    order("ord-declined", providers.card_declined, "10 Main St"),
    "",
  )
  narrate(
    customer,
    base,
    order("ord-slow-ship", providers.card_ok, providers.address_slow),
    "",
  )
  narrate(
    customer,
    base,
    order("ord-lost-answer", providers.card_first_answer_lost, "10 Main St"),
    "",
  )
  narrate(
    customer,
    base,
    order("ord-black-hole", providers.card_black_hole, "10 Main St"),
    "",
  )
  narrate(
    customer,
    base,
    order("ord-durable", providers.card_ok, "10 Main St"),
    "?mode=durable",
  )
  wait_for_status(application, "ord-durable", 50)
  show(customer, base, "ord-durable")
  process.sleep(300)

  let assert Ok(stock) = db.stock_level(pool, "kettle")
  io.println("\nkettle stock now " <> int.to_string(stock))
  list.each(["ord-happy", "ord-durable"], fn(id) {
    io.println(
      "receipt for "
      <> id
      <> " sent: "
      <> string.inspect(db.receipt_sent(pool, id)),
    )
  })

  io.println("\nTelemetry for ord-happy (saga + http_gun + grind):")
  telemetry.trace(application.services.collector, telemetry.order("ord-happy"))
  |> list.each(fn(e) { io.println("  " <> telemetry.render(e)) })
  io.println("\nTelemetry for ord-durable:")
  telemetry.trace(
    application.services.collector,
    telemetry.order("ord-durable"),
  )
  |> list.each(fn(e) { io.println("  " <> telemetry.render(e)) })
  let stray = telemetry.unattributed(application.services.collector)
  io.println("\nUnattributed events: " <> int.to_string(list.length(stray)))
  let _ = http_gun.stop(customer)
  app.stop(application)
}

fn narrate(
  customer: http_gun.Client,
  base: String,
  order: OrderRequest,
  query: String,
) -> Nil {
  let body =
    orders_body(order)
    |> bit_array.from_string
  let assert Ok(req) = request.to(base <> "/orders" <> query)
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(body)
  io.println("\nPOST /orders" <> query <> "  " <> order.order_id)
  case http_gun.send(customer, req) {
    Ok(buffered) ->
      io.println(
        "  -> "
        <> int.to_string(buffered.response.status)
        <> " "
        <> bit_array.to_string(buffered.response.body) |> result.unwrap(""),
      )
    Error(failure) -> io.println("  -> " <> string.inspect(failure))
  }
}

fn show(customer: http_gun.Client, base: String, id: String) -> Nil {
  let assert Ok(req) = request.to(base <> "/orders/" <> id)
  let req = request.set_body(req, <<>>)
  case http_gun.send(customer, req) {
    Ok(buffered) ->
      io.println(
        "GET /orders/"
        <> id
        <> " -> "
        <> bit_array.to_string(buffered.response.body) |> result.unwrap(""),
      )
    Error(failure) -> io.println(string.inspect(failure))
  }
}

fn wait_for_status(application: app.App, id: String, tries: Int) -> Nil {
  let pending = case db.order_status(application.services.pool, id) {
    Some(#(domain.Pending, _)) | None -> True
    Some(_) -> False
  }
  case pending && tries > 0 {
    True -> {
      process.sleep(100)
      wait_for_status(application, id, tries - 1)
    }
    False -> Nil
  }
}

pub fn orders_body(order: OrderRequest) -> String {
  json.to_string(codecs.encode_order(order))
}
