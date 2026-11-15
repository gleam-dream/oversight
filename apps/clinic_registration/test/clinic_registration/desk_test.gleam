//// The desk over HTTP: who may act, a card made stale by someone else's
//// correction, a rejection, and the gated tool refusing a duplicate that
//// appeared while the card was open.

import clinic_registration/desk
import clinic_registration/domain
import clinic_registration/scripted
import clinic_registration/store
import clinic_registration/telemetry
import decisions/occurrence
import decisions/policy.{AnyoneHolding, Ask, Policy, Several}
import gleam/dynamic/decode
import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import support

const bia = "bia; reception"

fn correction(phone: String, birth_date: String) -> String {
  "{\"t\":\"correct\",\"reason\":{\"category\":\"wrong_field\",\"note\":null},"
  <> "\"output\":{\"name\":\"Ana Souza\",\"birth_date\":\""
  <> birth_date
  <> "\",\"phone\":\""
  <> phone
  <> "\",\"coverage\":{\"insurer\":\"Unimed\",\"plan\":\"Unimed Flex\"},\"consent\":true}}"
}

pub fn the_desk_needs_a_validator_test() {
  use env <- support.with_app(fn(config) { config })
  assert support.call(env, http.Get, "/queue", "", "").status == 401
  assert support.call(env, http.Get, "/queue", " ; reception", "").status == 401
  assert support.call(env, http.Post, "/cards/nothing/open", support.felipe, "").status
    == 404
}

pub fn a_card_made_stale_by_a_correction_is_refused_test() {
  use env <- support.with_app(fn(config) { config })
  // Two receptionists approve each registration in this version.
  let assert Ok(Nil) =
    desk.publish(
      env.app.db,
      Policy(
        version: 2,
        rules: [],
        otherwise: Ask(Several(count: 2, of: AnyoneHolding(domain.reception))),
      ),
    )
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let waiting =
    support.arrive(env, support.message(phone, "Ana", support.ana_says))

  let #(felipe_seen, _) = support.open(env, waiting.id, support.felipe)
  let #(bia_seen, _) = support.open(env, waiting.id, bia)
  let corrected =
    support.verdict(
      env,
      waiting.id,
      bia,
      bia_seen,
      correction(phone, "1990-04-21"),
    )
  assert corrected.status == 200
  assert support.field(corrected.body, ["status"], decode.string) == "awaiting"

  // Felipe's card shows the output Bia replaced.
  let stale =
    support.verdict(
      env,
      waiting.id,
      support.felipe,
      felipe_seen,
      "{\"t\":\"approve\"}",
    )
  assert stale.status == 409
  assert support.field(stale.body, ["error"], decode.string) == "stale_card"
  assert string.contains(
    support.field(stale.body, ["detail"], decode.string),
    "open it again",
  )

  // Opened again, the card shows Bia's correction and her approval.
  let #(seen, card) = support.open(env, waiting.id, support.felipe)
  assert support.field(
      card,
      ["card", "standing_output", "birth_date"],
      decode.string,
    )
    == "1990-04-21"
  assert support.field(
      card,
      ["card", "approvals", "by"],
      decode.list(decode.string),
    )
    == ["bia"]
  let approved =
    support.verdict(
      env,
      waiting.id,
      support.felipe,
      seen,
      "{\"t\":\"approve\"}",
    )
  assert approved.status == 200
  assert support.field(approved.body, ["status"], decode.string) == "released"
  let assert Ok([patient]) = store.patients_with_phone(env.app.db, phone)
  assert patient.birth_date == "1990-04-21"
}

pub fn a_rejection_needs_a_reason_and_registers_nobody_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  let waiting = support.arrive(env, message)
  let #(seen, _) = support.open(env, waiting.id, support.felipe)

  let no_reason =
    "{\"t\":\"reject\",\"reason\":{\"category\":\" \",\"note\":null}}"
  let refused =
    support.verdict(env, waiting.id, support.felipe, seen, no_reason)
  assert refused.status == 422

  let reject =
    "{\"t\":\"reject\",\"reason\":{\"category\":\"not_a_new_patient\",\"note\":\"asked for her mother\"}}"
  let rejected = support.verdict(env, waiting.id, support.felipe, seen, reject)
  assert support.field(rejected.body, ["status"], decode.string) == "rejected"
  // The same verdict sent again on the same card stands.
  let again = support.verdict(env, waiting.id, support.felipe, seen, reject)
  assert again.status == 200
  assert store.patients_with_phone(env.app.db, phone) == Ok([])
  // The settlement notice is delivered and nothing is sent.
  assert support.eventually(5000, fn() {
    telemetry.mentioning(
      env.app.collector,
      "settlement notice delivered for " <> waiting.id,
    )
    != []
  })
  assert !list.any(scripted.sent(env.services), fn(sent) { sent.to == phone })
}

