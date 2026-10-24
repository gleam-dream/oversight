import financial_recovery/domain.{type Payment}
import financial_recovery/payments
import financial_recovery/provider
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/string
import gleam/time/duration
import grind
import grind/job
import grind/worker
import http_gun/error as http_error
import pog
import saga
import saga/codec
import saga/durable
import saga/execution
import saga/storage
import sinal
import sinal/fields

pub type Deps {
  Deps(
    connection: pog.Connection,
    storage: storage.Storage,
    provider: provider.Provider,
  )
}

pub type Admission {
  Queued(job.JobHandle(Payment, String, Nil))
  Completed(String)
}

pub type AdmissionError {
  PaymentRejected(domain.Error)
  QueueRejected(grind.SubmitError(Payment, String, Nil))
  TransactionUnconfirmed(pog.QueryError)
}

pub fn definition(deps: Deps) -> worker.Worker(Payment, String, Nil) {
  worker.responding(
    "financial.coordinate",
    input: worker.codec(fn(p) { Ok(domain.encode(p)) }, domain.decoder()),
    output: worker.codec(fn(s) { Ok(json.string(s)) }, decode.string),
    handle: fn(_, payment) { coordinate(deps, payment) },
  )
  |> worker.with_queue("payments")
}

pub fn delivery(
  worker: worker.Worker(Payment, String, Nil),
  payment: Payment,
) -> job.Job(Payment, String, Nil) {
  job.new(worker, payment)
  |> job.with_id("coordinate:" <> domain.id(payment.id))
}

pub fn admit_in(
  jobs: grind.Grind,
  worker: worker.Worker(Payment, String, Nil),
  tx: pog.Connection,
  payment: Payment,
) -> Result(Admission, AdmissionError) {
  use Nil <- result.try(
    payments.reserve_in(tx, payment) |> result.map_error(PaymentRejected),
  )
  use operation <- result.try(
    payments.read(tx, payment.id) |> result.map_error(PaymentRejected),
  )
  case operation.state {
    domain.Posted(reference) -> Ok(Completed(reference))
    domain.Reserved | domain.Confirmed(_) ->
      grind.submit_in(jobs, tx, delivery(worker, payment))
      |> result.map(fn(admission) { Queued(grind.handle(admission)) })
      |> result.map_error(QueueRejected)
  }
}

pub fn admit(
  jobs: grind.Grind,
  worker: worker.Worker(Payment, String, Nil),
  payment: Payment,
) -> Result(Admission, AdmissionError) {
  pog.transaction(grind.connection(jobs), fn(tx) {
    admit_in(jobs, worker, tx, payment)
  })
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionRolledBack(error) -> error
      pog.TransactionQueryError(error) -> TransactionUnconfirmed(error)
    }
  })
}

pub type Fault {
  UncertainEffect(detail: String)
  RefusedEffect(detail: String)
}

pub fn run_id(payment: Payment) -> String {
  "payment:" <> domain.id(payment.id)
}

pub fn posting_committed() -> sinal.Event(Nil, String) {
  sinal.event(
    ["financial_recovery", "posting", "committed"],
    fields.empty(),
    fields.string("operation"),
  )
}

fn payment_codec() -> codec.Codec(Payment) {
  codec.json("payment-1", fn(p) { Ok(domain.encode(p)) }, domain.decoder())
}

fn fault_codec() -> codec.Codec(Fault) {
  codec.json(
    "fault-1",
    fn(fault) {
      Ok(
        json.object([
          #(
            "unknown",
            json.bool(case fault {
              UncertainEffect(_) -> True
              RefusedEffect(_) -> False
            }),
          ),
          #(
            "detail",
            json.string(case fault {
              UncertainEffect(detail) | RefusedEffect(detail) -> detail
            }),
          ),
        ]),
      )
    },
    {
      use unknown <- decode.field("unknown", decode.bool)
      use detail <- decode.field("detail", decode.string)
      decode.success(case unknown {
        True -> UncertainEffect(detail)
        False -> RefusedEffect(detail)
      })
    },
  )
}

