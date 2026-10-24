// THROWAWAY: Can a child owner issue, persist, rebind, and observe typed compensation authority?
import lab/blueprint
import lab/saga
import lab/saga_child_link as child_link
import lab/saga_grind
import lab/saga_run_identity as identity
import lab/value

pub type ChildInput {
  ChildInput(order_id: String)
}

pub type ChildOutput {
  ChildOutput(receipt: String)
}

pub type ChildFailure {
  ChildFailure(reason: String)
}

pub type UndoFailure {
  UndoFailure(reason: String)
}

type Maybe(a) {
  Missing
  Present(a)
}

pub type ClaimEntry {
  ClaimEntry(stored_claim: saga_grind.StoredCompensationClaim)
}

pub type ClaimLedger {
  ClaimLedger(entries: List(ClaimEntry))
}

pub type RequestEntry {
  RequestEntry(
    request: saga_grind.CompensationRequest,
    stored: saga_grind.StoredCompensationRecord,
  )
}

pub type RequestLedger {
  RequestLedger(entries: List(RequestEntry))
}

pub fn probe() -> Nil {
  let child_definition = definition(undo_codec())
  let contract = child_contract(child_definition, 11, 12, 13, 14)
  let child_owner_id = must_owner("checkout-child-owner")
  let child_run_id = identity.run_id("checkout-run-17")
  let claim_deadline = 1_950_000_000_000
  let claimable_run =
    stored_run(
      child_owner_id,
      child_run_id,
      contract,
      11,
      saga_grind.StoredChildCompletedResultPruned(
        saga_grind.StoredCompensationClaimable(claim_deadline),
      ),
    )
  let read_only_owner =
    owner_with(
      child_owner_id,
      claimable_run,
      saga_grind.unsupported_compensation_claim,
      saga_grind.unsupported_compensation_read_claim,
      saga_grind.unsupported_compensation_request,
      saga_grind.unsupported_compensation_observation,
    )
  let assert Ok(child) =
    saga_grind.attach_child(read_only_owner, contract, child_run_id)
  let link = saga_grind.child_link(child)
  let parent =
    parent_attachment("approval-parent", "parent-run-9", "checkout-step-2")
  let command_id = identity.command_id("claim-parent-run-9-checkout-step-2")
  let claim_id_value = must_claim_id("owner-claim-17")
  let claim_command =
    saga_grind.compensation_claim_command(link, parent, command_id)
  let #(claim_ledger, claim_reply_result) =
    decide_claim(
      ClaimLedger([]),
      child_owner_id,
      claim_command,
      claim_id_value,
      claim_deadline - 1,
      claimable_run,
    )
  let assert Ok(saga_grind.CompensationClaimGranted(_, reference, _, _)) =
    claim_reply_result
  let claim_reply =
    saga_grind.CompensationClaimGranted(
      claim_command,
      reference,
      claim_deadline - 1,
      claimable_run,
    )
  let new_claim_owner =
    owner_with(
      child_owner_id,
      claimable_run,
      fn(actual_owner, actual_command) {
        assert_owner(actual_owner, child_owner_id)
        let assert True = actual_command == claim_command
        Ok(claim_reply)
      },
      saga_grind.unsupported_compensation_read_claim,
      saga_grind.unsupported_compensation_request,
      saga_grind.unsupported_compensation_observation,
    )
  let assert Ok(saga_grind.CompensationClaimNew(receipt)) =
    saga_grind.claim_child_compensation(
      new_claim_owner,
      child,
      parent,
      command_id,
    )
  let receipt_reference = saga_grind.compensation_receipt_reference(receipt)
  let assert True = receipt_reference == reference
  assert_reference_codec(receipt_reference)

  let #(_, replayed_claim_result) =
    decide_claim(
      claim_ledger,
      child_owner_id,
      claim_command,
      claim_id_value,
      claim_deadline,
      claimable_run,
    )
  let assert Ok(saga_grind.CompensationClaimAlreadyGranted(stored_claim)) =
    replayed_claim_result
  let replayed_claim_reply =
    saga_grind.CompensationClaimAlreadyGranted(stored_claim)
  let replay_claim_owner =
    owner_with(
      child_owner_id,
      claimable_run,
      fn(actual_owner, actual_command) {
        assert_owner(actual_owner, child_owner_id)
        let assert True = actual_command == claim_command
        Ok(replayed_claim_reply)
      },
      fn(actual_owner, actual_reference) {
        assert_owner(actual_owner, child_owner_id)
        let assert True = actual_reference == receipt_reference
        case find_claim(claim_ledger, actual_reference) {
          Present(stored_claim) -> Ok(stored_claim)
          Missing -> Error(saga_grind.ClaimRecordMissing)
        }
      },
      saga_grind.unsupported_compensation_request,
      saga_grind.unsupported_compensation_observation,
    )
  let assert Ok(saga_grind.CompensationClaimReplayed(replayed_receipt)) =
    saga_grind.claim_child_compensation(
      replay_claim_owner,
      child,
      parent,
      command_id,
    )
  let assert True =
    saga_grind.compensation_receipt_reference(replayed_receipt)
    == receipt_reference

  assert_claim_conflicts(
    claim_ledger,
    child_owner_id,
    link,
    parent,
    claim_deadline,
    claimable_run,
  )
  assert_expiry_and_claim_failures(
    child_owner_id,
    link,
    parent,
    command_id,
    claim_deadline,
    claimable_run,
  )
  assert_malformed_claim_reply_recovers(
    child_owner_id,
    child,
    parent,
    claim_command,
    reference,
    claim_reply,
  )

  let fresh_contract = child_contract(definition(undo_codec()), 11, 12, 13, 14)
  let assert Ok(rebound) =
    saga_grind.rebind_compensation_receipt(
      replay_claim_owner,
      fresh_contract,
      receipt_reference,
    )
  let assert True =
    saga_grind.compensation_receipt_reference(rebound) == receipt_reference
  assert_rebind_rejects_before_owner_or_decoder(
    child_owner_id,
    receipt_reference,
    child_definition,
  )

  let request_command_id = identity.command_id("compensate-checkout-17")
  let operation =
    saga_grind.compensation_request(receipt_reference, request_command_id)
  let request_deadline = claim_deadline
  let request_record =
    stored_compensation_record(
      receipt_reference,
      request_command_id,
      claimable_run,
      saga_grind.StoredCompensationPending,
    )
  let #(request_ledger, request_reply) =
    decide_request(
      claim_ledger,
      RequestLedger([]),
      operation,
      request_record,
      claim_deadline - 1,
    )
  let assert Ok(saga_grind.CompensationRequestStarted(_, _)) = request_reply
  let lost_ack_owner =
    owner_with(
      child_owner_id,
      claimable_run,
      saga_grind.unsupported_compensation_claim,
      saga_grind.unsupported_compensation_read_claim,
      fn(actual_owner, actual_request) {
        assert_owner(actual_owner, child_owner_id)
        let assert True = actual_request == operation
        Error(saga_grind.RequestPortCommitUnknown)
      },
      saga_grind.unsupported_compensation_observation,
    )
  let assert Error(saga_grind.CompensationRequestCommitUnknown(
    uncertain_request,
  )) =
    saga_grind.request_child_compensation(
      lost_ack_owner,
      receipt,
      request_command_id,
    )
  let request_handle =
    assert_request_recovery(
      child_owner_id,
      claimable_run,
      receipt,
      reference,
      operation,
      claim_ledger,
      request_ledger,
      request_deadline,
      uncertain_request,
    )
  assert_request_single_admission(
    claim_ledger,
    request_ledger,
    receipt_reference,
    request_deadline,
    request_record,
  )
  assert_compensation_observation(
    child_owner_id,
    claimable_run,
    receipt,
    reference,
    operation,
    request_handle,
  )
  assert_observation_metadata_precedes_decoder(
    child_owner_id,
    replay_claim_owner,
    claimable_run,
    link,
    receipt_reference,
  )
  Nil
}

