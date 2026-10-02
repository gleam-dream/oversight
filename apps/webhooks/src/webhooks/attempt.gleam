//// The pure core of one delivery attempt: job values and their codecs, and
//// the mapping from an http_gun result to a grind worker response.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string
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
  /// The body exceeded the read limit; only the first `limit` bytes were kept.
  BodyOverLimit(limit: Int)
}

pub type Receipt {
  Receipt(status: Int, body: BodyNote)
}

/// Failures the retry policy sees, typed, and the job outcome keeps.
pub type DeliveryError {
  ServerError(status: Int)
  ClientError(status: Int)
  Timeout
  /// A transport failure; `cause` is a stable name (see `failure_name`).
  Transport(cause: String)
  /// The local client could not take the request; nothing was sent.
  Unavailable(reason: String)
  /// A local defect or configuration problem; never retried.
  Internal(reason: String)
}

pub fn delivery_codec() -> worker.Codec(Delivery) {
  let assert Ok(codec) =
    worker.codec(
      "delivery-v1",
      fn(d: Delivery) {
        json.object([
          #("delivery_id", json.string(d.delivery_id)),
          #("event_id", json.string(d.event_id)),
          #("event_type", json.string(d.event_type)),
          #("tenant", json.string(d.tenant)),
          #("subscription_id", json.string(d.subscription_id)),
          #("body", json.string(d.body)),
        ])
      },
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
  codec
}

pub fn receipt_codec() -> worker.Codec(Receipt) {
  let assert Ok(codec) =
    worker.codec(
      "receipt-v1",
      fn(r: Receipt) {
        let #(kind, n) = case r.body {
          BodyRead(bytes) -> #("read", bytes)
          BodyOverLimit(limit) -> #("over_limit", limit)
        }
        json.object([
          #("status", json.int(r.status)),
          #("body", json.string(kind)),
          #("bytes", json.int(n)),
        ])
      },
      {
        use status <- decode.field("status", decode.int)
        use kind <- decode.field("body", decode.string)
        use n <- decode.field("bytes", decode.int)
        case kind {
          "read" -> decode.success(Receipt(status:, body: BodyRead(n)))
          "over_limit" ->
            decode.success(Receipt(status:, body: BodyOverLimit(n)))
          _ -> decode.failure(Receipt(status:, body: BodyRead(n)), "BodyNote")
        }
      },
    )
  codec
}

pub fn error_codec() -> worker.Codec(DeliveryError) {
  let assert Ok(codec) =
    worker.codec(
      "delivery-error-v2",
      fn(e: DeliveryError) {
        let #(kind, status, text) = case e {
          ServerError(s) -> #("server_error", s, "")
          ClientError(s) -> #("client_error", s, "")
          Timeout -> #("timeout", 0, "")
          Transport(cause) -> #("transport", 0, cause)
          Unavailable(reason) -> #("unavailable", 0, reason)
          Internal(reason) -> #("internal", 0, reason)
        }
        json.object([
          #("kind", json.string(kind)),
          #("status", json.int(status)),
          #("text", json.string(text)),
        ])
      },
      {
        use kind <- decode.field("kind", decode.string)
        use status <- decode.field("status", decode.int)
        use text <- decode.field("text", decode.string)
        case kind {
          "server_error" -> decode.success(ServerError(status))
          "client_error" -> decode.success(ClientError(status))
          "timeout" -> decode.success(Timeout)
          "transport" -> decode.success(Transport(text))
          "unavailable" -> decode.success(Unavailable(text))
          "internal" -> decode.success(Internal(text))
          _ -> decode.failure(Internal(text), "DeliveryError")
        }
      },
    )
  codec
}

