//// Scripted payment and shipping providers on loopback mist servers. They
//// are the external world for the demo and the tests: no real network, no
//// keys. Behaviour is chosen by magic card numbers and addresses so one
//// running server can script every scenario.
////
//// Payments (`POST /charges`, `POST /charges/:id/void`,
//// `GET /charges/by-key/:key`) dedupe by the `idempotency-key` header.
//// Shipping (`POST /shipments`, `POST /shipments/by-key/:key/cancel`,
//// `GET /shipments/by-key/:key`) dedupes the same way.

import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http.{Get, Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import mist

/// Approved immediately.
pub const card_ok = "4242424242424242"

/// Declined with HTTP 402.
pub const card_declined = "4000000000000002"

/// Charged, but the first answer arrives after the client's deadline. A retry
/// with the same idempotency key is answered at once with the same charge.
pub const card_first_answer_lost = "4000000000000259"

/// Charged, and every answer arrives after the client's deadline.
pub const card_black_hole = "4000000000009995"

/// Booked, but the answer arrives after the client's deadline.
pub const address_slow = "1 Slow Lane"

/// Booked, then the answer is held for a long time; watchers are told the
/// request arrived so a test can kill the caller mid-request.
pub const address_hold = "2 Held Road"

pub type ChargeStatus {
  Captured
  Voided
}

pub type ChargeRecord {
  ChargeRecord(id: String, key: String, amount_cents: Int, status: ChargeStatus)
}

pub type ShipmentStatus {
  Booked
  Cancelled
}

pub type ShipmentRecord {
  ShipmentRecord(id: String, key: String, status: ShipmentStatus)
}

pub type Snapshot {
  Snapshot(
    charges: List(ChargeRecord),
    shipments: List(ShipmentRecord),
    charge_requests: Int,
    shipment_requests: Int,
  )
}

pub opaque type Providers {
  Providers(
    state: Subject(Message),
    payments_port: Int,
    shipping_port: Int,
    servers: List(Pid),
    state_pid: Pid,
    slow_ms: Int,
  )
}

pub fn payments_url(p: Providers) -> String {
  "http://127.0.0.1:" <> int.to_string(p.payments_port)
}

pub fn shipping_url(p: Providers) -> String {
  "http://127.0.0.1:" <> int.to_string(p.shipping_port)
}

pub fn snapshot(p: Providers) -> Snapshot {
  actor.call(p.state, 1000, GetSnapshot)
}

pub fn charge_for(p: Providers, key: String) -> Option(ChargeRecord) {
  snapshot(p).charges |> list.find(fn(c) { c.key == key }) |> option.from_result
}

pub fn shipment_for(p: Providers, key: String) -> Option(ShipmentRecord) {
  snapshot(p).shipments
  |> list.find(fn(s) { s.key == key })
  |> option.from_result
}

/// Every shipment request that arrives is reported here by idempotency key.
pub fn watch_shipments(p: Providers, to: Subject(String)) -> Nil {
  actor.send(p.state, Watch(to))
}

/// `slow_ms` is how long a "slow" answer is held; pick it above the
/// client's request deadline.
pub fn start(slow_ms: Int) -> Result(Providers, actor.StartError) {
  use started <- result.try(
    actor.new(empty())
    |> actor.on_message(handle)
    |> actor.start,
  )
  let state = started.data
  use #(payments_pid, payments_port) <- result.try(
    serve(fn(req) { payments(state, slow_ms, req) }),
  )
  use #(shipping_pid, shipping_port) <- result.try(
    serve(fn(req) { shipping(state, slow_ms, req) }),
  )
  Ok(Providers(
    state:,
    payments_port:,
    shipping_port:,
    servers: [payments_pid, shipping_pid],
    state_pid: started.pid,
    slow_ms:,
  ))
}

/// Must run in the process that called `start`.
pub fn stop(p: Providers) -> Nil {
  list.each(p.servers, process.send_exit)
  process.unlink(p.state_pid)
  process.kill(p.state_pid)
}

