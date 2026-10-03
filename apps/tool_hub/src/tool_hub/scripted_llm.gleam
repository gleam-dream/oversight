//// A loopback LLM provider for llm_wire's scripted wire format
//// (`llm_wire/testing.config()`), served by mist. Each POST takes the next
//// step of a script. No request leaves the machine and no key is used.

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import llm_wire
import llm_wire/testing
import mist

pub type Step {
  /// Answer with this scripted reply.
  Reply(testing.Reply)
  /// Run `effect` first, then answer. Used to stop a peer between turns.
  After(effect: fn() -> Nil, reply: testing.Reply)
  /// Stream one text event, then keep the response open with SSE comments
  /// until the client goes away.
  Hold
}

/// What the provider observed, in order.
pub type Notice {
  /// A model request arrived; `body` is the request JSON as sent.
  Received(body: String)
  /// A held stream sent its first event.
  StreamHeld
  /// A held stream could no longer write: the client closed it.
  StreamClosed
}

pub opaque type Provider {
  Provider(port: Int, supervisor: process.Pid)
}

type ScriptMessage {
  Next(Subject(Option(Step)))
}

pub fn start(
  steps: List(Step),
  notices: Subject(Notice),
) -> Result(Provider, String) {
  use script <- result.try(
    actor.new(steps)
    |> actor.on_message(fn(steps, message) {
      let Next(reply) = message
      case steps {
        [] -> {
          process.send(reply, None)
          actor.continue([])
        }
        [step, ..rest] -> {
          process.send(reply, Some(step))
          actor.continue(rest)
        }
      }
    })
    |> actor.start
    |> result.replace_error("script actor failed to start"),
  )
  let port_subject = process.new_subject()
  use started <- result.try(
    mist.new(fn(req) { handle(req, script.data, notices) })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(port_subject, port) })
    |> mist.start
    |> result.replace_error("scripted provider failed to start"),
  )
  process.unlink(started.pid)
  use port <- result.map(
    process.receive(port_subject, 2000)
    |> result.replace_error("scripted provider reported no port"),
  )
  Provider(port, started.pid)
}

pub fn stop(provider: Provider) -> Nil {
  stop_process(provider.supervisor)
}

@external(erlang, "tool_hub_ffi", "stop_process")
fn stop_process(pid: process.Pid) -> Nil

/// llm_wire settings for this provider: the scripted adapter pointed at the
/// loopback endpoint. llm_wire limits plain `http://` to loopback addresses
/// through the HTTP Gun view of each call.
pub fn settings(provider: Provider) -> llm_wire.Config {
  testing.config()
  |> llm_wire.with_endpoint("http://127.0.0.1:" <> int.to_string(provider.port))
}

/// A scripted tool call; `arguments` is the raw JSON text the model "sent".
pub fn call(
  id: String,
  name: String,
  arguments: String,
) -> testing.ScriptedCall {
  testing.ScriptedCall(id:, name:, arguments_json: arguments)
}

fn handle(
  req: Request(mist.Connection),
  script: Subject(ScriptMessage),
  notices: Subject(Notice),
) -> response.Response(mist.ResponseData) {
  let body = case mist.read_body(req, 1_048_576) {
    Ok(read) -> bit_array.to_string(read.body) |> result.unwrap("")
    Error(_) -> ""
  }
  process.send(notices, Received(body))
  case process.call(script, 1000, Next) {
    None -> respond(testing.Status(500, "script exhausted"))
    Some(Reply(reply)) -> respond(reply)
    Some(After(effect, reply)) -> {
      effect()
      respond(reply)
    }
    Some(Hold) -> hold(req, notices)
  }
}

fn respond(reply: testing.Reply) -> response.Response(mist.ResponseData) {
  let #(status, chunks) = case reply {
    testing.Events(chunks) -> #(200, chunks)
    testing.Interrupted(chunks) -> #(200, chunks)
    testing.Status(code, text) -> #(code, [text])
  }
  response.new(status)
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(string.concat(chunks))),
  )
}

type Tick {
  Tick(count: Int)
}

fn hold(
  req: Request(mist.Connection),
  notices: Subject(Notice),
) -> response.Response(mist.ResponseData) {
  let first = case testing.text("Checking the inventory") {
    testing.Events([event, ..]) -> event
    _ -> ""
  }
  mist.chunked(
    req,
    response.new(200)
      |> response.set_header("content-type", "text/event-stream"),
    fn(self) {
      process.send(self, Tick(0))
      self
    },
    fn(self, tick, connection) {
      let Tick(count) = tick
      let data = case count {
        0 -> first
        _ -> ": keepalive\n\n"
      }
      case mist.send_chunk(connection, bit_array.from_string(data)) {
        Ok(Nil) -> {
          case count {
            0 -> process.send(notices, StreamHeld)
            _ -> Nil
          }
          process.send_after(self, 50, Tick(count + 1))
          mist.chunk_continue(self)
        }
        Error(Nil) -> {
          process.send(notices, StreamClosed)
          mist.chunk_stop()
        }
      }
    },
  )
}

/// Bodies of the model requests seen so far, draining `notices`.
pub fn drain(notices: Subject(Notice)) -> List(Notice) {
  case process.receive(notices, 0) {
    Ok(notice) -> [notice, ..drain(notices)]
    Error(Nil) -> []
  }
}

pub fn requests(notices: List(Notice)) -> List(String) {
  list.filter_map(notices, fn(notice) {
    case notice {
      Received(body) -> Ok(body)
      _ -> Error(Nil)
    }
  })
}
