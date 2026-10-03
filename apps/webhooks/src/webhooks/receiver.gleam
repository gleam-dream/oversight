//// A scripted tenant receiver on loopback (mist). It records every request
//// and answers by path, so the app can be exercised without real network.
////
////   /ok    204
////   /gone  410
////   /busy  429 with Retry-After: 1 on the first call, then 204
////   /throttled  429 with Retry-After: 0, always
////   /flaky 503 twice, then 204
////   /big   200 with a 64 KiB body

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

pub type Received {
  Received(path: String, headers: List(#(String, String)), body: BitArray)
}

pub opaque type Receiver {
  Receiver(port: Int, log: Subject(Message))
}

pub opaque type Message {
  Got(Received, reply: Subject(Int))
  All(reply: Subject(List(Received)))
}

type State {
  State(seen: List(Received), counts: Dict(String, Int))
}

pub fn start() -> Receiver {
  let assert Ok(log) =
    actor.new(State([], dict.new()))
    |> actor.on_message(fn(state: State, message) {
      case message {
        Got(received, reply) -> {
          let n = result.unwrap(dict.get(state.counts, received.path), 0) + 1
          process.send(reply, n)
          actor.continue(State(
            [received, ..state.seen],
            dict.insert(state.counts, received.path, n),
          ))
        }
        All(reply) -> {
          process.send(reply, list.reverse(state.seen))
          actor.continue(state)
        }
      }
    })
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

pub fn port(receiver: Receiver) -> Int {
  receiver.port
}

pub fn url(receiver: Receiver, path: String) -> String {
  "http://127.0.0.1:" <> int.to_string(receiver.port) <> path
}

pub fn received(receiver: Receiver) -> List(Received) {
  process.call(receiver.log, 1000, All)
}

fn serve(
  log: Subject(Message),
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let body = case mist.read_body(req, 1_048_576) {
    Ok(read) -> read.body
    Error(_) -> <<>>
  }
  let n =
    process.call(log, 1000, fn(reply) {
      Got(Received(req.path, req.headers, body), reply)
    })
  case req.path, n {
    "/ok", _ -> reply(204, [], <<>>)
    "/gone", _ -> reply(410, [], <<"gone":utf8>>)
    "/busy", 1 -> reply(429, [#("retry-after", "1")], <<>>)
    "/busy", _ -> reply(204, [], <<>>)
    "/throttled", _ -> reply(429, [#("retry-after", "0")], <<>>)
    "/flaky", n if n <= 2 -> reply(503, [], <<"try later":utf8>>)
    "/flaky", _ -> reply(204, [], <<>>)
    "/big", _ -> reply(200, [], big_body())
    _, _ -> reply(404, [], <<>>)
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
