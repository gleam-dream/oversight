//// The failure paths: deliveries repeated, verdicts racing, a stale card,
//// a worker killed between the provider's answer and the report, restarts
//// with a hold or an escalation pending, a provider that times out, and
//// withdrawing during the hold and after it.

import decisions
import decisions/entry
import decisions/occurrence
import decisions/policy
import decisions/view
import decisions/vocabulary.{Approve, Performed, Subject, Uncertain}
import decisions_postgres
import decisions_postgres/queue
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import grind/worker
import payout_desk/app
import payout_desk/auth
import payout_desk/db
import payout_desk/desk_tools
import payout_desk/domain
import payout_desk/jobs
import payout_desk/provider
import payout_desk/world
import pog
import support

fn payouts_of_dora(running: app.App) -> Int {
  let assert Ok(about) =
    queue.about(running.db, Subject("seller", "dora"), limit: 100)
  list.count(about, fn(summary) { summary.point == "payout" })
}

pub fn a_request_driven_twice_admits_one_payout_test() {
  use running <- support.with_app("twice", fn(s) { s })
  let id = support.ask(running, "r-twice", "O-2001", "partial", 8000)
  // The same request driven again, twice at once: the run is found by the
  // request and the gated call by its key, so nothing new is admitted.
  let again =
    support.race(2, fn(_) { jobs.propose(running.deps, running.db, "r-twice") })
  assert again == [worker.Succeeded(id), worker.Succeeded(id)]
  // A second submission of the request's job converges on the first.
  let assert Ok(Nil) =
    app.request(
      running,
      world.request("r-twice", "O-2001"),
      requested_by: "fiona",
    )
  process.sleep(500)
  assert payouts_of_dora(running) == 1
  assert db.occurrence_of(running.db, "r-twice") == Ok(Some(id))
}

pub fn two_validators_approving_at_once_release_once_test() {
  use running <- support.with_app("race", fn(s) { s })
  let id = support.ask(running, "r-race", "O-2002", "partial", 8000)
  let outcomes =
    support.race(2, fn(n) {
      support.decide(
        running,
        id,
        case n {
          0 -> "bia"
          _ -> "carl"
        },
        Approve,
      )
    })
  let accepted =
    list.count(outcomes, fn(o) {
      case o {
        Ok(known) -> occurrence.status_name(known.status) == "released"
        Error(_) -> False
      }
    })
  let refused =
    list.count(outcomes, fn(o) {
      case o {
        Error(decisions_postgres.Refused(decisions.AlreadyDecided(_))) -> True
        _ -> False
      }
    })
  assert #(accepted, refused) == #(1, 1)
  assert db.instructions_of(running.db, id) == Ok(1)
  let assert Some(told) = support.told(running, id, 20_000)
  assert told.outcome == "paid"
}

pub fn a_verdict_on_a_card_shown_before_a_correction_is_refused_test() {
  use running <- support.with_app("stale", fn(s) { s })
  // 800.00 is large: two approvals from finance, neither of them Fiona.
  let id = support.ask(running, "r-stale", "O-2003", "partial", 80_000)
  let bia_card = support.open(running, id, "bia")
  let assert Ok(known) = support.decide(running, id, "carl", Approve)
  assert occurrence.standing(known).1 == ["carl"]
  // Ana lowers it: Carl's approval of 800.00 no longer counts.
  let standing = occurrence.standing(known).0
  let assert Ok(known) =
    support.decide(running, id, "ana", support.corrected(60_000)(standing))
  assert occurrence.standing(known).1 == ["ana"]
  // Bia's card shows 800.00: her approval would approve what no longer stands.
  let assert Error(decisions_postgres.Refused(decisions.OutputChanged)) =
    support.decide_on(running, bia_card, Approve)
  // Opened again, it shows 600.00, and her approval is the second.
  let assert Ok(known) = support.decide(running, id, "bia", Approve)
  let assert occurrence.Released(final:, ..) = known.status
  assert final.amount_cents == 60_000
  let assert Some(told) = support.told(running, id, 20_000)
  assert told.message
    == "Dora, finance reviewed the dispute and paid you 600.00 instead of the 800.00 I proposed (receipt rcpt-1001)."
}

