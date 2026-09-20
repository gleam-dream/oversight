// THROWAWAY: Project a returned Saga local report onto a small Sinal event.
import lab/blueprint
import lab/saga
import lab/sinal
import lab/sinal_fields as fields
import lab/value

pub type ExecutionDisposition {
  ExecutionSucceeded
  ExecutionFailed
  ExecutionCancelled
}

pub type ExecutionMeasurements {
  ExecutionMeasurements(uncompensated: Int, undo_failures: Int)
}

pub type ExecutionMetadata {
  ExecutionMetadata(disposition: ExecutionDisposition)
}

pub opaque type ExecutionFact(o, e, u) {
  ExecutionFact(
    report: saga.LocalReport(o, e, u),
    measurements: ExecutionMeasurements,
    metadata: ExecutionMetadata,
  )
}

pub fn execution_fact(
  report: saga.LocalReport(o, e, u),
) -> ExecutionFact(o, e, u) {
  case report {
    saga.LocalExecutionSucceeded(_, uncompensated) ->
      ExecutionFact(
        report,
        ExecutionMeasurements(list_length(uncompensated), 0),
        ExecutionMetadata(ExecutionSucceeded),
      )
    saga.LocalExecutionFailed(failure, uncompensated) -> {
      let #(disposition, undo_failures) = case failure {
        saga.LocalFailed(_, failures) -> #(
          ExecutionFailed,
          list_length(failures),
        )
        saga.LocalCancelled(failures) -> #(
          ExecutionCancelled,
          list_length(failures),
        )
      }
      ExecutionFact(
        report,
        ExecutionMeasurements(list_length(uncompensated), undo_failures),
        ExecutionMetadata(disposition),
      )
    }
  }
}

pub fn fact_report(fact: ExecutionFact(o, e, u)) -> saga.LocalReport(o, e, u) {
  fact.report
}

pub fn fact_measurements(
  fact: ExecutionFact(o, e, u),
) -> ExecutionMeasurements {
  fact.measurements
}

pub fn fact_metadata(fact: ExecutionFact(o, e, u)) -> ExecutionMetadata {
  fact.metadata
}

pub fn execution_event() -> sinal.Event(
  ExecutionMeasurements,
  ExecutionMetadata,
) {
  let assert Ok(base_measurements) =
    fields.pair(
      fields.field("uncompensated", blueprint.int()),
      fields.field("undo_failures", blueprint.int()),
    )
  let measurements =
    fields.imap(
      base_measurements,
      fn(pair) {
        let #(uncompensated, undo_failures) = pair
        ExecutionMeasurements(uncompensated, undo_failures)
      },
      fn(measurements) {
        let ExecutionMeasurements(uncompensated, undo_failures) = measurements
        #(uncompensated, undo_failures)
      },
    )
  let metadata =
    fields.imap(
      fields.field("disposition", disposition_codec()),
      ExecutionMetadata,
      fn(metadata) {
        let ExecutionMetadata(disposition) = metadata
        disposition
      },
    )
  sinal.event(
    ["saga", "local", "execution", "finished"],
    measurements,
    metadata,
  )
}

pub fn emit_finished(
  backend: sinal.Backend,
  fact: ExecutionFact(o, e, u),
) -> Result(Nil, sinal.EmitError) {
  sinal.emit(backend, execution_event(), fact.measurements, fact.metadata)
}

fn disposition_codec() -> blueprint.Codec(ExecutionDisposition) {
  blueprint.new(
    fn(disposition) {
      let encoded = case disposition {
        ExecutionSucceeded -> "succeeded"
        ExecutionFailed -> "failed"
        ExecutionCancelled -> "cancelled"
      }
      Ok(value.Text(encoded))
    },
    fn(raw) {
      case raw {
        value.Text("succeeded") -> Ok(ExecutionSucceeded)
        value.Text("failed") -> Ok(ExecutionFailed)
        value.Text("cancelled") -> Ok(ExecutionCancelled)
        _ -> Error(blueprint.CannotDecode("unknown Saga execution disposition"))
      }
    },
  )
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}
