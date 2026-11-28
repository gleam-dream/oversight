//// The trigger is delivered at least once, and admission is by key: a
//// message delivered twice at once admits one message, one job and one
//// registration; two deliveries of the registration job make one
//// occurrence; a newer message from the same contact supersedes the
//// waiting recommendation.

import clinic_registration/app
import clinic_registration/domain
import clinic_registration/evaluation
import clinic_registration/jobs
import clinic_registration/llm
import clinic_registration/scripted
import clinic_registration/store
import clinic_registration/telemetry
import decisions
import decisions/learning
import decisions/occurrence
import decisions/vocabulary.{ModelCall, Recommendation, RuleFired, Superseded}
import decisions_postgres
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
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

/// Ana's first message; her model call is still running when she writes
/// again. Returns the first message, the second, and the first's key.
fn overtaken(env: support.Env) -> #(domain.Inbound, domain.Inbound) {
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Stall(1500, scripted.Answer(support.ana_answer(phone))),
    scripted.Answer(support.ana_answer(phone)),
  ])
  let first = support.message(phone, "Ana", "Oi, queria marcar uma consulta.")
  let assert Ok(_) = app.admit(env.app, first)
  // The first message's model call has started and not answered yet.
  assert support.eventually(3000, fn() {
    scripted.llm_calls(env.services, phone) == 1
  })
  let second = support.message(phone, "Ana", support.ana_says)
  let assert Ok(jobs.Admitted(superseded:)) = app.admit(env.app, second)
  // What the first message expected is superseded before it began.
  assert superseded == [domain.key(first.id)]
  #(first, second)
}

pub fn an_older_model_call_finishing_late_leaves_no_waiting_card_test() {
  use env <- support.with_app(fn(config) { config })
  let #(first, second) = overtaken(env)
  let next = support.await_status(env, second.id, "awaiting")

  // The first message's model answers after the second arrived: the
  // record refuses its recommendation, and only the second card waits.
  process.sleep(1800)
  assert telemetry.mentioning(
      env.app.collector,
      "recommended " <> domain.key(first.id),
    )
    == []
  let assert Ok(decisions.NotBegun(pending)) =
    decisions_postgres.refusing(env.app.pool, decisions.read_record(
      env.app.desk,
      _,
      key: domain.key(first.id),
    ))
  assert pending.ended == Some(Superseded(domain.newer_message))
  let cards =
    support.call(env, http.Get, "/queue", support.felipe, "").body
    |> support.field(
      ["cards"],
      decode.list(decode.at(["occurrence"], decode.string)),
    )
  assert cards == [next.id]
  // The operator's coverage: two messages expected, one superseded before
  // its recommendation, none still waiting.
  let assert Ok(coverage) = evaluation.coverage(env.app.pool, env.app.desk)
  assert coverage
    == learning.Coverage(
      expected: 2,
      superseded_before: 1,
      lapsed_before: 0,
      still_expected: 0,
    )
}

pub fn a_late_recommendation_is_refused_and_writes_nothing_test() {
  use env <- support.with_app(fn(config) { config })
  let #(first, _) = overtaken(env)
  let key = domain.key(first.id)
  let assert Ok(before) =
    decisions_postgres.refusing(env.app.pool, decisions.read_record(
      env.app.desk,
      _,
      key:,
    ))

  let late =
    decisions_postgres.transaction(env.app.pool, decisions.recommend_once(
      env.app.desk,
      _,
      key:,
      proposal: decisions.proposal(
        trigger: domain.trigger(first.id),
        about: domain.subject(first.contact),
        context: llm.manifest(first),
        recommending: Recommendation(
          output: domain.registration_of(
            support.ana_answer(first.contact),
            first.contact,
          ),
          by: ModelCall(configuration: "registration-extractor", version: "1"),
          explanation: RuleFired("late"),
          signals: [],
          reads: [],
        ),
      ),
    ))
  let assert Error(decisions_postgres.Refused(decisions.SupersededBefore(
    event: "newer_message",
  ))) = late
  let assert Ok(after) =
    decisions_postgres.refusing(env.app.pool, decisions.read_record(
      env.app.desk,
      _,
      key:,
    ))
  assert after == before
}

