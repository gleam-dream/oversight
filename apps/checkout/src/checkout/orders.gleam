//// Order placement and finalisation. Placement records the pending order
//// and admits its checkout job in one transaction; the job drives the saga
//// through `saga/durable` and records the outcome on the order
//// (`finalize`). The sweeper (`checkout/sweeper`) resolves an order whose
//// job ended without recording one.

import checkout/codecs
import checkout/db
import checkout/domain.{
  type Booked, type CheckoutError, type CheckoutRequest, type Order,
  type OrderRef, type OrderStatus, type UndoError,
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

/// The checkout settled on `report`, and writing it to the order row
/// failed. The report says what happened at the providers; the order row
/// does not.
pub type Unrecorded {
  Unrecorded(report: Report)
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
      log_internal(
        domain.order_id_to_string(request.order_id),
        "catalog lookup failed",
        error,
      )
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
      log_internal(order_text(order), "order insert failed", error)
      Error(StoreUnavailable)
    }
  }
}

/// Records the pending order, enqueues its checkout job and names the job
/// on the order, in one transaction, once per order id. The job id is
/// derived from the order as well, so even a lost commit reply converges on
/// the first job. A store failure is logged; the caller learns only that
/// admission did not commit.
pub fn place(
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
      Started(Nil) -> {
        use admission <- result.try(
          grind.submit_in(s.jobs, tx, checkout)
          |> result.map_error(fn(error) {
            log_internal(
              order_text(order),
              "durable admission failed",
              grind.describe_submit_error(error),
            )
            StoreUnavailable
          }),
        )
        let job_id = job.id(grind.handle(admission))
        use Nil <- result.try(
          db.set_job(tx, order, job_id)
          |> result.map_error(fn(error) {
            log_internal(order_text(order), "job not recorded", error)
            StoreUnavailable
          }),
        )
        Ok(Started(job_id))
      }
    }
  })
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionRolledBack(error) -> error
      pog.TransactionQueryError(error) -> {
        log_internal(order_text(order), "durable admission failed", error)
        StoreUnavailable
      }
    }
  })
}

fn order_text(order: Order) -> String {
  domain.order_id_to_string(order.order_id)
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

/// Records the saga outcome on the order and returns the report of what
/// was recorded. A confirmed order and its receipt job commit in one
/// transaction. When the write fails the order row is unchanged and the
/// result is `Unrecorded`: the caller must not present the outcome as the
/// order's state, and may call `finalize` again with the same outcome.
pub fn finalize(
  s: Services,
  order: OrderRef,
  outcome: Outcome,
) -> Result(Report, Unrecorded) {
  let unknown = list.length(execution.unknown_effects(outcome))
  case outcome {
    execution.Completed(booked)
    | execution.CompletedWithUnknownEffects(booked, _) -> {
      let detail =
        "charge "
        <> booked.charged.charge_id
        <> ", shipment "
        <> booked.shipment_id
      let report = Report(domain.Confirmed, detail, Error(Nil), [], unknown)
      case confirm_with_receipt(s, order, detail) {
        Ok(_) -> Ok(report)
        Error(error) -> {
          log_internal(order.order_id, "confirmation not recorded", error)
          Error(Unrecorded(report))
        }
      }
    }
    execution.Failed(cause, settlement) -> {
      let #(detail, error) = describe_cause(cause)
      log_cause(order.order_id, error)
      record(
        s,
        order,
        Report(
          domain.Rejected,
          detail,
          error,
          list.map(settlement.undone, saga.address_to_string),
          unknown,
        ),
      )
    }
    execution.Unresolved(step, failure, settlement) -> {
      let evidence = case failure {
        saga.Returned(error) -> error
        saga.Crashed(_) | saga.TimedOut ->
          domain.Interrupted(saga.address_to_string(step))
      }
      log_cause(order.order_id, Ok(evidence))
      let detail =
        saga.address_to_string(step)
        <> " held: "
        <> domain.describe_error(evidence)
      record(
        s,
        order,
        Report(
          domain.NeedsReconciliation,
          detail,
          Ok(evidence),
          list.map(settlement.undone, saga.address_to_string),
          unknown,
        ),
      )
    }
    execution.Cancelled(reason, settlement) -> {
      let detail = case reason {
        execution.CancelRequested -> "cancelled: requested"
        execution.OwnerExited -> "cancelled: owner exited"
      }
      record(
        s,
        order,
        Report(
          domain.Rejected,
          detail,
          Error(Nil),
          list.map(settlement.undone, saga.address_to_string),
          unknown,
        ),
      )
    }
  }
}

/// Writes the report's status and detail to the order row. The report is
/// returned only when the row holds it.
pub fn record(
  s: Services,
  order: OrderRef,
  report: Report,
) -> Result(Report, Unrecorded) {
  case db.set_status(s.pool, order, report.status, report.detail) {
    Ok(Nil) -> Ok(report)
    Error(error) -> {
      log_internal(order.order_id, "outcome not recorded", error)
      Error(Unrecorded(report))
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
  order: OrderRef,
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
  order: OrderRef,
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
  |> job.with_id("receipt:" <> domain.ref_key(order))
  |> job.with_correlation(telemetry.order(domain.ref_key(order)))
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
