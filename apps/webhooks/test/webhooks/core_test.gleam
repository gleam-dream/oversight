//// Pure tests: no database, no network.

import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import grind/testing as grind_testing
import grind/worker
import http_gun/destination
import http_gun/error
import sinal
import sinal/correlation
import sinal/fields
import webhooks/attempt.{
  BodyIncomplete, BodyRead, Delivered, Gone, Receipt, Refused, Reject, Reply,
  Retry, Snooze,
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
  let classify = attempt.classify(_, snooze, 0)
  assert classify(Ok(Reply(204, None, BodyRead(0))))
    == Delivered(Receipt(204, BodyRead(0)))
  assert classify(reply(503, None)) == Retry(attempt.ServerError(503))
  assert classify(reply(408, None)) == Retry(attempt.Timeout)
  assert classify(reply(410, None)) == Gone("receiver answered 410 Gone")
  assert classify(reply(400, None)) == Reject(attempt.ClientError(400))
  // 429 snoozes for Retry-After; the snooze does not consume an attempt.
  assert classify(reply(429, Some("7")))
    == Snooze(7000, "receiver answered 429; retry-after 7")
  // Missing, malformed or huge Retry-After falls back or is clamped.
  let assert Snooze(60_000, _) = classify(reply(429, None))
  let assert Snooze(60_000, _) =
    classify(reply(429, Some("Wed, 21 Oct 2026 07:28:00 GMT")))
  let assert Snooze(3_600_000, _) = classify(reply(429, Some("999999")))
  // WHK-8: once the context shows the snooze budget spent, a 429 uses an
  // attempt instead.
  assert attempt.classify(reply(429, Some("7")), snooze, snooze.max_snoozes)
    == Retry(attempt.RateLimited)

  // http_gun failures, by kind; the failure itself is the job error.
  let failed = fn(reason, evidence) {
    let failure = error.new(reason, evidence)
    #(failure, classify(Error(failure)))
  }
  let assert #(_, Refused("destination rejected by policy")) =
    failed(
      error.DestinationRejected(destination.AddressRefused(destination.Private)),
      error.NotSent,
    )
  let assert #(f, Retry(attempt.Http(g))) =
    failed(error.DeadlineExceeded, error.MaybeSent)
  assert f == g
  let assert #(f, Retry(attempt.Http(g))) =
    failed(error.ConnectionFailed(error.ConnectionRefused), error.NotSent)
  assert f == g && error.name(f) == "connection_failed.connection_refused"
  let assert #(_, Retry(attempt.Http(_))) =
    failed(error.AdmissionFull, error.NotSent)
  let assert #(_, Reject(attempt.Http(_))) =
    failed(error.LimitExceeded(error.RequestBodyBytes, 10, 20), error.NotSent)
  let assert #(_, Reject(attempt.Http(_))) =
    failed(error.PlaybackMismatch(0), error.NotSent)
  // WHK-3: a failure after the head keeps its status, which decides.
  assert classify(Error(
      error.new(error.RequestFailed(error.ConnectionReset), error.MaybeSent)
      |> error.with_status(200),
    ))
    == Delivered(Receipt(200, BodyIncomplete("request_failed.connection_reset")))
  let assert Retry(attempt.ServerError(503)) =
    classify(Error(
      error.new(error.IdleTimeout, error.MaybeSent) |> error.with_status(503),
    ))
}

/// The job error codec keeps an http_gun failure whole.
pub fn error_codec_round_trips_http_failures_test() {
  let failure =
    error.new(
      error.LimitExceeded(error.ResponseHeaderBytes, 10, 20),
      error.MaybeSent,
    )
    |> error.with_status(200)
  let assert Ok(perform) =
    grind_testing.perform(
      worker.responding(
        "echo",
        input: attempt.error_codec(),
        output: attempt.error_codec(),
        handle: fn(_, e) { worker.Failed(e) },
      )
        |> worker.with_error_codec(attempt.error_codec()),
      attempt.Http(failure),
    )
  assert perform == worker.Failed(attempt.Http(failure))
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
    == Error(HostNotAllowlisted("internal.example:80"))
  // A host name passes registration; delivery-time policy decides (see the
  // DNS-rebinding test).
  let assert Ok(_) = check("https://rebind.acme.test/hook", PublicTier)
  let assert Ok(_) = check("http://127.0.0.1:4000/hook", InternalTier)
  // WHK-4: a `host:port` entry pins the internal tier to one local server.
  let pinned = fn(url) {
    subscription.validate_endpoint(url, InternalTier, ["127.0.0.1:4000"])
  }
  let assert Ok(_) = pinned("http://127.0.0.1:4000/hook")
  assert pinned("http://127.0.0.1:4001/hook")
    == Error(HostNotAllowlisted("127.0.0.1:4001"))
  // The internal tier is loopback only, even for an allowlisted name.
  assert subscription.validate_endpoint("https://10.0.0.1/hook", InternalTier, [
      "10.0.0.1",
    ])
    == Error(ForbiddenAddress(destination.Private))
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
      correlation: correlation.from_key("evt_1:sub_1"),
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
  assert correlation.to_string(metadata.correlation) == "evt_1:sub_1"
  // A delivery id longer than a correlation allows still gets a stable one.
  let long = correlation.from_key(string.repeat("x", 200))
  assert string.length(correlation.to_string(long)) == 64
  assert long == correlation.from_key(string.repeat("x", 200))
}

/// Every `Outcome` is in the enum's list, so no observer is ever handed a
/// value it cannot decode.
pub fn every_outcome_is_listed_test() {
  let metadata = sinal.metadata_fields(telemetry.delivery_attempted())
  list.each(
    [
      telemetry.Delivered,
      telemetry.Retried,
      telemetry.Snoozed,
      telemetry.Gone,
      telemetry.Refused,
      telemetry.Rejected,
    ],
    fn(outcome) {
      let sample =
        telemetry.AttemptMetadata(
          correlation: correlation.from_key("evt"),
          tenant: "acme",
          outcome:,
          status: Some(200),
        )
      let assert Ok(Nil) = fields.check(metadata, sample)
    },
  )
}
