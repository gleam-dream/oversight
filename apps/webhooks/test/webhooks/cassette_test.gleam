//// http_gun cassettes inside grind worker tests: the worker's deps hold a
//// playback client, so a real queue consumer runs real attempts offline.

import gleam/bit_array
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/list
import gleam/option.{Some}
import grind/job
import grind/queue
import http_gun
import http_gun/cassette
import http_gun/error
import http_gun/fixture
import http_gun/request_options
import webhooks/attempt
import webhooks/delivery
import webhooks/egress
import webhooks/receiver
import webhooks/service
import webhooks/signing
import webhooks/store
import webhooks/subscription
import webhooks/support

const now = 1_700_000_000

const sub_id = "sub_tape"

const secret = "whsec_tape"

fn event(id: String) -> String {
  "{\"tenant\":\"acme\",\"type\":\"invoice.paid\",\"id\":\""
  <> id
  <> "\",\"data\":{}}"
}

/// The request the worker must send, written out independently of
/// `delivery.build_request`. Playback matches it exactly (method, URL,
/// sorted headers, body), so the clock is fixed and the signature is stable.
fn expected(event_id: String) -> Request(BitArray) {
  let body = event(event_id)
  let id = event_id <> ":" <> sub_id
  request.new()
  |> request.set_method(http.Post)
  |> request.set_host("hooks.acme.test")
  |> request.set_path("/hook")
  |> request.set_body(<<body:utf8>>)
  |> request.set_header("content-type", "application/json")
  |> request.set_header("user-agent", "gleam-dream-webhooks/0.1")
  |> request.set_header("webhook-event-type", "invoice.paid")
  |> request.set_header("webhook-id", id)
  |> request.set_header("webhook-timestamp", "1700000000")
  |> request.set_header(
    "webhook-signature",
    signing.sign(secret, id, now, <<body:utf8>>),
  )
}