fn definition(
  undo: blueprint.Codec(UndoFailure),
) -> saga.Definition(ChildInput, ChildOutput, ChildFailure, UndoFailure) {
  let assert Ok(definition_id) = saga.definition_id("checkout-child")
  let assert Ok(step_id) = saga.step_id("reserve-stock")
  let assert Ok(step_version) = saga.version(3)
  let assert Ok(input_version) = saga.version(11)
  let assert Ok(output_version) = saga.version(12)
  let assert Ok(error_version) = saga.version(13)
  let assert Ok(undo_version) = saga.version(14)
  let assert Ok(definition_version) = saga.version(7)
  let activity_contract =
    saga.ActivityContract(
      saga.VersionedCodec(input_version, child_input_codec()),
      saga.VersionedCodec(output_version, child_output_codec()),
      saga.VersionedCodec(error_version, child_failure_codec()),
      saga.VersionedCodec(undo_version, undo),
    )
  let activity =
    saga.activity(
      step_id,
      step_version,
      activity_contract,
      fn(input) { Ok(ChildOutput("receipt-" <> input.order_id)) },
      saga.Compensate(fn(_, _) { Ok(Nil) }),
    )
  saga.define(
    definition_id,
    definition_version,
    "checkout-child-signature-v7",
    activity,
  )
}

fn child_contract(
  definition: saga.Definition(
    ChildInput,
    ChildOutput,
    ChildFailure,
    UndoFailure,
  ),
  input_version: Int,
  output_version: Int,
  error_version: Int,
  undo_error_version: Int,
) -> saga.ChildContract(ChildInput, ChildOutput, ChildFailure, UndoFailure) {
  let assert Ok(input) = saga.version(input_version)
  let assert Ok(output) = saga.version(output_version)
  let assert Ok(error) = saga.version(error_version)
  let assert Ok(undo_error) = saga.version(undo_error_version)
  saga.child_contract(
    definition,
    saga.BoundaryVersions(input, output, error, undo_error),
  )
}

fn child_input_codec() -> blueprint.Codec(ChildInput) {
  blueprint.imap(blueprint.text(), ChildInput, fn(input) { input.order_id })
}

fn child_output_codec() -> blueprint.Codec(ChildOutput) {
  blueprint.imap(blueprint.text(), ChildOutput, fn(output) { output.receipt })
}

fn child_failure_codec() -> blueprint.Codec(ChildFailure) {
  blueprint.imap(blueprint.text(), ChildFailure, fn(failure) { failure.reason })
}

