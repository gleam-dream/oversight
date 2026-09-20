// THROWAWAY: Can ordinary typed worker results compose with pure retry policy?
import lab/blueprint
import lab/grind
import lab/grind_execution as execution
import lab/value

pub type Receipt {
  Receipt(transaction_id: String, amount: Int)
}

pub type PaymentError {
  PaymentDeclined(reason: String)
}

pub type ProviderPollResult {
  ProviderReady(Receipt)
  ProviderBusy(String)
  ProviderRejected(PaymentError)
}

pub type RuntimeReason {
  ProcessExited(String)
}

pub fn probe() -> Nil {
  let worker = payment_worker()
  let now = must_time(grind.available_at(1000))
  let at_limit = must_accounting(1, 1, 0)

  // Ordinary typed worker output stays typed and succeeds even at the limit.
  let success =
    execution.resolve(
      execution.Returned(execution.from_result(grind.invoke(worker, 12))),
      at_limit,
      now,
      never_retry,
    )
  let assert execution.Succeeded(Receipt("receipt", 12)) = success

  // The same ordinary worker error can retry below the limit, retaining e.
  let below_limit = must_accounting(1, 3, 0)
  let retry_business = fn(failure, accounting) {
    let assert execution.BusinessFailure(PaymentDeclined("below minimum")) =
      failure
    let assert 1 = execution.accounting_current(accounting)
    let assert 3 = execution.accounting_limit(accounting)
    execution.RetryAfter(must_delay(250))
  }
  let retry =
    execution.resolve(
      execution.Returned(execution.from_result(grind.invoke(worker, 0))),
      below_limit,
      now,
      retry_business,
    )
  let assert execution.RetryScheduled(
    execution.BusinessFailure(PaymentDeclined("below minimum")),
    retry_at,
  ) = retry
  let assert 1250 = grind.available_at_milliseconds(retry_at)

  // Policy may decline an otherwise affordable retry; the worker error remains.
  let denied =
    execution.resolve(
      execution.Returned(
        execution.WorkerFailed(PaymentDeclined("below minimum")),
      ),
      below_limit,
      now,
      fn(_, _) { execution.DoNotRetry },
    )
  let assert execution.RetryDeclined(execution.BusinessFailure(PaymentDeclined(
    "below minimum",
  ))) = denied

  // At the exact limit a failure exhausts without consulting policy.
  let exact_limit_failure =
    execution.resolve(
      execution.Returned(
        execution.WorkerFailed(PaymentDeclined("below minimum")),
      ),
      must_accounting(3, 3, 0),
      now,
      never_retry,
    )
  let assert execution.BudgetExhausted(execution.BusinessFailure(PaymentDeclined(
    "below minimum",
  ))) = exact_limit_failure

  // An over-limit supplied attempt exhausts without consulting policy.
  let over_limit = must_accounting(4, 3, 0)
  let exhausted =
    execution.resolve(
      execution.Returned(
        execution.WorkerFailed(PaymentDeclined("below minimum")),
      ),
      over_limit,
      now,
      never_retry,
    )
  let assert execution.BudgetExhausted(execution.BusinessFailure(PaymentDeclined(
    "below minimum",
  ))) = exhausted

  // Snooze refunds the active claim even at the limit; zero is consumed count,
  // not an active AttemptAccounting value.
  let snooze_budget = must_accounting(1, 1, 4)
  let snoozed =
    execution.resolve(
      execution.Returned(execution.WorkerSnoozed(
        must_delay(40),
        value.Text("wait for provider"),
      )),
      snooze_budget,
      now,
      never_retry,
    )
  let assert execution.Snoozed(snooze_at, consumed, snoozes, evidence) = snoozed
  let assert 1040 = grind.available_at_milliseconds(snooze_at)
  let assert 0 = consumed
  let assert 5 = snoozes
  let assert value.Text("wait for provider") = evidence

  // A separate provider-poll callback can return a scheduling directive.
  let callback_response = provider_poll_response(ProviderBusy("provider busy"))
  let callback_resolution =
    execution.resolve(
      execution.Returned(callback_response),
      below_limit,
      now,
      never_retry,
    )
  let assert execution.Snoozed(callback_at, 0, 1, value.Text("provider busy")) =
    callback_resolution
  let assert 1060 = grind.available_at_milliseconds(callback_at)

  // Scheduling directives retain their evidence and do not consult retry policy.
  let discarded =
    execution.resolve(
      execution.Returned(execution.WorkerDiscarded(value.Text("bad input"))),
      at_limit,
      now,
      never_retry,
    )
  let assert execution.Discarded(value.Text("bad input")) = discarded

  let cancelled =
    execution.resolve(
      execution.Returned(execution.WorkerCancelled(value.Text("superseded"))),
      at_limit,
      now,
      never_retry,
    )
  let assert execution.Cancelled(value.Text("superseded")) = cancelled

  // Both uncertainty paths reconcile directly, even at an exhausted budget.
  let worker_uncertain =
    execution.resolve(
      execution.Returned(
        execution.WorkerUncertain(value.Text("effect may have happened")),
      ),
      over_limit,
      now,
      never_retry,
    )
  let assert execution.Reconcile(value.Text("effect may have happened")) =
    worker_uncertain

  let unknown_attempt =
    execution.resolve(
      execution.Unknown(value.Text("worker reply lost")),
      over_limit,
      now,
      never_retry,
    )
  let assert execution.Reconcile(value.Text("worker reply lost")) =
    unknown_attempt

  // Runtime detail is a separate type from the worker's application error.
  let retry_runtime = fn(failure, _) {
    case failure {
      execution.ObservedRuntimeFailure(ProcessExited(reason)) -> {
        let assert "disk error" = reason
        execution.RetryAfter(must_delay(10))
      }
      execution.BusinessFailure(_) -> execution.DoNotRetry
    }
  }
  let runtime_failure =
    execution.resolve(
      execution.RuntimeFailed(ProcessExited("disk error")),
      below_limit,
      now,
      retry_runtime,
    )
  let assert execution.RetryScheduled(
    execution.ObservedRuntimeFailure(ProcessExited("disk error")),
    runtime_retry_at,
  ) = runtime_failure
  let assert 1010 = grind.available_at_milliseconds(runtime_retry_at)

  let assert Error(execution.CurrentAttemptMustBePositive) =
    execution.attempt_accounting(0, 3, 0)
  let assert Error(execution.AttemptLimitMustBePositive) =
    execution.attempt_accounting(1, 0, 0)
  let assert Error(execution.SnoozeCountMustNotBeNegative) =
    execution.attempt_accounting(1, 3, -1)
  let assert Error(execution.RetryDelayMustNotBeNegative) =
    execution.retry_delay(-1)
  Nil
}

