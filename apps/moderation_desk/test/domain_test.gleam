//// The platform's vocabulary: codecs and what a settlement means.

import decisions/wire
import gleam/list
import gleam/option.{None, Some}
import moderation_desk/domain.{
  Abuse, Consequence, Decided, Escalate, Hidden, HiddenPendingReview, Hide,
  ModeratorRejected, NobodyDecided, Publish, Published, SelfHarm, Spam,
  Superseded, Unreleased, WithSafetyTeam,
}

pub fn every_action_round_trips_through_its_codec_test() {
  list.each([Publish, Hide(Spam), Hide(SelfHarm), Escalate("threat")], fn(a) {
    let text = domain.to_text(domain.action_codec(), a)
    assert domain.from_text(domain.action_codec(), text) == Ok(a)
  })
  assert domain.to_text(domain.action_codec(), Hide(Abuse))
    == "{\"tag\":\"hide\",\"value\":\"abuse\"}"
}

pub fn the_point_codec_carries_a_schema_for_correction_forms_test() {
  let assert Some(_) = wire.schema(wire.codec(domain.action_codec()))
}

pub fn every_visibility_round_trips_test() {
  list.each(
    [
      domain.Pending,
      Published,
      Hidden(Abuse),
      WithSafetyTeam("threat"),
      HiddenPendingReview(NobodyDecided),
    ],
    fn(v) {
      let text = domain.to_text(domain.visibility_codec(), v)
      assert domain.from_text(domain.visibility_codec(), text) == Ok(v)
    },
  )
}

pub fn a_settlement_decides_visibility_strike_and_notification_test() {
  assert domain.consequence(Decided(Publish))
    == Consequence(Some(Published), False, Some(domain.YourPostIsLive))
  assert domain.consequence(Decided(Hide(Abuse)))
    == Consequence(
      Some(Hidden(Abuse)),
      True,
      Some(domain.YourPostWasHidden(Abuse)),
    )
  assert domain.consequence(Decided(Escalate("threat")))
    == Consequence(
      Some(WithSafetyTeam("threat")),
      False,
      Some(domain.YourPostIsWithTheSafetyTeam),
    )
  assert domain.consequence(Superseded) == Consequence(None, False, None)
  assert domain.consequence(Unreleased(ModeratorRejected))
    == Consequence(
      Some(HiddenPendingReview(ModeratorRejected)),
      False,
      Some(domain.YourPostAwaitsReview),
    )
}

pub fn strikes_never_go_below_zero_test() {
  let author = domain.Author("a", 400, 0, 0)
  assert domain.strike(author, by: -1).strikes == 0
  assert domain.strike(author, by: 1).strikes == 1
}
