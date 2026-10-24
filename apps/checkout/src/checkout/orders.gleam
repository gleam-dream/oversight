//// Order placement and finalisation, shared by the local path (the HTTP
//// handler runs the saga in-request) and the durable path (a grind job
//// drives the saga through `saga/durable`).

import checkout/codecs
import checkout/db
import checkout/domain.{
  type Booked, type CheckoutError, type OrderRequest, type OrderStatus,
  type UndoError,
}
import checkout/gateway.{type Gateway}
import checkout/telemetry.{type Collector}
import checkout/workflow.{type Checkout, type Persistence}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/time/duration
import grind.{type Grind}
import grind/job
import grind/worker.{type Worker}
import pog
import saga
import saga/execution
import saga/storage.{type Storage}

pub const receipts_queue = "receipts"

pub const checkouts_queue = "checkouts"

pub type ReceiptRequest {
  ReceiptRequest(order_id: String, email: String, amount_cents: Int)
}

pub type Services {
  Services(
    /// Grind's pool, which is also the app's: `grind.connection(jobs)`.
    pool: pog.Connection,
    jobs: Grind,
    gateway: Gateway,
    collector: Collector,
    /// saga_postgres on the same pool.
    storage: Storage,
    workflow: Checkout,
    persistence: Persistence,
    saga_config: execution.Config,
    receipt_worker: Worker(ReceiptRequest, String, Nil),
  )
}

pub type Outcome =
  execution.Outcome(Booked, CheckoutError, UndoError)

/// What the API reports for an order.
pub type Report {
  Report(
    status: OrderStatus,
    detail: String,
    /// The provider/stock error behind a rejection or hold, if any.
    error: Result(CheckoutError, Nil),
    undone: List(String),
    unknown_effects: Int,
  )
}

/// Runs the checkout saga inside the caller (the HTTP request).
pub fn place_local(s: Services, order: OrderRequest) -> Report {
  let _ = db.insert_order(s.pool, order.order_id)
  let config =
    execution.with_correlation(s.saga_config, telemetry.order(order.order_id))
  case execution.start(s.workflow, order, config) {
    Error(error) ->
      Report(domain.Rejected, string.inspect(error), Error(Nil), [], 0)
    Ok(run) ->
      case execution.await(run, duration.seconds(60)) {
        Ok(outcome) -> finalize(s, order, outcome)
        Error(error) ->
          Report(domain.Pending, string.inspect(error), Error(Nil), [], 0)
      }
  }
}

/// Records the pending order and enqueues its durable checkout job in one
/// transaction. The job id is derived from the order, so a repeated
/// placement converges on the first job.
pub fn place_durable(
  s: Services,
  checkout_worker: Worker(OrderRequest, String, Nil),
  order: OrderRequest,
) -> Result(Int, String) {
  let checkout =
    job.new(checkout_worker, order)
    |> job.with_id("checkout:" <> order.order_id)
    |> job.with_correlation(telemetry.order(order.order_id))
  pog.transaction(s.pool, fn(tx) {
    use _ <- result.try(
      db.insert_order(tx, order.order_id) |> result.map_error(string.inspect),
    )
    grind.submit_in(s.jobs, tx, checkout)
    |> result.map_error(grind.describe_submit_error)
  })
  |> result.map(fn(admission) { job.id(grind.handle(admission)) })
  |> result.map_error(describe_transaction_error)
}

fn describe_transaction_error(error: pog.TransactionError(String)) -> String {
  case error {
    pog.TransactionRolledBack(detail) -> detail
    pog.TransactionQueryError(error) -> string.inspect(error)
  }
}

