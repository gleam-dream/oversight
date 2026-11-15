//// The trigger is delivered at least once, and admission is by key: a
//// message delivered twice at once admits one message, one job and one
//// registration; two deliveries of the registration job make one
//// occurrence; a newer message from the same contact supersedes the
//// waiting recommendation.

import clinic_registration/app
import clinic_registration/domain
import clinic_registration/jobs
import clinic_registration/scripted
import clinic_registration/store
import decisions/occurrence
import decisions/vocabulary.{Superseded}
import gleam/dynamic/decode
import gleam/list
import gleam/string
import grind/worker
import support

pub fn a_message_delivered_twice_at_once_admits_one_registration_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)

  let admitted = support.race(2, fn(_) { app.admit(env.app, message) })
  assert list.count(admitted, fn(a) { a == Ok(jobs.Admitted([])) }) == 1
  assert list.count(admitted, fn(a) { a == Ok(jobs.Duplicate) }) == 1

  let _ = support.await_status(env, message.id, "awaiting")
  assert support.count(
      env,
      "SELECT count(*) FROM clinic_messages WHERE id = $1",
      [
        message.id,
      ],
    )
    == 1
  assert support.registrations(env) == 1
  assert support.count(
      env,
      "SELECT count(*) FROM clinic_jobs.grind_jobs
       WHERE worker_id = 'clinic.register' AND input #>> '{}' = $1",
      [message.id],
    )
    == 1
  assert scripted.llm_calls(env.services, phone) == 1

  // A third delivery, later, admits nothing either.
  assert app.admit(env.app, message) == Ok(jobs.Duplicate)
}

pub fn two_deliveries_of_the_registration_job_make_one_occurrence_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  // The message is kept without its job, so only these two deliveries run.
  let assert Ok(True) = store.insert_message(env.app.db, message)

  let outcomes =
    support.race(2, fn(_) { jobs.register(env.app.env, env.app.db, message.id) })
  assert list.all(outcomes, fn(outcome) {
    case outcome {
      worker.Succeeded(_) -> True
      _ -> False
    }
  })
  assert support.registrations(env) == 1
  let assert Ok(known) = support.read(env, message.id)
  assert occurrence.status_name(known.status) == "awaiting"
  // Both deliveries may have asked the model; the record keeps one answer.
  assert scripted.llm_calls(env.services, phone) <= 2
}

pub fn a_newer_message_supersedes_the_waiting_recommendation_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let first = support.message(phone, "Ana", "Oi, queria marcar uma consulta.")
  let waiting = support.arrive(env, first)

  let second = support.message(phone, "Ana", support.ana_says)
  let assert Ok(jobs.Admitted(superseded:)) = app.admit(env.app, second)
  assert superseded == [waiting.id]
  let assert Ok(expired) = support.read(env, first.id)
  assert expired.status == occurrence.Expired(Superseded(domain.newer_message))

  // The newer message's registration reads the whole conversation.
  let next = support.await_status(env, second.id, "awaiting")
  let #(_, card) = support.open(env, next.id, support.felipe)
  assert support.field(
      card,
      ["context", "conversation", "lines"],
      decode.list(decode.at(["text"], decode.string)),
    )
    == ["Oi, queria marcar uma consulta.", support.ana_says]
}

pub fn a_message_id_too_long_for_a_key_is_bounded_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  // The store refuses an occurrence id over 255 bytes; the channel's ids
  // are its own.
  let long_id = string.repeat("x", 300) <> support.tag("-")
  let message =
    domain.Inbound(
      ..support.message(phone, "Ana", support.ana_says),
      id: long_id,
    )
  let known = support.arrive(env, message)
  assert string.byte_size(known.id) < 255
  assert known.id == domain.key(long_id)
}
