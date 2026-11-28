//// Moderators at a live desk: two on one queue, a stale card, a
//// reviewer, missed hints and drift.

import decisions
import decisions/occurrence
import decisions/view
import decisions/vocabulary.{Approve, Correct, Reason}
import decisions_otp/store
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import moderation_desk/app
import moderation_desk/desk.{Moderating, Person, Reviewing}
import moderation_desk/domain
import moderation_desk/scripted
import moderation_desk/wiring
import support

fn moderator(name: String, think_ms: Int, on_duty: Bool) -> desk.Person {
  Person(
    validator: desk.moderator(name),
    role: Moderating,
    think_ms:,
    poll_ms: 20,
    on_duty:,
  )
}

/// Under version 1 every classifier answer waits for a moderator. Two
/// moderators drain one queue: each card is decided once, both work, and
/// no verdict of theirs is refused.
pub fn two_moderators_work_one_queue_without_colliding_test() {
  let a =
    support.start(
      support.with_people([
        moderator("ana", 1, True),
        moderator("bruno", 1, True),
      ]),
    )
  let posts = scripted.posts(1, 400)
  support.receive_all(a, posts)
  support.settle(a, posts, within: 30_000)
  let ana = desk.snapshot(support.person(a, "ana"))
  let bruno = desk.snapshot(support.person(a, "bruno"))
  let numbers = app.numbers(a)
  assert ana.decided > 0 && bruno.decided > 0
  assert ana.decided + bruno.decided == numbers.waited
  assert numbers.stale_cards == 0 && numbers.other_refusals == 0
  // Every verdict on the record is the only one on its occurrence.
  let summary = support.check(a)
  assert summary.occurrences == 400 && summary.settled == 400
  app.stop(a)
}