fn serve(
  handler: fn(Request(mist.Connection)) -> Response(mist.ResponseData),
) -> Result(#(Pid, Int), actor.StartError) {
  let port = process.new_subject()
  mist.new(handler)
  |> mist.bind("127.0.0.1")
  |> mist.port(0)
  |> mist.after_start(fn(bound, _, _) { process.send(port, bound) })
  |> mist.start
  |> result.map(fn(started) {
    let assert Ok(bound) = process.receive(port, 1000)
    #(started.pid, bound)
  })
}

// --- state ----------------------------------------------------------------

type State {
  State(
    charges: Dict(String, ChargeRecord),
    shipments: Dict(String, ShipmentRecord),
    charge_requests: Int,
    shipment_requests: Int,
    watchers: List(Subject(String)),
    next: Int,
  )
}

fn empty() -> State {
  State(dict.new(), dict.new(), 0, 0, [], 1)
}

type ChargeDecision {
  Decline(reason: String)
  Charge(record: ChargeRecord, delay: Bool)
}

type Message {
  RequestCharge(
    key: String,
    card: String,
    amount: Int,
    reply: Subject(ChargeDecision),
  )
  VoidCharge(id: String, reply: Subject(Result(ChargeRecord, Nil)))
  FindCharge(key: String, reply: Subject(Option(ChargeRecord)))
  RequestShipment(key: String, address: String, reply: Subject(ShipmentRecord))
  CancelShipment(key: String, reply: Subject(Option(ShipmentRecord)))
  FindShipment(key: String, reply: Subject(Option(ShipmentRecord)))
  Watch(Subject(String))
  GetSnapshot(Subject(Snapshot))
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    RequestCharge(key, card, amount, reply) -> {
      let state = State(..state, charge_requests: state.charge_requests + 1)
      case dict.get(state.charges, key), card {
        Ok(existing), _ -> {
          process.send(reply, Charge(existing, card == card_black_hole))
          actor.continue(state)
        }
        Error(Nil), c if c == card_declined -> {
          process.send(reply, Decline("insufficient_funds"))
          actor.continue(state)
        }
        Error(Nil), _ -> {
          let record =
            ChargeRecord(
              "ch_" <> int.to_string(state.next),
              key,
              amount,
              Captured,
            )
          process.send(
            reply,
            Charge(
              record,
              card == card_first_answer_lost || card == card_black_hole,
            ),
          )
          actor.continue(
            State(
              ..state,
              charges: dict.insert(state.charges, key, record),
              next: state.next + 1,
            ),
          )
        }
      }
    }
    VoidCharge(id, reply) -> {
      case dict.values(state.charges) |> list.find(fn(c) { c.id == id }) {
        Ok(found) -> {
          let voided = ChargeRecord(..found, status: Voided)
          process.send(reply, Ok(voided))
          actor.continue(
            State(
              ..state,
              charges: dict.insert(state.charges, found.key, voided),
            ),
          )
        }
        Error(Nil) -> {
          process.send(reply, Error(Nil))
          actor.continue(state)
        }
      }
    }
    FindCharge(key, reply) -> {
      process.send(reply, dict.get(state.charges, key) |> option.from_result)
      actor.continue(state)
    }
    RequestShipment(key, _address, reply) -> {
      list.each(state.watchers, process.send(_, key))
      let state = State(..state, shipment_requests: state.shipment_requests + 1)
      case dict.get(state.shipments, key) {
        Ok(existing) -> {
          process.send(reply, existing)
          actor.continue(state)
        }
        Error(Nil) -> {
          let record =
            ShipmentRecord("sh_" <> int.to_string(state.next), key, Booked)
          process.send(reply, record)
          actor.continue(
            State(
              ..state,
              shipments: dict.insert(state.shipments, key, record),
              next: state.next + 1,
            ),
          )
        }
      }
    }
    CancelShipment(key, reply) -> {
      case dict.get(state.shipments, key) {
        Ok(found) -> {
          let cancelled = ShipmentRecord(..found, status: Cancelled)
          process.send(reply, Some(cancelled))
          actor.continue(
            State(
              ..state,
              shipments: dict.insert(state.shipments, key, cancelled),
            ),
          )
        }
        Error(Nil) -> {
          process.send(reply, None)
          actor.continue(state)
        }
      }
    }
    FindShipment(key, reply) -> {
      process.send(reply, dict.get(state.shipments, key) |> option.from_result)
      actor.continue(state)
    }
    Watch(subject) ->
      actor.continue(State(..state, watchers: [subject, ..state.watchers]))
    GetSnapshot(reply) -> {
      process.send(
        reply,
        Snapshot(
          dict.values(state.charges),
          dict.values(state.shipments),
          state.charge_requests,
          state.shipment_requests,
        ),
      )
      actor.continue(state)
    }
  }
}

