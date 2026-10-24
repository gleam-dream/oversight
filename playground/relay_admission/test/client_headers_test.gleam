import admission_probe
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/cancellation
import http_gun/config as gun_config
import http_gun/deadline
import http_gun/destination
import json/blueprint/codec
import relay/client
import relay/http
import relay/server
import relay/subscriptions
import relay/tool

type Input {
  Input(name: String)
}

type Entered {
  Entered(pid: process.Pid, release: process.Subject(Nil))
}

@external(erlang, "client_peer_fixture", "start")
fn wire_peer(mode: String, closed: fn(Bool) -> Nil) -> #(process.Pid, Int)

fn definition() -> tool.Definition(Input, String) {
  let input = {
    use name <- codec.field("name", codec.string(), get: fn(value: Input) {
      value.name
    })
    codec.success(Input(name))
  }
  tool.define("greet", input, codec.string())
}

pub fn relative_timeout_stops_blocked_headers_before_dispatch_test() {
  use #(_, config, dispatched) <- fixture
  assert_blocked(
    config |> client.with_timeout(duration.seconds(1)),
    fn(peer) { peer },
    fn(_) { Nil },
    dispatched,
    client.TimedOut(client.NotSent),
  )
}

fn fixture(
  run: fn(#(http.Handler(Nil), client.Config, process.Subject(String))) -> a,
) -> a {
  let dispatched = process.new_subject()
  let service =
    server.new([
      tool.handle(definition(), fn(input) {
        process.send(dispatched, input.name)
        Ok("hello " <> input.name)
      }),
    ])
  use #(endpoint, config) <- with_service(service)
  run(#(endpoint, config, dispatched))
}

fn with_service(
  service: server.Server(Nil),
  run: fn(#(http.Handler(Nil), client.Config)) -> a,
) -> a {
  let assert Ok(endpoint) = http.start(http.new(service))
  use <- admission_probe.with_cleanup(_, fn() { http.stop(endpoint) })
  let url = "http://127.0.0.1:" <> int.to_string(http.port(endpoint)) <> "/"
  let assert Ok(config) = client.http(url)
  run(#(endpoint, config))
}

fn hold(entered: process.Subject(Entered)) -> List(#(String, String)) {
  let release = process.new_subject()
  process.send(entered, Entered(process.self(), release))
  process.receive_forever(release)
  []
}

fn assert_blocked(
  config: client.Config,
  view: fn(client.Client) -> client.Client,
  after_entry: fn(client.Client) -> Nil,
  dispatched: process.Subject(String),
  expected: client.Reason,
) {
  let entered = process.new_subject()
  let assert Ok(peer) =
    config
    |> client.with_headers(fn() { hold(entered) })
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let result = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(result, client.call(view(peer), definition(), Input("Ada")))
    })
  use <-
    admission_probe.with_cleanup(_, fn() {
      admission_probe.stop_process(caller)
    })
  let assert Ok(Entered(callback, release)) = process.receive(entered, 3000)
  after_entry(peer)
  // The one-second operation budget expires while the callback is blocked.
  // Three seconds is a harness failure bound, not an execution threshold.
  let before_release = process.receive(result, 3000)
  let stopped = admission_probe.wait_stopped(callback, 1000)
  process.send(release, Nil)
  let after_release = process.receive(dispatched, 250)
  let assert Ok(Error(failure)) = before_release
  client.reason(failure) |> should.equal(expected)
  stopped |> should.be_true
  after_release |> should.equal(Error(Nil))
}

pub fn absolute_deadline_stops_blocked_headers_test() {
  use #(_, config, dispatched) <- fixture
  assert_blocked(
    config,
    fn(peer) { client.with_deadline(peer, deadline.after(duration.seconds(1))) },
    fn(_) { Nil },
    dispatched,
    client.TimedOut(client.NotSent),
  )
}

pub fn cancellation_stops_blocked_headers_without_dispatch_test() {
  use #(_, config, dispatched) <- fixture
  use token <- cancellation.with_token
  assert_blocked(
    config,
    fn(peer) { client.with_cancellation(peer, token) },
    fn(_) { cancellation.cancel(token) },
    dispatched,
    client.Cancelled(client.NotSent),
  )
}

pub fn owned_client_close_stops_blocked_headers_test() {
  use #(_, config, dispatched) <- fixture
  assert_blocked(
    config,
    fn(peer) { peer },
    client.close,
    dispatched,
    client.Cancelled(client.NotSent),
  )
}

pub fn caller_exit_stops_blocked_headers_without_dispatch_test() {
  use #(_, config, dispatched) <- fixture
  let entered = process.new_subject()
  let assert Ok(peer) =
    config
    |> client.with_headers(fn() { hold(entered) })
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let caller =
    process.spawn_unlinked(fn() {
      client.call(peer, definition(), Input("Ada"))
    })
  use <-
    admission_probe.with_cleanup(_, fn() {
      admission_probe.stop_process(caller)
    })
  let assert Ok(Entered(callback, release)) = process.receive(entered, 3000)
  admission_probe.stop_process(caller)
  admission_probe.wait_stopped(callback, 1000) |> should.be_true
  process.send(release, Nil)
  process.receive(dispatched, 250) |> should.equal(Error(Nil))
}

pub fn callback_crash_is_sanitized_and_borrowed_client_recovers_test() {
  use #(_, config, dispatched) <- fixture
  let assert Ok(gun) =
    http_gun.start(
      gun_config.default()
      |> gun_config.with_destination(destination.loopback_only()),
    )
  use <- admission_probe.with_cleanup(_, fn() { http_gun.stop(gun) })
  let assert Ok(peer) =
    config
    |> client.with_http_client(gun)
    |> client.with_headers(fn() { panic as "credential-shaped-secret" })
    |> client.connect
  let assert Error(failure) = client.call(peer, definition(), Input("Ada"))
  client.close(peer)
  client.reason(failure) |> should.equal(client.InvalidConfig(client.Headers))
  string.contains(client.describe_error(failure), "credential-shaped-secret")
  |> should.be_false
  process.receive(dispatched, 0) |> should.equal(Error(Nil))
  let assert Ok(recovered) =
    config
    |> client.with_http_client(gun)
    |> client.with_headers(fn() { [] })
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(recovered) })
  let assert Ok(client.Succeeded("hello Ada", _)) =
    client.call(recovered, definition(), Input("Ada"))
}