fn undo_codec() -> blueprint.Codec(UndoFailure) {
  blueprint.imap(blueprint.text(), UndoFailure, fn(failure) { failure.reason })
}

fn panic_undo_codec() -> blueprint.Codec(UndoFailure) {
  blueprint.new(fn(failure) { blueprint.encode(undo_codec(), failure) }, fn(_) {
    todo as "metadata mismatch must be detected before undo decoding"
  })
}

fn panic_output_codec() -> blueprint.Codec(ChildOutput) {
  blueprint.new(
    fn(output) { blueprint.encode(child_output_codec(), output) },
    fn(_) {
      todo as "claiming compensation must not decode the historical output"
    },
  )
}

fn stored_run(
  owner: saga_grind.OwnerId,
  run_id: identity.RunId,
  contract: saga.ChildContract(
    ChildInput,
    ChildOutput,
    ChildFailure,
    UndoFailure,
  ),
  revision: Int,
  state: saga_grind.StoredChildState,
) -> saga_grind.StoredRun {
  let versions = saga.child_contract_boundary_versions(contract)
  saga_grind.StoredRun(
    saga_grind.owner_id_value(owner),
    run_id,
    saga.child_contract_identity(contract),
    saga.child_contract_version(contract),
    saga.child_contract_signature(contract),
    versions.0,
    versions.1,
    versions.2,
    versions.3,
    revision,
    state,
  )
}

fn must_owner(value: String) -> saga_grind.OwnerId {
  let assert Ok(owner) = saga_grind.owner_id(value)
  owner
}

fn parent_attachment(
  owner: String,
  run: String,
  attachment: String,
) -> saga_grind.ParentAttachment {
  let parent_owner = must_owner(owner)
  let parent_run = identity.run_id(run)
  let assert Ok(attachment) = saga_grind.attachment_id(attachment)
  let assert Ok(parent) =
    saga_grind.parent_attachment(parent_owner, parent_run, attachment)
  parent
}

fn must_claim_id(value: String) -> saga_grind.ClaimId {
  let assert Ok(claim) = saga_grind.claim_id(value)
  claim
}

fn owner_with(
  owner: saga_grind.OwnerId,
  stored: saga_grind.StoredRun,
  claim: fn(saga_grind.OwnerId, saga_grind.CompensationClaimCommand) ->
    Result(
      saga_grind.CompensationClaimReply,
      saga_grind.CompensationClaimPortError,
    ),
  read_claim: fn(saga_grind.OwnerId, saga_grind.DurableCompensationReceiptRef) ->
    Result(
      saga_grind.StoredCompensationClaim,
      saga_grind.CompensationClaimReadError,
    ),
  request: fn(saga_grind.OwnerId, saga_grind.CompensationRequest) ->
    Result(
      saga_grind.CompensationRequestReply,
      saga_grind.CompensationRequestPortError,
    ),
  observe: fn(saga_grind.OwnerId, saga_grind.CompensationRequest) ->
    Result(
      saga_grind.StoredCompensationRecord,
      saga_grind.CompensationObservePortError,
    ),
) -> saga_grind.DurableOwner {
  let port =
    saga_grind.owner_port(
      fn(actual_owner, requested_run) {
        assert_owner(actual_owner, owner)
        case requested_run == stored.run_id {
          True -> Ok(stored)
          False -> Error(saga_grind.StoredRunMissing)
        }
      },
      saga_grind.unsupported_submission,
      saga_grind.unsupported_cancellation,
      saga_grind.compensation_port(claim, read_claim, request, observe),
    )
  saga_grind.durable_owner(owner, port)
}

fn assert_owner(
  actual: saga_grind.OwnerId,
  expected: saga_grind.OwnerId,
) -> Nil {
  let assert True =
    saga_grind.owner_id_value(actual) == saga_grind.owner_id_value(expected)
  Nil
}

fn decide_claim(
  ledger: ClaimLedger,
  owner: saga_grind.OwnerId,
  command: saga_grind.CompensationClaimCommand,
  claim_id: saga_grind.ClaimId,
  now: Int,
  stored: saga_grind.StoredRun,
) -> #(
  ClaimLedger,
  Result(
    saga_grind.CompensationClaimReply,
    saga_grind.CompensationClaimPortError,
  ),
) {
  case
    child_link.owner(saga_grind.claim_command_link(command))
    == saga_grind.owner_id_value(owner)
  {
    False -> #(ledger, Error(saga_grind.ClaimRejected))
    True -> decide_claim_owned(ledger, command, claim_id, now, stored)
  }
}

