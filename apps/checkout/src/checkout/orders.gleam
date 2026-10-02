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
import checkout/saga_store.{type SagaStore}
import checkout/telemetry.{type Collector}
import checkout/workflow.{type Checkout}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import grind/job
import grind/postgres
import grind/submission
import grind/worker.{type Worker}
import pog
import saga
import saga/durable
import saga/execution

pub const receipts_queue = "receipts"

pub const checkouts_queue = "checkouts"

pub type ReceiptRequest {
  ReceiptRequest(order_id: String, email: String, amount_cents: Int)
}

pub type Services {
  Services(
    pool: pog.Connection,
    grind: postgres.Database,
    gateway: Gateway,
    collector: Collector,
    store: SagaStore,
    workflow: Checkout,
    persistence: durable.Persistence(
      OrderRequest,
      Booked,
      CheckoutError,
      UndoError,
    ),
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
  case execution.start(s.workflow, order, s.saga_config) {
    Error(error) ->
      Report(domain.Rejected, string.inspect(error), Error(Nil), [], 0)
    Ok(run) -> {
      telemetry.link(
        s.collector,
        telemetry.SagaRun(execution.run_id(run)),
        telemetry.order(order.order_id),
      )
      case execution.await(run, 60_000) {
        Ok(outcome) -> finalize(s, order, outcome)
        Error(error) ->
          Report(domain.Pending, string.inspect(error), Error(Nil), [], 0)
      }
    }
  }
}

/// Hands the order to the durable checkout queue.
pub fn place_durable(
  s: Services,
  checkout_worker: Worker(OrderRequest, String, Nil),
  order: OrderRequest,
) -> Result(Int, String) {
  let _ = db.insert_order(s.pool, order.order_id)
  use id <- result.try(
    submission.submission_id("checkout:" <> order.order_id)
    |> result.map_error(string.inspect),
  )
  postgres.submit_with_id(
    s.grind,
    checkouts_queue,
    id,
    checkout_worker,
    order,
    submission.Immediately,
  )
  |> result.map_error(string.inspect)
  |> result.map(admission_job_id)
}

fn admission_job_id(admission: submission.Admission(i, o, e)) -> Int {
  case admission {
    submission.Inserted(handle) -> job.id_value(handle)
    submission.Existing(conflict) | submission.Rescheduled(conflict) ->
      submission.conflict_job_id(conflict)
  }
}

/// Records the saga outcome on the order. A confirmed order gets its receipt
/// outbox row in the same transaction, then the outbox is flushed to grind.
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
      let _ = db.confirm_with_receipt(s.pool, order, detail)
      let _ = flush_outbox(s)
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
    other -> #(string.inspect(other), Error(Nil))
  }
}

// --- receipts ---------------------------------------------------------------

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
pub fn receipt_worker(
  pool: pog.Connection,
) -> Worker(ReceiptRequest, String, Nil) {
  let string_codec = codecs.JsonCodec("text-1", json.string, decode.string)
  let assert Ok(w) =
    worker.define(
      "checkout.receipt",
      "1",
      codecs.to_grind(receipt_codec()),
      codecs.to_grind(string_codec),
      fn(receipt: ReceiptRequest) {
        let message_id =
          "msg-"
          <> receipt.order_id
          <> "-"
          <> int.to_string(receipt.amount_cents)
        db.record_receipt(pool, receipt.order_id, message_id)
        |> result.replace(message_id)
        |> result.replace_error(Nil)
      },
    )
  w
}

/// Submits every receipt still pending in the outbox. `submit_with_id` with
/// an order-derived id makes a repeated flush (after a crash between submit
/// and `mark_submitted`) converge on the same job.
pub fn flush_outbox(s: Services) -> Result(List(Int), String) {
  use rows <- result.try(
    db.pending_receipts(s.pool) |> result.map_error(string.inspect),
  )
  list.try_map(rows, fn(row) {
    let assert Ok(id) = submission.submission_id("receipt:" <> row.order_id)
    use admission <- result.try(
      postgres.submit_with_id(
        s.grind,
        receipts_queue,
        id,
        s.receipt_worker,
        ReceiptRequest(row.order_id, row.email, row.amount_cents),
        submission.Immediately,
      )
      |> result.map_error(string.inspect),
    )
    use _ <- result.try(
      db.mark_submitted(s.pool, row.order_id)
      |> result.map_error(string.inspect),
    )
    Ok(admission_job_id(admission))
  })
}
