// THROWAWAY: Can Saga and Grind expose one explicit durable admission boundary?
import lab/blueprint.{type Codec, type DecodeError}
import lab/grind
import lab/saga.{type ChildContract, type Definition}
import lab/saga_checkpoint as checkpoint
import lab/saga_child_link as child_link
import lab/saga_run_identity as identity
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

pub opaque type OwnerId {
  OwnerId(String)
}

pub type OwnerIdError {
  OwnerIdMustNotBeEmpty
}

pub fn owner_id(value: String) -> Result(OwnerId, OwnerIdError) {
  case value {
    "" -> Error(OwnerIdMustNotBeEmpty)
    _ -> Ok(OwnerId(value))
  }
}

// A scripted read boundary stands in for an independently owned run store.
// It makes no transaction, retention, or concurrency claim.
pub opaque type DurableOwner {
  DurableOwner(
    id: OwnerId,
    read: fn(identity.RunId) -> Result(StoredRun, OwnerReadError),
  )
}

pub fn durable_owner(
  id: OwnerId,
  read: fn(identity.RunId) -> Result(StoredRun, OwnerReadError),
) -> DurableOwner {
  DurableOwner(id, read)
}

pub type OwnerReadError {
  StoredRunMissing
  OwnerUnavailable
}

// This is the concrete information an adapter can load from its store.
// Terminal payloads remain Value until a compatible retained contract is bound.
pub type StoredRun {
  StoredRun(
    owner_id: String,
    run_id: identity.RunId,
    definition_id: String,
    definition_version: Int,
    signature: String,
    input_version: Int,
    output_version: Int,
    error_version: Int,
    undo_error_version: Int,
    revision: Int,
    state: StoredChildState,
  )
}

pub type StoredChildState {
  StoredChildQueued
  StoredChildRunning
  StoredChildWaiting
  StoredChildCompleted(output: Value, compensation: StoredCompensation)
  StoredChildResultUnavailable
  StoredChildFailed(cause: Value, undo_failures: List(Value))
  StoredChildCancelled(undo_failures: List(Value))
  StoredChildNeedsReconciliation(evidence: List(Value))
}

pub type StoredCompensation {
  StoredCompensationDiscarded
  StoredCompensationClaimable(until_milliseconds: Int)
  StoredCompensationClaimed
  StoredCompensationPending
  StoredCompensationRunning
  StoredCompensationSucceeded
  StoredCompensationFailed(undo_failures: List(Value))
  StoredCompensationNeedsReconciliation(evidence: List(Value))
}

pub opaque type DurableChild(o, e, u) {
  DurableChild(
    link: child_link.ChildLink,
    output_codec: Codec(o),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
  )
}

pub fn child_link(child: DurableChild(o, e, u)) -> child_link.ChildLink {
  child.link
}

// Compatibility has the same meaning during attachment and observation.
// Storage and decoding failures remain specific to their operation.
pub type CompatibilityError {
  ChildOwnerMismatch
  ChildRunIdentityMismatch
  ChildDefinitionIdentityMismatch
  ChildDefinitionVersionMismatch
  ChildSignatureMismatch
  ChildInputCodecVersionMismatch
  ChildOutputCodecVersionMismatch
  ChildErrorCodecVersionMismatch
  ChildUndoErrorCodecVersionMismatch
}

pub type AttachError {
  ChildIncompatible(CompatibilityError)
  ChildRunMissing
  ChildOwnerUnavailable
  ChildLinkInvalid
}

pub fn attach_child(
  owner: DurableOwner,
  contract: ChildContract(i, o, e, u),
  run_id: identity.RunId,
) -> Result(DurableChild(o, e, u), AttachError) {
  let DurableOwner(owner_id, read) = owner
  case read(run_id) {
    Error(StoredRunMissing) -> Error(ChildRunMissing)
    Error(OwnerUnavailable) -> Error(ChildOwnerUnavailable)
    Ok(stored) -> {
      let OwnerId(owner_name) = owner_id
      case run_matches_contract(stored, owner_name, run_id, contract) {
        Error(mismatch) -> Error(ChildIncompatible(mismatch))
        Ok(Nil) -> {
          let versions = saga.child_contract_boundary_versions(contract)
          case
            child_link.new(
              owner_name,
              run_id,
              saga.child_contract_identity(contract),
              saga.child_contract_version(contract),
              saga.child_contract_signature(contract),
              versions.0,
              versions.1,
              versions.2,
              versions.3,
            )
          {
            Error(_) -> Error(ChildLinkInvalid)
            Ok(link) -> Ok(child_for(link, contract))
          }
        }
      }
    }
  }
}

