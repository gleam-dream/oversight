//// The cascade of models, each in a process of its own with a deadline,
//// and what a failed attempt leaves on the record.

import decisions
import decisions/model
import decisions/occurrence
import decisions/vocabulary.{Classifier, Rules}
import decisions_otp/backlog
import decisions_otp/store
import gleam/list
import gleam/time/duration
import moderation_desk/app
import moderation_desk/domain
import moderation_desk/models
import moderation_desk/scripted
import moderation_desk/wiring
import support

fn quick_deadlines() -> app.Config {
  app.Config(
    ..app.config(),
    timing: models.Timing(
      rules_within: duration.milliseconds(100),
      classifier_within: duration.milliseconds(100),
      classifier_ms: 0,
    ),
  )
}

pub fn the_rule_model_answers_the_obvious_and_reads_nothing_test() {
  let a = support.start(app.config())
  let spam = scripted.post(1)
  assert scripted.kind_of(1) == scripted.LinkSpam
  support.receive_all(a, [spam])
  support.settle(a, [spam], within: 5000)
  let known = support.occurrence(a, spam)
  assert known.recommendation.by == Rules("moderation-rules", "1")
  assert known.recommendation.reads == []
  assert support.visibility(a, spam) == Ok(domain.Hidden(domain.Spam))
  app.stop(a)
}

/// The classifier answers what the rules abstain on; the record holds
/// the reads it received, and a card resolves them to what it read.
pub fn the_classifier_answers_the_rest_through_recorded_reads_test() {
  let a = support.start(app.config())
  let post = scripted.post(50)
  support.receive_all(a, [post])
  support.settle(a, [post], within: 5000)
  let known = support.occurrence(a, post)
  assert known.recommendation.by == Classifier("moderation-classifier", "1")
  let kinds = list.map(known.recommendation.reads, fn(ref) { ref.kind })
  assert kinds == [wiring.author_history, wiring.thread_read]
  let content = wiring.content(app.store_of(a))
  list.each(known.recommendation.reads, fn(ref) {
    let assert Ok(body) = content(ref)
    assert model.digest(body) == ref.revision
  })
  app.stop(a)
}

/// A classifier that hangs is killed at its deadline; the attempt is on
/// the record and the trigger is retried, and answers the second time.
pub fn a_hanging_classifier_is_killed_and_retried_test() {
  let a = support.start(quick_deadlines())
  let post = scripted.faulty(scripted.post(50), "[hang-once]")
  support.receive_all(a, [post])
  support.settle(a, [post], within: 5000)
  let known = support.occurrence(a, post)
  let assert [occurrence.Attempt(failure: model.Deadline(_), ..)] =
    known.attempts
  assert app.numbers(a).deadlines == 1
  assert support.visibility(a, post) == Ok(domain.Published)
  app.stop(a)
}

/// A classifier that raises takes nothing down. Each failed attempt is
/// on the record; after three the trigger is set aside, and the posts
/// behind it are moderated.
pub fn a_raising_classifier_is_set_aside_after_three_attempts_test() {
  let a = support.start(quick_deadlines())
  let s = app.store_of(a)
  let broken = scripted.faulty(scripted.post(52), "[raise]")
  let fine = scripted.post(53)
  support.receive_all(a, [broken, fine])
  let assert True =
    app.wait_until(
      fn() {
        case store.backlog(s).aside() {
          Ok([_]) -> True
          _ -> False
        }
      },
      within: 5000,
    )
  let assert Ok([
    backlog.Aside(job: backlog.TriggerJob(submitted), attempts:, ..),
  ]) = store.backlog(s).aside()
  assert submitted.key == wiring.key(broken)
  assert attempts == 3
  let assert Error(decisions.NotRecommended(attempts:)) =
    decisions.read(
      app.desk_of(a),
      store.handle(s),
      occurrence: wiring.key(broken),
    )
  assert list.length(attempts) == 3
  assert list.all(attempts, fn(attempt) {
    case attempt.failure {
      model.Raised(_) -> True
      _ -> False
    }
  })
  support.settle(a, [fine], within: 5000)
  assert support.visibility(a, broken) == Ok(domain.Pending)
  let numbers = app.numbers(a)
  assert numbers.raised == 3 && numbers.set_aside == 1
  app.stop(a)
}
