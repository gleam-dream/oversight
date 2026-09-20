// THROWAWAY: Can unique admission preserve typed keys, queue scope, and replay?
import lab/blueprint
import lab/grind
import lab/value

pub type Input {
  Input(account_id: Int, order_id: Int, note: String)
}

type Store {
  Store(
    now: Int,
    rows: List(grind.UniqueRecord),
    commands: List(CommandReceipt),
  )
}

type CommandReceipt {
  CommandReceipt(grind.UniqueRequest, grind.UniquePortResponse)
}

pub fn probe() -> Nil {
  let route = route_fixture("orders")
  let other_route = route_fixture("priority")
  let worker = worker_fixture(3)
  let account_policy =
    make_account_policy(grind.WithinQueue, grind.WhileRetained)
  let account_row =
    record_fixture(
      "account-existing",
      route,
      3,
      Input(41, 10, "stored note"),
      grind.SelectedInputKey("account-id", 1),
      value.Int(41),
      grind.Immediate,
      grind.Available,
      100,
    )
  let store = Store(1000, [account_row], [])
  let account_queue = queue_fixture(route, store)

  let same_key_different_input =
    grind.submit_unique(
      account_queue,
      command("same-key-different-input"),
      worker,
      Input(41, 99, "different note"),
      grind.Immediate,
      account_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Existing(existing)) = same_key_different_input
  let assert "account-existing" =
    grind.job_id_value(grind.conflict_job_id(existing))
  let assert 3 = grind.conflict_worker_version(existing)
  let assert True =
    grind.same_queue_route(route, grind.conflict_route(existing))
  let wrong_worker_id = worker_fixture_with_id("other-worker", 3)
  let wrong_id_binding = grind.bind_conflict(wrong_worker_id, existing)
  let assert Error(grind.ConflictWorkerIdMismatch) = wrong_id_binding
  let wrong_version_binding = grind.bind_conflict(worker_fixture(4), existing)
  let assert Error(grind.ConflictWorkerVersionMismatch) = wrong_version_binding

  let selected_miss =
    grind.submit_unique(
      account_queue,
      command("different-account"),
      worker,
      Input(42, 10, "same other fields"),
      grind.Immediate,
      account_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(inserted)) = selected_miss
  let assert "job-different-account" =
    grind.job_id_value(grind.job_id_of(inserted))
  let assert True = grind.same_queue_route(route, grind.job_route_of(inserted))

  let order_identity = must_key_identity("order-id", 1)
  let order_policy =
    grind.selected_input(
      grind.WithinQueue,
      grind.WhileRetained,
      grind.AllRetained,
      order_identity,
      fn(input: Input) { input.order_id },
      blueprint.int(),
    )
  let same_encoded_value_different_policy =
    grind.submit_unique(
      account_queue,
      command("different-projection-contract"),
      worker,
      Input(55, 41, "same encoded projection value"),
      grind.Immediate,
      order_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = same_encoded_value_different_policy

  let newer_worker = worker_fixture(4)
  let version_is_part_of_identity =
    grind.submit_unique(
      account_queue,
      command("different-worker-version"),
      newer_worker,
      Input(41, 10, "same selected key"),
      grind.Immediate,
      account_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = version_is_part_of_identity

  let within_queue_policy = account_policy
  let across_queue_policy =
    make_account_policy(grind.AcrossQueues, grind.WhileRetained)
  let within_queue_result =
    grind.submit_unique(
      queue_fixture(other_route, store),
      command("scope-within-queue"),
      worker,
      Input(41, 10, "same account"),
      grind.Immediate,
      within_queue_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = within_queue_result
  let across_queue_result =
    grind.submit_unique(
      queue_fixture(other_route, store),
      command("scope-across-queues"),
      worker,
      Input(41, 10, "same account"),
      grind.Immediate,
      across_queue_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Existing(across_conflict)) = across_queue_result
  let assert True =
    grind.same_queue_route(route, grind.conflict_route(across_conflict))
  let other_owner_route =
    route_fixture_with_owner("secondary-storage", "orders")
  let across_other_owner =
    grind.submit_unique(
      queue_fixture(other_owner_route, store),
      command("across-queues-stays-within-owner"),
      worker,
      Input(41, 10, "same account"),
      grind.Immediate,
      across_queue_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = across_other_owner
  let assert Ok(across_handle) = grind.bind_conflict(worker, across_conflict)
  let assert True =
    grind.same_queue_route(route, grind.job_route_of(across_handle))
  let assert Error(grind.PollQueueRouteMismatch) =
    grind.poll(queue_fixture(other_route, store), across_handle)

  let full_input_policy =
    grind.full_input(grind.WithinQueue, grind.WhileRetained, grind.AllRetained)
  let reordered_object_row =
    grind.UniqueRecord(
      grind.job_id("legacy-full-input"),
      route,
      "invoice-worker",
      3,
      value.Object([
        #("note", value.Text("full equality")),
        #("order_id", value.Int(8)),
        #("account_id", value.Int(7)),
      ]),
      value.Null,
      grind.NoUniqueKeyMaterial,
      grind.Immediate,
      grind.Available,
      50,
    )
  let full_input_store = Store(1000, [reordered_object_row], [])
  let full_input_result =
    grind.submit_unique(
      queue_fixture(route, full_input_store),
      command("full-input-order-independent"),
      worker,
      Input(7, 8, "full equality"),
      grind.Immediate,
      full_input_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Existing(full_conflict)) = full_input_result
  let assert "legacy-full-input" =
    grind.job_id_value(grind.conflict_job_id(full_conflict))

  let assert True =
    profile_equal(
      value.Object([
        #(
          "nested",
          value.Array([value.Int(1), value.Object([#("x", value.Text("y"))])]),
        ),
        #("other", value.Bool(True)),
      ]),
      value.Object([
        #("other", value.Bool(True)),
        #(
          "nested",
          value.Array([value.Int(1), value.Object([#("x", value.Text("y"))])]),
        ),
      ]),
    )
  let assert False =
    profile_equal(
      value.Array([value.Int(1), value.Int(2)]),
      value.Array([value.Int(2), value.Int(1)]),
    )
  let assert False =
    profile_equal(
      value.Object([#("x", value.Int(1)), #("x", value.Int(1))]),
      value.Object([#("x", value.Int(1)), #("x", value.Int(1))]),
    )

  period_and_state_probes(route, worker, full_input_policy)
  reschedule_probes(route, worker, account_policy, account_row)
  missing_projection_probe(route, worker, account_policy, account_row)
  failure_and_recovery_probes(route, worker, account_policy)
  configuration_and_contention_probes(route, worker, account_policy)
  Nil
}

fn period_and_state_probes(
  route: grind.QueueRoute,
  worker: grind.Worker(Input, String, String),
  policy: grind.Uniqueness(Input),
) -> Nil {
  let input = Input(7, 8, "full equality")
  let boundary_policy =
    grind.full_input(
      grind.WithinQueue,
      grind.For(must_duration(100), grind.FromInsertion),
      grind.AllRetained,
    )
  let at_cutoff =
    legacy_record(route, input, 900, grind.Available, grind.Immediate)
  let boundary_result =
    grind.submit_unique(
      queue_fixture(route, Store(1000, [at_cutoff], [])),
      command("exact-cutoff"),
      worker,
      input,
      grind.Immediate,
      boundary_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Existing(_)) = boundary_result

  let one_before_cutoff =
    legacy_record(route, input, 899, grind.Available, grind.Immediate)
  let before_result =
    grind.submit_unique(
      queue_fixture(route, Store(1000, [one_before_cutoff], [])),
      command("before-cutoff"),
      worker,
      input,
      grind.Immediate,
      boundary_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = before_result

  let from_schedule =
    grind.full_input(
      grind.WithinQueue,
      grind.For(must_duration(100), grind.FromSchedule),
      grind.AllRetained,
    )
  let scheduled_at_960 =
    legacy_record(route, input, 500, grind.Scheduled, grind.At(must_time(960)))
  let schedule_cutoff =
    grind.submit_unique(
      queue_fixture(route, Store(1060, [scheduled_at_960], [])),
      command("future-schedule-cutoff"),
      worker,
      input,
      grind.Immediate,
      from_schedule,
      grind.KeepExisting,
    )
  let assert Ok(grind.Existing(_)) = schedule_cutoff
  let after_future_cutoff =
    grind.submit_unique(
      queue_fixture(route, Store(1061, [scheduled_at_960], [])),
      command("future-schedule-expired"),
      worker,
      input,
      grind.Immediate,
      from_schedule,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = after_future_cutoff

  let scheduled_only =
    grind.full_input(
      grind.WithinQueue,
      grind.WhileRetained,
      grind.ScheduledOnly,
    )
  let executing =
    legacy_record(route, input, 500, grind.Executing, grind.Immediate)
  let state_miss =
    grind.submit_unique(
      queue_fixture(route, Store(1000, [executing], [])),
      command("scheduled-only-excludes-executing"),
      worker,
      input,
      grind.Immediate,
      scheduled_only,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = state_miss
  let scheduled =
    legacy_record(route, input, 500, grind.Scheduled, grind.At(must_time(700)))
  let state_hit =
    grind.submit_unique(
      queue_fixture(route, Store(1000, [scheduled], [])),
      command("scheduled-only-includes-scheduled"),
      worker,
      input,
      grind.Immediate,
      scheduled_only,
      grind.KeepExisting,
    )
  let assert Ok(grind.Existing(_)) = state_hit

  let incomplete_only =
    grind.full_input(grind.WithinQueue, grind.WhileRetained, grind.Incomplete)
  let completed =
    legacy_record(route, input, 500, grind.Completed, grind.Immediate)
  let completed_miss =
    grind.submit_unique(
      queue_fixture(route, Store(1000, [completed], [])),
      command("incomplete-excludes-completed"),
      worker,
      input,
      grind.Immediate,
      incomplete_only,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = completed_miss

  let not_cancelled =
    grind.full_input(
      grind.WithinQueue,
      grind.WhileRetained,
      grind.NotCancelledOrDiscarded,
    )
  let cancelled =
    legacy_record(route, input, 500, grind.Cancelled, grind.Immediate)
  let cancelled_miss =
    grind.submit_unique(
      queue_fixture(route, Store(1000, [cancelled], [])),
      command("successful-profile-excludes-cancelled"),
      worker,
      input,
      grind.Immediate,
      not_cancelled,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = cancelled_miss
  let completed_hit =
    grind.submit_unique(
      queue_fixture(route, Store(1000, [completed], [])),
      command("successful-profile-includes-completed"),
      worker,
      input,
      grind.Immediate,
      not_cancelled,
      grind.KeepExisting,
    )
  let assert Ok(grind.Existing(_)) = completed_hit
  let _ = policy
  Nil
}

fn reschedule_probes(
  route: grind.QueueRoute,
  worker: grind.Worker(Input, String, String),
  policy: grind.Uniqueness(Input),
  original: grind.UniqueRecord,
) -> Nil {
  let scheduled =
    record_fixture(
      "scheduled-reschedule",
      route,
      3,
      Input(41, 1, "must remain stored"),
      grind.SelectedInputKey("account-id", 1),
      value.Int(41),
      grind.At(must_time(1500)),
      grind.Scheduled,
      200,
    )
  let store = Store(1000, [scheduled], [])
  let new_time = must_time(2500)
  let request =
    request_fixture(
      route,
      worker,
      command("reschedule-scheduled"),
      Input(41, 88, "new request body"),
      grind.At(new_time),
      policy,
      grind.RescheduleScheduled,
    )
  let #(updated_store, response) = decide(store, request)
  let assert grind.UniquePortResponse(
    _,
    1000,
    grind.PortRescheduled(before, after),
  ) = response
  let assert "scheduled-reschedule" = grind.job_id_value(before.id)
  let assert True = before.payload == after.payload
  let assert True = after.availability == grind.At(new_time)
  let assert grind.Scheduled = after.state
  let assert Store(_, [updated, ..], _) = updated_store
  let assert True = before.payload == updated.payload
  let assert True = updated.availability == grind.At(new_time)

  let result =
    grind.submit_unique(
      queue_fixture(route, store),
      command("reschedule-scheduled-end-to-end"),
      worker,
      Input(41, 88, "new request body"),
      grind.At(new_time),
      policy,
      grind.RescheduleScheduled,
    )
  let assert Ok(grind.Rescheduled(conflict)) = result
  let assert grind.Scheduled = grind.conflict_state(conflict)

  let executing =
    record_fixture(
      "executing-not-replaced",
      route,
      3,
      Input(41, 1, "active attempt payload"),
      grind.SelectedInputKey("account-id", 1),
      value.Int(41),
      grind.Immediate,
      grind.Executing,
      200,
    )
  let executing_result =
    grind.submit_unique(
      queue_fixture(route, Store(1000, [executing], [])),
      command("do-not-replace-executing"),
      worker,
      Input(41, 99, "proposed replacement"),
      grind.At(new_time),
      policy,
      grind.RescheduleScheduled,
    )
  let assert Ok(grind.Existing(active_conflict)) = executing_result
  let assert grind.Executing = grind.conflict_state(active_conflict)

  let bad_after =
    grind.UniqueRecord(
      scheduled.id,
      scheduled.route,
      scheduled.worker_id,
      scheduled.worker_version,
      encode_input(Input(41, 88, "incorrectly replaced payload")),
      scheduled.key,
      scheduled.key_policy,
      grind.At(new_time),
      grind.Scheduled,
      scheduled.inserted_at,
    )
  let malformed_queue =
    queue_with_port(route, fn(request) {
      grind.UniquePortResponse(
        request,
        1000,
        grind.PortRescheduled(scheduled, bad_after),
      )
    })
  let malformed =
    grind.submit_unique(
      malformed_queue,
      command("reject-payload-replacement"),
      worker,
      Input(41, 88, "new request body"),
      grind.At(new_time),
      policy,
      grind.RescheduleScheduled,
    )
  let assert Error(grind.UniqueBackendContractViolated(_)) = malformed
  let _ = original
  Nil
}

fn missing_projection_probe(
  route: grind.QueueRoute,
  worker: grind.Worker(Input, String, String),
  account_policy: grind.Uniqueness(Input),
  _account_row: grind.UniqueRecord,
) -> Nil {
  let ordinary =
    grind.UniqueRecord(
      grind.job_id("ordinary-job-without-projection"),
      route,
      "invoice-worker",
      3,
      encode_input(Input(41, 10, "legacy body")),
      value.Null,
      grind.NoUniqueKeyMaterial,
      grind.Immediate,
      grind.Available,
      50,
    )
  let result =
    grind.submit_unique(
      queue_fixture(route, Store(1000, [ordinary], [])),
      command("missing-material-selected-key"),
      worker,
      Input(41, 20, "new body"),
      grind.Immediate,
      account_policy,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = result
  Nil
}

fn failure_and_recovery_probes(
  route: grind.QueueRoute,
  worker: grind.Worker(Input, String, String),
  policy: grind.Uniqueness(Input),
) -> Nil {
  let stable_command = command("recover-after-expiry")
  let recovered_policy =
    grind.full_input(
      grind.WithinQueue,
      grind.For(must_duration(10), grind.FromSchedule),
      grind.AllRetained,
    )
  let old_schedule = must_time(1000)
  let retry_schedule = must_time(1020)
  let committed_row =
    legacy_record(
      route,
      Input(71, 1, "same exact request"),
      1000,
      grind.Scheduled,
      grind.At(old_schedule),
    )
  let request =
    request_fixture(
      route,
      worker,
      stable_command,
      Input(71, 1, "same exact request"),
      grind.At(retry_schedule),
      recovered_policy,
      grind.RescheduleScheduled,
    )
  let #(committed_store, original_receipt) =
    decide(Store(1000, [committed_row], []), request)
  let assert grind.UniquePortResponse(
    accepted_request,
    1000,
    grind.PortRescheduled(_, original_after),
  ) = original_receipt
  let assert True = accepted_request == request
  let assert True = original_after.availability == grind.At(retry_schedule)
  let Store(_, _, committed_commands) = committed_store
  // The later snapshot has lost the row and passed the period, but its command
  // ledger must replay the original committed reschedule exactly.
  let delayed_store = Store(100_000, [], committed_commands)
  let unknown_result =
    grind.submit_unique(
      queue_with_port(route, fn(port_request) {
        grind.UniquePortResponse(port_request, 1000, grind.PortCommitUnknown)
      }),
      stable_command,
      worker,
      Input(71, 1, "same exact request"),
      grind.At(retry_schedule),
      recovered_policy,
      grind.RescheduleScheduled,
    )
  let assert Error(grind.UniqueCommitUnknown(recovery)) = unknown_result
  let assert True = stable_command == grind.recovery_submission_id(recovery)
  let wrong_origin = route_fixture_with_owner("other-storage", "orders")
  let wrong_route_queue =
    queue_with_port(wrong_origin, fn(_request) {
      todo as "a cross-route recovery must be rejected before calling this port"
    })
  let assert Error(grind.RecoveryWrongRoute(_)) =
    grind.recover_unique(wrong_route_queue, recovery)
  let recovered =
    grind.recover_unique(queue_fixture(route, delayed_store), recovery)
  let assert Ok(grind.Rescheduled(recovered_conflict)) = recovered
  let assert grind.Scheduled = grind.conflict_state(recovered_conflict)
  let assert True =
    grind.same_queue_route(route, grind.conflict_route(recovered_conflict))

  let changed_request =
    grind.submit_unique(
      queue_fixture(route, delayed_store),
      stable_command,
      worker,
      Input(72, 1, "changed request under same command"),
      grind.At(retry_schedule),
      recovered_policy,
      grind.RescheduleScheduled,
    )
  let assert Error(grind.UniqueAdmissionFailed(grind.AdmissionRejected(_))) =
    changed_request
  let stale_reply =
    grind.submit_unique(
      queue_with_port(route, fn(_new_request) {
        grind.UniquePortResponse(
          request,
          1000,
          grind.PortRescheduled(committed_row, original_after),
        )
      }),
      stable_command,
      worker,
      Input(72, 1, "same command, different prepared request"),
      grind.At(retry_schedule),
      recovered_policy,
      grind.RescheduleScheduled,
    )
  let assert Error(grind.UniqueBackendContractViolated(_)) = stale_reply

  let bad_record =
    grind.UniqueRecord(
      grind.job_id("malformed-reply"),
      route,
      "wrong-worker",
      3,
      encode_input(Input(71, 1, "same exact request")),
      value.Object([]),
      grind.FullInputKey,
      grind.Immediate,
      grind.Available,
      1000,
    )
  let malformed =
    grind.submit_unique(
      queue_with_port(route, fn(port_request) {
        grind.UniquePortResponse(
          port_request,
          1000,
          grind.PortInserted(bad_record),
        )
      }),
      command("malformed-response-retains-recovery"),
      worker,
      Input(71, 1, "same exact request"),
      grind.Immediate,
      policy,
      grind.KeepExisting,
    )
  let assert Error(grind.UniqueBackendContractViolated(malformed_recovery)) =
    malformed
  let malformed_request = grind.recovery_request(malformed_recovery)
  let repaired_record =
    grind.UniqueRecord(
      grind.job_id("malformed-commit-reconciled"),
      route,
      "invoice-worker",
      3,
      grind.unique_request_payload(malformed_request),
      grind.unique_request_key(malformed_request),
      grind.unique_request_key_policy(malformed_request),
      grind.unique_request_availability(malformed_request),
      grind.Available,
      1000,
    )
  let repaired_response =
    grind.UniquePortResponse(
      malformed_request,
      1000,
      grind.PortInserted(repaired_record),
    )
  let repaired_store =
    Store(100_000, [], [CommandReceipt(malformed_request, repaired_response)])
  let repaired =
    grind.recover_unique(
      queue_fixture(route, repaired_store),
      malformed_recovery,
    )
  let assert Ok(grind.Inserted(repaired_handle)) = repaired
  let assert "malformed-commit-reconciled" =
    grind.job_id_value(grind.job_id_of(repaired_handle))

  let contended =
    grind.submit_unique(
      queue_with_port(route, fn(port_request) {
        grind.UniquePortResponse(port_request, 1000, grind.PortContended)
      }),
      command("lock-contention"),
      worker,
      Input(9, 1, "contended"),
      grind.Immediate,
      policy,
      grind.KeepExisting,
    )
  let assert Error(grind.UniqueAdmissionContended) = contended
  Nil
}

fn configuration_and_contention_probes(
  route: grind.QueueRoute,
  worker: grind.Worker(Input, String, String),
  policy: grind.Uniqueness(Input),
) -> Nil {
  let assert Error(grind.QueueOwnerMustNotBeEmpty) = grind.queue_owner("")
  let assert Error(grind.QueueNameMustNotBeEmpty) = grind.queue_name("")
  let assert Error(grind.UniquePeriodMustBePositive) =
    grind.positive_duration(0)
  let assert Error(grind.UniquePeriodMustBePositive) =
    grind.positive_duration(-1)
  let assert Error(grind.UniqueKeyPolicyIdMustNotBeEmpty) =
    grind.unique_key_identity("", 1)
  let assert Error(grind.UniqueKeyPolicyVersionMustBePositive) =
    grind.unique_key_identity("account-id", 0)
  let assert Error(grind.SubmissionIdMustNotBeEmpty) = grind.submission_id("")

  let fail_codec =
    blueprint.new(
      fn(_key: Int) { Error(blueprint.CannotEncode("key codec rejected")) },
      fn(raw) { blueprint.decode(blueprint.int(), raw) },
    )
  let bad_identity = must_key_identity("failing-key", 1)
  let fails_before_port =
    grind.selected_input(
      grind.WithinQueue,
      grind.WhileRetained,
      grind.AllRetained,
      bad_identity,
      fn(input: Input) { input.account_id },
      fail_codec,
    )
  let no_call =
    grind.submit_unique(
      queue_with_port(route, fn(_request) {
        todo as "key encoding failure must happen before the admission port"
      }),
      command("key-codec-failure"),
      worker,
      Input(1, 2, "never admitted"),
      grind.Immediate,
      fails_before_port,
      grind.KeepExisting,
    )
  let assert Error(grind.UniqueKeyCouldNotEncode(_)) = no_call

  let duplicate_input_codec =
    blueprint.new(
      fn(_input: Input) {
        Ok(
          value.Object([
            #("duplicate", value.Int(1)),
            #("duplicate", value.Int(1)),
          ]),
        )
      },
      fn(_raw) { Error(blueprint.CannotDecode("probe encoder only")) },
    )
  let duplicate_input_worker =
    worker_with_codec("invoice-worker", 3, duplicate_input_codec)
  let duplicate_payload =
    grind.submit_unique(
      queue_with_port(route, fn(_request) {
        todo as "duplicate input object names must be rejected before the port"
      }),
      command("duplicate-input-fields"),
      duplicate_input_worker,
      Input(1, 2, "duplicate"),
      grind.Immediate,
      grind.full_input(
        grind.WithinQueue,
        grind.WhileRetained,
        grind.AllRetained,
      ),
      grind.KeepExisting,
    )
  let assert Error(grind.UniqueInputContainsDuplicateObjectNames) =
    duplicate_payload

  let duplicate_key_codec =
    blueprint.new(
      fn(_key: Int) {
        Ok(
          value.Object([
            #("duplicate", value.Int(1)),
            #("duplicate", value.Int(1)),
          ]),
        )
      },
      fn(_raw) { Error(blueprint.CannotDecode("probe encoder only")) },
    )
  let duplicate_key_policy =
    grind.selected_input(
      grind.WithinQueue,
      grind.WhileRetained,
      grind.AllRetained,
      must_key_identity("duplicate-key", 1),
      fn(input: Input) { input.account_id },
      duplicate_key_codec,
    )
  let duplicate_key =
    grind.submit_unique(
      queue_with_port(route, fn(_request) {
        todo as "duplicate selected-key object names must be rejected before the port"
      }),
      command("duplicate-key-fields"),
      worker,
      Input(1, 2, "duplicate"),
      grind.Immediate,
      duplicate_key_policy,
      grind.KeepExisting,
    )
  let assert Error(grind.UniqueKeyContainsDuplicateObjectNames) = duplicate_key

  let full_policy =
    grind.full_input(grind.WithinQueue, grind.WhileRetained, grind.AllRetained)
  let full_input = Input(5, 6, "full key")
  let inconsistent_full_row =
    grind.UniqueRecord(
      grind.job_id("full-key-payload-mismatch"),
      route,
      "invoice-worker",
      3,
      encode_input(full_input),
      value.Text("different persisted key"),
      grind.FullInputKey,
      grind.Immediate,
      grind.Available,
      1,
    )
  let inconsistent_full_result =
    grind.submit_unique(
      queue_with_port(route, fn(request) {
        grind.UniquePortResponse(
          request,
          1,
          grind.PortExisting(inconsistent_full_row),
        )
      }),
      command("full-key-must-match-payload"),
      worker,
      full_input,
      grind.Immediate,
      full_policy,
      grind.KeepExisting,
    )
  let assert Error(grind.UniqueBackendContractViolated(_)) =
    inconsistent_full_result

  let no_schedule =
    grind.submit_unique(
      queue_with_port(route, fn(_request) {
        todo as "immediate reschedule must be rejected before the admission port"
      }),
      command("reschedule-needs-time"),
      worker,
      Input(1, 2, "no schedule"),
      grind.Immediate,
      policy,
      grind.RescheduleScheduled,
    )
  let assert Error(grind.RescheduleRequiresAvailabilityTime) = no_schedule
  Nil
}

fn queue_fixture(route: grind.QueueRoute, store: Store) -> grind.Queue {
  queue_with_port(route, fn(request) {
    let #(_, response) = decide(store, request)
    response
  })
}

fn queue_with_port(
  route: grind.QueueRoute,
  port: fn(grind.UniqueRequest) -> grind.UniquePortResponse,
) -> grind.Queue {
  grind.with_unique_admission_port(
    grind.queue(route, fn(_admission) { Error(grind.QueueStorageUnavailable) }),
    port,
  )
}

fn request_fixture(
  route: grind.QueueRoute,
  worker: grind.Worker(Input, String, String),
  command_id: grind.SubmissionId,
  input: Input,
  availability: grind.Availability,
  policy: grind.Uniqueness(Input),
  action: grind.ConflictAction,
) -> grind.UniqueRequest {
  let unknown_queue =
    queue_with_port(route, fn(request) {
      grind.UniquePortResponse(request, 0, grind.PortCommitUnknown)
    })
  let assert Error(grind.UniqueCommitUnknown(recovery)) =
    grind.submit_unique(
      unknown_queue,
      command_id,
      worker,
      input,
      availability,
      policy,
      action,
    )
  grind.recovery_request(recovery)
}

fn decide(
  store: Store,
  request: grind.UniqueRequest,
) -> #(Store, grind.UniquePortResponse) {
  let Store(now, rows, commands) = store
  let command_id = grind.unique_request_submission_id(request)
  case find_command(command_id, commands) {
    Ok(CommandReceipt(prior_request, response)) ->
      case same_exact_request(prior_request, request) {
        True -> #(store, response)
        False -> #(
          store,
          grind.UniquePortResponse(
            request,
            now,
            grind.PortRejected(
              grind.AdmissionRejected(value.Text("command id reused")),
            ),
          ),
        )
      }
    Error(Nil) ->
      case first_matching(request, rows, now) {
        Error(Nil) -> {
          let record = inserted_record(request, now)
          let response =
            grind.UniquePortResponse(request, now, grind.PortInserted(record))
          #(
            Store(now, [record, ..rows], [
              CommandReceipt(request, response),
              ..commands
            ]),
            response,
          )
        }
        Ok(existing) ->
          case
            grind.unique_request_conflict_action(request),
            existing.state,
            grind.unique_request_availability(request)
          {
            grind.RescheduleScheduled, grind.Scheduled, grind.At(_) -> {
              let after =
                grind.UniqueRecord(
                  ..existing,
                  availability: grind.unique_request_availability(request),
                )
              let response =
                grind.UniquePortResponse(
                  request,
                  now,
                  grind.PortRescheduled(existing, after),
                )
              #(
                Store(now, replace_record(existing.id, after, rows), [
                  CommandReceipt(request, response),
                  ..commands
                ]),
                response,
              )
            }
            _, _, _ -> {
              let response =
                grind.UniquePortResponse(
                  request,
                  now,
                  grind.PortExisting(existing),
                )
              #(
                Store(now, rows, [CommandReceipt(request, response), ..commands]),
                response,
              )
            }
          }
      }
  }
}

fn inserted_record(
  request: grind.UniqueRequest,
  now: Int,
) -> grind.UniqueRecord {
  let state = case grind.unique_request_availability(request) {
    grind.Immediate -> grind.Available
    grind.At(_) -> grind.Scheduled
  }
  grind.UniqueRecord(
    grind.job_id(
      "job-"
      <> grind.submission_id_value(grind.unique_request_submission_id(request)),
    ),
    grind.unique_request_route(request),
    grind.unique_request_worker_id(request),
    grind.unique_request_worker_version(request),
    grind.unique_request_payload(request),
    grind.unique_request_key(request),
    grind.unique_request_key_policy(request),
    grind.unique_request_availability(request),
    state,
    now,
  )
}

fn first_matching(
  request: grind.UniqueRequest,
  rows: List(grind.UniqueRecord),
  now: Int,
) -> Result(grind.UniqueRecord, Nil) {
  case rows {
    [] -> Error(Nil)
    [record, ..rest] ->
      case matches(request, record, now) {
        True -> Ok(record)
        False -> first_matching(request, rest, now)
      }
  }
}

fn matches(
  request: grind.UniqueRequest,
  record: grind.UniqueRecord,
  now: Int,
) -> Bool {
  let request_route = grind.unique_request_route(request)
  let same_owner =
    grind.queue_owner_value(request_route)
    == grind.queue_owner_value(record.route)
  let same_scope = case grind.unique_request_scope(request) {
    grind.WithinQueue -> grind.same_queue_route(request_route, record.route)
    grind.AcrossQueues -> same_owner
  }
  same_owner
  && same_scope
  && record.worker_id == grind.unique_request_worker_id(request)
  && record.worker_version == grind.unique_request_worker_version(request)
  && same_key_contract(request, record)
  && state_selected(grind.unique_request_states(request), record.state)
  && within_period(grind.unique_request_period(request), record, now)
}

fn same_key_contract(
  request: grind.UniqueRequest,
  record: grind.UniqueRecord,
) -> Bool {
  case grind.unique_request_key_policy(request), record.key_policy {
    grind.FullInputKey, grind.FullInputKey ->
      profile_equal(record.payload, record.key)
      && profile_equal(record.payload, grind.unique_request_key(request))
    grind.FullInputKey, grind.NoUniqueKeyMaterial ->
      profile_equal(record.payload, grind.unique_request_key(request))
    grind.SelectedInputKey(request_name, request_version),
      grind.SelectedInputKey(record_name, record_version)
    ->
      request_name == record_name
      && request_version == record_version
      && profile_equal(record.key, grind.unique_request_key(request))
    _, _ -> False
  }
}

fn state_selected(
  states: grind.UniqueStates,
  state: grind.UniqueJobState,
) -> Bool {
  case states, state {
    grind.AllRetained, _ -> True
    grind.Incomplete, grind.Suspended -> True
    grind.Incomplete, grind.Available -> True
    grind.Incomplete, grind.Scheduled -> True
    grind.Incomplete, grind.Executing -> True
    grind.Incomplete, grind.Retryable -> True
    grind.NotCancelledOrDiscarded, grind.Cancelled -> False
    grind.NotCancelledOrDiscarded, grind.Discarded -> False
    grind.NotCancelledOrDiscarded, _ -> True
    grind.ScheduledOnly, grind.Scheduled -> True
    _, _ -> False
  }
}

fn within_period(
  period: grind.UniquePeriod,
  record: grind.UniqueRecord,
  now: Int,
) -> Bool {
  case period {
    grind.WhileRetained -> True
    grind.For(duration, origin) -> {
      let timestamp = case origin {
        grind.FromInsertion -> record.inserted_at
        grind.FromSchedule ->
          case record.availability {
            grind.Immediate -> record.inserted_at
            grind.At(time) -> grind.available_at_milliseconds(time)
          }
      }
      timestamp >= now - grind.positive_duration_milliseconds(duration)
    }
  }
}

fn find_command(
  id: grind.SubmissionId,
  commands: List(CommandReceipt),
) -> Result(CommandReceipt, Nil) {
  case commands {
    [] -> Error(Nil)
    [CommandReceipt(request, _) as receipt, ..rest] ->
      case grind.unique_request_submission_id(request) == id {
        True -> Ok(receipt)
        False -> find_command(id, rest)
      }
  }
}

fn same_exact_request(
  left: grind.UniqueRequest,
  right: grind.UniqueRequest,
) -> Bool {
  grind.unique_request_submission_id(left)
  == grind.unique_request_submission_id(right)
  && grind.same_queue_route(
    grind.unique_request_route(left),
    grind.unique_request_route(right),
  )
  && grind.unique_request_worker_id(left)
  == grind.unique_request_worker_id(right)
  && grind.unique_request_worker_version(left)
  == grind.unique_request_worker_version(right)
  && grind.unique_request_payload(left) == grind.unique_request_payload(right)
  && grind.unique_request_key(left) == grind.unique_request_key(right)
  && grind.unique_request_key_policy(left)
  == grind.unique_request_key_policy(right)
  && grind.unique_request_scope(left) == grind.unique_request_scope(right)
  && grind.unique_request_period(left) == grind.unique_request_period(right)
  && grind.unique_request_states(left) == grind.unique_request_states(right)
  && grind.unique_request_availability(left)
  == grind.unique_request_availability(right)
  && grind.unique_request_conflict_action(left)
  == grind.unique_request_conflict_action(right)
}

fn replace_record(
  id: grind.JobId,
  replacement: grind.UniqueRecord,
  rows: List(grind.UniqueRecord),
) -> List(grind.UniqueRecord) {
  case rows {
    [] -> []
    [record, ..rest] ->
      case grind.job_id_value(record.id) == grind.job_id_value(id) {
        True -> [replacement, ..rest]
        False -> [record, ..replace_record(id, replacement, rest)]
      }
  }
}

fn profile_equal(left: value.Value, right: value.Value) -> Bool {
  valid_profile_value(left)
  && valid_profile_value(right)
  && equal_valid_value(left, right)
}

fn valid_profile_value(item: value.Value) -> Bool {
  case item {
    value.Null -> True
    value.Bool(_) -> True
    value.Int(_) -> True
    value.Text(_) -> True
    value.Array(items) -> valid_values(items)
    value.Object(fields) -> valid_fields(fields)
  }
}

fn valid_values(items: List(value.Value)) -> Bool {
  case items {
    [] -> True
    [item, ..rest] -> valid_profile_value(item) && valid_values(rest)
  }
}

fn valid_fields(fields: List(#(String, value.Value))) -> Bool {
  case fields {
    [] -> True
    [#(key, item), ..rest] ->
      !contains_key(key, rest)
      && valid_profile_value(item)
      && valid_fields(rest)
  }
}

fn contains_key(key: String, fields: List(#(String, value.Value))) -> Bool {
  case fields {
    [] -> False
    [#(field, _), ..rest] -> field == key || contains_key(key, rest)
  }
}

fn equal_valid_value(left: value.Value, right: value.Value) -> Bool {
  case left, right {
    value.Null, value.Null -> True
    value.Bool(a), value.Bool(b) -> a == b
    value.Int(a), value.Int(b) -> a == b
    value.Text(a), value.Text(b) -> a == b
    value.Array(a), value.Array(b) -> equal_lists(a, b)
    value.Object(a), value.Object(b) -> equal_fields(a, b)
    _, _ -> False
  }
}

fn equal_lists(left: List(value.Value), right: List(value.Value)) -> Bool {
  case left, right {
    [], [] -> True
    [a, ..left_rest], [b, ..right_rest] ->
      equal_valid_value(a, b) && equal_lists(left_rest, right_rest)
    _, _ -> False
  }
}

fn equal_fields(
  left: List(#(String, value.Value)),
  right: List(#(String, value.Value)),
) -> Bool {
  case left, right {
    [], [] -> True
    [#(key, item), ..rest], right ->
      case get_field(key, right) {
        Error(Nil) -> False
        Ok(other) ->
          equal_valid_value(item, other)
          && equal_fields(rest, remove_field(key, right))
      }
    _, _ -> False
  }
}

fn get_field(
  key: String,
  fields: List(#(String, value.Value)),
) -> Result(value.Value, Nil) {
  case fields {
    [] -> Error(Nil)
    [#(field, item), ..rest] ->
      case field == key {
        True -> Ok(item)
        False -> get_field(key, rest)
      }
  }
}

fn remove_field(
  key: String,
  fields: List(#(String, value.Value)),
) -> List(#(String, value.Value)) {
  case fields {
    [] -> []
    [#(field, item), ..rest] ->
      case field == key {
        True -> rest
        False -> [#(field, item), ..remove_field(key, rest)]
      }
  }
}

fn record_fixture(
  id: String,
  route: grind.QueueRoute,
  version: Int,
  input: Input,
  key_policy: grind.UniqueKeyPolicy,
  key: value.Value,
  availability: grind.Availability,
  state: grind.UniqueJobState,
  inserted_at: Int,
) -> grind.UniqueRecord {
  grind.UniqueRecord(
    grind.job_id(id),
    route,
    "invoice-worker",
    version,
    encode_input(input),
    key,
    key_policy,
    availability,
    state,
    inserted_at,
  )
}

fn legacy_record(
  route: grind.QueueRoute,
  input: Input,
  inserted_at: Int,
  state: grind.UniqueJobState,
  availability: grind.Availability,
) -> grind.UniqueRecord {
  grind.UniqueRecord(
    grind.job_id("legacy-row"),
    route,
    "invoice-worker",
    3,
    encode_input(input),
    value.Null,
    grind.NoUniqueKeyMaterial,
    availability,
    state,
    inserted_at,
  )
}

fn make_account_policy(
  scope: grind.QueueScope,
  period: grind.UniquePeriod,
) -> grind.Uniqueness(Input) {
  grind.selected_input(
    scope,
    period,
    grind.AllRetained,
    must_key_identity("account-id", 1),
    fn(input: Input) { input.account_id },
    blueprint.int(),
  )
}

fn worker_fixture(version_number: Int) -> grind.Worker(Input, String, String) {
  worker_fixture_with_id("invoice-worker", version_number)
}

fn worker_fixture_with_id(
  worker_name: String,
  version_number: Int,
) -> grind.Worker(Input, String, String) {
  worker_with_codec(worker_name, version_number, input_codec())
}

fn worker_with_codec(
  worker_name: String,
  version_number: Int,
  codec: blueprint.Codec(Input),
) -> grind.Worker(Input, String, String) {
  let assert Ok(id) = grind.worker_id(worker_name)
  let assert Ok(version) = grind.worker_version(version_number)
  grind.worker(
    id,
    version,
    codec,
    blueprint.text(),
    blueprint.text(),
    fn(_input) { todo as "submission must not execute the worker" },
  )
}

fn input_codec() -> blueprint.Codec(Input) {
  blueprint.new(
    fn(input: Input) {
      Ok(
        value.Object([
          #("account_id", value.Int(input.account_id)),
          #("order_id", value.Int(input.order_id)),
          #("note", value.Text(input.note)),
        ]),
      )
    },
    fn(raw) {
      case raw {
        value.Object(fields) ->
          case
            get_integer("account_id", fields),
            get_integer("order_id", fields),
            get_text("note", fields)
          {
            Ok(account_id), Ok(order_id), Ok(note) ->
              Ok(Input(account_id, order_id, note))
            _, _, _ -> Error(blueprint.CannotDecode("invalid input fields"))
          }
        _ -> Error(blueprint.CannotDecode("expected input object"))
      }
    },
  )
}

fn encode_input(input: Input) -> value.Value {
  let assert Ok(encoded) = blueprint.encode(input_codec(), input)
  encoded
}

fn get_integer(
  key: String,
  fields: List(#(String, value.Value)),
) -> Result(Int, Nil) {
  case get_field(key, fields) {
    Ok(value.Int(number)) -> Ok(number)
    _ -> Error(Nil)
  }
}

fn get_text(
  key: String,
  fields: List(#(String, value.Value)),
) -> Result(String, Nil) {
  case get_field(key, fields) {
    Ok(value.Text(text)) -> Ok(text)
    _ -> Error(Nil)
  }
}

fn route_fixture(queue: String) -> grind.QueueRoute {
  route_fixture_with_owner("primary-storage", queue)
}

fn route_fixture_with_owner(
  owner_name: String,
  queue: String,
) -> grind.QueueRoute {
  let assert Ok(owner) = grind.queue_owner(owner_name)
  let assert Ok(name) = grind.queue_name(queue)
  grind.queue_route(owner, name)
}

fn command(text: String) -> grind.SubmissionId {
  let assert Ok(id) = grind.submission_id(text)
  id
}

fn must_key_identity(name: String, version: Int) -> grind.UniqueKeyIdentity {
  let assert Ok(identity) = grind.unique_key_identity(name, version)
  identity
}

fn must_duration(milliseconds: Int) -> grind.PositiveDuration {
  let assert Ok(duration) = grind.positive_duration(milliseconds)
  duration
}

fn must_time(milliseconds: Int) -> grind.AvailableAt {
  let assert Ok(time) = grind.available_at(milliseconds)
  time
}
