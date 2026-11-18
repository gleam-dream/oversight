import gleam/list
import gleam/option.{None, Some}
import pages/durable_work.{
  Grind, Lease, Model, Saga, Sagax, SameTransactionCommits,
  SameTransactionRollsBack, SeparateWritesWithCrash, Showing, Tour, Tx,
}
import pages/durable_work/checkout.{
  Aborted, Completed, CrashAfterCharge, Durable, Finished, HeldForReconciliation,
  Local, Lost, NoCrash,
}
import pages/durable_work/checkouts
import pages/durable_work/job.{
  BusinessFailed, Executing, HoldUncertain, NotSubmitted, Queued,
  ReplayAfterLeaseExpiry, Retryable, Stored, Succeeded, Uncertain,
}
import pages/durable_work/queue.{Dead, HeldUncertain, Worker}
import pages/durable_work/queue_widget
import site/context
import site/motion
import site/progress
import site/tour.{Free, Guided, Paused}

fn still() -> context.Context {
  context.new(motion.Off, progress.empty())
}

fn moving() -> context.Context {
  context.new(motion.On, progress.empty())
}

fn next(
  model: durable_work.Model,
  id: durable_work.TourId,
  context: context.Context,
) -> durable_work.Model {
  durable_work.update(model, Tour(id, tour.Next), context).0
}

fn steps(
  model: durable_work.Model,
  id: durable_work.TourId,
  count: Int,
  context: context.Context,
) -> durable_work.Model {
  list.fold(list.repeat(Nil, count), model, fn(m, _) { next(m, id, context) })
}

// GRIND LIFECYCLE -------------------------------------------------------------

pub fn the_grind_tour_drives_one_job_to_an_audited_success_test() {
  let model = durable_work.init()
  let model = next(model, Grind, still())
  assert model.job.phase == Stored(Queued)
  let model = next(model, Grind, still())
  assert model.job.phase == Stored(Executing)
  assert model.job.attempts == 1
  let model = next(model, Grind, still())
  assert model.job.phase == Stored(Retryable)
  let model = next(model, Grind, still())
  assert model.job.phase == Stored(Executing)
  assert model.job.attempts == 2
  let model = next(model, Grind, still())
  assert model.job.phase == Stored(Uncertain)
  let model = next(model, Grind, still())
  assert model.job.phase == Stored(Succeeded)
  assert list.first(model.job.history)
    == Ok("operator resolution (audited): effect happened → Succeeded")
  assert list.length(model.job.history) == 7
  let model = next(model, Grind, still())
  assert tour.phase(tour.get(model.tours, Grind)) == Free
}

pub fn going_back_in_the_grind_tour_replays_from_a_fresh_job_test() {
  let model = steps(durable_work.init(), Grind, 4, still())
  let model = durable_work.update(model, Tour(Grind, tour.Back), still()).0
  assert tour.phase(tour.get(model.tours, Grind)) == Guided(3, Paused)
  assert model.job.phase == Stored(Retryable)
  assert model.job.attempts == 1
}

pub fn a_third_failure_is_terminal_test() {
  let run = fn(job, events) {
    list.fold(events, job, fn(j, e) { job.apply(j, e, HoldUncertain) })
  }
  let job =
    run(job.new(), [
      job.SubmitNow,
      job.Claim,
      job.HandlerFails,
      job.BackoffPasses,
      job.Claim,
      job.HandlerFails,
      job.BackoffPasses,
      job.Claim,
    ])
  assert job.attempts == 3
  let assert [_, _, _, _, last] = job.choices(job)
  assert last.event == job.NodeDies
  let failed = job.apply(job, job.HandlerFails, HoldUncertain)
  assert failed.phase == Stored(BusinessFailed)
  assert job.choices(failed) |> list.map(fn(c) { c.event }) == [job.StartOver]
  assert job.apply(failed, job.StartOver, HoldUncertain).phase == NotSubmitted
}

pub fn a_dead_node_replays_only_when_declared_safe_test() {
  let executing =
    job.new()
    |> job.apply(job.SubmitNow, HoldUncertain)
    |> job.apply(job.Claim, HoldUncertain)
  assert job.apply(executing, job.NodeDies, HoldUncertain).phase
    == Stored(Uncertain)
  assert job.apply(executing, job.NodeDies, ReplayAfterLeaseExpiry).phase
    == Stored(Queued)
  // An event that makes no sense now leaves the row alone.
  assert job.apply(executing, job.AuditSent, HoldUncertain) == executing
}

// GRIND QUEUE -----------------------------------------------------------------