fn borrowed(run: fn(http_gun.Client) -> a) -> a {
  let assert Ok(gun) =
    http_gun.start(
      gun_config.default()
      |> gun_config.with_destination(destination.loopback_only())
      |> gun_config.with_max_open_bodies(1),
    )
  use <- admission_probe.with_cleanup(_, fn() { http_gun.stop(gun) })
  run(gun)
}

pub fn subscription_survives_opening_budget_and_keeps_cancellation_test() {
  use #(endpoint, config, _) <- fixture
  use token <- cancellation.with_token
  let assert Ok(peer) =
    config
    |> client.with_timeout(duration.seconds(1))
    |> client.with_headers(fn() { [] })
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let assert Ok(subscription) =
    peer
    |> client.with_cancellation(token)
    |> client.listen([subscriptions.ToolsListChanged])
  use <-
    admission_probe.with_cleanup(_, fn() {
      client.close_subscription(subscription)
    })
  // Reading with no notifications deliberately crosses the opening deadline.
  client.next_notification(subscription, duration.milliseconds(1200))
  |> should.equal(Ok(None))
  http.notify(endpoint, subscriptions.ToolsListChanged)
  client.next_notification(subscription, duration.seconds(1))
  |> should.equal(Ok(Some(subscriptions.ToolsListChanged)))
  cancellation.cancel(token)
  let assert Error(error) =
    client.next_notification(subscription, duration.seconds(1))
  client.reason(error) |> should.equal(client.Cancelled(client.MaybeSent))
}

pub fn subscription_keeps_explicit_absolute_deadline_test() {
  use #(_, config, _) <- fixture
  let assert Ok(peer) =
    config
    |> client.with_headers(fn() { [] })
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let assert Ok(subscription) =
    peer
    |> client.with_deadline(deadline.after(duration.seconds(1)))
    |> client.listen([subscriptions.ToolsListChanged])
  use <-
    admission_probe.with_cleanup(_, fn() {
      client.close_subscription(subscription)
    })
  let assert Error(error) =
    client.next_notification(subscription, duration.seconds(2))
  client.reason(error) |> should.equal(client.TimedOut(client.MaybeSent))
}