pub fn reattach_child(
  owner: DurableOwner,
  contract: ChildContract(i, o, e, u),
  link: child_link.ChildLink,
) -> Result(DurableChild(o, e, u), AttachError) {
  let DurableOwner(owner_id, read) = owner
  let OwnerId(owner_name) = owner_id
  case check_link_owner_and_contract(link, owner_name, contract) {
    Error(mismatch) -> Error(ChildIncompatible(mismatch))
    Ok(Nil) ->
      case read(child_link.run(link)) {
        Error(StoredRunMissing) -> Error(ChildRunMissing)
        Error(OwnerUnavailable) -> Error(ChildOwnerUnavailable)
        Ok(stored) ->
          case run_matches_link(stored, owner_name, link) {
            Error(mismatch) -> Error(ChildIncompatible(mismatch))
            Ok(Nil) -> Ok(child_for(link, contract))
          }
      }
  }
}

fn child_for(
  link: child_link.ChildLink,
  contract: ChildContract(i, o, e, u),
) -> DurableChild(o, e, u) {
  DurableChild(
    link,
    saga.child_contract_output_codec(contract),
    saga.child_contract_error_codec(contract),
    saga.child_contract_undo_error_codec(contract),
  )
}

pub type ChildCompensationView(u) {
  CompensationDiscarded
  CompensationClaimable(until_milliseconds: Int)
  CompensationClaimed
  CompensationRequested(CompensationStatus(u))
}

pub type CompensationStatus(u) {
  CompensationPending
  CompensationRunning
  CompensationSucceeded
  CompensationFailed(undo_failures: List(u))
  CompensationNeedsReconciliation(evidence: List(Value))
}

pub type DurableChildState(o, e, u) {
  ChildQueued(revision: Int)
  ChildRunning(revision: Int)
  ChildWaiting(revision: Int)
  ChildCompleted(
    revision: Int,
    historical_output: o,
    compensation: ChildCompensationView(u),
  )
  ChildFailed(revision: Int, cause: e, undo_failures: List(u))
  ChildCancelled(revision: Int, undo_failures: List(u))
  ChildNeedsReconciliation(revision: Int, evidence: List(Value))
}

pub type ChildDataError {
  OutputCouldNotDecode(DecodeError)
  CauseCouldNotDecode(DecodeError)
  UndoErrorCouldNotDecode(DecodeError)
  UndoErrorAtIndex(Int, DecodeError)
}

pub type ObserveError {
  ObservedIncompatible(CompatibilityError)
  ObservedRunMissing
  ObservedOwnerUnavailable
  ChildResultUnavailable
  ChildStoredDataCorrupt(ChildDataError)
}

// Observation always revalidates durable metadata before touching a terminal
// Value, because the typed handle may outlive the deployment that made it.
pub fn observe_child(
  owner: DurableOwner,
  child: DurableChild(o, e, u),
) -> Result(DurableChildState(o, e, u), ObserveError) {
  let DurableOwner(owner_id, read) = owner
  let OwnerId(owner_name) = owner_id
  case child_link.owner(child.link) == owner_name {
    False -> Error(ObservedIncompatible(ChildOwnerMismatch))
    True ->
      case read(child_link.run(child.link)) {
        Error(StoredRunMissing) -> Error(ObservedRunMissing)
        Error(OwnerUnavailable) -> Error(ObservedOwnerUnavailable)
        Ok(stored) ->
          case run_matches_link(stored, owner_name, child.link) {
            Error(mismatch) -> Error(ObservedIncompatible(mismatch))
            Ok(Nil) -> decode_stored_child(stored, child)
          }
      }
  }
}

