// THROWAWAY: Can claimed-attempt acknowledgements retain ownership evidence?
import lab/grind
import lab/grind_execution as execution

pub opaque type AttemptId {
  AttemptId(Int)
}

pub opaque type OwnershipEpoch {
  OwnershipEpoch(Int)
}

pub opaque type RecordRevision {
  RecordRevision(Int)
}

pub opaque type CommandId {
  CommandId(String)
}

pub type ClaimValueError {
  IdentityValueMustBePositive
  CommandIdMustNotBeEmpty
}

// These constructors accept explicit lab labels. They do not certify global
// uniqueness or generate native claim, epoch, or command identities.
pub fn attempt_id(label: Int) -> Result(AttemptId, ClaimValueError) {
  case label > 0 {
    True -> Ok(AttemptId(label))
    False -> Error(IdentityValueMustBePositive)
  }
}

pub fn attempt_id_label(id: AttemptId) -> Int {
  let AttemptId(label) = id
  label
}

pub fn ownership_epoch(label: Int) -> Result(OwnershipEpoch, ClaimValueError) {
  case label > 0 {
    True -> Ok(OwnershipEpoch(label))
    False -> Error(IdentityValueMustBePositive)
  }
}

pub fn ownership_epoch_label(epoch: OwnershipEpoch) -> Int {
  let OwnershipEpoch(label) = epoch
  label
}

pub fn record_revision(label: Int) -> Result(RecordRevision, ClaimValueError) {
  case label > 0 {
    True -> Ok(RecordRevision(label))
    False -> Error(IdentityValueMustBePositive)
  }
}

pub fn record_revision_label(revision: RecordRevision) -> Int {
  let RecordRevision(label) = revision
  label
}

pub fn command_id(label: String) -> Result(CommandId, ClaimValueError) {
  case label {
    "" -> Error(CommandIdMustNotBeEmpty)
    _ -> Ok(CommandId(label))
  }
}

pub fn command_id_label(id: CommandId) -> String {
  let CommandId(label) = id
  label
}

pub opaque type ClaimSnapshot {
  ClaimSnapshot(
    job_id: grind.JobId,
    attempt_id: AttemptId,
    epoch: OwnershipEpoch,
    retry_ordinal: Int,
    observed_lease_until: grind.AvailableAt,
    observed_revision: RecordRevision,
  )
}

pub type ClaimError {
  RetryOrdinalMustBePositiveForClaim
}

pub fn claim_snapshot(
  job_id: grind.JobId,
  attempt_id: AttemptId,
  epoch: OwnershipEpoch,
  retry_ordinal: Int,
  observed_lease_until: grind.AvailableAt,
  observed_revision: RecordRevision,
) -> Result(ClaimSnapshot, ClaimError) {
  case retry_ordinal > 0 {
    True ->
      Ok(ClaimSnapshot(
        job_id,
        attempt_id,
        epoch,
        retry_ordinal,
        observed_lease_until,
        observed_revision,
      ))
    False -> Error(RetryOrdinalMustBePositiveForClaim)
  }
}

pub fn claim_job_id(claim: ClaimSnapshot) -> grind.JobId {
  let ClaimSnapshot(job_id: job_id, ..) = claim
  job_id
}

pub fn claim_attempt_id(claim: ClaimSnapshot) -> AttemptId {
  let ClaimSnapshot(attempt_id: attempt_id, ..) = claim
  attempt_id
}

pub fn claim_epoch(claim: ClaimSnapshot) -> OwnershipEpoch {
  let ClaimSnapshot(epoch: epoch, ..) = claim
  epoch
}

pub fn claim_retry_ordinal(claim: ClaimSnapshot) -> Int {
  let ClaimSnapshot(retry_ordinal: retry_ordinal, ..) = claim
  retry_ordinal
}

pub fn claim_observed_lease_until(claim: ClaimSnapshot) -> grind.AvailableAt {
  let ClaimSnapshot(observed_lease_until: expiry, ..) = claim
  expiry
}

pub fn claim_observed_revision(claim: ClaimSnapshot) -> RecordRevision {
  let ClaimSnapshot(observed_revision: revision, ..) = claim
  revision
}

pub type AttemptPhase(output, error, runtime) {
  Executing(grind.CancelIntent)
  PhaseAcknowledged(execution.AttemptResolution(output, error, runtime))
  CancellationCommitted
}