fn decide_claim_owned(
  ledger: ClaimLedger,
  command: saga_grind.CompensationClaimCommand,
  claim_id: saga_grind.ClaimId,
  now: Int,
  stored: saga_grind.StoredRun,
) -> #(
  ClaimLedger,
  Result(
    saga_grind.CompensationClaimReply,
    saga_grind.CompensationClaimPortError,
  ),
) {
  case find_claim_for_link(ledger, saga_grind.claim_command_link(command)) {
    Present(existing) -> {
      let accepted = existing.accepted
      case accepted == command {
        True -> #(
          ledger,
          Ok(saga_grind.CompensationClaimAlreadyGranted(existing)),
        )
        False ->
          case
            saga_grind.claim_command_parent(accepted)
            == saga_grind.claim_command_parent(command)
          {
            True -> #(ledger, Error(saga_grind.ClaimCommandConflict))
            False -> #(
              ledger,
              Error(saga_grind.ClaimAlreadyOwnedByAnotherParent),
            )
          }
      }
    }
    Missing ->
      case claim_deadline(stored.state) {
        Error(error) -> #(ledger, Error(error))
        Ok(until) ->
          case now >= 0 && now < until {
            False -> #(ledger, Error(saga_grind.ClaimWindowExpired))
            True -> {
              let reference =
                saga_grind.compensation_reference(
                  saga_grind.claim_command_link(command),
                  claim_id,
                  saga_grind.claim_command_parent(command),
                )
              let entry =
                saga_grind.StoredCompensationClaim(command, reference, stored)
              let next = ClaimLedger([ClaimEntry(entry), ..ledger.entries])
              let reply =
                saga_grind.CompensationClaimGranted(
                  command,
                  reference,
                  now,
                  stored,
                )
              #(next, Ok(reply))
            }
          }
      }
  }
}

fn claim_deadline(
  state: saga_grind.StoredChildState,
) -> Result(Int, saga_grind.CompensationClaimPortError) {
  case state {
    saga_grind.StoredChildCompleted(
      _,
      saga_grind.StoredCompensationClaimable(until),
    ) -> Ok(until)
    saga_grind.StoredChildCompletedResultPruned(saga_grind.StoredCompensationClaimable(
      until,
    )) -> Ok(until)
    saga_grind.StoredChildCompleted(_, saga_grind.StoredCompensationDiscarded) ->
      Error(saga_grind.ClaimCompensationDiscarded)
    saga_grind.StoredChildCompletedResultPruned(
      saga_grind.StoredCompensationDiscarded,
    ) -> Error(saga_grind.ClaimCompensationDiscarded)
    saga_grind.StoredChildCompleted(
      _,
      saga_grind.StoredCompensationJournalPruned,
    ) -> Error(saga_grind.ClaimJournalPruned)
    saga_grind.StoredChildCompletedResultPruned(
      saga_grind.StoredCompensationJournalPruned,
    ) -> Error(saga_grind.ClaimJournalPruned)
    _ -> Error(saga_grind.ClaimChildNotSuccessful)
  }
}

fn find_claim(
  ledger: ClaimLedger,
  reference: saga_grind.DurableCompensationReceiptRef,
) -> Maybe(saga_grind.StoredCompensationClaim) {
  case ledger.entries {
    [] -> Missing
    [ClaimEntry(entry), ..rest] ->
      case entry.reference == reference {
        True -> Present(entry)
        False -> find_claim(ClaimLedger(rest), reference)
      }
  }
}

fn find_claim_for_link(
  ledger: ClaimLedger,
  link: child_link.ChildLink,
) -> Maybe(saga_grind.StoredCompensationClaim) {
  case ledger.entries {
    [] -> Missing
    [ClaimEntry(entry), ..rest] ->
      case saga_grind.receipt_child_link(entry.reference) == link {
        True -> Present(entry)
        False -> find_claim_for_link(ClaimLedger(rest), link)
      }
  }
}

fn decide_request(
  claims: ClaimLedger,
  ledger: RequestLedger,
  request: saga_grind.CompensationRequest,
  record: saga_grind.StoredCompensationRecord,
  now: Int,
) -> #(
  RequestLedger,
  Result(
    saga_grind.CompensationRequestReply,
    saga_grind.CompensationRequestPortError,
  ),
) {
  let reference = saga_grind.compensation_request_reference(request)
  case find_claim(claims, reference) {
    Missing -> #(ledger, Error(saga_grind.RequestPortMissingClaim))
    Present(claim) ->
      case find_request_for_reference(ledger, reference) {
        Present(existing) ->
          case existing.request == request {
            True -> #(
              ledger,
              Ok(saga_grind.CompensationRequestAlreadyExists(
                existing.request,
                existing.stored,
              )),
            )
            False -> #(ledger, Error(saga_grind.RequestPortAlreadyAdmitted))
          }
        Missing ->
          case claim_deadline(claim.stored.state) {
            Error(saga_grind.ClaimJournalPruned) -> #(
              ledger,
              Error(saga_grind.RequestPortJournalUnavailable),
            )
            Error(saga_grind.ClaimCompensationDiscarded) -> #(
              ledger,
              Error(saga_grind.RequestPortJournalUnavailable),
            )
            Error(_) -> #(ledger, Error(saga_grind.RequestPortMissingClaim))
            Ok(expires_at) ->
              case now >= 0 && now < expires_at {
                False -> #(ledger, Error(saga_grind.RequestPortExpired))
                True -> {
                  let next =
                    RequestLedger([
                      RequestEntry(request, record),
                      ..ledger.entries
                    ])
                  #(
                    next,
                    Ok(saga_grind.CompensationRequestStarted(request, record)),
                  )
                }
              }
          }
      }
  }
}

