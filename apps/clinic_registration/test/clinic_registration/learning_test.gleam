//// Learning from the record. Six registrations under version 1: four
//// approved, one corrected, one rejected. They are exported as examples,
//// agreement is tallied, the examples are replayed against other
//// configurations, a changed read is flagged as drift, and agreement is
//// the gate for publishing version 2.

import clinic_registration/app
import clinic_registration/evaluation.{Gate}
import clinic_registration/llm
import clinic_registration/scripted
import clinic_registration/store
import decisions/learning
import decisions/model
import decisions/occurrence
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/time/timestamp
import support

fn batch(env: support.Env) -> Nil {
  list.each([0, 1, 2, 3, 4, 5], fn(n) {
    let phone = support.phone()
    scripted.script(env.services, phone, [
      scripted.Answer(support.ana_answer(phone)),
    ])
    let waiting =
      support.arrive(
        env,
        support.message(
          phone,
          "Paciente " <> int.to_string(n),
          support.ana_says,
        ),
      )
    let #(seen, _) = support.open(env, waiting.id, support.felipe)
    let verdict = case n {
      4 ->
        "{\"t\":\"correct\",\"reason\":{\"category\":\"wrong_field\",\"note\":null},"
        <> "\"output\":{\"name\":\"Ana Souza\",\"birth_date\":\"1990-12-04\",\"phone\":\""
        <> phone
        <> "\",\"coverage\":{\"insurer\":\"Unimed\",\"plan\":\"Unimed Flex\"},\"consent\":true}}"
      5 -> "{\"t\":\"reject\",\"reason\":{\"category\":\"spam\",\"note\":null}}"
      _ -> "{\"t\":\"approve\"}"
    }
    let assert 200 =
      support.verdict(env, waiting.id, support.felipe, seen, verdict).status
  })
}

pub fn the_record_teaches_and_gates_version_2_test() {
  use env <- support.with_app(fn(config) { config })
  batch(env)
  let assert Ok(recorded) = evaluation.recorded(env.app.db, env.app.desk)
  assert list.length(recorded) == 6

  // Export: one self-contained document per registration, holding the
  // provider exchange as a read.
  let assert Ok(examples) =
    evaluation.export(env.app.db, recorded, as_of: timestamp.system_time())
  let documents = evaluation.documents(examples)
  assert list.length(documents) == 6
  let assert [first, ..] = documents
  let text = json.to_string(first)
  assert support.field(text, ["format"], decode.string) == "decision-example.v1"
  assert support.field(
      text,
      ["reads"],
      decode.list(decode.at(["name"], decode.string)),
    )
    |> list.contains(llm.call_read)

  // Agreement: four of the five let through unchanged, and one rejection.
  let agreement = evaluation.agreement(recorded)
  assert agreement.agreed == 4
  assert agreement.judged == 5
  assert agreement.rejected == 1

  // The configuration in production replays to the same agreement.
  let provider = env.app.env.provider
  let same = evaluation.replay(examples, llm.first(), provider)
  assert same.unanswered == []
  assert same.tally.judged == 5
  assert same.tally.agreed == 4

  // The same request read differently: the record answers it.
  let reread =
    evaluation.replay(examples, llm.same_request_other_reading(), provider)
  assert reread.unanswered == []

  // Another prompt sends other bytes: the record holds no answer.
  let other = evaluation.replay(examples, llm.second_prompt(), provider)
  assert list.length(other.unanswered) == 6
  assert list.all(other.unanswered, fn(pair) {
    case pair.1 {
      model.NotRecorded(read: "llm_wire.call", ..) -> True
      _ -> False
    }
  })
  assert other.tally == learning.nothing
  // A re-run asks the provider on the recorded context.
  let rerun =
    evaluation.rerun(
      env.app.db,
      examples,
      llm.second_prompt(),
      provider,
      env.app.http,
    )
  assert rerun.unanswered == []
  assert rerun.tally.judged == 5

  // Drift: each registration that was released changed its own lookup,
  // because the patient now exists. The rejected one did not.
  let drifted = evaluation.drift(examples, llm.latest(env.app.db))
  assert list.length(drifted) == 5
  assert list.all(drifted, fn(drift) { drift.read == llm.similar_read })
  // Then the clinic stops accepting an insurer: every example's insurer
  // list no longer matches.
  let assert Ok(Nil) = store.drop_insurer(env.app.db, "SulAmérica")
  let drifted = evaluation.drift(examples, llm.latest(env.app.db))
  assert list.count(drifted, fn(drift) { drift.read == llm.insurers_read }) == 6

  // The gate: too few, too little, then enough.
  let assert Error(evaluation.TooFewJudged(judged: 6, needed: 20)) =
    evaluation.promote(
      env.app.db,
      agreement,
      Gate(min_judged: 20, min_agreement: 0.6),
    )
    |> unwrap_closed
  let assert Error(evaluation.TooLittleAgreement(..)) =
    evaluation.promote(
      env.app.db,
      agreement,
      Gate(min_judged: 5, min_agreement: 0.9),
    )
    |> unwrap_closed
  assert store.policy_versions(env.app.db, "registration") == Ok([1])
  let assert Ok(Nil) =
    evaluation.promote(
      env.app.db,
      agreement,
      Gate(min_judged: 5, min_agreement: 0.6),
    )
  assert store.policy_versions(env.app.db, "registration") == Ok([1, 2])

  // Under version 2 a sure registration proceeds, held for its undo
  // window.
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  let assert Ok(_) = app.admit(env.app, message)
  let held = support.await_status(env, message.id, "held")
  assert held.policy_version == Some(2)
  assert occurrence.final(held) != option.None

  // Every message expected a registration, and none is still waiting.
  let assert Ok(coverage) = evaluation.coverage(env.app.db, env.app.desk)
  assert coverage
    == learning.Coverage(expected: 7, superseded_before: 0, still_expected: 0)
}

fn unwrap_closed(
  promoted: Result(Nil, evaluation.PromotionError),
) -> Result(Nil, evaluation.Closed) {
  case promoted {
    Ok(Nil) -> Ok(Nil)
    Error(evaluation.GateClosed(closed)) -> Error(closed)
    Error(evaluation.NotPublished(_)) -> panic as "the gate was open"
  }
}
