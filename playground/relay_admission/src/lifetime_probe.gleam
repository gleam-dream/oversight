//// Public consumer checks for callback lifetime, shutdown, and dispatch authority.

import admission_probe as probe
import gleam/erlang/process
import gleam/http/request
import gleam/time/duration
import json/blueprint/codec
import relay/http
import relay/server
import relay/testing
import relay/tool

type Entry {
  Entry(owner: process.Pid, release: process.Subject(Nil))
}

fn hold(entered: process.Subject(Entry)) {
  let release = process.new_subject()
  process.send(entered, Entry(process.self(), release))
  process.receive_forever(release)
}

type Borrowed {
  Borrowed(address: process.Subject(process.Subject(Nil)), owner: process.Pid)
}

fn borrowed_loop(address: process.Subject(process.Subject(Nil))) {
  let reply = process.receive_forever(address)
  process.send(reply, Nil)
  borrowed_loop(address)
}

fn borrowed() -> Borrowed {
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let address = process.new_subject()
      process.send(ready, address)
      borrowed_loop(address)
    })
  let assert Ok(address) = process.receive(ready, 2000)
  Borrowed(address, owner)
}

fn ping(borrowed: Borrowed) -> Result(Nil, Nil) {
  let reply = process.new_subject()
  process.send(borrowed.address, reply)
  process.receive(reply, 200)
}

type NativeContext {
  NativeContext(mailbox: process.Subject(Nil), borrowed: Borrowed)
}

pub type LifetimeObservation {
  LifetimeObservation(
    callback_owner_is_caller: Bool,
    owner_alive_during_handler: Bool,
    borrowed_usable_during_handler: Bool,
    response: Result(Int, Nil),
    owner_stopped_after_response: Bool,
    borrowed_usable_after_response: Bool,
  )
}

pub fn resource_lifetime(carrier: probe.Carrier) -> LifetimeObservation {
  let borrowed = borrowed()
  use <- probe.with_cleanup(_, fn() { probe.stop_process(borrowed.owner) })
  let handler_entered = process.new_subject()
  let tool =
    tool.define("whoami", codec.success(Nil), codec.string())
    |> tool.handle_call(fn(call, _) {
      let context: NativeContext = tool.context(call)
      let assert Ok(owner) = process.subject_owner(context.mailbox)
      let release = process.new_subject()
      process.send(handler_entered, #(owner, release, ping(context.borrowed)))
      process.receive_forever(release)
      Ok(tool.complete("acme"))
    })
  let endpoint =
    probe.start(
      http.new_with_context(server.new([tool]), fn(_) {
        Ok(NativeContext(process.new_subject(), borrowed))
      })
        |> http.with_request_timeout(duration.seconds(2)),
      carrier,
    )
  use <- probe.with_cleanup(_, fn() { http.stop(endpoint) })
  let replies = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(replies, probe.send(endpoint, carrier, probe.call(False)))
    })
  use <- probe.with_cleanup(_, fn() { probe.stop_process(caller) })
  let assert Ok(#(owner, release, during)) =
    process.receive(handler_entered, 2000)
  let alive = process.is_alive(owner)
  process.send(release, Nil)
  let response = process.receive(replies, 2000)
  let stopped = probe.wait_stopped(owner, 200)
  LifetimeObservation(
    owner == caller,
    alive,
    during == Ok(Nil),
    response,
    stopped,
    ping(borrowed) == Ok(Nil),
  )
}

pub type Stop {
  EndpointStop
  CallerDeath
}

pub type ShutdownObservation {
  ShutdownObservation(
    callback_stopped: Bool,
    borrowed_usable: Bool,
    dispatched: Result(Nil, Nil),
  )
}

