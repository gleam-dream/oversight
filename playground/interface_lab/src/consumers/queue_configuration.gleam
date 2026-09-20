// THROWAWAY: Can queue maintenance change dispatch without owning admission?
import lab/blueprint
import lab/grind
import lab/grind_claim as claim
import lab/grind_execution as execution
import lab/grind_queue as queue_config

pub fn probe() -> Nil {
  let primary_route = route_fixture("billing", "mail")
  let second_owner_route = route_fixture("analytics", "mail")
  let primary =
    queue_config.QueueConfig(
      route: primary_route,
      concurrency: must_concurrency(2),
      mode: queue_config.Processing,
    )
  let second_owner =
    queue_config.QueueConfig(
      route: second_owner_route,
      concurrency: must_concurrency(1),
      mode: queue_config.Processing,
    )
  let zero_active = must_active(0)
  let one_active = must_active(1)
  let two_active = must_active(2)
  let three_active = must_active(3)

  let duplicate =
    queue_config.QueueConfig(..primary, concurrency: must_concurrency(1))
  let assert Error(queue_config.DuplicateQueueRoute(duplicate_route)) =
    queue_config.queue_configs([primary, duplicate])
  let assert True = grind.same_queue_route(primary_route, duplicate_route)

  let assert Ok(configs) = queue_config.queue_configs([primary, second_owner])
  let assert queue_config.ConfigFound(found_primary) =
    queue_config.config_for_route(configs, primary_route)
  let assert True = grind.same_queue_route(primary_route, found_primary.route)
  // The queue name is shared, but a different storage owner is a distinct route.
  let assert queue_config.ConfigFound(found_second_owner) =
    queue_config.config_for_route(configs, second_owner_route)
  let assert queue_config.MayClaim(up_to: 1) =
    queue_config.plan_dispatch(found_second_owner, zero_active)
  let assert queue_config.AtCapacity =
    queue_config.plan_dispatch(found_second_owner, one_active)
  let assert Ok(empty_configs) = queue_config.queue_configs([])
  let assert queue_config.ConfigMissing =
    queue_config.config_for_route(empty_configs, primary_route)
  let assert queue_config.ConfigMissing =
    queue_config.config_for_route(configs, route_fixture("other", "mail"))

  let assert Error(queue_config.LocalConcurrencyMustBePositive) =
    queue_config.local_concurrency(0)
  let assert Error(queue_config.LocalConcurrencyMustBePositive) =
    queue_config.local_concurrency(-1)
  let assert Error(queue_config.ActiveCountMustNotBeNegative) =
    queue_config.active_count(-1)

  let assert queue_config.MayClaim(up_to: 2) =
    queue_config.plan_dispatch(primary, zero_active)
  let assert queue_config.AtCapacity =
    queue_config.plan_dispatch(primary, two_active)
  // Overcapacity is clamped to no additional claim proposal.
  let assert queue_config.AtCapacity =
    queue_config.plan_dispatch(primary, three_active)

  // The other owner with the same queue name still has its local capacity.
  let assert queue_config.MayClaim(up_to: 1) =
    queue_config.plan_dispatch(second_owner, zero_active)

  // Start one typed unique job before maintenance begins.
  let worker = worker_fixture()
  let uniqueness =
    grind.full_input(grind.WithinQueue, grind.WhileRetained, grind.AllRetained)
  let inserted =
    grind.submit_unique(
      queue_fixture(primary_route, "running-before-pause"),
      must_submission_id("running-before-pause"),
      worker,
      41,
      grind.Immediate,
      uniqueness,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(handle)) = inserted
  let assert True =
    grind.same_queue_route(primary_route, grind.job_route_of(handle))
  let snapshot = make_claim(grind.job_id_of(handle))
  let running = claim.running_attempt(snapshot)
  let paused = queue_config.QueueConfig(..primary, mode: queue_config.Paused)
  let assert queue_config.DispatchPaused =
    queue_config.plan_dispatch(paused, one_active)

  // Pausing does not block a new unique admission or cancel the active attempt.
  let admitted_while_paused =
    grind.submit_unique(
      queue_fixture(primary_route, "mail-admitted-during-pause"),
      must_submission_id("mail-while-paused"),
      worker,
      42,
      grind.Immediate,
      uniqueness,
      grind.KeepExisting,
    )
  let assert Ok(grind.Inserted(_)) = admitted_while_paused

  // Scaling down while paused takes effect after resume. The old running attempt
  // still occupies the only configured slot until its acknowledgement commits.
  let scaled_down =
    queue_config.QueueConfig(..paused, concurrency: must_concurrency(1))
  let assert queue_config.DispatchPaused =
    queue_config.plan_dispatch(scaled_down, one_active)
  let resumed =
    queue_config.QueueConfig(..scaled_down, mode: queue_config.Processing)
  let assert queue_config.AtCapacity =
    queue_config.plan_dispatch(resumed, one_active)
  // A stale active count above the new limit also proposes no new claim.
  let assert queue_config.AtCapacity =
    queue_config.plan_dispatch(resumed, two_active)
  let assert claim.AttemptAcknowledged(_, _, execution.Succeeded("delivered")) =
    acknowledge_success(running, snapshot)
  // Completion lowers the observed active count and restores one advisory slot.
  let assert queue_config.MayClaim(up_to: 1) =
    queue_config.plan_dispatch(resumed, zero_active)

  Nil
}