fn decode_stored_child(
  stored: StoredRun,
  child: DurableChild(o, e, u),
) -> Result(DurableChildState(o, e, u), ObserveError) {
  case stored.state {
    StoredChildQueued -> Ok(ChildQueued(stored.revision))
    StoredChildRunning -> Ok(ChildRunning(stored.revision))
    StoredChildWaiting -> Ok(ChildWaiting(stored.revision))
    StoredChildResultUnavailable -> Error(ChildResultUnavailable)
    StoredChildCompleted(raw_output, compensation) ->
      case blueprint.decode(child.output_codec, raw_output) {
        Error(error) ->
          Error(ChildStoredDataCorrupt(OutputCouldNotDecode(error)))
        Ok(output) ->
          case decode_compensation(compensation, child.undo_error_codec) {
            Error(error) -> Error(ChildStoredDataCorrupt(error))
            Ok(view) -> Ok(ChildCompleted(stored.revision, output, view))
          }
      }
    StoredChildFailed(raw_cause, raw_undo_failures) ->
      case blueprint.decode(child.error_codec, raw_cause) {
        Error(error) ->
          Error(ChildStoredDataCorrupt(CauseCouldNotDecode(error)))
        Ok(cause) ->
          case
            decode_undo_errors(raw_undo_failures, child.undo_error_codec, 0)
          {
            Error(error) -> Error(ChildStoredDataCorrupt(error))
            Ok(undo_failures) ->
              Ok(ChildFailed(stored.revision, cause, undo_failures))
          }
      }
    StoredChildCancelled(raw_undo_failures) ->
      case decode_undo_errors(raw_undo_failures, child.undo_error_codec, 0) {
        Error(error) -> Error(ChildStoredDataCorrupt(error))
        Ok(undo_failures) -> Ok(ChildCancelled(stored.revision, undo_failures))
      }
    StoredChildNeedsReconciliation(evidence) ->
      Ok(ChildNeedsReconciliation(stored.revision, evidence))
  }
}

fn decode_compensation(
  compensation: StoredCompensation,
  undo_error_codec: Codec(u),
) -> Result(ChildCompensationView(u), ChildDataError) {
  case compensation {
    StoredCompensationDiscarded -> Ok(CompensationDiscarded)
    StoredCompensationClaimable(until_milliseconds) ->
      Ok(CompensationClaimable(until_milliseconds))
    StoredCompensationClaimed -> Ok(CompensationClaimed)
    StoredCompensationPending -> Ok(CompensationRequested(CompensationPending))
    StoredCompensationRunning -> Ok(CompensationRequested(CompensationRunning))
    StoredCompensationSucceeded ->
      Ok(CompensationRequested(CompensationSucceeded))
    StoredCompensationFailed(raw_undo_failures) ->
      case decode_undo_errors(raw_undo_failures, undo_error_codec, 0) {
        Error(error) -> Error(error)
        Ok(undo_failures) ->
          Ok(CompensationRequested(CompensationFailed(undo_failures)))
      }
    StoredCompensationNeedsReconciliation(evidence) ->
      Ok(CompensationRequested(CompensationNeedsReconciliation(evidence)))
  }
}

fn decode_undo_errors(
  values: List(Value),
  codec: Codec(u),
  index: Int,
) -> Result(List(u), ChildDataError) {
  case values {
    [] -> Ok([])
    [value, ..rest] ->
      case blueprint.decode(codec, value) {
        Error(error) -> Error(UndoErrorAtIndex(index, error))
        Ok(decoded) ->
          case decode_undo_errors(rest, codec, index + 1) {
            Error(error) -> Error(error)
            Ok(tail) -> Ok([decoded, ..tail])
          }
      }
  }
}

