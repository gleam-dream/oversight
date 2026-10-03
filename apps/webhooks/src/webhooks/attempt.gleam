//// The pure core of one delivery attempt: job values and their codecs, and
//// the mapping from an http_gun result to a grind worker response.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration
import grind/worker
import http_gun/error

// ---------------------------------------------------------------------------
// Job values
// ---------------------------------------------------------------------------

/// One delivery: an event fanned out to one subscription. The secret and the
/// URL are not part of the job; the worker reads them at attempt time so a
/// disabled subscription stops receiving and secrets stay out of job rows.
pub type Delivery {
  Delivery(
    delivery_id: String,
    event_id: String,
    event_type: String,
    tenant: String,
    subscription_id: String,
    body: String,
  )
}

/// How much of the receiver's body the attempt read. The status code decides
/// the outcome; the body is diagnostic only.
pub type BodyNote {
  BodyRead(bytes: Int)
  /// The head arrived but the body did not: it exceeded the read limit, or
  /// the connection failed while reading it. `reason` is the http_gun name.
  BodyIncomplete(reason: String)
}

pub type Receipt {
  Receipt(status: Int, body: BodyNote)
}

/// Failures the retry policy sees, typed, and the job outcome keeps.
pub type DeliveryError {
  ServerError(status: Int)
  ClientError(status: Int)
  Timeout
  /// 429 after the snooze budget was spent; retried like a server error.
  RateLimited
  /// The request failed before a response head arrived.
  Http(failure: error.Failure)
  /// The local client could not take the request; nothing was sent.
  Unavailable(reason: String)
  /// A local defect or configuration problem; never retried.
  Internal(reason: String)
}

pub fn delivery_codec() -> worker.Codec(Delivery) {
  worker.codec(
    worker.infallible(fn(d: Delivery) {
      json.object([
        #("delivery_id", json.string(d.delivery_id)),
        #("event_id", json.string(d.event_id)),
        #("event_type", json.string(d.event_type)),
        #("tenant", json.string(d.tenant)),
        #("subscription_id", json.string(d.subscription_id)),
        #("body", json.string(d.body)),
      ])
    }),
    {
      use delivery_id <- decode.field("delivery_id", decode.string)
      use event_id <- decode.field("event_id", decode.string)
      use event_type <- decode.field("event_type", decode.string)
      use tenant <- decode.field("tenant", decode.string)
      use subscription_id <- decode.field("subscription_id", decode.string)
      use body <- decode.field("body", decode.string)
      decode.success(Delivery(
        delivery_id:,
        event_id:,
        event_type:,
        tenant:,
        subscription_id:,
        body:,
      ))
    },
  )
}

