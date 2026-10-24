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
import grind/worker.{type Context, type Worker}
import http_gun
import http_gun/error
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
    egress: Egress,
    tenants: Dict(String, Tier),
    /// How much of a receiver's response body an attempt will buffer.
    max_response_bytes: Int,
  )
}

pub type Plan {
  Plan(max_attempts: Int, backoff: Backoff, snooze: SnoozePolicy)
}

pub fn default_plan() -> Plan {
  Plan(
    max_attempts: 8,
    backoff: attempt.Backoff(15_000, 3_600_000),
    snooze: attempt.default_snooze(),
  )
}

/// The grind worker definition. Receivers deduplicate on `webhook-id`, so an
/// attempt abandoned by a dead node is replayed instead of held for an
/// operator.
pub fn worker(
  deps: Deps,
  plan: Plan,
  queue: String,
) -> Worker(Delivery, Receipt, DeliveryError) {
  worker.responding(
    worker_id,
    input: attempt.delivery_codec(),
    output: attempt.receipt_codec(),
    handle: fn(context, delivery) { handle(deps, plan, context, delivery) },
  )
  |> worker.with_error_codec(attempt.error_codec())
  |> worker.with_queue(queue)
  |> worker.with_max_attempts(plan.max_attempts)
  |> worker.with_retry_policy(attempt.retry_policy(plan.backoff))
  |> worker.with_abandonment(worker.ReplayAfterLeaseExpiry(max_replays: 3))
}

/// One attempt. Reads the subscription fresh so disabled endpoints and
/// rotated URLs or secrets take effect on the next attempt.
pub fn handle(
  deps: Deps,
  plan: Plan,
  context: Context,
  delivery: Delivery,
) -> worker.Response(Receipt, DeliveryError) {
  let db = worker.connection(context)
  case store.get_subscription(db, delivery.subscription_id) {
    Error(store.NotFound) -> worker.Discarded("subscription deleted")
    Error(store.QueryFailed(_)) ->
      worker.Failed(attempt.Unavailable("subscription lookup failed"))
    Ok(subscription.Subscription(status: subscription.Disabled(reason), ..)) ->
      worker.Discarded("subscription disabled: " <> reason)
    Ok(sub) ->
      case dict.get(deps.tenants, sub.tenant) {
        Error(Nil) -> worker.Discarded("unknown tenant " <> sub.tenant)
        Ok(tier) -> deliver(deps, plan, context, delivery, sub, tier)
      }
  }
}

fn deliver(
  deps: Deps,
  plan: Plan,
  context: Context,
  delivery: Delivery,
  sub: Subscription,
  tier: Tier,
) -> worker.Response(Receipt, DeliveryError) {
  let started = now_ms()
  let correlation = worker.correlation(context)
  let #(status, disposition) = case
    build_request(sub, delivery, unix_seconds())
  {
    Error(e) -> #(None, attempt.Reject(e))
    Ok(req) -> {
      let sent =
        egress.client_for(deps.egress, tier)
        |> http_gun.with_correlation(correlation)
        |> send(req, deps.max_response_bytes)
      let status = case sent {
        Ok(reply) -> Some(reply.status)
        Error(failure) -> error.status(failure)
      }
      #(
        status,
        attempt.classify(sent, plan.snooze, worker.snooze_count(context)),
      )
    }
  }
  let db = worker.connection(context)
  let _ =
    store.record_attempt(
      db,
      delivery.delivery_id,
      status,
      describe(disposition),
    )
  case disposition {
    attempt.Gone(reason) | attempt.Refused(reason) -> {
      let _ = store.disable(db, sub.id, reason)
      Nil
    }
    _ -> Nil
  }
  sinal.emit(
    telemetry.delivery_attempted(),
    telemetry.AttemptMeasurements(now_ms() - started),
    telemetry.AttemptMetadata(
      correlation:,
      tenant: delivery.tenant,
      outcome: outcome(disposition),
      status:,
    ),
  )
  attempt.to_response(disposition)
}

fn outcome(disposition: Disposition) -> telemetry.Outcome {
  case disposition {
    attempt.Delivered(_) -> telemetry.Delivered
    attempt.Retry(_) -> telemetry.Retried
    attempt.Snooze(_, _) -> telemetry.Snoozed
    attempt.Gone(_) -> telemetry.Gone
    attempt.Refused(_) -> telemetry.Refused
    attempt.Reject(_) -> telemetry.Rejected
  }
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
/// delivery log; an oversized body fails with the response status, which
/// `attempt.classify` still delivers as a 2xx, so a retrying worker never
/// delivers it twice.
pub fn send(
  client: http_gun.Client,
  req: Request(BitArray),
  max_body: Int,
) -> Result(Reply, error.Failure) {
  use sent <- result.map(
    client
    |> http_gun.with_body_limit(max_body, http_gun.Fail)
    |> http_gun.send(req),
  )
  let resp = sent.response
  let retry_after =
    response.get_header(resp, "retry-after") |> option.from_result
  attempt.Reply(
    resp.status,
    retry_after,
    attempt.BodyRead(bit_array.byte_size(resp.body)),
  )
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
