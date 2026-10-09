//// Separate consumer of Relay's public API. Barriers establish callback entry
//// before timeout observations. Every owned process/socket has fixture cleanup.

import gleam/erlang/process
import gleam/http/request
import gleam/json
import gleam/time/duration
import json/blueprint/codec
import relay/authorization
import relay/http
import relay/server
import relay/testing
import relay/tool

pub type Carrier {
  Buffered
  Listener
}

pub type Admission {
  Context
  Verification
}

pub type AppContext {
  AppContext(tenant: String)
}

type Entry {
  Entry(release: process.Subject(Nil), owner: process.Pid, child: process.Pid)
}

pub type Observation {
  Observation(
    before_release: Result(Int, Nil),
    capacity_before_release: Int,
    after_release: Result(Int, Nil),
    capacity_after_release: Int,
    dispatched: Result(String, Nil),
    callback_runs_in_caller: Bool,
    subject_owned_by_callback: Bool,
    child_alive_past_deadline: Bool,
    child_alive_after_response: Bool,
  )
}

@external(erlang, "admission_fixture", "with_cleanup")
pub fn with_cleanup(work: fn() -> a, cleanup: fn() -> Nil) -> a

@external(erlang, "admission_fixture", "stop_process")
pub fn stop_process(pid: process.Pid) -> Nil

@external(erlang, "admission_fixture", "wait_stopped")
pub fn wait_stopped(pid: process.Pid, timeout: Int) -> Bool

@external(erlang, "admission_fixture", "monotonic_milliseconds")
fn monotonic_milliseconds() -> Int

type Socket

@external(erlang, "admission_fixture", "open_request")
fn open_request(
  port: Int,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Socket, String)

@external(erlang, "admission_fixture", "read_status")
fn read_status(socket: Socket) -> Result(Int, String)

@external(erlang, "admission_fixture", "close")
fn close(socket: Socket) -> Nil

pub fn call(block: Bool) -> request.Request(BitArray) {
  testing.request("tools/call", [
    #("name", json.string("whoami")),
    #("arguments", json.object([])),
  ])
  |> authorize(block)
}

fn authorize(
  req: request.Request(BitArray),
  block: Bool,
) -> request.Request(BitArray) {
  let token = case block {
    True -> "blocked"
    False -> "accepted"
  }
  req
  |> request.set_header("accept", "application/json")
  |> request.set_header("authorization", "Bearer " <> token)
}

fn hold(entered: process.Subject(Entry)) -> Nil {
  let release = process.new_subject()
  let child = process.spawn(fn() { process.sleep_forever() })
  process.send(entered, Entry(release, process.self(), child))
  process.receive_forever(release)
}

fn config(
  admission: Admission,
  entered: process.Subject(Entry),
  dispatched: process.Subject(String),
) -> http.Config(AppContext) {
  let tool =
    tool.define("whoami", codec.success(Nil), codec.string())
    |> tool.handle_call(fn(call, _) {
      let AppContext(tenant) = tool.context(call)
      process.send(dispatched, tenant)
      Ok(tool.complete(tenant))
    })
  let server = server.new([tool])
  let config = case admission {
    Context ->
      http.new_with_context(server, fn(request) {
        case request.get_header(request, "authorization") {
          Ok("Bearer blocked") -> hold(entered)
          _ -> Nil
        }
        Ok(AppContext("acme"))
      })
    Verification -> {
      let assert Ok(resource) =
        authorization.protected_resource("https://mcp.example.test/")
      let verifier =
        authorization.verifier("scripted", fn(token, _) {
          case authorization.token_value(token) {
            "blocked" -> hold(entered)
            _ -> Nil
          }
          case authorization.token_value(token) {
            "blocked" | "accepted" ->
              Ok(
                authorization.attestation(
                  AppContext("acme"),
                  [authorization.resource_uri(resource)],
                  [],
                ),
              )
            _ -> Error(authorization.BearerRejected)
          }
        })
      http.new_protected(
        server,
        verifier,
        authorization.protection(resource, []),
        fn(_, grant) { Ok(authorization.grant_principal(grant)) },
      )
    }
  }
  config
  |> http.with_request_timeout(duration.milliseconds(120))
  |> http.with_cancellation_grace(duration.milliseconds(20))
  |> http.with_max_concurrent_requests(1)
}

