//// The durable checkout: a grind job whose handler drives the checkout saga
//// through `saga/durable`, on saga_postgres.
////
//// Grind owns delivery and redelivery; saga owns progress and compensation.
//// The handler maps saga's durable results onto grind's responses: a busy
//// execution or a lost runner snoozes the job (redelivery resumes from the
//// last checkpoint; a killed runner releases its claim, so that resume is
//// immediate), and a saga that needs reconciliation becomes a grind
//// `Uncertain` job, which needs an audited operator resolution.
////
//// The handler is idempotent by construction (the saga checkpoint decides
//// what runs), so an abandoned attempt is replayed after its lease expires
//// instead of waiting for an operator. `drive` is bounded by the handler's
//// own deadline and stops its runner when the handler process dies.

import checkout/codecs
import checkout/domain.{
  type Booked, type CheckoutError, type OrderRequest, type UndoError,
}
import checkout/orders.{type Services}
import checkout/telemetry
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/time/duration.{type Duration}
import gleam/time/timestamp
import grind/worker.{type Worker}
import saga/durable
import saga/execution

/// How long one attempt may drive the saga. The worker's timeout is a
/// little longer, so `drive` returns before grind stops the handler.
fn attempt_budget() -> Duration {
  duration.seconds(60)
}

pub fn execution_id(order: OrderRequest) -> String {
  "checkout:" <> order.order_id
}

/// `redelivery` is the snooze after a lost runner or a storage failure;
/// `busy` the snooze while another runner's claim holds the execution. A
/// killed runner releases its claim, so only a lost node leaves one behind,
/// and the claim lasts saga_postgres's lease: `busy` should be at least that,
/// or grind's snooze cap ends the job before the lease does.
pub fn checkout_worker(
  s: Services,
  redelivery redelivery: Duration,
  busy busy: Duration,
) -> Worker(OrderRequest, String, Nil) {
  let summary = codecs.JsonCodec("summary-1", json.string, decode.string)
  worker.responding(
    "checkout.run",
    input: codecs.to_grind(codecs.order()),
    output: codecs.to_grind(summary),
    handle: fn(context, order) { drive(s, context, order, redelivery, busy) },
  )
  |> worker.with_queue(orders.checkouts_queue)
  |> worker.with_timeout(
    worker.After(duration.add(attempt_budget(), duration.seconds(5))),
  )
  |> worker.with_abandonment(worker.ReplayAfterLeaseExpiry(max_replays: 3))
}

fn drive(
  s: Services,
  context: worker.Context,
  order: OrderRequest,
  redelivery: Duration,
  busy: Duration,
) -> worker.Response(String, Nil) {
  let driven = case
    durable.start_or_reconnect(
      s.persistence,
      s.storage,
      id: execution_id(order),
      input: order,
    )
  {
    Error(error) -> Error(error)
    Ok(run) ->
      run
      |> durable.with_correlation(telemetry.order(order.order_id))
      |> drive_until_cancelled(context, budget(context))
  }
  case driven {
    Ok(outcome) -> {
      let report = orders.finalize(s, order, outcome)
      case outcome {
        execution.Unresolved(..) -> worker.Uncertain(report.detail)
        execution.Cancelled(..) -> worker.Cancelled(report.detail)
        _ ->
          worker.Succeeded(
            domain.status_to_string(report.status) <> ": " <> report.detail,
          )
      }
    }
    Error(error) ->
      case durable.error_kind(error) {
        durable.Busy ->
          worker.Snoozed(after: busy, reason: durable.describe_error(error))
        durable.Transient ->
          worker.Snoozed(
            after: redelivery,
            reason: durable.describe_error(error),
          )
        durable.NeedsReconciliation | durable.Incompatible | durable.Defect ->
          worker.Uncertain(durable.describe_error(error))
      }
  }
}

type Driving {
  Driven(
    Result(execution.Outcome(Booked, CheckoutError, UndoError), durable.Error),
  )
  CancelRequested
}

/// `durable.drive` blocks its caller, and grind delivers a cancellation to
/// the handler's own mailbox, so the drive runs in a linked process while
/// the handler waits for either. A cancellation is recorded with
/// `durable.cancel`; the runner rolls back at its next checkpoint. The
/// runner still stops when the handler dies, through the link.
fn drive_until_cancelled(
  run: durable.Run(OrderRequest, Booked, CheckoutError, UndoError),
  context: worker.Context,
  timeout: Duration,
) -> Result(execution.Outcome(Booked, CheckoutError, UndoError), durable.Error) {
  let reply = process.new_subject()
  process.spawn(fn() { process.send(reply, durable.drive(run, timeout:)) })
  let driving =
    process.new_selector()
    |> process.select_map(reply, Driven)
    |> process.merge_selector(
      process.map_selector(worker.cancellation(context), fn(_) {
        CancelRequested
      }),
    )
  let wait =
    duration.to_milliseconds(duration.add(timeout, duration.seconds(1)))
  case process.selector_receive(driving, wait) {
    Ok(Driven(result)) -> result
    Ok(CancelRequested) -> {
      let _ = durable.cancel(run)
      process.receive(reply, wait)
      |> result.unwrap(Error(durable.DriveTimedOut))
    }
    Error(Nil) -> Error(durable.DriveTimedOut)
  }
}

/// The time left before grind stops the handler, less a margin to save the
/// outcome and acknowledge.
fn budget(context: worker.Context) -> Duration {
  case worker.deadline(context) {
    None -> attempt_budget()
    Some(deadline) -> {
      let left =
        timestamp.difference(timestamp.system_time(), deadline)
        |> duration.subtract(duration.seconds(5))
      let floor = duration.milliseconds(1)
      case duration.compare(left, floor) {
        order.Lt -> floor
        _ -> left
      }
    }
  }
}
