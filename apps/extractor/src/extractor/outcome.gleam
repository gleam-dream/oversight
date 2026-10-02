//// Maps fetch, extraction and storage failures onto Grind's queue responses.
////
//// This is the app's translation between llm_wire's retry vocabulary
//// (`retry.assess` + `RetryHint` + `RetryEvidence`), http_gun's failure
//// reasons, and Grind's `WorkerResponse`. Extraction is a read-only provider
//// call, so retrying after `RequestMayHaveReachedProvider` is safe here; an
//// app whose call has effects would also branch on `RetryEvidence`.

import extractor/document
import extractor/llm
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import grind/worker
import http_gun/error as http_error
import llm_wire/retry
import llm_wire/types
import pog

/// Why one extraction attempt failed.
pub type Failure {
  FetchFailed(document.FetchError)
  ExtractFailed(llm.ExtractError)
  StoreFailed(pog.QueryError)
}

/// The retained business error of a retryable attempt. Grind persists it
/// with the job through the error codec in `extractor/jobs`.
pub type JobError {
  Transient(stage: Stage, detail: String)
}

pub type Stage {
  Fetch
  Extract
  Store
}

/// A pure scheduling decision, testable without a queue.
pub type Decision {
  /// Let the worker's retry policy back off and count an attempt.
  Retry(JobError)
  /// Come back after this delay without spending an attempt.
  Snooze(delay_ms: Int, reason: String)
  /// The input cannot succeed unchanged.
  Discard(reason: String)
}

/// Delay used when a provider asks to back off without a usable hint.
pub const default_snooze_ms = 5000

pub fn decide(failure: Failure) -> Decision {
  case failure {
    FetchFailed(error) -> decide_fetch(error)
    ExtractFailed(error) -> decide_extract(error)
    StoreFailed(error) -> Retry(Transient(Store, string.inspect(error)))
  }
}

fn decide_fetch(error: document.FetchError) -> Decision {
  case error {
    document.Transport(failure) ->
      decide_http(Fetch, failure.reason, document.describe(error))
    document.HttpStatus(status) if status == 429 || status >= 500 ->
      Retry(Transient(Fetch, document.describe(error)))
    document.HttpStatus(_)
    | document.InvalidUrl(_)
    | document.UnsupportedContentType(_)
    | document.TooLarge(..)
    | document.NotUtf8 -> Discard(document.describe(error))
  }
}

fn decide_extract(error: llm.ExtractError) -> Decision {
  case error {
    llm.NotPrepared(wire) -> Discard("request not prepared: " <> describe(wire))
    llm.Refused(reason) -> Discard("provider refused: " <> reason)
    llm.Truncated -> Discard("structured output hit the token limit")
    llm.UnexpectedToolCall -> Discard("provider asked for an undeclared tool")
    llm.CallFailed(provider:, error:, evidence: _) ->
      case retry.assess(provider, error), error {
        retry.MayHelp, types.HttpStatusError(status_code:, retry_hint:, ..) ->
          Snooze(
            hint_ms(retry_hint),
            "provider answered " <> int.to_string(status_code),
          )
        retry.MayHelp, types.ProviderError(code: Some(code), ..) ->
          Snooze(default_snooze_ms, "provider reported " <> code)
        retry.MayHelp, _ -> Retry(Transient(Extract, describe(error)))
        retry.WillNotHelpUnchanged, _ -> Discard(describe(error))
        // llm_wire leaves every http_gun failure `Unknown`; the app
        // classifies the typed http_gun reason itself.
        retry.Unknown, types.HttpFailure(reason) ->
          decide_http(Extract, reason, describe(error))
        retry.Unknown, types.OutputValidationError(reason) ->
          Discard("invalid structured output: " <> reason)
        retry.Unknown, types.ProtocolError(reason) ->
          Discard("provider protocol error: " <> reason)
        retry.Unknown, _ -> Retry(Transient(Extract, describe(error)))
      }
  }
}

fn decide_http(
  stage: Stage,
  reason: http_error.Reason,
  detail: String,
) -> Decision {
  case reason {
    http_error.DestinationRejected
    | http_error.InvalidRequest(_)
    | http_error.InvalidConfig(_) -> Discard(detail)
    http_error.LimitExceeded(..) -> Discard(detail)
    _ -> Retry(Transient(stage, detail))
  }
}

/// `Retry-After` seconds become a Grind delay. An HTTP-date value would need
/// a date parser in the app; it falls back to the default delay.
fn hint_ms(hint: Option(types.RetryHint)) -> Int {
  case hint {
    Some(types.RetryDelaySeconds(seconds)) -> seconds * 1000
    Some(types.RetryHeaderValue(_)) | None -> default_snooze_ms
  }
}

pub fn to_response(
  decision: Decision,
) -> worker.WorkerResponse(output, JobError) {
  case decision {
    Retry(error) -> worker.WorkerFailed(error)
    Snooze(delay_ms, reason) ->
      case worker.retry_delay(delay_ms) {
        Ok(delay) -> worker.WorkerSnoozed(delay, reason)
        Error(_) -> worker.WorkerDiscarded("unrepresentable snooze: " <> reason)
      }
    Discard(reason) -> worker.WorkerDiscarded(reason)
  }
}

pub fn describe(error: types.WireError) -> String {
  case error {
    types.HttpFailure(reason) ->
      http_error.describe(http_error.Failure(reason, http_error.MayHaveBeenSent))
    types.HttpStatusError(status_code:, ..) ->
      "HTTP " <> int.to_string(status_code)
    types.ProviderError(code:, message:) ->
      option.unwrap(code, "provider") <> ": " <> message
    types.DeadlineExceeded(_) -> "deadline exceeded"
    types.ConfigurationError(reason)
    | types.PreparationError(reason)
    | types.TransportError(reason)
    | types.ProtocolError(reason)
    | types.OutputValidationError(reason) -> reason
    types.ResourceLimitExceeded(limit_name:, ..) -> "limit " <> limit_name
    types.CancelledLocally -> "cancelled locally"
  }
}
