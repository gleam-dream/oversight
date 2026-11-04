//// A scripted tenant receiver on loopback (mist), written the way a real
//// webhook consumer should check deliveries. It records every request and,
//// for an endpoint whose secret it trusts, answers in this order:
////
//// 1. 401 unless the signature verifies and `webhook-timestamp` is within
////    the tolerance of the receiver's clock (`signing.verify_within`).
//// 2. 204 without running the endpoint when the `webhook-id` was already
////    processed: the delivery id is the idempotency key.
//// 3. Otherwise the endpoint's script runs, and a 2xx answer marks the
////    `webhook-id` processed. A failed attempt is not remembered, so the
////    sender's retry runs the endpoint again.
////
//// The scripts, by path:
////
////   /ok    204
////   /gone  410
////   /busy  429 with Retry-After: 1 on the first call, then 204
////   /throttled  429 with Retry-After: 0, always
////   /flaky 503 twice, then 204
////   /big   200 with a 64 KiB body
////
//// One actor checks, runs and marks each request, so two copies of a
//// delivery arriving together still run the endpoint once. A receiver with
//// durable effects records the processed id in the same transaction as the
//// effect.

import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import mist
import webhooks/signing

pub type Received {
  Received(
    path: String,
    headers: List(#(String, String)),
    body: BitArray,
    verdict: Verdict,
  )
}

/// What the receiver did with one request.
pub type Verdict {
  /// Verified and new: the endpoint's script ran and answered `status`.
  Processed(status: Int)
  /// Verified, but its `webhook-id` was already processed: acknowledged
  /// without running the script again.
  Duplicate
  /// Refused with 401 before the script ran.
  Rejected(reason: String)
}

pub type Settings {
  Settings(
    /// How far `webhook-timestamp` may be from the receiver's clock, either
    /// way. Standard Webhooks suggests five minutes.
    tolerance_seconds: Int,
    /// How long a processed `webhook-id` is remembered. It is never less
    /// than twice the tolerance, the longest a captured request stays
    /// fresh; covering the sender's retry horizon as well makes every retry
    /// of a processed delivery a duplicate.
    retention_seconds: Int,
  )
}

pub fn default_settings() -> Settings {
  Settings(tolerance_seconds: 300, retention_seconds: 86_400)
}

pub opaque type Receiver {
  Receiver(port: Int, log: Subject(Message))
}

pub opaque type Message {
  Check(
    path: String,
    headers: List(#(String, String)),
    body: BitArray,
    now: Int,
    reply: Subject(Answer),
  )
  All(reply: Subject(List(Received)))
  Trust(path: String, secret: String)
}

type Answer {
  Answer(status: Int, headers: List(#(String, String)), body: BitArray)
}

type State {
  State(
    settings: Settings,
    secrets: Dict(String, String),
    seen: List(Received),
    counts: Dict(String, Int),
    /// Processed `webhook-id` -> the Unix second it may be forgotten.
    processed: Dict(String, Int),
  )
}

pub fn start() -> Receiver {
  start_with(default_settings())
}

pub fn start_with(settings: Settings) -> Receiver {
  let settings =
    Settings(
      ..settings,
      retention_seconds: int.max(
        settings.retention_seconds,
        2 * settings.tolerance_seconds,
      ),
    )
  let assert Ok(log) =
    actor.new(State(settings, dict.new(), [], dict.new(), dict.new()))
    |> actor.on_message(handle_message)
    |> actor.start
  let ports = process.new_subject()
  let assert Ok(_) =
    mist.new(fn(req) { serve(log.data, req) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
  let assert Ok(port) = process.receive(ports, 1000)
  Receiver(port:, log: log.data)
}

/// Registers the signing secret of the endpoint at `path`. A request to a
/// path without one is refused.
pub fn trust(receiver: Receiver, path: String, secret: String) -> Nil {
  process.send(receiver.log, Trust(path, secret))
}

pub fn port(receiver: Receiver) -> Int {
  receiver.port
}

pub fn url(receiver: Receiver, path: String) -> String {
  "http://127.0.0.1:" <> int.to_string(receiver.port) <> path
}

pub fn received(receiver: Receiver) -> List(Received) {
  process.call(receiver.log, 1000, All)
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Trust(path, secret) ->
      actor.continue(
        State(..state, secrets: dict.insert(state.secrets, path, secret)),
      )
    All(reply) -> {
      process.send(reply, list.reverse(state.seen))
      actor.continue(state)
    }
    Check(path, headers, body, now, reply) -> {
      let state =
        State(
          ..state,
          processed: dict.filter(state.processed, fn(_, until) { until > now }),
        )
      let #(verdict, answer, state) = case
        verify(state, path, headers, body, now)
      {
        Error(reason) -> #(Rejected(reason), Answer(401, [], <<>>), state)
        Ok(id) ->
          case dict.has_key(state.processed, id) {
            True -> #(Duplicate, Answer(204, [], <<>>), state)
            False -> {
              let n = result.unwrap(dict.get(state.counts, path), 0) + 1
              let answer = script(path, n)
              let processed = case answer.status >= 200 && answer.status < 300 {
                True ->
                  dict.insert(
                    state.processed,
                    id,
                    now + state.settings.retention_seconds,
                  )
                False -> state.processed
              }
              #(
                Processed(answer.status),
                answer,
                State(
                  ..state,
                  counts: dict.insert(state.counts, path, n),
                  processed:,
                ),
              )
            }
          }
      }
      process.send(reply, answer)
      actor.continue(
        State(..state, seen: [
          Received(path, headers, body, verdict),
          ..state.seen
        ]),
      )
    }
  }
}

/// The verified `webhook-id`, or why the request is refused. The signature
/// covers the body bytes exactly as received.
fn verify(
  state: State,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  now: Int,
) -> Result(String, String) {
  let header = fn(name) { list.key_find(headers, name) }
  use secret <- result.try(
    dict.get(state.secrets, path) |> result.replace_error("unknown endpoint"),
  )
  case
    header(signing.id_header),
    header(signing.timestamp_header) |> result.try(int.parse),
    header(signing.signature_header)
  {
    Ok(id), Ok(timestamp), Ok(signature) ->
      case
        signing.verify_within(
          secret,
          id,
          timestamp,
          body,
          signature,
          now:,
          tolerance: state.settings.tolerance_seconds,
        )
      {
        Ok(Nil) -> Ok(id)
        Error(signing.StaleTimestamp) -> Error("stale timestamp")
        Error(signing.InvalidSignature) -> Error("invalid signature")
      }
    _, _, _ -> Error("missing signature headers")
  }
}

fn serve(
  log: Subject(Message),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let body = case mist.read_body(req, 1_048_576) {
    Ok(read) -> read.body
    Error(_) -> <<>>
  }
  let answer =
    process.call(log, 1000, Check(req.path, req.headers, body, unix_now(), _))
  reply(answer.status, answer.headers, answer.body)
}

fn script(path: String, n: Int) -> Answer {
  case path, n {
    "/ok", _ -> Answer(204, [], <<>>)
    "/gone", _ -> Answer(410, [], <<"gone":utf8>>)
    "/busy", 1 -> Answer(429, [#("retry-after", "1")], <<>>)
    "/busy", _ -> Answer(204, [], <<>>)
    "/throttled", _ -> Answer(429, [#("retry-after", "0")], <<>>)
    "/flaky", n if n <= 2 -> Answer(503, [], <<"try later":utf8>>)
    "/flaky", _ -> Answer(204, [], <<>>)
    "/big", _ -> Answer(200, [], big_body())
    _, _ -> Answer(404, [], <<>>)
  }
}

pub fn big_body() -> BitArray {
  list.repeat(<<"0123456789abcdef":utf8>>, 4096) |> bit_array_concat
}

fn bit_array_concat(parts: List(BitArray)) -> BitArray {
  list.fold(parts, <<>>, fn(acc, part) { <<acc:bits, part:bits>> })
}

fn reply(
  status: Int,
  headers: List(#(String, String)),
  body: BitArray,
) -> Response(mist.ResponseData) {
  list.fold(headers, response.new(status), fn(resp, header) {
    response.set_header(resp, header.0, header.1)
  })
  |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
}

fn unix_now() -> Int {
  now_ms() / 1000
}

@external(erlang, "webhooks_ffi", "now_ms")
fn now_ms() -> Int
