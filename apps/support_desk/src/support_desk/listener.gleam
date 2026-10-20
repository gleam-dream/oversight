//// Owns one scripted Mist listener. A failed linked startup is isolated
//// here; explicit stop and caller exit both retire the listener subtree.

import gleam/erlang/atom
import gleam/erlang/process.{type Pid}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/otp/actor
import gleam/result
import mist

pub type Listener {
  Listener(pid: Pid, port: Int)
}

pub fn start(
  handle: fn(Request(mist.Connection)) -> Response(mist.ResponseData),
) -> Result(Listener, String) {
  actor.new_with_initialiser(30_000, fn(_) {
    process.trap_exits(True)
    let ports = process.new_subject()
    use started <- result.try(
      mist.new(handle)
      |> mist.bind("127.0.0.1")
      |> mist.port(0)
      |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
      |> mist.start
      |> result.replace_error("scripted listener did not start"),
    )
    case process.receive(ports, 2000) {
      Ok(port) ->
        Ok(
          actor.initialised(started.pid)
          |> actor.selecting(
            process.new_selector()
            |> process.select_trapped_exits(fn(message) { message }),
          )
          |> actor.returning(port),
        )
      Error(Nil) -> {
        let _ = stop_process(started.pid)
        Error("scripted listener did not report its port")
      }
    }
  })
  |> actor.on_message(fn(listener, message) {
    case message.pid == listener {
      True ->
        case message.reason {
          process.Normal -> actor.stop()
          _ -> actor.stop_abnormal("scripted listener stopped unexpectedly")
        }
      False -> {
        case stop_process(listener) {
          Ok(Nil) -> actor.stop()
          // Keep the owner alive: its caller must see a shutdown timeout,
          // never a successful owner exit while the listener still runs.
          Error(_) -> actor.continue(listener)
        }
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { Listener(started.pid, started.data) })
  |> result.map_error(fn(error) {
    case error {
      actor.InitFailed(reason) -> reason
      _ -> "scripted listener owner did not start"
    }
  })
}

/// Return only once the listener owner and its subtree have stopped.
pub fn stop(listener: Listener) -> Result(Nil, String) {
  stop_process(listener.pid)
}

fn stop_process(pid: Pid) -> Result(Nil, String) {
  let monitor = process.monitor(pid)
  process.unlink(pid)
  let _ = exit(pid, atom.create("shutdown"))
  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(30_000)
    |> result.replace_error("scripted listener did not stop in time")
  process.demonitor_process(monitor)
  stopped
}

@external(erlang, "erlang", "exit")
fn exit(pid: Pid, reason: atom.Atom) -> Bool