pub fn a_notice_for_a_record_superseded_before_it_began_ends_delivered_test() {
  use env <- support.with_app(fn(config) { config })
  let #(first, _) = overtaken(env)
  let #(_, follow) =
    jobs.follower(env.app.env, jobs.confirm_worker(env.app.env))
  let assert Error(decisions_postgres.OwnFailed(failure)) =
    decisions_postgres.transaction_with(env.app.pool, fn(tx) {
      follow(tx, domain.key(first.id))
      |> result.map_error(decisions_postgres.Own)
    })
  let assert decisions.DeskRefused(decisions.SupersededBefore(..)) = failure
  // A dropped notice: delivered, nothing follows.
  assert decisions.handling(failure) == decisions.Drop
}

pub fn two_messages_from_one_contact_at_once_leave_one_expected_test() {
  use env <- support.with_app(fn(config) { config })
  // Twenty rounds; in each, two different messages from one contact are
  // admitted by two processes released together.
  list.each(int_range(20), fn(_) {
    let phone = support.phone()
    scripted.script(env.services, phone, [
      scripted.Answer(support.ana_answer(phone)),
    ])
    let messages = [
      support.message(phone, "Ana", "Oi, queria marcar uma consulta."),
      support.message(phone, "Ana", support.ana_says),
    ]
    let admitted =
      support.race(2, fn(n) {
        let assert Ok(message) = list.drop(messages, n) |> list.first
        app.admit(env.app, message)
      })
    assert list.all(admitted, fn(result) {
      case result {
        Ok(jobs.Admitted(..)) -> True
        _ -> False
      }
    })
    // Exactly one registration stays: the other was superseded before
    // anything was recommended for it.
    let records =
      list.map(messages, fn(message) {
        let assert Ok(record) =
          decisions_postgres.refusing(env.app.pool, decisions.read_record(
            env.app.desk,
            _,
            key: domain.key(message.id),
          ))
        record
      })
    let superseded =
      list.filter(records, fn(record) {
        case record {
          decisions.NotBegun(pending) -> pending.ended != None
          decisions.Begun(_) -> False
        }
      })
    assert list.length(superseded) == 1
    // The one that stays was admitted second, so its conversation holds
    // both messages.
    let assert Ok(survivor) =
      list.find(messages, fn(message) {
        case
          decisions_postgres.refusing(env.app.pool, decisions.read_record(
            env.app.desk,
            _,
            key: domain.key(message.id),
          ))
        {
          Ok(decisions.NotBegun(pending)) -> pending.ended == None
          Ok(decisions.Begun(_)) -> True
          Error(_) -> False
        }
      })
    let waiting = support.await_status(env, survivor.id, "awaiting")
    let #(_, card) = support.open(env, waiting.id, support.felipe)
    assert list.length(support.field(
        card,
        ["context", "conversation", "lines"],
        decode.list(decode.dynamic),
      ))
      == 2
  })
}

pub fn an_admission_that_waits_too_long_for_the_contact_is_delivered_again_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  // Another transaction, on a pool of its own, holds the library's lock
  // on Ana for 6 s, longer than the store waits for a lock (4 s).
  let held = process.new_subject()
  process.spawn(fn() {
    support.with_pool(env.url, fn(db) {
      decisions_postgres.transaction(db, fn(tx) {
        let assert Ok(_) =
          decisions_postgres.port(env.app.records).load(
            tx,
            decisions.subject_lock(
              point: domain.point_name,
              subject: domain.subject(phone),
            ),
          )
        process.send(held, Nil)
        process.sleep(6000)
        Ok(Nil)
      })
    })
  })
  let assert Ok(Nil) = process.receive(held, 5000)
  let body =
    "{\"id\":\""
    <> message.id
    <> "\",\"from\":\""
    <> phone
    <> "\",\"profile_name\":\"Ana\",\"text\":\"Oi\"}"
  let first = support.deliver(env, body)
  // The admission ended as contention and kept nothing: the channel is
  // told to deliver it again.
  assert first.status == 503
  assert support.status_of(env, message.id) == "absent"
  // Delivered again once the other transaction ended, it is admitted.
  process.sleep(2500)
  let again = support.deliver(env, body)
  assert again.status == 202
  let _ = support.await_status(env, message.id, "awaiting")
}

fn int_range(count: Int) -> List(Int) {
  int.range(from: count - 1, to: -1, with: [], run: list.prepend)
}
