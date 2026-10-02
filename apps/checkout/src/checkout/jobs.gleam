//// The durable checkout: a grind job whose handler drives the checkout saga
//// through `saga/durable`, on the Postgres saga storage.
////
//// Grind owns delivery and redelivery; saga owns progress and compensation.
//// The handler maps saga's durable results onto grind's queue responses:
//// a lost runner or a busy execution snoozes the job (redelivery resumes
//// from the last checkpoint), and a saga that needs reconciliation becomes a
//// grind `Uncertain` job, which needs an audited operator resolution.

import checkout/codecs
import checkout/domain.{type OrderRequest}
import checkout/orders.{type Services}
import checkout/saga_store
import gleam/dynamic/decode
import gleam/json
import gleam/string
import grind/worker.{type Worker}
import saga/durable
import saga/execution
import saga/storage

pub fn execution_id(order: OrderRequest) -> String {
  "checkout:" <> order.order_id
}

pub fn checkout_worker(
  s: Services,
  redelivery_ms: Int,
) -> Worker(OrderRequest, String, Nil) {
  let summary = codecs.JsonCodec("summary-1", json.string, decode.string)
  let assert Ok(w) =
    worker.define(
      "checkout.run",
      "1",
      codecs.to_grind(codecs.order()),
      codecs.to_grind(summary),
      fn(_order) { Error(Nil) },
    )
  let assert Ok(redeliver) = worker.retry_delay(redelivery_ms)
  worker.with_queue_handler(w, fn(order) { drive(s, order, redeliver) })
}

fn drive(
  s: Services,
  order: OrderRequest,
  redeliver: worker.RetryDelay,
) -> worker.WorkerResponse(String, Nil) {
  let id = execution_id(order)
  let store = saga_store.storage(s.store, id)
  let driven = {
    case durable.start_or_reconnect(store, id, s.persistence, order) {
      Error(error) -> Error(error)
      Ok(reference) ->
        durable.drive(store, reference, s.persistence, s.saga_config)
    }
  }
  case driven {
    Ok(outcome) -> {
      let report = orders.finalize(s, order, outcome)
      case outcome {
        execution.Unresolved(..) -> worker.WorkerUncertain(report.detail)
        execution.Cancelled(..) -> worker.WorkerCancelled(report.detail)
        _ ->
          worker.WorkerSucceeded(
            domain.status_to_string(report.status) <> ": " <> report.detail,
          )
      }
    }
    Error(durable.RunnerLost) ->
      worker.WorkerSnoozed(redeliver, "saga runner lost; resume on redelivery")
    Error(durable.StorageError(storage.Busy)) ->
      worker.WorkerSnoozed(redeliver, "saga execution owned by another runner")
    Error(error) -> worker.WorkerUncertain(string.inspect(error))
  }
}
