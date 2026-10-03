//// http_gun cassettes inside grind worker tests: the service's egress client
//// is a playback client, so the registered worker runs real attempts
//// offline.

import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/list
import gleam/option.{Some}
import grind
import grind/job
import http_gun
import http_gun/cassette
import http_gun/error
import http_gun/testing
import webhooks/attempt
import webhooks/egress
import webhooks/receiver
import webhooks/service
import webhooks/store
import webhooks/subscription.{PublicTier}
import webhooks/support

const sub_id = "sub_tape"

fn event(id: String) -> String {
  "{\"tenant\":\"acme\",\"type\":\"invoice.paid\",\"id\":\""
  <> id
  <> "\",\"data\":{}}"
}

/// The request the worker must send, written out independently of
/// `delivery.build_request`. The timestamp and signature change every
/// second, so the script leaves them out of matching (`unsigned`).
fn expected(event_id: String) -> Request(BitArray) {
  let body = event(event_id)
  request.new()
  |> request.set_method(http.Post)
  |> request.set_host("hooks.acme.test")
  |> request.set_path("/hook")
  |> request.set_body(<<body:utf8>>)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("user-agent", "gleam-dream-webhooks/0.1")
  |> request.set_header("webhook-event-type", "invoice.paid")
  |> request.set_header("webhook-id", event_id <> ":" <> sub_id)
}

fn unsigned(script: testing.Script) -> testing.Script {
  testing.ignoring_headers(script, ["webhook-timestamp", "webhook-signature"])
}

