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

pub fn owner_id_value(id: OwnerId) -> String {
  let OwnerId(value) = id
  value
}

pub opaque type AttachmentId {
  AttachmentId(String)
}

pub type AttachmentIdError {
  AttachmentIdMustNotBeEmpty
}

pub fn attachment_id(value: String) -> Result(AttachmentId, AttachmentIdError) {
  case value {
    "" -> Error(AttachmentIdMustNotBeEmpty)
    _ -> Ok(AttachmentId(value))
  }
}

pub fn attachment_id_value(id: AttachmentId) -> String {
  let AttachmentId(value) = id
  value
}

// Parent identity is structured into independently encoded values. The
// attachment key is scoped by owner and run; no delimiter-based concatenation
// is used to create a compound identity. A parent must allocate distinct stable
// IDs for distinct occurrences, including repeated graph nodes and iterations.
pub opaque type ParentAttachment {
  ParentAttachment(
    owner: OwnerId,
    run_id: identity.RunId,
    attachment_id: AttachmentId,
  )
}

pub type ParentAttachmentError {
  ParentRunIdMustNotBeEmpty
  ParentAttachmentIdMustNotBeEmpty
}

pub fn parent_attachment(
  owner: OwnerId,
  run_id: identity.RunId,
  attachment_id: AttachmentId,
) -> Result(ParentAttachment, ParentAttachmentError) {
  case identity.run_id_value(run_id), attachment_id_value(attachment_id) {
    "", _ -> Error(ParentRunIdMustNotBeEmpty)
    _, "" -> Error(ParentAttachmentIdMustNotBeEmpty)
    _, _ -> Ok(ParentAttachment(owner, run_id, attachment_id))
  }
}

pub fn parent_attachment_owner(parent: ParentAttachment) -> OwnerId {
  parent.owner
}

pub fn parent_attachment_run_id(parent: ParentAttachment) -> identity.RunId {
  parent.run_id
}

pub fn parent_attachment_id(parent: ParentAttachment) -> AttachmentId {
  parent.attachment_id
}

pub opaque type ClaimId {
  ClaimId(String)
}

pub type ClaimIdError {
  ClaimIdMustNotBeEmpty
}

pub fn claim_id(value: String) -> Result(ClaimId, ClaimIdError) {
  case value {
    "" -> Error(ClaimIdMustNotBeEmpty)
    _ -> Ok(ClaimId(value))
  }
}

pub fn claim_id_value(id: ClaimId) -> String {
  let ClaimId(value) = id
  value
}

pub opaque type DurableCompensationReceiptRef {
  DurableCompensationReceiptRef(
    child_link: child_link.ChildLink,
    claim_id: ClaimId,
    parent: ParentAttachment,
  )
}

// An owner creates this routing reference after committing a claim. The value
// alone is not authority: rebinding still reads and validates the owner record.
pub fn compensation_reference(
  link: child_link.ChildLink,
  claim: ClaimId,
  parent: ParentAttachment,
) -> DurableCompensationReceiptRef {
  DurableCompensationReceiptRef(link, claim, parent)
}

pub fn receipt_child_link(
  reference: DurableCompensationReceiptRef,
) -> child_link.ChildLink {
  reference.child_link
}

pub fn receipt_claim_id(reference: DurableCompensationReceiptRef) -> ClaimId {
  reference.claim_id
}

pub fn receipt_parent(
  reference: DurableCompensationReceiptRef,
) -> ParentAttachment {
  reference.parent
}

pub fn compensation_receipt_ref_codec() -> Codec(DurableCompensationReceiptRef) {
  blueprint.new(encode_receipt_ref, decode_receipt_ref)
}

fn encode_receipt_ref(
  reference: DurableCompensationReceiptRef,
) -> Result(Value, blueprint.EncodeError) {
  case blueprint.encode(child_link.codec(), reference.child_link) {
    Error(error) -> Error(blueprint.EncodeAtIndex(1, error))
    Ok(encoded_link) ->
      Ok(
        value.Array([
          value.Text("compensation-receipt-ref-v1"),
          encoded_link,
          value.Text(claim_id_value(reference.claim_id)),
          value.Text(owner_id_value(reference.parent.owner)),
          value.Text(identity.run_id_value(reference.parent.run_id)),
          value.Text(attachment_id_value(reference.parent.attachment_id)),
        ]),
      )
  }
}

fn decode_receipt_ref(
  raw: Value,
) -> Result(DurableCompensationReceiptRef, DecodeError) {
  case raw {
    value.Array([
      value.Text("compensation-receipt-ref-v1"),
      encoded_link,
      value.Text(raw_claim_id),
      value.Text(raw_parent_owner),
      value.Text(raw_parent_run),
      value.Text(raw_attachment_id),
    ]) ->
      case blueprint.decode(child_link.codec(), encoded_link) {
        Error(error) -> Error(blueprint.DecodeAtIndex(1, error))
        Ok(link) ->
          case claim_id(raw_claim_id) {
            Error(_) ->
              Error(blueprint.DecodeAtIndex(
                2,
                blueprint.CannotDecode("Claim id must not be empty"),
              ))
            Ok(claim) ->
              case owner_id(raw_parent_owner) {
                Error(_) ->
                  Error(blueprint.DecodeAtIndex(
                    3,
                    blueprint.CannotDecode("Parent owner id must not be empty"),
                  ))
                Ok(parent_owner) -> {
                  let parent_run = identity.run_id(raw_parent_run)
                  case attachment_id(raw_attachment_id) {
                    Error(_) ->
                      Error(blueprint.DecodeAtIndex(
                        5,
                        blueprint.CannotDecode(
                          "Parent attachment identity is invalid",
                        ),
                      ))
                    Ok(parent_attachment_id) ->
                      case
                        parent_attachment(
                          parent_owner,
                          parent_run,
                          parent_attachment_id,
                        )
                      {
                        Error(_) ->
                          Error(blueprint.DecodeAtIndex(
                            4,
                            blueprint.CannotDecode(
                              "Parent attachment identity is invalid",
                            ),
                          ))
                        Ok(parent) ->
                          Ok(DurableCompensationReceiptRef(link, claim, parent))
                      }
                  }
                }
              }
          }
      }
    value.Array([value.Text("compensation-receipt-ref-v1"), ..]) ->
      Error(blueprint.CannotDecode(
        "Compensation receipt reference has the wrong field count",
      ))
    _ ->
      Error(blueprint.CannotDecode("Expected compensation receipt reference"))
  }
}

