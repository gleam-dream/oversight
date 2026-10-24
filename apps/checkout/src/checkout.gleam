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
import gleam/time/duration
import grind
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
  let assert Ok(application) = app.start(app.default_config(url))
  let assert Ok(#(_, port)) = web.start(application)
  // The demo's own customer client, separate from the app's provider client.
  let assert Ok(customer) = http_gun.start(gateway.customer_config())
  let pool = application.services.pool
  let assert Ok(Nil) = db.set_stock(pool, "kettle", 5)
  let base = "http://127.0.0.1:" <> int.to_string(port)
  io.println("Order API listening on " <> base <> "; kettle stock = 5")

  let order = fn(id, card, address) {
    OrderRequest(id, "kettle", 1, card, 4999, address, id <> "@example.test")
  }
  let _ =
    narrate(
      customer,
      base,
      order("ord-happy", providers.card_ok, "10 Main St"),
      "",
    )
  let _ =
    narrate(
      customer,
      base,
      order("ord-declined", providers.card_declined, "10 Main St"),
      "",
    )
  let _ =
    narrate(
      customer,
      base,
      order("ord-slow-ship", providers.card_ok, providers.address_slow),
      "",
    )
  let _ =
    narrate(
      customer,
      base,
      order("ord-lost-answer", providers.card_first_answer_lost, "10 Main St"),
      "",
    )
  let _ =
    narrate(
      customer,
      base,
      order("ord-black-hole", providers.card_black_hole, "10 Main St"),
      "",
    )
  let placed =
    narrate(
      customer,
      base,
      order("ord-durable", providers.card_ok, "10 Main St"),
      "?mode=durable",
    )
  let jobs = application.services.jobs
  let assert Ok(job_id) = json.parse(placed, decode.at(["job_id"], decode.int))
  let assert Ok(handle) = grind.bind(jobs, application.checkout_worker, job_id)
  let assert Ok(grind.Succeeded(summary)) =
    grind.await(jobs, handle, within: duration.seconds(10))
  io.println("  job " <> int.to_string(job_id) <> " -> " <> summary)
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
  http_gun.stop(customer)
  app.stop(application)
}

fn narrate(
  customer: http_gun.Client,
  base: String,
  order: OrderRequest,
  query: String,
) -> String {
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
    Ok(buffered) -> {
      let body =
        bit_array.to_string(buffered.response.body) |> result.unwrap("")
      io.println(
        "  -> " <> int.to_string(buffered.response.status) <> " " <> body,
      )
      body
    }
    Error(failure) -> {
      io.println("  -> " <> error.describe(failure))
      ""
    }
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
    Error(failure) -> io.println(error.describe(failure))
  }
}

pub fn orders_body(order: OrderRequest) -> String {
  json.to_string(codecs.encode_order(order))
}
