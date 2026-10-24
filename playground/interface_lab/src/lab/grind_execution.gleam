// THROWAWAY: Can typed worker results enter a pure retry-resolution boundary?
import lab/grind
import lab/value.{type Value}

pub opaque type RetryDelay {
  RetryDelay(milliseconds: Int)
}

pub type RetryDelayError {
  RetryDelayMustNotBeNegative
}

// A retry delay is relative duration, distinct from Grind's absolute time.
pub fn retry_delay(milliseconds: Int) -> Result(RetryDelay, RetryDelayError) {
  case milliseconds >= 0 {
    True -> Ok(RetryDelay(milliseconds))
    False -> Error(RetryDelayMustNotBeNegative)
  }
}

pub fn retry_delay_milliseconds(delay: RetryDelay) -> Int {
  let RetryDelay(milliseconds) = delay
  milliseconds
}

pub type WorkerResponse(output, error) {
  WorkerSucceeded(output)
  WorkerFailed(error)
  WorkerSnoozed(delay: RetryDelay, evidence: Value)
  WorkerDiscarded(evidence: Value)
  WorkerCancelled(evidence: Value)
  WorkerUncertain(evidence: Value)
}

pub fn from_result(
  result: Result(output, error),
) -> WorkerResponse(output, error) {
  case result {
    Ok(output) -> WorkerSucceeded(output)
    Error(error) -> WorkerFailed(error)
  }
}

pub type AttemptReport(output, error, runtime) {
  Returned(response: WorkerResponse(output, error))
  RuntimeFailed(reason: runtime)
  Unknown(evidence: Value)
}

pub type AttemptFailure(error, runtime) {
  BusinessFailure(error: error)
  ObservedRuntimeFailure(reason: runtime)
}

pub opaque type AttemptAccounting {
  AttemptAccounting(current: Int, limit: Int, snoozes: Int)
}

pub type AccountingError {
  CurrentAttemptMustBePositive
  AttemptLimitMustBePositive
  SnoozeCountMustNotBeNegative
}

// Current includes the active claim. Values above limit are retained so the
// resolver can report budget exhaustion without silently normalizing input.
pub fn attempt_accounting(
  current: Int,
  limit: Int,
  snoozes: Int,
) -> Result(AttemptAccounting, AccountingError) {
  case current > 0 {
    False -> Error(CurrentAttemptMustBePositive)
    True ->
      case limit > 0 {
        False -> Error(AttemptLimitMustBePositive)
        True ->
          case snoozes >= 0 {
            False -> Error(SnoozeCountMustNotBeNegative)
            True -> Ok(AttemptAccounting(current, limit, snoozes))
          }
      }
  }
}

pub fn accounting_current(accounting: AttemptAccounting) -> Int {
  let AttemptAccounting(current, _, _) = accounting
  current
}

pub fn accounting_limit(accounting: AttemptAccounting) -> Int {
  let AttemptAccounting(_, limit, _) = accounting
  limit
}

pub fn accounting_snoozes(accounting: AttemptAccounting) -> Int {
  let AttemptAccounting(_, _, snoozes) = accounting
  snoozes
}

pub type RetryDecision {
  RetryAfter(delay: RetryDelay)
  DoNotRetry
}

pub type AttemptResolution(output, error, runtime) {
  Succeeded(output)
  RetryScheduled(
    failure: AttemptFailure(error, runtime),
    available_at: grind.AvailableAt,
  )
  RetryDeclined(failure: AttemptFailure(error, runtime))
  BudgetExhausted(failure: AttemptFailure(error, runtime))
  Snoozed(
    available_at: grind.AvailableAt,
    consumed_attempts: Int,
    snoozes: Int,
    evidence: Value,
  )
  Discarded(evidence: Value)
  Cancelled(evidence: Value)
  Reconcile(evidence: Value)
}

// These are proposed outcomes only; a later store transition must commit one.
// Only failures consult policy, and only while the supplied budget has room.
pub fn resolve(
  report: AttemptReport(output, error, runtime),
  accounting: AttemptAccounting,
  now: grind.AvailableAt,
  retry_policy: fn(AttemptFailure(error, runtime), AttemptAccounting) ->
    RetryDecision,
) -> AttemptResolution(output, error, runtime) {
  case report {
    Unknown(evidence) -> Reconcile(evidence)
    RuntimeFailed(reason) ->
      resolve_failure(
        ObservedRuntimeFailure(reason),
        accounting,
        now,
        retry_policy,
      )
    Returned(response) ->
      case response {
        WorkerSucceeded(output) -> Succeeded(output)
        WorkerFailed(error) ->
          resolve_failure(BusinessFailure(error), accounting, now, retry_policy)
        WorkerSnoozed(delay, evidence) ->
          Snoozed(
            available_after(now, delay),
            accounting_current(accounting) - 1,
            accounting_snoozes(accounting) + 1,
            evidence,
          )
        WorkerDiscarded(evidence) -> Discarded(evidence)
        WorkerCancelled(evidence) -> Cancelled(evidence)
        WorkerUncertain(evidence) -> Reconcile(evidence)
      }
  }
}

fn resolve_failure(
  failure: AttemptFailure(error, runtime),
  accounting: AttemptAccounting,
  now: grind.AvailableAt,
  retry_policy: fn(AttemptFailure(error, runtime), AttemptAccounting) ->
    RetryDecision,
) -> AttemptResolution(output, error, runtime) {
  case accounting_current(accounting) >= accounting_limit(accounting) {
    True -> BudgetExhausted(failure)
    False ->
      case retry_policy(failure, accounting) {
        RetryAfter(delay) ->
          RetryScheduled(failure, available_after(now, delay))
        DoNotRetry -> RetryDeclined(failure)
      }
  }
}

fn available_after(
  now: grind.AvailableAt,
  delay: RetryDelay,
) -> grind.AvailableAt {
  let unix_milliseconds =
    grind.available_at_milliseconds(now) + retry_delay_milliseconds(delay)
  // Both inputs are nonnegative and Erlang integers do not overflow.
  let assert Ok(available_at) = grind.available_at(unix_milliseconds)
  available_at
}