// A read port supports attachment and observation. Admission and cancellation
// are separate named callbacks so unsupported operations stay explicit.
pub opaque type OwnerPort {
  OwnerPort(
    read: fn(OwnerId, identity.RunId) -> Result(StoredRun, OwnerReadError),
    submit: fn(OwnerId, ChildSubmission) ->
      Result(ChildSubmissionReply, OwnerSubmissionError),
    cancel: fn(OwnerId, ChildCancellation) ->
      Result(ChildCancellationReply, OwnerCancellationPortError),
    compensation: CompensationPort,
  )
}

// These callbacks are adapter seams, not storage or concurrency guarantees.
// The request adapter must deduplicate one command per claim before checking
// fresh retention. A replay can recover its original handle after expiry, but
// a different command cannot admit a second request for the same claim.
pub opaque type CompensationPort {
  CompensationPort(
    claim: fn(OwnerId, CompensationClaimCommand) ->
      Result(CompensationClaimReply, CompensationClaimPortError),
    read_claim: fn(OwnerId, DurableCompensationReceiptRef) ->
      Result(StoredCompensationClaim, CompensationClaimReadError),
    request: fn(OwnerId, CompensationRequest) ->
      Result(CompensationRequestReply, CompensationRequestPortError),
    observe: fn(OwnerId, CompensationRequest) ->
      Result(StoredCompensationRecord, CompensationObservePortError),
  )
}

pub fn compensation_port(
  claim: fn(OwnerId, CompensationClaimCommand) ->
    Result(CompensationClaimReply, CompensationClaimPortError),
  read_claim: fn(OwnerId, DurableCompensationReceiptRef) ->
    Result(StoredCompensationClaim, CompensationClaimReadError),
  request: fn(OwnerId, CompensationRequest) ->
    Result(CompensationRequestReply, CompensationRequestPortError),
  observe: fn(OwnerId, CompensationRequest) ->
    Result(StoredCompensationRecord, CompensationObservePortError),
) -> CompensationPort {
  CompensationPort(claim, read_claim, request, observe)
}

pub fn unsupported_compensation_port() -> CompensationPort {
  compensation_port(
    unsupported_compensation_claim,
    unsupported_compensation_read_claim,
    unsupported_compensation_request,
    unsupported_compensation_observation,
  )
}

pub fn owner_port(
  read: fn(OwnerId, identity.RunId) -> Result(StoredRun, OwnerReadError),
  submit: fn(OwnerId, ChildSubmission) ->
    Result(ChildSubmissionReply, OwnerSubmissionError),
  cancel: fn(OwnerId, ChildCancellation) ->
    Result(ChildCancellationReply, OwnerCancellationPortError),
  compensation: CompensationPort,
) -> OwnerPort {
  OwnerPort(read, submit, cancel, compensation)
}

pub opaque type DurableOwner {
  DurableOwner(id: OwnerId, port: OwnerPort)
}

pub fn durable_owner(id: OwnerId, port: OwnerPort) -> DurableOwner {
  DurableOwner(id, port)
}

pub fn unsupported_submission(
  _owner: OwnerId,
  _request: ChildSubmission,
) -> Result(ChildSubmissionReply, OwnerSubmissionError) {
  Error(SubmissionUnsupportedOperation)
}

pub fn unsupported_cancellation(
  _owner: OwnerId,
  _request: ChildCancellation,
) -> Result(ChildCancellationReply, OwnerCancellationPortError) {
  Error(CancellationUnsupportedOperation)
}

pub type OwnerReadError {
  StoredRunMissing
  OwnerUnavailable
}

pub type OwnerSubmissionError {
  SubmissionUnsupportedOperation
  SubmissionCommandConflict
  SubmissionRejected
  SubmissionUnavailable
  SubmissionCommitUnknown
}

pub type ChildSubmissionReply {
  ChildCreated(accepted_request: ChildSubmission, stored: StoredRun)
  ChildAlreadyExists(accepted_request: ChildSubmission, stored: StoredRun)
}

pub type OwnerCancellationPortError {
  CancellationUnsupportedOperation
  CancellationIncompatible(CompatibilityError)
  CancellationUnavailable
  CancellationCommitUnknown
}

pub type ChildCancellationReply {
  CancellationIntentRecorded(new_revision: Int)
  CancellationIntentAlreadyRecorded
  CancellationAlreadyTerminal
  CancellationTargetMissing
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
  // The successful outcome can be pruned while the compensation journal stays
  // available. This preserves success and retention facts without the output.
  StoredChildCompletedResultPruned(compensation: StoredCompensation)
  StoredChildResultUnavailable
  StoredChildFailed(cause: Value, undo_failures: List(Value))
  StoredChildCancelled(undo_failures: List(Value))
  StoredChildNeedsReconciliation(evidence: List(Value))
}

pub type StoredCompensation {
  StoredCompensationDiscarded
  StoredCompensationJournalPruned
  StoredCompensationClaimable(until_milliseconds: Int)
  StoredCompensationClaimed
  StoredCompensationPending
  StoredCompensationRunning
  StoredCompensationSucceeded
  StoredCompensationFailed(undo_failures: List(Value))
  StoredCompensationNeedsReconciliation(evidence: List(Value))
}

// This retention applies to the child compensation journal. Terminal result
// retention remains a separate owner policy.
pub type Retention {
  Discard
  RetainUntil(grind.AvailableAt)
}

pub type ChildSubmission {
  ChildSubmission(
    command_id: identity.CommandId,
    definition_identity: String,
    definition_version: Int,
    signature: String,
    input_version: Int,
    output_version: Int,
    error_version: Int,
    undo_error_version: Int,
    encoded_input: Value,
    retention: Retention,
  )
}

pub type ChildCancellation {
  ChildCancellation(link: child_link.ChildLink, command_id: identity.CommandId)
}

pub opaque type CompensationClaimCommand {
  CompensationClaimCommand(
    child_link: child_link.ChildLink,
    claimant: ParentAttachment,
    command_id: identity.CommandId,
  )
}

// This is an adapter request value, not a compensation capability.
pub fn compensation_claim_command(
  link: child_link.ChildLink,
  claimant: ParentAttachment,
  command_id: identity.CommandId,
) -> CompensationClaimCommand {
  CompensationClaimCommand(link, claimant, command_id)
}

pub fn claim_command_link(
  command: CompensationClaimCommand,
) -> child_link.ChildLink {
  command.child_link
}

pub fn claim_command_parent(
  command: CompensationClaimCommand,
) -> ParentAttachment {
  command.claimant
}

pub fn claim_command_id(
  command: CompensationClaimCommand,
) -> identity.CommandId {
  command.command_id
}

