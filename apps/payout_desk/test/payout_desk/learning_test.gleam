//// Learning from the record: export what finance decided, tally it, and
//// replay a stricter candidate model against it.

import decisions/learning
import decisions/vocabulary.{Approve, Reason, Reject}
import gleam/list
import gleam/option.{None, Some}
import payout_desk/app
import payout_desk/review
import support

pub fn finance_decisions_are_tallied_and_replayed_test() {
  use running <- support.with_app("learning", fn(s) { s })
  // Each dispute owes 80.00, of which 20.00 is the chargeback fee.
  let approved = support.ask(running, "r-l1", "O-6001", "partial", 8000)
  let lowered = support.ask(running, "r-l2", "O-6002", "partial", 8000)
  let rejected = support.ask(running, "r-l3", "O-6003", "partial", 8000)
  let assert Ok(_) = support.decide(running, approved, "bia", Approve)
  let standing = support.read(running, lowered).recommendation.output
  let assert Ok(_) =
    support.decide(running, lowered, "bia", support.corrected(6000)(standing))
  let assert Ok(_) =
    support.decide(running, rejected, "carl", Reject(Reason("buyer_won", None)))

  let assert Ok(known) = review.recorded(running.db, app.payout_desk(running))
  let summary = review.summary(known)
  // Finance let two through, one as proposed; it lowered one and rejected
  // one, which lets nothing through and so is not judged.
  assert summary.tally.judged == 2
  assert summary.tally.agreed == 1
  assert summary.lowered == 1
  assert summary.tally.rejected == 1

  let #(examples, missing) = review.export(running.db, known)
  assert missing == []
  assert list.length(examples) == 3
  // The candidate bears the fee: 60.00 everywhere. It matches the
  // correction, not the approval of 80.00.
  let #(scored, changes) = review.replay(examples, review.stricter())
  assert scored.unanswered == []
  assert scored.tally
    == learning.Tally(agreed: 1, judged: 2, rejected: 1, right: 0, assessed: 0)
  let by_id = fn(id) {
    let assert Ok(change) = list.find(changes, fn(c) { c.occurrence == id })
    #(change.decided, change.candidate_cents)
  }
  assert by_id(approved) == #(Some(8000), Ok(6000))
  assert by_id(lowered) == #(Some(6000), Ok(6000))
  assert by_id(rejected) == #(None, Ok(6000))
}