fn find_request_for_reference(
  ledger: RequestLedger,
  reference: saga_grind.DurableCompensationReceiptRef,
) -> Maybe(RequestEntry) {
  case ledger.entries {
    [] -> Missing
    [entry, ..rest] ->
      case
        saga_grind.compensation_request_reference(entry.request) == reference
      {
        True -> Present(entry)
        False -> find_request_for_reference(RequestLedger(rest), reference)
      }
  }
}

fn stored_compensation_record(
  reference: saga_grind.DurableCompensationReceiptRef,
  request_id: identity.CommandId,
  run: saga_grind.StoredRun,
  status: saga_grind.StoredCompensation,
) -> saga_grind.StoredCompensationRecord {
  saga_grind.StoredCompensationRecord(
    reference,
    request_id,
    saga_grind.metadata_for_run(run),
    saga_grind.StoredChildHistoricallySucceeded,
    status,
  )
}

fn assert_reference_codec(
  reference: saga_grind.DurableCompensationReceiptRef,
) -> Nil {
  let codec = saga_grind.compensation_receipt_ref_codec()
  let assert Ok(encoded) = blueprint.encode(codec, reference)
  let assert Ok(decoded) = blueprint.decode(codec, encoded)
  let assert True = decoded == reference
  let assert Error(_) = blueprint.decode(codec, value.Array([]))
  Nil
}

fn assert_claim_conflicts(
  ledger: ClaimLedger,
  owner: saga_grind.OwnerId,
  link: child_link.ChildLink,
  parent: saga_grind.ParentAttachment,
  deadline: Int,
  stored: saga_grind.StoredRun,
) -> Nil {
  let command_id = identity.command_id("different-claim-command")
  let command = saga_grind.compensation_claim_command(link, parent, command_id)
  let #(_, same_parent) =
    decide_claim(
      ledger,
      owner,
      command,
      must_claim_id("unused-claim-id"),
      deadline - 1,
      stored,
    )
  let assert Error(saga_grind.ClaimCommandConflict) = same_parent
  let other_parent =
    parent_attachment("other-parent", "parent-run-9", "checkout-step-2")
  let other_command =
    saga_grind.compensation_claim_command(
      link,
      other_parent,
      identity.command_id("other-parent-claim"),
    )
  let #(_, other_owner) =
    decide_claim(
      ledger,
      owner,
      other_command,
      must_claim_id("unused-claim-id-2"),
      deadline - 1,
      stored,
    )
  let assert Error(saga_grind.ClaimAlreadyOwnedByAnotherParent) = other_owner
  Nil
}

fn assert_expiry_and_claim_failures(
  owner: saga_grind.OwnerId,
  link: child_link.ChildLink,
  parent: saga_grind.ParentAttachment,
  command_id: identity.CommandId,
  deadline: Int,
  stored: saga_grind.StoredRun,
) -> Nil {
  let fresh_command =
    saga_grind.compensation_claim_command(
      link,
      parent,
      identity.command_id("fresh-after-expiry"),
    )
  let #(_, expired) =
    decide_claim(
      ClaimLedger([]),
      owner,
      fresh_command,
      must_claim_id("expired-claim"),
      deadline,
      stored,
    )
  let assert Error(saga_grind.ClaimWindowExpired) = expired
  let discarded =
    stored_run(
      owner,
      stored.run_id,
      child_contract(definition(undo_codec()), 11, 12, 13, 14),
      12,
      saga_grind.StoredChildCompletedResultPruned(
        saga_grind.StoredCompensationDiscarded,
      ),
    )
  let #(_, discard_error) =
    decide_claim(
      ClaimLedger([]),
      owner,
      saga_grind.compensation_claim_command(link, parent, command_id),
      must_claim_id("discarded-claim"),
      deadline - 1,
      discarded,
    )
  let assert Error(saga_grind.ClaimCompensationDiscarded) = discard_error
  let pruned =
    stored_run(
      owner,
      stored.run_id,
      child_contract(definition(undo_codec()), 11, 12, 13, 14),
      12,
      saga_grind.StoredChildCompletedResultPruned(
        saga_grind.StoredCompensationJournalPruned,
      ),
    )
  let #(_, prune_error) =
    decide_claim(
      ClaimLedger([]),
      owner,
      saga_grind.compensation_claim_command(
        link,
        parent,
        identity.command_id("pruned-command"),
      ),
      must_claim_id("pruned-claim"),
      deadline - 1,
      pruned,
    )
  let assert Error(saga_grind.ClaimJournalPruned) = prune_error
  let failed =
    stored_run(
      owner,
      stored.run_id,
      child_contract(definition(undo_codec()), 11, 12, 13, 14),
      12,
      saga_grind.StoredChildFailed(value.Text("failed"), []),
    )
  let #(_, failed_error) =
    decide_claim(
      ClaimLedger([]),
      owner,
      saga_grind.compensation_claim_command(
        link,
        parent,
        identity.command_id("failed-command"),
      ),
      must_claim_id("failed-claim"),
      deadline - 1,
      failed,
    )
  let assert Error(saga_grind.ClaimChildNotSuccessful) = failed_error
  Nil
}

