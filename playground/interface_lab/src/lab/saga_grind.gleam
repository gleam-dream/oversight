// THROWAWAY: Can Saga and Grind expose one explicit durable admission boundary?
import lab/grind
import lab/saga.{type Definition}
import lab/saga_checkpoint as checkpoint
import lab/value.{type Value}

pub opaque type RunHandle(o, e, u) {
  RunHandle(run_id: checkpoint.RunId)
}

pub type SubmitError {
  InputCouldNotEncode
  RunAdmissionFailed
}

// Both modes accept the same durable Definition. Local execution returns an
// opaque lifecycle token, so approval suspension remains visible to the caller.
pub fn run_local(
  definition: Definition(i, o, e, u),
  input: i,
) -> Result(checkpoint.Execution(o, e, u), checkpoint.StartError) {
  checkpoint.start(definition, input)
}

pub fn submit(
  queue: grind.Queue,
  definition: Definition(i, o, e, u),
  input: i,
) -> Result(RunHandle(o, e, u), SubmitError) {
  case saga.encode_input(definition, input) {
    Error(_) -> Error(InputCouldNotEncode)
    Ok(encoded_input) -> {
      let payload =
        value.Object([
          #("definition_id", value.Text(saga.definition_identity(definition))),
          #(
            "definition_version",
            value.Int(saga.definition_version_number(definition)),
          ),
          #(
            "structural_signature",
            value.Text(saga.definition_signature(definition)),
          ),
          #("run_input", encoded_input),
        ])
      admit_run(queue, payload)
    }
  }
}

// This boundary must atomically record the run and admit its worker job. A
// future implementation may use Grind's transactional outbox; no durability is
// claimed by the playground.
fn admit_run(
  _queue: grind.Queue,
  _payload: Value,
) -> Result(RunHandle(o, e, u), SubmitError) {
  todo as "atomically persist workflow identity and admit its Grind worker job"
}

pub fn run_id(handle: RunHandle(o, e, u)) -> checkpoint.RunId {
  handle.run_id
}

pub type RunPhase {
  RunQueued
  RunActive
  RunWaiting
  RunTerminal
  RunNeedsReconciliation
}

pub type StatusError {
  RunNotFound
  RunnerStateUnavailable
}

pub fn phase(
  _queue: grind.Queue,
  _handle: RunHandle(o, e, u),
) -> Result(RunPhase, StatusError) {
  todo as "read the committed workflow state"
}

pub type ResultError {
  RunNotFoundForResult
  ResultNotReady
  DefinitionDoesNotMatchRun
  TerminalOutcomeCouldNotBeDecoded
}

pub fn result(
  _queue: grind.Queue,
  _definition: Definition(i, o, e, u),
  _handle: RunHandle(o, e, u),
) -> Result(checkpoint.RunOutcome(o, e, u), ResultError) {
  todo as "validate run identity and decode the committed typed terminal outcome"
}

pub type CancelOutcome {
  CancellationRecorded(new_revision: Int)
  CancellationAlreadyRecorded
  RunAlreadyTerminal
}

pub type CancelError {
  RunNotFoundForCancellation
  CancellationStorageUnavailable
}

pub fn cancel(
  _queue: grind.Queue,
  _handle: RunHandle(o, e, u),
) -> Result(CancelOutcome, CancelError) {
  todo as "persist cancellation intent and stop new admission without blocking a worker"
}