// --- HTTP -----------------------------------------------------------------

fn payments(
  state: Subject(Message),
  slow_ms: Int,
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let key = request.get_header(req, "idempotency-key") |> result.unwrap("")
  case req.method, request.path_segments(req) {
    Post, ["charges"] -> {
      let decoder = {
        use card <- decode.field("card", decode.string)
        use amount <- decode.field("amount_cents", decode.int)
        decode.success(#(card, amount))
      }
      case read_json(req, decoder) {
        Error(Nil) -> reply(400, json.object([]))
        Ok(#(card, amount)) ->
          case actor.call(state, 1000, RequestCharge(key, card, amount, _)) {
            Decline(reason) ->
              reply(402, json.object([#("reason", json.string(reason))]))
            Charge(record, delay) -> {
              case delay {
                True -> process.sleep(slow_ms)
                False -> Nil
              }
              reply(200, charge_json(record))
            }
          }
      }
    }
    Post, ["charges", id, "void"] ->
      case actor.call(state, 1000, VoidCharge(id, _)) {
        Ok(record) -> reply(200, charge_json(record))
        Error(Nil) -> reply(404, json.object([]))
      }
    Get, ["charges", "by-key", key] ->
      case actor.call(state, 1000, FindCharge(key, _)) {
        Some(record) -> reply(200, charge_json(record))
        None -> reply(404, json.object([]))
      }
    _, _ -> reply(404, json.object([]))
  }
}

fn shipping(
  state: Subject(Message),
  slow_ms: Int,
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let key = request.get_header(req, "idempotency-key") |> result.unwrap("")
  case req.method, request.path_segments(req) {
    Post, ["shipments"] -> {
      let decoder = decode.field("address", decode.string, decode.success)
      case read_json(req, decoder) {
        Error(Nil) -> reply(400, json.object([]))
        Ok(address) -> {
          let record = actor.call(state, 1000, RequestShipment(key, address, _))
          case address {
            a if a == address_slow -> process.sleep(slow_ms)
            a if a == address_hold -> process.sleep(slow_ms * 10)
            _ -> Nil
          }
          reply(201, shipment_json(record))
        }
      }
    }
    Post, ["shipments", "by-key", key, "cancel"] ->
      case actor.call(state, 1000, CancelShipment(key, _)) {
        Some(record) -> reply(200, shipment_json(record))
        None -> reply(404, json.object([]))
      }
    Get, ["shipments", "by-key", key] ->
      case actor.call(state, 1000, FindShipment(key, _)) {
        Some(record) -> reply(200, shipment_json(record))
        None -> reply(404, json.object([]))
      }
    _, _ -> reply(404, json.object([]))
  }
}

fn read_json(
  req: Request(mist.Connection),
  decoder: decode.Decoder(a),
) -> Result(a, Nil) {
  use req <- result.try(
    mist.read_body(req, 65_536) |> result.replace_error(Nil),
  )
  json.parse_bits(req.body, decoder) |> result.replace_error(Nil)
}

fn reply(status: Int, body: json.Json) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}

fn charge_json(c: ChargeRecord) -> json.Json {
  json.object([
    #("id", json.string(c.id)),
    #(
      "status",
      json.string(case c.status {
        Captured -> "captured"
        Voided -> "voided"
      }),
    ),
  ])
}

fn shipment_json(s: ShipmentRecord) -> json.Json {
  json.object([
    #("id", json.string(s.id)),
    #(
      "status",
      json.string(case s.status {
        Booked -> "booked"
        Cancelled -> "cancelled"
      }),
    ),
  ])
}
