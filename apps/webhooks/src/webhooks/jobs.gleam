//// Reading a delivery job back from its id (the API hands out job ids, not
//// typed handles).
////
//// Glue for a grind defect: every non-failure acknowledgement (succeeded,
//// snoozed, discarded, cancelled, runtime_failed) writes
//// `error_version = NULL`, and `postgres.bind_handle` compares that column
//// with the worker's error codec version. A worker defined with
//// `define_with_error_codec` therefore cannot re-bind its own finished job:
//// `CodecContractMismatch(ErrorCodec, "delivery-error-v1", "none")`. The
//// workaround binds through a twin definition without an error codec.

import grind/job
import grind/postgres
import grind/worker.{type Worker}
import webhooks/attempt.{type Delivery, type DeliveryError, type Receipt}

pub fn outcome(
  jobs: postgres.Database,
  definition: Worker(Delivery, Receipt, DeliveryError),
  id: Int,
) -> Result(job.Outcome(Receipt, DeliveryError), postgres.JobReadError) {
  case postgres.bind_handle(jobs, definition, id) {
    Ok(handle) -> postgres.outcome(jobs, handle)
    Error(postgres.CodecContractMismatch(kind: worker.ErrorCodec, ..)) ->
      case postgres.bind_handle(jobs, twin(), id) {
        Ok(handle) -> postgres.outcome(jobs, handle)
        Error(e) -> Error(e)
      }
    Error(e) -> Error(e)
  }
}

/// Same identity and input/output codecs, no error codec. Never registered.
fn twin() -> Worker(Delivery, Receipt, DeliveryError) {
  let assert Ok(definition) =
    worker.define(
      "webhooks.deliver",
      "v1",
      attempt.delivery_codec(),
      attempt.receipt_codec(),
      fn(_) { Error(attempt.Internal("read-only twin")) },
    )
  definition
}