pub opaque type CurrentAttempt(output, error, runtime) {
  CurrentAttempt(
    job_id: grind.JobId,
    attempt_id: AttemptId,
    epoch: OwnershipEpoch,
    retry_ordinal: Int,
    current_lease_until: grind.AvailableAt,
    revision: RecordRevision,
    phase: AttemptPhase(output, error, runtime),
  )
}

pub fn running_attempt(
  claim: ClaimSnapshot,
) -> CurrentAttempt(output, error, runtime) {
  let ClaimSnapshot(
    job_id: job_id,
    attempt_id: attempt_id,
    epoch: epoch,
    retry_ordinal: retry_ordinal,
    observed_lease_until: lease_until,
    observed_revision: revision,
  ) = claim
  CurrentAttempt(
    job_id,
    attempt_id,
    epoch,
    retry_ordinal,
    lease_until,
    revision,
    Executing(grind.NoRequest),
  )
}

pub fn current_lease_until(
  current: CurrentAttempt(output, error, runtime),
) -> grind.AvailableAt {
  let CurrentAttempt(current_lease_until: expiry, ..) = current
  expiry
}

pub fn current_revision(
  current: CurrentAttempt(output, error, runtime),
) -> RecordRevision {
  let CurrentAttempt(revision: revision, ..) = current
  revision
}

pub fn current_phase(
  current: CurrentAttempt(output, error, runtime),
) -> AttemptPhase(output, error, runtime) {
  let CurrentAttempt(phase: phase, ..) = current
  phase
}

pub type RenewalError {
  RenewalStaleOwnership
  RenewalRevisionMismatch
  RenewalAttemptNotExecuting
  RenewalCancellationRequested
  RenewalLeaseExpired
  RenewalMustExtendCurrentLease
}

// This pure model validates renewal against the current record revision and
// current expiry. The refreshed snapshot retains the same attempt and epoch.
pub fn decide_renewal(
  current: CurrentAttempt(output, error, runtime),
  claim: ClaimSnapshot,
  now: grind.AvailableAt,
  new_expiry: grind.AvailableAt,
) -> Result(
  #(CurrentAttempt(output, error, runtime), ClaimSnapshot),
  RenewalError,
) {
  let CurrentAttempt(
    job_id: current_job_id,
    attempt_id: current_attempt_id,
    epoch: current_epoch,
    retry_ordinal: current_retry_ordinal,
    current_lease_until: current_expiry,
    revision: current_revision,
    phase: current_phase,
  ) = current
  let ClaimSnapshot(
    job_id: claim_job_id,
    attempt_id: claim_attempt_id,
    epoch: claim_epoch,
    observed_revision: claim_revision,
    ..,
  ) = claim
  case
    current_job_id == claim_job_id
    && current_attempt_id == claim_attempt_id
    && current_epoch == claim_epoch
  {
    False -> Error(RenewalStaleOwnership)
    True ->
      case claim_revision == current_revision {
        False -> Error(RenewalRevisionMismatch)
        True ->
          case current_phase {
            PhaseAcknowledged(_) | CancellationCommitted ->
              Error(RenewalAttemptNotExecuting)
            Executing(grind.Requested) -> Error(RenewalCancellationRequested)
            Executing(grind.NoRequest) ->
              case
                grind.available_at_milliseconds(now)
                >= grind.available_at_milliseconds(current_expiry)
              {
                True -> Error(RenewalLeaseExpired)
                False ->
                  case
                    grind.available_at_milliseconds(new_expiry)
                    > grind.available_at_milliseconds(current_expiry)
                  {
                    False -> Error(RenewalMustExtendCurrentLease)
                    True -> {
                      let next_revision = increment_revision(current_revision)
                      let next_current =
                        CurrentAttempt(
                          current_job_id,
                          current_attempt_id,
                          current_epoch,
                          current_retry_ordinal,
                          new_expiry,
                          next_revision,
                          current_phase,
                        )
                      let next_claim =
                        ClaimSnapshot(
                          claim_job_id,
                          claim_attempt_id,
                          claim_epoch,
                          current_retry_ordinal,
                          new_expiry,
                          next_revision,
                        )
                      Ok(#(next_current, next_claim))
                    }
                  }
              }
          }
      }
  }
}

pub type AcknowledgementRejection {
  StaleOwnership
  ExpiredLease
  CancellationWon
  AttemptAlreadyAcknowledged
}

pub type AckDecision(output, error, runtime) {
  AcceptAttempt(execution.AttemptResolution(output, error, runtime))
  RejectAttempt(
    reason: AcknowledgementRejection,
    proposal: execution.AttemptResolution(output, error, runtime),
  )
}

// The old observed expiry and revision are intentionally not compared here.
// Renewal preserves owner identity; acknowledgement checks the live expiry.
pub fn decide_acknowledgement(
  current: CurrentAttempt(output, error, runtime),
  claim: ClaimSnapshot,
  now: grind.AvailableAt,
  proposal: execution.AttemptResolution(output, error, runtime),
) -> #(
  CurrentAttempt(output, error, runtime),
  AckDecision(output, error, runtime),
) {
  let CurrentAttempt(
    job_id: current_job_id,
    attempt_id: current_attempt_id,
    epoch: current_epoch,
    retry_ordinal: current_retry_ordinal,
    current_lease_until: current_expiry,
    revision: current_revision,
    phase: current_phase,
  ) = current
  let ClaimSnapshot(
    job_id: claim_job_id,
    attempt_id: claim_attempt_id,
    epoch: claim_epoch,
    ..,
  ) = claim
  case
    current_job_id == claim_job_id
    && current_attempt_id == claim_attempt_id
    && current_epoch == claim_epoch
  {
    False -> #(current, RejectAttempt(StaleOwnership, proposal))
    True ->
      case current_phase {
        PhaseAcknowledged(_) -> #(
          current,
          RejectAttempt(AttemptAlreadyAcknowledged, proposal),
        )
        CancellationCommitted -> #(
          current,
          RejectAttempt(CancellationWon, proposal),
        )
        Executing(cancel_intent) ->
          case
            grind.available_at_milliseconds(now)
            >= grind.available_at_milliseconds(current_expiry)
          {
            True -> #(current, RejectAttempt(ExpiredLease, proposal))
            False ->
              case cancel_intent {
                grind.Requested -> {
                  let cancelled =
                    CurrentAttempt(
                      current_job_id,
                      current_attempt_id,
                      current_epoch,
                      current_retry_ordinal,
                      current_expiry,
                      increment_revision(current_revision),
                      CancellationCommitted,
                    )
                  #(cancelled, RejectAttempt(CancellationWon, proposal))
                }
                grind.NoRequest -> {
                  let acknowledged =
                    CurrentAttempt(
                      current_job_id,
                      current_attempt_id,
                      current_epoch,
                      current_retry_ordinal,
                      current_expiry,
                      increment_revision(current_revision),
                      PhaseAcknowledged(proposal),
                    )
                  #(acknowledged, AcceptAttempt(proposal))
                }
              }
          }
      }
  }
}