pub type CompensationClaimReply {
  // A newly granted reply carries the owner-checked pre-claim snapshot. It
  // must still show a live claimable journal; a post-commit mismatch is
  // ambiguous and therefore retains the exact retry token.
  CompensationClaimGranted(
    accepted: CompensationClaimCommand,
    reference: DurableCompensationReceiptRef,
    checked_at_milliseconds: Int,
    checked_run: StoredRun,
  )
  CompensationClaimAlreadyGranted(stored_claim: StoredCompensationClaim)
}

pub type StoredCompensationClaim {
  StoredCompensationClaim(
    accepted: CompensationClaimCommand,
    reference: DurableCompensationReceiptRef,
    stored: StoredRun,
  )
}

pub type CompensationClaimPortError {
  ClaimUnsupportedOperation
  ClaimRunMissing
  ClaimOwnerUnavailable
  ClaimChildNotSuccessful
  ClaimCompensationDiscarded
  ClaimJournalPruned
  ClaimWindowExpired
  ClaimAlreadyOwnedByAnotherParent
  ClaimCommandConflict
  ClaimRejected
  ClaimCommitUnknown
}

pub type CompensationClaimReadError {
  ClaimRecordMissing
  ClaimRecordUnavailable
}

pub opaque type CompensationRequest {
  CompensationRequest(
    reference: DurableCompensationReceiptRef,
    command_id: identity.CommandId,
  )
}

// Constructing a request value does not issue or admit compensation.
pub fn compensation_request(
  reference: DurableCompensationReceiptRef,
  command_id: identity.CommandId,
) -> CompensationRequest {
  CompensationRequest(reference, command_id)
}

pub fn compensation_request_reference(
  request: CompensationRequest,
) -> DurableCompensationReceiptRef {
  request.reference
}

pub fn compensation_request_command_id(
  request: CompensationRequest,
) -> identity.CommandId {
  request.command_id
}

pub type CompensationRequestReply {
  CompensationRequestStarted(
    accepted: CompensationRequest,
    stored: StoredCompensationRecord,
  )
  CompensationRequestAlreadyExists(
    accepted: CompensationRequest,
    stored: StoredCompensationRecord,
  )
}

pub type CompensationRequestPortError {
  CompensationRequestUnsupportedOperation
  RequestPortMissingClaim
  RequestPortExpired
  RequestPortJournalUnavailable
  RequestPortCommandConflict
  RequestPortAlreadyAdmitted
  RequestPortUnavailable
  RequestPortRejected
  RequestPortCommitUnknown
}

pub type CompensationObservePortError {
  CompensationObservationUnsupportedOperation
  CompensationRequestNotFound
  CompensationJournalPruned
  CompensationObservationUnavailable
}

pub type StoredCompensationRecord {
  StoredCompensationRecord(
    reference: DurableCompensationReceiptRef,
    request_id: identity.CommandId,
    run: StoredRunMetadata,
    history: StoredChildHistory,
    compensation: StoredCompensation,
  )
}

pub type StoredRunMetadata {
  StoredRunMetadata(
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
  )
}

pub type StoredChildHistory {
  StoredChildHistoricallySucceeded
  StoredChildDidNotSucceed
}

pub fn metadata_for_run(stored: StoredRun) -> StoredRunMetadata {
  StoredRunMetadata(
    stored.owner_id,
    stored.run_id,
    stored.definition_id,
    stored.definition_version,
    stored.signature,
    stored.input_version,
    stored.output_version,
    stored.error_version,
    stored.undo_error_version,
    stored.revision,
  )
}

pub opaque type DurableChild(o, e, u) {
  DurableChild(
    link: child_link.ChildLink,
    output_codec: Codec(o),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
  )
}

pub opaque type DurableCompensationReceipt(u) {
  DurableCompensationReceipt(
    reference: DurableCompensationReceiptRef,
    undo_error_codec: Codec(u),
  )
}

pub fn compensation_receipt_reference(
  receipt: DurableCompensationReceipt(u),
) -> DurableCompensationReceiptRef {
  receipt.reference
}

pub type CompensationClaimOutcome(u) {
  CompensationClaimNew(receipt: DurableCompensationReceipt(u))
  CompensationClaimReplayed(receipt: DurableCompensationReceipt(u))
}

pub opaque type UncertainCompensationClaim(u) {
  UncertainCompensationClaim(
    owner_id: OwnerId,
    command: CompensationClaimCommand,
    undo_error_codec: Codec(u),
  )
}

pub type CompensationClaimError(u) {
  CompensationClaimCommandMustNotBeEmpty
  CompensationClaimOwnerMismatch
  CompensationClaimUnsupported
  CompensationClaimRunMissing
  CompensationClaimOwnerUnavailable
  CompensationClaimNotSuccessful
  CompensationClaimDiscarded
  CompensationClaimJournalPruned
  CompensationClaimExpired
  CompensationClaimedByAnotherParent
  CompensationClaimCommandConflict
  CompensationClaimRejected
  CompensationClaimCommitUnknown(UncertainCompensationClaim(u))
  CompensationClaimRouteMismatch(UncertainCompensationClaim(u))
  CompensationClaimReplyInvalid(
    reason: CompensationClaimReplyError,
    uncertain: UncertainCompensationClaim(u),
  )
}

pub type CompensationClaimReplyError {
  ClaimAcceptedCommandMismatch
  ClaimReferenceMismatch
  ClaimStoredRunIncompatible(CompatibilityError)
  ClaimRunWasNotSuccessful
  ClaimJournalNotClaimable
  ClaimJournalWasPruned
  ClaimDeadlineWasNotLive
  ClaimTimestampWasInvalid
}

pub opaque type CompensationHandle(u) {
  CompensationHandle(request: CompensationRequest, undo_error_codec: Codec(u))
}

pub fn compensation_handle_request(
  handle: CompensationHandle(u),
) -> CompensationRequest {
  handle.request
}

pub type CompensationRequestOutcome(u) {
  CompensationRequestNew(handle: CompensationHandle(u))
  CompensationRequestReplayed(handle: CompensationHandle(u))
}

pub opaque type UncertainCompensationRequest(u) {
  UncertainCompensationRequest(
    owner_id: OwnerId,
    request: CompensationRequest,
    undo_error_codec: Codec(u),
  )
}

pub type CompensationRequestError(u) {
  CompensationRequestCommandMustNotBeEmpty
  CompensationRequestOwnerMismatch
  CompensationRequestUnsupported
  CompensationRequestClaimMissing
  CompensationRequestAlreadyAdmitted
  CompensationRequestExpired
  CompensationRequestJournalUnavailable
  CompensationRequestCommandConflict
  CompensationRequestOwnerUnavailable
  CompensationRequestRejected
  CompensationRequestCommitUnknown(UncertainCompensationRequest(u))
  CompensationRequestRouteMismatch(UncertainCompensationRequest(u))
  CompensationRequestReplyInvalid(
    reason: CompensationRequestReplyError,
    uncertain: UncertainCompensationRequest(u),
  )
}

