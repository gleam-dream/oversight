//// Dora's payout from her request to the provider's receipt, decided by
//// finance over MCP.

import decisions/occurrence
import decisions/vocabulary.{Ref}
import gleam/list
import gleam/option.{None, Some}
import json/blueprint/codec
import payout_desk/app
import payout_desk/db
import payout_desk/desk_tools.{OpenRequest, QueueRequest, VerdictRequest}
import payout_desk/domain
import payout_desk/provider
import relay/client as mcp
import support

pub fn finance_corrects_and_dora_is_told_what_was_paid_test() {
  use running <- support.with_app("story", fn(s) { s })
  let id = support.ask(running, "r-1", "O-1001", "partial", 8000)
  let known = support.read(running, id)
  // The agent's tool call is the key; what it received is on the record.
  let assert occurrence.Awaiting(_) = known.status
  assert known.recommendation.output.amount_cents == 8000
  assert list.length(known.recommendation.reads) == 3
  assert known.requester == Some("fiona")

  // Fiona asked, so her queue leaves the payout out; Bia's holds it.
  let fiona = support.desk(running, "fiona")
  let assert Ok(mcp.Succeeded(queue, _)) =
    mcp.call(fiona, desk_tools.queue_definition(), QueueRequest(10))
  assert queue.payouts == []
  let bia = support.desk(running, "bia")
  let assert Ok(mcp.Succeeded(queue, _)) =
    mcp.call(bia, desk_tools.queue_definition(), QueueRequest(10))
  assert list.map(queue.payouts, fn(q) { q.occurrence }) == [id]

  // The dispute is revised after the model read it. The card still shows
  // what the model read, and flags that it changed since.
  let assert Ok(Nil) =
    db.put_dispute(
      running.db,
      domain.Dispute(..current_dispute(running), note: "reviewed again"),
    )
  let assert Ok(mcp.Succeeded(card, _)) =
    mcp.call(bia, desk_tools.open_definition(), OpenRequest(id))
  assert list.map(card.pulled, fn(i) { i.ref.kind })
    == [domain.read_order, domain.read_dispute, domain.read_history]
  let assert Ok(read) =
    list.find(card.pulled, fn(i) { i.ref.kind == domain.read_dispute })
  let assert Ok(content) = read.content
  let assert Ok(dispute) = codec.decode_json(domain.dispute_codec(), content)
  assert dispute.seller_owed_cents == 8000
  assert dispute.note != "reviewed again"
  let changed =
    list.filter_map(card.pulled, fn(i) {
      case i.now {
        Some(_) -> Ok(i.ref.kind)
        None -> Error(Nil)
      }
    })
  assert changed == [domain.read_dispute]
  assert card.standing.amount_cents == 8000

  // Bia lowers it to 60.00: the chargeback fee is the seller's.
  let assert Ok(mcp.Succeeded(decided, _)) =
    mcp.call(
      bia,
      desk_tools.decide_definition(),
      VerdictRequest(
        occurrence: id,
        seen: card.seen,
        verdict: "correct",
        amount_cents: Some(6000),
        reason: Some("chargeback_fee"),
        note: Some("20.00 is the chargeback fee, which the seller bears"),
      ),
    )
  // A payout a person approved is released at once.
  assert decided.status == "released"
  assert decided.standing_cents == 6000

  // Released in the verdict's transaction, then paid once under the
  // release key, and told.
  let assert Some(told) = support.told(running, id, 20_000)
  let known = support.read(running, id)
  let assert occurrence.Released(key:, final:, ..) = known.status
  assert final.amount_cents == 6000
  // The release check recorded the balance it compared the payout with.
  assert list.contains(
    occurrence.relied(known),
    Ref("seller_available_cents", "dora", "200000"),
  )
  assert provider.counts(running.settings.provider, key).payments == 1
  assert told.outcome == "paid"
  assert told.from_agent
  assert db.balance(running.db, "dora") == Ok(#(200_000 - 6000, 0))
  // The run was resumed with the truth: the tool returned 60.00.
  assert told.message
    == "Dora, finance reviewed the dispute and paid you 60.00 instead of the 80.00 I proposed (receipt rcpt-1001)."
}

fn current_dispute(running: app.App) -> domain.Dispute {
  let assert Ok(dispute) = db.dispute(running.db, "O-1001")
  dispute
}