pub fn shutdown(stop: Stop) -> ShutdownObservation {
  let borrowed = borrowed()
  use <- probe.with_cleanup(_, fn() { probe.stop_process(borrowed.owner) })
  let entered = process.new_subject()
  let dispatched = process.new_subject()
  let tool =
    tool.define("whoami", codec.success(Nil), codec.string())
    |> tool.handle(fn(_) {
      process.send(dispatched, Nil)
      Ok("acme")
    })
  let endpoint =
    probe.start(
      http.new_with_context(server.new([tool]), fn(_) {
        hold(entered)
        Ok(borrowed)
      })
        |> http.with_request_timeout(duration.seconds(5))
        |> http.with_cancellation_grace(duration.milliseconds(20)),
      probe.Buffered,
    )
  use <- probe.with_cleanup(_, fn() { http.stop(endpoint) })
  let caller =
    process.spawn_unlinked(fn() {
      let _ = http.handle(endpoint, probe.call(False))
      Nil
    })
  use <- probe.with_cleanup(_, fn() { probe.stop_process(caller) })
  let assert Ok(entry) = process.receive(entered, 2000)
  use <- probe.with_cleanup(_, fn() { probe.stop_process(entry.owner) })
  // Observe termination independently of the stop call returning. A blocking
  // stop implementation must not conceal callback work exceeding its grace.
  let stopper =
    process.spawn_unlinked(fn() {
      case stop {
        EndpointStop -> http.stop(endpoint)
        CallerDeath -> probe.stop_process(caller)
      }
    })
  use <- probe.with_cleanup(_, fn() { probe.stop_process(stopper) })
  let stopped = probe.wait_stopped(entry.owner, 200)
  process.send(entry.release, Nil)
  ShutdownObservation(
    stopped,
    ping(borrowed) == Ok(Nil),
    process.receive(dispatched, 100),
  )
}

pub type PanicObservation {
  PanicObservation(
    response: Result(Int, Nil),
    caller_alive: Bool,
    recovery: Int,
  )
}

pub fn callback_panic() -> PanicObservation {
  let endpoint =
    probe.start(
      http.new_with_context(server.new([]), fn(req) {
        case request.get_header(req, "authorization") {
          Ok("Bearer blocked") -> panic as "scripted admission failure"
          _ -> Ok(Nil)
        }
      }),
      probe.Buffered,
    )
  use <- probe.with_cleanup(_, fn() { http.stop(endpoint) })
  let replies = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(replies, http.handle(endpoint, probe.call(True)).status)
      process.sleep_forever()
    })
  use <- probe.with_cleanup(_, fn() { probe.stop_process(caller) })
  let response = process.receive(replies, 200)
  PanicObservation(
    response,
    process.is_alive(caller),
    http.handle(endpoint, testing.request("tools/list", [])).status,
  )
}

pub type PolicyObservation {
  PolicyObservation(
    response_before_release: Result(Int, Nil),
    dispatched: Result(Nil, Nil),
  )
}

/// Policy entry is acknowledged, then returns success only after the response
/// deadline. Cancellation authority must survive this late positive decision.
pub fn delayed_policy() -> PolicyObservation {
  let entered = process.new_subject()
  let dispatched = process.new_subject()
  let tool =
    tool.define("whoami", codec.success(Nil), codec.string())
    |> tool.handle(fn(_) {
      process.send(dispatched, Nil)
      Ok("acme")
    })
  let service =
    server.new([tool])
    |> server.with_tool_access(visible: fn(_, _) { True }, callable: fn(_, _) {
      hold(entered)
      True
    })
  let endpoint =
    probe.start(
      http.new(service)
        |> http.with_request_timeout(duration.milliseconds(40))
        |> http.with_cancellation_grace(duration.milliseconds(500)),
      probe.Buffered,
    )
  use <- probe.with_cleanup(_, fn() { http.stop(endpoint) })
  let replies = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(replies, http.handle(endpoint, probe.call(False)).status)
    })
  use <- probe.with_cleanup(_, fn() { probe.stop_process(caller) })
  let assert Ok(entry) = process.receive(entered, 2000)
  let response = process.receive(replies, 200)
  process.send(entry.release, Nil)
  PolicyObservation(response, process.receive(dispatched, 200))
}