pub fn start(config: http.Config(a), carrier: Carrier) -> http.Handler(a) {
  let result = case carrier {
    Buffered -> http.handler(config)
    Listener -> http.start(config)
  }
  let assert Ok(endpoint) = result
  endpoint
}

pub fn send(
  endpoint: http.Handler(a),
  carrier: Carrier,
  req: request.Request(BitArray),
) -> Int {
  case carrier {
    Buffered -> http.handle(endpoint, req).status
    Listener -> {
      let assert Ok(socket) =
        open_request(http.port(endpoint), req.headers, req.body)
      use <- with_cleanup(_, fn() { close(socket) })
      let assert Ok(status) = read_status(socket)
      status
    }
  }
}

// Callback DOWN does not acknowledge termination of all request-owned work or
// the endpoint's slot release. Poll only overload refusal within a fixed window;
// a timeout or any other response remains visible to the assertion.
fn recovered_capacity(endpoint: http.Handler(a), carrier: Carrier) -> Int {
  capacity_until(endpoint, carrier, monotonic_milliseconds() + 200)
}

fn capacity_until(
  endpoint: http.Handler(a),
  carrier: Carrier,
  deadline: Int,
) -> Int {
  let status =
    send(
      endpoint,
      carrier,
      testing.request("tools/list", []) |> authorize(False),
    )
  case status == 503 && monotonic_milliseconds() < deadline {
    True -> {
      process.sleep(5)
      capacity_until(endpoint, carrier, deadline)
    }
    False -> status
  }
}

/// Wait for cleanup before checking capacity; a timeout response does not
/// acknowledge termination. Assertions run after fixture cleanup even on failure.
pub fn blocked(admission: Admission, carrier: Carrier) -> Observation {
  let entered = process.new_subject()
  let dispatched = process.new_subject()
  let endpoint = start(config(admission, entered, dispatched), carrier)
  use <- with_cleanup(_, fn() { http.stop(endpoint) })
  let replies = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(replies, send(endpoint, carrier, call(True)))
    })
  use <- with_cleanup(_, fn() { stop_process(caller) })
  let assert Ok(entry) = process.receive(entered, 2000)
  use <-
    with_cleanup(_, fn() {
      stop_process(entry.child)
      stop_process(entry.owner)
    })
  let before = process.receive(replies, 400)
  let _ = wait_stopped(entry.owner, 200)
  let _ = wait_stopped(entry.child, 200)
  let child_alive = process.is_alive(entry.child)
  let busy = recovered_capacity(endpoint, carrier)
  process.send(entry.release, Nil)
  let after = case before {
    Ok(_) -> before
    Error(_) -> process.receive(replies, 2000)
  }
  let recovered = recovered_capacity(endpoint, carrier)
  Observation(
    before,
    busy,
    after,
    recovered,
    process.receive(dispatched, 200),
    entry.owner == caller,
    process.subject_owner(entry.release) == Ok(entry.owner),
    child_alive,
    process.is_alive(entry.child),
  )
}

/// Accepted native principal reaches the handler; a refused principal does not.
/// A subsequent accepted call demonstrates recovery on the same endpoint.
pub fn authorization_control(
  carrier: Carrier,
) -> #(Int, Int, Int, List(String)) {
  let entered = process.new_subject()
  let dispatched = process.new_subject()
  let endpoint =
    start(
      config(Verification, entered, dispatched)
        |> http.with_request_timeout(duration.seconds(1)),
      carrier,
    )
  use <- with_cleanup(_, fn() { http.stop(endpoint) })
  let accepted = send(endpoint, carrier, call(False))
  let refused =
    send(
      endpoint,
      carrier,
      call(False)
        |> request.set_header("authorization", "Bearer refused"),
    )
  let recovered = send(endpoint, carrier, call(False))
  let assert Ok(first) = process.receive(dispatched, 1000)
  let assert Ok(second) = process.receive(dispatched, 1000)
  let assert Error(Nil) = process.receive(dispatched, 0)
  #(accepted, refused, recovered, [first, second])
}

