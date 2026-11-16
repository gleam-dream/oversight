//// The decision point and its policy versions, as data.

import decisions
import decisions/fact
import decisions/policy.{
  AnyoneHolding, Ask, Never, PerCent, Policy, Proceed, Several, Step,
  UndeclaredFact, When,
}
import decisions/vocabulary.{type Facts, Classifier, Rules}
import gleam/option.{None, Some}
import gleam/time/duration
import moderation_desk/domain.{Escalate, Hide, Publish, Spam}
import moderation_desk/point

fn facts(
  action: domain.Action,
  stage: String,
  category: String,
  confidence: Float,
  new_author: Bool,
) -> Facts {
  let p = point.declaration()
  [
    fact.set(point.stage(), stage),
    fact.set(point.category(), category),
    fact.set(point.confidence(), confidence),
    fact.set(point.new_author(), new_author),
    ..decisions.facts_of(p, action)
  ]
}

const classifier = Classifier("moderation-classifier", "2")

pub fn both_versions_are_publishable_test() {
  assert decisions.publishable(point.declaration(), point.version_1())
    == Ok(Nil)
  assert decisions.publishable(point.declaration(), point.version_2())
    == Ok(Nil)
}

pub fn a_policy_reading_an_undeclared_fact_is_refused_test() {
  let typo =
    Policy(
      version: 3,
      rules: [
        When(policy.Known("confidense"), Proceed(sample: Never, hold: None)),
      ],
      otherwise: Ask(AnyoneHolding(point.moderators)),
    )
  assert decisions.publishable(point.declaration(), typo)
    == Error([UndeclaredFact("confidense")])
}

pub fn version_1_lets_only_the_rules_through_test() {
  let v1 = point.version_1()
  assert policy.evaluate(
      v1,
      Rules("moderation-rules", "1"),
      facts(Hide(Spam), "rules", "spam", 1.0, False),
    )
    == Proceed(sample: Never, hold: None)
  assert policy.evaluate(
      v1,
      classifier,
      facts(Publish, "classifier", "clean", 0.99, False),
    )
    == Ask(AnyoneHolding(point.moderators))
}

pub fn version_2_proceeds_on_confident_publishes_and_spam_test() {
  let v2 = point.version_2()
  assert policy.evaluate(
      v2,
      classifier,
      facts(Publish, "classifier", "clean", 0.95, False),
    )
    == Proceed(sample: PerCent(2), hold: None)
  assert policy.evaluate(
      v2,
      classifier,
      facts(Hide(Spam), "classifier", "spam", 0.95, True),
    )
    == Proceed(
      sample: PerCent(2),
      hold: Some(duration.minutes(point.undo_minutes)),
    )
}

pub fn version_2_asks_for_new_authors_doubt_and_abuse_test() {
  let v2 = point.version_2()
  let moderators = Ask(AnyoneHolding(point.moderators))
  assert policy.evaluate(
      v2,
      classifier,
      facts(Publish, "classifier", "clean", 0.95, True),
    )
    == moderators
  assert policy.evaluate(
      v2,
      classifier,
      facts(Publish, "classifier", "clean", 0.8, False),
    )
    == moderators
}

pub fn version_2_asks_two_moderators_to_hide_for_abuse_test() {
  assert policy.evaluate(
      point.version_2(),
      classifier,
      facts(Hide(domain.Abuse), "classifier", "abuse", 0.95, False),
    )
    == Ask(Several(2, AnyoneHolding(point.moderators)))
}

pub fn version_2_asks_a_senior_for_a_sensitive_category_test() {
  assert policy.evaluate(
      point.version_2(),
      classifier,
      facts(Escalate("risk"), "classifier", "self_harm", 0.99, False),
    )
    == Ask(AnyoneHolding(point.seniors))
}

pub fn an_unknown_fact_never_proceeds_test() {
  // No confidence and no author: a classifier that reported less asks.
  let p = point.declaration()
  let sparse = [
    fact.set(point.stage(), "classifier"),
    ..decisions.facts_of(p, Publish)
  ]
  assert policy.evaluate(point.version_2(), classifier, sparse)
    == Ask(AnyoneHolding(point.moderators))
}

pub fn a_waiting_occurrence_escalates_to_seniors_after_30_minutes_test() {
  let #(now, later) =
    policy.timeline(
      point.version_2(),
      classifier,
      facts(Publish, "classifier", "clean", 0.8, False),
      waited: 0,
    )
  assert now == Ask(AnyoneHolding(point.moderators))
  assert later == [Step(after: 30, outcome: Ask(AnyoneHolding(point.seniors)))]
}
