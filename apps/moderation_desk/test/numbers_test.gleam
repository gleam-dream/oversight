//// The operator's numbers agree with the record.

import decisions/occurrence
import decisions_otp/store
import gleam/list
import moderation_desk/app
import moderation_desk/intake
import moderation_desk/scripted
import support

pub fn the_numbers_match_the_record_test() {
  let a = support.start(app.config())
  support.publish_version_2(a)
  let posts =
    scripted.posts(1, 1000)
    |> list.map(fn(post) {
      case post.id {
        "post-150" | "post-250" -> scripted.faulty(post, "[hang-once]")
        _ -> post
      }
    })
  support.receive_all(a, posts)
  list.each(list.take(posts, 10), fn(post) {
    let assert Ok(intake.Duplicate) = app.receive(a, post)
  })
  support.settle(a, posts, within: 30_000)
  let numbers = app.numbers(a)
  let known = list.map(posts, support.occurrence(a, _))
  let handle = support.handle(a)
  assert numbers.received == 1000
  assert numbers.duplicates == 10
  assert numbers.proceeded + numbers.waited == 1000
  assert numbers.by_rules + numbers.by_classifier == 1000
  assert numbers.sampled == list.count(known, fn(o) { o.sampled })
  assert numbers.waited
    == list.count(known, fn(o) { occurrence.verdicts(o) != [] })
  assert numbers.deadlines == 2
  assert numbers.settlements == 1000
  // A hide for abuse needs two approvals under version 2.
  assert numbers.approved + numbers.corrected
    == list.fold(known, 0, fn(sum, o) {
      sum + list.length(occurrence.verdicts(o))
    })
  assert numbers.set_aside == 0
  assert list.length(store.heads(handle)) == 1000
  app.stop(a)
}
