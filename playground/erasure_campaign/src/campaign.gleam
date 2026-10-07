import domain.{type Command, type PreparationError, type Receipt, Receipt}
import evidence
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/time/duration
import grind
import grind/job
import grind/worker
import http_gun
import pog
import saga
import saga/execution

pub type Services {
  Services(client: http_gun.Client, base: String)
}

pub type Gate {
  NoGate
  Gate(process.Subject(process.Subject(Nil)))
}

pub fn request(services: Services, method: http.Method, path: String) {
  let assert Ok(req) = request.to(services.base <> path)
  http_gun.send(
    services.client,
    req |> request.set_method(method) |> request.set_body(<<>>),
  )
}

pub fn lookup(services: Services, command: Command) -> Result(Receipt, Nil) {
  case request(services, http.Get, "/effect/" <> domain.identity(command)) {
    Ok(buffered) if buffered.response.status == 200 -> {
      let assert Ok(reference) = bit_array.to_string(buffered.response.body)
      case reference == "receipt:" <> domain.identity(command) {
        True -> Ok(Receipt(reference))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

pub fn deletion_worker(
  services: Services,
  gate: Gate,
) -> worker.Worker(Command, Receipt, Nil) {
  worker.responding(
    "erasure.target",
    input: worker.codec(worker.infallible(domain.encode), domain.decoder()),
    output: worker.codec(
      worker.infallible(fn(receipt: Receipt) { json.string(receipt.reference) }),
      domain.receipt_decoder(),
    ),
    handle: fn(context, command) {
      case gate {
        NoGate -> Nil
        Gate(entered) -> {
          let release = process.new_subject()
          process.send(entered, release)
          let assert Ok(Nil) = process.receive(release, 10_000)
          Nil
        }
      }
      let db = worker.connection(context)
      case evidence.read(db, command) {
        evidence.Confirmed(receipt) -> worker.Succeeded(receipt)
        evidence.Rejected -> worker.Discarded("authoritative target rejection")
        evidence.Pending ->
          worker.Uncertain("application attempt pending; lookup required")
        evidence.Unseen -> {
          case evidence.begin(db, command) {
            False -> worker.Uncertain("another delivery owns attempt evidence")
            True -> perform(services, db, command)
          }
        }
      }
    },
  )
  |> worker.with_queue("erasure")
}

fn perform(
  services: Services,
  db: pog.Connection,
  command: Command,
) -> worker.Response(Receipt, Nil) {
  case request(services, http.Delete, "/effect/" <> domain.identity(command)) {
    Ok(buffered) if buffered.response.status == 200 -> {
      let assert Ok(reference) = bit_array.to_string(buffered.response.body)
      case reference == "receipt:" <> domain.identity(command) {
        True -> {
          let receipt = Receipt(reference)
          evidence.confirm(db, command, receipt)
          worker.Succeeded(receipt)
        }
        False -> worker.Uncertain("invalid receipt after deletion request")
      }
    }
    Ok(buffered) if buffered.response.status == 409 -> {
      evidence.reject(db, command)
      worker.Discarded("fixture guarantees 409 has no effect")
    }
    Error(failure) -> {
      evidence.transport_failure(db, command, failure)
      worker.Uncertain("deletion response lost; lookup required")
    }
    Ok(_) -> worker.Uncertain("unclassified response; lookup required")
  }
}

pub fn submit(
  jobs: grind.Grind,
  worker: worker.Worker(Command, Receipt, Nil),
  command: Command,
) {
  let assert Ok(admission) = grind.submit(jobs, job.new(worker, command))
  grind.handle(admission)
}

pub type TargetResult {
  Erased(Command, Receipt)
  Refused(Command)
}

pub type CampaignResult {
  Finished(results: List(TargetResult))
  StoppedAfterRejection(results: List(TargetResult), remaining: List(Command))
  AdmissionNeedsInvestigation(
    results: List(TargetResult),
    command: Command,
    error: grind.SubmitError(Command, Receipt, Nil),
    remaining: List(Command),
  )
  NeedsInvestigation(
    results: List(TargetResult),
    command: Command,
    handle: job.JobHandle(Command, Receipt, Nil),
    observed: Result(grind.Outcome(Receipt, Nil), grind.ReadError),
    remaining: List(Command),
  )
}

/// Explicit campaign policy governs admission after a known target rejection.
/// Uncertainty stops admission under either policy.
pub fn execute_targets(
  jobs: grind.Grind,
  worker: worker.Worker(Command, Receipt, Nil),
  commands: List(Command),
  policy: domain.Policy,
) -> CampaignResult {
  execute_remaining(jobs, worker, commands, policy, [])
}

fn execute_remaining(jobs, worker, commands, policy, results) {
  case commands {
    [] -> Finished(list.reverse(results))
    [command, ..rest] -> {
      case grind.submit(jobs, job.new(worker, command)) {
        Error(error) ->
          AdmissionNeedsInvestigation(
            list.reverse(results),
            command,
            error,
            rest,
          )
        Ok(admission) -> {
          let handle = grind.handle(admission)
          case grind.await(jobs, handle, within: duration.seconds(5)) {
            Ok(grind.Succeeded(receipt)) ->
              execute_remaining(jobs, worker, rest, policy, [
                Erased(command, receipt),
                ..results
              ])
            Ok(grind.Discarded(_)) ->
              case policy {
                domain.StopOnRejection ->
                  StoppedAfterRejection(
                    list.reverse([Refused(command), ..results]),
                    rest,
                  )
                domain.ContinueOnRejection ->
                  execute_remaining(jobs, worker, rest, policy, [
                    Refused(command),
                    ..results
                  ])
              }
            observed ->
              NeedsInvestigation(
                list.reverse(results),
                command,
                handle,
                observed,
                rest,
              )
          }
        }
      }
    }
  }
}

pub fn prepare(db: pog.Connection, operation: String, fail_plan: Bool) {
  let freeze =
    saga.step("freeze_export", fn(operation: String) -> Result(
      String,
      PreparationError,
    ) {
      let assert Ok(_) =
        pog.query(
          "INSERT INTO erasure_preparation(operation,frozen,staged) VALUES($1,true,false)",
        )
        |> pog.parameter(pog.text(operation))
        |> pog.execute(db)
      Ok(operation)
    })
    |> saga.undo(fn(undo) -> Result(Nil, PreparationError) {
      let assert Ok(_) =
        pog.query(
          "UPDATE erasure_preparation SET frozen=false,undos=undos+1 WHERE operation=$1",
        )
        |> pog.parameter(pog.text(undo.output))
        |> pog.execute(db)
      Ok(Nil)
    })
  let stage =
    saga.step("stage_plan", fn(operation: String) {
      case fail_plan {
        True -> Error(domain.PlanRejected)
        False -> {
          let assert Ok(_) =
            pog.query(
              "UPDATE erasure_preparation SET staged=true WHERE operation=$1",
            )
            |> pog.parameter(pog.text(operation))
            |> pog.execute(db)
          Ok(operation)
        }
      }
    })
  let workflow =
    saga.define("erasure_preparation", fn(input) {
      input |> saga.perform(freeze) |> saga.perform(stage)
    })
  execution.run(workflow, operation, execution.config())
}

/// Normal success releases temporary preparation; it does not undo deletions.
pub fn release_preparation(db: pog.Connection, operation: String) {
  let assert Ok(rows) =
    pog.query(
      "UPDATE erasure_preparation SET frozen=false,staged=false WHERE operation=$1",
    )
    |> pog.parameter(pog.text(operation))
    |> pog.execute(db)
  assert rows.count == 1
}
