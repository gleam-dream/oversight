// THROWAWAY: Can child admission preserve a retryable owner command and typed result boundary?
import lab/blueprint
import lab/grind as jobs
import lab/saga
import lab/saga_grind
import lab/saga_run_identity as identity
import lab/value

pub type ChildInput {
  ChildInput(order_id: String, quantity: Int)
}

pub type Receipt {
  Receipt(order_id: String)
}

pub type ChildFailure {
  ChildFailure(reason: String)
}

pub type UndoFailure {
  UndoFailure(reason: String)
}

pub type SubmissionRecord {
  SubmissionRecord(
    command: String,
    accepted_request: saga_grind.ChildSubmission,
    stored_run: saga_grind.StoredRun,
  )
}

pub type SubmissionStore {
  SubmissionStore(records: List(SubmissionRecord))
}

pub fn probe() -> Nil {
  let current_contract = contract(input_codec())
  let owner_id = must_owner("inventory-child-owner")
  let run_id = identity.run_id("child-run-17")
  let assert Ok(compensation_retention) = jobs.available_at(1_950_000_000_000)
  let retention = saga_grind.RetainUntil(compensation_retention)
  let command = identity.command_id("admit-order-17")
  let input = ChildInput("order-17", 3)
  let assert Ok(prepared) =
    saga_grind.prepare_child(current_contract, input, retention, command)
  let request = saga_grind.prepared_submission(prepared)
  assert_request(request, "order-17", 3, retention)
  let assert Error(saga_grind.ChildInputCouldNotEncode(_)) =
    saga_grind.prepare_child(
      current_contract,
      ChildInput("encode-failure", 1),
      retention,
      identity.command_id("bad-order"),
    )
  let assert Error(saga_grind.StableCommandMustNotBeEmpty) =
    saga_grind.prepare_child(
      current_contract,
      input,
      retention,
      identity.command_id(""),
    )
  let assert Error(jobs.AvailableAtMustNotBeNegative) = jobs.available_at(-1)

  // The immutable ledger is threaded through calls. New, replay, and conflict
  // replies are derived from earlier accepted command data rather than echoes
  // selected independently for each callback.
  let accepted_run =
    stored_for(
      "inventory-child-owner",
      run_id,
      request,
      1,
      saga_grind.StoredChildCompleted(
        value.Text("receipt-order-17"),
        saga_grind.StoredCompensationClaimable(1_950_000_000_000),
      ),
    )
  let empty_store = SubmissionStore([])
  let #(after_create, create_reply) =
    decide_submission(empty_store, request, accepted_run)
  let assert Ok(saga_grind.ChildCreated(accepted_request, _)) = create_reply
  let assert True = accepted_request == request
  let create_owner =
    owner_for_submission(owner_id, run_id, accepted_run, request, create_reply)
  let assert Ok(saga_grind.NewlyAdmitted(created_child)) =
    saga_grind.submit_child(create_owner, prepared)
  let created_link = saga_grind.child_link(created_child)

  let #(after_replay, replay_reply) =
    decide_submission(after_create, request, accepted_run)
  let assert Ok(saga_grind.ChildAlreadyExists(replayed_request, _)) =
    replay_reply
  let assert True = replayed_request == request
  let replay_owner =
    owner_for_submission(owner_id, run_id, accepted_run, request, replay_reply)
  let assert Ok(saga_grind.AlreadyAdmitted(replayed_child)) =
    saga_grind.submit_child(replay_owner, prepared)
  let assert True = saga_grind.child_link(replayed_child) == created_link

  let changed_input = ChildInput("order-18", 3)
  let assert Ok(changed_input_prepared) =
    saga_grind.prepare_child(
      current_contract,
      changed_input,
      retention,
      command,
    )
  let changed_input_request =
    saga_grind.prepared_submission(changed_input_prepared)
  let #(unchanged_after_input_conflict, input_conflict) =
    decide_submission(after_replay, changed_input_request, accepted_run)
  let assert True = unchanged_after_input_conflict == after_replay
  let assert Error(saga_grind.SubmissionCommandConflict) = input_conflict
  let conflict_owner =
    owner_for_submission(
      owner_id,
      run_id,
      accepted_run,
      changed_input_request,
      input_conflict,
    )
  let assert Error(saga_grind.ChildSubmissionConflict) =
    saga_grind.submit_child(conflict_owner, changed_input_prepared)

  let retention_changed = changed_retention(request, saga_grind.Discard)
  let #(unchanged_after_retention_conflict, retention_conflict) =
    decide_submission(after_replay, retention_changed, accepted_run)
  let assert True = unchanged_after_retention_conflict == after_replay
  let assert Error(saga_grind.SubmissionCommandConflict) = retention_conflict

  let second_command = identity.command_id("admit-order-18")
  let assert Ok(second_prepared) =
    saga_grind.prepare_child(
      current_contract,
      ChildInput("order-18", 2),
      retention,
      second_command,
    )
  let second_request = saga_grind.prepared_submission(second_prepared)
  let second_run =
    stored_for(
      "inventory-child-owner",
      identity.run_id("child-run-18"),
      second_request,
      1,
      saga_grind.StoredChildQueued,
    )
  let #(after_second_command, second_reply) =
    decide_submission(after_replay, second_request, second_run)
  let assert Ok(saga_grind.ChildCreated(accepted_second_request, _)) =
    second_reply
  let assert True = accepted_second_request == second_request

  let third_command = identity.command_id("admit-order-19")
  let assert Ok(third_prepared) =
    saga_grind.prepare_child(
      current_contract,
      ChildInput("order-19", 1),
      retention,
      third_command,
    )
  let third_request = saga_grind.prepared_submission(third_prepared)
  let third_run =
    stored_for(
      "inventory-child-owner",
      identity.run_id("child-run-19"),
      third_request,
      1,
      saga_grind.StoredChildQueued,
    )
  let #(after_third_command, third_reply) =
    decide_submission(after_second_command, third_request, third_run)
  let assert Ok(saga_grind.ChildCreated(accepted_third_request, _)) =
    third_reply
  let assert True = accepted_third_request == third_request
  let #(after_multi_replay, multi_replay_reply) =
    decide_submission(after_third_command, request, accepted_run)
  let assert True = after_multi_replay == after_third_command
  let assert Ok(saga_grind.ChildAlreadyExists(multi_replay_request, multi_run)) =
    multi_replay_reply
  let assert True = multi_replay_request == request
  let assert True = multi_run == accepted_run
  let multi_replay_owner =
    owner_for_submission(
      owner_id,
      run_id,
      accepted_run,
      request,
      multi_replay_reply,
    )
  let assert Ok(saga_grind.AlreadyAdmitted(_)) =
    saga_grind.submit_child(multi_replay_owner, prepared)

  // The store records the request, then loses the acknowledgement. Its explicit
  // next-state receipt makes retry recover the same child under the same owner.
  let #(after_lost_ack, committed_before_lost_ack) =
    decide_submission(empty_store, request, accepted_run)
  let assert Ok(saga_grind.ChildCreated(lost_ack_request, _)) =
    committed_before_lost_ack
  let assert True = lost_ack_request == request
  let unknown_owner =
    owner_with_raw_callbacks(
      owner_id,
      run_id,
      accepted_run,
      fn(actual_owner, actual_request) {
        assert_owner_and_request(
          actual_owner,
          owner_id,
          actual_request,
          request,
        )
        Error(saga_grind.SubmissionCommitUnknown)
      },
      saga_grind.unsupported_cancellation,
    )
  let assert Error(saga_grind.ChildSubmissionCommitUnknown(uncertain)) =
    saga_grind.submit_child(unknown_owner, prepared)
  let wrong_route =
    owner_with_raw_callbacks(
      must_owner("other-inventory-owner"),
      run_id,
      accepted_run,
      fn(_, _) { panic as "a retry under another owner must be rejected first" },
      saga_grind.unsupported_cancellation,
    )
  let assert Error(saga_grind.ChildSubmissionRouteMismatch(routed_uncertain)) =
    saga_grind.retry_submission(wrong_route, uncertain)
  let unavailable_retry_owner =
    owner_for_submission(
      owner_id,
      run_id,
      accepted_run,
      request,
      Error(saga_grind.SubmissionUnavailable),
    )
  let assert Error(saga_grind.ChildSubmissionUnavailable) =
    saga_grind.retry_submission(unavailable_retry_owner, routed_uncertain)
  let #(after_unknown_replay, unknown_replay_reply) =
    decide_submission(after_lost_ack, request, accepted_run)
  let assert Ok(saga_grind.ChildAlreadyExists(unknown_replay_request, _)) =
    unknown_replay_reply
  let assert True = unknown_replay_request == request
  let retry_owner =
    owner_for_submission(
      owner_id,
      run_id,
      accepted_run,
      request,
      unknown_replay_reply,
    )
  let assert Ok(saga_grind.AlreadyAdmitted(recovered_child)) =
    saga_grind.retry_submission(retry_owner, routed_uncertain)
  let assert True = saga_grind.child_link(recovered_child) == created_link
  let assert True = after_unknown_replay == after_lost_ack

  // A success-shaped reply that echoes different admission data is ambiguous:
  // keep the same owner-bound token and recover through that command again.
  let #(after_receipt_commit, accepted_reply) =
    decide_submission(empty_store, request, accepted_run)
  let assert Ok(saga_grind.ChildCreated(accepted_request, _)) = accepted_reply
  let assert True = accepted_request == request
  let wrong_receipt = changed_retention(request, saga_grind.Discard)
  let bad_reply_owner =
    owner_for_submission(
      owner_id,
      run_id,
      accepted_run,
      request,
      Ok(saga_grind.ChildCreated(wrong_receipt, accepted_run)),
    )
  let assert Error(saga_grind.ChildSubmissionReplyInvalid(
    saga_grind.AcceptedRequestMismatch,
    bad_reply_token,
  )) = saga_grind.submit_child(bad_reply_owner, prepared)
  let #(after_bad_reply_retry, valid_reply) =
    decide_submission(after_receipt_commit, request, accepted_run)
  let assert Ok(saga_grind.ChildAlreadyExists(valid_request, _)) = valid_reply
  let assert True = valid_request == request
  let valid_retry_owner =
    owner_for_submission(owner_id, run_id, accepted_run, request, valid_reply)
  let assert Ok(saga_grind.AlreadyAdmitted(_)) =
    saga_grind.retry_submission(valid_retry_owner, bad_reply_token)
  let assert True = after_bad_reply_retry == after_receipt_commit

  let sentinel_contract =
    contract_with_output(input_codec(), sentinel_output_codec())
  let assert Ok(sentinel_prepared) =
    saga_grind.prepare_child(
      sentinel_contract,
      input,
      retention,
      identity.command_id("sentinel-output"),
    )
  let sentinel_request = saga_grind.prepared_submission(sentinel_prepared)
  let wrong_owner_run =
    stored_for(
      "unrelated-child-owner",
      identity.run_id("wrong-owner-run"),
      sentinel_request,
      2,
      saga_grind.StoredChildCompleted(
        value.Null,
        saga_grind.StoredCompensationDiscarded,
      ),
    )
  let wrong_owner_reply =
    owner_for_submission(
      owner_id,
      run_id,
      wrong_owner_run,
      sentinel_request,
      Ok(saga_grind.ChildCreated(sentinel_request, wrong_owner_run)),
    )
  let assert Error(saga_grind.ChildSubmissionReplyInvalid(
    saga_grind.AcceptedRunIncompatible(saga_grind.ChildOwnerMismatch),
    _,
  )) = saga_grind.submit_child(wrong_owner_reply, sentinel_prepared)
  let wrong_version_run =
    stored_with_output_version(
      "inventory-child-owner",
      identity.run_id("wrong-version-run"),
      sentinel_request,
      2,
      99,
    )
  let wrong_version_reply =
    owner_for_submission(
      owner_id,
      run_id,
      wrong_version_run,
      sentinel_request,
      Ok(saga_grind.ChildCreated(sentinel_request, wrong_version_run)),
    )
  let assert Error(saga_grind.ChildSubmissionReplyInvalid(
    saga_grind.AcceptedRunIncompatible(
      saga_grind.ChildOutputCodecVersionMismatch,
    ),
    _,
  )) = saga_grind.submit_child(wrong_version_reply, sentinel_prepared)

  let assert Ok(saga_grind.ChildCompleted(
    1,
    Receipt("receipt-order-17"),
    saga_grind.CompensationClaimable(1_950_000_000_000),
  )) = saga_grind.observe_child(create_owner, created_child)

  let active_state =
    stored_for(
      "inventory-child-owner",
      run_id,
      request,
      7,
      saga_grind.StoredChildRunning,
    )
  let active_command = identity.command_id("cancel-order-17")
  let expected_active_cancel =
    saga_grind.ChildCancellation(created_link, active_command)
  let active_owner =
    owner_for_cancellation(
      owner_id,
      run_id,
      active_state,
      expected_active_cancel,
      Ok(saga_grind.CancellationIntentRecorded(8)),
    )
  let assert Ok(saga_grind.ChildCancellationRecorded(8)) =
    saga_grind.request_child_cancellation(
      active_owner,
      created_child,
      active_command,
    )
  // Cancellation records intent; the stale read remains Running until the
  // child owner publishes a new committed state.
  let assert Ok(saga_grind.ChildRunning(7)) =
    saga_grind.observe_child(active_owner, created_child)

  let replay_cancel_owner =
    owner_for_cancellation(
      owner_id,
      run_id,
      active_state,
      expected_active_cancel,
      Ok(saga_grind.CancellationIntentAlreadyRecorded),
    )
  let assert Ok(saga_grind.ChildCancellationAlreadyRecorded) =
    saga_grind.request_child_cancellation(
      replay_cancel_owner,
      created_child,
      active_command,
    )
  let unknown_cancel_owner =
    owner_with_raw_callbacks(
      owner_id,
      run_id,
      active_state,
      saga_grind.unsupported_submission,
      fn(actual_owner, actual_command) {
        assert_owner_value(actual_owner, owner_id)
        let assert True = actual_command == expected_active_cancel
        Error(saga_grind.CancellationCommitUnknown)
      },
    )
  let assert Error(saga_grind.ChildCancellationCommitUnknown(
    unknown_child,
    unknown_command,
  )) =
    saga_grind.request_child_cancellation(
      unknown_cancel_owner,
      created_child,
      active_command,
    )
  let assert True = unknown_child == created_child
  let assert True =
    identity.command_id_value(unknown_command)
    == identity.command_id_value(active_command)
  let recovered_cancel_owner =
    owner_for_cancellation(
      owner_id,
      run_id,
      active_state,
      expected_active_cancel,
      Ok(saga_grind.CancellationIntentAlreadyRecorded),
    )
  let assert Ok(saga_grind.ChildCancellationAlreadyRecorded) =
    saga_grind.request_child_cancellation(
      recovered_cancel_owner,
      created_child,
      unknown_command,
    )

  let terminal_cancel_owner =
    owner_for_cancellation(
      owner_id,
      run_id,
      accepted_run,
      expected_active_cancel,
      Ok(saga_grind.CancellationAlreadyTerminal),
    )
  let assert Ok(saga_grind.ChildCancellationAlreadyTerminal) =
    saga_grind.request_child_cancellation(
      terminal_cancel_owner,
      created_child,
      active_command,
    )
  let assert Ok(saga_grind.ChildCompleted(
    1,
    Receipt("receipt-order-17"),
    saga_grind.CompensationClaimable(1_950_000_000_000),
  )) = saga_grind.observe_child(terminal_cancel_owner, created_child)

  let missing_cancel_owner =
    owner_for_cancellation(
      owner_id,
      run_id,
      active_state,
      expected_active_cancel,
      Ok(saga_grind.CancellationTargetMissing),
    )
  let assert Ok(saga_grind.ChildCancellationMissing) =
    saga_grind.request_child_cancellation(
      missing_cancel_owner,
      created_child,
      active_command,
    )
  let incompatible_cancel_owner =
    owner_for_cancellation(
      owner_id,
      run_id,
      active_state,
      expected_active_cancel,
      Error(saga_grind.CancellationIncompatible(
        saga_grind.ChildDefinitionVersionMismatch,
      )),
    )
  let assert Error(saga_grind.ChildCancellationIncompatible(
    saga_grind.ChildDefinitionVersionMismatch,
  )) =
    saga_grind.request_child_cancellation(
      incompatible_cancel_owner,
      created_child,
      active_command,
    )
  let unavailable_cancel_owner =
    owner_for_cancellation(
      owner_id,
      run_id,
      active_state,
      expected_active_cancel,
      Error(saga_grind.CancellationUnavailable),
    )
  let assert Error(saga_grind.ChildCancellationUnavailable) =
    saga_grind.request_child_cancellation(
      unavailable_cancel_owner,
      created_child,
      active_command,
    )
  let no_cancel_owner =
    owner_with_raw_callbacks(
      must_owner("unrelated-child-owner"),
      run_id,
      active_state,
      saga_grind.unsupported_submission,
      fn(_, _) { panic as "owner mismatch must reject before cancellation" },
    )
  let assert Error(saga_grind.ChildCancellationIncompatible(
    saga_grind.ChildOwnerMismatch,
  )) =
    saga_grind.request_child_cancellation(
      no_cancel_owner,
      created_child,
      active_command,
    )
  let assert Error(saga_grind.ChildCancellationCommandMustNotBeEmpty) =
    saga_grind.request_child_cancellation(
      active_owner,
      created_child,
      identity.command_id(""),
    )
  Nil
}

