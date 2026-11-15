//// The autonomy ladder's gate: replay before publishing.

import decisions/learning
import gleam/list
import moderation_desk/app.{type App}
import moderation_desk/gate
import moderation_desk/models
import moderation_desk/point
import moderation_desk/scripted
import moderation_desk/wiring
import support

const threshold = gate.Threshold(agreement_per_cent: 98, at_least: 50)

/// A period under version 1: every classifier answer was judged by a
/// moderator.
fn recorded() -> App {
  let a = support.start(app.config())
  let posts = scripted.posts(1, 400)
  support.receive_all(a, posts)
  support.settle(a, posts, within: 30_000)
  a
}

pub fn a_candidate_that_lets_abuse_through_is_held_test() {
  let a = recorded()
  let eager = gate.Candidate("eager", "eager", point.version_2())
  let assert Ok(gate.Held(report)) =
    gate.publish_if_clear(
      app.store_of(a),
      app.desk_of(a),
      eager,
      threshold,
      across: 4,
    )
  assert report.would_proceed >= threshold.at_least
  assert report.agreed_on_proceed < report.would_proceed
  // Nothing was published.
  let assert Ok(current) = wiring.current_policy(support.handle(a))
  assert current.version == 1
  assert wiring.classifier_version(support.handle(a)) == "1"
  app.stop(a)
}

pub fn a_candidate_that_agrees_is_published_test() {
  let a = recorded()
  let careful = gate.Candidate("classifier 2", "2", point.version_2())
  let assert Ok(gate.Published(report)) =
    gate.publish_if_clear(
      app.store_of(a),
      app.desk_of(a),
      careful,
      threshold,
      across: 4,
    )
  assert report.agreed_on_proceed == report.would_proceed
  assert report.unanswered == 0
  let assert Ok(current) = wiring.current_policy(support.handle(a))
  assert current == point.version_2()
  assert wiring.classifier_version(support.handle(a)) == "2"
  app.stop(a)
}

/// The parallel replay adds up to the sequential one, on any number of
/// processes.
pub fn the_replay_across_processes_equals_the_sequential_one_test() {
  let a = recorded()
  let assert Ok(examples) = gate.examples(app.store_of(a), app.desk_of(a))
  let sequential =
    learning.replay(examples, models.candidate("2"), same: fn(x, y) { x == y })
  list.each([1, 3, app.schedulers()], fn(across) {
    let report =
      gate.replay(
        app.store_of(a),
        examples,
        gate.Candidate("2", "2", point.version_2()),
        across:,
      )
    assert report.model_agreed == sequential.tally.agreed
    assert report.model_judged == sequential.tally.judged
  })
  app.stop(a)
}

/// Authors whose posts were hidden after the classifier read their
/// history: the replay flags the examples whose recorded read has
/// changed since.
pub fn drift_is_flagged_when_an_authors_history_changed_test() {
  let a = recorded()
  let assert Ok(examples) = gate.examples(app.store_of(a), app.desk_of(a))
  let report =
    gate.replay(
      app.store_of(a),
      examples,
      gate.Candidate("2", "2", point.version_2()),
      across: 4,
    )
  assert report.drifted > 0
  assert report.drifted < report.examples
  app.stop(a)
}