pub fn borrowed_client_cancellation_survives_relay_owner_test() {
  let entered = process.new_subject()
  let service =
    server.new([
      tool.handle(definition(), fn(input) {
        let release = process.new_subject()
        process.send(entered, release)
        process.receive_forever(release)
        Ok(input.name)
      }),
    ])
  use #(_, config) <- with_service(service)
  use gun <- borrowed
  use token <- cancellation.with_token
  let assert Ok(peer) =
    config
    |> client.with_http_client(http_gun.with_cancellation(gun, token))
    |> client.with_headers(fn() { [] })
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let answer = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(answer, client.call(peer, definition(), Input("Ada")))
    })
  use <-
    admission_probe.with_cleanup(_, fn() {
      admission_probe.stop_process(caller)
    })
  let assert Ok(release) = process.receive(entered, 3000)
  cancellation.cancel(token)
  let result = process.receive(answer, 2000)
  process.send(release, Nil)
  let assert Ok(Error(error)) = result
  client.reason(error) |> should.equal(client.Cancelled(client.MaybeSent))
}

pub fn request_timeout_does_not_cancel_borrowed_token_or_client_test() {
  use #(_, config, dispatched) <- fixture
  use gun <- borrowed
  use token <- cancellation.with_token
  let base =
    config |> client.with_http_client(http_gun.with_cancellation(gun, token))
  assert_blocked(
    base |> client.with_timeout(duration.seconds(1)),
    fn(peer) { peer },
    // Borrowed close preserves active request ownership, as documented.
    client.close,
    dispatched,
    client.TimedOut(client.NotSent),
  )
  cancellation.is_cancelled(token) |> should.be_false
  let assert Ok(peer) = client.connect(base)
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let assert Ok(client.Succeeded("hello Ada", _)) =
    client.call(peer, definition(), Input("Ada"))
}

pub fn headers_and_transport_share_one_budget_test() {
  let called = process.new_subject()
  let service =
    server.new([
      tool.handle(definition(), fn(input) {
        let release = process.new_subject()
        process.send(called, release)
        process.receive_forever(release)
        Ok(input.name)
      }),
    ])
  use #(_, config) <- with_service(service)
  let headers = process.new_subject()
  let assert Ok(peer) =
    config
    |> client.with_timeout(duration.seconds(3))
    |> client.with_headers(fn() { hold(headers) })
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let answer = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(answer, client.call(peer, definition(), Input("Ada")))
    })
  use <-
    admission_probe.with_cleanup(_, fn() {
      admission_probe.stop_process(caller)
    })
  let assert Ok(Entered(_, release_headers)) = process.receive(headers, 1000)
  // Consume two seconds of the three-second budget after observed entry.
  // The timer controls elapsed budget, not callback ordering.
  let _ = process.send_after(release_headers, 2000, Nil)
  let assert Ok(release_tool) = process.receive(called, 3000)
  let outcome = process.receive(answer, 1500)
  process.send(release_tool, Nil)
  let assert Ok(Error(error)) = outcome
  client.reason(error) |> should.equal(client.TimedOut(client.MaybeSent))
}

pub fn subscription_header_acquisition_uses_opening_budget_test() {
  use #(_, config, _) <- fixture
  let entered = process.new_subject()
  let assert Ok(peer) =
    config
    |> client.with_timeout(duration.seconds(1))
    |> client.with_headers(fn() { hold(entered) })
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let result = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(
        result,
        client.listen(peer, [subscriptions.ToolsListChanged]),
      )
    })
  use <-
    admission_probe.with_cleanup(_, fn() {
      admission_probe.stop_process(caller)
    })
  let assert Ok(Entered(callback, release)) = process.receive(entered, 1000)
  let outcome = process.receive(result, 2000)
  process.send(release, Nil)
  let assert Ok(Error(error)) = outcome
  client.reason(error) |> should.equal(client.TimedOut(client.NotSent))
  admission_probe.wait_stopped(callback, 1000) |> should.be_true
}

fn with_wire_peer(
  mode: String,
  run: fn(client.Client, process.Subject(Bool)) -> a,
) -> a {
  let closed = process.new_subject()
  let #(server, port) =
    wire_peer(mode, fn(result) { process.send(closed, result) })
  use <-
    admission_probe.with_cleanup(_, fn() {
      admission_probe.stop_process(server)
    })
  let assert Ok(config) =
    client.http("http://127.0.0.1:" <> int.to_string(port) <> "/")
  let assert Ok(peer) =
    config
    |> client.with_timeout(duration.seconds(1))
    |> client.with_headers(fn() { [] })
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  run(peer, closed)
}