fn assert_malformed_claim_reply_recovers(
  owner: saga_grind.OwnerId,
  child: saga_grind.DurableChild(ChildOutput, ChildFailure, UndoFailure),
  parent: saga_grind.ParentAttachment,
  command: saga_grind.CompensationClaimCommand,
  reference: saga_grind.DurableCompensationReceiptRef,
  valid_reply: saga_grind.CompensationClaimReply,
) -> Nil {
  let wrong_reference =
    saga_grind.compensation_reference(
      saga_grind.claim_command_link(command),
      must_claim_id("wrong-claim-id"),
      parent,
    )
  let assert Error(saga_grind.CompensationClaimReplyInvalid(_, uncertain)) =
    saga_grind.claim_child_compensation(
      owner_with(
        owner,
        dummy_run(),
        fn(_, _) {
          Ok(saga_grind.CompensationClaimGranted(
            command,
            wrong_reference,
            1,
            dummy_run(),
          ))
        },
        saga_grind.unsupported_compensation_read_claim,
        saga_grind.unsupported_compensation_request,
        saga_grind.unsupported_compensation_observation,
      ),
      child,
      parent,
      saga_grind.claim_command_id(command),
    )
  let assert Error(saga_grind.CompensationClaimRouteMismatch(_)) =
    saga_grind.retry_compensation_claim(
      owner_with(
        must_owner("wrong-owner-route"),
        dummy_run(),
        saga_grind.unsupported_compensation_claim,
        saga_grind.unsupported_compensation_read_claim,
        saga_grind.unsupported_compensation_request,
        saga_grind.unsupported_compensation_observation,
      ),
      uncertain,
    )
  let retry_owner =
    owner_with(
      owner,
      dummy_run(),
      fn(actual_owner, actual_command) {
        assert_owner(actual_owner, owner)
        let assert True = actual_command == command
        Ok(valid_reply)
      },
      saga_grind.unsupported_compensation_read_claim,
      saga_grind.unsupported_compensation_request,
      saga_grind.unsupported_compensation_observation,
    )
  let assert Ok(saga_grind.CompensationClaimNew(recovered)) =
    saga_grind.retry_compensation_claim(retry_owner, uncertain)
  let assert True =
    saga_grind.compensation_receipt_reference(recovered) == reference
  Nil
}

fn assert_rebind_rejects_before_owner_or_decoder(
  owner: saga_grind.OwnerId,
  reference: saga_grind.DurableCompensationReceiptRef,
  child_definition: saga.Definition(
    ChildInput,
    ChildOutput,
    ChildFailure,
    UndoFailure,
  ),
) -> Nil {
  let incompatible = child_contract(child_definition, 11, 12, 13, 99)
  let panic_owner =
    owner_with(
      owner,
      dummy_run(),
      saga_grind.unsupported_compensation_claim,
      fn(_, _) { todo as "metadata mismatch must be rejected before owner read" },
      saga_grind.unsupported_compensation_request,
      saga_grind.unsupported_compensation_observation,
    )
  let assert Error(saga_grind.CompensationReceiptIncompatible(
    saga_grind.ChildUndoErrorCodecVersionMismatch,
  )) =
    saga_grind.rebind_compensation_receipt(panic_owner, incompatible, reference)
  let bad_run =
    stored_run(
      owner,
      child_link.run(saga_grind.receipt_child_link(reference)),
      incompatible,
      12,
      saga_grind.StoredChildCompletedResultPruned(
        saga_grind.StoredCompensationClaimable(2_000_000_000_000),
      ),
    )
  let bad_stored_claim =
    saga_grind.StoredCompensationClaim(
      saga_grind.compensation_claim_command(
        saga_grind.receipt_child_link(reference),
        saga_grind.receipt_parent(reference),
        identity.command_id("stored-rebind-command"),
      ),
      reference,
      bad_run,
    )
  let bad_claim_owner =
    owner_with(
      owner,
      dummy_run(),
      saga_grind.unsupported_compensation_claim,
      fn(actual_owner, actual_reference) {
        assert_owner(actual_owner, owner)
        let assert True = actual_reference == reference
        Ok(bad_stored_claim)
      },
      saga_grind.unsupported_compensation_request,
      saga_grind.unsupported_compensation_observation,
    )
  let assert Error(saga_grind.CompensationClaimStoredRunIncompatible(
    saga_grind.ChildUndoErrorCodecVersionMismatch,
  )) =
    saga_grind.rebind_compensation_receipt(
      bad_claim_owner,
      child_contract(child_definition, 11, 12, 13, 14),
      reference,
    )
  Nil
}