fn decide_submission(
  store: SubmissionStore,
  request: saga_grind.ChildSubmission,
  proposed_run: saga_grind.StoredRun,
) -> #(
  SubmissionStore,
  Result(saga_grind.ChildSubmissionReply, saga_grind.OwnerSubmissionError),
) {
  let SubmissionStore(records) = store
  let saga_grind.ChildSubmission(command_id, ..) = request
  decide_in_records(
    records,
    [],
    identity.command_id_value(command_id),
    request,
    proposed_run,
  )
}

fn decide_in_records(
  records: List(SubmissionRecord),
  earlier: List(SubmissionRecord),
  command: String,
  request: saga_grind.ChildSubmission,
  proposed_run: saga_grind.StoredRun,
) -> #(
  SubmissionStore,
  Result(saga_grind.ChildSubmissionReply, saga_grind.OwnerSubmissionError),
) {
  case records {
    [] -> #(
      SubmissionStore(append(
        [SubmissionRecord(command, request, proposed_run)],
        reverse(earlier),
      )),
      Ok(saga_grind.ChildCreated(request, proposed_run)),
    )
    [record, ..rest] -> {
      let SubmissionRecord(stored_command, accepted_request, stored_run) =
        record
      case stored_command == command {
        True ->
          case request == accepted_request {
            True -> #(
              SubmissionStore(append(reverse(earlier), [record, ..rest])),
              Ok(saga_grind.ChildAlreadyExists(accepted_request, stored_run)),
            )
            False -> #(
              SubmissionStore(append(reverse(earlier), [record, ..rest])),
              Error(saga_grind.SubmissionCommandConflict),
            )
          }
        False ->
          decide_in_records(
            rest,
            [record, ..earlier],
            command,
            request,
            proposed_run,
          )
      }
    }
  }
}