pub fn the_tool_refuses_a_duplicate_and_the_refusal_is_recorded_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  let waiting = support.arrive(env, message)
  let #(seen, _) = support.open(env, waiting.id, support.felipe)

  // While the card is open, someone at the front desk registers Ana.
  let assert Ok(Nil) =
    store.insert_patient(
      env.app.db,
      id: "front-desk-1",
      registration: domain.Registration(
        name: "Ana Souza",
        birth_date: Some("1990-04-12"),
        phone:,
        coverage: None,
        consent: True,
      ),
      birth_date: "1990-04-12",
      by: "front desk",
    )

  let approved =
    support.verdict(
      env,
      waiting.id,
      support.felipe,
      seen,
      "{\"t\":\"approve\"}",
    )
  assert approved.status == 409
  assert support.field(approved.body, ["error"], decode.string)
    == "not_registered"

  // Nothing of the verdict's transaction is left, and the refusal is on
  // the record. The occurrence still waits.
  let assert Ok([patient]) = store.patients_with_phone(env.app.db, phone)
  assert patient.id == "front-desk-1"
  let assert Ok(known) = support.read(env, message.id)
  assert occurrence.status_name(known.status) == "awaiting"
  let assert [#("felipe", _, reason)] = occurrence.refusals(known)
  assert string.contains(reason, "already registered")
}

pub fn the_card_shows_what_the_model_read_and_marks_what_changed_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let waiting =
    support.arrive(env, support.message(phone, "Ana", support.ana_says))

  // After the model read it, the clinic stops accepting an insurer.
  let assert Ok(Nil) = store.drop_insurer(env.app.db, "SulAmérica")
  let #(_, card) = support.open(env, waiting.id, support.felipe)

  // The context is the one the model had, read from the record by the
  // model's own reader...
  assert support.field(
      card,
      ["context", "accepted_insurers"],
      decode.list(decode.string),
    )
    == support.insurers
  // ...and the card marks the read whose content changed since.
  let changed =
    support.field(
      card,
      ["card", "model_read"],
      decode.list({
        use kind <- decode.subfield(["ref", "kind"], decode.string)
        use changed <- decode.field(
          "changed_to",
          decode.optional(decode.dynamic),
        )
        decode.success(#(kind, changed != None))
      }),
    )
  assert list.key_find(changed, "insurers.accepted") == Ok(True)
  assert list.key_find(changed, "patients.similar") == Ok(False)
}

pub fn the_release_check_refuses_a_corrected_phone_that_is_taken_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  let taken = support.phone()
  let assert Ok(Nil) =
    store.insert_patient(
      env.app.db,
      id: "front-desk-2",
      registration: domain.Registration(
        name: "Ana Souza",
        birth_date: Some("1990-04-12"),
        phone: taken,
        coverage: None,
        consent: True,
      ),
      birth_date: "1990-04-12",
      by: "front desk",
    )
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = support.message(phone, "Ana", support.ana_says)
  let waiting = support.arrive(env, message)
  let #(seen, _) = support.open(env, waiting.id, support.felipe)

  // Felipe corrects the phone to Ana's other number, which a patient
  // already has. The guard checks the contact's phone; the release check
  // sees the corrected output and refuses.
  let corrected =
    support.verdict(
      env,
      waiting.id,
      support.felipe,
      seen,
      correction(taken, "1990-04-12"),
    )
  assert corrected.status == 409
  assert support.field(corrected.body, ["error"], decode.string)
    == "not_registered"
  let assert Ok(known) = support.read(env, message.id)
  let assert [#("felipe", _, reason)] = occurrence.refusals(known)
  assert string.contains(reason, taken)
  assert store.patients_with_phone(env.app.db, phone) == Ok([])
}
