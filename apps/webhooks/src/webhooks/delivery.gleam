//// The delivery worker: a grind queue handler that signs and sends one
//// webhook through the tenant's http_gun client and maps the result back to
//// a grind response.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/option.{None, Some}
import gleam/result
import gleam/uri
import grind/worker.{type Worker}
import http_gun
import http_gun/error
import http_gun/request_options
import http_gun/telemetry as http_telemetry
import pog
import sinal
import webhooks/attempt.{
  type Backoff, type Delivery, type DeliveryError, type Disposition,
  type Receipt, type Reply, type SnoozePolicy,
}
import webhooks/egress.{type Egress}
import webhooks/signing
import webhooks/store
import webhooks/subscription.{type Subscription, type Tier}
import webhooks/telemetry

pub const worker_id = "webhooks.deliver"

pub type Deps {
  Deps(
    db: pog.Connection,
    egress: Egress,
    tenants: Dict(String, Tier),
    /// Unix seconds used in the signature. Injected so cassette playback,
    /// which matches headers exactly, sees a deterministic signature.
    clock: fn() -> Int,
    snooze: SnoozePolicy,
    /// How much of a receiver's response body an attempt will buffer.
    max_response_bytes: Int,
    /// Glue for telemetry correlation (see `webhooks/telemetry`).
    correlate: fn(http_telemetry.Id, String) -> Nil,
  )
}

pub type Plan {
  Plan(max_attempts: Int, backoff: Backoff)
}

pub fn default_plan() -> Plan {
  Plan(max_attempts: 8, backoff: attempt.Backoff(15_000, 3_600_000))
}

/// The grind worker definition. All decisions live in the queue handler; the
/// plain `perform` callback is required by `worker.define*` but only reached
/// through `worker.invoke`, so it adapts the same handler.
pub fn worker(
  deps: Deps,
  plan: Plan,
) -> Worker(Delivery, Receipt, DeliveryError) {
  let assert Ok(definition) =
    worker.define_with_error_codec(
      worker_id,
      "v1",
      attempt.delivery_codec(),
      attempt.receipt_codec(),
      attempt.error_codec(),
      fn(delivery) {
        case handle(deps, delivery) {
          worker.WorkerSucceeded(receipt) -> Ok(receipt)
          worker.WorkerFailed(e) -> Error(e)
          _ -> Error(attempt.Internal("non-result disposition"))
        }
      },
    )
  let assert Ok(definition) =
    worker.with_max_attempts(definition, plan.max_attempts)
  definition
  |> worker.with_retry_policy(attempt.retry_policy(plan.backoff))
  |> worker.with_queue_handler(fn(delivery) { handle(deps, delivery) })
}

/// One attempt. Reads the subscription fresh so disabled endpoints and
/// rotated URLs or secrets take effect on the next attempt.
pub fn handle(
  deps: Deps,
  delivery: Delivery,
) -> worker.WorkerResponse(Receipt, DeliveryError) {
  case store.get_subscription(deps.db, delivery.subscription_id) {
    Error(store.NotFound) -> worker.WorkerDiscarded("subscription deleted")
    Error(store.QueryFailed(_)) ->
      worker.WorkerFailed(attempt.Unavailable("subscription lookup failed"))
    Ok(subscription.Subscription(status: subscription.Disabled(reason), ..)) ->
      worker.WorkerDiscarded("subscription disabled: " <> reason)
    Ok(sub) ->
      case dict.get(deps.tenants, sub.tenant) {
        Error(Nil) -> worker.WorkerDiscarded("unknown tenant " <> sub.tenant)
        Ok(tier) -> deliver(deps, delivery, sub, tier)
      }
  }
}