fn append(
  left: List(SubmissionRecord),
  right: List(SubmissionRecord),
) -> List(SubmissionRecord) {
  case left {
    [] -> right
    [first, ..rest] -> [first, ..append(rest, right)]
  }
}

fn reverse(records: List(SubmissionRecord)) -> List(SubmissionRecord) {
  reverse_with(records, [])
}

fn reverse_with(
  records: List(SubmissionRecord),
  reversed: List(SubmissionRecord),
) -> List(SubmissionRecord) {
  case records {
    [] -> reversed
    [first, ..rest] -> reverse_with(rest, [first, ..reversed])
  }
}

fn assert_request(
  request: saga_grind.ChildSubmission,
  expected_order: String,
  expected_quantity: Int,
  expected_retention: saga_grind.Retention,
) -> Nil {
  let saga_grind.ChildSubmission(
    command_id,
    definition_identity,
    definition_version,
    signature,
    input_version,
    output_version,
    error_version,
    undo_error_version,
    encoded_input,
    retention,
  ) = request
  let assert True = identity.command_id_value(command_id) == "admit-order-17"
  let assert True = definition_identity == "inventory-child"
  let assert True = definition_version == 4
  let assert True = signature == "inventory-structural-signature-v4"
  let assert True = input_version == 11
  let assert True = output_version == 12
  let assert True = error_version == 13
  let assert True = undo_error_version == 14
  let assert value.Array([value.Text(order_id), value.Int(quantity)]) =
    encoded_input
  let assert True = order_id == expected_order
  let assert True = quantity == expected_quantity
  let assert True = retention == expected_retention
  let assert saga_grind.RetainUntil(until) = retention
  let assert True = jobs.available_at_milliseconds(until) == 1_950_000_000_000
  Nil
}