fn assert_request_recovery(
  owner: saga_grind.OwnerId,
  stored_run: saga_grind.StoredRun,
  receipt: saga_grind.DurableCompensationReceipt(UndoFailure),
  reference: saga_grind.DurableCompensationReceiptRef,
  operation: saga_grind.CompensationRequest,
  claims: ClaimLedger,
  ledger: RequestLedger,
  deadline: Int,
  uncertain: saga_grind.UncertainCompensationRequest(UndoFailure),
) -> saga_grind.CompensationHandle(UndoFailure) {
  let #(_, replay_reply) =
    decide_request(
      claims,
      ledger,
      operation,
      stored_compensation_record(
        reference,
        saga_grind.compensation_request_command_id(operation),
        stored_run,
        saga_grind.StoredCompensationPending,
      ),
      deadline,
    )
  let assert Ok(saga_grind.CompensationRequestAlreadyExists(_, _)) =
    replay_reply
  let owner_port =
    owner_with(
      owner,
      stored_run,
      saga_grind.unsupported_compensation_claim,
      saga_grind.unsupported_compensation_read_claim,
      fn(actual_owner, actual_request) {
        assert_owner(actual_owner, owner)
        let assert True = actual_request == operation
        replay_reply
      },
      saga_grind.unsupported_compensation_observation,
    )
  let assert Error(saga_grind.CompensationRequestRouteMismatch(_)) =
    saga_grind.retry_child_compensation_request(
      owner_with(
        must_owner("different-compensation-owner"),
        stored_run,
        saga_grind.unsupported_compensation_claim,
        saga_grind.unsupported_compensation_read_claim,
        saga_grind.unsupported_compensation_request,
        saga_grind.unsupported_compensation_observation,
      ),
      uncertain,
    )
  let assert Ok(saga_grind.CompensationRequestReplayed(handle)) =
    saga_grind.retry_child_compensation_request(owner_port, uncertain)
  let assert True = saga_grind.compensation_handle_request(handle) == operation
  let _ = receipt
  handle
}

fn assert_request_single_admission(
  claims: ClaimLedger,
  ledger: RequestLedger,
  reference: saga_grind.DurableCompensationReceiptRef,
  deadline: Int,
  record: saga_grind.StoredCompensationRecord,
) -> Nil {
  let different =
    saga_grind.compensation_request(
      reference,
      identity.command_id("second-command-must-not-redeem-receipt"),
    )
  let accepted_request =
    saga_grind.compensation_request(reference, record.request_id)
  let #(_, replay_after_deadline) =
    decide_request(claims, ledger, accepted_request, record, deadline)
  let assert Error(saga_grind.RequestPortAlreadyAdmitted) =
    decide_request(claims, ledger, different, record, deadline - 1).1
  let assert Ok(saga_grind.CompensationRequestAlreadyExists(_, _)) =
    replay_after_deadline
  let assert Error(saga_grind.RequestPortAlreadyAdmitted) =
    decide_request(claims, ledger, different, record, deadline + 1).1
  let #(_, no_admission) =
    decide_request(claims, RequestLedger([]), different, record, deadline)
  let assert Error(saga_grind.RequestPortExpired) = no_admission
  let fabricated_reference =
    saga_grind.compensation_reference(
      saga_grind.receipt_child_link(reference),
      must_claim_id("never-claimed"),
      saga_grind.receipt_parent(reference),
    )
  let fabricated_request =
    saga_grind.compensation_request(
      fabricated_reference,
      identity.command_id("unowned-compensation"),
    )
  let #(_, no_claim) =
    decide_request(
      ClaimLedger([]),
      RequestLedger([]),
      fabricated_request,
      record,
      deadline - 1,
    )
  let assert Error(saga_grind.RequestPortMissingClaim) = no_claim
  Nil
}

fn assert_compensation_observation(
  owner: saga_grind.OwnerId,
  run: saga_grind.StoredRun,
  receipt: saga_grind.DurableCompensationReceipt(UndoFailure),
  reference: saga_grind.DurableCompensationReceiptRef,
  operation: saga_grind.CompensationRequest,
  handle: saga_grind.CompensationHandle(UndoFailure),
) -> Nil {
  let pending =
    stored_compensation_record(
      reference,
      saga_grind.compensation_request_command_id(operation),
      run,
      saga_grind.StoredCompensationPending,
    )
  let assert Ok(saga_grind.CompensationPending) =
    saga_grind.observe_child_compensation(
      owner_with(
        owner,
        run,
        saga_grind.unsupported_compensation_claim,
        saga_grind.unsupported_compensation_read_claim,
        saga_grind.unsupported_compensation_request,
        fn(_, _) { Ok(pending) },
      ),
      handle,
    )
  let succeeded =
    stored_compensation_record(
      reference,
      saga_grind.compensation_request_command_id(operation),
      run,
      saga_grind.StoredCompensationSucceeded,
    )
  let assert Ok(saga_grind.CompensationSucceeded) =
    saga_grind.observe_child_compensation(
      owner_with(
        owner,
        run,
        saga_grind.unsupported_compensation_claim,
        saga_grind.unsupported_compensation_read_claim,
        saga_grind.unsupported_compensation_request,
        fn(actual_owner, actual_request) {
          assert_owner(actual_owner, owner)
          let assert True = actual_request == operation
          Ok(succeeded)
        },
      ),
      handle,
    )
  let failed =
    stored_compensation_record(
      reference,
      saga_grind.compensation_request_command_id(operation),
      run,
      saga_grind.StoredCompensationFailed([value.Text("undo-sentinel")]),
    )
  let assert Ok(saga_grind.CompensationFailed([UndoFailure("undo-sentinel")])) =
    saga_grind.observe_child_compensation(
      owner_with(
        owner,
        run,
        saga_grind.unsupported_compensation_claim,
        saga_grind.unsupported_compensation_read_claim,
        saga_grind.unsupported_compensation_request,
        fn(_, _) { Ok(failed) },
      ),
      handle,
    )
  let reconciled =
    stored_compensation_record(
      reference,
      saga_grind.compensation_request_command_id(operation),
      run,
      saga_grind.StoredCompensationNeedsReconciliation([
        value.Text("uncertain-effect"),
      ]),
    )
  let assert Ok(saga_grind.CompensationNeedsReconciliation([
    value.Text("uncertain-effect"),
  ])) =
    saga_grind.observe_child_compensation(
      owner_with(
        owner,
        run,
        saga_grind.unsupported_compensation_claim,
        saga_grind.unsupported_compensation_read_claim,
        saga_grind.unsupported_compensation_request,
        fn(_, _) { Ok(reconciled) },
      ),
      handle,
    )
  assert_child_output_preserved(owner, run, receipt)
  Nil
}

