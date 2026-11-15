//// One registration from message to confirmation, through the desk's HTTP
//// API: policy version 1 asks reception, Felipe opens the card, corrects
//// the birth date, the patient row is inserted in his verdict's
//// transaction, and Ana's confirmation is sent once under the release key.

import clinic_registration/scripted
import clinic_registration/store
import clinic_registration/telemetry
import decisions/occurrence
import decisions/vocabulary.{Performed}
import gleam/dynamic/decode
import gleam/http
import gleam/list
import gleam/option.{Some}
import gleam/string
import support

pub fn a_message_becomes_a_patient_and_a_confirmation_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(scripted.extraction(
      name: "Ana Souza",
      birth_date: Some("1990-12-04"),
      phone:,
      insurer: Some("Unimed"),
      plan: Some("Unimed Flex"),
      confidence: 0.82,
    )),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  let waiting = support.arrive(env, message)

  // Policy version 1 asks reception; the queue shows the card.
  assert waiting.policy_version == Some(1)
  let queue = support.call(env, http.Get, "/queue", support.felipe, "")
  assert queue.status == 200
  assert support.field(
      queue.body,
      ["cards"],
      decode.list(decode.at(["occurrence"], decode.string)),
    )
    |> list.contains(waiting.id)

  // The card shows the context the model had, read by the model's own
  // reader from the record: the conversation, no similar patient, and the
  // accepted insurers.
  let #(seen, card) = support.open(env, waiting.id, support.felipe)
  assert support.field(
      card,
      ["context", "conversation", "lines"],
      decode.list(decode.at(["text"], decode.string)),
    )
    == [support.ana_says]
  assert support.field(
      card,
      ["context", "accepted_insurers"],
      decode.list(decode.string),
    )
    == support.insurers
  assert support.field(
      card,
      ["context", "similar_patients"],
      decode.list(decode.dynamic),
    )
    == []
  assert support.field(
      card,
      ["card", "standing_output", "birth_date"],
      decode.string,
    )
    == "1990-12-04"
  assert support.field(
      card,
      ["card", "approvals", "by"],
      decode.list(decode.string),
    )
    == []
  assert string.contains(
    support.field(card, ["model_exchange", "request"], decode.string),
    support.ana_says,
  )

  // Felipe corrects the birth date: Ana wrote 12/04, the 12th of April.
  let corrected =
    "{\"t\":\"correct\",\"reason\":{\"category\":\"wrong_field\",\"note\":\"dd/mm\"},"
    <> "\"output\":{\"name\":\"Ana Souza\",\"birth_date\":\"1990-04-12\",\"phone\":\""
    <> phone
    <> "\",\"coverage\":{\"insurer\":\"Unimed\",\"plan\":\"Unimed Flex\"},\"consent\":true}}"
  let decided =
    support.verdict(env, waiting.id, support.felipe, seen, corrected)
  assert decided.status == 200
  assert support.field(decided.body, ["status"], decode.string) == "released"

  // The patient row is the corrected record, registered by Felipe.
  let assert Ok([patient]) = store.patients_with_phone(env.app.db, phone)
  assert patient.birth_date == "1990-04-12"
  assert patient.registered_by == "felipe"
  assert patient.id == waiting.id

  // The guard's evidence is on the release.
  let known = support.await_status(env, message.id, "released")
  assert occurrence.relied(known) != []

  // The confirmation is sent once, under the release key, and reported.
  assert support.eventually(5000, fn() {
    case support.read(env, message.id) {
      Ok(known) ->
        case occurrence.effect(known) {
          Some(Performed(_)) -> True
          _ -> False
        }
      Error(_) -> False
    }
  })
  let assert occurrence.Released(key:, ..) = known.status
  assert scripted.sends(env.services, key) == 1
  let assert [sent] =
    list.filter(scripted.sent(env.services), fn(sent) { sent.to == phone })
  assert string.contains(sent.text, "Olá Ana")

  // The application's own events, in order.
  let lines = telemetry.mentioning(env.app.collector, waiting.id)
  assert list.any(lines, string.contains(_, "awaiting under policy v1"))
  assert list.any(lines, string.contains(_, "felipe corrected"))
  assert list.any(lines, string.contains(_, "settlement notice delivered"))
  assert list.any(lines, string.contains(_, "performed"))
}