pub type DisconnectObservation {
  DisconnectObservation(
    capacity_while_disconnected: Int,
    callback_alive: Bool,
    child_alive: Bool,
    dispatched_after_release: Result(String, Nil),
  )
}

/// The client closes only after admission is known to be blocked.
pub fn disconnect(admission: Admission) -> DisconnectObservation {
  let entered = process.new_subject()
  let dispatched = process.new_subject()
  let endpoint =
    start(
      config(admission, entered, dispatched)
        |> http.with_request_timeout(duration.seconds(5)),
      Listener,
    )
  use <- with_cleanup(_, fn() { http.stop(endpoint) })
  let req = call(True)
  let assert Ok(socket) =
    open_request(http.port(endpoint), req.headers, req.body)
  use <- with_cleanup(_, fn() { close(socket) })
  let assert Ok(entry) = process.receive(entered, 2000)
  use <-
    with_cleanup(_, fn() {
      stop_process(entry.child)
      stop_process(entry.owner)
    })
  close(socket)
  let _ = wait_stopped(entry.owner, 200)
  let _ = wait_stopped(entry.child, 200)
  // Observe dispatch absence after the established close and bounded cleanup.
  let assert Error(Nil) = process.receive(dispatched, 200)
  let busy = recovered_capacity(endpoint, Listener)
  let owner_alive = process.is_alive(entry.owner)
  let child_alive = process.is_alive(entry.child)
  process.send(entry.release, Nil)
  DisconnectObservation(
    busy,
    owner_alive,
    child_alive,
    process.receive(dispatched, 200),
  )
}

pub type BudgetObservation {
  BudgetObservation(
    before_handler_release: Result(Int, Nil),
    after_handler_release: Result(Int, Nil),
  )
}

/// A verifier uses 200 ms of a 600 ms budget, then a barrier-held handler is
/// observed for another 450 ms. A fresh dispatch budget incorrectly permits it.
pub fn shared_budget(carrier: Carrier) -> BudgetObservation {
  let verification_entered = process.new_subject()
  let handler_entered = process.new_subject()
  let tool =
    tool.define("whoami", codec.success(Nil), codec.string())
    |> tool.handle_call(fn(call, _) {
      let release = process.new_subject()
      process.send(handler_entered, release)
      let _ =
        process.new_selector()
        |> process.select(release)
        |> process.merge_selector(tool.cancelled(call))
        |> process.selector_receive(2000)
      Ok(tool.complete("acme"))
    })
  let assert Ok(resource) =
    authorization.protected_resource("https://mcp.example.test/")
  let verifier =
    authorization.verifier("shared-budget", fn(_, _) {
      hold(verification_entered)
      Ok(
        authorization.attestation(
          AppContext("acme"),
          [authorization.resource_uri(resource)],
          [],
        ),
      )
    })
  let endpoint =
    start(
      http.new_protected(
        server.new([tool]),
        verifier,
        authorization.protection(resource, []),
        fn(_, grant) { Ok(authorization.grant_principal(grant)) },
      )
        |> http.with_request_timeout(duration.milliseconds(600))
        |> http.with_cancellation_grace(duration.milliseconds(20)),
      carrier,
    )
  use <- with_cleanup(_, fn() { http.stop(endpoint) })
  let replies = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(replies, send(endpoint, carrier, call(False)))
    })
  use <- with_cleanup(_, fn() { stop_process(caller) })
  let assert Ok(entry) = process.receive(verification_entered, 2000)
  use <-
    with_cleanup(_, fn() {
      stop_process(entry.child)
      stop_process(entry.owner)
    })
  let assert Error(Nil) = process.receive(replies, 200)
  process.send(entry.release, Nil)
  let assert Ok(release_handler) = process.receive(handler_entered, 2000)
  let before = process.receive(replies, 450)
  process.send(release_handler, Nil)
  let after = case before {
    Ok(_) -> before
    Error(_) -> process.receive(replies, 2000)
  }
  BudgetObservation(before, after)
}

