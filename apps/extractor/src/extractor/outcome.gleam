//// Maps fetch, extraction and storage failures onto Grind's queue responses.
////
//// This is the app's translation between llm_wire's `advise` (a prospect
//// and the provider's delay), http_gun's failure `Kind` for fetches, and
//// Grind's `Response`. Extraction is a read-only provider call, so retrying
//// a `MaybeSent` failure is safe here; an app whose call has effects would
//// also branch on `failure.sent`.

import extractor/document
import extractor/llm
import gleam/int
import gleam/option.{Some}
import gleam/string
import gleam/time/duration.{type Duration}
import grind/worker
import http_gun/error as http_error
import llm_wire
import llm_wire/error
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
  Snooze(delay: Duration, reason: String)
  /// The input cannot succeed unchanged.
  Discard(reason: String)
}

/// Delay used when a provider asks to back off without a usable hint.
pub fn default_snooze() -> Duration {
  duration.seconds(5)
}

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
      decide_http(Fetch, failure, document.describe(error))
    document.HttpStatus(status) if status == 429 || status >= 500 ->
      Retry(Transient(Fetch, document.describe(error)))
    document.HttpStatus(_)
    | document.InvalidUrl(_)
    | document.UnsupportedContentType(_)
    | document.TooLarge(..)
    | document.NotUtf8 -> Discard(document.describe(error))
  }
}

fn decide_extract(extract_error: llm.ExtractError) -> Decision {
  case extract_error {
    llm.NotPrepared(problem) ->
      Discard("request not prepared: " <> error.describe_prepare_error(problem))
    llm.Refused(reason) -> Discard("provider refused: " <> reason)
    llm.Truncated -> Discard("structured output hit the token limit")
    llm.UnexpectedToolCall -> Discard("provider asked for an undeclared tool")
    llm.CallFailed(failure) -> decide_call(failure)
  }
}

fn decide_call(failure: llm_wire.Failure) -> Decision {
  let detail = llm_wire.describe_failure(failure)
  case failure.error, llm_wire.advise(failure) {
    error.InvalidOutput(raw_output:, failure: reason), _ ->
      Discard(
        "invalid structured output: "
        <> error.describe_value_failure(reason)
        <> "; output: "
        <> string.slice(raw_output, 0, 200),
      )
    error.Protocol(problem), _ ->
      Discard("provider protocol error: " <> problem)
    error.Status(code:, ..), llm_wire.RetryAdvice(llm_wire.MayHelp, after:) ->
      Snooze(
        option.unwrap(after, default_snooze()),
        "provider answered " <> int.to_string(code),
      )
    error.Provider(code: Some(code), ..),
      llm_wire.RetryAdvice(llm_wire.MayHelp, ..)
    -> Snooze(default_snooze(), "provider reported " <> code)
    _, llm_wire.RetryAdvice(llm_wire.MayHelp, ..)
    | _, llm_wire.RetryAdvice(llm_wire.Unknown, ..)
    -> Retry(Transient(Extract, detail))
    _, llm_wire.RetryAdvice(llm_wire.WillNotHelpUnchanged, ..) ->
      Discard(detail)
  }
}

/// Extraction and fetching are read-only, so a transient failure is retried
/// whether or not the request was sent; every other kind cannot succeed
/// unchanged.
fn decide_http(
  stage: Stage,
  failure: http_error.Failure,
  detail: String,
) -> Decision {
  case http_error.is_retryable(failure, idempotent: True) {
    True -> Retry(Transient(stage, detail))
    False -> Discard(detail)
  }
}

pub fn to_response(decision: Decision) -> worker.Response(output, JobError) {
  case decision {
    Retry(error) -> worker.Failed(error)
    Snooze(delay, reason) -> worker.Snoozed(delay, reason)
    Discard(reason) -> worker.Discarded(reason)
  }
}
