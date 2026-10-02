//// Pure tests: no database, no network.

import gleam/bit_array
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import http_gun/destination
import http_gun/error
import sinal
import sinal/correlation
import webhooks/attempt.{
  BodyRead, Delivered, Gone, Receipt, Refused, Reject, Reply, Retry, Snooze,
}
import webhooks/signing
import webhooks/subscription.{
  CredentialsInUrl, ForbiddenAddress, HostNotAllowlisted, InternalTier,
  PublicTier, UnsupportedScheme,
}
import webhooks/telemetry

fn reply(status: Int, retry_after) {
  Ok(Reply(status, retry_after, BodyRead(0)))
}

pub fn status_and_failure_mapping_test() {
  let snooze = attempt.default_snooze()
  assert attempt.classify(Ok(Reply(204, None, BodyRead(0))), snooze)
    == Delivered(Receipt(204, BodyRead(0)))
  assert attempt.classify(reply(503, None), snooze)
    == Retry(attempt.ServerError(503))
  assert attempt.classify(reply(408, None), snooze) == Retry(attempt.Timeout)
  assert attempt.classify(reply(410, None), snooze)
    == Gone("receiver answered 410 Gone")
  assert attempt.classify(reply(400, None), snooze)
    == Reject(attempt.ClientError(400))
  // 429 snoozes for Retry-After; the snooze does not consume an attempt.
  assert attempt.classify(reply(429, Some("7")), snooze)
    == Snooze(7000, "receiver answered 429; retry-after 7")
  // Missing, malformed or huge Retry-After falls back or is clamped.
  let assert Snooze(60_000, _) = attempt.classify(reply(429, None), snooze)
  let assert Snooze(60_000, _) =
    attempt.classify(reply(429, Some("Wed, 21 Oct 2026 07:28:00 GMT")), snooze)
  let assert Snooze(3_600_000, _) =
    attempt.classify(reply(429, Some("999999")), snooze)
  // http_gun failure classes.
  let failed = fn(reason, evidence) {
    attempt.classify(Error(error.Failure(reason, evidence)), snooze)
  }
  assert failed(error.DestinationRejected, error.NotSubmitted)
    == Refused("destination rejected by policy")
  assert failed(error.DeadlineExceeded, error.MayHaveBeenSent)
    == Retry(attempt.Timeout)
  assert failed(
      error.ConnectionFailed(error.ConnectionRefused),
      error.NotSubmitted,
    )
    == Retry(attempt.Transport("connection_failed.connection_refused"))
  assert failed(error.AdmissionFull, error.NotSubmitted)
    == Retry(attempt.Unavailable("admission_full"))
  assert failed(
      error.LimitExceeded(error.RequestBodyBytes, 10, 20),
      error.NotSubmitted,
    )
    == Reject(attempt.Internal("limit_exceeded.request_body_bytes"))
  assert failed(error.FixtureMismatch(0), error.NotSubmitted)
    == Reject(attempt.Internal("fixture_mismatch.0"))
}

pub fn signature_round_trip_test() {
  let body = bit_array.from_string("{\"a\":1}")
  let header = signing.sign("whsec_x", "evt_1:sub_1", 1_700_000_000, body)
  assert signing.verify("whsec_x", "evt_1:sub_1", 1_700_000_000, body, header)
  // Any change to secret, id, time or body breaks it.
  assert !signing.verify("whsec_y", "evt_1:sub_1", 1_700_000_000, body, header)
  assert !signing.verify("whsec_x", "evt_2:sub_1", 1_700_000_000, body, header)
  assert !signing.verify("whsec_x", "evt_1:sub_1", 1_700_000_001, body, header)
  assert !signing.verify(
    "whsec_x",
    "evt_1:sub_1",
    1_700_000_000,
    bit_array.from_string("{\"a\":2}"),
    header,
  )
}

pub fn registration_rejects_unsafe_endpoints_test() {
  let check = fn(url, tier) {
    subscription.validate_endpoint(url, tier, ["127.0.0.1", "localhost"])
  }
  assert check("https://169.254.169.254/latest/meta-data", PublicTier)
    == Error(ForbiddenAddress(destination.Reserved))
  assert check("https://10.1.2.3/hook", PublicTier)
    == Error(ForbiddenAddress(destination.Private))
  assert check("https://127.0.0.1:8443/hook", PublicTier)
    == Error(ForbiddenAddress(destination.Loopback))
  assert check("https://[::1]/hook", PublicTier)
    == Error(ForbiddenAddress(destination.Loopback))
  assert check("https://[::ffff:10.0.0.1]/hook", PublicTier)
    == Error(ForbiddenAddress(destination.Private))
  assert check("http://hooks.acme.example/hook", PublicTier)
    == Error(UnsupportedScheme("http"))
  assert check("https://user:pw@hooks.acme.example/hook", PublicTier)
    == Error(CredentialsInUrl)
  assert check("http://internal.example/hook", InternalTier)
    == Error(HostNotAllowlisted("internal.example"))
  // A host name passes registration; delivery-time policy decides (see the
  // DNS-rebinding test).
  let assert Ok(_) = check("https://rebind.acme.test/hook", PublicTier)
  let assert Ok(_) = check("http://127.0.0.1:4000/hook", InternalTier)
}

/// The app's event round-trips through native telemetry, with the delivery
/// id as the shared `correlation` key and the outcome as a closed enum.
pub fn delivery_attempted_event_round_trip_test() {
  let seen = process.new_subject()
  let attachment =
    sinal.observe(telemetry.delivery_attempted(), fn(m, d) {
      process.send(seen, #(m, d))
    })
  let metadata =
    telemetry.AttemptMetadata(
      correlation: telemetry.delivery_correlation("evt_1:sub_1"),
      tenant: "acme",
      outcome: telemetry.Snoozed,
      status: None,
    )
  sinal.emit(
    telemetry.delivery_attempted(),
    telemetry.AttemptMeasurements(3),
    metadata,
  )
  let assert Ok(Nil) = sinal.detach(attachment)
  assert process.receive(seen, 100)
    == Ok(#(telemetry.AttemptMeasurements(3), metadata))
  let assert Some(c) = metadata.correlation
  assert correlation.to_string(c) == "evt_1:sub_1"
  // A delivery id longer than a correlation allows is emitted without one.
  assert telemetry.delivery_correlation(string.repeat("x", 200)) == None
}