fn answer(
  status: Int,
  headers: List(#(String, String)),
  body: BitArray,
) -> testing.Reply {
  let resp =
    list.fold(headers, response.new(status), fn(r, h) {
      response.set_header(r, h.0, h.1)
    })
  testing.Respond(response.set_body(resp, [body]), testing.Finished([]))
}

/// A service whose egress client plays `script` back.
fn with_tape(script: testing.Script, run: fn(service.Service) -> a) -> a {
  let options = support.options()
  let settings =
    egress.Settings(..options.egress, start_client: testing.playback(script, _))
  use svc <- support.with_service(service.Options(..options, egress: settings))
  let assert Ok(Nil) =
    store.insert_subscription(
      svc.db,
      subscription.Subscription(
        id: sub_id,
        tenant: "acme",
        url: "https://hooks.acme.test/hook",
        secret: "whsec_tape",
        status: subscription.Active,
      ),
    )
  run(svc)
}

pub fn cassette_drives_snooze_discard_and_body_limit_test() {
  let exchanges = [
    testing.exchange(
      expected("evt_1"),
      answer(429, [#("retry-after", "120")], <<>>),
    ),
    testing.exchange(expected("evt_2"), answer(200, [], receiver.big_body())),
    testing.exchange(expected("evt_3"), answer(410, [], <<"gone":utf8>>)),
  ]
  // Through the serialized cassette format, as if loaded from disk.
  let assert Ok(tape) =
    cassette.parse(cassette.encode(testing.script(exchanges)), 1_048_576)
  use svc <- with_tape(unsigned(tape))

  let assert [#(_, rate_limited)] = support.publish(svc, event("evt_1"))
  let assert [#(_, big)] = support.publish(svc, event("evt_2"))
  let assert [#(_, gone)] = support.publish(svc, event("evt_3"))
  // The 429 snoozes for Retry-After (120 s), so it is not due again.
  assert support.drain(svc) == Ok(3)

  assert support.outcome(svc, rate_limited) == Ok(grind.Pending(job.Scheduled))
  // WHK-3: the oversized body fails with the 200 it belonged to, so the
  // delivery is not retried.
  assert support.outcome(svc, big)
    == Ok(
      grind.Succeeded(attempt.Receipt(
        200,
        attempt.BodyIncomplete("limit_exceeded.response_body_bytes"),
      )),
    )
  assert support.outcome(svc, gone)
    == Ok(grind.Discarded("receiver answered 410 Gone"))
  let assert Ok(subscription.Subscription(status: subscription.Disabled(_), ..)) =
    store.get_subscription(svc.db, sub_id)

  // The same exchange through http_gun directly: `Fail` keeps the status on
  // the failure; `Truncate` returns the head and the first 1024 bytes.
  let big_tape = fn(overflow) {
    let assert Ok(client) =
      testing.playback(
        testing.script([
          testing.exchange(
            expected("evt_2"),
            answer(200, [], receiver.big_body()),
          ),
        ]),
        egress.config(egress.default_settings()),
      )
    egress.client_for(egress.Egress(client, []), PublicTier)
    |> http_gun.with_body_limit(1024, overflow)
  }
  let assert Error(failure) =
    http_gun.send(big_tape(http_gun.Fail), expected("evt_2"))
  let assert error.LimitExceeded(error.ResponseBodyBytes, 1024, _) =
    error.reason(failure)
  assert error.status(failure) == Some(200)
  let assert Ok(http_gun.Buffered(response:, truncated: True, ..)) =
    http_gun.send(big_tape(http_gun.Truncate), expected("evt_2"))
  assert response.status == 200
  Nil
}

/// A 429 whose body is over the limit fails with its status, and the failure
/// keeps `Retry-After`: the delivery snoozes for the receiver's 120 s, not
/// the 60 s default.
pub fn oversized_429_keeps_retry_after_test() {
  let script =
    testing.script([
      testing.exchange(
        expected("evt_big429"),
        answer(429, [#("retry-after", "120")], receiver.big_body()),
      ),
    ])
  let assert Ok(client) =
    testing.playback(script, egress.config(egress.default_settings()))
  let assert Error(failure) =
    egress.client_for(egress.Egress(client, []), PublicTier)
    |> http_gun.with_body_limit(1024, http_gun.Fail)
    |> http_gun.send(expected("evt_big429"))
  assert error.status(failure) == Some(429)
  assert list.key_find(error.headers(failure), "retry-after") == Ok("120")
  let assert attempt.Snooze(120_000, _) =
    attempt.classify(Error(failure), attempt.default_snooze(), 0)
  Nil
}

/// The egress client refuses any request that skips the tenant view, so a
/// call that forgets `egress.client_for` fails instead of reaching loopback.
pub fn request_without_tenant_view_is_refused_test() {
  use svc <- with_tape(unsigned(testing.script([])))
  let loopback =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_scheme(http.Http)
    |> request.set_host("127.0.0.1")
    |> request.set_port(8080)
    |> request.set_body(<<"{}":utf8>>)
  let assert Error(failure) = http_gun.send(svc.egress.client, loopback)
  assert error.reason(failure) == error.ViewDestinationRequired
  assert error.evidence(failure) == error.NotSent
  assert error.kind(failure) == error.Refused
  assert error.is_retryable(failure, idempotent: True) == False
  // Through the tenant's view the request gets past that check (a playback
  // client then has no exchange for it).
  let assert Error(failure) =
    http_gun.send(egress.client_for(svc.egress, PublicTier), loopback)
  assert error.reason(failure) != error.ViewDestinationRequired
  Nil
}

/// WHK-1: a 429 snoozes a worker that has an error codec; the job stays
/// bindable while scheduled, runs again, and the second exchange delivers.
pub fn snooze_with_error_codec_runs_again_test() {
  let tape =
    testing.script([
      testing.exchange(
        expected("evt_s"),
        answer(429, [#("retry-after", "0")], <<>>),
      ),
      testing.exchange(expected("evt_s"), answer(204, [], <<>>)),
    ])
    |> unsigned
  use svc <- with_tape(tape)
  let assert [#(delivery_id, job_id)] = support.publish(svc, event("evt_s"))
  assert support.drain_up_to(svc, 1) == Ok(1)
  assert support.outcome(svc, job_id) == Ok(grind.Pending(job.Scheduled))
  assert support.drain(svc) == Ok(1)

  assert support.outcome(svc, job_id)
    == Ok(grind.Succeeded(attempt.Receipt(204, attempt.BodyRead(0))))
  let assert Ok(row) = store.get_delivery(svc.db, delivery_id)
  assert row.attempts == 2
  // Both exchanges were consumed.
  let assert Error(failure) =
    http_gun.send(egress.client_for(svc.egress, PublicTier), expected("evt_s"))
  assert error.reason(failure) == error.PlaybackExhausted
  Nil
}
