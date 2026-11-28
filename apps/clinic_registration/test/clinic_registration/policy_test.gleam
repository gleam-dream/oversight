//// The policy is data in versions. Each version is checked against the
//// point's declared facts before it is stored. Version 1 asks reception;
//// version 2 lets a sure registration proceed and sends a possible
//// duplicate to the manager. A registration that waits 30 minutes
//// escalates, also across a restart of the runtime, and a verdict after
//// the 24-hour validity is refused.

import clinic_registration/app
import clinic_registration/desk
import clinic_registration/domain
import clinic_registration/jobs
import clinic_registration/scripted
import clinic_registration/store
import clinic_registration/telemetry
import decisions
import decisions/fact
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Never, Proceed, When}
import decisions/vocabulary.{
  DeadlinePassed, Flag, ModelCall, Performed, Superseded,
}
import decisions_postgres
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import support

/// A registration the model reported without the insurer's answer cannot
/// be read by the rule that lets a sure registration proceed, so reception
/// is asked, and stays the one asked after the escalation's 30 minutes:
/// the reading stops at the first condition it cannot tell.
pub fn a_registration_missing_a_fact_asks_reception_test() {
  let without_insurer = [
    fact.set(domain.confidence(), 0.99),
    fact.set(domain.missing_fields(), 0.0),
    fact.set(domain.similar_patient(), False),
    fact.set(domain.consent(), True),
  ]
  let model = ModelCall(configuration: "registration", version: "1")
  let #(now, _) =
    policy.timeline(
      domain.proceed_when_sure(),
      model,
      without_insurer,
      waited: 0,
    )
  assert now == Ask(AnyoneHolding(domain.reception))
  let #(later, _) =
    policy.timeline(
      domain.proceed_when_sure(),
      model,
      without_insurer,
      waited: 45,
    )
  assert later == Ask(AnyoneHolding(domain.reception))
}

pub fn a_policy_version_is_checked_before_it_is_stored_test() {
  use env <- support.with_app(fn(config) { config })
  let assert Ok(misspelt) =
    policy.new(
      version: 3,
      rules: [
        When(
          policy.AtLeast("confidense", 0.9),
          Proceed(sample: Never, hold: None),
        ),
      ],
      otherwise: AnyoneHolding(domain.reception),
    )
  let assert Error(desk.Unpublishable([policy.UndeclaredFact("confidense")])) =
    desk.publish(env.app.db, misspelt)
  let assert Ok(wrong_kind) =
    policy.new(
      version: 3,
      rules: [
        When(
          policy.Is("confidence", Flag(True)),
          Proceed(sample: Never, hold: None),
        ),
      ],
      otherwise: AnyoneHolding(domain.reception),
    )
  let assert Error(desk.Unpublishable([policy.WrongKind(fact: "confidence", ..)])) =
    desk.publish(env.app.db, wrong_kind)
  let assert Error(desk.NotStored(_)) =
    desk.publish(env.app.db, domain.always_ask())
  assert store.policy_versions(env.app.db, domain.point_name) == Ok([1])
  let assert Ok(Nil) = desk.publish(env.app.db, domain.proceed_when_sure())
  assert store.policy_versions(env.app.db, domain.point_name) == Ok([1, 2])
}

pub fn version_2_lets_a_sure_registration_proceed_after_its_undo_window_test() {
  use env <- support.with_restarts
  let assert Ok(Nil) = desk.publish(env.app.db, domain.proceed_when_sure())

  // Sure, complete, consented, accepted insurer, nobody similar: the
  // policy accepts it and holds it for the undo window.
  let sure = support.phone()
  scripted.script(env.services, sure, [
    scripted.Answer(support.ana_answer(sure)),
  ])
  let message = support.message(sure, "Ana", support.ana_says)
  let assert Ok(_) = app.admit(env.app, message)
  let held = support.await_status(env, message.id, "held")
  assert held.policy_version == Some(2)
  assert store.patients_with_phone(env.app.db, sure) == Ok([])
  // Unsure: reception decides.
  let unsure = support.phone()
  scripted.script(env.services, unsure, [
    scripted.Answer(scripted.extraction(
      name: "Bruno Lima",
      birth_date: Some("1985-02-01"),
      phone: unsure,
      insurer: Some("Unimed"),
      plan: Some("Unimed Flex"),
      confidence: 0.6,
    )),
  ])
  let waiting =
    support.arrive(env, support.message(unsure, "Bruno", "Quero marcar."))
  let assert occurrence.Awaiting(AnyoneHolding("reception")) = waiting.status

  // An insurer the clinic does not accept: reception decides.
  let other = support.phone()
  scripted.script(env.services, other, [
    scripted.Answer(scripted.extraction(
      name: "Carla Reis",
      birth_date: Some("1979-07-30"),
      phone: other,
      insurer: Some("Golden Cross"),
      plan: Some("Essencial"),
      confidence: 0.97,
    )),
  ])
  let waiting =
    support.arrive(env, support.message(other, "Carla", "Quero marcar."))
  let assert occurrence.Awaiting(AnyoneHolding("reception")) = waiting.status

  // Eleven minutes later the undo window has ended: the registration is
  // released by the policy, the patient row is written, Ana is told.
  let #(env, delivered) = support.later(env, 11)
  assert delivered >= 1
  let released = support.await_status(env, message.id, "released")
  let assert occurrence.Released(by: occurrence.ByPolicy(2), ..) =
    released.status
  let assert Ok([patient]) = store.patients_with_phone(env.app.db, sure)
  assert patient.registered_by == "policy v2"
  assert support.eventually(5000, fn() {
    case support.read(env, message.id) {
      Ok(known) ->
        case occurrence.effect(known) {
          Some(Performed(_)) -> True
          _ -> False
        }
      _ -> False
    }
  })
  env
}

