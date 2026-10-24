//// Application-owned settlement of a finished unresolved payment workflow.

import financial_recovery/coordinator
import financial_recovery/domain
import financial_recovery/payments
import financial_recovery/provider
import gleam/dynamic/decode
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import grind
import grind/admin
import grind/job
import pog
import saga/durable
import saga/execution
import sinal
import sinal/fields

pub type Decision {
  Decision(id: String, by: String, details: String)
}

pub type Record {
  Record(
    decision: Decision,
    job_id: Int,
    operation: domain.OperationId,
    reference: String,
    queue_confirmed: Bool,
  )
}

pub type Error {
  NotFinishedUnresolved
  NotUncertain
  InvalidDecisionField(String)
  DecisionConflict
  MissingDecision
  JobRead(grind.ReadError)
  Workflow(durable.Error)
  Payment(domain.Error)
  Lookup(provider.Error)
  Database(pog.QueryError)
  QueuePending(admin.Error)
  /// The outer confirmation transaction may have committed. Resume by this ID.
  QueueConfirmationUnknown(decision_id: String)
  InvalidLimit
}

pub fn migrate(connection: pog.Connection) -> Result(Nil, Error) {
  pog.query(
    "CREATE TABLE reconciliations (id text PRIMARY KEY, job_id bigint NOT NULL UNIQUE, operation text NOT NULL UNIQUE REFERENCES operations, resolved_by text NOT NULL, details text NOT NULL, reference text NOT NULL, queue_confirmed boolean NOT NULL DEFAULT false)",
  )
  |> pog.execute(connection)
  |> result.replace(Nil)
  |> result.map_error(Database)
}

/// The caller authenticates and authorizes the operator before calling.
/// A decision ID binds one exact job, actor and reason for safe retries.
pub fn reconcile(
  deps: coordinator.Deps,
  jobs: grind.Grind,
  job_id: Int,
  decision: Decision,
) -> Result(Record, Error) {
  use Nil <- result.try(validate(decision))
  case read(deps.connection, decision.id) {
    Ok(record) -> {
      use Nil <- result.try(matches(record, job_id, decision))
      finish(deps, jobs, record)
    }
    Error(MissingDecision) -> {
      case prepare(deps, jobs, job_id) {
        Error(original) -> {
          // Another caller can commit this exact decision while preflight waits.
          // Recheck its authority once, without retrying provider or SQL effects.
          case read(deps.connection, decision.id) {
            Ok(record) -> {
              use Nil <- result.try(matches(record, job_id, decision))
              finish(deps, jobs, record)
            }
            Error(MissingDecision) -> Error(original)
            Error(error) -> Error(error)
          }
        }
        Ok(#(payment, reference)) -> {
          use record <- result.try(record_settlement(
            deps.connection,
            payment,
            Record(decision, job_id, payment.id, reference, False),
          ))
          sinal.emit(settlement_committed(), Nil, decision.id)
          finish(deps, jobs, record)
        }
      }
    }
    Error(error) -> Error(error)
  }
}

fn prepare(
  deps: coordinator.Deps,
  jobs: grind.Grind,
  job_id: Int,
) -> Result(#(domain.Payment, String), Error) {
  use handle <- result.try(
    grind.bind(jobs, coordinator.definition(deps), job_id)
    |> result.map_error(JobRead),
  )
  use state <- result.try(
    grind.state(jobs, handle) |> result.map_error(JobRead),
  )
  use Nil <- result.try(case state {
    job.Uncertain -> Ok(Nil)
    _ -> Error(NotUncertain)
  })
  use payment <- result.try(
    grind.arguments(jobs, handle) |> result.map_error(JobRead),
  )
  use operation <- result.try(
    payments.read(deps.connection, payment.id) |> result.map_error(Payment),
  )
  use Nil <- result.try(case operation.payment == payment {
    True -> Ok(Nil)
    False -> Error(Payment(domain.IdentityConflict))
  })
  use run <- result.try(
    coordinator.start(deps, payment) |> result.map_error(Workflow),
  )
  use status <- result.try(durable.read(run) |> result.map_error(Workflow))
  use Nil <- result.try(case status {
    durable.Finished(execution.Unresolved(_, _, _)) -> Ok(Nil)
    _ -> Error(NotFinishedUnresolved)
  })
  use reference <- result.try(
    provider.lookup(deps.provider, payment.id) |> result.map_error(Lookup),
  )
  Ok(#(payment, reference))
}

pub fn settlement_committed() -> sinal.Event(Nil, String) {
  sinal.event(
    ["financial_recovery", "reconciliation", "committed"],
    fields.empty(),
    fields.string("decision"),
  )
}

pub fn queue_confirmed() -> sinal.Event(Nil, String) {
  sinal.event(
    ["financial_recovery", "reconciliation", "queue_confirmed"],
    fields.empty(),
    fields.string("decision"),
  )
}

/// Bounded discovery for an application-owned recovery loop. No worker starts.
pub fn pending(
  connection: pog.Connection,
  limit: Int,
  after after: option.Option(String),
) -> Result(List(Record), Error) {
  case limit > 0 && limit <= 100 {
    False -> Error(InvalidLimit)
    True ->
      pog.query(
        "SELECT id,job_id,operation,resolved_by,details,reference,queue_confirmed FROM reconciliations WHERE NOT queue_confirmed AND id > $2 ORDER BY id LIMIT $1",
      )
      |> pog.parameter(pog.int(limit))
      |> pog.parameter(pog.text(option.unwrap(after, "")))
      |> pog.returning(record_decoder())
      |> pog.execute(connection)
      |> result.map(fn(rows) { rows.rows })
      |> result.map_error(Database)
  }
}

/// Reuses the committed evidence and exact queue decision after process loss.
pub fn resume(
  deps: coordinator.Deps,
  jobs: grind.Grind,
  id: String,
) -> Result(Record, Error) {
  use record <- result.try(read(deps.connection, id))
  finish(deps, jobs, record)
}

fn validate(decision: Decision) -> Result(Nil, Error) {
  list.try_each(
    [#("id", decision.id), #("by", decision.by), #("details", decision.details)],
    fn(field) {
      case string.trim(field.1) == "" {
        True -> Error(InvalidDecisionField(field.0))
        False -> Ok(Nil)
      }
    },
  )
}

fn matches(
  record: Record,
  job_id: Int,
  decision: Decision,
) -> Result(Nil, Error) {
  case record.job_id == job_id && record.decision == decision {
    True -> Ok(Nil)
    False -> Error(DecisionConflict)
  }
}

fn record_settlement(
  connection: pog.Connection,
  payment: domain.Payment,
  record: Record,
) -> Result(Record, Error) {
  pog.transaction(connection, fn(tx) {
    use _ <- result.try(
      pog.query("SET LOCAL statement_timeout = '1500ms'")
      |> pog.execute(tx)
      |> result.map_error(Database),
    )
    use _ <- result.try(
      pog.query(
        "INSERT INTO reconciliations(id,job_id,operation,resolved_by,details,reference) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING",
      )
      |> pog.parameter(pog.text(record.decision.id))
      |> pog.parameter(pog.int(record.job_id))
      |> pog.parameter(pog.text(domain.id(record.operation)))
      |> pog.parameter(pog.text(record.decision.by))
      |> pog.parameter(pog.text(record.decision.details))
      |> pog.parameter(pog.text(record.reference))
      |> pog.execute(tx)
      |> result.map_error(Database),
    )
    use retained <- result.try(
      read(tx, record.decision.id)
      |> result.map_error(fn(error) {
        case error {
          MissingDecision -> DecisionConflict
          _ -> error
        }
      }),
    )
    use Nil <- result.try(matches(retained, record.job_id, record.decision))
    use Nil <- result.try(
      case
        retained.reference == record.reference
        && retained.operation == payment.id
      {
        True -> Ok(Nil)
        False -> Error(DecisionConflict)
      },
    )
    use _ <- result.try(
      payments.settle_in(tx, payment, record.reference)
      |> result.map_error(Payment),
    )
    Ok(retained)
  })
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionRolledBack(error) -> error
      pog.TransactionQueryError(error) -> Database(error)
    }
  })
}

