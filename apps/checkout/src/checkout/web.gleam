//// The order API on wisp + mist.
////
//// - `POST /orders` takes `{order_id, sku, quantity, payment_token, address,
////   email}`. The server prices it from the catalog; a body with any other
////   field (an amount, a card number) is refused with 422. The checkout
////   saga runs in the request and answers with the final status (201
////   confirmed, 402/409/502/504 rejected, 202 held).
//// - `POST /orders?mode=durable` enqueues the durable checkout job (202).
//// - `GET /orders/:id` reads the caller's own order; another customer's
////   order is a 404.
////
//// Every route needs `Authorization: Bearer <token>` for a configured
//// customer (401 otherwise). The `order_id` is the customer's idempotency
//// key: repeating a placement returns the existing order (200) without
//// running the saga again, and reusing the id for a different SKU or
//// quantity, or as another customer, is a 409.

import checkout/app.{type App}
import checkout/codecs
import checkout/customers
import checkout/db
import checkout/domain.{type CheckoutError}
import checkout/orders.{type Report}
import envoy
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun/error
import mist
import wisp
import wisp/wisp_mist

/// The environment variable holding wisp's signing secret.
pub const secret_key_base_variable = "CHECKOUT_SECRET_KEY_BASE"

/// Wisp signs cookies and messages with this secret and requires at least
/// 64 characters. A configured value shorter than that is refused; an unset
/// one is replaced by a random per-boot secret, so anything signed does not
/// survive a restart.
pub fn secret_key_base(
  configured: Result(String, Nil),
) -> Result(String, String) {
  case configured {
    Ok(secret) ->
      case string.byte_size(secret) >= 64 {
        True -> Ok(secret)
        False ->
          Error(secret_key_base_variable <> " must be at least 64 characters")
      }
    Error(Nil) -> {
      wisp.log_warning(
        secret_key_base_variable
        <> " is unset; using a random secret, so signed values will not survive a restart",
      )
      Ok(wisp.random_string(64))
    }
  }
}

pub fn start(app: App) -> Result(#(Pid, Int), String) {
  use secret <- result.try(secret_key_base(envoy.get(secret_key_base_variable)))
  let port = process.new_subject()
  wisp_mist.handler(handle(_, app), secret)
  |> mist.new
  |> mist.bind("127.0.0.1")
  |> mist.port(0)
  |> mist.after_start(fn(bound, _, _) { process.send(port, bound) })
  |> mist.start
  |> result.map_error(string.inspect)
  |> result.map(fn(started) {
    let assert Ok(bound) = process.receive(port, 1000)
    #(started.pid, bound)
  })
}

pub fn handle(req: wisp.Request, app: App) -> wisp.Response {
  use <- wisp.rescue_crashes
  use customer_id <- require_customer(req, app)
  case req.method, wisp.path_segments(req) {
    Post, ["orders"] -> place(req, app, customer_id)
    Get, ["orders", order_id] -> show(app, customer_id, order_id)
    _, _ -> wisp.not_found()
  }
}

/// Every route acts as one customer, resolved from the bearer token before
/// the body is read. No token, or one the table does not know, is a 401.
fn require_customer(
  req: wisp.Request,
  app: App,
  next: fn(String) -> wisp.Response,
) -> wisp.Response {
  case
    customers.authenticate(
      app.customers,
      request.get_header(req, "authorization"),
    )
  {
    Ok(customer_id) -> next(customer_id)
    Error(Nil) ->
      error_response(401, "unauthorized")
      |> wisp.set_header("www-authenticate", "Bearer")
  }
}