fn run_matches_contract(
  stored: StoredRun,
  owner_name: String,
  run_id: identity.RunId,
  contract: ChildContract(i, o, e, u),
) -> Result(Nil, CompatibilityError) {
  let versions = saga.child_contract_boundary_versions(contract)
  case stored.owner_id == owner_name {
    False -> Error(ChildOwnerMismatch)
    True ->
      case stored.run_id == run_id {
        False -> Error(ChildRunIdentityMismatch)
        True ->
          case stored.definition_id == saga.child_contract_identity(contract) {
            False -> Error(ChildDefinitionIdentityMismatch)
            True ->
              case
                stored.definition_version
                == saga.child_contract_version(contract)
              {
                False -> Error(ChildDefinitionVersionMismatch)
                True ->
                  case
                    stored.signature == saga.child_contract_signature(contract)
                  {
                    False -> Error(ChildSignatureMismatch)
                    True ->
                      case stored.input_version == versions.0 {
                        False -> Error(ChildInputCodecVersionMismatch)
                        True ->
                          case stored.output_version == versions.1 {
                            False -> Error(ChildOutputCodecVersionMismatch)
                            True ->
                              case stored.error_version == versions.2 {
                                False -> Error(ChildErrorCodecVersionMismatch)
                                True ->
                                  case stored.undo_error_version == versions.3 {
                                    False ->
                                      Error(ChildUndoErrorCodecVersionMismatch)
                                    True -> Ok(Nil)
                                  }
                              }
                          }
                      }
                  }
              }
          }
      }
  }
}

fn run_matches_link(
  stored: StoredRun,
  owner_name: String,
  link: child_link.ChildLink,
) -> Result(Nil, CompatibilityError) {
  case stored.owner_id == owner_name {
    False -> Error(ChildOwnerMismatch)
    True ->
      case stored.run_id == child_link.run(link) {
        False -> Error(ChildRunIdentityMismatch)
        True ->
          case stored.definition_id == child_link.definition(link) {
            False -> Error(ChildDefinitionIdentityMismatch)
            True ->
              case
                stored.definition_version == child_link.definition_version(link)
              {
                False -> Error(ChildDefinitionVersionMismatch)
                True ->
                  case stored.signature == child_link.signature(link) {
                    False -> Error(ChildSignatureMismatch)
                    True ->
                      case
                        stored.input_version == child_link.input_version(link)
                      {
                        False -> Error(ChildInputCodecVersionMismatch)
                        True ->
                          case
                            stored.output_version
                            == child_link.output_version(link)
                          {
                            False -> Error(ChildOutputCodecVersionMismatch)
                            True ->
                              case
                                stored.error_version
                                == child_link.error_version(link)
                              {
                                False -> Error(ChildErrorCodecVersionMismatch)
                                True ->
                                  case
                                    stored.undo_error_version
                                    == child_link.undo_error_version(link)
                                  {
                                    False ->
                                      Error(ChildUndoErrorCodecVersionMismatch)
                                    True -> Ok(Nil)
                                  }
                              }
                          }
                      }
                  }
              }
          }
      }
  }
}

fn check_link_owner_and_contract(
  link: child_link.ChildLink,
  owner_name: String,
  contract: ChildContract(i, o, e, u),
) -> Result(Nil, CompatibilityError) {
  let versions = saga.child_contract_boundary_versions(contract)
  case child_link.owner(link) == owner_name {
    False -> Error(ChildOwnerMismatch)
    True ->
      case
        child_link.definition(link) == saga.child_contract_identity(contract)
      {
        False -> Error(ChildDefinitionIdentityMismatch)
        True ->
          case
            child_link.definition_version(link)
            == saga.child_contract_version(contract)
          {
            False -> Error(ChildDefinitionVersionMismatch)
            True ->
              case
                child_link.signature(link)
                == saga.child_contract_signature(contract)
              {
                False -> Error(ChildSignatureMismatch)
                True ->
                  case child_link.input_version(link) == versions.0 {
                    False -> Error(ChildInputCodecVersionMismatch)
                    True ->
                      case child_link.output_version(link) == versions.1 {
                        False -> Error(ChildOutputCodecVersionMismatch)
                        True ->
                          case child_link.error_version(link) == versions.2 {
                            False -> Error(ChildErrorCodecVersionMismatch)
                            True ->
                              case
                                child_link.undo_error_version(link)
                                == versions.3
                              {
                                False ->
                                  Error(ChildUndoErrorCodecVersionMismatch)
                                True -> Ok(Nil)
                              }
                          }
                      }
                  }
              }
          }
      }
  }
}