fn answer(
  status: Int,
  headers: List(#(String, String)),
  body: BitArray,
) -> fixture.Reply {
  let resp =
    list.fold(headers, response.new(status), fn(r, h) {
      response.set_header(r, h.0, h.1)
    })
  fixture.Respond(response.set_body(resp, [body]), fixture.Complete([]))
}

fn setup(svc: service.Service) -> Nil {
  let assert Ok(Nil) =
    store.insert_subscription(
      svc.db,
      subscription.Subscription(
        id: sub_id,
        tenant: "acme",
        url: "https://hooks.acme.test/hook",
        secret:,
        status: subscription.Active,
      ),
    )
  Nil
}

fn worker_with(svc: service.Service, tape: http_gun.Client) {
  delivery.worker(
    delivery.Deps(
      ..svc.deps,
      egress: egress.Egress(public: tape, internal: tape),
      max_response_bytes: 1024,
    ),
    delivery.Plan(max_attempts: 3, backoff: attempt.Backoff(0, 0)),
  )
}

fn options() -> service.Options {
  service.Options(..support.options(), clock: fn() { now })
}

pub fn cassette_drives_snooze_discard_and_body_limit_test() {
  use svc <- support.with_service(options())
  setup(svc)
  let exchanges = [
    fixture.Exchange(
      expected("evt_1"),
      answer(429, [#("retry-after", "120")], <<>>),
    ),
    fixture.Exchange(expected("evt_2"), answer(200, [], receiver.big_body())),
    fixture.Exchange(expected("evt_3"), answer(410, [], <<"gone":utf8>>)),
  ]
  // Through the serialized cassette format, as if loaded from disk.
  let assert Ok(tape) = cassette.new(exchanges)
  let assert Ok(tape) = cassette.parse(cassette.encode(tape), 1_048_576)
  let assert Ok(client) =
    cassette.playback(tape, egress.public_config(egress.default_settings()))

  let assert [#(_, rate_limited)] = support.publish(svc, event("evt_1"))
  let assert [#(_, big)] = support.publish(svc, event("evt_2"))
  let assert [#(_, gone)] = support.publish(svc, event("evt_3"))

  let consumer =
    service.start_consumer_with(
      svc,
      worker_with(svc, client),
      service.manual_policy(),
    )
  assert queue.process_one(consumer) == Ok(True)
  assert queue.process_one(consumer) == Ok(True)
  assert queue.process_one(consumer) == Ok(True)
  // The 429 snoozes for Retry-After (120 s), so nothing is due.
  assert queue.process_one(consumer) == Ok(False)
  let assert Ok(_) = queue.stop(consumer)

  assert support.outcome(svc, rate_limited) == Ok(job.Pending(job.Scheduled))
  // The oversized body does not hide the 200.
  assert support.outcome(svc, big)
    == Ok(job.SucceededWith(attempt.Receipt(200, attempt.BodyOverLimit(1024))))
  assert support.outcome(svc, gone)
    == Ok(job.DiscardedWithReason("receiver answered 410 Gone"))
  let assert Ok(subscription.Subscription(status: subscription.Disabled(_), ..)) =
    store.get_subscription(svc.db, sub_id)

  // The same exchange through http_gun directly: the default policy fails
  // without a status; the `Truncate` policy the worker uses keeps the 200.
  let big_tape = fn() {
    let assert Ok(tape) =
      cassette.new([
        fixture.Exchange(
          expected("evt_2"),
          answer(200, [], receiver.big_body()),
        ),
      ])
    let assert Ok(client) =
      cassette.playback(tape, egress.public_config(egress.default_settings()))
    client
  }
  let collect = fn(overflow) {
    request_options.Options(
      ..request_options.default(),
      collect: Some(request_options.Collect(1024, overflow)),
    )
  }
  let assert Error(error.Failure(
    error.LimitExceeded(error.CollectedBodyBytes, 1024, _),
    error.MayHaveBeenSent,
  )) =
    http_gun.send_with_options(
      big_tape(),
      expected("evt_2"),
      collect(request_options.Fail),
    )
  let assert Ok(http_gun.Buffered(response:, truncated: True, ..)) =
    http_gun.send_with_options(
      big_tape(),
      expected("evt_2"),
      collect(request_options.Truncate),
    )
  assert response.status == 200
  assert bit_array.byte_size(response.body) == 1024
  Nil
}

/// WHK-1: a 429 snoozes a worker that has an error codec; the job stays
/// bindable while scheduled, runs again, and the second exchange delivers.
pub fn snooze_with_error_codec_runs_again_test() {
  use svc <- support.with_service(options())
  setup(svc)
  let assert Ok(tape) =
    cassette.new([
      fixture.Exchange(
        expected("evt_s"),
        answer(429, [#("retry-after", "0")], <<>>),
      ),
      fixture.Exchange(expected("evt_s"), answer(204, [], <<>>)),
    ])
  let assert Ok(client) =
    cassette.playback(tape, egress.public_config(egress.default_settings()))
  let assert [#(delivery_id, job_id)] = support.publish(svc, event("evt_s"))
  let consumer =
    service.start_consumer_with(
      svc,
      worker_with(svc, client),
      service.manual_policy(),
    )
  assert queue.process_one(consumer) == Ok(True)
  assert support.outcome(svc, job_id) == Ok(job.Pending(job.Scheduled))
  assert queue.process_one(consumer) == Ok(True)
  assert queue.process_one(consumer) == Ok(False)
  let assert Ok(_) = queue.stop(consumer)

  assert support.outcome(svc, job_id)
    == Ok(job.SucceededWith(attempt.Receipt(204, attempt.BodyRead(0))))
  let assert Ok(row) = store.get_delivery(svc.db, delivery_id)
  assert row.attempts == 2
  // Both exchanges were consumed.
  let assert Error(error.Failure(error.FixtureExhausted, _)) =
    http_gun.send(client, expected("evt_s"))
  Nil
}
