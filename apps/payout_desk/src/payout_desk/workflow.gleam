//// The payout after its release: a durable Saga with three dependent steps.
////
//// 1. `reserve` sets the amount aside from the seller's balance. Undone
////    (the reservation released) when a later step fails.
//// 2. `pay` asks the provider to pay, with the release key as the
////    idempotency key. A declined payment fails the run, which releases the
////    reservation. A timeout is an unknown effect: the run ends
////    `Unresolved` with nothing undone, and the payout is reconciled by a
////    lookup (`jobs`), never by paying again.
//// 3. `post` turns the reservation into a posted payout with the receipt.
////
//// Every step is recoverable: after a lost runner, Saga asks the step's
//// resolver what happened instead of running it again. The resolver of
//// `pay` asks the provider by the release key.

import decisions/vocabulary.{type Ref, Ref}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/time/duration
import payout_desk/db.{type Instruction, Instruction}
import payout_desk/provider.{type Provider}
import pog
import saga
import saga/codec.{type Codec}
import saga/durable
import saga/execution
import saga/storage.{type Storage}

pub type Fault {
  /// The payment was definitely not made.
  Declined(reason: String)
  /// The provider did not answer in time: the payment may have been made.
  TimedOut
  /// The application's database failed.
  Unavailable(detail: String)
}

pub fn describe_fault(fault: Fault) -> String {
  case fault {
    Declined(reason) -> "declined: " <> reason
    TimedOut -> "the provider did not answer in time"
    Unavailable(detail) -> detail
  }
}

/// A paid instruction: the release key and the provider's receipt.
pub type Paid {
  Paid(release_key: String, receipt: String)
}

pub type Deps {
  Deps(
    db: pog.Connection,
    provider: Provider,
    sagas: Storage,
    /// How long `pay` waits for the provider's answer, in milliseconds.
    provider_timeout_ms: Int,
    /// Called after the provider answered a payment and before Saga saves
    /// it: a fault point for the tests, `fn() { Nil }` otherwise.
    after_paid: fn() -> Nil,
  )
}

pub type Run =
  durable.Run(Instruction, String, Fault, String)

/// The saved execution for this instruction, started or reconnected.
pub fn start(
  deps: Deps,
  instruction: Instruction,
) -> Result(Run, durable.Error) {
  durable.new(
    workflow(deps),
    input: instruction_codec(),
    output: codec.text(),
    error: fault_codec(),
    undo_error: codec.text(),
  )
  |> durable.with_config(
    execution.config()
    |> execution.with_step_timeout(execution.After(duration.seconds(10))),
  )
  |> durable.start_or_reconnect(
    deps.sagas,
    id: run_id(instruction.release_key),
    input: instruction,
  )
}

pub fn run_id(release_key: String) -> String {
  "payout:" <> release_key
}