fn changed_retention(
  request: saga_grind.ChildSubmission,
  retention: saga_grind.Retention,
) -> saga_grind.ChildSubmission {
  let saga_grind.ChildSubmission(
    command_id,
    definition_identity,
    definition_version,
    signature,
    input_version,
    output_version,
    error_version,
    undo_error_version,
    encoded_input,
    _,
  ) = request
  saga_grind.ChildSubmission(
    command_id,
    definition_identity,
    definition_version,
    signature,
    input_version,
    output_version,
    error_version,
    undo_error_version,
    encoded_input,
    retention,
  )
}

fn stored_for(
  owner_name: String,
  run_id: identity.RunId,
  request: saga_grind.ChildSubmission,
  revision: Int,
  state: saga_grind.StoredChildState,
) -> saga_grind.StoredRun {
  let saga_grind.ChildSubmission(
    _,
    definition_identity,
    definition_version,
    signature,
    input_version,
    output_version,
    error_version,
    undo_error_version,
    _,
    _,
  ) = request
  saga_grind.StoredRun(
    owner_name,
    run_id,
    definition_identity,
    definition_version,
    signature,
    input_version,
    output_version,
    error_version,
    undo_error_version,
    revision,
    state,
  )
}

fn stored_with_output_version(
  owner_name: String,
  run_id: identity.RunId,
  request: saga_grind.ChildSubmission,
  revision: Int,
  output_version: Int,
) -> saga_grind.StoredRun {
  let saga_grind.ChildSubmission(
    _,
    definition_identity,
    definition_version,
    signature,
    input_version,
    _,
    error_version,
    undo_error_version,
    _,
    _,
  ) = request
  saga_grind.StoredRun(
    owner_name,
    run_id,
    definition_identity,
    definition_version,
    signature,
    input_version,
    output_version,
    error_version,
    undo_error_version,
    revision,
    saga_grind.StoredChildCompleted(
      value.Null,
      saga_grind.StoredCompensationDiscarded,
    ),
  )
}