pub type CancellationRequestResult {
  CancellationRequested
  CancellationAlreadyRequested
  RequestAfterAcknowledgement
  RequestAfterCancellation
}

// A request records intent. It does not imply cancellation won the race.
pub fn request_cancellation(
  current: CurrentAttempt(output, error, runtime),
) -> #(CurrentAttempt(output, error, runtime), CancellationRequestResult) {
  let CurrentAttempt(
    job_id: job_id,
    attempt_id: attempt_id,
    epoch: epoch,
    retry_ordinal: retry_ordinal,
    current_lease_until: expiry,
    revision: revision,
    phase: phase,
  ) = current
  case phase {
    Executing(grind.NoRequest) -> #(
      CurrentAttempt(
        job_id,
        attempt_id,
        epoch,
        retry_ordinal,
        expiry,
        increment_revision(revision),
        Executing(grind.Requested),
      ),
      CancellationRequested,
    )
    Executing(grind.Requested) -> #(current, CancellationAlreadyRequested)
    PhaseAcknowledged(_) -> #(current, RequestAfterAcknowledgement)
    CancellationCommitted -> #(current, RequestAfterCancellation)
  }
}

pub type CancellationCommitResult {
  CancellationWasCommitted
  CancellationWasNotRequested
  CancellationAfterAcknowledgement
  CancellationWasAlreadyCommitted
}

