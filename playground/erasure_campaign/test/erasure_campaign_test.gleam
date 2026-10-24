import campaign
import domain.{
  Archive, Command, DropReply, OperationId, Profile, Reject, SubjectId,
}
import envoy
import evidence
import exception
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/time/duration
import gleeunit
import grind
import grind/admin
import grind/job
import grind/queue
import http_gun
import http_gun/config
import http_gun/error
import pog
import saga/execution

pub fn main() {
  gleeunit.main()
}

fn with_runtime(
  services: campaign.Services,
  gate: campaign.Gate,
  concurrency: Int,
  run,
) {
  let assert Ok(url) = envoy.get("DATABASE_URL")
  let assert Ok(pool) = pog.url_config(process.new_name("erasure_pool"), url)
  let worker = campaign.deletion_worker(services, gate)
  let config =
    grind.new(pool |> pog.pool_size(4))
    |> grind.with_worker(worker)
    |> grind.with_queue(
      queue.new("erasure")
      |> queue.with_concurrency(concurrency)
      |> queue.with_poll_interval(duration.milliseconds(10)),
    )
    |> grind.with_startup_migration
    |> grind.without_pruner
  let assert Ok(jobs) = grind.start(config, process.new_name("erasure_jobs"))
  use <- exception.defer(fn() {
    let assert Ok(_) = grind.stop(jobs)
  })
  run(jobs, worker)
}

fn command(operation, target) {
  Command(SubjectId("synthetic"), OperationId(operation), target)
}

fn count(services, command) {
  let assert Ok(buffered) =
    campaign.request(services, http.Get, "/count/" <> domain.identity(command))
  let assert Ok(text) = bit_array.to_string(buffered.response.body)
  text
}