fn route_fixture(owner: String, name: String) -> grind.QueueRoute {
  let assert Ok(owner) = grind.queue_owner(owner)
  let assert Ok(name) = grind.queue_name(name)
  grind.queue_route(owner, name)
}

fn must_concurrency(value: Int) -> queue_config.LocalConcurrency {
  let assert Ok(concurrency) = queue_config.local_concurrency(value)
  concurrency
}

fn must_active(value: Int) -> queue_config.ActiveCount {
  let assert Ok(active) = queue_config.active_count(value)
  active
}

fn must_submission_id(value: String) -> grind.SubmissionId {
  let assert Ok(id) = grind.submission_id(value)
  id
}

fn worker_fixture() -> grind.Worker(Int, String, String) {
  let assert Ok(id) = grind.worker_id("mail-worker")
  let assert Ok(version) = grind.worker_version(1)
  grind.worker(
    id,
    version,
    blueprint.int(),
    blueprint.text(),
    blueprint.text(),
    fn(_input) { Ok("delivered") },
  )
}

fn queue_fixture(route: grind.QueueRoute, id: String) -> grind.Queue {
  grind.with_unique_admission_port(
    grind.queue(route, fn(_admission) { Error(grind.QueueStorageUnavailable) }),
    fn(request) {
      let record =
        grind.UniqueRecord(
          grind.job_id(id),
          grind.unique_request_route(request),
          grind.unique_request_worker_id(request),
          grind.unique_request_worker_version(request),
          grind.unique_request_payload(request),
          grind.unique_request_key(request),
          grind.unique_request_key_policy(request),
          grind.unique_request_availability(request),
          grind.Available,
          1000,
        )
      grind.UniquePortResponse(request, 1000, grind.PortInserted(record))
    },
  )
}

fn make_claim(job_id: grind.JobId) -> claim.ClaimSnapshot {
  let assert Ok(attempt) = claim.attempt_id(1)
  let assert Ok(epoch) = claim.ownership_epoch(1)
  let assert Ok(revision) = claim.record_revision(1)
  let assert Ok(snapshot) =
    claim.claim_snapshot(job_id, attempt, epoch, 1, must_time(5000), revision)
  snapshot
}

fn acknowledge_success(
  running: claim.CurrentAttempt(String, String, String),
  snapshot: claim.ClaimSnapshot,
) -> claim.Acknowledgement(String, String, String) {
  let proposal = execution.Succeeded("delivered")
  let assert Ok(command_id) = claim.command_id("maintenance-ack")
  let command = claim.ack_command(command_id, snapshot, proposal)
  let now = must_time(1000)
  let store =
    claim.store_port(fn(acknowledgement) {
      let observed_claim = claim.ack_command_claim(acknowledgement)
      let observed_proposal = claim.ack_command_proposal(acknowledgement)
      let #(next, decision) =
        claim.decide_acknowledgement(
          running,
          observed_claim,
          now,
          observed_proposal,
        )
      claim.TransactionResolved(next, decision)
    })
  claim.acknowledge(store, command)
}

fn must_time(milliseconds: Int) -> grind.AvailableAt {
  let assert Ok(time) = grind.available_at(milliseconds)
  time
}
