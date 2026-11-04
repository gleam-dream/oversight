//// Order placement and finalisation, shared by the local path (the HTTP
//// handler runs the saga in-request) and the durable path (a grind job
//// drives the saga through `saga/durable`).

import checkout/codecs
import checkout/db
import checkout/domain.{
  type Booked, type CheckoutError, type CheckoutRequest, type Order,
  type OrderStatus, type UndoError,
}
import checkout/gateway.{type Gateway}
import checkout/telemetry.{type Collector}
import checkout/workflow.{type Checkout, type Persistence}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
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
import wisp

pub const receipts_queue = "receipts"

pub const checkouts_queue = "checkouts"

pub type ReceiptRequest {
  ReceiptRequest(
    customer_id: String,
    order_id: String,
    email: String,
    amount_cents: Int,
  )
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
    /// How long `POST /orders` waits for the local saga before cancelling it.
    local_budget: duration.Duration,
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

/// Why a request did not become an order.
pub type PlaceError {
  /// The SKU is not in the catalog, so it has no price.
  UnknownSku(sku: String)
  /// This customer already used the order id for a different SKU or
  /// quantity. The existing order is untouched. Another customer's orders
  /// never conflict: order ids are scoped to the customer.
  OrderIdConflict
  /// The catalog or order store could not be read or written; the detail is
  /// in the log.
  StoreUnavailable
}

/// What a placement did.
pub type Placement(a) {
  /// This placement created the order and started its checkout.
  Started(a)
  /// The customer already placed this order; nothing ran again.
  Existing(db.OrderRecord)
}

/// Prices a customer's request from the catalog: the amount is the SKU's
/// unit price times the quantity. This is the only place an order's amount
/// is set, and the customer id comes from the caller's credential.
pub fn price(
  s: Services,
  customer_id: String,
  request: CheckoutRequest,
) -> Result(Order, PlaceError) {
  case db.unit_price(s.pool, request.sku) {
    Ok(Some(unit_price_cents)) ->
      Ok(domain.price(request, customer_id:, unit_price_cents:))
    Ok(None) -> Error(UnknownSku(request.sku))
    Error(error) -> {
      log_internal(request.order_id, "catalog lookup failed", error)
      Error(StoreUnavailable)
    }
  }
}

/// Claims the customer's order id for this order. The id is the customer's
/// own idempotency key: the first placement creates the order, repeating
/// the same SKU and quantity gets the existing order, and a different SKU
/// or quantity is a conflict. Another customer's use of the same id is a
/// separate order and is never consulted. Only `Started` may run the saga.
fn claim(
  conn: pog.Connection,
  order: Order,
) -> Result(Placement(Nil), PlaceError) {
  case db.insert_order(conn, order) {
    Ok(db.Inserted) -> Ok(Started(Nil))
    Ok(db.AlreadyExists(existing))
      if existing.sku == order.sku && existing.quantity == order.quantity
    -> Ok(Existing(existing))
    Ok(db.AlreadyExists(_)) | Ok(db.Contended) -> Error(OrderIdConflict)
    Error(error) -> {
      log_internal(order.order_id, "order insert failed", error)
      Error(StoreUnavailable)
    }
  }
}

/// Runs the checkout saga inside the caller (the HTTP request), once per
/// order id.
pub fn place_local(
  s: Services,
  order: Order,
) -> Result(Placement(Report), PlaceError) {
  use claimed <- result.map(claim(s.pool, order))
  case claimed {
    Existing(existing) -> Existing(existing)
    Started(Nil) -> Started(run_local(s, order))
  }
}

/// Runs the saga and records its outcome before the request answers, so the
/// order never stays `pending` behind a local placement. A saga that
/// cannot start is recorded `rejected`. One that outlasts `local_budget` is
/// cancelled and awaited until it settles, and that settled outcome is
/// recorded: the run never keeps reserving or charging after the request
/// returns, which would otherwise happen unobserved (the request process
/// owns the run, so its exit cancels the run with nobody to record it).
/// Re-running the saga on a retry instead would not be safe: a released
/// reservation and a voided charge under the same order key read as
/// already done.
fn run_local(s: Services, order: Order) -> Report {
  let config =
    execution.with_correlation(
      s.saga_config,
      telemetry.order(domain.key(order)),
    )
  case execution.start(s.workflow, order, config) {
    Error(error) -> {
      log_internal(order.order_id, "saga start failed", error)
      let detail = "checkout could not start"
      let _ = db.set_status(s.pool, order, domain.Rejected, detail)
      Report(domain.Rejected, detail, Error(Nil), [], 0)
    }
    Ok(run) ->
      case execution.await(run, s.local_budget) {
        Ok(outcome) -> finalize(s, order, outcome)
        Error(error) -> {
          log_internal(order.order_id, "saga await ended", error)
          execution.cancel(run)
          case execution.await(run, settle_budget()) {
            Ok(outcome) -> finalize(s, order, outcome)
            Error(error) -> {
              log_internal(order.order_id, "saga did not settle", error)
              let detail = "checkout outcome unknown"
              let _ =
                db.set_status(s.pool, order, domain.NeedsReconciliation, detail)
              Report(domain.NeedsReconciliation, detail, Error(Nil), [], 0)
            }
          }
        }
      }
  }
}

/// How long a cancelled local run may take to settle: its settle window,
/// then undo and compensation, each under its own timeout.
fn settle_budget() -> duration.Duration {
  duration.seconds(60)
}

/// Records the pending order and enqueues its durable checkout job in one
/// transaction, once per order id. The job id is derived from the order as
/// well, so even a lost commit reply converges on the first job. A store
/// failure is logged; the caller learns only that admission did not commit.
pub fn place_durable(
  s: Services,
  checkout_worker: Worker(Order, String, Nil),
  order: Order,
) -> Result(Placement(Int), PlaceError) {
  let checkout =
    job.new(checkout_worker, order)
    |> job.with_id("checkout:" <> domain.key(order))
    |> job.with_correlation(telemetry.order(domain.key(order)))
  pog.transaction(s.pool, fn(tx) {
    use claimed <- result.try(claim(tx, order))
    case claimed {
      Existing(existing) -> Ok(Existing(existing))
      Started(Nil) ->
        grind.submit_in(s.jobs, tx, checkout)
        |> result.map(fn(admission) { Started(job.id(grind.handle(admission))) })
        |> result.map_error(fn(error) {
          log_internal(
            order.order_id,
            "durable admission failed",
            grind.describe_submit_error(error),
          )
          StoreUnavailable
        })
    }
  })
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionRolledBack(error) -> error
      pog.TransactionQueryError(error) -> {
        log_internal(order.order_id, "durable admission failed", error)
        StoreUnavailable
      }
    }
  })
}

