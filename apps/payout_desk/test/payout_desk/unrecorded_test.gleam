//// A write the record or the seller depends on that fails is not taken for
//// done: the job waits for the store and writes again.

import gleam/int
import gleam/list
import gleam/option.{Some}
import grind/admin
import grind/job
import payout_desk/app.{type App}
import payout_desk/domain
import payout_desk/jobs
import payout_desk/world
import pog
import support

/// Makes every insert into `table` that `when` matches fail, the way a
/// database fault would. Returns the function that removes the fault.
fn refuse_insert(
  db: pog.Connection,
  table: String,
  when: String,
) -> fn() -> Nil {
  let run = fn(sql) {
    let assert Ok(_) = pog.query(sql) |> pog.execute(db)
    Nil
  }
  run(
    "CREATE FUNCTION refuse_insert() RETURNS trigger AS $$
     BEGIN RAISE EXCEPTION 'store fault'; END $$ LANGUAGE plpgsql",
  )
  run("CREATE TRIGGER refuse_insert BEFORE INSERT ON " <> table <> "
     FOR EACH ROW WHEN (" <> when <> ") EXECUTE FUNCTION refuse_insert()")
  fn() {
    run("DROP TRIGGER refuse_insert ON " <> table)
    run("DROP FUNCTION refuse_insert()")
  }
}

/// The jobs of `worker` that have run at least once.
fn ran(running: App, worker: String) -> List(admin.JobSummary) {
  let assert Ok(jobs) =
    admin.list(
      running.jobs,
      admin.query(limit: 100) |> admin.in_queue(jobs.queue),
    )
  list.filter(jobs, fn(summary) {
    summary.worker_id == worker
    && {
      summary.attempt > 1
      || summary.snooze_count > 0
      || summary.state == job.Succeeded
    }
  })
}

/// A reply that cannot be stored leaves the tell job unfinished: the seller
/// was not told, so the job does not say "told". Once the store takes the
/// reply, the job tells the seller.
pub fn an_unstored_reply_keeps_the_tell_job_test() {
  use running <- support.with_app("unstored_reply", fn(s) { s })
  let restore = refuse_insert(running.db, "replies", "true")
  let id = support.ask(running, "r-u1", "O-7001", domain.won_by_seller, 4000)
  let assert True =
    support.eventually(20_000, fn() { ran(running, "payout.tell") != [] })
  let assert [tell] = ran(running, "payout.tell")
  assert tell.state != job.Succeeded
  restore()

  let assert Some(told) = support.told(running, id, 20_000)
  assert told.outcome == "paid"
}

/// A failed agent run whose failure cannot be recorded does not spend one
/// of the request's attempts: the record is what counts them, so the job
/// waits for the store instead of failing.
pub fn an_unrecorded_run_failure_spends_no_attempt_test() {
  let key = "unrecorded-" <> int.to_string(support.unique())
  use running <- support.with_app("unrecorded_failure", fn(s) {
    app.Settings(..s, model_fault: fn() { support.once(key) })
  })
  let restore =
    refuse_insert(
      running.db,
      "decisions_entries",
      "NEW.kind = 'attempt_failed'",
    )
  let assert Ok(Nil) =
    world.disputed(
      running.db,
      order: "O-7002",
      status: "partial",
      owed_cents: 8000,
      fee_cents: 2000,
    )
  let assert Ok(Nil) =
    app.request(
      running,
      world.request("r-u2", "O-7002"),
      requested_by: world.fiona,
    )
  let assert True =
    support.eventually(10_000, fn() { ran(running, "payout.agent") != [] })
  let assert [agent] = ran(running, "payout.agent")
  // Grind counts a snoozed delivery as no attempt.
  assert agent.attempt <= 1
  restore()

  let assert Ok(id) = app.occurrence_of(running, "r-u2", 15_000)
  let known = support.read(running, id)
  assert list.length(known.attempts) == 1
}
