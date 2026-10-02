//// The order API on wisp + mist.
////
//// - `POST /orders` runs the checkout saga in the request and answers with
////   the final status (201 confirmed, 402/409/502/504 rejected, 202 held).
//// - `POST /orders?mode=durable` enqueues the durable checkout job (202).
//// - `GET /orders/:id` reads the order row.

import checkout/app.{type App}
import checkout/codecs
import checkout/db
import checkout/domain.{type CheckoutError}
import checkout/orders.{type Report}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid}
import gleam/http.{Get, Post}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun/error
import mist
import wisp
import wisp/wisp_mist

pub fn start(app: App) -> Result(#(Pid, Int), String) {
  let port = process.new_subject()
  wisp_mist.handler(handle(_, app), "checkout-demo-secret-key-base-0123456789")
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
  case req.method, wisp.path_segments(req) {
    Post, ["orders"] -> place(req, app)
    Get, ["orders", order_id] -> show(app, order_id)
    _, _ -> wisp.not_found()
  }
}

fn place(req: wisp.Request, app: App) -> wisp.Response {
  use body <- wisp.require_json(req)
  case decode_order(body) {
    Error(Nil) -> wisp.unprocessable_content()
    Ok(order) ->
      case list.key_find(wisp.get_query(req), "mode") {
        Ok("durable") ->
          case orders.place_durable(app.services, app.checkout_worker, order) {
            Ok(job_id) ->
              json.object([
                #("order_id", json.string(order.order_id)),
                #("status", json.string("pending")),
                #("job_id", json.int(job_id)),
              ])
              |> json.to_string
              |> wisp.json_response(202)
            Error(detail) ->
              json.object([#("error", json.string(detail))])
              |> json.to_string
              |> wisp.json_response(503)
          }
        _ -> {
          let report = orders.place_local(app.services, order)
          report_json(order.order_id, report)
          |> json.to_string
          |> wisp.json_response(status_code(report))
        }
      }
  }
}

fn show(app: App, order_id: String) -> wisp.Response {
  case db.order_status(app.services.pool, order_id) {
    None -> wisp.not_found()
    Some(#(status, detail)) ->
      json.object([
        #("order_id", json.string(order_id)),
        #("status", json.string(domain.status_to_string(status))),
        #("detail", json.string(detail)),
      ])
      |> json.to_string
      |> wisp.json_response(200)
  }
}

fn decode_order(body: decode.Dynamic) -> Result(domain.OrderRequest, Nil) {
  decode.run(body, codecs.order_decoder()) |> result.replace_error(Nil)
}

fn report_json(order_id: String, report: Report) -> json.Json {
  json.object([
    #("order_id", json.string(order_id)),
    #("status", json.string(domain.status_to_string(report.status))),
    #("detail", json.string(report.detail)),
    #("undone", json.array(report.undone, json.string)),
    #("unknown_effects", json.int(report.unknown_effects)),
  ])
}

/// The HTTP status follows the typed error, including http_gun's failure
/// class: a provider deadline is a 504, any other transport failure a 502.
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
    domain.ProviderUnreachable(
      failure: error.Failure(error.DeadlineExceeded, _),
      ..,
    ) -> 504
    domain.ProviderUnreachable(..) | domain.ProviderRejected(..) -> 502
    domain.StockStoreFailed(_) | domain.Interrupted(_) -> 503
  }
}