fn workflow(deps: Deps) -> saga.Workflow(Instruction, String, Fault, String) {
  let reserve =
    saga.step("reserve", fn(instruction: Instruction) {
      db.reserve(deps.db, instruction)
      |> result.replace(instruction)
      |> result.map_error(fn(error) {
        case error {
          db.Insufficient(..) -> Declined(db.describe(error))
          _ -> Unavailable(db.describe(error))
        }
      })
    })
    |> saga.undo(fn(undo: saga.UndoRequest(Instruction, Instruction)) {
      db.release(deps.db, undo.input.release_key)
      |> result.map_error(db.describe)
    })
    |> durable.recoverable(
      version: "1",
      input: instruction_codec(),
      output: instruction_codec(),
      resolve: fn(instruction: Instruction, _) {
        case db.reservation(deps.db, instruction.release_key) {
          Ok(Some(_)) -> durable.Completed(instruction)
          Ok(option.None) -> durable.NotSent
          Error(_) -> durable.MaybeSent
        }
      },
    )
  let pay =
    saga.effect("pay", fn(instruction: Instruction, _key) {
      case
        provider.pay(
          deps.provider,
          key: instruction.release_key,
          amount_cents: instruction.amount_cents,
          within: deps.provider_timeout_ms,
        )
      {
        Ok(receipt) -> {
          deps.after_paid()
          Ok(Paid(instruction.release_key, receipt))
        }
        Error(provider.Declined(reason)) -> Error(Declined(reason))
        Error(provider.TimedOut) -> Error(TimedOut)
      }
    })
    |> saga.unknown_when(fn(fault) { fault == TimedOut })
    |> durable.recoverable(
      version: "1",
      input: instruction_codec(),
      output: paid_codec(),
      // Asked instead of paying again. The provider's lookup is
      // authoritative and its payment is idempotent by key, so "not found"
      // means it never paid, and sending again under the same key is safe.
      resolve: fn(instruction: Instruction, _) {
        case provider.lookup(deps.provider, instruction.release_key) {
          provider.Found(receipt) ->
            durable.Completed(Paid(instruction.release_key, receipt))
          provider.NotFound -> durable.NotSent
        }
      },
    )
  let post =
    saga.step("post", fn(paid: Paid) {
      db.post(deps.db, paid.release_key, paid.receipt)
      |> result.replace(paid.receipt)
      |> result.map_error(fn(error) { Unavailable(db.describe(error)) })
    })
    |> durable.recoverable(
      version: "1",
      input: paid_codec(),
      output: codec.text(),
      resolve: fn(paid: Paid, _) {
        case db.posting(deps.db, paid.release_key) {
          Ok(Some(receipt)) -> durable.Completed(receipt)
          Ok(option.None) -> durable.NotSent
          Error(_) -> durable.MaybeSent
        }
      },
    )
  saga.define("payout", fn(input) {
    input
    |> saga.perform(reserve)
    |> saga.perform(pay)
    |> saga.perform(post)
  })
}

fn instruction_codec() -> Codec(Instruction) {
  codec.json(
    "instruction-1",
    fn(i: Instruction) {
      Ok(
        json.object([
          #("release_key", json.string(i.release_key)),
          #("occurrence", json.string(i.occurrence)),
          #("seller", json.string(i.seller)),
          #("order", json.string(i.order)),
          #("amount_cents", json.int(i.amount_cents)),
        ]),
      )
    },
    {
      use release_key <- decode.field("release_key", decode.string)
      use occurrence <- decode.field("occurrence", decode.string)
      use seller <- decode.field("seller", decode.string)
      use order <- decode.field("order", decode.string)
      use amount_cents <- decode.field("amount_cents", decode.int)
      decode.success(Instruction(
        release_key:,
        occurrence:,
        seller:,
        order:,
        amount_cents:,
      ))
    },
  )
}

fn paid_codec() -> Codec(Paid) {
  codec.json(
    "paid-1",
    fn(p: Paid) {
      Ok(
        json.object([
          #("release_key", json.string(p.release_key)),
          #("receipt", json.string(p.receipt)),
        ]),
      )
    },
    {
      use release_key <- decode.field("release_key", decode.string)
      use receipt <- decode.field("receipt", decode.string)
      decode.success(Paid(release_key:, receipt:))
    },
  )
}

fn fault_codec() -> Codec(Fault) {
  codec.json(
    "fault-1",
    fn(fault) {
      Ok(case fault {
        Declined(reason) ->
          json.object([
            #("t", json.string("declined")),
            #("detail", json.string(reason)),
          ])
        TimedOut -> json.object([#("t", json.string("timed_out"))])
        Unavailable(detail) ->
          json.object([
            #("t", json.string("unavailable")),
            #("detail", json.string(detail)),
          ])
      })
    },
    {
      use tag <- decode.field("t", decode.string)
      case tag {
        "declined" -> {
          use detail <- decode.field("detail", decode.string)
          decode.success(Declined(detail))
        }
        "timed_out" -> decode.success(TimedOut)
        _ -> {
          use detail <- decode.optional_field("detail", "", decode.string)
          decode.success(Unavailable(detail))
        }
      }
    },
  )
}

/// The evidence of a performed payout, as `decisions.report` records it:
/// the provider's receipt for the release key.
pub fn receipt(release_key: String, receipt: String) -> Ref {
  Ref(kind: "provider.receipt", id: release_key, revision: receipt)
}