pub fn describe_error(e: DeliveryError) -> String {
  case e {
    ServerError(s) -> "server error " <> int.to_string(s)
    ClientError(s) -> "client error " <> int.to_string(s)
    Timeout -> "timeout"
    Transport(cause) -> "transport: " <> cause
    Unavailable(reason) -> "unavailable: " <> reason
    Internal(reason) -> "internal: " <> reason
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

/// How long a 429 snoozes when Retry-After is absent or unusable, and the
/// most it ever waits.
pub type SnoozePolicy {
  SnoozePolicy(default_ms: Int, maximum_ms: Int)
}

pub fn default_snooze() -> SnoozePolicy {
  SnoozePolicy(default_ms: 60_000, maximum_ms: 3_600_000)
}

pub fn classify(
  result: Result(Reply, error.Failure),
  snooze: SnoozePolicy,
) -> Disposition {
  case result {
    Ok(Reply(status:, retry_after:, body:)) ->
      case status {
        _ if status >= 200 && status < 300 -> Delivered(Receipt(status, body))
        410 -> Gone("receiver answered 410 Gone")
        429 ->
          Snooze(
            retry_after_ms(retry_after, snooze),
            "receiver answered 429; retry-after "
              <> option.unwrap(retry_after, "absent"),
          )
        408 -> Retry(Timeout)
        _ if status >= 500 -> Retry(ServerError(status))
        _ -> Reject(ClientError(status))
      }
    Error(failure) -> classify_failure(failure)
  }
}

/// Glue: every http_gun `Reason` mapped to a delivery decision. The match is
/// exhaustive on purpose so a new reason fails compilation here.
pub fn classify_failure(failure: error.Failure) -> Disposition {
  let name = failure_name(failure.reason)
  case failure.reason {
    error.DestinationRejected -> Refused("destination rejected by policy")
    error.ResolutionFailed -> Retry(Transport(name))
    error.ConnectionFailed(_) | error.RequestFailed(_) -> Retry(Transport(name))
    error.DeadlineExceeded | error.ReadTimeout -> Retry(Timeout)
    error.AdmissionFull | error.ClientClosed | error.Cancelled | error.Closed ->
      Retry(Unavailable(name))
    error.LimitExceeded(kind:, ..) ->
      case kind {
        error.RequestBodyBytes
        | error.RequestHeaderBytes
        | error.RequestHeaderCount -> Reject(Internal(name))
        _ -> Retry(Transport(name))
      }
    error.InvalidConfig(_)
    | error.InvalidRequest(_)
    | error.ReadConflict
    | error.WrongOwner
    | error.FixtureMissing
    | error.FixtureIo(_, _)
    | error.FixtureCorrupt
    | error.FixtureVersion(_)
    | error.FixtureExhausted
    | error.FixtureMismatch(_)
    | error.CaptureFailed(_) -> Reject(Internal(name))
  }
}

/// Glue: a stable, persistable name for an http_gun reason. http_gun has one
/// internally (http_gun/internal/codec.gleam:116) but exposes only
/// `error.describe`, a log sentence.
pub fn failure_name(reason: error.Reason) -> String {
  case reason {
    error.InvalidConfig(_) -> "invalid_config"
    error.InvalidRequest(_) -> "invalid_request"
    error.ClientClosed -> "client_closed"
    error.AdmissionFull -> "admission_full"
    error.DestinationRejected -> "destination_rejected"
    error.ResolutionFailed -> "resolution_failed"
    error.ConnectionFailed(cause) -> "connection_failed." <> cause_name(cause)
    error.RequestFailed(cause) -> "request_failed." <> cause_name(cause)
    error.DeadlineExceeded -> "deadline_exceeded"
    error.ReadTimeout -> "read_timeout"
    error.ReadConflict -> "read_conflict"
    error.WrongOwner -> "wrong_owner"
    error.Closed -> "closed"
    error.Cancelled -> "cancelled"
    error.LimitExceeded(kind:, ..) -> "limit_exceeded." <> limit_name(kind)
    error.FixtureMissing -> "fixture_missing"
    error.FixtureIo(_, _) -> "fixture_io"
    error.FixtureCorrupt -> "fixture_corrupt"
    error.FixtureVersion(_) -> "fixture_version"
    error.FixtureExhausted -> "fixture_exhausted"
    error.FixtureMismatch(position) ->
      "fixture_mismatch." <> int.to_string(position)
    error.CaptureFailed(_) -> "capture_failed"
  }
}

fn cause_name(cause: error.TransportCause) -> String {
  case cause {
    error.NameResolutionFailed -> "name_resolution_failed"
    error.ConnectionRefused -> "connection_refused"
    error.CertificateRejected -> "certificate_rejected"
    error.TlsFailed -> "tls_failed"
    error.ConnectionReset -> "connection_reset"
    error.PeerClosed -> "peer_closed"
    error.PeerDraining -> "peer_draining"
    error.ProtocolError -> "protocol_error"
    error.HeaderLimitReached -> "header_limit_reached"
    error.TransportTimeout -> "transport_timeout"
    error.UnexpectedProtocol -> "unexpected_protocol"
    error.UnknownTransport -> "unknown_transport"
  }
}

fn limit_name(kind: error.LimitKind) -> String {
  case kind {
    error.RequestBodyBytes -> "request_body_bytes"
    error.RequestHeaderBytes -> "request_header_bytes"
    error.RequestHeaderCount -> "request_header_count"
    error.ResponseHeaderBytes -> "response_header_bytes"
    error.ResponseHeaderCount -> "response_header_count"
    error.ResponseChunkBytes -> "response_chunk_bytes"
    error.ResponseQueueBytes -> "response_queue_bytes"
    error.CollectedBodyBytes -> "collected_body_bytes"
    error.FixtureBytes -> "fixture_bytes"
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
) -> worker.WorkerResponse(Receipt, DeliveryError) {
  case disposition {
    Delivered(receipt) -> worker.WorkerSucceeded(receipt)
    Retry(e) | Reject(e) -> worker.WorkerFailed(e)
    Snooze(milliseconds, reason) ->
      case worker.retry_delay(milliseconds) {
        Ok(delay) -> worker.WorkerSnoozed(delay, reason)
        Error(_) -> worker.WorkerFailed(Internal("invalid snooze delay"))
      }
    Gone(reason) -> worker.WorkerDiscarded(reason)
    Refused(reason) -> worker.WorkerDiscarded(reason)
  }
}

/// Exponential backoff for retryable errors; permanent errors are declined.
pub type Backoff {
  Backoff(base_ms: Int, maximum_ms: Int)
}

pub fn retry_policy(backoff: Backoff) -> worker.RetryPolicy(DeliveryError) {
  worker.retry_policy(fn(failure, context) {
    let worker.BusinessFailure(e) = failure
    case e {
      ClientError(_) | Internal(_) -> worker.DoNotRetry
      ServerError(_) | Timeout | Transport(_) | Unavailable(_) -> {
        let exponent = int.max(context.current_attempt - 1, 0)
        let delay =
          int.min(backoff.base_ms * pow2(exponent), backoff.maximum_ms)
        case worker.retry_delay(delay) {
          Ok(d) -> worker.RetryAfter(d)
          Error(_) -> worker.DoNotRetry
        }
      }
    }
  })
}

fn pow2(n: Int) -> Int {
  case n {
    0 -> 1
    _ -> 2 * pow2(n - 1)
  }
}

pub fn status_of(result: Result(Reply, error.Failure)) -> Option(Int) {
  case result {
    Ok(reply) -> Some(reply.status)
    Error(_) -> None
  }
}
