//// Telling the agent and the seller the truth.
////
//// The trap in the recipe's notes: an agent's approval request expires
//// unanswered, the agent library rejects the call and gives the model its
//// next turn, and a model that reads any answer as success tells the
//// customer the payout is done. Here the policy hands the proposal over and
//// the run ends at once: no approval exists to expire, and no model turn
//// happens between the handover and the decision. Whatever the follow-on
//// run's model then says, the seller is sent only what the record says.

import decisions/occurrence
import decisions/vocabulary.{Approve}
import fabric
import fabric/model as fabric_model
import fabric/run
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import payout_desk/agent.{Session} as payout_agent
import payout_desk/app
import payout_desk/db
import payout_desk/domain
import payout_desk/events
import payout_desk/jobs
import payout_desk/reads
import sinal
import sinal/correlation
import support

pub fn the_trap_cannot_occur_no_approval_and_no_turn_after_the_handover_test() {
  use running <- support.with_app("trap", fn(s) {
    app.Settings(..s, script: payout_agent.Naive)
  })
  let id = support.ask(running, "r-trap", "O-4001", "partial", 8000)
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
  // The run ended when its policy handed the proposal over: the call never
  // ran, and no approval exists to answer or expire.
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert run.Finished(run.HandedOver(tool: "propose_payout", ..)) =
    snapshot.status
  assert fabric.pending(handle) == Ok([])
  let assert Ok(proposal) =
    list.find(snapshot.actions, fn(a) { a.call.name == payout_agent.propose })
  let assert run.Handover(_) = proposal.state
  // The model took two turns, the reads and the proposal, and the
  // transcript ends with the proposal: no result, no turn after it.
  assert snapshot.turns_used == 2
  let assert Ok(fabric_model.AssistantMessage(last)) =
    list.last(snapshot.transcript)
  assert list.map(last.calls, fn(c) { c.name }) == [payout_agent.propose]
  // Time passes, longer than the one-second expiry the trap needed, and
  // recovering the run changes nothing: an ended run takes no turn.
  process.sleep(1500)
  let assert Ok(recovered) =
    fabric.recover(
      running.deps.runs,
      running.deps.agent,
      session,
      payout_agent.run_id("r-trap", 0),
    )
  let assert Ok(run.Finished(run.HandedOver(..))) =
    fabric.await(recovered, within: duration.seconds(1))
  let assert Ok(later) = fabric.snapshot(recovered)
  assert later.turns_used == 2
  assert later.transcript == snapshot.transcript
  // Nothing is told while the record waits, and no follow-on run exists.
  let known = support.read(running, id)
  let assert occurrence.Awaiting(_) = known.status
  assert db.told(running.db, id) == Ok(None)
  let assert Error(_) =
    fabric.open(
      running.deps.runs,
      running.deps.agent,
      session,
      payout_agent.follow_on_id("r-trap"),
    )
  // Finance corrects it. The follow-on run's model claims 80.00 was paid;
  // the seller is sent what the record says, and the claim is kept beside
  // it for review.
  let standing = occurrence.standing(known).0
  let assert Ok(_) =
    support.decide(running, id, "bia", support.corrected(6000)(standing))
  let assert Some(told) = support.told(running, id, 20_000)
  assert told.outcome == "paid"
  assert !told.from_agent
  assert told.message
    == "Dora, we paid you 60.00. Finance corrected the 80.00 we first proposed."
  assert told.agent_message == "Done, Dora: 80.00 is on its way."
  // A model's claim read against the record before it stated the outcome
  // is never delivered.
  let claim =
    domain.Reply(
      outcome: "paid",
      amount_cents: 8000,
      message: "Done, Dora: 80.00 is on its way.",
    )
  assert jobs.deliver(running.db, known, Some(claim)) == Error(jobs.NotKnownYet)
}

pub fn a_follow_on_model_that_proposes_again_is_denied_and_told_from_the_record_test() {
  use running <- support.with_app("insistent", fn(s) {
    app.Settings(..s, script: payout_agent.Insistent)
  })
  let id = support.ask(running, "r-again", "O-4003", "partial", 8000)
  let assert Ok(_) = support.decide(running, id, "bia", Approve)
  let assert Some(told) = support.told(running, id, 20_000)
  // The follow-on run's model proposed the payout again. The policy denied
  // it instead of handing it over a second time, and the run completed.
  let session =
    Session(
      request: "r-again",
      seller: "dora",
      sources: reads.live(running.db),
      settled: None,
    )
  let assert Ok(handle) =
    fabric.open(
      running.deps.runs,
      running.deps.agent,
      session,
      payout_agent.follow_on_id("r-again"),
    )
  let assert Ok(follow_on) = fabric.snapshot(handle)
  let assert run.Finished(run.Completed(_)) = follow_on.status
  assert list.map(follow_on.actions, fn(a) { #(a.call.name, a.state) })
    == [#(payout_agent.propose, run.Denied("the payout is already decided"))]
  // The model answered from the denial, which states no outcome: its reply
  // does not match the record, so Dora is told from the record and the
  // reply is kept.
  assert told.outcome == "paid"
  assert !told.from_agent
  assert told.message == "Dora, we paid you 80.00."
  assert told.agent_message
    == "Dora, I could not confirm your payout yet; finance will follow up."
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
