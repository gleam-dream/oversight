//// Triggers at volume: admission by key.

import decisions
import decisions/learning
import decisions/vocabulary.{Superseded}
import decisions_otp/store
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import moderation_desk/app
import moderation_desk/domain
import moderation_desk/intake
import moderation_desk/models
import moderation_desk/point
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
  support.reading(a, wiring.set_visibility(_, post.id, domain.Pending))
  support.settle(a, [post], within: 5000)
  // Both triggers were worked; the second found the occurrence.
  let assert True =
    app.wait_until(fn() { app.numbers(a).triggers_worked == 2 }, within: 5000)
  process.sleep(50)
  assert support.check(a).occurrences == 1
  assert support.reading(a, store.count(_, wiring.released)) == 1
  assert support.notified(a) == [#(wiring.key(post), 1)]
  app.stop(a)
}

/// An edit that arrives before the worker answers supersedes the
/// expected recommendation: the old key is never recommended. Coverage
/// counts it, and once the backlog is empty nothing is still expected.
pub fn an_edit_before_the_answer_supersedes_the_expected_recommendation_test() {
  let a = support.start(app.config())
  let s = app.store_of(a)
  let posts = scripted.posts(1, 200)
  let assert Ok(Nil) = app.pause_runtime(a)
  let first = scripted.post(250)
  support.receive_all(a, [first, ..posts])
  let assert Ok(edited) =
    intake.edit(s, app.desk_of(a), first.id, "thanks for the patch, it works")
  assert edited.superseded == 0
  let assert Ok(Nil) = app.resume_runtime(a)
  support.settle(a, [edited.post, ..posts], within: 20_000)
  let assert Ok(decisions.NotBegun(pending)) =
    store.transaction(app.store_of(a), decisions.read_record(
      app.desk_of(a),
      _,
      key: wiring.key(first),
    ))
  assert pending.ended == Some(Superseded(point.edited))
  let assert Ok([]) = store.backlog(s).undelivered(10)
  assert app.coverage(a)
    == learning.Coverage(
      expected: 202,
      superseded_before: 1,
      lapsed_before: 0,
      still_expected: 0,
    )
  support.check(a)
  app.stop(a)
}

/// Two edits of one post at once run one after the other: `happened`
/// takes the post's subject lock first, so they number their revisions
/// in turn, and each supersedes what the one before expected.
pub fn two_edits_at_once_run_one_after_the_other_test() {
  let a = support.start(app.config())
  let s = app.store_of(a)
  let post = scripted.post(50)
  let assert Ok(Nil) = app.pause_runtime(a)
  support.receive_all(a, [post])
  let replies = process.new_subject()
  list.each(["thanks for the patch", "thanks for the fix"], fn(text) {
    process.spawn(fn() {
      process.send(replies, intake.edit(s, app.desk_of(a), post.id, text))
    })
  })
  let edits =
    list.map([1, 2], fn(_) {
      let assert Ok(Ok(edited)) = process.receive(replies, 5000)
      edited
    })
  assert list.sort(list.map(edits, fn(e) { e.post.revision }), int.compare)
    == [2, 3]
  let assert Ok(latest) = support.reading(a, wiring.post(_, post.id))
  assert latest.revision == 3
  let assert Ok(Nil) = app.resume_runtime(a)
  support.settle(a, [latest], within: 5000)
  assert app.coverage(a)
    == learning.Coverage(
      expected: 3,
      superseded_before: 2,
      lapsed_before: 0,
      still_expected: 0,
    )
  assert support.notified(a) == [#(wiring.key(latest), 1)]
  support.check(a)
  app.stop(a)
}