pub fn a_worker_killed_after_the_provider_answered_pays_once_test() {
  let key = "kill-" <> int.to_string(support.unique())
  use running <- support.with_app("killed", fn(s) {
    app.Settings(..s, after_paid: fn(handler) {
      case support.once(key) {
        // The attempt waits until its runner, which stops with the dead
        // handler, kills it: the answer is never saved.
        True -> {
          process.kill(handler)
          process.sleep(5000)
        }
        False -> Nil
      }
    })
  })
  let id = support.ask(running, "r-kill", "O-2004", "partial", 8000)
  let assert Ok(_) = support.decide(running, id, "bia", Approve)
  // The handler dies with the payment made and nothing saved or reported.
  // Grind replays the job once its lease expires; Saga asks the provider
  // instead of paying again.
  let assert Some(told) = support.told(running, id, 40_000)
  let known = support.read(running, id)
  let assert occurrence.Released(key: release, ..) = known.status
  let counts = provider.counts(running.settings.provider, release)
  assert counts.pay_requests == 1
  assert counts.payments == 1
  assert counts.lookups >= 1
  let assert Some(Performed(_)) = occurrence.effect(known)
  assert told.outcome == "paid"
  assert db.balance(running.db, "dora") == Ok(#(200_000 - 8000, 0))
}

pub fn a_restart_with_a_hold_pending_releases_after_it_test() {
  let settings =
    app.Settings(..support.settings("hold_restart"), hold: duration.seconds(3))
  let first = support.start(settings)
  // A small payout the seller's dispute won: the policy accepts it and
  // holds it.
  let id = support.ask(first, "r-hold", "O-2005", domain.won_by_seller, 4000)
  let assert occurrence.Held(..) = support.read(first, id).status
  // The wake-up's Grind job is lost (pruned, say); its row in the decision
  // store stays pending.
  let assert Ok(lost) =
    pog.query("DELETE FROM \"" <> settings.schema <> "\".grind_jobs
       WHERE worker_id = 'decisions.wake'")
    |> pog.execute(first.db)
  assert lost.count == 1
  app.stop(first)
  // The next runtime's start-up sweep gives the pending wake-up a job, and
  // it is delivered.
  let assert Ok(second) = app.start(settings)
  assert second.swept.wakes == 1
  let assert Some(told) = support.told(second, id, 30_000)
  assert told.outcome == "paid"
  let assert occurrence.Released(key:, ..) = support.read(second, id).status
  assert provider.counts(settings.provider, key).payments == 1
  app.stop(second)
  provider.stop(settings.provider)
}

pub fn a_restart_with_an_escalation_pending_lets_the_head_of_finance_decide_test() {
  let settings = support.settings("escalation")
  let first = support.start(settings)
  let id = support.ask(first, "r-esc", "O-2006", "partial", 80_000)
  // One approval from finance is not enough for 800.00.
  let assert Ok(known) = support.decide(first, id, "carl", Approve)
  let assert occurrence.Awaiting(_) = known.status
  // Before the hour, the head of finance may not decide.
  let assert Error(decisions_postgres.Refused(decisions.NotEligible)) =
    support.decide(first, id, "hana", Approve)
  app.stop(first)
  // The runtime comes back with its record's clock an hour and a minute
  // on. The escalation's wake-up is stored; its Grind job waits on the
  // database's clock, a real hour, so the test delivers the wake-ups due on
  // the store's clock now, through the wake-up worker's own code path.
  let second =
    support.start(app.Settings(..settings, record_skew: duration.minutes(61)))
  let assert Ok(1) = app.deliver_due(second, 10)
  let assert occurrence.Awaiting(eligible:) = support.read(second, id).status
  assert list.contains(policy.sets(eligible), domain.head_of_finance)
  // The card says how far each alternative is: Carl's one approval of the
  // two from finance, none yet of the one from the head of finance.
  let assert Ok(card) =
    desk_tools.open(second.tools, auth.Principal("hana"), id)
  assert card.approvals.alternatives
    == [
      view.Alternative(sets: [domain.finance], have: 1, need: 2),
      view.Alternative(sets: [domain.head_of_finance], have: 0, need: 1),
    ]
  // Carl's one approval is still not enough; Hana's alone is.
  let assert Ok(known) = support.decide(second, id, "hana", Approve)
  let assert occurrence.Released(by: occurrence.ByValidator("hana"), ..) =
    known.status
  let assert Some(told) = support.told(second, id, 30_000)
  assert told.outcome == "paid"
  app.stop(second)
  provider.stop(settings.provider)
}

pub fn a_guard_that_lost_its_connection_at_the_wake_up_is_retried_test() {
  let key = "guard-" <> int.to_string(support.unique())
  let lost = process.new_subject()
  use running <- support.with_app("guard_lost", fn(s) {
    app.Settings(..s, guard_fault: fn() {
      case support.once(key) {
        True -> {
          process.send(lost, Nil)
          True
        }
        False -> False
      }
    })
  })
  // A small payout the policy accepted; its release waits for the hold.
  let id = support.ask(running, "r-guard", "O-2010", domain.won_by_seller, 4000)
  let assert occurrence.Held(..) = support.read(running, id).status
  // At the wake-up the guard cannot tell: nothing is refused, and the
  // wake-up is delivered again.
  let assert Ok(Nil) = process.receive(lost, 20_000)
  let assert Some(told) = support.told(running, id, 60_000)
  let known = support.read(running, id)
  let assert occurrence.Released(key: release, ..) = known.status
  assert told.outcome == "paid"
  assert provider.counts(running.settings.provider, release).payments == 1
  assert db.instructions_of(running.db, id) == Ok(1)
  // Nothing was recorded as refused: no refused release, no refused verdict.
  assert occurrence.refusals(known) == []
  assert !list.any(known.entries, fn(e) {
    case e.event {
      entry.Refused(..) -> True
      _ -> False
    }
  })
}

pub fn a_provider_timeout_is_settled_by_a_lookup_not_a_second_payment_test() {
  use running <- support.with_app("timeout", fn(s) {
    app.Settings(..s, provider_timeout_ms: 300)
  })
  provider.script(running.settings.provider, [provider.AnswerLost])
  let id = support.ask(running, "r-timeout", "O-2007", "partial", 8000)
  let assert Ok(_) = support.decide(running, id, "bia", Approve)
  let assert Some(told) = support.told(running, id, 30_000)
  let known = support.read(running, id)
  let assert occurrence.Released(key:, ..) = known.status
  // The record keeps both reports; the latest is the one that counts.
  let reports =
    list.filter_map(known.entries, fn(entry) {
      case entry.event {
        entry.Effected(effect) -> Ok(effect)
        _ -> Error(Nil)
      }
    })
  let assert [Uncertain(_), Performed(_)] = reports
  let counts = provider.counts(running.settings.provider, key)
  assert counts.pay_requests == 1
  assert counts.payments == 1
  assert counts.lookups == 1
  assert told.outcome == "paid"
}

pub fn withdraw_during_the_hold_and_after_it_test() {
  use running <- support.with_app("withdraw", fn(s) {
    app.Settings(..s, hold: duration.seconds(2))
  })
  let desk = app.payout_desk(running)
  let withdraw = fn(id, subject) {
    let assert Ok(validator) = db.validator(running.db, subject)
    decisions_postgres.transaction(running.db, decisions.withdraw_as(
      desk,
      _,
      occurrence: id,
      by: validator,
    ))
  }
  // A small payout the policy accepted on its own, held for two seconds.
  let first = support.ask(running, "r-w1", "O-2008", domain.won_by_seller, 4000)
  let assert occurrence.Held(by: occurrence.ByPolicy(1), ..) =
    support.read(running, first).status
  // Sam is not in finance: he may not take it back.
  let assert Error(decisions_postgres.Refused(decisions.NotTheDecider)) =
    withdraw(first, "sam")
  // Carl is: finance may withdraw what the policy accepted.
  let assert Ok(known) = withdraw(first, "carl")
  let assert occurrence.Withdrawn(by: "carl") = known.status
  let assert Some(told) = support.told(running, first, 20_000)
  assert told.outcome == "withdrawn"
  assert db.instructions_of(running.db, first) == Ok(0)

  let second =
    support.ask(running, "r-w2", "O-2009", domain.won_by_seller, 3000)
  process.sleep(2200)
  // The hold has ended by the store's clock, whether or not its wake-up
  // was delivered: too late.
  let assert Error(decisions_postgres.Refused(decisions.NotHeld)) =
    withdraw(second, "carl")
  let assert Some(told) = support.told(running, second, 20_000)
  assert told.outcome == "paid"
}

pub fn a_request_key_stays_within_the_store_bounds_test() {
  let longest = string.repeat("r", jobs.max_request_id_bytes)
  assert string.byte_size("release:" <> jobs.request_key(longest)) <= 255
  use running <- support.with_app("key_bound", fn(s) { s })
  let assert Error("a request id is at most 64 bytes") =
    app.request(
      running,
      world.request(longest <> "r", "O-2011"),
      requested_by: "fiona",
    )
}
