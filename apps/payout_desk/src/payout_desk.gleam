//// A narrated run: one payout from Dora's request to the provider's
//// receipt, decided by Bia from her own assistant over MCP.
////
//// Run it with the disposable PostgreSQL helper:
////
//// ```sh
//// ../scripts/with-postgres.sh gleam run
//// ```

import decisions
import decisions/occurrence
import decisions/view.{type View}
import decisions/vocabulary
import decisions_postgres
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import payout_desk/app
import payout_desk/db
import payout_desk/desk_tools.{OpenRequest, QueueRequest, VerdictRequest}
import payout_desk/domain
import payout_desk/events
import payout_desk/provider
import payout_desk/world
import relay/client as mcp
import sinal

pub fn main() -> Nil {
  let assert Ok(url) = app.database_url()
    as "DATABASE_URL is unset: run with ../scripts/with-postgres.sh gleam run"
  let assert Ok(payments) = provider.start()
  let stages = process.new_subject()
  let attachment =
    sinal.observe(events.moved(), fn(_, moved: events.Moved) {
      process.send(
        stages,
        events.stage_name(moved.stage) <> " (" <> moved.detail <> ")",
      )
    })
  let settings =
    app.settings(url, schema: "payout_desk_run", provider: payments)
  let assert Ok(running) = app.start(settings)
  let assert Ok(Nil) = world.seed(running.db)
  let assert Ok(Nil) =
    world.disputed(
      running.db,
      order: "O-1001",
      status: "partial",
      owed_cents: 8000,
      fee_cents: 2000,
    )

  say("1. Dora asks support for a payout correction after a disputed order.")
  let assert Ok(Nil) =
    app.request(
      running,
      world.request("r-1001", "O-1001"),
      requested_by: world.fiona,
    )
  let assert Ok(id) = app.occurrence_of(running, "r-1001", 15_000)
  let known = read(running, id)
  say(
    "   The agent read the order, the dispute and Dora's history, and called propose_payout("
    <> domain.money(known.recommendation.output.amount_cents)
    <> ").",
  )
  say(
    "   The call did not pay. It became occurrence "
    <> id
    <> ", "
    <> occurrence.status_name(known.status)
    <> ": a medium payout waits for someone in finance other than Fiona, who asked.",
  )

  say("")
  say("2. Bia signs in and opens her queue from her own assistant (MCP).")
  let bia = connect(running, "bia")
  let assert Ok(mcp.Succeeded(queue, _)) =
    mcp.call(bia, desk_tools.queue_definition(), QueueRequest(10))
  list.each(queue.payouts, fn(q) {
    say(
      "   - "
      <> q.occurrence
      <> ": "
      <> q.seller
      <> ", order "
      <> q.order
      <> ", "
      <> domain.money(q.amount_cents),
    )
  })
  let assert Ok(mcp.Succeeded(card, _)) =
    mcp.call(bia, desk_tools.open_definition(), OpenRequest(id))
  say("   The card, as Bia sees it:")
  print_card(card)

  say("")
  say(
    "3. Bia lowers it to 60.00: 20.00 of it is the chargeback fee, which the seller bears.",
  )
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
  say(
    "   "
    <> decided.status
    <> " at "
    <> domain.money(decided.standing_cents)
    <> ": a payout a person approved is released at once. The release check recorded the balance it compared.",
  )

  say("")
  say("4. Paid through the provider, and told.")
  let told = wait_told(running, id, 30_000)
  let known = read(running, id)
  case known.status, occurrence.effect(known) {
    occurrence.Released(key:, final:, ..), Some(effect) -> {
      say(
        "   Released "
        <> domain.money(final.amount_cents)
        <> " under the release key "
        <> key
        <> ".",
      )
      say("   The workflow reported the effect: " <> describe_effect(effect))
      say(
        "   Payments the provider made under it: "
        <> int.to_string(provider.counts(payments, key).payments),
      )
    }
    status, _ -> say("   " <> occurrence.status_name(status))
  }
  case told {
    Some(told) -> {
      say(
        "   The agent's run was resumed with what really happened. Dora is told:",
      )
      say("     \"" <> told.message <> "\"")
    }
    None -> say("   Dora has not been told yet.")
  }

  say("")
  say("5. What the application announced (Sinal):")
  list.each(drain(stages, []), fn(stage) { say("   - " <> stage) })

  let _ = sinal.detach(attachment)
  app.stop(running)
  provider.stop(payments)
}

fn describe_effect(effect: vocabulary.Effect) -> String {
  case effect {
    vocabulary.Performed(receipt:) -> "performed, receipt " <> receipt.revision
    vocabulary.NotPerformed(reason:) -> "not performed: " <> reason
    vocabulary.Uncertain(reason:) -> "uncertain: " <> reason
  }
}

fn say(text: String) -> Nil {
  io.println(text)
}

fn print_card(card: View(domain.Payout)) -> Nil {
  say(
    "   +-- occurrence "
    <> card.occurrence
    <> " (seen "
    <> int.to_string(card.seen)
    <> ")",
  )
  say(
    "   | status:       "
    <> card.status
    <> ", waiting for "
    <> string.join(card.waiting_for, ", "),
  )
  say(
    "   | proposed:     pay "
    <> card.recommendation.output.seller
    <> " "
    <> domain.money(card.recommendation.output.amount_cents)
    <> " for "
    <> card.recommendation.output.order,
  )
  list.each(card.approvals.alternatives, fn(alternative) {
    say(
      "   | approvals:    "
      <> int.to_string(alternative.have)
      <> " of "
      <> int.to_string(alternative.need)
      <> " from "
      <> string.join(alternative.sets, " or "),
    )
  })
  say("   | context:")
  list.each(card.pushed, print_input)
  say("   | what the model read:")
  list.each(card.pulled, print_input)
  say("   +--")
}

fn print_input(item: view.Item) -> Nil {
  let changed = case item.now {
    Some(newer) -> " (changed since: " <> newer.revision <> ")"
    None -> ""
  }
  say("   |   " <> item.ref.kind <> "(" <> item.ref.id <> ")" <> changed)
  say("   |     " <> result.unwrap(item.content, "(not on record)"))
}

fn read(running: app.App, id: String) -> occurrence.Occurrence(domain.Payout) {
  let assert Ok(known) =
    decisions_postgres.transaction(running.db, decisions.read(
      app.payout_desk(running),
      _,
      occurrence: id,
    ))
  known
}

fn wait_told(running: app.App, id: String, within: Int) -> Option(db.Told) {
  case db.told(running.db, id) {
    Ok(Some(told)) -> Some(told)
    _ if within > 0 -> {
      process.sleep(100)
      wait_told(running, id, within - 100)
    }
    _ -> None
  }
}

fn connect(running: app.App, subject: String) -> mcp.Client {
  let token = app.token(running, subject)
  let assert Ok(config) = mcp.http(running.mcp_url)
  let assert Ok(client) =
    config
    |> mcp.with_timeout(duration.seconds(10))
    |> mcp.with_headers(fn() { [#("authorization", "Bearer " <> token)] })
    |> mcp.connect
  client
}

fn drain(stages: process.Subject(String), found: List(String)) -> List(String) {
  case process.receive(stages, 200) {
    Ok(stage) -> drain(stages, [stage, ..found])
    Error(Nil) -> list.reverse(found) |> list.unique
  }
}