/// Records the saga outcome on the order. A confirmed order and its receipt
/// job commit in one transaction.
pub fn finalize(s: Services, order: OrderRequest, outcome: Outcome) -> Report {
  let unknown = list.length(execution.unknown_effects(outcome))
  case outcome {
    execution.Completed(booked)
    | execution.CompletedWithUnknownEffects(booked, _) -> {
      let detail =
        "charge "
        <> booked.charged.charge_id
        <> ", shipment "
        <> booked.shipment_id
      let _ = confirm_with_receipt(s, order, detail)
      Report(domain.Confirmed, detail, Error(Nil), [], unknown)
    }
    execution.Failed(cause, settlement) -> {
      let #(detail, error) = describe_cause(cause)
      let _ = db.set_status(s.pool, order.order_id, domain.Rejected, detail)
      Report(
        domain.Rejected,
        detail,
        error,
        list.map(settlement.undone, saga.address_to_string),
        unknown,
      )
    }
    execution.Unresolved(step, evidence, settlement) -> {
      let detail =
        saga.address_to_string(step)
        <> " held: "
        <> domain.describe_error(evidence)
      let _ =
        db.set_status(
          s.pool,
          order.order_id,
          domain.NeedsReconciliation,
          detail,
        )
      Report(
        domain.NeedsReconciliation,
        detail,
        Ok(evidence),
        list.map(settlement.undone, saga.address_to_string),
        unknown,
      )
    }
    execution.Cancelled(reason, settlement) -> {
      let detail = "cancelled: " <> string.inspect(reason)
      let _ = db.set_status(s.pool, order.order_id, domain.Rejected, detail)
      Report(
        domain.Rejected,
        detail,
        Error(Nil),
        list.map(settlement.undone, saga.address_to_string),
        unknown,
      )
    }
  }
}

fn describe_cause(
  cause: execution.Cause(CheckoutError),
) -> #(String, Result(CheckoutError, Nil)) {
  case cause {
    execution.StepFailed(step, error) -> #(
      saga.address_to_string(step) <> ": " <> domain.describe_error(error),
      Ok(error),
    )
    execution.RetryLimitReached(step, saga.Returned(error))
    | execution.RetrySuperseded(step, saga.Returned(error)) -> #(
      saga.address_to_string(step) <> ": " <> domain.describe_error(error),
      Ok(error),
    )
    other -> #(
      execution.describe_cause(other, error: domain.describe_error),
      Error(Nil),
    )
  }
}

// --- receipts ---------------------------------------------------------------

/// Confirms the order and enqueues its receipt in the same transaction:
/// both commit, or neither does. Returns the receipt job's id.
pub fn confirm_with_receipt(
  s: Services,
  order: OrderRequest,
  detail: String,
) -> Result(Int, String) {
  pog.transaction(s.pool, fn(tx) {
    use _ <- result.try(
      db.set_status(tx, order.order_id, domain.Confirmed, detail)
      |> result.map_error(string.inspect),
    )
    grind.submit_in(s.jobs, tx, receipt_job(s, order))
    |> result.map_error(grind.describe_submit_error)
  })
  |> result.map(fn(admission) { job.id(grind.handle(admission)) })
  |> result.map_error(describe_transaction_error)
}

/// The receipt job for an order, under an order-derived id.
pub fn receipt_job(
  s: Services,
  order: OrderRequest,
) -> job.Job(ReceiptRequest, String, Nil) {
  job.new(
    s.receipt_worker,
    ReceiptRequest(order.order_id, order.email, order.amount_cents),
  )
  |> job.with_id("receipt:" <> order.order_id)
  |> job.with_correlation(telemetry.order(order.order_id))
}

pub fn receipt_codec() -> codecs.JsonCodec(ReceiptRequest) {
  codecs.JsonCodec(
    "receipt-1",
    fn(r: ReceiptRequest) {
      json.object([
        #("order_id", json.string(r.order_id)),
        #("email", json.string(r.email)),
        #("amount_cents", json.int(r.amount_cents)),
      ])
    },
    {
      use order_id <- decode.field("order_id", decode.string)
      use email <- decode.field("email", decode.string)
      use amount <- decode.field("amount_cents", decode.int)
      decode.success(ReceiptRequest(order_id, email, amount))
    },
  )
}

/// "Sends" a receipt by recording it in the app's own table, deduplicated
/// by order id.
pub fn receipt_worker() -> Worker(ReceiptRequest, String, Nil) {
  let string_codec = codecs.JsonCodec("text-1", json.string, decode.string)
  worker.responding(
    "checkout.receipt",
    input: codecs.to_grind(receipt_codec()),
    output: codecs.to_grind(string_codec),
    handle: fn(context, receipt: ReceiptRequest) {
      let message_id =
        "msg-" <> receipt.order_id <> "-" <> int.to_string(receipt.amount_cents)
      db.record_receipt(
        worker.connection(context),
        receipt.order_id,
        message_id,
      )
      |> result.replace(message_id)
      |> result.replace_error(Nil)
      |> worker.from_result
    },
  )
  |> worker.with_queue(receipts_queue)
}