pub fn reception_takes_back_a_registration_during_its_undo_window_test() {
  use env <- support.with_restarts
  let assert Ok(Nil) = desk.publish(env.app.db, domain.proceed_when_sure())
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  let assert Ok(_) = app.admit(env.app, message)
  let held = support.await_status(env, message.id, "held")

  // A manager may not; reception may.
  let refused =
    support.call(
      env,
      http.Post,
      "/cards/" <> held.id <> "/withdraw",
      support.marta,
      "",
    )
  assert refused.status == 403
  let withdrawn =
    support.call(
      env,
      http.Post,
      "/cards/" <> held.id <> "/withdraw",
      support.felipe,
      "",
    )
  assert withdrawn.status == 200
  assert support.field(withdrawn.body, ["status"], decode.string) == "withdrawn"

  // After the window nothing is released, written or sent.
  let #(env, _) = support.later(env, 11)
  assert support.status_of(env, message.id) == "withdrawn"
  assert store.patients_with_phone(env.app.db, phone) == Ok([])
  process.sleep(300)
  assert !list.any(scripted.sent(env.services), fn(sent) { sent.to == phone })
  env
}

pub fn a_newer_message_supersedes_a_held_registration_test() {
  use env <- support.with_restarts
  let assert Ok(Nil) = desk.publish(env.app.db, domain.proceed_when_sure())
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
    scripted.Answer(scripted.extraction(
      name: "Ana Souza",
      birth_date: Some("1990-04-12"),
      phone:,
      insurer: Some("Unimed"),
      plan: Some("Unimed Flex"),
      confidence: 0.5,
    )),
  ])
  let first = support.message(phone, "Ana", support.ana_says)
  let assert Ok(_) = app.admit(env.app, first)
  let held = support.await_status(env, first.id, "held")

  // Ana writes again during the undo window: the held registration is
  // superseded, and the new message is registered on its own.
  let second = support.message(phone, "Ana", "Na verdade é Unimed Nacional.")
  let assert Ok(jobs.Admitted(superseded:)) = app.admit(env.app, second)
  assert list.contains(superseded, held.id)
  let assert Ok(expired) = support.read(env, first.id)
  assert expired.status == occurrence.Expired(Superseded(domain.newer_message))
  let _ = support.await_status(env, second.id, "awaiting")

  // After the window nothing of the first registration is released.
  let #(env, _) = support.later(env, 11)
  assert support.status_of(env, first.id) == "expired"
  assert store.patients_with_phone(env.app.db, phone) == Ok([])
  env
}

pub fn a_possible_duplicate_asks_the_manager_test() {
  use env <- support.with_app(fn(config) { config })
  let assert Ok(Nil) = desk.publish(env.app.db, domain.proceed_when_sure())
  // Ana is already a patient, under her old phone.
  let assert Ok(Nil) =
    store.insert_patient(
      env.app.db,
      id: support.tag("patient-"),
      registration: domain.Registration(
        name: "Ana Souza",
        birth_date: Some("1990-04-12"),
        phone: support.phone(),
        coverage: option.None,
        consent: True,
      ),
      birth_date: "1990-04-12",
      by: "import",
    )
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let waiting =
    support.arrive(env, support.message(phone, "Ana Souza", support.ana_says))
  let assert occurrence.Awaiting(AnyoneHolding("manager")) = waiting.status

  // Felipe neither sees nor opens it; Marta does, and sees the patient
  // the lookup found.
  let queued = fn(validator) {
    support.call(env, http.Get, "/queue", validator, "").body
    |> support.field(
      ["cards"],
      decode.list(decode.at(["occurrence"], decode.string)),
    )
  }
  assert !list.contains(queued(support.felipe), waiting.id)
  assert list.contains(queued(support.marta), waiting.id)
  let refused =
    support.call(
      env,
      http.Post,
      "/cards/" <> waiting.id <> "/open",
      support.felipe,
      "",
    )
  assert refused.status == 403
  let #(_, card) = support.open(env, waiting.id, support.marta)
  assert support.field(
      card,
      ["context", "similar_patients"],
      decode.list(decode.at(["name"], decode.string)),
    )
    == ["Ana Souza"]
}

