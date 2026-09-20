// THROWAWAY: Can an opaque continuation become a versioned non-generic snapshot?
import lab/blueprint.{type Codec}
import lab/saga.{type Definition}
import lab/value.{type Value}

pub opaque type RunId {
  RunId(String)
}

pub fn run_id(value: String) -> RunId {
  RunId(value)
}

pub opaque type CommandId {
  CommandId(String)
}

pub fn command_id(value: String) -> CommandId {
  CommandId(value)
}

pub type CancellationIntent {
  ContinueRun
  CancelRequested
}

pub type StepResult {
  StepPending
  StepRunning
  StepSucceeded(output: Value)
  StepFailed(error: Value)
  StepSkipped
  StepAmbiguous(evidence: Value)
}

pub type StepSnapshot {
  StepSnapshot(
    identity: String,
    input: Value,
    operation_version: Int,
    codec_versions: List(Int),
    result: StepResult,
    selected_branches: List(String),
    compensation: CompensationState,
  )
}

pub type CompensationState {
  NotCompensable
  CompensationNotStarted
  CompensationRunning
  CompensationSucceeded
  CompensationFailed(error: Value)
}

pub type WaitReference {
  ApprovalWait(step_id: String, approval_id: String, answer_codec_version: Int)
  ChildWait(step_id: String, child_run_id: String, child_revision: Int)
}

pub type AmbiguousEffect {
  AmbiguousEffect(step_id: String, evidence: Value)
}

// Persisted data is deliberately concrete and non-generic. It carries no
// executable closure; restore binds it to a freshly deployed Definition.
pub type Snapshot {
  Snapshot(
    definition_id: String,
    definition_version: Int,
    structural_signature: String,
    run_id: String,
    revision: Int,
    run_input: Value,
    cancellation: CancellationIntent,
    steps: List(StepSnapshot),
    completion_order: List(String),
    waiting_on: List(WaitReference),
    ambiguous_effects: List(AmbiguousEffect),
  )
}

pub type FreezeError {
  OperationStillRunning
  BoundaryNotCheckpointable
}

pub type RestoreError {
  DefinitionIdentityMismatch
  DefinitionVersionMismatch
  StructuralSignatureMismatch
  UnknownStep(String)
  CodecVersionMismatch(String)
  SnapshotCorrupt(String)
}

pub type SnapshotEncodingError {
  SnapshotValueCouldNotEncode(String)
}

pub type SnapshotDecodingError {
  SnapshotValueWasInvalid(String)
}

pub type RunOutcome(o, e, u) {
  WorkflowSucceeded(o)
  WorkflowFailed(e, undo_failures: List(u))
  WorkflowCancelled(undo_failures: List(u))
  WorkflowNeedsReconciliation(ambiguous: List(AmbiguousEffect))
}

pub type WaitingState {
  WaitingForApproval(approval_id: String, expected_revision: Int)
  WaitingForChild(child_run_id: String, expected_revision: Int)
}

pub opaque type Execution(o, e, u) {
  Execution(run_id: RunId, revision: Int, state: ExecutionState(o, e, u))
}

type ExecutionState(o, e, u) {
  Active
  Suspended(WaitingState)
  Finished(RunOutcome(o, e, u))
}

pub opaque type Checkpointable(o, e, u) {
  Checkpointable(snapshot: Snapshot)
}

pub type Restored(o, e, u) {
  RestoredRunnable(Execution(o, e, u))
  RestoredWaiting(Execution(o, e, u), WaitingState)
  RestoredTerminal(Execution(o, e, u), RunOutcome(o, e, u))
  RestoredReconciliationRequired(Execution(o, e, u), List(AmbiguousEffect))
}

pub type ExecutionStatus(o, e, u) {
  ExecutionRunning
  ExecutionWaiting(WaitingState)
  ExecutionFinished(RunOutcome(o, e, u))
}

pub type StartError {
  DefinitionCannotStart(Value)
}

// The return token is opaque and only the runner can hand it out. This starter
// is a type boundary; it does not execute a workflow in this playground.
pub fn start(
  _definition: Definition(i, o, e, u),
  _input: i,
) -> Result(Execution(o, e, u), StartError) {
  todo as "construct a runner-owned execution after admission"
}

pub fn execution_status(
  _execution: Execution(o, e, u),
) -> ExecutionStatus(o, e, u) {
  todo as "report whether the local runner is active, suspended, or terminal"
}

pub fn quiesce(
  _execution: Execution(o, e, u),
) -> Result(Checkpointable(o, e, u), FreezeError) {
  todo as "wait for the documented checkpoint boundary and retain unresolved effect evidence"
}

pub fn freeze(checkpointable: Checkpointable(o, e, u)) -> Snapshot {
  let Checkpointable(snapshot) = checkpointable
  snapshot
}

// Snapshot encoding is separate from reaching a checkpoint boundary.
pub fn encode_snapshot(
  _snapshot: Snapshot,
) -> Result(Value, SnapshotEncodingError) {
  todo as "encode the concrete envelope at the chosen storage boundary"
}

pub fn decode_snapshot(
  _value: Value,
) -> Result(Snapshot, SnapshotDecodingError) {
  todo as "parse untrusted persisted data into the concrete snapshot envelope"
}

pub fn restore(
  _definition: Definition(i, o, e, u),
  _snapshot: Snapshot,
) -> Result(Restored(o, e, u), RestoreError) {
  todo as "validate identity, versions, codecs, and signature against the deployed definition"
}

pub opaque type ApprovalRef(a) {
  ApprovalRef(
    run_id: RunId,
    approval_id: String,
    expected_revision: Int,
    answer_codec: Codec(a),
  )
}

// Approval references provide typed routing only; they are not credentials.
pub fn approval_ref(
  run_id: RunId,
  approval_id: String,
  expected_revision: Int,
  answer_codec: Codec(a),
) -> ApprovalRef(a) {
  ApprovalRef(run_id, approval_id, expected_revision, answer_codec)
}

pub type SignalOutcome {
  SignalAccepted(new_revision: Int)
  SignalDuplicate
  SignalStaleRevision(current_revision: Int)
  SignalWrongApproval
  SignalRunTerminal
}

pub type SignalError {
  AnswerCouldNotEncode
  SignalStorageUnavailable
  SignalAnswerRejected
}

pub fn signal(
  _approval: ApprovalRef(a),
  _command_id: CommandId,
  _answer: a,
) -> Result(SignalOutcome, SignalError) {
  todo as "atomically check run state, approval identity, revision, and command deduplication"
}

pub fn approval_reference_run(approval: ApprovalRef(a)) -> RunId {
  let ApprovalRef(run_id, _, _, _) = approval
  run_id
}

// A denial is a durable command, not a failed activity or a malformed answer.
pub fn deny_approval(
  _approval: ApprovalRef(a),
  _command_id: CommandId,
) -> Result(SignalOutcome, SignalError) {
  todo as "atomically record denial with the same revision, identity, and deduplication checks"
}