pub fn start(
  deps: Deps,
  payment: Payment,
) -> Result(durable.Run(Payment, String, Fault, String), durable.Error) {
  let transfer =
    saga.effect("transfer", fn(payment: Payment, _key) {
      use state <- result.try(admitted_state(deps, payment))
      case state {
        domain.Confirmed(_) | domain.Posted(_) -> Ok(payment)
        domain.Reserved -> submit_reserved(deps, payment)
      }
    })
    |> saga.unknown_when(fn(fault) {
      case fault {
        UncertainEffect(_) -> True
        RefusedEffect(_) -> False
      }
    })
    |> durable.recoverable(
      version: "1",
      input: payment_codec(),
      output: payment_codec(),
      resolve: fn(payment, _) { resolve_transfer(deps, payment) },
    )
  let post =
    saga.effect("post", fn(payment: Payment, _key) {
      use reference <- result.map(
        payments.post(deps.connection, payment.id)
        |> result.map_error(fn(error) { UncertainEffect(string.inspect(error)) }),
      )
      sinal.emit(posting_committed(), Nil, domain.id(payment.id))
      reference
    })
    |> saga.unknown_when(fn(_) { True })
    |> durable.recoverable(
      version: "1",
      input: payment_codec(),
      output: codec.text(),
      resolve: fn(payment, _) {
        case payments.posting(deps.connection, payment.id) {
          Ok(reference) -> durable.Completed(reference)
          Error(_) -> durable.MaybeSent
        }
      },
    )
  let workflow =
    saga.define("financial_recovery", fn(input) {
      input |> saga.perform(transfer) |> saga.perform(post)
    })
  let persistence =
    durable.new(
      workflow,
      input: payment_codec(),
      output: codec.text(),
      error: fault_codec(),
      undo_error: codec.text(),
    )
    |> durable.with_config(
      execution.config()
      |> execution.with_step_timeout(execution.After(duration.seconds(25))),
    )
  durable.start_or_reconnect(
    persistence,
    deps.storage,
    id: run_id(payment),
    input: payment,
  )
}

pub fn coordinate(
  deps: Deps,
  payment: Payment,
) -> worker.Response(String, Nil) {
  case
    start(deps, payment)
    |> result.try(durable.drive(_, timeout: duration.seconds(30)))
  {
    Ok(execution.Completed(reference)) -> worker.Succeeded(reference)
    Ok(outcome) ->
      held(
        payment,
        "Saga ended without settled completion: " <> string.inspect(outcome),
      )
    Error(error) ->
      case durable.error_kind(error) {
        durable.Busy | durable.Transient ->
          worker.Snoozed(
            after: duration.milliseconds(50),
            reason: durable.describe_error(error),
          )
        durable.NeedsReconciliation | durable.Incompatible | durable.Defect ->
          held(payment, durable.describe_error(error))
      }
  }
}

fn resolve_transfer(
  deps: Deps,
  payment: Payment,
) -> durable.Evidence(Payment, Fault) {
  case admitted_state(deps, payment) {
    Ok(domain.Confirmed(_)) | Ok(domain.Posted(_)) -> durable.Completed(payment)
    Ok(domain.Reserved) -> lookup_transfer(deps, payment)
    Error(_) -> durable.MaybeSent
  }
}

fn admitted_state(deps: Deps, payment: Payment) -> Result(domain.State, Fault) {
  use operation <- result.try(
    payments.read(deps.connection, payment.id)
    |> result.map_error(fn(error) {
      case error {
        domain.OperationMissing ->
          RefusedEffect("financial operation was not admitted")
        _ -> UncertainEffect(string.inspect(error))
      }
    }),
  )
  case operation.payment == payment {
    True -> Ok(operation.state)
    False ->
      Error(RefusedEffect("financial operation identity has different intent"))
  }
}

fn submit_reserved(deps: Deps, payment: Payment) -> Result(Payment, Fault) {
  use reference <- result.try(
    provider.submit(deps.provider, payment)
    |> result.map_error(fn(failure) {
      case failure {
        provider.Transport(failure) ->
          case http_error.evidence(failure) {
            http_error.NotSent -> RefusedEffect(http_error.describe(failure))
            http_error.MaybeSent ->
              UncertainEffect(http_error.describe(failure))
          }
        _ -> UncertainEffect(string.inspect(failure))
      }
    }),
  )
  payments.evidence(deps.connection, payment.id, reference)
  |> result.replace(payment)
  |> result.map_error(fn(error) { UncertainEffect(string.inspect(error)) })
}

fn lookup_transfer(
  deps: Deps,
  payment: Payment,
) -> durable.Evidence(Payment, Fault) {
  case provider.lookup(deps.provider, payment.id) {
    Ok(reference) ->
      case payments.evidence(deps.connection, payment.id, reference) {
        Ok(Nil) -> durable.Completed(payment)
        Error(_) -> durable.MaybeSent
      }
    // Even 404 is not authoritative in this provider contract. No unknown
    // lookup permits another payment, or releases the financial reservation.
    Error(_) -> durable.MaybeSent
  }
}

/// The coordinator has returned from Saga with unresolved evidence. Observers
/// normally record this fact; a test uses it to expose acknowledgement races.
pub fn recovery_held() -> sinal.Event(Nil, String) {
  sinal.event(
    ["financial_recovery", "recovery", "held"],
    fields.empty(),
    fields.string("operation"),
  )
}

fn held(payment: Payment, detail: String) -> worker.Response(String, Nil) {
  sinal.emit(recovery_held(), Nil, domain.id(payment.id))
  worker.Uncertain(detail)
}