pub fn the_queue_reproduces_the_reference_after_ten_ticks_test() {
  let q = queue.advance(queue.new(), 10)
  assert q.done == 1
  assert q.renewals == 6
  assert q.workers
    == [
      Worker(queue.Alive, Some(1)),
      Worker(queue.Alive, Some(4)),
      Worker(queue.Alive, None),
    ]
  assert list.first(q.log)
    == Ok("W2 claimed job 4, skipping 2 rows locked by other workers")
  assert queue.count(q, fn(s) { s == queue.RetryLater(10) }) == 0
  assert queue.row(q, 2) |> option.map(fn(r) { r.attempts }) == Some(1)
}

/// The lease tour with motion off, as the page issues it, applied by the
/// widget's own command handling.
fn queue_after_tour(step_count: Int) -> #(durable_work.Model, queue.Queue) {
  // Replay runs the first step's action too, as Play does in the browser.
  let model =
    durable_work.update(durable_work.init(), Tour(Lease, tour.Replay), still()).0
  let model = steps(model, Lease, step_count, still())
  let #(q, _) =
    queue_widget.catch_up(
      queue.new(),
      Some(0),
      model.queue.expiry,
      model.queue.commands,
    )
  #(model, q)
}

pub fn the_lease_tour_holds_the_dead_workers_job_as_uncertain_test() {
  let #(model, q) = queue_after_tour(3)
  assert model.queue.expiry == HoldUncertain
  assert q.ticks == 40
  assert q.done == 8
  assert q.uncertain == 1
  assert q.renewals == 20
  assert queue.worker_at(q, 1) == Some(Worker(Dead, None))
  assert queue.row(q, 2) |> option.map(fn(r) { r.state }) == Some(HeldUncertain)
}

pub fn the_lease_tour_replays_when_declared_safe_test() {
  let #(model, q) = queue_after_tour(4)
  assert model.queue.expiry == ReplayAfterLeaseExpiry
  assert q.ticks == 60
  assert q.done == 9
  assert q.uncertain == 1
  assert q.replays == 1
  assert q.renewals == 24
  assert list.take(q.log, 2)
    == [
      "job 12: handler returned an error → retry with backoff",
      "job 10: lease expired → replayed, because you declared it safe to repeat",
    ]
}

pub fn with_motion_the_tour_leaves_time_to_the_live_queue_test() {
  let model = steps(durable_work.init(), Lease, 2, moving())
  let codes = list.map(model.queue.commands, fn(entry) { entry.1 })
  assert codes == [queue_widget.Kill(1)]
}