fn owner_for_submission(
  owner_id: saga_grind.OwnerId,
  run_id: identity.RunId,
  stored: saga_grind.StoredRun,
  expected_request: saga_grind.ChildSubmission,
  result: Result(
    saga_grind.ChildSubmissionReply,
    saga_grind.OwnerSubmissionError,
  ),
) -> saga_grind.DurableOwner {
  owner_with_raw_callbacks(
    owner_id,
    run_id,
    stored,
    fn(actual_owner, request) {
      assert_owner_and_request(
        actual_owner,
        owner_id,
        request,
        expected_request,
      )
      result
    },
    saga_grind.unsupported_cancellation,
  )
}

fn owner_for_cancellation(
  owner_id: saga_grind.OwnerId,
  run_id: identity.RunId,
  stored: saga_grind.StoredRun,
  expected_request: saga_grind.ChildCancellation,
  result: Result(
    saga_grind.ChildCancellationReply,
    saga_grind.OwnerCancellationPortError,
  ),
) -> saga_grind.DurableOwner {
  owner_with_raw_callbacks(
    owner_id,
    run_id,
    stored,
    saga_grind.unsupported_submission,
    fn(actual_owner, request) {
      assert_owner_value(actual_owner, owner_id)
      let assert True = request == expected_request
      result
    },
  )
}