/// Internal detail for operators: the full term goes to the log, keyed by
/// order, and never into an API body or an order row.
fn log_internal(order_id: String, context: String, detail: a) -> Nil {
  wisp.log_warning(
    "order " <> order_id <> ": " <> context <> ": " <> string.inspect(detail),
  )
}

fn describe_transaction_error(error: pog.TransactionError(String)) -> String {
  case error {
    pog.TransactionRolledBack(detail) -> detail
    pog.TransactionQueryError(error) -> string.inspect(error)
  }
}

/// Records the saga outcome on the order. A confirmed order and its receipt
/// job commit in one transaction.
pub fn finalize(s: Services, order: Order, outcome: Outcome) -> Report {
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
      log_cause(order.order_id, error)
      let _ = db.set_status(s.pool, order, domain.Rejected, detail)
      Report(
        domain.Rejected,
        detail,
        error,
        list.map(settlement.undone, saga.address_to_string),
        unknown,
      )
    }
    execution.Unresolved(step, evidence, settlement) -> {
      log_cause(order.order_id, Ok(evidence))
      let detail =
        saga.address_to_string(step)
        <> " held: "
        <> domain.describe_error(evidence)
      let _ = db.set_status(s.pool, order, domain.NeedsReconciliation, detail)
      Report(
        domain.NeedsReconciliation,
        detail,
        Ok(evidence),
        list.map(settlement.undone, saga.address_to_string),
        unknown,
      )
    }
    execution.Cancelled(reason, settlement) -> {
      let detail = case reason {
        execution.CancelRequested -> "cancelled: requested"
        execution.OwnerExited -> "cancelled: owner exited"
      }
      let _ = db.set_status(s.pool, order, domain.Rejected, detail)
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

fn log_cause(order_id: String, error: Result(CheckoutError, Nil)) -> Nil {
  case error {
    Ok(error) ->
      wisp.log_warning("order " <> order_id <> ": " <> domain.log_detail(error))
    Error(Nil) -> Nil
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
  order: Order,
  detail: String,
) -> Result(Int, String) {
  pog.transaction(s.pool, fn(tx) {
    use _ <- result.try(
      db.set_status(tx, order, domain.Confirmed, detail)
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
  order: Order,
) -> job.Job(ReceiptRequest, String, Nil) {
  job.new(
    s.receipt_worker,
    ReceiptRequest(
      order.customer_id,
      order.order_id,
      order.email,
      order.amount_cents,
    ),
  )
  |> job.with_id("receipt:" <> domain.key(order))
  |> job.with_correlation(telemetry.order(domain.key(order)))
}

pub fn receipt_codec() -> codecs.JsonCodec(ReceiptRequest) {
  codecs.JsonCodec(
    "receipt-2",
    fn(r: ReceiptRequest) {
      json.object([
        #("customer_id", json.string(r.customer_id)),
        #("order_id", json.string(r.order_id)),
        #("email", json.string(r.email)),
        #("amount_cents", json.int(r.amount_cents)),
      ])
    },
    {
      use customer_id <- decode.field("customer_id", decode.string)
      use order_id <- decode.field("order_id", decode.string)
      use email <- decode.field("email", decode.string)
      use amount <- decode.field("amount_cents", decode.int)
      decode.success(ReceiptRequest(customer_id, order_id, email, amount))
    },
  )
}

/// "Sends" a receipt by recording it in the app's own table, deduplicated
/// by the customer's order.
pub fn receipt_worker() -> Worker(ReceiptRequest, String, Nil) {
  let string_codec = codecs.JsonCodec("text-1", json.string, decode.string)
  worker.responding(
    "checkout.receipt",
    input: codecs.to_grind(receipt_codec()),
    output: codecs.to_grind(string_codec),
    handle: fn(context, receipt: ReceiptRequest) {
      let message_id =
        "msg-"
        <> domain.order_key(receipt.customer_id, receipt.order_id)
        <> "-"
        <> int.to_string(receipt.amount_cents)
      db.record_receipt(
        worker.connection(context),
        receipt.customer_id,
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