pub fn queue_commands_survive_their_encoding_test() {
  let controls =
    queue_widget.controls()
    |> queue_widget.issue(queue_widget.Reset)
    |> queue_widget.issue(queue_widget.Advance(8))
    |> queue_widget.issue(queue_widget.Expire(ReplayAfterLeaseExpiry))
    |> queue_widget.issue(queue_widget.Kill(2))
    |> queue_widget.issue(queue_widget.AddJobs)
  assert queue_widget.decode(queue_widget.encode(controls))
    == Ok(#(ReplayAfterLeaseExpiry, controls.commands))
}

pub fn a_new_widget_takes_earlier_commands_as_its_baseline_test() {
  let commands = [#(1, queue_widget.Advance(10)), #(2, queue_widget.Kill(0))]
  let #(q, seen) =
    queue_widget.catch_up(queue.new(), None, HoldUncertain, commands)
  assert seen == Some(2)
  assert q.ticks == 0
  let #(q, seen) =
    queue_widget.catch_up(
      q,
      seen,
      HoldUncertain,
      list.append(commands, [#(3, queue_widget.Advance(2))]),
    )
  assert seen == Some(3)
  assert q.ticks == 2
}

pub fn more_jobs_keep_the_newest_twenty_one_rows_test() {
  let q = queue.new() |> queue.add_jobs |> queue.add_jobs
  assert list.length(q.rows) == 21
  assert list.first(q.rows) |> option.from_result |> option.map(fn(r) { r.id })
    == Some(6)
  assert q.next_id == 27
}

// TRANSACTIONAL ADMISSION -----------------------------------------------------

pub fn the_admission_tour_walks_the_three_outcomes_test() {
  let model = next(durable_work.init(), Tx, still())
  assert model.admission == SameTransactionCommits
  let model = next(model, Tx, still())
  assert model.admission == SameTransactionRollsBack
  let model = next(model, Tx, still())
  assert model.admission == SeparateWritesWithCrash
  let model = durable_work.update(model, Tour(Tx, tour.Replay), still()).0
  assert model.admission == SameTransactionCommits
}

// SAGA CHECKOUT ---------------------------------------------------------------

fn outcome(model: durable_work.Model) -> checkout.Progress {
  let c = model.checkout
  let events = checkout.events(c.plan, c.crash, c.durability)
  let upto = case c.run {
    durable_work.NotRun -> -1
    Showing(upto) -> upto
    durable_work.Replaying(upto, _) -> upto
  }
  checkout.snapshot(events, upto).progress
}

pub fn the_saga_tour_without_motion_shows_each_run_at_once_test() {
  let model = next(durable_work.init(), Saga, still())
  assert outcome(model) == Finished(Completed)
  let model = next(model, Saga, still())
  assert outcome(model) == Finished(Aborted("compensated"))
  let model = next(model, Saga, still())
  assert outcome(model) == Finished(HeldForReconciliation)
  let model = next(model, Saga, still())
  assert model.checkout.crash == CrashAfterCharge
  assert model.checkout.durability == Local
  assert outcome(model) == Finished(Lost)
  let model = next(model, Saga, still())
  assert model.checkout.durability == Durable
  assert outcome(model) == Finished(Completed)
}

pub fn an_animated_run_reveals_one_event_per_tick_test() {
  let model = next(durable_work.init(), Saga, moving())
  let assert durable_work.Replaying(0, epoch) = model.checkout.run
  let tick = fn(m) {
    durable_work.update(m, durable_work.CheckoutTicked(epoch), moving()).0
  }
  let model = tick(model)
  assert model.checkout.run == durable_work.Replaying(1, epoch)
  // A stale tick from an earlier run changes nothing.
  let stale =
    durable_work.update(model, durable_work.CheckoutTicked(epoch - 1), moving()).0
  assert stale == model
  let model = tick(model) |> tick |> tick
  assert model.checkout.run == durable_work.Replaying(4, epoch)
  let model = tick(model)
  assert model.checkout.run == Showing(5)
  assert outcome(model) == Finished(Completed)
  // Leaving the page freezes a run mid-flight.
  let again =
    durable_work.update(model, durable_work.ReaderRanCheckout, moving()).0
  let assert durable_work.Replaying(0, _) = again.checkout.run
  assert durable_work.leave(again).checkout.run == Showing(0)
}

pub fn a_durable_crash_resumes_without_charging_again_test() {
  let events = checkout.events(checkout.happy, CrashAfterCharge, Durable)
  let snap = checkout.snapshot(events, list.length(events) - 1)
  assert snap.charge == checkout.Done
  assert snap.ship == checkout.Done
  assert list.length(events)
    == checkout.events(checkout.happy, NoCrash, Durable)
    |> list.length
    |> fn(n) { n + 1 }
}

pub fn a_flagged_order_releases_its_stock_test() {
  let plan = checkout.Plan(..checkout.happy, screening: checkout.Flagged)
  let events = checkout.events(plan, NoCrash, Durable)
  let snap = checkout.snapshot(events, list.length(events) - 1)
  assert snap.reserve == checkout.Undone
  assert snap.charge == checkout.Skipped
  assert snap.progress == Finished(Aborted("flagged"))
}

// 200 CHECKOUTS ---------------------------------------------------------------

fn tallies(rates: checkouts.Rates) -> List(Int) {
  let runs = checkouts.runs(rates)
  list.map(checkouts.kinds, checkouts.tally(runs, _))
}

pub fn two_hundred_runs_match_the_reference_test() {
  // Completed, compensated, stopped early, held, as the reference draws them.
  assert tallies(checkouts.defaults) == [165, 21, 11, 3]
  assert checkouts.retried(checkouts.runs(checkouts.defaults)) == 14
}

pub fn the_ladder_tour_spreads_holds_and_compensations_test() {
  let model = next(durable_work.init(), Sagax, still())
  assert model.rates.unknown == 30
  assert tallies(model.rates) == [156, 21, 11, 12]
  assert checkouts.retried(model.runs) == 52
  let model = next(model, Sagax, still())
  assert tallies(model.rates) == [132, 45, 11, 12]
  let model = durable_work.update(model, Tour(Sagax, tour.Replay), still()).0
  assert model.rates == checkouts.defaults
}

pub fn clicking_a_square_replays_that_run_above_test() {
  let model = durable_work.init()
  let model =
    durable_work.update(
      Model(..model, checkout: checkout_with_crash(model)),
      durable_work.ReaderPickedCheckout(6),
      still(),
    ).0
  assert model.checkout.plan
    == checkout.Plan(..checkout.happy, payment: checkout.Declined)
  assert model.checkout.crash == NoCrash
  assert outcome(model) == Finished(Aborted("Declined"))
}

fn checkout_with_crash(model: durable_work.Model) -> durable_work.Checkout {
  durable_work.Checkout(..model.checkout, crash: CrashAfterCharge)
}
