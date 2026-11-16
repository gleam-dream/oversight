//// Telling the agent and the seller the truth.
////
//// The trap in the recipe's notes: an agent's approval request expires
//// unanswered, Fabric rejects the call and gives the model its next turn,
//// and a model that reads any answer as success tells the customer the
//// payout is done. Here the approval never expires in production; and
//// whatever the model says, the seller is sent only what the record says.

import decisions/occurrence
import decisions/vocabulary.{Approve}
import fabric
import fabric/run
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import payout_desk/agent.{Session} as payout_agent
import payout_desk/app
import payout_desk/db
import payout_desk/events
import payout_desk/jobs
import payout_desk/reads
import sinal
import sinal/correlation
import support

pub fn the_trap_an_expired_approval_never_tells_the_seller_done_test() {
  use running <- support.with_app("trap", fn(s) {
    app.Settings(
      ..s,
      script: payout_agent.Naive,
      approval_expiry: run.After(duration.seconds(1)),
    )
  })
  let id = support.ask(running, "r-trap", "O-4001", "partial", 8000)
  process.sleep(1500)
  // The approval expired. Whoever touches the run next rejects the call,
  // and the run goes on: its model says the payout is done.
  let session =
    Session(
      request: "r-trap",
      seller: "dora",
      sources: reads.live(running.db),
      settled: None,
    )
  let assert Ok(handle) =
    fabric.open(
      running.deps.runs,
      running.deps.agent,
      session,
      payout_agent.run_id("r-trap", 0),
    )
  let assert Ok(payout_agent.Answered(reply)) =
    payout_agent.settle(handle, duration.seconds(10))
  assert reply.outcome == "paid"
  assert reply.message == "Done, Dora: 80.00 is on its way."
  // Nothing is sent on the strength of it: the record says no one decided.
  let known = support.read(running, id)
  let assert occurrence.Awaiting(_) = known.status
  assert jobs.deliver(running.db, known, Some(reply)) == Error(jobs.NotKnownYet)
  assert db.told(running.db, id) == Ok(None)
  // Finance corrects it later. The seller is sent what the record says,
  // and the model's claim is kept beside it for review.
  let standing = occurrence.standing(known).0
  let assert Ok(_) =
    support.decide(running, id, "bia", support.corrected(6000)(standing))
  let assert Some(told) = support.told(running, id, 20_000)
  assert told.outcome == "paid"
  assert !told.from_agent
  assert told.message
    == "Dora, we paid you 60.00. Finance corrected the 80.00 we first proposed."
  assert told.agent_message == "Done, Dora: 80.00 is on its way."
}

pub fn every_stage_of_a_payout_is_announced_test() {
  let seen = process.new_subject()
  let attachment =
    sinal.observe(events.moved(), fn(_, moved: events.Moved) {
      case moved.correlation == correlation.from_key("r-events") {
        True -> process.send(seen, events.stage_name(moved.stage))
        False -> Nil
      }
    })
  use running <- support.with_app("events", fn(s) { s })
  let id = support.ask(running, "r-events", "O-4002", "partial", 8000)
  let assert Ok(_) = support.decide(running, id, "bia", Approve)
  let assert Some(_) = support.told(running, id, 20_000)
  let stages = collect(seen, [])
  let _ = sinal.detach(attachment)
  assert list.unique(stages) == ["admitted", "settled", "paid", "told"]
}

fn collect(seen: process.Subject(String), found: List(String)) -> List(String) {
  case process.receive(seen, 200) {
    Ok(stage) -> collect(seen, [stage, ..found])
    Error(Nil) -> list.reverse(found)
  }
}