pub fn receipt_codec() -> worker.Codec(Receipt) {
  worker.codec(
    worker.infallible(fn(r: Receipt) {
      let body = case r.body {
        BodyRead(bytes) -> [#("bytes", json.int(bytes))]
        BodyIncomplete(reason) -> [#("incomplete", json.string(reason))]
      }
      json.object([#("status", json.int(r.status)), ..body])
    }),
    {
      use status <- decode.field("status", decode.int)
      use body <- decode.then(
        decode.one_of(decode.at(["bytes"], decode.int) |> decode.map(BodyRead), [
          decode.at(["incomplete"], decode.string) |> decode.map(BodyIncomplete),
        ]),
      )
      decode.success(Receipt(status:, body:))
    },
  )
}

pub fn error_codec() -> worker.Codec(DeliveryError) {
  worker.codec(
    worker.infallible(fn(e: DeliveryError) {
      let #(kind, detail) = case e {
        ServerError(s) -> #("server_error", [#("status", json.int(s))])
        ClientError(s) -> #("client_error", [#("status", json.int(s))])
        Timeout -> #("timeout", [])
        RateLimited -> #("rate_limited", [])
        Http(failure) -> #("http", [#("failure", error.to_json(failure))])
        Unavailable(reason) -> #("unavailable", [#("text", json.string(reason))])
        Internal(reason) -> #("internal", [#("text", json.string(reason))])
      }
      json.object([#("kind", json.string(kind)), ..detail])
    }),
    {
      use kind <- decode.field("kind", decode.string)
      let status = decode.at(["status"], decode.int)
      let text = decode.at(["text"], decode.string)
      case kind {
        "server_error" -> decode.map(status, ServerError)
        "client_error" -> decode.map(status, ClientError)
        "timeout" -> decode.success(Timeout)
        "rate_limited" -> decode.success(RateLimited)
        "http" -> decode.at(["failure"], error.decoder()) |> decode.map(Http)
        "unavailable" -> decode.map(text, Unavailable)
        "internal" -> decode.map(text, Internal)
        _ -> decode.failure(Internal(kind), "DeliveryError")
      }
    },
  )
}

pub fn describe_error(e: DeliveryError) -> String {
  case e {
    ServerError(s) -> "server error " <> int.to_string(s)
    ClientError(s) -> "client error " <> int.to_string(s)
    Timeout -> "timeout"
    RateLimited -> "rate limited past the snooze budget"
    Http(failure) -> "http: " <> error.name(failure)
    Unavailable(reason) -> "unavailable: " <> reason
    Internal(reason) -> "internal: " <> reason
  }
}

/// Whether another attempt may succeed. Receivers deduplicate on the
/// `webhook-id` header, so a request that may have been sent is safe to
/// send again.
pub fn retryable(e: DeliveryError) -> Bool {
  case e {
    ServerError(_) | Timeout | RateLimited | Unavailable(_) -> True
    ClientError(_) | Internal(_) -> False
    Http(failure) -> error.is_retryable(failure, idempotent: True)
  }
}

// ---------------------------------------------------------------------------
// Classification: http_gun result -> disposition -> grind response
// ---------------------------------------------------------------------------

/// What the attempt observed when the receiver answered.
pub type Reply {
  Reply(status: Int, retry_after: Option(String), body: BodyNote)
}

pub type Disposition {
  Delivered(Receipt)
  /// Retry with the worker's backoff; consumes an attempt.
  Retry(DeliveryError)
  /// 429: come back after Retry-After; does not consume an attempt.
  Snooze(milliseconds: Int, reason: String)
  /// 410: discard and disable the subscription.
  Gone(reason: String)
  /// Destination policy refused the address: discard and disable.
  Refused(reason: String)
  /// A permanent failure: fail without retrying.
  Reject(DeliveryError)
}

/// How long a 429 snoozes when Retry-After is absent or unusable, the most
/// it ever waits, and how many snoozes one delivery gets before a 429 counts
/// as a failed attempt.
pub type SnoozePolicy {
  SnoozePolicy(default_ms: Int, maximum_ms: Int, max_snoozes: Int)
}

pub fn default_snooze() -> SnoozePolicy {
  SnoozePolicy(default_ms: 60_000, maximum_ms: 3_600_000, max_snoozes: 10)
}

/// `snoozes` is how often this delivery has snoozed so far
/// (`worker.snooze_count`).
pub fn classify(
  result: Result(Reply, error.Failure),
  snooze: SnoozePolicy,
  snoozes: Int,
) -> Disposition {
  case result {
    Ok(Reply(status:, retry_after:, body:)) ->
      classify_status(status, retry_after, body, snooze, snoozes)
    // The head arrived before the failure, so the status and its
    // Retry-After still decide.
    Error(failure) ->
      case error.status(failure), error.kind(failure) {
        Some(status), _ ->
          classify_status(
            status,
            list.key_find(error.headers(failure), "retry-after")
              |> option.from_result,
            BodyIncomplete(error.name(failure)),
            snooze,
            snoozes,
          )
        None, error.Refused -> Refused("destination rejected by policy")
        None, _ -> fail(Http(failure))
      }
  }
}

fn classify_status(
  status: Int,
  retry_after: Option(String),
  body: BodyNote,
  snooze: SnoozePolicy,
  snoozes: Int,
) -> Disposition {
  case status {
    _ if status >= 200 && status < 300 -> Delivered(Receipt(status, body))
    410 -> Gone("receiver answered 410 Gone")
    429 if snoozes >= snooze.max_snoozes -> fail(RateLimited)
    429 ->
      Snooze(
        retry_after_ms(retry_after, snooze),
        "receiver answered 429; retry-after "
          <> option.unwrap(retry_after, "absent"),
      )
    408 -> fail(Timeout)
    _ if status >= 500 -> fail(ServerError(status))
    _ -> fail(ClientError(status))
  }
}

fn fail(e: DeliveryError) -> Disposition {
  case retryable(e) {
    True -> Retry(e)
    False -> Reject(e)
  }
}

/// Retry-After in delta-seconds; an HTTP-date or garbage falls back to the
/// default. Always clamped to the policy maximum.
pub fn retry_after_ms(header: Option(String), policy: SnoozePolicy) -> Int {
  let requested = case header {
    Some(text) ->
      case int.parse(string.trim(text)) {
        Ok(seconds) if seconds >= 0 -> seconds * 1000
        _ -> policy.default_ms
      }
    None -> policy.default_ms
  }
  int.min(requested, policy.maximum_ms)
}

/// Grind's vocabulary for a disposition. `Gone` and `Refused` side effects
/// (disabling the subscription) happen in the worker before this is returned.
pub fn to_response(
  disposition: Disposition,
) -> worker.Response(Receipt, DeliveryError) {
  case disposition {
    Delivered(receipt) -> worker.Succeeded(receipt)
    Retry(e) | Reject(e) -> worker.Failed(e)
    Snooze(milliseconds, reason) ->
      worker.Snoozed(after: duration.milliseconds(milliseconds), reason:)
    Gone(reason) | Refused(reason) -> worker.Discarded(reason)
  }
}

/// Exponential backoff for retryable errors; permanent errors are declined.
pub type Backoff {
  Backoff(base_ms: Int, maximum_ms: Int)
}

pub fn retry_policy(
  backoff: Backoff,
) -> fn(DeliveryError, Int) -> worker.RetryDecision {
  fn(e, attempt) {
    case retryable(e) {
      False -> worker.DoNotRetry
      True ->
        backoff.base_ms * pow2(int.max(attempt - 1, 0))
        |> int.min(backoff.maximum_ms)
        |> duration.milliseconds
        |> worker.RetryAfter
    }
  }
}

fn pow2(n: Int) -> Int {
  case n {
    0 -> 1
    _ -> 2 * pow2(n - 1)
  }
}