fn preparation_failure(db) {
  let assert Ok(execution.Failed(
    execution.StepFailed(_, domain.PlanRejected),
    settlement,
  )) = campaign.prepare(db, "bad-plan", True)
  assert settlement.unknown_effects == []
  let assert Ok(rows) =
    pog.query(
      "SELECT frozen,staged,undos FROM erasure_preparation WHERE operation='bad-plan'",
    )
    |> pog.returning({
      use frozen <- decode.field(0, decode.bool)
      use staged <- decode.field(1, decode.bool)
      use undos <- decode.field(2, decode.int)
      decode.success(#(frozen, staged, undos))
    })
    |> pog.execute(db)
  assert rows.rows == [#(False, False, 1)]
  io.println(
    "PASS preparation failure: freeze undone once, plan never staged, no deletion admitted",
  )
}

fn uncertain(services, jobs, worker) {
  let db = grind.connection(jobs)
  let lost = command("reply-loss", DropReply)
  let handle = campaign.submit(jobs, worker, lost)
  let assert Ok(grind.Uncertain(_)) =
    grind.await(jobs, handle, within: duration.seconds(5))
  assert evidence.read(db, lost) == evidence.Pending
  let failure = evidence.failure(db, lost)
  assert error.evidence(failure) == error.MaybeSent
  assert error.kind(failure) == error.Network
  assert error.status(failure) == option.None
  io.println("HTTP receipt: " <> error.describe(failure))
  assert count(services, lost) == "1"
  // A genuinely new job has no old queue receipt to rely on.
  let duplicate = campaign.submit(jobs, worker, lost)
  let assert Ok(grind.Uncertain(_)) =
    grind.await(jobs, duplicate, within: duration.seconds(5))
  assert count(services, lost) == "1"
  let assert Ok(receipt) = campaign.lookup(services, lost)
  evidence.confirm(db, lost, receipt)
  list.each([handle, duplicate], fn(handle) {
    let resolution =
      admin.resolution(
        admin.ConfirmSuccess(receipt),
        id: "lookup-confirmed-" <> int.to_string(job.id(handle)),
        by: "synthetic-reconciler",
        details: "Authoritative fixture lookup matched the exact subject/operation/target",
      )
    let assert Ok(admin.Applied(job.Succeeded)) =
      admin.resolve_uncertain(jobs, handle, resolution)
    let assert Ok(admin.AlreadyApplied(job.Succeeded)) =
      admin.resolve_uncertain(jobs, handle, resolution)
  })
  let remaining = command("reply-loss", Archive)
  assert evidence.read(db, remaining) == evidence.Unseen
  assert count(services, remaining) == "0"
  assert count(services, lost) == "1"
  io.println(
    "PASS reply loss: two deliveries held uncertain, lookup confirms, exactly one DELETE, remaining target deferred",
  )
}

fn partial_cancellation(services, jobs, worker) {
  let db = grind.connection(jobs)
  let first = command("cancelled", DropReply)
  let remaining = command("cancelled", Archive)
  let handle = campaign.submit(jobs, worker, first)
  let assert Ok(grind.Uncertain(_)) =
    grind.await(jobs, handle, within: duration.seconds(5))
  let assert Ok(admission) =
    grind.submit(
      jobs,
      job.new(worker, remaining) |> job.after(duration.hours(1)),
    )
  let pending = grind.handle(admission)
  assert grind.cancel(jobs, handle) == Ok(grind.AlreadyUncertain)
  assert grind.cancel(jobs, pending) == Ok(grind.CancelledBeforeRun)
  assert evidence.read(db, first) == evidence.Pending
  let replay =
    admin.resolution(
      admin.AuthorizeReplay,
      id: "forbidden-replay",
      by: "synthetic-reconciler",
      details: "Cancellation must prohibit replay",
    )
  assert admin.resolve_uncertain(jobs, handle, replay)
    == Error(admin.CancellationPending)
  let assert Ok(receipt) = campaign.lookup(services, first)
  evidence.confirm(db, first, receipt)
  let decision =
    admin.resolution(
      admin.ConfirmSuccess(receipt),
      id: "cancelled-but-erased",
      by: "synthetic-reconciler",
      details: "Cancellation cannot reverse the observed deletion",
    )
  let assert Ok(admin.Applied(job.Succeeded)) =
    admin.resolve_uncertain(jobs, handle, decision)
  assert evidence.read(db, first) == evidence.Confirmed(receipt)
  assert evidence.read(db, remaining) == evidence.Unseen
  assert count(services, first) == "1"
  assert count(services, remaining) == "0"
  io.println(
    "PASS cancellation: intent retained; one authoritative deletion, one cancelled-before-run target; campaign remains partially erased",
  )
}

fn target_policy(services, jobs, worker) {
  list.each(
    [
      #("policy-unknown-stop", domain.StopOnRejection),
      #("policy-unknown-continue", domain.ContinueOnRejection),
    ],
    fn(pair) {
      let #(case_id, policy) = pair
      let completed = command(case_id, Archive)
      let unknown = command(case_id, DropReply)
      let unknown_next = command(case_id, Profile)
      let assert campaign.NeedsInvestigation(
        [campaign.Erased(_, _)],
        halted,
        handle,
        Ok(grind.Uncertain(_)),
        [remaining],
      ) =
        campaign.execute_targets(
          jobs,
          worker,
          [completed, unknown, unknown_next],
          policy,
        )
      assert remaining == unknown_next
      assert halted == unknown
      assert grind.arguments(jobs, handle) == Ok(unknown)
      assert count(services, unknown) == "1"
      assert count(services, unknown_next) == "0"
    },
  )
  let stop_reject = command("stop", Reject)
  let stop_next = command("stop", Profile)
  assert campaign.execute_targets(
      jobs,
      worker,
      [stop_reject, stop_next],
      domain.StopOnRejection,
    )
    == campaign.StoppedAfterRejection([campaign.Refused(stop_reject)], [
      stop_next,
    ])
  assert count(services, stop_next) == "0"
  let continue_reject = command("continue", Reject)
  let continue_next = command("continue", Profile)
  let assert campaign.Finished([campaign.Refused(_), campaign.Erased(_, _)]) =
    campaign.execute_targets(
      jobs,
      worker,
      [continue_reject, continue_next],
      domain.ContinueOnRejection,
    )
  assert count(services, continue_next) == "1"
  io.println(
    "PASS target policy: stop/continue differ on known rejection; both return typed investigation after lost reply and retain completed target plus job handle",
  )
}

pub fn complete_campaign_test() {
  let assert Ok(base) = envoy.get("ERASURE_FIXTURE_URL")
  let assert Ok(client) =
    http_gun.start(config.default() |> config.allow_loopback)
  use <- exception.defer(fn() { http_gun.stop(client) })
  let services = campaign.Services(client, base)
  let first = command("ordinary", Profile)
  let old_id = {
    use jobs, worker <- with_runtime(services, campaign.NoGate, 1)
    let db = grind.connection(jobs)
    evidence.install(db)
    let assert Ok(execution.Completed("ordinary")) =
      campaign.prepare(db, "ordinary", False)
    let handle = campaign.submit(jobs, worker, first)
    assert grind.arguments(jobs, handle) == Ok(first)
    let assert Ok(grind.Succeeded(receipt)) =
      grind.await(jobs, handle, within: duration.seconds(5))
    assert evidence.read(db, first) == evidence.Confirmed(receipt)
    let second = Command(..first, target: Archive)
    let next = campaign.submit(jobs, worker, second)
    let assert Ok(grind.Succeeded(_)) =
      grind.await(jobs, next, within: duration.seconds(5))
    assert count(services, first) == "1"
    assert count(services, second) == "1"
    campaign.release_preparation(db, "ordinary")
    let assert Ok(cleanup) =
      pog.query(
        "SELECT operation FROM erasure_preparation WHERE frozen OR staged",
      )
      |> pog.execute(db)
    assert cleanup.count == 0
    io.println(
      "PASS ordinary: Saga preparation, native identity roundtrip, two target deletions",
    )
    preparation_failure(db)
    uncertain(services, jobs, worker)
    partial_cancellation(services, jobs, worker)
    target_policy(services, jobs, worker)
    let assert Ok(pruned) =
      admin.prune_finished(
        jobs,
        older_than: duration.milliseconds(1),
        limit: 100,
      )
    assert pruned > 0
    let assert Error(grind.JobNotFound) = grind.outcome(jobs, handle)
    job.id(handle)
  }
  {
    // New owner, pool, registered runtime and queue processes. Provider and DB survive.
    use jobs, worker <- with_runtime(services, campaign.NoGate, 1)
    let assert Error(grind.JobNotFound) = grind.bind(jobs, worker, old_id)
    let handle = campaign.submit(jobs, worker, first)
    let assert Ok(grind.Succeeded(_)) =
      grind.await(jobs, handle, within: duration.seconds(5))
    assert count(services, first) == "1"
    let remaining = command("reply-loss", Archive)
    let next = campaign.submit(jobs, worker, remaining)
    let assert Ok(grind.Succeeded(_)) =
      grind.await(jobs, next, within: duration.seconds(5))
    assert count(services, remaining) == "1"
    assert count(services, command("reply-loss", DropReply)) == "1"
    io.println(
      "PASS fresh coordinator after pruning: old job missing, new delivery uses application receipt, remaining target finishes, no repeated DELETE",
    )
  }
  {
    let entered = process.new_subject()
    use jobs, worker <- with_runtime(services, campaign.Gate(entered), 2)
    let handles =
      list.map(
        [
          command("bounded-1", Profile),
          command("bounded-2", Profile),
          command("bounded-3", Profile),
        ],
        campaign.submit(jobs, worker, _),
      )
    let assert Ok(release_one) = process.receive(entered, 5000)
    let assert Ok(release_two) = process.receive(entered, 5000)
    let assert Ok(executing) =
      admin.list(jobs, admin.query(limit: 100) |> admin.in_state(job.Executing))
    assert list.length(executing) == 2
    let assert Ok(queued) =
      admin.list(jobs, admin.query(limit: 100) |> admin.in_state(job.Queued))
    assert list.length(queued) == 1
    assert process.receive(entered, 100) == Error(Nil)
    process.send(release_one, Nil)
    let assert Ok(release_three) = process.receive(entered, 5000)
    process.send(release_two, Nil)
    process.send(release_three, Nil)
    list.each(handles, fn(handle) {
      let assert Ok(grind.Succeeded(_)) =
        grind.await(jobs, handle, within: duration.seconds(5))
    })
    io.println(
      "PASS concurrency=2: two handlers at barriers, third queued, third enters only after release",
    )
  }
}