// This is the modeled cancellation transition; a native store must commit it.
pub fn commit_cancellation(
  current: CurrentAttempt(output, error, runtime),
) -> #(CurrentAttempt(output, error, runtime), CancellationCommitResult) {
  let CurrentAttempt(
    job_id: job_id,
    attempt_id: attempt_id,
    epoch: epoch,
    retry_ordinal: retry_ordinal,
    current_lease_until: expiry,
    revision: revision,
    phase: phase,
  ) = current
  case phase {
    Executing(grind.Requested) -> #(
      CurrentAttempt(
        job_id,
        attempt_id,
        epoch,
        retry_ordinal,
        expiry,
        increment_revision(revision),
        CancellationCommitted,
      ),
      CancellationWasCommitted,
    )
    Executing(grind.NoRequest) -> #(current, CancellationWasNotRequested)
    PhaseAcknowledged(_) -> #(current, CancellationAfterAcknowledgement)
    CancellationCommitted -> #(current, CancellationWasAlreadyCommitted)
  }
}

pub opaque type AckCommand(output, error, runtime) {
  AckCommand(
    command_id: CommandId,
    claim: ClaimSnapshot,
    proposal: execution.AttemptResolution(output, error, runtime),
  )
}

pub fn ack_command(
  command_id: CommandId,
  claim: ClaimSnapshot,
  proposal: execution.AttemptResolution(output, error, runtime),
) -> AckCommand(output, error, runtime) {
  AckCommand(command_id, claim, proposal)
}

pub fn ack_command_id(
  command: AckCommand(output, error, runtime),
) -> CommandId {
  let AckCommand(command_id: command_id, ..) = command
  command_id
}

pub fn ack_command_claim(
  command: AckCommand(output, error, runtime),
) -> ClaimSnapshot {
  let AckCommand(claim: claim, ..) = command
  claim
}

pub fn ack_command_proposal(
  command: AckCommand(output, error, runtime),
) -> execution.AttemptResolution(output, error, runtime) {
  let AckCommand(proposal: proposal, ..) = command
  proposal
}

pub type ReconciliationRecord(output, error, runtime) {
  ReconciliationRecord(
    command_id: CommandId,
    claim: ClaimSnapshot,
    proposal: execution.AttemptResolution(output, error, runtime),
  )
}

pub type StoreReply(output, error, runtime) {
  TransactionResolved(
    current: CurrentAttempt(output, error, runtime),
    decision: AckDecision(output, error, runtime),
  )
  TransactionUnavailable
  AttemptRecordMissing
  CommitUnknown
}

pub opaque type StorePort(output, error, runtime) {
  StorePort(
    transact: fn(AckCommand(output, error, runtime)) ->
      StoreReply(output, error, runtime),
  )
}

// A real implementation must atomically read current ownership and time,
// decide, and apply before returning a known transaction result.
pub fn store_port(
  transact: fn(AckCommand(output, error, runtime)) ->
    StoreReply(output, error, runtime),
) -> StorePort(output, error, runtime) {
  StorePort(transact)
}

pub type Acknowledgement(output, error, runtime) {
  AttemptAcknowledged(
    current: CurrentAttempt(output, error, runtime),
    command_id: CommandId,
    proposal: execution.AttemptResolution(output, error, runtime),
  )
  AttemptRejected(
    current: CurrentAttempt(output, error, runtime),
    reason: AcknowledgementRejection,
    proposal: execution.AttemptResolution(output, error, runtime),
  )
  StoreUnavailable(command: AckCommand(output, error, runtime))
  MissingAttempt(command: AckCommand(output, error, runtime))
  UnknownCommit(reconciliation: ReconciliationRecord(output, error, runtime))
}

// Current record, current time, decision, and write belong inside transact.
// Unknown commits retain the command for reconciliation and imply no result.
pub fn acknowledge(
  store: StorePort(output, error, runtime),
  command: AckCommand(output, error, runtime),
) -> Acknowledgement(output, error, runtime) {
  let StorePort(transact) = store
  case transact(command) {
    TransactionResolved(current, AcceptAttempt(_returned_proposal)) -> {
      let AckCommand(command_id: command_id, ..) = command
      let proposal = ack_command_proposal(command)
      AttemptAcknowledged(current, command_id, proposal)
    }
    TransactionResolved(current, RejectAttempt(reason, _returned_proposal)) -> {
      let proposal = ack_command_proposal(command)
      AttemptRejected(current, reason, proposal)
    }
    TransactionUnavailable -> StoreUnavailable(command)
    AttemptRecordMissing -> MissingAttempt(command)
    CommitUnknown -> {
      let AckCommand(command_id: command_id, claim: claim, proposal: proposal) =
        command
      UnknownCommit(ReconciliationRecord(command_id, claim, proposal))
    }
  }
}

fn increment_revision(revision: RecordRevision) -> RecordRevision {
  let RecordRevision(label) = revision
  RecordRevision(label + 1)
}