fn owner_with_raw_callbacks(
  owner_id: saga_grind.OwnerId,
  run_id: identity.RunId,
  stored: saga_grind.StoredRun,
  submit: fn(saga_grind.OwnerId, saga_grind.ChildSubmission) ->
    Result(saga_grind.ChildSubmissionReply, saga_grind.OwnerSubmissionError),
  cancel: fn(saga_grind.OwnerId, saga_grind.ChildCancellation) ->
    Result(
      saga_grind.ChildCancellationReply,
      saga_grind.OwnerCancellationPortError,
    ),
) -> saga_grind.DurableOwner {
  let port =
    saga_grind.owner_port(
      fn(actual_owner, requested_run) {
        assert_owner_value(actual_owner, owner_id)
        case requested_run == run_id {
          True -> Ok(stored)
          False -> Error(saga_grind.StoredRunMissing)
        }
      },
      submit,
      cancel,
      saga_grind.unsupported_compensation_port(),
    )
  saga_grind.durable_owner(owner_id, port)
}

fn assert_owner_and_request(
  actual_owner: saga_grind.OwnerId,
  expected_owner: saga_grind.OwnerId,
  actual: saga_grind.ChildSubmission,
  expected: saga_grind.ChildSubmission,
) -> Nil {
  assert_owner_value(actual_owner, expected_owner)
  let assert True = actual == expected
  Nil
}

