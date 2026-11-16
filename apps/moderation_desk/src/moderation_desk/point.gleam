//// The decision point `moderation`: its declaration, the typed facts a
//// policy may read, and the policy versions, which are data.
////
//// Version 1 lets the rule model's answers through and asks a moderator
//// for everything else. Version 2 proceeds on confident publishes by
//// established authors and on confident hides of spam, holding a hide
//// for `undo_minutes` so that a senior may take it back, samples 2 % of
//// what it proceeds for a later review, asks a senior for anything in a
//// sensitive category, asks two moderators to agree before a post is
//// hidden for abuse (a senior counts as a moderator), and asks a
//// moderator for the rest. Under both, an
//// occurrence nobody decided escalates to seniors after
//// `escalate_after_minutes`, and expires when its validity passes.

import decisions
import decisions/fact.{type Key}
import decisions/policy.{
  type Policy, AnyOf, AnyoneHolding, Ask, Never, PerCent, Policy, Proceed,
  Several, When,
}
import decisions/vocabulary.{ApproveRejectOrCorrect}
import decisions/wire
import gleam/option.{None, Some}
import gleam/time/duration
import moderation_desk/domain.{type Action}

/// The point's name, stored on every occurrence.
pub const name = "moderation"

/// The decision set of moderators.
pub const moderators = "moderators"

/// The decision set of senior moderators. Seniors hold `moderators` too.
pub const seniors = "seniors"

/// The decision set allowed to review sampled occurrences.
pub const reviewers = "reviewers"

/// The world event that supersedes a waiting recommendation about a post.
pub const edited = "post_edited"

/// Minutes an occurrence waits before it goes to seniors.
pub const escalate_after_minutes = 30

/// Minutes an occurrence may wait before it expires.
pub const valid_minutes = 120

/// Minutes during which a senior may take back a hide of spam version 2
/// let through without a person.
pub const undo_minutes = 5

/// How confident the classifier must be for version 2 to proceed.
pub const confident = 0.9

/// The classifier's confidence, from its signals.
pub fn confidence() -> Key(Float) {
  fact.number("confidence")
}

/// The category the recommender gave, from its signals: `"clean"` or a
/// violation's name.
pub fn category() -> Key(String) {
  fact.text("category")
}

/// Whether the author joined less than a week ago, from the signals of a
/// recommender that read the author's history.
pub fn new_author() -> Key(Bool) {
  fact.flag("new_author")
}

/// Which stage of the cascade answered: `"rules"` or `"classifier"`.
pub fn stage() -> Key(String) {
  fact.text("stage")
}

/// The kind of the recommended action, computed from the output.
pub fn action() -> Key(String) {
  fact.text("action")
}

/// The declaration of the point.
pub fn declaration() -> decisions.Point(Action) {
  decisions.point(name, wire.codec(domain.action_codec()))
  |> decisions.allowing(ApproveRejectOrCorrect)
  |> decisions.fact(action(), domain.action_name)
  |> decisions.signal(stage())
  |> decisions.signal(confidence())
  |> decisions.signal(category())
  |> decisions.signal(new_author())
  |> decisions.valid_for(duration.minutes(valid_minutes))
  |> decisions.superseded_by(edited)
  |> decisions.reviewed_by(reviewers)
  |> decisions.withdrawn_by(seniors)
}

fn rules_settle() -> policy.Rule {
  When(policy.is(stage(), "rules"), Proceed(sample: Never, hold: None))
}

fn escalation() -> policy.Rule {
  When(policy.waited(escalate_after_minutes), Ask(AnyoneHolding(seniors)))
}

/// Version 1: the rule model's answers proceed, a moderator decides the
/// rest.
pub fn version_1() -> Policy {
  Policy(
    version: 1,
    rules: [rules_settle(), escalation()],
    otherwise: Ask(AnyoneHolding(moderators)),
  )
}

/// Version 2, as published once the replay gate passes.
pub fn version_2() -> Policy {
  Policy(
    version: 2,
    rules: [
      rules_settle(),
      When(
        AnyOf([
          policy.is(category(), domain.violation_name(domain.SelfHarm)),
          policy.is(category(), domain.violation_name(domain.Violence)),
        ]),
        Ask(AnyoneHolding(seniors)),
      ),
      When(
        policy.All([
          policy.is(action(), "publish"),
          policy.at_least(confidence(), confident),
          policy.is(new_author(), False),
        ]),
        Proceed(sample: PerCent(2), hold: None),
      ),
      When(
        policy.All([
          policy.is(action(), "hide"),
          policy.is(category(), domain.violation_name(domain.Spam)),
          policy.at_least(confidence(), confident),
        ]),
        // A senior may take a confident hide of spam back within the undo
        // window, and an edit during it supersedes the hide.
        Proceed(sample: PerCent(2), hold: Some(duration.minutes(undo_minutes))),
      ),
      escalation(),
      When(
        policy.All([
          policy.is(action(), "hide"),
          policy.is(category(), domain.violation_name(domain.Abuse)),
        ]),
        Ask(Several(2, AnyoneHolding(moderators))),
      ),
    ],
    otherwise: Ask(AnyoneHolding(moderators)),
  )
}