fn assert_observation_metadata_precedes_decoder(
  owner: saga_grind.OwnerId,
  claim_owner: saga_grind.DurableOwner,
  original_run: saga_grind.StoredRun,
  link: child_link.ChildLink,
  reference: saga_grind.DurableCompensationReceiptRef,
) -> Nil {
  let panic_contract =
    child_contract(definition(panic_undo_codec()), 11, 12, 13, 14)
  let assert Ok(_) =
    saga_grind.reattach_child(claim_owner, panic_contract, link)
  let assert Ok(receipt) =
    saga_grind.rebind_compensation_receipt(
      claim_owner,
      panic_contract,
      reference,
    )
  let command =
    saga_grind.compensation_request(
      reference,
      identity.command_id("metadata-before-undo-decode"),
    )
  let good_record =
    stored_compensation_record(
      reference,
      saga_grind.compensation_request_command_id(command),
      original_run,
      saga_grind.StoredCompensationPending,
    )
  let start_owner =
    owner_with(
      owner,
      original_run,
      saga_grind.unsupported_compensation_claim,
      saga_grind.unsupported_compensation_read_claim,
      fn(_, actual_request) {
        let assert True = actual_request == command
        Ok(saga_grind.CompensationRequestStarted(command, good_record))
      },
      saga_grind.unsupported_compensation_observation,
    )
  let assert Ok(saga_grind.CompensationRequestNew(handle)) =
    saga_grind.request_child_compensation(
      start_owner,
      receipt,
      saga_grind.compensation_request_command_id(command),
    )
  let incompatible_contract =
    child_contract(definition(panic_undo_codec()), 11, 12, 13, 99)
  let incompatible_run =
    stored_run(
      owner,
      original_run.run_id,
      incompatible_contract,
      99,
      saga_grind.StoredChildCompletedResultPruned(
        saga_grind.StoredCompensationClaimable(2_000_000_000_000),
      ),
    )
  let malformed_payload =
    saga_grind.StoredCompensationRecord(
      reference,
      saga_grind.compensation_request_command_id(command),
      saga_grind.metadata_for_run(incompatible_run),
      saga_grind.StoredChildHistoricallySucceeded,
      saga_grind.StoredCompensationFailed([value.Text("must-not-decode")]),
    )
  let assert Error(saga_grind.CompensationObservationIncompatible(
    saga_grind.ChildUndoErrorCodecVersionMismatch,
  )) =
    saga_grind.observe_child_compensation(
      owner_with(
        owner,
        original_run,
        saga_grind.unsupported_compensation_claim,
        saga_grind.unsupported_compensation_read_claim,
        saga_grind.unsupported_compensation_request,
        fn(_, actual_request) {
          let assert True = actual_request == command
          Ok(malformed_payload)
        },
      ),
      handle,
    )
  Nil
}

fn assert_child_output_preserved(
  owner: saga_grind.OwnerId,
  old_run: saga_grind.StoredRun,
  _receipt: saga_grind.DurableCompensationReceipt(UndoFailure),
) -> Nil {
  let contract = child_contract(definition(undo_codec()), 11, 12, 13, 14)
  let run =
    stored_run(
      owner,
      old_run.run_id,
      contract,
      17,
      saga_grind.StoredChildCompleted(
        value.Text("historical-receipt-17"),
        saga_grind.StoredCompensationSucceeded,
      ),
    )
  let assert Ok(child) =
    saga_grind.attach_child(
      owner_with(
        owner,
        run,
        saga_grind.unsupported_compensation_claim,
        saga_grind.unsupported_compensation_read_claim,
        saga_grind.unsupported_compensation_request,
        saga_grind.unsupported_compensation_observation,
      ),
      contract,
      run.run_id,
    )
  let assert Ok(saga_grind.ChildCompleted(
    17,
    ChildOutput("historical-receipt-17"),
    saga_grind.CompensationRequested(saga_grind.CompensationSucceeded),
  )) =
    saga_grind.observe_child(
      owner_with(
        owner,
        run,
        saga_grind.unsupported_compensation_claim,
        saga_grind.unsupported_compensation_read_claim,
        saga_grind.unsupported_compensation_request,
        saga_grind.unsupported_compensation_observation,
      ),
      child,
    )
  Nil
}

fn dummy_run() -> saga_grind.StoredRun {
  let owner = must_owner("dummy-owner")
  let contract = child_contract(definition(undo_codec()), 11, 12, 13, 14)
  stored_run(
    owner,
    identity.run_id("dummy-run"),
    contract,
    1,
    saga_grind.StoredChildQueued,
  )
}