fn deliver(
  deps: Deps,
  delivery: Delivery,
  sub: Subscription,
  tier: Tier,
) -> worker.WorkerResponse(Receipt, DeliveryError) {
  let started = now_ms()
  let #(result, disposition) = case build_request(sub, delivery, deps.clock()) {
    Error(e) -> #(Error(Nil), attempt.Reject(e))
    Ok(req) -> {
      // Glue: the worker cannot see its grind job id, and http_gun's
      // correlation Id is opaque, so the app registers the pairing itself.
      let correlation = http_telemetry.new_id()
      deps.correlate(correlation, delivery.delivery_id)
      let client =
        egress.client_for(deps.egress, tier)
        |> http_gun.with_correlation(correlation)
      let sent = send(client, req, deps.max_response_bytes)
      #(result.replace_error(sent, Nil), attempt.classify(sent, deps.snooze))
    }
  }
  let status = case result {
    Ok(reply) -> Some(reply.status)
    Error(Nil) -> None
  }
  let _ =
    store.record_attempt(
      deps.db,
      delivery.delivery_id,
      status,
      describe(disposition),
    )
  case disposition {
    attempt.Gone(reason) | attempt.Refused(reason) -> {
      let _ = store.disable(deps.db, sub.id, reason)
      Nil
    }
    _ -> Nil
  }
  let _ =
    sinal.emit(
      telemetry.delivery_attempted(),
      telemetry.AttemptMeasurements(now_ms() - started),
      telemetry.AttemptMetadata(
        delivery.delivery_id,
        delivery.tenant,
        attempt.disposition_name(disposition),
        status,
      ),
    )
  attempt.to_response(disposition)
}

/// The signed request. The body is the event exactly as the tenant's app
/// posted it; identity, time and signature travel in headers.
pub fn build_request(
  sub: Subscription,
  delivery: Delivery,
  timestamp: Int,
) -> Result(Request(BitArray), DeliveryError) {
  use parsed <- result.try(
    uri.parse(sub.url)
    |> result.replace_error(attempt.Internal("stored url does not parse")),
  )
  use base <- result.try(
    request.from_uri(parsed)
    |> result.replace_error(attempt.Internal("stored url is not absolute")),
  )
  let payload = bit_array.from_string(delivery.body)
  let headers = [
    #("content-type", "application/json"),
    #("user-agent", "gleam-dream-webhooks/0.1"),
    #("webhook-event-type", delivery.event_type),
    ..signing.headers(sub.secret, delivery.delivery_id, timestamp, payload)
  ]
  Ok(
    request.Request(
      ..request.set_body(base, payload),
      method: http.Post,
      headers: headers,
    ),
  )
}

/// Send and read the status. The body is read only up to `max_body` for the
/// delivery log: under the `Truncate` policy a 200 with an oversized body is
/// still a delivered webhook, so a retrying worker never delivers it twice.
pub fn send(
  client: http_gun.Client,
  req: Request(BitArray),
  max_body: Int,
) -> Result(Reply, error.Failure) {
  let options =
    request_options.Options(
      ..request_options.default(),
      collect: Some(request_options.Collect(max_body, request_options.Truncate)),
    )
  use sent <- result.map(http_gun.send_with_options(client, req, options))
  let resp = sent.response
  let note = case sent.truncated {
    True -> attempt.BodyOverLimit(max_body)
    False -> attempt.BodyRead(bit_array.byte_size(resp.body))
  }
  let retry_after =
    response.get_header(resp, "retry-after") |> option.from_result
  attempt.Reply(resp.status, retry_after, note)
}

fn describe(disposition: Disposition) -> String {
  case disposition {
    attempt.Delivered(_) -> "delivered"
    attempt.Retry(e) -> "retry: " <> attempt.describe_error(e)
    attempt.Reject(e) -> "rejected: " <> attempt.describe_error(e)
    attempt.Snooze(_, reason) -> "snoozed: " <> reason
    attempt.Gone(reason) -> "gone: " <> reason
    attempt.Refused(reason) -> "refused: " <> reason
  }
}

pub fn unix_seconds() -> Int {
  now_ms() / 1000
}

@external(erlang, "webhooks_ffi", "now_ms")
pub fn now_ms() -> Int