pub fn an_escalation_pending_across_a_restart_is_delivered_test() {
  let assert Ok(services) = scripted.start()
  let url = support.fresh_database()
  let first = support.boot(services, url, fn(config) { config })
  let phone = support.phone()
  scripted.script(services, phone, [scripted.Answer(support.ana_answer(phone))])
  let message = support.message(phone, "Ana", support.ana_says)
  let waiting = support.arrive(first, message)
  let assert occurrence.Awaiting(AnyoneHolding("reception")) = waiting.status
  app.stop(first.app)

  // While nothing runs, the escalation is a pending wake-up and a Grind
  // job due in 30 minutes on the database's clock. The runtime starts
  // again half an hour later by the store's clock, and the wake-ups due on
  // that clock are delivered through the wake worker's own code path.
  let second =
    support.boot(services, url, fn(config) {
      app.Config(..config, clock_offset: duration.minutes(31))
    })
  let assert Ok(delivered) =
    decisions_postgres.deliver_due(
      second.app.records,
      second.app.pool,
      [decisions.waker(second.app.desk)],
      limit: 10,
    )
  assert delivered == 1
  assert support.eventually(15_000, fn() {
    case support.read(second, message.id) {
      Ok(known) ->
        case known.status {
          occurrence.Awaiting(policy.Either(_)) -> True
          _ -> False
        }
      Error(_) -> False
    }
  })
  let marta_sees =
    support.call(second, http.Get, "/queue", support.marta, "").body
    |> support.field(
      ["cards"],
      decode.list(decode.at(["occurrence"], decode.string)),
    )
  assert list.contains(marta_sees, waiting.id)
  app.stop(second.app)
  scripted.stop(services)
}

pub fn a_wake_up_whose_job_was_lost_is_swept_and_delivered_test() {
  let assert Ok(services) = scripted.start()
  let url = support.fresh_database()
  // Recommended as if 29 minutes 56 seconds ago: by the store's clock the
  // escalation falls due 4 seconds from now.
  let first =
    support.boot(services, url, fn(config) {
      app.Config(..config, clock_offset: duration.seconds(-{ 30 * 60 - 4 }))
    })
  let phone = support.phone()
  scripted.script(services, phone, [scripted.Answer(support.ana_answer(phone))])
  let message = support.message(phone, "Ana", support.ana_says)
  let waiting = support.arrive(first, message)
  app.stop(first.app)

  // The runtime starts again with its jobs lost: a Grind schema of its own
  // that holds none of them. The wake-up rows are still pending, so the
  // start-up sweep admits a job for each (the escalation and the validity),
  // and Grind delivers the escalation when it falls due.
  let second =
    support.boot(services, url, fn(config) {
      app.Config(..config, jobs_schema: "clinic_jobs_after_loss")
    })
  assert second.app.swept.wakes == 2
  assert support.eventually(15_000, fn() {
    case support.read(second, message.id) {
      Ok(known) ->
        case known.status {
          occurrence.Awaiting(policy.Either(_)) -> True
          _ -> False
        }
      Error(_) -> False
    }
  })
  assert telemetry.mentioning(
      second.app.collector,
      "wake-up delivered for " <> waiting.id,
    )
    != []
  app.stop(second.app)
  scripted.stop(services)
}

pub fn a_verdict_after_the_validity_passed_is_refused_test() {
  let assert Ok(services) = scripted.start()
  let url = support.fresh_database()
  let first = support.boot(services, url, fn(config) { config })
  let phone = support.phone()
  scripted.script(services, phone, [scripted.Answer(support.ana_answer(phone))])
  let message = support.message(phone, "Ana", support.ana_says)
  let waiting = support.arrive(first, message)
  let #(seen, _) = support.open(first, waiting.id, support.felipe)

  // The same clinic a day and a minute later, by the store's clock.
  let later =
    support.restart(first, fn(config) {
      app.Config(..config, clock_offset: duration.minutes(24 * 60 + 1))
    })
  let late =
    support.verdict(
      later,
      waiting.id,
      support.felipe,
      seen,
      "{\"t\":\"approve\"}",
    )
  assert late.status == 410
  assert support.field(late.body, ["error"], decode.string) == "not_awaiting"
  let reopened =
    support.call(
      later,
      http.Post,
      "/cards/" <> waiting.id <> "/open",
      support.felipe,
      "",
    )
  assert reopened.status == 410
  assert store.patients_with_phone(later.app.db, phone) == Ok([])

  // The validity wake-up, delivered now, expires it.
  let assert Ok(decisions.Woken(expired)) =
    decisions_postgres.refusing(later.app.pool, decisions.wake(
      later.app.desk,
      _,
      occurrence: waiting.id,
    ))
  assert expired.status == occurrence.Expired(DeadlinePassed)
  app.stop(later.app)
  scripted.stop(services)
}
