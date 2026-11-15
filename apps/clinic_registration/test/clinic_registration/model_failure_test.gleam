//// The model runs outside any transaction, with a deadline. A provider
//// failure, an undecodable answer or a missed deadline is a failed
//// attempt on the record, and the job tries again; the card shows the
//// attempts. A worker killed after the model answered and before the
//// recommendation committed leaves nothing, and the replayed job
//// recommends once.

import clinic_registration/app
import clinic_registration/scripted
import decisions
import decisions/model
import decisions/occurrence
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/time/duration
import support

fn failures(known: occurrence.Occurrence(a)) -> List(model.Failure) {
  list.map(known.attempts, fn(attempt) { attempt.failure })
}

pub fn a_provider_failure_is_an_attempt_and_the_job_retries_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Status(503),
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  let known = support.arrive(env, message)

  let assert [model.ProviderFailed(..)] = failures(known)
  assert scripted.llm_calls(env.services, phone) == 2
  let #(_, card) = support.open(env, known.id, support.felipe)
  assert list.length(support.field(
      card,
      ["attempts"],
      decode.list(decode.string),
    ))
    == 1
}

pub fn an_undecodable_answer_is_an_attempt_with_its_exchange_kept_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.NotStructured("Acho que o nome dela é Ana."),
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  let known = support.arrive(env, message)

  let assert [model.Undecodable(_)] = failures(known)
  // Both exchanges are evidence; only the second one is on the
  // recommendation.
  assert support.count(
      env,
      "SELECT count(*) FROM clinic_evidence WHERE kind = 'llm_wire.call'",
      [],
    )
    == 2
}

pub fn a_missed_deadline_is_an_attempt_test() {
  use env <- support.with_app(fn(config) {
    app.Config(..config, model_deadline: duration.milliseconds(300))
  })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Stall(900, scripted.Answer(support.ana_answer(phone))),
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  let known = support.arrive(env, message)
  let assert [model.Deadline(_)] = failures(known)
}

pub fn every_attempt_failing_leaves_the_attempts_on_the_record_test() {
  use env <- support.with_app(fn(config) {
    app.Config(..config, max_attempts: 2)
  })
  let phone = support.phone()
  scripted.script(env.services, phone, [scripted.Status(503)])
  let message = support.message(phone, "Ana", support.ana_says)
  let assert Ok(_) = app.admit(env.app, message)

  assert support.eventually(8000, fn() {
    case support.read(env, message.id) {
      Error(decisions.NotRecommended(attempts:)) -> list.length(attempts) == 2
      _ -> False
    }
  })
  // No third attempt.
  process.sleep(800)
  let assert Error(decisions.NotRecommended(attempts:)) =
    support.read(env, message.id)
  assert list.length(attempts) == 2
  assert scripted.llm_calls(env.services, phone) == 2
}

pub fn a_worker_killed_after_the_model_answered_recommends_once_test() {
  let key = support.tag("kill-after-model-")
  use env <- support.with_app(fn(config) {
    app.Config(..config, after_model: fn(_) {
      case support.once(key) {
        True -> process.kill(process.self())
        False -> Nil
      }
    })
  })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  let assert Ok(_) = app.admit(env.app, message)

  // The first attempt dies before its transaction: nothing is on the
  // record. Grind replays it once its lease expires.
  assert support.eventually(1500, fn() {
    scripted.llm_calls(env.services, phone) == 1
  })
  assert support.status_of(env, message.id) == "absent"
  assert support.eventually(15_000, fn() {
    support.status_of(env, message.id) == "awaiting"
  })
  let assert Ok(known) = support.read(env, message.id)
  assert known.attempts == []
  assert scripted.llm_calls(env.services, phone) == 2
  assert support.registrations(env) == 1
}
