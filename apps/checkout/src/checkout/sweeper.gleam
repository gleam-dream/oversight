//// Resolves pending orders that nothing will finish.
////
//// Placement records a pending order and admits its checkout job in one
//// transaction, and the job ends only after the order row holds the saga's
//// outcome. An order can still stay pending: an operator cancels its job, a
//// job runs out of snoozes or replays while the store refuses the write, or
//// the order was placed before checkout was durable and has no job. The
//// sweeper finds orders pending for longer than `stale_after` and resolves
//// each one by what is known about it:
////
//// | Known | Recorded |
//// | --- | --- |
//// | the job is still running or waiting | nothing yet |
//// | the job is uncertain | `needs_reconciliation` |
//// | the job ended and the saga finished | the saga's outcome, as the job would have (`orders.finalize`) |
//// | the job ended and the saga did not finish | `needs_reconciliation` |
//// | the job ended and the saga never started | `rejected`: nothing reached a provider |
//// | the order has no job | `needs_reconciliation`: nothing records what its saga did |
////
//// It never runs a saga step: a saga that did not finish may have charged
//// or booked, so an operator reconciles it with the providers by the order
//// key. A write that fails is left for the next sweep.

import checkout/db
import checkout/domain.{type Order, type OrderRef, type OrderStatus}
import checkout/jobs
import checkout/orders.{type Services}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import grind
import grind/worker.{type Worker}
import saga/durable
import saga/storage
import wisp

/// How many orders one sweep looks at.
const batch = 100

/// What a sweep did with one order.
pub type Resolution {
  /// The order's status is now this.
  Recorded(OrderStatus)
  /// The order's job is still running or waiting to run.
  StillRunning
  /// Nothing could be decided or written now; the next sweep tries again.
  Deferred
}

/// Looks at the pending orders unchanged for `stale_after` and resolves
/// each one it can. Returns each order id with what was done.
pub fn sweep(
  s: Services,
  checkout_worker: Worker(Order, String, Nil),
  stale_after stale_after: Duration,
) -> Result(List(#(String, Resolution)), String) {
  use pending <- result.map(
    db.stale_pending(s.pool, stale_after, limit: batch)
    |> result.map_error(string.inspect),
  )
  list.map(pending, fn(order) {
    #(order.ref.order_id, resolve(s, checkout_worker, order))
  })
}

fn resolve(
  s: Services,
  checkout_worker: Worker(Order, String, Nil),
  order: db.PendingOrder,
) -> Resolution {
  case order.job_id {
    None -> hold(s, order.ref, "placed without a checkout job")
    Some(job_id) ->
      case job_state(s, checkout_worker, job_id) {
        Error(reason) -> defer(order.ref, reason)
        Ok(grind.Pending(_)) -> StillRunning
        Ok(grind.Uncertain(evidence)) -> {
          log(order.ref, "checkout job uncertain: " <> evidence)
          hold(s, order.ref, "checkout job uncertain")
        }
        Ok(grind.Succeeded(_))
        | Ok(grind.Failed(..))
        | Ok(grind.Discarded(_))
        | Ok(grind.Cancelled(_)) -> settle_from_saga(s, order.ref)
      }
  }
}

fn job_state(
  s: Services,
  checkout_worker: Worker(Order, String, Nil),
  job_id: Int,
) -> Result(grind.Outcome(String, Nil), String) {
  use handle <- result.try(
    grind.bind(s.jobs, checkout_worker, job_id)
    |> result.map_error(grind.describe_read_error),
  )
  grind.await(s.jobs, handle, within: duration.milliseconds(0))
  |> result.map_error(grind.describe_read_error)
}

/// The job ended without recording the outcome: record what the saga
/// saved.
fn settle_from_saga(s: Services, order: OrderRef) -> Resolution {
  let id = jobs.execution_id_of(domain.ref_key(order))
  case durable.reconnect(s.persistence, s.storage, id:) {
    Error(durable.StorageFailure(storage.NotFound)) ->
      record(s, order, domain.Rejected, "checkout did not start")
    Error(error) -> defer(order, durable.describe_error(error))
    Ok(run) ->
      case durable.read(run) {
        Error(error) -> defer(order, durable.describe_error(error))
        Ok(durable.Finished(outcome)) ->
          case orders.finalize(s, order, outcome) {
            Ok(report) -> Recorded(report.status)
            Error(orders.Unrecorded(_)) -> Deferred
          }
        Ok(durable.Pending) | Ok(durable.Suspended(_)) ->
          hold(s, order, "checkout stopped before it finished")
      }
  }
}

fn hold(s: Services, order: OrderRef, detail: String) -> Resolution {
  record(s, order, domain.NeedsReconciliation, detail)
}

fn record(
  s: Services,
  order: OrderRef,
  status: OrderStatus,
  detail: String,
) -> Resolution {
  case
    orders.record(s, order, orders.Report(status, detail, Error(Nil), [], 0))
  {
    Ok(_) -> Recorded(status)
    Error(orders.Unrecorded(_)) -> Deferred
  }
}

fn defer(order: OrderRef, reason: String) -> Resolution {
  log(order, reason)
  Deferred
}

fn log(order: OrderRef, detail: String) -> Nil {
  wisp.log_warning("order " <> order.order_id <> ": sweep: " <> detail)
}

type Message {
  Sweep
}

/// The sweeper as a child of the application's tree: it sweeps every
/// `every`, the first time `every` after it starts. A sweep that fails is
/// logged and the next one runs on time.
pub fn supervised(
  s: Services,
  checkout_worker: Worker(Order, String, Nil),
  every every: Duration,
  stale_after stale_after: Duration,
) -> supervision.ChildSpecification(Nil) {
  let interval = duration.to_milliseconds(every)
  supervision.worker(fn() {
    actor.new_with_initialiser(1000, fn(self) {
      process.send_after(self, interval, Sweep)
      actor.initialised(self) |> actor.returning(Nil) |> Ok
    })
    |> actor.on_message(fn(self, _message: Message) {
      case sweep(s, checkout_worker, stale_after:) {
        Ok(_) -> Nil
        Error(reason) -> wisp.log_warning("sweep failed: " <> reason)
      }
      process.send_after(self, interval, Sweep)
      actor.continue(self)
    })
    |> actor.start
  })
}