/// Under version 2 a hide for abuse needs two moderators; a senior
/// counts as one. A senior corrects a card a moderator is reading: the
/// card still waits, the moderator's verdict on the card as she saw it is
/// refused as stale, and the hints about the card are what tell her to
/// open it again. She approves the correction, the second approval.
pub fn a_card_corrected_by_a_senior_is_refused_as_stale_test() {
  let a =
    support.start(
      support.with_people([
        moderator("ana", 400, True),
        moderator("bruno", 0, False),
      ]),
    )
  support.publish_version_2(a)
  let s = app.store_of(a)
  let insult = scripted.post(88)
  assert scripted.kind_of(88) == scripted.Insult
  support.receive_all(a, [insult])
  let key = wiring.key(insult)
  let assert True =
    app.wait_until(
      fn() { support.reading(a, store.get(_, wiring.claims, key)) == Ok("ana") },
      within: 5000,
    )
  let correction = domain.Escalate("repeated harassment")
  let assert Ok(corrected) =
    desk.decide_now(
      s,
      app.desk_of(a),
      desk.senior("carla"),
      key,
      Correct(output: correction, reason: Reason("needs_safety_team", None)),
    )
  // One approval of two: the card still waits.
  let assert occurrence.Awaiting(_) = corrected.status
  support.settle(a, [insult], within: 5000)
  let snapshot = desk.snapshot(support.person(a, "ana"))
  assert snapshot.stale == 1
  assert snapshot.told > 0
  assert snapshot.decided == 1
  let known = support.occurrence(a, insult)
  let assert [#("carla", Correct(..)), #("ana", Approve)] =
    occurrence.verdicts(known)
  let assert occurrence.Released(final:, ..) = known.status
  assert final == correction
  assert support.visibility(a, insult)
    == Ok(domain.WithSafetyTeam("repeated harassment"))
  assert support.reading(a, store.get(_, wiring.claims, key)) == Error(Nil)
  app.stop(a)
}

/// Under version 2 about 2 % of what proceeds on the classifier's answer
/// is sampled. The reviewer
/// works that queue; a moderator who does not hold `reviewers` may not
/// review.
pub fn a_reviewer_works_the_sampled_queue_test() {
  let reviewer =
    Person(
      validator: desk.reviewer("dev"),
      role: Reviewing,
      think_ms: 0,
      poll_ms: 20,
      on_duty: False,
    )
  let a =
    support.start(
      support.with_people([
        moderator("ana", 0, True),
        Person(..moderator("carla", 0, True), validator: desk.senior("carla")),
        reviewer,
      ]),
    )
  support.publish_version_2(a)
  let posts = scripted.posts(1, 1000)
  support.receive_all(a, posts)
  support.settle(a, posts, within: 30_000)
  let sampled = store.review_queue(app.store_of(a))
  assert sampled != []
  let assert [first, ..] = sampled
  let refused =
    store.transaction(app.store_of(a), fn(tx) {
      let desk = app.desk_of(a)
      case
        decisions.open(
          desk,
          tx,
          occurrence: first,
          by: desk.moderator("ana"),
          latest: wiring.latest(tx),
        )
      {
        Ok(card) -> decisions.review(desk, tx, card, Approve)
        Error(refusal) -> Error(refusal)
      }
    })
  assert refused == Error(decisions.NotEligible)
  desk.on_duty(support.person(a, "dev"), True)
  let assert True =
    app.wait_until(
      fn() { store.review_queue(app.store_of(a)) == [] },
      within: 10_000,
    )
  assert desk.snapshot(support.person(a, "dev")).reviewed
    == list.length(sampled)
  let known =
    store.transaction(app.store_of(a), decisions.read(
      app.desk_of(a),
      _,
      occurrence: first,
    ))
  let assert Ok(known) = known
  let assert [#("dev", _)] = occurrence.reviews(known)
  support.check(a)
  app.stop(a)
}

/// A store keeps room for two hints per subscriber here. While the only
/// moderator reads a card, 30 posts enter her queue; the store drops
/// hints and tells her how many, she reads the queue again, and every
/// post is still decided.
pub fn a_moderator_who_missed_hints_reads_again_test() {
  let config =
    app.Config(
      ..support.with_people([moderator("ana", 150, True)]),
      store: store.Config(..app.config().store, hint_capacity: 2),
    )
  let a = support.start(config)
  // Insults: under version 1 every one waits for a moderator.
  let posts =
    scripted.posts(1, 1000)
    |> list.filter(fn(p) { scripted.kind_of(number(p)) == scripted.Insult })
    |> list.take(30)
  support.receive_all(a, posts)
  support.settle(a, posts, within: 30_000)
  // The store tells her what she missed once her mailbox has room, with
  // no further change needed.
  let assert True =
    app.wait_until(
      fn() { desk.snapshot(support.person(a, "ana")).missed > 0 },
      within: 2000,
    )
  let ana = desk.snapshot(support.person(a, "ana"))
  assert ana.decided == 30
  assert app.numbers(a).hints_missed == ana.missed
  app.stop(a)
}

fn number(post: domain.Post) -> Int {
  let assert Ok(n) = int.parse(string.replace(post.id, "post-", ""))
  n
}

/// The author's history changes after the classifier read it: a card
/// opened afterwards shows the read as changed, with the newer revision.
pub fn a_card_shows_drift_when_the_authors_history_changed_test() {
  let a = support.start(support.with_people([moderator("ana", 0, False)]))
  // Posts 88 and 288 are insults by the same author.
  let first = scripted.post(88)
  let second = scripted.post(288)
  assert first.author == second.author
  support.receive_all(a, [first, second])
  let assert True =
    app.wait_until(
      fn() {
        support.awaiting(a, first) != [] && support.awaiting(a, second) != []
      },
      within: 5000,
    )
  // The first is hidden: the author gets a strike.
  let assert Ok(_) =
    desk.decide_now(
      app.store_of(a),
      app.desk_of(a),
      desk.moderator("bia"),
      wiring.key(first),
      Approve,
    )
  let assert True =
    app.wait_until(
      fn() { support.visibility(a, first) == Ok(domain.Hidden(domain.Abuse)) },
      within: 5000,
    )
  let assert Ok(shown) =
    store.transaction(app.store_of(a), fn(tx) {
      decisions.open(
        app.desk_of(a),
        tx,
        occurrence: wiring.key(second),
        by: desk.moderator("bia"),
        latest: wiring.latest(tx),
      )
    })
  let card = view.of(shown, content: wiring.content(app.store_of(a)))
  let assert [history] =
    list.filter(card.pulled, fn(item) { item.ref.kind == wiring.author_history })
  let assert Some(newer) = history.now
  assert newer.revision != history.ref.revision
  assert occurrence.drift(decisions.shown(shown)) == [newer]
  app.stop(a)
}
