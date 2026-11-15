//// Under version 2 the policy lets a sure registration proceed and samples
//// one in five for a review after the fact. The manager reviews the
//// sampled ones from `GET /reviews`; reception may not. A review changes
//// nothing and counts toward agreement.

import clinic_registration/app
import clinic_registration/desk
import clinic_registration/domain
import clinic_registration/scripted
import decisions/learning
import decisions/policy
import gleam/dynamic/decode
import gleam/http
import gleam/list
import support

/// A message whose registration the policy samples.
fn sampled_message(phone: String) -> domain.Inbound {
  let message = support.message(phone, "Ana", support.ana_says)
  case policy.is_sampled(policy.PerCent(20), domain.key(message.id)) {
    True -> message
    False -> sampled_message(phone)
  }
}

pub fn the_manager_reviews_a_sampled_registration_test() {
  use env <- support.with_app(fn(config) { config })
  let assert Ok(Nil) = desk.publish(env.app.db, domain.proceed_when_sure())
  let phone = support.phone()
  scripted.script(env.services, phone, [
    scripted.Answer(support.ana_answer(phone)),
  ])
  let message = sampled_message(phone)
  let assert Ok(_) = app.admit(env.app, message)
  let released = support.await_status(env, message.id, "released")
  assert released.sampled

  let reviews = fn() {
    support.call(env, http.Get, "/reviews", support.marta, "").body
    |> support.field(["reviews"], decode.list(decode.string))
  }
  assert reviews() == [released.id]

  // Reception may not review; the manager may.
  let refused =
    support.call(
      env,
      http.Post,
      "/cards/" <> released.id <> "/open",
      support.felipe,
      "",
    )
  assert refused.status == 403
  let #(seen, card) = support.open(env, released.id, support.marta)
  assert support.field(card, ["card", "status"], decode.string) == "released"
  let reviewed =
    support.call(
      env,
      http.Post,
      "/cards/" <> released.id <> "/review",
      support.marta,
      "{\"seen\":" <> support.show(seen) <> ",\"verdict\":{\"t\":\"approve\"}}",
    )
  assert reviewed.status == 200
  assert support.field(reviewed.body, ["status"], decode.string) == "released"

  // Reviewed once: it leaves the review queue and counts as agreement.
  assert reviews() == []
  let assert Ok(known) = support.read(env, message.id)
  let tally = learning.tally([known]) |> learning.total
  assert tally.judged == 1
  assert tally.agreed == 1
  assert support.eventually(5000, fn() {
    list.length(scripted.sent(env.services)) == 1
  })
}