fn payment_worker() -> grind.Worker(Int, Receipt, PaymentError) {
  let assert Ok(id) = grind.worker_id("payment")
  let assert Ok(version) = grind.worker_version(1)
  grind.worker(
    id,
    version,
    blueprint.int(),
    receipt_codec(),
    payment_error_codec(),
    fn(amount) {
      case amount > 0 {
        True -> Ok(Receipt("receipt", amount))
        False -> Error(PaymentDeclined("below minimum"))
      }
    },
  )
}

fn receipt_codec() -> blueprint.Codec(Receipt) {
  blueprint.imap(
    blueprint.pair(blueprint.text(), blueprint.int()),
    fn(pair) { Receipt(pair.0, pair.1) },
    fn(receipt) { #(receipt.transaction_id, receipt.amount) },
  )
}

fn payment_error_codec() -> blueprint.Codec(PaymentError) {
  blueprint.imap(
    blueprint.text(),
    fn(reason) { PaymentDeclined(reason) },
    fn(error) {
      let PaymentDeclined(reason) = error
      reason
    },
  )
}

fn provider_poll_response(
  result: ProviderPollResult,
) -> execution.WorkerResponse(Receipt, PaymentError) {
  case result {
    ProviderReady(receipt) -> execution.WorkerSucceeded(receipt)
    ProviderBusy(reason) ->
      execution.WorkerSnoozed(must_delay(60), value.Text(reason))
    ProviderRejected(error) -> execution.WorkerFailed(error)
  }
}

fn must_accounting(
  current: Int,
  limit: Int,
  snoozes: Int,
) -> execution.AttemptAccounting {
  let assert Ok(accounting) =
    execution.attempt_accounting(current, limit, snoozes)
  accounting
}

fn must_delay(milliseconds: Int) -> execution.RetryDelay {
  let assert Ok(delay) = execution.retry_delay(milliseconds)
  delay
}

fn must_time(
  time: Result(grind.AvailableAt, grind.ScheduleError),
) -> grind.AvailableAt {
  let assert Ok(available_at) = time
  available_at
}

fn never_retry(
  _failure: execution.AttemptFailure(PaymentError, RuntimeReason),
  _accounting: execution.AttemptAccounting,
) -> execution.RetryDecision {
  panic as "retry policy must not be called for this result"
}
