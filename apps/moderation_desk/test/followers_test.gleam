//// What follows a settlement, time as a fact, edits and appeals.

import decisions
import decisions/occurrence
import decisions/vocabulary.{
  Approve, Assessment, DeadlinePassed, Reason, Reject, Superseded, Wrong,
}
import decisions_otp/runtime
import decisions_otp/store
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import gleam/time/duration
import moderation_desk/app
import moderation_desk/desk.{Moderating, Person}
import moderation_desk/domain
import moderation_desk/intake
import moderation_desk/point
import moderation_desk/scripted
import moderation_desk/wiring
import support

fn nobody() -> app.Config {
  support.with_people([
    Person(
      validator: desk.moderator("ana"),
      role: Moderating,
      think_ms: 0,
      poll_ms: 20,
      on_duty: False,
    ),
  ])
}

/// Each released action reaches the platform once: the visibility, a
/// strike for a hide, a safety case for an escalation, one notification.
pub fn a_release_publishes_hides_or_escalates_once_test() {
  let a = support.start(app.config())
  let ordinary = scripted.post(50)
  let spam = scripted.post(1)
  let threat = scripted.post(97)
  let posts = [ordinary, spam, threat]
  support.receive_all(a, posts)
  support.settle(a, posts, within: 10_000)
  assert support.visibility(a, ordinary) == Ok(domain.Published)
  assert support.visibility(a, spam) == Ok(domain.Hidden(domain.Spam))
  assert support.visibility(a, threat)
    == Ok(domain.WithSafetyTeam("threat of violence"))
  let handle = support.handle(a)
  let assert Ok(author) = wiring.author(handle, spam.author)
  assert author.strikes == 1
  assert store.get(handle, wiring.safety, threat.id) == Ok("threat of violence")
  assert list.sort(support.notified(a), fn(x, y) { compare(x.0, y.0) })
    == list.sort(list.map(posts, fn(p) { #(wiring.key(p), 1) }), fn(x, y) {
      compare(x.0, y.0)
    })
  app.stop(a)
}

fn compare(a: String, b: String) -> order.Order {
  string.compare(a, b)
}

/// Nobody is on duty. After 30 minutes the occurrence waits for seniors;
/// when its validity passes it expires, and the application hides the
/// post until someone looks again.
pub fn an_undecided_post_escalates_then_expires_test() {
  let a = support.start(nobody())
  let s = app.store_of(a)
  let insult = scripted.post(88)
  support.receive_all(a, [insult])
  let assert True =
    app.wait_until(
      fn() { support.awaiting(a, insult) == [point.moderators] },
      within: 5000,
    )
  store.advance(s, duration.minutes(31))
  let assert True =
    app.wait_until(
      fn() { support.awaiting(a, insult) == [point.seniors] },
      within: 5000,
    )
  store.advance(s, duration.minutes(90))
  support.settle(a, [insult], within: 5000)
  let known = support.occurrence(a, insult)
  assert known.status == occurrence.Expired(DeadlinePassed)
  assert support.visibility(a, insult)
    == Ok(domain.HiddenPendingReview(domain.NobodyDecided))
  let assert [#(_, _, domain.YourPostAwaitsReview)] =
    wiring.notifications(support.handle(a))
  app.stop(a)
}

/// A paused runtime delivers nothing while time passes. Stopping its
/// whole tree loses only a delivery in hand, which rolls back: the
/// escalations are rows, and the runtime the root starts again over the
/// same store delivers them.
pub fn escalations_survive_a_runtime_stopped_and_started_again_test() {
  let a = support.start(nobody())
  let s = app.store_of(a)
  let posts = [scripted.post(88), scripted.post(89), scripted.post(90)]
  support.receive_all(a, posts)
  let assert True =
    app.wait_until(
      fn() {
        list.all(posts, fn(p) { support.awaiting(a, p) == [point.moderators] })
      },
      within: 5000,
    )
  let control = app.control(a)
  let assert Ok(before) = runtime.supervisor_of(control)
  let assert Ok(Nil) = app.pause_runtime(a)
  store.advance(s, duration.minutes(31))
  process.sleep(100)
  assert list.all(posts, fn(p) { support.awaiting(a, p) == [point.moderators] })
  assert list.length(store.wakes(support.handle(a))) == 6
  let assert Ok(Nil) = app.restart_runtime(a)
  let assert True =
    app.wait_until(
      fn() {
        list.all(posts, fn(p) { support.awaiting(a, p) == [point.seniors] })
      },
      within: 5000,
    )
  let assert Ok(after) = runtime.supervisor_of(control)
  assert before != after
  support.check(a)
  app.stop(a)
}

/// Under version 2 a hide for abuse waits for two moderators, and after
/// 30 minutes for a senior. The escalation asks for a senior's approval:
/// one moderator's approval standing does not meet it, so the occurrence
/// goes on waiting, now for seniors; one senior's approval standing
/// already meets it, so the escalation accepts and releases the hide.
pub fn the_escalation_accepts_only_what_the_standing_approvals_meet_test() {
  let a = support.start(nobody())
  support.publish_version_2(a)
  let s = app.store_of(a)
  // Posts 88 and 89 are insults by established authors.
  let first = scripted.post(88)
  let second = scripted.post(89)
  support.receive_all(a, [first, second])
  let assert True =
    app.wait_until(
      fn() {
        support.awaiting(a, first) == [point.moderators]
        && support.awaiting(a, second) == [point.moderators]
      },
      within: 5000,
    )
  let assert Ok(_) =
    desk.decide_now(
      s,
      app.desk_of(a),
      desk.moderator("bia"),
      wiring.key(first),
      Approve,
    )
  let assert Ok(_) =
    desk.decide_now(
      s,
      app.desk_of(a),
      desk.senior("carla"),
      wiring.key(second),
      Approve,
    )
  assert support.awaiting(a, first) == [point.moderators]
  assert support.awaiting(a, second) == [point.moderators]
  store.advance(s, duration.minutes(31))
  support.settle(a, [second], within: 5000)
  assert support.visibility(a, second) == Ok(domain.Hidden(domain.Abuse))
  let assert True =
    app.wait_until(
      fn() { support.awaiting(a, first) == [point.seniors] },
      within: 5000,
    )
  assert support.visibility(a, first) == Ok(domain.Pending)
  support.check(a)
  app.stop(a)
}

/// An edit supersedes the waiting recommendation about the old text; the
/// old one tells nobody, and the new revision is decided on its own.
pub fn an_edit_supersedes_a_waiting_recommendation_test() {
  let a = support.start(nobody())
  support.publish_version_2(a)
  let s = app.store_of(a)
  // Post 91 is an insult by an established author.
  let insult = scripted.post(91)
  support.receive_all(a, [insult])
  let assert True =
    app.wait_until(fn() { support.awaiting(a, insult) != [] }, within: 5000)
  let assert Ok(edited) =
    intake.edit(s, app.desk_of(a), insult.id, "thanks for the patch, it works")
  assert edited.superseded == 1
  assert edited.post.revision == 2
  support.settle(a, [edited.post], within: 5000)
  let assert Ok(old) =
    decisions.read(
      app.desk_of(a),
      support.handle(a),
      occurrence: wiring.key(insult),
    )
  assert old.status == occurrence.Expired(Superseded(point.edited))
  assert support.visibility(a, insult) == Ok(domain.Published)
  // One notification, about the new revision.
  assert support.notified(a) == [#(wiring.key(edited.post), 1)]
  support.check(a)
  app.stop(a)
}

/// An appeal is a later assessment on the released occurrence. Upheld,
/// it publishes the post and takes the strike back; the verdict and the
/// output stay as they were.
pub fn an_upheld_appeal_is_an_assessment_and_publishes_the_post_test() {
  let a = support.start(app.config())
  let s = app.store_of(a)
  let insult = scripted.post(91)
  support.receive_all(a, [insult])
  support.settle(a, [insult], within: 5000)
  assert support.visibility(a, insult) == Ok(domain.Hidden(domain.Abuse))
  let before = support.occurrence(a, insult)
  let assert Ok(Nil) =
    intake.appeal(s, app.desk_of(a), insult.id, intake.Upheld)
  let after = support.occurrence(a, insult)
  assert after.status == before.status
  assert occurrence.verdicts(after) == occurrence.verdicts(before)
  let assert [Assessment(finding: Wrong(Some(domain.Publish)), ..)] =
    occurrence.assessments(after)
  assert support.visibility(a, insult) == Ok(domain.Published)
  let assert Ok(author) = wiring.author(support.handle(a), insult.author)
  assert author.strikes == 0
  // A post still waiting has nothing to appeal.
  let waiting = scripted.post(92)
  app.stop(a)
  let b = support.start(nobody())
  support.receive_all(b, [waiting])
  let assert True =
    app.wait_until(fn() { support.awaiting(b, waiting) != [] }, within: 5000)
  let assert Error(_) =
    intake.appeal(app.store_of(b), app.desk_of(b), waiting.id, intake.Upheld)
  app.stop(b)
}

/// A moderator who rejects the recommendation releases nothing: the post
/// is hidden until someone looks again.
pub fn a_rejection_hides_the_post_pending_review_test() {
  let a = support.start(nobody())
  let post = scripted.post(50)
  support.receive_all(a, [post])
  let assert True =
    app.wait_until(fn() { support.awaiting(a, post) != [] }, within: 5000)
  let assert Ok(_) =
    desk.decide_now(
      app.store_of(a),
      app.desk_of(a),
      desk.moderator("bia"),
      wiring.key(post),
      Reject(Reason("unclear", None)),
    )
  support.settle(a, [post], within: 5000)
  assert support.visibility(a, post)
    == Ok(domain.HiddenPendingReview(domain.ModeratorRejected))
  app.stop(a)
}
