//// The policy as data at work: a small payout the seller's dispute won
//// proceeds by itself; a seller with recent chargebacks is assessed by the
//// consulted `risk` point first; a rejection, an expiry and a release the
//// release check refuses each reach the seller as what really happened.

import decisions
import decisions/fact
import decisions/occurrence
import decisions/policy
import decisions/vocabulary.{Approve, Reason, Reject}
import decisions_postgres
import decisions_postgres/queue
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import payout_desk/app
import payout_desk/db
import payout_desk/domain
import support

pub fn a_small_payout_the_seller_won_proceeds_by_policy_test() {
  use running <- support.with_app("small", fn(s) { s })
  let id = support.ask(running, "r-small", "O-3001", domain.won_by_seller, 4000)
  let known = support.read(running, id)
  assert fact.get(known.recommendation.signals, domain.dispute_for_seller())
    == Ok(True)
  // Accepted by the policy and held, so finance may still take it back
  // (`robustness_test` withdraws one).
  let assert occurrence.Held(by: occurrence.ByPolicy(1), ..) = known.status
  let assert Some(told) = support.told(running, id, 20_000)
  assert told.outcome == "paid"
  assert told.message == "Dora, we paid you 40.00 (receipt rcpt-1001)."
}

pub fn a_seller_with_chargebacks_is_assessed_by_risk_first_test() {
  use running <- support.with_app("risk", fn(s) { s })
  let assert Ok(Nil) = db.add_chargeback(running.db, "dora", 10)
  let assert Ok(Nil) = db.add_chargeback(running.db, "dora", 40)
  let id = support.ask(running, "r-risk", "O-3002", "partial", 8000)
  let known = support.read(running, id)
  // The risk point's settlement informed the payout, and the policy, read
  // again, asks for two approvals.
  assert known.informed == [fact.set(domain.risk_level(), "high")]
  let assert occurrence.Awaiting(eligible:) = known.status
  assert policy.approvals(eligible) == 2
  let assert Ok(about) =
    queue.about(running.db, vocabulary.Subject("seller", "dora"), limit: 10)
  assert list.map(about, fn(s) { s.point }) |> list.sort(string.compare)
    == ["payout", "risk"]
}

pub fn a_rejection_is_told_with_its_reason_test() {
  use running <- support.with_app("reject", fn(s) { s })
  let id = support.ask(running, "r-reject", "O-3003", "partial", 8000)
  let assert Ok(known) =
    support.decide(
      running,
      id,
      "bia",
      Reject(Reason("buyer_won", Some("the buyer won the dispute in full"))),
    )
  let assert occurrence.Rejected(_) = known.status
  let assert Some(told) = support.told(running, id, 20_000)
  assert told.outcome == "rejected"
  assert told.from_agent
  assert told.message
    == "Dora, finance did not approve the payout: the buyer won the dispute in full."
  assert db.instructions_of(running.db, id) == Ok(0)
}

pub fn an_expired_request_is_told_that_nothing_was_paid_test() {
  use running <- support.with_app("expire", fn(s) {
    app.Settings(..s, validity: duration.seconds(2))
  })
  let id = support.ask(running, "r-expire", "O-3004", "partial", 8000)
  let assert Some(told) = support.told(running, id, 20_000)
  let assert occurrence.Expired(_) = support.read(running, id).status
  assert told.outcome == "expired"
  // A verdict after the validity is refused.
  let assert Error(decisions_postgres.Refused(decisions.NotAwaiting)) =
    support.decide(running, id, "bia", Approve)
}

pub fn a_release_the_balance_does_not_cover_is_refused_and_kept_test() {
  // A person's approval releases at once: the release check runs in the
  // verdict's transaction.
  use running <- support.with_app("refused", fn(s) { s })
  let id = support.ask(running, "r-refused", "O-3005", "partial", 8000)
  // The balance drops below the payout after the agent proposed it.
  let assert Ok(Nil) = db.put_seller(running.db, "dora", 5000)
  let assert Error(decisions_postgres.Refused(decisions.ToolRefused(reason:, ..))) =
    support.decide(running, id, "bia", Approve)
  assert reason == "the balance has 50.00 available, the payout asks 80.00"
  // The verdict's transaction rolled back; a second one kept the refusal.
  let known = support.read(running, id)
  let assert occurrence.Awaiting(_) = known.status
  assert list.length(occurrence.refusals(known)) == 1
  assert db.instructions_of(running.db, id) == Ok(0)
}

pub fn a_release_refused_after_the_hold_is_told_as_refused_test() {
  use running <- support.with_app("refused_hold", fn(s) {
    app.Settings(..s, hold: duration.seconds(2))
  })
  let id =
    support.ask(running, "r-refused2", "O-3006", domain.won_by_seller, 4000)
  let assert occurrence.Held(..) = support.read(running, id).status
  // The balance drops during the hold; the release checks it again.
  let assert Ok(Nil) = db.put_seller(running.db, "dora", 1000)
  let assert Some(told) = support.told(running, id, 20_000)
  let assert occurrence.Refused(_) = support.read(running, id).status
  assert told.outcome == "refused"
  assert db.instructions_of(running.db, id) == Ok(0)
}
