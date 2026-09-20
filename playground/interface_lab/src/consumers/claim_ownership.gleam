// THROWAWAY: Can current attempt ownership fence a proposed acknowledgement?
import consumers/worker_outcomes as outcomes
import lab/grind
import lab/grind_claim as claim
import lab/grind_execution as execution
import lab/value

pub fn probe() -> Nil {
  let job_id = grind.job_id("invoice-1")
  let original_claim = make_claim(job_id, 31, 61, 2, must_time(2000), 1)
  let original_attempt = claim.running_attempt(original_claim)
  let proposal = succeeded("renewed owner", 12)
  let command = make_command("ack-renewed", original_claim, proposal)

  // Renewal increments record revision but retains attempt identity and epoch.
  let assert Ok(#(renewed_attempt, refreshed_claim)) =
    claim.decide_renewal(
      original_attempt,
      original_claim,
      must_time(1500),
      must_time(3000),
    )
  let assert 31 =
    claim.attempt_id_label(claim.claim_attempt_id(refreshed_claim))
  let assert 61 =
    claim.ownership_epoch_label(claim.claim_epoch(refreshed_claim))
  let assert 2 = claim.claim_retry_ordinal(refreshed_claim)
  // A supplied accounting observation is not authoritative during renewal.
  let inconsistent_observation =
    make_claim(job_id, 31, 61, 99, must_time(2000), 1)
  let assert Ok(#(_, corrected_observation)) =
    claim.decide_renewal(
      original_attempt,
      inconsistent_observation,
      must_time(1500),
      must_time(3000),
    )
  let assert 2 = claim.claim_retry_ordinal(corrected_observation)
  let assert 2 =
    claim.record_revision_label(claim.current_revision(renewed_attempt))
  let assert 3000 =
    grind.available_at_milliseconds(claim.current_lease_until(renewed_attempt))

  // The old snapshot expired at 2,000, but the live lease runs to 3,000.
  // Its stale revision and expiry do not reject acknowledgement after renewal.
  let acknowledged =
    claim.acknowledge(
      scripted_store(renewed_attempt, must_time(2500), TransactionAvailable),
      command,
    )
  let assert claim.AttemptAcknowledged(
    acknowledged_attempt,
    command_id,
    retained,
  ) = acknowledged
  let assert "ack-renewed" = claim.command_id_label(command_id)
  let assert execution.Succeeded(outcomes.Receipt("renewed owner", 12)) =
    retained
  let assert 3 =
    claim.record_revision_label(claim.current_revision(acknowledged_attempt))
  let assert claim.PhaseAcknowledged(execution.Succeeded(outcomes.Receipt(
    "renewed owner",
    12,
  ))) = claim.current_phase(acknowledged_attempt)
  let assert Error(claim.RenewalRevisionMismatch) =
    claim.decide_renewal(
      renewed_attempt,
      original_claim,
      must_time(2500),
      must_time(4000),
    )

  // A later cancellation request sees this attempt's acknowledgement and does
  // not replace it with cancellation. Job-level projection is outside this slice.
  let assert #(_, claim.RequestAfterAcknowledgement) =
    claim.request_cancellation(acknowledged_attempt)
  let assert #(_, claim.CancellationAfterAcknowledgement) =
    claim.commit_cancellation(acknowledged_attempt)

  let replayed_ack =
    claim.acknowledge(
      scripted_store(
        acknowledged_attempt,
        must_time(2500),
        TransactionAvailable,
      ),
      command,
    )
  let assert claim.AttemptRejected(
    _,
    claim.AttemptAlreadyAcknowledged,
    replayed_proposal,
  ) = replayed_ack
  let assert execution.Succeeded(outcomes.Receipt("renewed owner", 12)) =
    replayed_proposal

  // Exact expiry rejects acknowledgement and prevents late renewal resurrection.
  let exact_expiry_claim = make_claim(job_id, 32, 62, 3, must_time(4000), 1)
  let exact_expiry_attempt = claim.running_attempt(exact_expiry_claim)
  let exact_expiry_command =
    make_command("ack-at-expiry", exact_expiry_claim, succeeded("late", 3))
  let expired_ack =
    claim.acknowledge(
      scripted_store(
        exact_expiry_attempt,
        must_time(4000),
        TransactionAvailable,
      ),
      exact_expiry_command,
    )
  let assert claim.AttemptRejected(_, claim.ExpiredLease, retained_late) =
    expired_ack
  let assert execution.Succeeded(outcomes.Receipt("late", 3)) = retained_late
  let assert Error(claim.RenewalLeaseExpired) =
    claim.decide_renewal(
      exact_expiry_attempt,
      exact_expiry_claim,
      must_time(4000),
      must_time(5000),
    )
  let assert #(requested_at_expiry, claim.CancellationRequested) =
    claim.request_cancellation(exact_expiry_attempt)
  let requested_expiry_ack =
    claim.acknowledge(
      scripted_store(requested_at_expiry, must_time(4000), TransactionAvailable),
      exact_expiry_command,
    )
  let assert claim.AttemptRejected(expired_requested, claim.ExpiredLease, _) =
    requested_expiry_ack
  let assert claim.Executing(grind.Requested) =
    claim.current_phase(expired_requested)

  // After snooze the retry ordinal may repeat, but new attempt and epoch
  // identities reject the old execution while retaining its typed receipt.
  let reclaimed_claim = make_claim(job_id, 33, 63, 2, must_time(5000), 2)
  let reclaimed_attempt = claim.running_attempt(reclaimed_claim)
  let assert 2 = claim.claim_retry_ordinal(reclaimed_claim)
  let assert False =
    claim.claim_attempt_id(original_claim)
    == claim.claim_attempt_id(reclaimed_claim)
  let assert False =
    claim.claim_epoch(original_claim) == claim.claim_epoch(reclaimed_claim)
  let stale_completion =
    claim.acknowledge(
      scripted_store(reclaimed_attempt, must_time(1500), TransactionAvailable),
      command,
    )
  let assert claim.AttemptRejected(
    current,
    claim.StaleOwnership,
    stale_proposal,
  ) = stale_completion
  let assert execution.Succeeded(outcomes.Receipt("renewed owner", 12)) =
    stale_proposal
  let assert 33 =
    claim.attempt_id_label(claim.claim_attempt_id(reclaimed_claim))
  let assert 63 =
    claim.ownership_epoch_label(claim.claim_epoch(reclaimed_claim))
  let assert 2 = claim.record_revision_label(claim.current_revision(current))

  // Cancellation is only requested until a cancellation transition commits.
  let assert #(requested, claim.CancellationRequested) =
    claim.request_cancellation(original_attempt)
  let assert #(cancelled, claim.CancellationWasCommitted) =
    claim.commit_cancellation(requested)
  let assert claim.CancellationCommitted = claim.current_phase(cancelled)
  let cancel_first =
    claim.acknowledge(
      scripted_store(cancelled, must_time(1500), TransactionAvailable),
      command,
    )
  let assert claim.AttemptRejected(_, claim.CancellationWon, cancel_proposal) =
    cancel_first
  let assert execution.Succeeded(outcomes.Receipt("renewed owner", 12)) =
    cancel_proposal

  // A request alone does not win; a live ack transaction can commit it.
  let assert #(requested_only, claim.CancellationRequested) =
    claim.request_cancellation(original_attempt)
  let requested_race =
    claim.acknowledge(
      scripted_store(requested_only, must_time(1500), TransactionAvailable),
      command,
    )
  let assert claim.AttemptRejected(request_won, claim.CancellationWon, _) =
    requested_race
  let assert claim.CancellationCommitted = claim.current_phase(request_won)

  // An uncertain proposal is also retained when committed cancellation wins.
  let uncertainty = execution.Reconcile(value.Text("effect may have happened"))
  let uncertainty_command =
    make_command("ack-uncertain", original_claim, uncertainty)
  let uncertain_cancel_first =
    claim.acknowledge(
      scripted_store(cancelled, must_time(1500), TransactionAvailable),
      uncertainty_command,
    )
  let assert claim.AttemptRejected(
    _,
    claim.CancellationWon,
    retained_uncertainty,
  ) = uncertain_cancel_first
  let assert execution.Reconcile(value.Text("effect may have happened")) =
    retained_uncertainty

  // Unavailable storage and unknown commit remain attached to the exact command.
  let unavailable_command =
    make_command("ack-unavailable", original_claim, proposal)
  let unavailable =
    claim.acknowledge(
      scripted_store(original_attempt, must_time(1500), TransactionUnavailable),
      unavailable_command,
    )
  let assert claim.StoreUnavailable(returned_unavailable_command) = unavailable
  let assert "ack-unavailable" =
    claim.command_id_label(claim.ack_command_id(returned_unavailable_command))
  let assert True = returned_unavailable_command == unavailable_command
  let assert execution.Succeeded(outcomes.Receipt("renewed owner", 12)) =
    claim.ack_command_proposal(returned_unavailable_command)

  let missing_command = make_command("ack-pruned", original_claim, proposal)
  let missing =
    claim.acknowledge(
      scripted_store(original_attempt, must_time(1500), TransactionMissing),
      missing_command,
    )
  let assert claim.MissingAttempt(returned_missing_command) = missing
  let assert "ack-pruned" =
    claim.command_id_label(claim.ack_command_id(returned_missing_command))
  let assert True = returned_missing_command == missing_command
  let assert execution.Succeeded(outcomes.Receipt("renewed owner", 12)) =
    claim.ack_command_proposal(returned_missing_command)

  let unknown_command = make_command("ack-unknown", original_claim, proposal)
  let unknown =
    claim.acknowledge(
      scripted_store(original_attempt, must_time(1500), TransactionUnknown),
      unknown_command,
    )
  let assert claim.UnknownCommit(claim.ReconciliationRecord(
    command_id: unresolved_id,
    claim: unresolved_claim,
    proposal: unresolved_proposal,
  )) = unknown
  let assert "ack-unknown" = claim.command_id_label(unresolved_id)
  let assert True = unresolved_id == claim.ack_command_id(unknown_command)
  let assert True = unresolved_claim == claim.ack_command_claim(unknown_command)
  let assert "invoice-1" =
    grind.job_id_value(claim.claim_job_id(unresolved_claim))
  let assert 31 =
    claim.attempt_id_label(claim.claim_attempt_id(unresolved_claim))
  let assert 61 =
    claim.ownership_epoch_label(claim.claim_epoch(unresolved_claim))
  let assert execution.Succeeded(outcomes.Receipt("renewed owner", 12)) =
    unresolved_proposal
  let assert True =
    unresolved_proposal == claim.ack_command_proposal(unknown_command)
  Nil
}

type FixtureReply {
  TransactionAvailable
  TransactionUnavailable
  TransactionMissing
  TransactionUnknown
}

fn scripted_store(
  current: claim.CurrentAttempt(
    outcomes.Receipt,
    outcomes.PaymentError,
    outcomes.RuntimeReason,
  ),
  now: grind.AvailableAt,
  reply: FixtureReply,
) -> claim.StorePort(
  outcomes.Receipt,
  outcomes.PaymentError,
  outcomes.RuntimeReason,
) {
  claim.store_port(fn(command) {
    case reply {
      TransactionUnavailable -> claim.TransactionUnavailable
      TransactionMissing -> claim.AttemptRecordMissing
      TransactionUnknown -> claim.CommitUnknown
      TransactionAvailable -> {
        let current_claim = claim.ack_command_claim(command)
        let proposal = claim.ack_command_proposal(command)
        let #(next_current, decision) =
          claim.decide_acknowledgement(current, current_claim, now, proposal)
        claim.TransactionResolved(next_current, decision)
      }
    }
  })
}

fn succeeded(
  reference: String,
  amount: Int,
) -> execution.AttemptResolution(
  outcomes.Receipt,
  outcomes.PaymentError,
  outcomes.RuntimeReason,
) {
  execution.Succeeded(outcomes.Receipt(reference, amount))
}

fn make_command(
  id: String,
  snapshot: claim.ClaimSnapshot,
  proposal: execution.AttemptResolution(
    outcomes.Receipt,
    outcomes.PaymentError,
    outcomes.RuntimeReason,
  ),
) -> claim.AckCommand(
  outcomes.Receipt,
  outcomes.PaymentError,
  outcomes.RuntimeReason,
) {
  let assert Ok(command_id) = claim.command_id(id)
  claim.ack_command(command_id, snapshot, proposal)
}

fn make_claim(
  job_id: grind.JobId,
  attempt_label: Int,
  epoch_label: Int,
  retry_ordinal: Int,
  lease_until: grind.AvailableAt,
  revision_label: Int,
) -> claim.ClaimSnapshot {
  let assert Ok(attempt) = claim.attempt_id(attempt_label)
  let assert Ok(epoch) = claim.ownership_epoch(epoch_label)
  let assert Ok(revision) = claim.record_revision(revision_label)
  let assert Ok(snapshot) =
    claim.claim_snapshot(
      job_id,
      attempt,
      epoch,
      retry_ordinal,
      lease_until,
      revision,
    )
  snapshot
}

fn must_time(milliseconds: Int) -> grind.AvailableAt {
  let assert Ok(time) = grind.available_at(milliseconds)
  time
}