fn assert_owner_value(
  actual: saga_grind.OwnerId,
  expected: saga_grind.OwnerId,
) -> Nil {
  let assert True =
    saga_grind.owner_id_value(actual) == saga_grind.owner_id_value(expected)
  Nil
}

fn contract(
  input: blueprint.Codec(ChildInput),
) -> saga.ChildContract(ChildInput, Receipt, ChildFailure, UndoFailure) {
  contract_with_output(input, receipt_codec())
}

fn contract_with_output(
  input: blueprint.Codec(ChildInput),
  output: blueprint.Codec(Receipt),
) -> saga.ChildContract(ChildInput, Receipt, ChildFailure, UndoFailure) {
  let activity =
    saga.activity(
      must_step_id("reserve-order"),
      must_version(1),
      saga.ActivityContract(
        saga.VersionedCodec(must_version(1), input),
        saga.VersionedCodec(must_version(1), output),
        saga.VersionedCodec(must_version(1), failure_codec()),
        saga.VersionedCodec(must_version(1), undo_failure_codec()),
      ),
      fn(input) { Ok(Receipt(input.order_id)) },
      saga.Compensate(fn(_, _) { Ok(Nil) }),
    )
  let definition =
    saga.define(
      must_definition_id("inventory-child"),
      must_version(4),
      "inventory-structural-signature-v4",
      activity,
    )
  saga.child_contract(
    definition,
    saga.BoundaryVersions(
      must_version(11),
      must_version(12),
      must_version(13),
      must_version(14),
    ),
  )
}

fn input_codec() -> blueprint.Codec(ChildInput) {
  let pair_codec = blueprint.pair(blueprint.text(), blueprint.int())
  blueprint.new(
    fn(input: ChildInput) {
      case input.order_id == "encode-failure" {
        True -> Error(blueprint.CannotEncode("input fixture rejected"))
        False -> blueprint.encode(pair_codec, #(input.order_id, input.quantity))
      }
    },
    fn(raw) {
      case blueprint.decode(pair_codec, raw) {
        Error(error) -> Error(error)
        Ok(#(order_id, quantity)) -> Ok(ChildInput(order_id, quantity))
      }
    },
  )
}

fn receipt_codec() -> blueprint.Codec(Receipt) {
  blueprint.imap(blueprint.text(), Receipt, fn(receipt) {
    let Receipt(order_id) = receipt
    order_id
  })
}

fn sentinel_output_codec() -> blueprint.Codec(Receipt) {
  blueprint.new(
    fn(receipt) {
      let Receipt(order_id) = receipt
      Ok(value.Text(order_id))
    },
    fn(_) {
      panic as "metadata mismatch must be rejected before output decoding"
    },
  )
}

fn failure_codec() -> blueprint.Codec(ChildFailure) {
  blueprint.imap(blueprint.text(), ChildFailure, fn(failure) {
    let ChildFailure(reason) = failure
    reason
  })
}

fn undo_failure_codec() -> blueprint.Codec(UndoFailure) {
  blueprint.imap(blueprint.text(), UndoFailure, fn(failure) {
    let UndoFailure(reason) = failure
    reason
  })
}

fn must_owner(value: String) -> saga_grind.OwnerId {
  let assert Ok(owner) = saga_grind.owner_id(value)
  owner
}

fn must_definition_id(value: String) -> saga.DefinitionId {
  let assert Ok(id) = saga.definition_id(value)
  id
}

fn must_step_id(value: String) -> saga.StepId {
  let assert Ok(id) = saga.step_id(value)
  id
}

fn must_version(value: Int) -> saga.Version {
  let assert Ok(version) = saga.version(value)
  version
}