pub fn read(connection: pog.Connection, id: String) -> Result(Record, Error) {
  use rows <- result.try(
    pog.query(
      "SELECT id,job_id,operation,resolved_by,details,reference,queue_confirmed FROM reconciliations WHERE id=$1",
    )
    |> pog.parameter(pog.text(id))
    |> pog.returning(record_decoder())
    |> pog.execute(connection)
    |> result.map_error(Database),
  )
  list.first(rows.rows) |> result.replace_error(MissingDecision)
}

fn record_decoder() -> decode.Decoder(Record) {
  use id <- decode.field(0, decode.string)
  use job_id <- decode.field(1, decode.int)
  use operation <- decode.field(2, decode.string)
  use by <- decode.field(3, decode.string)
  use details <- decode.field(4, decode.string)
  use reference <- decode.field(5, decode.string)
  use queue_confirmed <- decode.field(6, decode.bool)
  decode.success(Record(
    Decision(id, by, details),
    job_id,
    domain.OperationId(operation),
    reference,
    queue_confirmed,
  ))
}

fn finish(
  deps: coordinator.Deps,
  jobs: grind.Grind,
  record: Record,
) -> Result(Record, Error) {
  case record.queue_confirmed {
    True -> Ok(record)
    False -> {
      case confirm_queue(deps, jobs, record) {
        Ok(confirmed) -> {
          sinal.emit(queue_confirmed(), Nil, record.decision.id)
          Ok(confirmed)
        }
        Error(error) -> {
          // An identical concurrent caller may have committed and the job may
          // already be pruned. The application acknowledgment proves our exact
          // decision; a queue outcome alone would not prove its attribution.
          case read(deps.connection, record.decision.id) {
            Ok(Record(queue_confirmed: True, ..) as confirmed) -> Ok(confirmed)
            _ -> Error(error)
          }
        }
      }
    }
  }
}

fn confirm_queue(
  deps: coordinator.Deps,
  jobs: grind.Grind,
  record: Record,
) -> Result(Record, Error) {
  use handle <- result.try(
    grind.bind(jobs, coordinator.definition(deps), record.job_id)
    |> result.map_error(JobRead),
  )
  let resolution =
    admin.resolution(
      admin.ConfirmSuccess(record.reference),
      id: "financial-reconciliation:" <> record.decision.id,
      by: record.decision.by,
      details: "Application reconciliation confirmed and posted the payment; the original Saga outcome is unchanged. "
        <> record.decision.details,
    )
  pog.transaction(deps.connection, fn(tx) {
    use _ <- result.try(
      pog.query("SET LOCAL statement_timeout = '1500ms'")
      |> pog.execute(tx)
      |> result.map_error(Database),
    )
    use admin.Staged(_) <- result.try(
      admin.resolve_uncertain_in(jobs, tx, handle, resolution)
      |> result.map_error(QueuePending),
    )
    use _ <- result.try(
      pog.query("UPDATE reconciliations SET queue_confirmed=true WHERE id=$1")
      |> pog.parameter(pog.text(record.decision.id))
      |> pog.execute(tx)
      |> result.map_error(Database),
    )
    Ok(Record(..record, queue_confirmed: True))
  })
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionRolledBack(error) -> error
      pog.TransactionQueryError(_) ->
        QueueConfirmationUnknown(record.decision.id)
    }
  })
}
