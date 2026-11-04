//// The scripted receiver as a reference webhook consumer: it verifies each
//// request's signature and timestamp before running the endpoint, and treats
//// `webhook-id` as its idempotency key. No database.

import gleam/list
import webhooks/delivery
import webhooks/receiver.{Duplicate, Processed, Rejected}
import webhooks/signing
import webhooks/support

const secret = "whsec_receiver_test"

fn deliver(rx, path: String, id: String, timestamp: Int) -> Int {
  let body = <<"{\"type\":\"ping\",\"data\":null}":utf8>>
  support.post(
    receiver.port(rx),
    path,
    signing.headers(secret, id, timestamp, body),
    body,
  )
}

fn verdicts(rx) -> List(receiver.Verdict) {
  receiver.received(rx) |> list.map(fn(r) { r.verdict })
}

/// A replayed delivery is acknowledged, and the endpoint does not run again.
pub fn replayed_delivery_is_acknowledged_once_test() {
  let rx = receiver.start()
  receiver.trust(rx, "/flaky", secret)
  let now = delivery.unix_seconds()
  // Retries of an unprocessed delivery are not duplicates: /flaky fails
  // twice, then succeeds.
  assert deliver(rx, "/flaky", "evt_1:sub_1", now) == 503
  assert deliver(rx, "/flaky", "evt_1:sub_1", now) == 503
  assert deliver(rx, "/flaky", "evt_1:sub_1", now) == 204
  // Once processed, the same id is a duplicate, whatever its timestamp.
  assert deliver(rx, "/flaky", "evt_1:sub_1", now) == 204
  assert deliver(rx, "/flaky", "evt_1:sub_1", now + 5) == 204
  // Another id is new work.
  assert deliver(rx, "/flaky", "evt_2:sub_1", now) == 204
  assert verdicts(rx)
    == [
      Processed(503),
      Processed(503),
      Processed(204),
      Duplicate,
      Duplicate,
      Processed(204),
    ]
}

pub fn timestamp_outside_the_tolerance_is_rejected_test() {
  let rx = receiver.start()
  receiver.trust(rx, "/ok", secret)
  let now = delivery.unix_seconds()
  // Correctly signed, but captured more than five minutes ago, or dated
  // more than five minutes ahead.
  assert deliver(rx, "/ok", "evt_old:sub_1", now - 301) == 401
  assert deliver(rx, "/ok", "evt_new:sub_1", now + 301) == 401
  assert deliver(rx, "/ok", "evt_fresh:sub_1", now - 290) == 204
  assert verdicts(rx)
    == [
      Rejected("stale timestamp"),
      Rejected("stale timestamp"),
      Processed(204),
    ]

  // The tolerance is configurable.
  let strict =
    receiver.start_with(
      receiver.Settings(..receiver.default_settings(), tolerance_seconds: 10),
    )
  receiver.trust(strict, "/ok", secret)
  assert deliver(strict, "/ok", "evt_old:sub_1", now - 30) == 401
  assert deliver(strict, "/ok", "evt_new:sub_1", now) == 204
}

pub fn unsigned_or_unknown_requests_are_rejected_test() {
  let rx = receiver.start()
  receiver.trust(rx, "/ok", secret)
  let now = delivery.unix_seconds()
  let body = <<"{}":utf8>>
  // Signed with another secret.
  assert support.post(
      receiver.port(rx),
      "/ok",
      signing.headers("whsec_other", "evt_1:sub_1", now, body),
      body,
    )
    == 401
  // No signature headers.
  assert support.post(receiver.port(rx), "/ok", [], body) == 401
  // No secret is registered for /gone.
  assert deliver(rx, "/gone", "evt_1:sub_1", now) == 401
  assert verdicts(rx)
    == [
      Rejected("invalid signature"),
      Rejected("missing signature headers"),
      Rejected("unknown endpoint"),
    ]
}
