//// Scripted loopback services the desk depends on: an orders API, a
//// payments API and a customer-notification API, all on one mist server.
//// Each order id selects how the services behave, so one table drives
//// every scenario. Every request is recorded in arrival order.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import json/blueprint/codec
import mist
import support_desk/bounded_body
import support_desk/domain.{type Order, Order}
import support_desk/listener.{type Listener}

/// How long the payments API stalls for an order whose refund outcome
/// must stay unknown to the caller.
pub const payment_stall_ms = 1500

/// The largest request body the listener reads.
pub const max_body_bytes = 65_536

pub type Services {
  Services(base_url: String, calls: Subject(Recorded), listener: Listener)
}

/// The order table. `A-300` fails customer notification, `A-400` stalls
/// the payment API past any reasonable deadline, `A-600` was refunded
/// already, `A-700` is declined by the payment provider.
pub fn orders() -> List(Order) {
  [
    Order("A-100", "ada@example.com", 2500, "delivered"),
    Order("A-200", "grace@example.com", 12_000, "delivered"),
    Order("A-300", "alan@example.com", 4000, "delivered"),
    Order("A-400", "edsger@example.com", 3000, "delivered"),
    Order("A-500", "barbara@example.com", 1800, "delivered"),
    Order("A-600", "donald@example.com", 900, "refunded"),
    Order("A-700", "margaret@example.com", 2200, "delivered"),
  ]
}

pub fn start() -> Result(Services, String) {
  use calls <- result.try(start_recorder())
  case listener.start(fn(req) { handle(calls, req) }) {
    Ok(listener) ->
      Ok(Services(
        "http://127.0.0.1:" <> int.to_string(listener.port),
        calls,
        listener,
      ))
    Error(error) -> {
      stop_recorder(calls)
      Error(error)
    }
  }
}

/// Stop the listener before its request recorder.
pub fn stop(services: Services) -> Result(Nil, String) {
  use Nil <- result.map(listener.stop(services.listener))
  stop_recorder(services.calls)
}

/// Requests seen so far, as `"POST /payments/refunds A-100"`.
pub fn calls(services: Services) -> List(String) {
  process.call(services.calls, 1000, Calls)
}

pub fn calls_matching(services: Services, prefix: String) -> List(String) {
  calls(services) |> list.filter(fn(call) { string.starts_with(call, prefix) })
}

fn handle(
  calls: Subject(Recorded),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case req.method {
    http.Post ->
      case bounded_body.read(req, max_body_bytes) {
        Error(error) -> bounded_body.refusal(error)
        Ok(body) ->
          route(calls, req, bit_array.to_string(body) |> result.unwrap(""))
      }
    _ -> route(calls, req, "")
  }
}

fn route(
  calls: Subject(Recorded),
  req: Request(mist.Connection),
  body: String,
) -> Response(mist.ResponseData) {
  let order_id =
    json.parse(body, decode.at(["order_id"], decode.string))
    |> result.unwrap("")
  case req.method, request.path_segments(req) {
    http.Get, ["orders", id] -> {
      record(calls, "GET /orders " <> id)
      case list.find(orders(), fn(order) { order.order_id == id }) {
        Ok(order) -> {
          let assert Ok(text) = codec.encode_json(domain.order(), order)
          reply(200, text)
        }
        Error(Nil) -> reply(404, "{\"error\":\"no such order\"}")
      }
    }
    http.Post, ["payments", "refunds"] -> {
      record(calls, "POST /payments/refunds " <> order_id)
      let key =
        json.parse(body, decode.at(["idempotency_key"], decode.string))
        |> result.unwrap("")
      case order_id {
        "A-400" -> {
          // The provider does take the refund, but answers too late.
          process.sleep(payment_stall_ms)
          reply(201, refund_body(refund_id(calls, order_id, key)))
        }
        "A-700" -> reply(402, "{\"error\":\"card_declined\"}")
        _ -> reply(201, refund_body(refund_id(calls, order_id, key)))
      }
    }
    http.Post, ["payments", "refunds", refund_id, "void"] -> {
      record(calls, "POST /payments/void " <> refund_id)
      reply(200, "{\"voided\":true}")
    }
    http.Post, ["notify"] -> {
      record(calls, "POST /notify " <> order_id)
      case order_id {
        "A-300" -> reply(503, "{\"error\":\"mail relay down\"}")
        _ -> reply(202, "{\"queued\":true}")
      }
    }
    _, _ -> reply(404, "{\"error\":\"not found\"}")
  }
}

fn refund_body(refund_id: String) -> String {
  json.object([#("refund_id", json.string(refund_id))])
  |> json.to_string
}

/// The payments API honours idempotency keys as a real provider does: a
/// repeated key answers the refund it created, and another key creates
/// another refund. An order's first refund is `rf_<order>`.
fn refund_id(
  calls: Subject(Recorded),
  order_id: String,
  key: String,
) -> String {
  process.call(calls, 1000, Refund(order_id, key, _))
}

/// Refunds the payments API has created, as `#(key, refund id)`.
pub fn refunds(services: Services) -> List(#(String, String)) {
  process.call(services.calls, 1000, Refunds)
}

fn reply(status: Int, text: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}

// Request recorder --------------------------------------------------------

pub opaque type Recorded {
  Record(String)
  Calls(reply: Subject(List(String)))
  Refund(order_id: String, key: String, reply: Subject(String))
  Refunds(reply: Subject(List(#(String, String))))
  Stop
}

type Seen {
  Seen(calls: List(String), refunds: List(#(String, String)))
}

fn record(calls: Subject(Recorded), call: String) -> Nil {
  process.send(calls, Record(call))
}

fn start_recorder() -> Result(Subject(Recorded), String) {
  actor.new(Seen([], []))
  |> actor.on_message(fn(seen: Seen, message) {
    case message {
      Stop -> actor.stop()
      Record(call) -> actor.continue(Seen(..seen, calls: [call, ..seen.calls]))
      Calls(reply) -> {
        process.send(reply, list.reverse(seen.calls))
        actor.continue(seen)
      }
      Refunds(reply) -> {
        process.send(reply, list.reverse(seen.refunds))
        actor.continue(seen)
      }
      Refund(order_id, key, reply) ->
        case list.key_find(seen.refunds, key) {
          Ok(id) -> {
            process.send(reply, id)
            actor.continue(seen)
          }
          Error(Nil) -> {
            let earlier =
              list.count(seen.refunds, fn(refund) {
                string.starts_with(refund.1, "rf_" <> order_id)
              })
            let id = case earlier {
              0 -> "rf_" <> order_id
              n -> "rf_" <> order_id <> "_" <> int.to_string(n + 1)
            }
            process.send(reply, id)
            actor.continue(Seen(..seen, refunds: [#(key, id), ..seen.refunds]))
          }
        }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error("could not start the request recorder")
}

fn stop_recorder(calls: Subject(Recorded)) -> Nil {
  let assert Ok(pid) = process.subject_owner(calls)
  let monitor = process.monitor(pid)
  process.send(calls, Stop)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive_forever
}