pub fn subscription_http_headers_are_inside_opening_budget_test() {
  use peer, closed <- with_wire_peer("headers")
  let assert Error(error) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  client.reason(error) |> should.equal(client.TimedOut(client.MaybeSent))
  process.receive(closed, 1000) |> should.equal(Ok(True))
}

pub fn subscription_acknowledgement_is_inside_opening_budget_test() {
  use peer, closed <- with_wire_peer("ack")
  let assert Error(error) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  client.reason(error) |> should.equal(client.TimedOut(client.MaybeSent))
  process.receive(closed, 1000) |> should.equal(Ok(True))
}

pub fn malformed_notification_closes_the_owned_stream_test() {
  use peer, closed <- with_wire_peer("malformed")
  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  use <-
    admission_probe.with_cleanup(_, fn() {
      client.close_subscription(subscription)
    })
  let assert Error(error) =
    client.next_notification(subscription, duration.seconds(1))
  client.kind(error) |> should.equal(client.Protocol)
  // A terminal protocol error must close the socket without an explicit close.
  process.receive(closed, 1000) |> should.equal(Ok(True))
}

pub fn repeated_cancelled_acquisition_releases_workers_and_preserves_pool_test() {
  use #(_, config, dispatched) <- fixture
  use gun <- borrowed
  let config = client.with_http_client(config, gun)
  list.each([1, 2, 3, 4, 5], fn(_) {
    use token <- cancellation.with_token
    assert_blocked(
      config,
      fn(peer) { client.with_cancellation(peer, token) },
      fn(_) { cancellation.cancel(token) },
      dispatched,
      client.Cancelled(client.NotSent),
    )
  })
  let assert Ok(peer) = client.connect(config)
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let assert Ok(client.Succeeded("hello Ada", _)) =
    client.call(peer, definition(), Input("Ada"))
}

pub fn relative_relay_budget_preserves_borrowed_absolute_deadline_test() {
  let called = process.new_subject()
  let service =
    server.new([
      tool.handle(definition(), fn(input) {
        let release = process.new_subject()
        process.send(called, release)
        process.receive_forever(release)
        Ok(input.name)
      }),
    ])
  use #(_, config) <- with_service(service)
  use gun <- borrowed
  let gun = http_gun.with_deadline(gun, deadline.after(duration.seconds(1)))
  let assert Ok(peer) =
    config
    |> client.with_http_client(gun)
    |> client.with_timeout(duration.seconds(10))
    |> client.with_headers(fn() { [] })
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let answer = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(answer, client.call(peer, definition(), Input("Ada")))
    })
  use <-
    admission_probe.with_cleanup(_, fn() {
      admission_probe.stop_process(caller)
    })
  let assert Ok(release) = process.receive(called, 1000)
  let result = process.receive(answer, 2000)
  process.send(release, Nil)
  let assert Ok(Error(error)) = result
  client.reason(error) |> should.equal(client.TimedOut(client.MaybeSent))
}

fn assert_terminal_stream_releases_body(mode: String) {
  use #(_, ordinary, _) <- fixture
  use gun <- borrowed
  let #(server, port) = wire_peer(mode, fn(_) { Nil })
  use <-
    admission_probe.with_cleanup(_, fn() {
      admission_probe.stop_process(server)
    })
  let assert Ok(config) =
    client.http("http://127.0.0.1:" <> int.to_string(port) <> "/")
  let assert Ok(peer) =
    config
    |> client.with_http_client(gun)
    |> client.with_max_response_bytes(1024)
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(peer) })
  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  use <-
    admission_probe.with_cleanup(_, fn() {
      client.close_subscription(subscription)
    })
  let assert Error(_) =
    client.next_notification(subscription, duration.seconds(1))
  // The pool has exactly one body slot. A terminal stream error must release it
  // before this consumer explicitly closes the subscription in fixture cleanup.
  let assert Ok(recovered) =
    ordinary
    |> client.with_http_client(gun)
    |> client.with_timeout(duration.seconds(1))
    |> client.connect
  use <- admission_probe.with_cleanup(_, fn() { client.close(recovered) })
  let assert Ok(client.Succeeded("hello Ada", _)) =
    client.call(recovered, definition(), Input("Ada"))
}

pub fn subscription_eof_releases_borrowed_body_slot_test() {
  assert_terminal_stream_releases_body("eof")
}

pub fn oversized_subscription_event_releases_borrowed_body_slot_test() {
  assert_terminal_stream_releases_body("oversize")
}
