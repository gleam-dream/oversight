//// Triggers at volume: admission by key.

import decisions_otp/store
import gleam/erlang/process
import gleam/list
import moderation_desk/app
import moderation_desk/domain
import moderation_desk/intake
import moderation_desk/models
import moderation_desk/scripted
import moderation_desk/wiring
import support

/// Twenty deliveries of one post at once admit it once: one trigger, one
/// occurrence, one notification.
pub fn a_post_delivered_at_once_by_many_is_admitted_once_test() {
  let a = support.start(app.config())
  let post = scripted.post(50)
  let replies = process.new_subject()
  list.each(scripted.numbers(1, 20), fn(_) {
    process.spawn(fn() { process.send(replies, app.receive(a, post)) })
  })
  let receipts =
    list.map(scripted.numbers(1, 20), fn(_) {
      let assert Ok(Ok(receipt)) = process.receive(replies, 5000)
      receipt
    })
  assert list.count(receipts, fn(r) { r == intake.Admitted }) == 1
  assert list.count(receipts, fn(r) { r == intake.Duplicate }) == 19
  support.settle(a, [post], within: 5000)
  assert support.notified(a) == [#(wiring.key(post), 1)]
  assert support.check(a).occurrences == 1
  let numbers = app.numbers(a)
  assert numbers.received == 1 && numbers.duplicates == 19
  app.stop(a)
}

/// Two triggers with one key that bypass admission still make one
/// occurrence: `recommend_once` is the second line of defence.
pub fn two_triggers_with_one_key_make_one_occurrence_test() {
  let a = support.start(app.config())
  let s = app.store_of(a)
  let post = scripted.post(51)
  let assert Ok(Nil) =
    store.transaction(s, fn(tx) {
      wiring.put_post(tx, post)
      let jobs = store.backlog(s)
      let assert Ok(Nil) =
        jobs.submit(tx, wiring.key(post), models.payload(post))
      jobs.submit(tx, wiring.key(post), models.payload(post))
    })
  wiring.set_visibility(support.handle(a), post.id, domain.Pending)
  support.settle(a, [post], within: 5000)
  // Both triggers were worked; the second found the occurrence.
  let assert True =
    app.wait_until(fn() { app.numbers(a).triggers_worked == 2 }, within: 5000)
  process.sleep(50)
  assert support.check(a).occurrences == 1
  assert store.count(support.handle(a), wiring.released) == 1
  assert support.notified(a) == [#(wiring.key(post), 1)]
  app.stop(a)
}