/// The ordinary task uses Relay defaults with no application context builder.
pub fn defaults() -> Int {
  let assert Ok(endpoint) = http.handler(http.new(server.new([])))
  use <- with_cleanup(_, fn() { http.stop(endpoint) })
  http.handle(endpoint, testing.request("tools/list", [])).status
}

pub type RetirementObservation {
  RetirementObservation(
    response: Result(Int, Nil),
    callback_alive_at_response: Bool,
    capacity_during_grace: Int,
    callback_stopped: Bool,
    capacity_after_termination: Int,
    dispatched: Result(String, Nil),
  )
}

/// A long cleanup grace separates response delivery from owned-work termination.
/// The callback remains behind its barrier until after both observations.
pub fn retirement() -> RetirementObservation {
  let entered = process.new_subject()
  let dispatched = process.new_subject()
  let endpoint =
    start(
      config(Context, entered, dispatched)
        |> http.with_cancellation_grace(duration.milliseconds(500)),
      Buffered,
    )
  use <- with_cleanup(_, fn() { http.stop(endpoint) })
  let replies = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(replies, send(endpoint, Buffered, call(True)))
    })
  use <- with_cleanup(_, fn() { stop_process(caller) })
  let assert Ok(entry) = process.receive(entered, 2000)
  use <-
    with_cleanup(_, fn() {
      stop_process(entry.child)
      stop_process(entry.owner)
    })
  let response = process.receive(replies, 400)
  let alive = process.is_alive(entry.owner)
  let busy =
    send(
      endpoint,
      Buffered,
      testing.request("tools/list", []) |> authorize(False),
    )
  let stopped = wait_stopped(entry.owner, 1000)
  let recovered = recovered_capacity(endpoint, Buffered)
  process.send(entry.release, Nil)
  RetirementObservation(
    response,
    alive,
    busy,
    stopped,
    recovered,
    process.receive(dispatched, 100),
  )
}

pub type LateAdmissionObservation {
  LateAdmissionObservation(
    response: Result(Int, Nil),
    callback_alive_on_release: Bool,
    dispatched: Result(String, Nil),
    callback_stopped: Bool,
    capacity_after_termination: Int,
  )
}

/// Let a still-live context callback return positively after expiry. This
/// distinguishes revoked dispatch authority from termination alone.
pub fn late_context_success() -> LateAdmissionObservation {
  let entered = process.new_subject()
  let dispatched = process.new_subject()
  let endpoint =
    start(
      config(Context, entered, dispatched)
        |> http.with_cancellation_grace(duration.milliseconds(500)),
      Buffered,
    )
  use <- with_cleanup(_, fn() { http.stop(endpoint) })
  let replies = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(replies, send(endpoint, Buffered, call(True)))
    })
  use <- with_cleanup(_, fn() { stop_process(caller) })
  let assert Ok(entry) = process.receive(entered, 2000)
  use <-
    with_cleanup(_, fn() {
      stop_process(entry.child)
      stop_process(entry.owner)
    })
  let response = process.receive(replies, 400)
  let alive = process.is_alive(entry.owner)
  process.send(entry.release, Nil)
  let stopped = wait_stopped(entry.owner, 1000)
  let capacity = recovered_capacity(endpoint, Buffered)
  LateAdmissionObservation(
    response,
    alive,
    process.receive(dispatched, 100),
    stopped,
    capacity,
  )
}
