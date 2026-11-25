//// The order API on wisp + mist.
////
//// - `POST /orders` takes `{order_id, sku, quantity, payment_token, address,
////   email}`. The server prices it from the catalog; a body with any other
////   field (an amount, a card number) is refused with 422. It records the
////   pending order and enqueues its checkout job in one transaction and
////   answers 202 with the job id; `GET /orders/:id` shows the outcome once
////   the job has recorded it.
//// - `GET /orders/:id` reads the caller's own order; another customer's
////   order is a 404.
////
//// Every route needs `Authorization: Bearer <token>` for a configured
//// customer (401 otherwise). The `order_id` is the customer's own
//// idempotency key: repeating a placement returns the existing order (200)
//// without running the saga again, and reusing the id for a different SKU
//// or quantity is a 409. Order ids are scoped to the customer, so another
//// customer placing under the same id creates their own order.

import checkout/codecs
import checkout/customers.{type Customers}
import checkout/db
import checkout/domain.{type Order}
import checkout/orders.{type Services}
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Subject}
import gleam/http.{Get, Post}
import gleam/http/request
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import grind/worker.{type Worker}
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

/// What the routes act on. Every handle in it is a name, so the same
/// value stays usable after the process behind a handle restarts.
pub type Context {
  Context(
    services: Services,
    checkout_worker: Worker(Order, String, Nil),
    customers: Customers,
  )
}

/// The messages of the endpoint process, which holds the port the
/// listener is bound to.
pub opaque type EndpointMessage {
  Bound(port: Int)
  CurrentPort(reply: Subject(Option(Int)))
}

/// The endpoint process, registered under `name`. Start it before the
/// listener, in a group that restarts the listener when the endpoint
/// restarts: the listener reports its port once, when it starts.
pub fn endpoint(
  name: Name(EndpointMessage),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    actor.new(None)
    |> actor.named(name)
    |> actor.on_message(fn(port, message) {
      case message {
        Bound(port) -> actor.continue(Some(port))
        CurrentPort(reply) -> {
          process.send(reply, port)
          actor.continue(port)
        }
      }
    })
    |> actor.start
    |> result.map(fn(started) { actor.Started(..started, data: Nil) })
  })
}

/// The order API's listener on loopback. `port` 0 binds any free port.
/// Each time the listener starts it tells the endpoint which port it
/// bound, so with `port` 0 a restarted listener has a new address.
pub fn listener(
  context: Context,
  secret_key_base secret: String,
  port port: Int,
  endpoint endpoint: Name(EndpointMessage),
) -> supervision.ChildSpecification(Nil) {
  wisp_mist.handler(handle(_, context), secret)
  |> mist.new
  |> mist.bind("127.0.0.1")
  |> mist.port(port)
  |> mist.after_start(fn(bound, _, _) {
    process.send(process.named_subject(endpoint), Bound(bound))
  })
  |> mist.supervised
  |> supervision.map_data(fn(_) { Nil })
}

/// The port the listener is bound to now, or `Error(Nil)` while no
/// listener has reported one. Panics when no endpoint is running.
pub fn port(endpoint: Name(EndpointMessage)) -> Result(Int, Nil) {
  actor.call(process.named_subject(endpoint), 1000, CurrentPort)
  |> option.to_result(Nil)
}

pub fn handle(req: wisp.Request, app: Context) -> wisp.Response {
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
  app: Context,
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

fn place(
  req: wisp.Request,
  app: Context,
  customer_id: String,
) -> wisp.Response {
  use body <- wisp.require_json(req)
  case decode.run(body, codecs.checkout_request_decoder()) {
    Error(_) -> error_response(422, "invalid_order")
    Ok(request) ->
      case orders.price(app.services, customer_id, request) {
        Error(error) -> place_error(error)
        Ok(order) ->
          case orders.place(app.services, app.checkout_worker, order) {
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

fn show(app: Context, customer_id: String, order_id: String) -> wisp.Response {
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

fn error_response(status: Int, code: String) -> wisp.Response {
  json.object([#("error", json.string(code))])
  |> json.to_string
  |> wisp.json_response(status)
}