pub type CompensationReceiptBindError {
  CompensationReceiptOwnerMismatch
  CompensationReceiptIncompatible(CompatibilityError)
  CompensationClaimRecordMissing
  CompensationClaimRecordUnavailable
  CompensationClaimRecordMismatch
  CompensationClaimStoredRunIncompatible(CompatibilityError)
}

pub type CompensationRequestReplyError {
  CompensationAcceptedCommandMismatch
  CompensationStoredRunIncompatible(CompatibilityError)
  CompensationChildWasNotSuccessful
  CompensationRequestWasNotRecorded
}

pub type CompensationObservationError {
  CompensationObservationUnsupported
  CompensationRequestMissing
  CompensationObservationJournalPruned
  CompensationObservationOwnerUnavailable
  CompensationObservationIncompatible(CompatibilityError)
  CompensationObservationChildNotSuccessful
  CompensationObservationCorrupt(ChildDataError)
}

pub opaque type PreparedChild(o, e, u) {
  PreparedChild(
    request: ChildSubmission,
    output_codec: Codec(o),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
  )
}

// The request is bound to the owner route after a commit-unknown response.
// It is a retry token, not evidence that the store committed or can be reached.
// OwnerId equality is only the configured route check; it does not authenticate
// or prove that two callback sets share the same backing store.
pub opaque type UncertainSubmission(o, e, u) {
  UncertainSubmission(owner_id: OwnerId, prepared: PreparedChild(o, e, u))
}

pub fn prepared_submission(
  prepared: PreparedChild(o, e, u),
) -> ChildSubmission {
  prepared.request
}

pub fn prepared_command_id(
  prepared: PreparedChild(o, e, u),
) -> identity.CommandId {
  prepared.request.command_id
}

pub type PrepareChildError {
  StableCommandMustNotBeEmpty
  ChildInputCouldNotEncode(blueprint.EncodeError)
}

