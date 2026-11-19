//// The Result railway: five steps to place an order. Each returns Ok or
//// Error, and the first error skips every step after it.

import gleam/float
import gleam/int
import gleam/list
import gleam/set.{type Set}

pub type Step {
  ParseRequest
  ValidateAmount
  ReserveStock
  ChargeCard
  SendReceipt
}

pub const steps = [
  ParseRequest,
  ValidateAmount,
  ReserveStock,
  ChargeCard,
  SendReceipt,
]

/// The steps the reader made fail.
pub type Failures =
  Set(Step)

pub fn none() -> Failures {
  set.new()
}

pub fn toggle(failures: Failures, step: Step) -> Failures {
  case set.contains(failures, step) {
    True -> set.delete(failures, step)
    False -> set.insert(failures, step)
  }
}

/// What happened to one step on this run.
pub type Track {
  /// Ok, and the value moves on to the next step.
  RanOk
  /// The first failure: the error track starts here.
  Failed
  /// After the first failure: never runs.
  Skipped
}

pub type Outcome {
  /// Every step succeeded: Ok(receipt).
  AllOk
  /// The first failing step, counted from zero.
  FailedAt(index: Int, step: Step)
}

pub fn outcome(failures: Failures) -> Outcome {
  list.index_fold(steps, AllOk, fn(outcome, step, index) {
    case outcome, set.contains(failures, step) {
      AllOk, True -> FailedAt(index, step)
      _, _ -> outcome
    }
  })
}

pub fn tracks(failures: Failures) -> List(#(Step, Track)) {
  let outcome = outcome(failures)
  list.index_map(steps, fn(step, index) {
    #(step, case outcome {
      AllOk -> RanOk
      FailedAt(index: first, ..) if index < first -> RanOk
      FailedAt(index: first, ..) if index == first -> Failed
      FailedAt(..) -> Skipped
    })
  })
}

pub fn name(step: Step) -> String {
  case step {
    ParseRequest -> "Parse request"
    ValidateAmount -> "Validate amount"
    ReserveStock -> "Reserve stock"
    ChargeCard -> "Charge card"
    SendReceipt -> "Send receipt"
  }
}

pub fn error(step: Step) -> String {
  case step {
    ParseRequest -> "BadRequest"
    ValidateAmount -> "InvalidAmount"
    ReserveStock -> "OutOfStock"
    ChargeCard -> "Declined"
    SendReceipt -> "MailNotSent"
  }
}

pub fn result_label(outcome: Outcome) -> String {
  case outcome {
    AllOk -> "Ok(receipt)"
    FailedAt(step:, ..) -> "Error(" <> error(step) <> ")"
  }
}

/// How far the happy track is green, in percent.
pub fn ok_percent(outcome: Outcome) -> Int {
  case outcome {
    AllOk -> 100
    FailedAt(index:, ..) -> percent(int.to_float(index))
  }
}

/// Where the error track turns red, in percent.
pub fn error_start(outcome: Outcome) -> Int {
  case outcome {
    AllOk -> 100
    FailedAt(index:, ..) -> percent(int.to_float(index) +. 0.5)
  }
}

fn percent(position: Float) -> Int {
  float.round(position /. int.to_float(list.length(steps)) *. 100.0)
}

pub fn note(outcome: Outcome) -> String {
  case outcome {
    AllOk ->
      "Everything succeeded: the value flows along the happy track to the end."
    FailedAt(index:, step:) ->
      "Step "
      <> int.to_string(index + 1)
      <> " failed, so steps after it never ran. The caller receives "
      <> result_label(outcome)
      <> " as a value and must decide what to do. "
      <> case step {
        ChargeCard ->
          "Notice the stock is already reserved: undoing earlier steps is a job for Saga, in module 8."
        _ ->
          "gleam-dream libraries go further: their error types also say whether an effect may already have happened. More in module 4."
      }
  }
}
