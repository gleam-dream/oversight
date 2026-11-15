//// What follows the settlement: Ana's confirmation, sent under the
//// release key and reported as performed, not performed, or uncertain
//// until a lookup by the key settles it.

import clinic_registration/domain.{type Registration}
import clinic_registration/scripted
import decisions/entry
import decisions/occurrence.{type Occurrence}
import decisions/vocabulary.{type Effect, NotPerformed, Performed, Uncertain}
import gleam/list
import gleam/option.{Some}
import support

fn effects(known: Occurrence(a)) -> List(Effect) {
  list.filter_map(known.entries, fn(e) {
    case e.event {
      entry.Effected(effect:) -> Ok(effect)
      _ -> Error(Nil)
    }
  })
}

fn approve(env: support.Env, message_id: String) -> Occurrence(Registration) {
  let assert Ok(waiting) = support.read(env, message_id)
  let #(seen, _) = support.open(env, waiting.id, support.felipe)
  let assert 200 =
    support.verdict(
      env,
      waiting.id,
      support.felipe,
      seen,
      "{\"t\":\"approve\"}",
    ).status
  support.await_status(env, message_id, "released")
}

fn settled(env: support.Env, message_id: String) -> Occurrence(Registration) {
  let done =
    support.eventually(8000, fn() {
      case support.read(env, message_id) {
        Ok(known) ->
          case occurrence.effect(known) {
            Some(Uncertain(_)) | option.None -> False
            Some(_) -> True
          }
        Error(_) -> False
      }
    })
  assert done
  let assert Ok(known) = support.read(env, message_id)
  known
}

pub fn a_lost_answer_is_uncertain_until_the_lookup_settles_it_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  // The provider sends the message, then answers after the client's
  // 400 ms deadline.
  scripted.recipient(env.services, phone, scripted.SlowFirstAnswer(1200))
  let message = support.message(phone, "Ana", support.ana_says)
  let _ = support.arrive(env, message)
  let released = approve(env, message.id)
  let assert occurrence.Released(key:, ..) = released.status

  let known = settled(env, message.id)
  let assert [Uncertain(_), Performed(receipt)] = effects(known)
  assert receipt.id == key
  // The lookup found the message; it was not sent again.
  assert scripted.sends(env.services, key) == 1
  assert list.count(scripted.sent(env.services), fn(sent) { sent.to == phone })
    == 1
}

pub fn a_refused_send_is_not_performed_test() {
  use env <- support.with_app(fn(config) { config })
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  scripted.recipient(env.services, phone, scripted.Refuse("not on the channel"))
  let message = support.message(phone, "Ana", support.ana_says)
  let _ = support.arrive(env, message)
  let _ = approve(env, message.id)

  let known = settled(env, message.id)
  let assert [NotPerformed(_)] = effects(known)
  // The patient is registered whatever became of the message.
  assert occurrence.status_name(known.status) == "released"
}
