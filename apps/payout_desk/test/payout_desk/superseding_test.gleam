//// Work in flight on the record. A request expects its payout under its
//// own key from the moment it is admitted, so a failed agent run and the
//// payout that follows are one record, and a newer event (the seller's
//// account suspended) supersedes a payout at any stage before release:
//// expected, waiting for finance, or on hold. A run that handed its
//// proposal over has already ended, so a supersession leaves nothing in
//// Fabric to cancel.

import decisions
import decisions/learning
import decisions/occurrence
import decisions/vocabulary
import decisions_postgres
import decisions_postgres/queue
import fabric
import fabric/run
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import grind/worker
import payout_desk/agent as payout_agent
import payout_desk/app
import payout_desk/db
import payout_desk/domain
import payout_desk/jobs
import payout_desk/provider
import payout_desk/reads
import payout_desk/review
import payout_desk/world
import pog
import support

pub fn a_suspension_supersedes_payouts_on_hold_and_waiting_test() {
  use running <- support.with_app("suspend", fn(s) {
    app.Settings(..s, hold: duration.seconds(30))
  })
  let held = support.ask(running, "r-s1", "O-6101", domain.won_by_seller, 4000)
  let waiting = support.ask(running, "r-s2", "O-6102", "partial", 8000)
  let assert occurrence.Held(..) = support.read(running, held).status
  let assert occurrence.Awaiting(_) = support.read(running, waiting).status
  let assert Ok(superseded) = app.suspend_seller(running, "dora")
  assert list.sort(list.map(superseded.expired, fn(k) { k.id }), string.compare)
    == list.sort([held, waiting], string.compare)
  // Nothing was released or paid; each lapsed, and Dora is told so.
  list.each([held, waiting], fn(id) {
    let known = support.read(running, id)
    let assert occurrence.Lapsed(vocabulary.Superseded(
      event: "seller_suspended",
    )) = occurrence.account(known)
    let assert Some(told) = support.told(running, id, 20_000)
    assert told.outcome == "superseded"
    assert db.instructions_of(running.db, id) == Ok(0)
  })
  assert db.balance(running.db, "dora") == Ok(#(200_000, 0))
}

pub fn a_suspension_before_the_agent_proposed_supersedes_the_expectation_test() {
  // Nothing delivers jobs: the request is admitted and expected, and its
  // agent has not run.
  use running <- support.with_app("suspend_early", fn(s) {
    app.Settings(..s, consumers: False)
  })
  let assert Ok(Nil) =
    world.disputed(
      running.db,
      order: "O-6103",
      status: "partial",
      owed_cents: 8000,
      fee_cents: 2000,
    )
  let assert Ok(Nil) =
    app.request(running, world.request("r-s3", "O-6103"), requested_by: "fiona")
  // The expectation is work in flight an operator can list.
  let assert Ok(pending) =
    queue.pending(running.db, point: "payout", limit: 10, after: None)
  assert list.map(pending, fn(p) { p.occurrence }) == [jobs.request_key("r-s3")]
  let assert Ok(superseded) = app.suspend_seller(running, "dora")
  assert superseded.not_begun == [jobs.request_key("r-s3")]
  // The agent's job, delivered now, does not drive a run for it.
  assert jobs.propose(running.deps, running.db, "r-s3")
    == worker.Succeeded("superseded before the agent proposed")
  let assert Ok(records) = review.records(running.db, app.payout_desk(running))
  assert review.summary(records).coverage
    == learning.Coverage(
      expected: 1,
      superseded_before: 1,
      lapsed_before: 0,
      still_expected: 0,
    )
}

pub fn a_suspension_while_the_agent_is_working_leaves_nothing_to_cancel_test() {
  // The barrier: once the agent's run has handed its proposal over and
  // ended, and before the proposal is admitted, the job hands the test a
  // release and waits for it.
  let parked = process.new_subject()
  use running <- support.with_app("suspend_working", fn(s) {
    app.Settings(..s, before_admit: fn() {
      let release = process.new_subject()
      process.send(parked, release)
      let _ = process.receive(release, 20_000)
      Nil
    })
  })
  let key = jobs.request_key("r-s4")
  let assert Ok(Nil) =
    world.disputed(
      running.db,
      order: "O-6105",
      status: "partial",
      owed_cents: 8000,
      fee_cents: 2000,
    )
  let assert Ok(Nil) =
    app.request(running, world.request("r-s4", "O-6105"), requested_by: "fiona")
  let assert Ok(release) = process.receive(parked, 20_000)
  // The seller is suspended while the run waits to be admitted.
  let assert Ok(superseded) = app.suspend_seller(running, "dora")
  assert superseded.not_begun == [key]
  process.send(release, Nil)
  // The proposal is refused: the record stays superseded before it began.
  let assert Some(told) = support.told(running, key, 20_000)
  assert told.outcome == "superseded"
  assert !told.from_agent
  let read = fn() {
    decisions_postgres.transaction(running.db, decisions.read_record(
      app.payout_desk(running),
      _,
      key:,
    ))
  }
  let assert Ok(decisions.NotBegun(pending)) = read()
  assert pending.ended
    == Some(vocabulary.Superseded(event: domain.seller_suspended))
  // The run ended with its handover, before the suspension, and stays so:
  // nothing cancelled it, and no follow-on run continues it.
  let session =
    payout_agent.Session(
      request: "r-s4",
      seller: "dora",
      sources: reads.live(running.db),
      settled: None,
    )
  let assert Ok(handle) =
    fabric.open(
      running.deps.runs,
      running.deps.agent,
      session,
      payout_agent.run_id("r-s4", 0),
    )
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert run.Finished(run.HandedOver(tool: "propose_payout", ..)) =
    snapshot.status
  let assert Error(_) =
    fabric.open(
      running.deps.runs,
      running.deps.agent,
      session,
      payout_agent.follow_on_id("r-s4"),
    )
  // Nothing was paid, and the seller was told once.
  assert db.instructions_of(running.db, key) == Ok(0)
  assert provider.counts(running.settings.provider, "release:" <> key)
    == provider.Counts(0, 0, 0)
  assert db.balance(running.db, "dora") == Ok(#(200_000, 0))
  let assert Ok(rows) =
    pog.query("SELECT count(*) FROM replies WHERE occurrence = $1")
    |> pog.parameter(pog.text(key))
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(running.db)
  assert rows.rows == [1]
}

pub fn a_failed_agent_run_and_its_payout_are_one_record_test() {
  let key = "model-" <> int.to_string(support.unique())
  use running <- support.with_app("attempts", fn(s) {
    app.Settings(..s, model_fault: fn() { support.once(key) })
  })
  // The model's provider refuses the first call: that run fails, the
  // record keeps the failed attempt under the request's key, Grind retries
  // the job, and a fresh run proposes.
  let id = support.ask(running, "r-a1", "O-6104", "partial", 8000)
  assert id == jobs.request_key("r-a1")
  let known = support.read(running, id)
  let assert [attempt] = known.attempts
  assert attempt.trigger == vocabulary.Trigger("request", "r-a1")
  let assert vocabulary.RunAction(run: "payoutretry-1-r-a1", ..) =
    known.recommendation.explanation
  assert occurrence.was_expected(known)
  let assert occurrence.Awaiting(_) = known.status
}

pub fn a_retried_request_and_a_request_named_like_its_retry_are_two_runs_test() {
  // `x-1` at its first attempt and `x` at its second once named the same
  // run: `payout-x-1`.
  assert payout_agent.run_id("x-1", 0) != payout_agent.run_id("x", 1)
  let key = "collide-" <> int.to_string(support.unique())
  use running <- support.with_app("collide", fn(s) {
    app.Settings(..s, model_fault: fn() { support.once(key) })
  })
  // Request `c`'s first run fails; its retry runs as its second attempt.
  let first = support.ask(running, "c", "O-6106", "partial", 8000)
  // Request `c-1` then runs its own first attempt, not `c`'s retry.
  let second = support.ask(running, "c-1", "O-6107", "partial", 6000)
  let c = support.read(running, first)
  let c1 = support.read(running, second)
  let assert vocabulary.RunAction(run: "payoutretry-1-c", ..) =
    c.recommendation.explanation
  let assert vocabulary.RunAction(run: "payout-c-1", ..) =
    c1.recommendation.explanation
  // Each payout is its own request's: its order and amount.
  assert #(c.recommendation.output.order, c.recommendation.output.amount_cents)
    == #("O-6106", 8000)
  assert #(
      c1.recommendation.output.order,
      c1.recommendation.output.amount_cents,
    )
    == #("O-6107", 6000)
  assert list.length(c.attempts) == 1
  assert c1.attempts == []
}