pub fn prepare_child(
  contract: ChildContract(i, o, e, u),
  input: i,
  retention: Retention,
  command_id: identity.CommandId,
) -> Result(PreparedChild(o, e, u), PrepareChildError) {
  case identity.command_id_value(command_id) {
    "" -> Error(StableCommandMustNotBeEmpty)
    _ ->
      case blueprint.encode(saga.child_contract_input_codec(contract), input) {
        Error(error) -> Error(ChildInputCouldNotEncode(error))
        Ok(encoded_input) -> {
          let versions = saga.child_contract_boundary_versions(contract)
          let request =
            ChildSubmission(
              command_id,
              saga.child_contract_identity(contract),
              saga.child_contract_version(contract),
              saga.child_contract_signature(contract),
              versions.0,
              versions.1,
              versions.2,
              versions.3,
              encoded_input,
              retention,
            )
          Ok(PreparedChild(
            request,
            saga.child_contract_output_codec(contract),
            saga.child_contract_error_codec(contract),
            saga.child_contract_undo_error_codec(contract),
          ))
        }
      }
  }
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

pub type ChildSubmitError(o, e, u) {
  ChildSubmissionUnsupported
  ChildSubmissionConflict
  ChildSubmissionRejected
  ChildSubmissionUnavailable
  ChildSubmissionCommitUnknown(UncertainSubmission(o, e, u))
  ChildSubmissionRouteMismatch(UncertainSubmission(o, e, u))
  ChildSubmissionReplyInvalid(
    reason: SubmissionReplyError,
    uncertain: UncertainSubmission(o, e, u),
  )
}

pub type SubmissionReplyError {
  AcceptedRequestMismatch
  AcceptedRunIncompatible(CompatibilityError)
  AcceptedRunLinkInvalid
}

pub type ChildAdmission(o, e, u) {
  NewlyAdmitted(DurableChild(o, e, u))
  AlreadyAdmitted(DurableChild(o, e, u))
}

// Preparation is separate so callers can keep the exact encoded request when
// a store reports an ambiguous commit and retry with its stable command.
pub fn submit_child(
  owner: DurableOwner,
  prepared: PreparedChild(o, e, u),
) -> Result(ChildAdmission(o, e, u), ChildSubmitError(o, e, u)) {
  submit_prepared(owner, prepared)
}

pub fn retry_submission(
  owner: DurableOwner,
  uncertain: UncertainSubmission(o, e, u),
) -> Result(ChildAdmission(o, e, u), ChildSubmitError(o, e, u)) {
  // A retry outcome never erases the caller's original uncertainty. Keep the
  // token so an unavailable retry or another lost acknowledgement can retry.
  let UncertainSubmission(original_owner_id, prepared) = uncertain
  let DurableOwner(owner_id, _) = owner
  case owner_id == original_owner_id {
    False -> Error(ChildSubmissionRouteMismatch(uncertain))
    True -> submit_prepared(owner, prepared)
  }
}

fn submit_prepared(
  owner: DurableOwner,
  prepared: PreparedChild(o, e, u),
) -> Result(ChildAdmission(o, e, u), ChildSubmitError(o, e, u)) {
  let DurableOwner(owner_id, port) = owner
  let OwnerPort(_, submit, _, _) = port
  let OwnerId(owner_name) = owner_id
  case submit(owner_id, prepared.request) {
    Error(SubmissionUnsupportedOperation) -> Error(ChildSubmissionUnsupported)
    Error(SubmissionCommandConflict) -> Error(ChildSubmissionConflict)
    Error(SubmissionRejected) -> Error(ChildSubmissionRejected)
    Error(SubmissionUnavailable) -> Error(ChildSubmissionUnavailable)
    Error(SubmissionCommitUnknown) ->
      Error(
        ChildSubmissionCommitUnknown(UncertainSubmission(owner_id, prepared)),
      )
    Ok(reply) ->
      case child_from_submission(owner_name, prepared, reply) {
        Ok(admission) -> Ok(admission)
        Error(reason) ->
          Error(ChildSubmissionReplyInvalid(
            reason,
            UncertainSubmission(owner_id, prepared),
          ))
      }
  }
}

fn child_from_submission(
  owner_name: String,
  prepared: PreparedChild(o, e, u),
  reply: ChildSubmissionReply,
) -> Result(ChildAdmission(o, e, u), SubmissionReplyError) {
  case reply {
    ChildCreated(accepted_request, stored) ->
      case accepted_request == prepared.request {
        False -> Error(AcceptedRequestMismatch)
        True ->
          case durable_child_from_submission(owner_name, prepared, stored) {
            Error(error) -> Error(error)
            Ok(child) -> Ok(NewlyAdmitted(child))
          }
      }
    ChildAlreadyExists(accepted_request, stored) ->
      case accepted_request == prepared.request {
        False -> Error(AcceptedRequestMismatch)
        True ->
          case durable_child_from_submission(owner_name, prepared, stored) {
            Error(error) -> Error(error)
            Ok(child) -> Ok(AlreadyAdmitted(child))
          }
      }
  }
}

fn durable_child_from_submission(
  owner_name: String,
  prepared: PreparedChild(o, e, u),
  stored: StoredRun,
) -> Result(DurableChild(o, e, u), SubmissionReplyError) {
  let request = prepared.request
  case
    child_link.new(
      owner_name,
      stored.run_id,
      request.definition_identity,
      request.definition_version,
      request.signature,
      request.input_version,
      request.output_version,
      request.error_version,
      request.undo_error_version,
    )
  {
    Error(_) -> Error(AcceptedRunLinkInvalid)
    Ok(link) ->
      case run_matches_link(stored, owner_name, link) {
        Error(mismatch) -> Error(AcceptedRunIncompatible(mismatch))
        Ok(Nil) ->
          Ok(DurableChild(
            link,
            prepared.output_codec,
            prepared.error_codec,
            prepared.undo_error_codec,
          ))
      }
  }
}

pub type ChildCancellationOutcome {
  ChildCancellationRecorded(new_revision: Int)
  ChildCancellationAlreadyRecorded
  ChildCancellationAlreadyTerminal
  ChildCancellationMissing
}

pub type ChildCancellationError(o, e, u) {
  ChildCancellationCommandMustNotBeEmpty
  ChildCancellationUnsupported
  ChildCancellationIncompatible(CompatibilityError)
  ChildCancellationUnavailable
  ChildCancellationCommitUnknown(
    child: DurableChild(o, e, u),
    command_id: identity.CommandId,
  )
}

// Cancellation is an owner command against the immutable child link. It
// records intent; the owner decides the eventual child outcome.
pub fn request_child_cancellation(
  owner: DurableOwner,
  child: DurableChild(o, e, u),
  command_id: identity.CommandId,
) -> Result(ChildCancellationOutcome, ChildCancellationError(o, e, u)) {
  case identity.command_id_value(command_id) {
    "" -> Error(ChildCancellationCommandMustNotBeEmpty)
    _ -> {
      let DurableOwner(owner_id, port) = owner
      let OwnerPort(_, _, cancel, _) = port
      let OwnerId(owner_name) = owner_id
      case child_link.owner(child.link) == owner_name {
        False -> Error(ChildCancellationIncompatible(ChildOwnerMismatch))
        True -> {
          let request = ChildCancellation(child.link, command_id)
          case cancel(owner_id, request) {
            Ok(CancellationIntentRecorded(revision)) ->
              Ok(ChildCancellationRecorded(revision))
            Ok(CancellationIntentAlreadyRecorded) ->
              Ok(ChildCancellationAlreadyRecorded)
            Ok(CancellationAlreadyTerminal) ->
              Ok(ChildCancellationAlreadyTerminal)
            Ok(CancellationTargetMissing) -> Ok(ChildCancellationMissing)
            Error(CancellationUnsupportedOperation) ->
              Error(ChildCancellationUnsupported)
            Error(CancellationIncompatible(reason)) ->
              Error(ChildCancellationIncompatible(reason))
            Error(CancellationUnavailable) ->
              Error(ChildCancellationUnavailable)
            Error(CancellationCommitUnknown) ->
              Error(ChildCancellationCommitUnknown(child, command_id))
          }
        }
      }
    }
  }
}

pub fn attach_child(
  owner: DurableOwner,
  contract: ChildContract(i, o, e, u),
  run_id: identity.RunId,
) -> Result(DurableChild(o, e, u), AttachError) {
  let DurableOwner(owner_id, port) = owner
  let OwnerPort(read, _, _, _) = port
  case read(owner_id, run_id) {
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
  let DurableOwner(owner_id, port) = owner
  let OwnerPort(read, _, _, _) = port
  let OwnerId(owner_name) = owner_id
  case check_link_owner_and_contract(link, owner_name, contract) {
    Error(mismatch) -> Error(ChildIncompatible(mismatch))
    Ok(Nil) ->
      case read(owner_id, child_link.run(link)) {
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
  ChildJournalPruned
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
  let DurableOwner(owner_id, port) = owner
  let OwnerPort(read, _, _, _) = port
  let OwnerId(owner_name) = owner_id
  case child_link.owner(child.link) == owner_name {
    False -> Error(ObservedIncompatible(ChildOwnerMismatch))
    True ->
      case read(owner_id, child_link.run(child.link)) {
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
    StoredChildCompletedResultPruned(_) -> Error(ChildResultUnavailable)
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
    StoredCompensationJournalPruned -> Ok(ChildJournalPruned)
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

fn metadata_matches_link(
  stored: StoredRunMetadata,
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

pub fn unsupported_compensation_claim(
  _owner: OwnerId,
  _command: CompensationClaimCommand,
) -> Result(CompensationClaimReply, CompensationClaimPortError) {
  Error(ClaimUnsupportedOperation)
}

pub fn unsupported_compensation_read_claim(
  _owner: OwnerId,
  _reference: DurableCompensationReceiptRef,
) -> Result(StoredCompensationClaim, CompensationClaimReadError) {
  Error(ClaimRecordUnavailable)
}

pub fn unsupported_compensation_request(
  _owner: OwnerId,
  _request: CompensationRequest,
) -> Result(CompensationRequestReply, CompensationRequestPortError) {
  Error(CompensationRequestUnsupportedOperation)
}

pub fn unsupported_compensation_observation(
  _owner: OwnerId,
  _request: CompensationRequest,
) -> Result(StoredCompensationRecord, CompensationObservePortError) {
  Error(CompensationObservationUnsupportedOperation)
}

pub fn claim_child_compensation(
  owner: DurableOwner,
  child: DurableChild(o, e, u),
  claimant: ParentAttachment,
  command_id: identity.CommandId,
) -> Result(CompensationClaimOutcome(u), CompensationClaimError(u)) {
  let DurableOwner(owner_id, port) = owner
  let OwnerPort(_, _, _, compensation) = port
  let CompensationPort(claim, _, _, _) = compensation
  let ChildLinkForClaim(link, undo_error_codec) = child_for_claim(child)
  case identity.command_id_value(command_id) {
    "" -> Error(CompensationClaimCommandMustNotBeEmpty)
    _ ->
      case child_link.owner(link) == owner_id_value(owner_id) {
        False -> Error(CompensationClaimOwnerMismatch)
        True -> {
          let command = CompensationClaimCommand(link, claimant, command_id)
          case claim(owner_id, command) {
            Ok(reply) ->
              decode_claim_reply(owner_id, command, undo_error_codec, reply)
            Error(error) ->
              map_claim_port_error(owner_id, command, undo_error_codec, error)
          }
        }
      }
  }
}

type ChildLinkForClaim(u) {
  ChildLinkForClaim(child_link.ChildLink, Codec(u))
}

fn child_for_claim(child: DurableChild(o, e, u)) -> ChildLinkForClaim(u) {
  ChildLinkForClaim(child.link, child.undo_error_codec)
}

pub fn retry_compensation_claim(
  owner: DurableOwner,
  uncertain: UncertainCompensationClaim(u),
) -> Result(CompensationClaimOutcome(u), CompensationClaimError(u)) {
  let UncertainCompensationClaim(original_owner_id, command, undo_error_codec) =
    uncertain
  let DurableOwner(owner_id, port) = owner
  let OwnerPort(_, _, _, compensation) = port
  let CompensationPort(claim, _, _, _) = compensation
  case owner_id == original_owner_id {
    False -> Error(CompensationClaimRouteMismatch(uncertain))
    True ->
      case claim(owner_id, command) {
        Ok(reply) ->
          decode_claim_reply(owner_id, command, undo_error_codec, reply)
        Error(error) ->
          map_claim_port_error(owner_id, command, undo_error_codec, error)
      }
  }
}

fn map_claim_port_error(
  owner_id: OwnerId,
  command: CompensationClaimCommand,
  undo_error_codec: Codec(u),
  error: CompensationClaimPortError,
) -> Result(CompensationClaimOutcome(u), CompensationClaimError(u)) {
  case error {
    ClaimUnsupportedOperation -> Error(CompensationClaimUnsupported)
    ClaimRunMissing -> Error(CompensationClaimRunMissing)
    ClaimOwnerUnavailable -> Error(CompensationClaimOwnerUnavailable)
    ClaimChildNotSuccessful -> Error(CompensationClaimNotSuccessful)
    ClaimCompensationDiscarded -> Error(CompensationClaimDiscarded)
    ClaimJournalPruned -> Error(CompensationClaimJournalPruned)
    ClaimWindowExpired -> Error(CompensationClaimExpired)
    ClaimAlreadyOwnedByAnotherParent ->
      Error(CompensationClaimedByAnotherParent)
    ClaimCommandConflict -> Error(CompensationClaimCommandConflict)
    ClaimRejected -> Error(CompensationClaimRejected)
    ClaimCommitUnknown ->
      Error(
        CompensationClaimCommitUnknown(UncertainCompensationClaim(
          owner_id,
          command,
          undo_error_codec,
        )),
      )
  }
}

fn decode_claim_reply(
  owner_id: OwnerId,
  command: CompensationClaimCommand,
  undo_error_codec: Codec(u),
  reply: CompensationClaimReply,
) -> Result(CompensationClaimOutcome(u), CompensationClaimError(u)) {
  case reply {
    CompensationClaimGranted(accepted, reference, checked_at, checked_run) ->
      case validate_claim_acceptance(owner_id, command, accepted, reference) {
        Error(reason) ->
          claim_reply_invalid(owner_id, command, undo_error_codec, reason)
        Ok(Nil) ->
          case
            run_matches_link(
              checked_run,
              owner_id_value(owner_id),
              command.child_link,
            )
          {
            Error(mismatch) ->
              claim_reply_invalid(
                owner_id,
                command,
                undo_error_codec,
                ClaimStoredRunIncompatible(mismatch),
              )
            Ok(Nil) ->
              case claimable_deadline(checked_run.state) {
                Error(reason) ->
                  claim_reply_invalid(
                    owner_id,
                    command,
                    undo_error_codec,
                    reason,
                  )
                Ok(until) ->
                  case checked_at >= 0 {
                    False ->
                      claim_reply_invalid(
                        owner_id,
                        command,
                        undo_error_codec,
                        ClaimTimestampWasInvalid,
                      )
                    True ->
                      case checked_at < until {
                        False ->
                          claim_reply_invalid(
                            owner_id,
                            command,
                            undo_error_codec,
                            ClaimDeadlineWasNotLive,
                          )
                        True ->
                          Ok(
                            CompensationClaimNew(DurableCompensationReceipt(
                              reference,
                              undo_error_codec,
                            )),
                          )
                      }
                  }
              }
          }
      }
    CompensationClaimAlreadyGranted(stored_claim) ->
      case validate_stored_claim(owner_id, command, stored_claim) {
        Error(reason) ->
          claim_reply_invalid(owner_id, command, undo_error_codec, reason)
        Ok(reference) ->
          Ok(
            CompensationClaimReplayed(DurableCompensationReceipt(
              reference,
              undo_error_codec,
            )),
          )
      }
  }
}

fn validate_claim_acceptance(
  owner_id: OwnerId,
  expected: CompensationClaimCommand,
  accepted: CompensationClaimCommand,
  reference: DurableCompensationReceiptRef,
) -> Result(Nil, CompensationClaimReplyError) {
  case expected == accepted {
    False -> Error(ClaimAcceptedCommandMismatch)
    True ->
      case reference_matches_claim(reference, accepted, owner_id) {
        True -> Ok(Nil)
        False -> Error(ClaimReferenceMismatch)
      }
  }
}

fn reference_matches_claim(
  reference: DurableCompensationReceiptRef,
  command: CompensationClaimCommand,
  owner_id: OwnerId,
) -> Bool {
  reference.child_link == command.child_link
  && reference.parent == command.claimant
  && child_link.owner(reference.child_link) == owner_id_value(owner_id)
}

fn validate_stored_claim(
  owner_id: OwnerId,
  expected: CompensationClaimCommand,
  stored_claim: StoredCompensationClaim,
) -> Result(DurableCompensationReceiptRef, CompensationClaimReplyError) {
  case stored_claim.accepted == expected {
    False -> Error(ClaimAcceptedCommandMismatch)
    True ->
      case reference_matches_claim(stored_claim.reference, expected, owner_id) {
        False -> Error(ClaimReferenceMismatch)
        True ->
          case
            run_matches_link(
              stored_claim.stored,
              owner_id_value(owner_id),
              expected.child_link,
            )
          {
            Error(mismatch) -> Error(ClaimStoredRunIncompatible(mismatch))
            Ok(Nil) -> Ok(stored_claim.reference)
          }
      }
  }
}

fn claimable_deadline(
  state: StoredChildState,
) -> Result(Int, CompensationClaimReplyError) {
  case state {
    StoredChildCompleted(_, StoredCompensationClaimable(until)) -> Ok(until)
    StoredChildCompletedResultPruned(StoredCompensationClaimable(until)) ->
      Ok(until)
    StoredChildCompleted(_, StoredCompensationDiscarded) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompletedResultPruned(StoredCompensationJournalPruned) ->
      Error(ClaimJournalWasPruned)
    StoredChildCompleted(_, StoredCompensationJournalPruned) ->
      Error(ClaimJournalWasPruned)
    StoredChildCompletedResultPruned(StoredCompensationDiscarded) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompleted(_, StoredCompensationClaimed) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompletedResultPruned(StoredCompensationClaimed) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompleted(_, StoredCompensationPending) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompletedResultPruned(StoredCompensationPending) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompleted(_, StoredCompensationRunning) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompletedResultPruned(StoredCompensationRunning) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompleted(_, StoredCompensationSucceeded) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompletedResultPruned(StoredCompensationSucceeded) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompleted(_, StoredCompensationFailed(_)) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompletedResultPruned(StoredCompensationFailed(_)) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompleted(_, StoredCompensationNeedsReconciliation(_)) ->
      Error(ClaimJournalNotClaimable)
    StoredChildCompletedResultPruned(StoredCompensationNeedsReconciliation(_)) ->
      Error(ClaimJournalNotClaimable)
    _ -> Error(ClaimRunWasNotSuccessful)
  }
}

fn claim_reply_invalid(
  owner_id: OwnerId,
  command: CompensationClaimCommand,
  undo_error_codec: Codec(u),
  reason: CompensationClaimReplyError,
) -> Result(CompensationClaimOutcome(u), CompensationClaimError(u)) {
  Error(CompensationClaimReplyInvalid(
    reason,
    UncertainCompensationClaim(owner_id, command, undo_error_codec),
  ))
}

pub fn rebind_compensation_receipt(
  owner: DurableOwner,
  contract: ChildContract(i, o, e, u),
  reference: DurableCompensationReceiptRef,
) -> Result(DurableCompensationReceipt(u), CompensationReceiptBindError) {
  let DurableOwner(owner_id, port) = owner
  let OwnerPort(_, _, _, compensation) = port
  let CompensationPort(_, read_claim, _, _) = compensation
  let link = reference.child_link
  let owner_name = owner_id_value(owner_id)
  case child_link.owner(link) == owner_name {
    False -> Error(CompensationReceiptOwnerMismatch)
    True ->
      case check_link_owner_and_contract(link, owner_name, contract) {
        Error(mismatch) -> Error(CompensationReceiptIncompatible(mismatch))
        Ok(Nil) ->
          case read_claim(owner_id, reference) {
            Error(ClaimRecordMissing) -> Error(CompensationClaimRecordMissing)
            Error(ClaimRecordUnavailable) ->
              Error(CompensationClaimRecordUnavailable)
            Ok(stored_claim) ->
              case validate_bound_claim(owner_id, reference, stored_claim) {
                Error(ClaimAcceptedCommandMismatch) ->
                  Error(CompensationClaimRecordMismatch)
                Error(ClaimReferenceMismatch) ->
                  Error(CompensationClaimRecordMismatch)
                Error(ClaimStoredRunIncompatible(mismatch)) ->
                  Error(CompensationClaimStoredRunIncompatible(mismatch))
                Error(_) -> Error(CompensationClaimRecordMismatch)
                Ok(Nil) ->
                  Ok(DurableCompensationReceipt(
                    reference,
                    saga.child_contract_undo_error_codec(contract),
                  ))
              }
          }
      }
  }
}

fn validate_bound_claim(
  owner_id: OwnerId,
  expected_reference: DurableCompensationReceiptRef,
  stored_claim: StoredCompensationClaim,
) -> Result(Nil, CompensationClaimReplyError) {
  case stored_claim.reference == expected_reference {
    False -> Error(ClaimReferenceMismatch)
    True ->
      case
        reference_matches_claim(
          expected_reference,
          stored_claim.accepted,
          owner_id,
        )
      {
        False -> Error(ClaimAcceptedCommandMismatch)
        True ->
          case
            run_matches_link(
              stored_claim.stored,
              owner_id_value(owner_id),
              expected_reference.child_link,
            )
          {
            Error(mismatch) -> Error(ClaimStoredRunIncompatible(mismatch))
            Ok(Nil) -> Ok(Nil)
          }
      }
  }
}

pub fn request_child_compensation(
  owner: DurableOwner,
  receipt: DurableCompensationReceipt(u),
  command_id: identity.CommandId,
) -> Result(CompensationRequestOutcome(u), CompensationRequestError(u)) {
  let DurableOwner(owner_id, port) = owner
  let OwnerPort(_, _, _, compensation) = port
  let CompensationPort(_, _, request, _) = compensation
  case identity.command_id_value(command_id) {
    "" -> Error(CompensationRequestCommandMustNotBeEmpty)
    _ ->
      case
        child_link.owner(receipt.reference.child_link)
        == owner_id_value(owner_id)
      {
        False -> Error(CompensationRequestOwnerMismatch)
        True -> {
          let operation = CompensationRequest(receipt.reference, command_id)
          case request(owner_id, operation) {
            Ok(reply) ->
              decode_compensation_request_reply(
                owner_id,
                operation,
                receipt.undo_error_codec,
                reply,
              )
            Error(error) ->
              map_compensation_request_error(
                owner_id,
                operation,
                receipt.undo_error_codec,
                error,
              )
          }
        }
      }
  }
}

pub fn retry_child_compensation_request(
  owner: DurableOwner,
  uncertain: UncertainCompensationRequest(u),
) -> Result(CompensationRequestOutcome(u), CompensationRequestError(u)) {
  let UncertainCompensationRequest(original_owner_id, operation, codec) =
    uncertain
  let DurableOwner(owner_id, port) = owner
  let OwnerPort(_, _, _, compensation) = port
  let CompensationPort(_, _, request, _) = compensation
  case owner_id == original_owner_id {
    False -> Error(CompensationRequestRouteMismatch(uncertain))
    True ->
      case request(owner_id, operation) {
        Ok(reply) ->
          decode_compensation_request_reply(owner_id, operation, codec, reply)
        Error(error) ->
          map_compensation_request_error(owner_id, operation, codec, error)
      }
  }
}

fn map_compensation_request_error(
  owner_id: OwnerId,
  operation: CompensationRequest,
  undo_error_codec: Codec(u),
  error: CompensationRequestPortError,
) -> Result(CompensationRequestOutcome(u), CompensationRequestError(u)) {
  case error {
    CompensationRequestUnsupportedOperation ->
      Error(CompensationRequestUnsupported)
    RequestPortMissingClaim -> Error(CompensationRequestClaimMissing)
    RequestPortExpired -> Error(CompensationRequestExpired)
    RequestPortJournalUnavailable ->
      Error(CompensationRequestJournalUnavailable)
    RequestPortCommandConflict -> Error(CompensationRequestCommandConflict)
    RequestPortAlreadyAdmitted -> Error(CompensationRequestAlreadyAdmitted)
    RequestPortUnavailable -> Error(CompensationRequestOwnerUnavailable)
    RequestPortRejected -> Error(CompensationRequestRejected)
    RequestPortCommitUnknown ->
      Error(
        CompensationRequestCommitUnknown(UncertainCompensationRequest(
          owner_id,
          operation,
          undo_error_codec,
        )),
      )
  }
}

fn decode_compensation_request_reply(
  owner_id: OwnerId,
  expected: CompensationRequest,
  undo_error_codec: Codec(u),
  reply: CompensationRequestReply,
) -> Result(CompensationRequestOutcome(u), CompensationRequestError(u)) {
  case reply {
    CompensationRequestStarted(accepted, stored) ->
      case validate_request_record(owner_id, expected, accepted, stored) {
        Error(reason) ->
          compensation_request_reply_invalid(
            owner_id,
            expected,
            undo_error_codec,
            reason,
          )
        Ok(Nil) ->
          case request_state_was_recorded(stored.compensation) {
            True ->
              Ok(
                CompensationRequestNew(CompensationHandle(
                  expected,
                  undo_error_codec,
                )),
              )
            False ->
              compensation_request_reply_invalid(
                owner_id,
                expected,
                undo_error_codec,
                CompensationRequestWasNotRecorded,
              )
          }
      }
    CompensationRequestAlreadyExists(accepted, stored) ->
      case validate_request_record(owner_id, expected, accepted, stored) {
        Error(reason) ->
          compensation_request_reply_invalid(
            owner_id,
            expected,
            undo_error_codec,
            reason,
          )
        Ok(Nil) ->
          Ok(
            CompensationRequestReplayed(CompensationHandle(
              expected,
              undo_error_codec,
            )),
          )
      }
  }
}

fn validate_request_record(
  owner_id: OwnerId,
  expected: CompensationRequest,
  accepted: CompensationRequest,
  stored: StoredCompensationRecord,
) -> Result(Nil, CompensationRequestReplyError) {
  case expected == accepted {
    False -> Error(CompensationAcceptedCommandMismatch)
    True ->
      case
        stored.reference == expected.reference
        && stored.request_id == expected.command_id
      {
        False -> Error(CompensationAcceptedCommandMismatch)
        True ->
          case
            metadata_matches_link(
              stored.run,
              owner_id_value(owner_id),
              expected.reference.child_link,
            )
          {
            Error(mismatch) ->
              Error(CompensationStoredRunIncompatible(mismatch))
            Ok(Nil) ->
              case stored.history {
                StoredChildHistoricallySucceeded -> Ok(Nil)
                StoredChildDidNotSucceed ->
                  Error(CompensationChildWasNotSuccessful)
              }
          }
      }
  }
}

fn request_state_was_recorded(state: StoredCompensation) -> Bool {
  case state {
    StoredCompensationPending -> True
    StoredCompensationRunning -> True
    StoredCompensationSucceeded -> True
    StoredCompensationFailed(_) -> True
    StoredCompensationNeedsReconciliation(_) -> True
    _ -> False
  }
}

fn compensation_request_reply_invalid(
  owner_id: OwnerId,
  operation: CompensationRequest,
  undo_error_codec: Codec(u),
  reason: CompensationRequestReplyError,
) -> Result(CompensationRequestOutcome(u), CompensationRequestError(u)) {
  Error(CompensationRequestReplyInvalid(
    reason,
    UncertainCompensationRequest(owner_id, operation, undo_error_codec),
  ))
}

pub fn observe_child_compensation(
  owner: DurableOwner,
  handle: CompensationHandle(u),
) -> Result(CompensationStatus(u), CompensationObservationError) {
  let DurableOwner(owner_id, port) = owner
  let OwnerPort(_, _, _, compensation) = port
  let CompensationPort(_, _, _, observe) = compensation
  let operation = handle.request
  let reference = operation.reference
  case child_link.owner(reference.child_link) == owner_id_value(owner_id) {
    False -> Error(CompensationObservationIncompatible(ChildOwnerMismatch))
    True ->
      case observe(owner_id, operation) {
        Error(CompensationObservationUnsupportedOperation) ->
          Error(CompensationObservationUnsupported)
        Error(CompensationRequestNotFound) -> Error(CompensationRequestMissing)
        Error(CompensationJournalPruned) ->
          Error(CompensationObservationJournalPruned)
        Error(CompensationObservationUnavailable) ->
          Error(CompensationObservationOwnerUnavailable)
        Ok(stored) ->
          case validate_request_record(owner_id, operation, operation, stored) {
            Error(CompensationAcceptedCommandMismatch) ->
              Error(CompensationObservationIncompatible(
                ChildRunIdentityMismatch,
              ))
            Error(CompensationStoredRunIncompatible(mismatch)) ->
              Error(CompensationObservationIncompatible(mismatch))
            Error(CompensationChildWasNotSuccessful) ->
              Error(CompensationObservationChildNotSuccessful)
            Error(_) ->
              Error(CompensationObservationIncompatible(
                ChildRunIdentityMismatch,
              ))
            Ok(Nil) ->
              decode_compensation_status(
                stored.compensation,
                handle.undo_error_codec,
              )
          }
      }
  }
}

fn decode_compensation_status(
  stored: StoredCompensation,
  undo_error_codec: Codec(u),
) -> Result(CompensationStatus(u), CompensationObservationError) {
  case stored {
    StoredCompensationPending -> Ok(CompensationPending)
    StoredCompensationRunning -> Ok(CompensationRunning)
    StoredCompensationSucceeded -> Ok(CompensationSucceeded)
    StoredCompensationFailed(raw_undo_errors) ->
      case decode_undo_errors(raw_undo_errors, undo_error_codec, 0) {
        Error(error) -> Error(CompensationObservationCorrupt(error))
        Ok(undo_errors) -> Ok(CompensationFailed(undo_errors))
      }
    StoredCompensationNeedsReconciliation(evidence) ->
      Ok(CompensationNeedsReconciliation(evidence))
    StoredCompensationDiscarded -> Error(CompensationRequestMissing)
    StoredCompensationJournalPruned ->
      Error(CompensationObservationJournalPruned)
    StoredCompensationClaimable(_) -> Error(CompensationRequestMissing)
    StoredCompensationClaimed -> Error(CompensationRequestMissing)
  }
}