fn place(req: wisp.Request, app: App, customer_id: String) -> wisp.Response {
  use body <- wisp.require_json(req)
  case decode.run(body, codecs.checkout_request_decoder()) {
    Error(_) -> error_response(422, "invalid_order")
    Ok(request) ->
      case orders.price(app.services, customer_id, request) {
        Error(error) -> place_error(error)
        Ok(order) ->
          case list.key_find(wisp.get_query(req), "mode") {
            Ok("durable") ->
              case
                orders.place_durable(app.services, app.checkout_worker, order)
              {
                Ok(orders.Started(job_id)) ->
                  json.object([
                    #("order_id", json.string(order.order_id)),
                    #("status", json.string("pending")),
                    #("amount_cents", json.int(order.amount_cents)),
                    #("job_id", json.int(job_id)),
                  ])
                  |> json.to_string
                  |> wisp.json_response(202)
                Ok(orders.Existing(existing)) -> existing_order(existing)
                Error(error) -> place_error(error)
              }
            _ ->
              case orders.place_local(app.services, order) {
                Ok(orders.Started(report)) ->
                  report_json(order.order_id, report)
                  |> json.to_string
                  |> wisp.json_response(status_code(report))
                Ok(orders.Existing(existing)) -> existing_order(existing)
                Error(error) -> place_error(error)
              }
          }
      }
  }
}

fn place_error(error: orders.PlaceError) -> wisp.Response {
  case error {
    orders.UnknownSku(_) -> error_response(422, "unknown_sku")
    orders.OrderIdConflict -> error_response(409, "order_id_conflict")
    orders.StoreUnavailable -> error_response(503, "store_unavailable")
  }
}

fn show(app: App, customer_id: String, order_id: String) -> wisp.Response {
  case db.order_for(app.services.pool, customer_id, order_id) {
    Ok(Some(existing)) -> existing_order(existing)
    Ok(None) -> wisp.not_found()
    Error(error) -> {
      wisp.log_warning(
        "order " <> order_id <> ": order read failed: " <> string.inspect(error),
      )
      error_response(503, "store_unavailable")
    }
  }
}

/// The customer's own order as stored: the body of `GET /orders/:id` and
/// of a repeated placement.
fn existing_order(existing: db.OrderRecord) -> wisp.Response {
  json.object([
    #("order_id", json.string(existing.order_id)),
    #("status", json.string(domain.status_to_string(existing.status))),
    #("sku", json.string(existing.sku)),
    #("quantity", json.int(existing.quantity)),
    #("amount_cents", json.int(existing.amount_cents)),
    #("detail", json.string(existing.detail)),
  ])
  |> json.to_string
  |> wisp.json_response(200)
}

/// Bodies carry the order's status, a stable error code when there is one,
/// and the report's client-facing detail. Internal terms are logged by
/// `orders`, never rendered here.
fn report_json(order_id: String, report: Report) -> json.Json {
  let code = case report.status, report.error {
    _, Ok(error) -> [#("error", json.string(domain.error_code(error)))]
    domain.Rejected, Error(Nil) -> [#("error", json.string("checkout_failed"))]
    _, Error(Nil) -> []
  }
  json.object(
    [
      #("order_id", json.string(order_id)),
      #("status", json.string(domain.status_to_string(report.status))),
      ..code
    ]
    |> list.append([
      #("detail", json.string(report.detail)),
      #("undone", json.array(report.undone, json.string)),
      #("unknown_effects", json.int(report.unknown_effects)),
    ]),
  )
}

fn error_response(status: Int, code: String) -> wisp.Response {
  json.object([#("error", json.string(code))])
  |> json.to_string
  |> wisp.json_response(status)
}

/// The HTTP status follows the typed error, including http_gun's failure
/// kind: a provider timeout is a 504, any other transport failure a 502.
pub fn status_code(report: Report) -> Int {
  case report.status, report.error {
    domain.Confirmed, _ -> 201
    domain.NeedsReconciliation, _ | domain.Pending, _ -> 202
    domain.Rejected, Ok(error) -> error_status(error)
    domain.Rejected, Error(Nil) -> 500
  }
}

fn error_status(error: CheckoutError) -> Int {
  case error {
    domain.Declined(_) -> 402
    domain.OutOfStock(..) -> 409
    domain.ProviderUnreachable(failure:, ..) ->
      case error.kind(failure) {
        error.TimedOut -> 504
        _ -> 502
      }
    domain.ProviderRejected(..) -> 502
    domain.StockStoreFailed(_) | domain.Interrupted(_) -> 503
  }
}
