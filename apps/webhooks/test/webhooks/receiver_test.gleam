//// The scripted receiver as a reference webhook consumer: it verifies each
//// request's signature and timestamp before running the endpoint, and treats
//// `webhook-id` as its idempotency key. No database.

import gleam/list
import gleam/string
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

/// The idempotency key is the endpoint and the `webhook-id` together: one
/// id delivered to two endpoints is new work at each.
pub fn same_id_at_another_endpoint_is_processed_test() {
  let rx = receiver.start()
  receiver.trust(rx, "/ok", secret)
  receiver.trust(rx, "/busy", secret)
  let now = delivery.unix_seconds()
  assert deliver(rx, "/ok", "evt_1:sub_1", now) == 204
  assert deliver(rx, "/busy", "evt_1:sub_1", now) == 429
  assert deliver(rx, "/busy", "evt_1:sub_1", now) == 204
  assert deliver(rx, "/busy", "evt_1:sub_1", now) == 204
  assert deliver(rx, "/ok", "evt_1:sub_1", now) == 204
  assert verdicts(rx)
    == [
      Processed(204),
      Processed(429),
      Processed(204),
      Duplicate,
      Duplicate,
    ]
}

@external(erlang, "webhooks_test_ffi", "set_clock")
fn set_clock(seconds: Int) -> Nil

@external(erlang, "webhooks_test_ffi", "clock")
fn clock() -> Int

/// At the shortest retention, a delivery dated as far ahead as the
/// tolerance allows is still remembered at the last second its timestamp is
/// fresh, so a replay at that boundary is a duplicate, and after it is
/// stale.
pub fn replay_at_the_retention_boundary_is_a_duplicate_test() {
  let tolerance = 10
  let rx =
    receiver.start_with(
      receiver.Settings(
        ..receiver.default_settings(),
        tolerance_seconds: tolerance,
        retention_seconds: 0,
        clock: clock,
      ),
    )
  receiver.trust(rx, "/ok", secret)
  let start = 1_700_000_000
  let timestamp = start + tolerance
  set_clock(start)
  assert deliver(rx, "/ok", "evt_edge:sub_1", timestamp) == 204
  // The last second the timestamp is fresh: 2 * tolerance after processing.
  set_clock(timestamp + tolerance)
  assert deliver(rx, "/ok", "evt_edge:sub_1", timestamp) == 204
  set_clock(timestamp + tolerance + 1)
  assert deliver(rx, "/ok", "evt_edge:sub_1", timestamp) == 401
  assert verdicts(rx)
    == [Processed(204), Duplicate, Rejected("stale timestamp")]
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

@external(erlang, "webhooks_test_ffi", "raw_status")
fn raw_status(port: Int, request: BitArray) -> Int

fn head(path: String, headers: List(String)) -> String {
  "POST "
  <> path
  <> " HTTP/1.1\r\nhost: 127.0.0.1\r\n"
  <> string.join(list.map(headers, fn(h) { h <> "\r\n" }), "")
  <> "\r\n"
}

/// The body limit holds however the body is framed: a chunked body, or one
/// without a length, is refused before any of it is read, and a declared
/// length over the limit is refused without reading the body.
pub fn body_limit_holds_for_every_framing_test() {
  let rx =
    receiver.start_with(
      receiver.Settings(..receiver.default_settings(), max_body_bytes: 1024),
    )
  receiver.trust(rx, "/ok", secret)
  let port = receiver.port(rx)
  // Chunked, 4 KiB in one chunk: over the limit with no Content-Length.
  let chunk = string.repeat("x", 4096)
  assert raw_status(port, <<
      head("/ok", ["transfer-encoding: chunked"]):utf8,
      "1000\r\n":utf8,
      chunk:utf8,
      "\r\n0\r\n\r\n":utf8,
    >>)
    == 411
  // Chunked, even when small.
  assert raw_status(port, <<
      head("/ok", ["transfer-encoding: chunked"]):utf8,
      "2\r\n{}\r\n0\r\n\r\n":utf8,
    >>)
    == 411
  // No framing at all.
  assert raw_status(port, <<head("/ok", []):utf8>>) == 411
  // A declared length over the limit; the body is never sent.
  assert raw_status(port, <<head("/ok", ["content-length: 1025"]):utf8>>) == 413
  assert verdicts(rx)
    == [
      Rejected("length required"),
      Rejected("length required"),
      Rejected("length required"),
      Rejected("body too large"),
    ]
}

/// A body read in several chunks is verified over exactly the bytes sent.
pub fn large_body_is_verified_over_its_raw_bytes_test() {
  let rx = receiver.start()
  receiver.trust(rx, "/ok", secret)
  let body = <<
    "{\"data\":\"":utf8,
    string.repeat("é", 100_000):utf8,
    "\"}":utf8,
  >>
  let now = delivery.unix_seconds()
  assert support.post(
      receiver.port(rx),
      "/ok",
      signing.headers(secret, "evt_big:sub_1", now, body),
      body,
    )
    == 204
  let assert [received] = receiver.received(rx)
  assert received.body == body
  assert received.verdict == Processed(204)
}
