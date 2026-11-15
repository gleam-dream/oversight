//// The platform's own moderation vocabulary: posts, authors and threads,
//// the action a model recommends for a post, and the pure decisions about
//// what a settled decision means for the post and its author.
////
//// Nothing here reads a store or starts a process. The decision point's
//// output is `Action`; everything the library records about it goes
//// through `action_codec`.

import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import json/blueprint/codec.{type Codec}

/// A post at one revision. An edit makes a new revision of the same id.
pub type Post {
  Post(id: String, author: String, thread: String, text: String, revision: Int)
}

/// A rule of the platform that a post can break.
pub type Violation {
  Spam
  Abuse
  SelfHarm
  Violence
}

/// What a classifier says a post is.
pub type Category {
  Clean
  Breaks(violation: Violation)
}

/// What to do with a post: the decision point's output.
pub type Action {
  /// Show the post.
  Publish
  /// Hide the post because it breaks `reason`.
  Hide(reason: Violation)
  /// Hide the post and hand it to the safety team, for `reason`.
  Escalate(reason: String)
}

/// What the platform knows about an author. A model reads it as the
/// author's history; it changes when a post of theirs is hidden.
pub type Author {
  Author(id: String, joined_days: Int, posts: Int, strikes: Int)
}

/// What the platform knows about a thread.
pub type Thread {
  Thread(id: String, heated: Bool)
}

/// Whether readers see a post.
pub type Visibility {
  /// Not decided yet.
  Pending
  Published
  Hidden(reason: Violation)
  /// Hidden and handed to the safety team.
  WithSafetyTeam(reason: String)
  /// Hidden until a person looks again, because no decision released an
  /// action for it.
  HiddenPendingReview(why: Unreleased)
}

/// Why a settled decision released no action.
pub type Unreleased {
  /// Nobody decided before the decision's validity passed.
  NobodyDecided
  /// A moderator rejected the recommendation without giving an action.
  ModeratorRejected
  /// The gated tool refused the release.
  ReleaseRefused
}

/// What the author is told.
pub type Notification {
  YourPostIsLive
  YourPostWasHidden(reason: Violation)
  YourPostIsWithTheSafetyTeam
  YourPostAwaitsReview
  YourAppealWasUpheld
  YourAppealWasDismissed
}

/// How a decision about one revision of a post ended, in the platform's
/// words.
pub type Settlement {
  Decided(action: Action)
  /// An edit made the decision moot; the new revision has its own.
  Superseded
  Unreleased(why: Unreleased)
}

/// What a settlement changes: the post's visibility, a strike on the
/// author, and what the author is told. `None` leaves the visibility as it
/// is.
pub type Consequence {
  Consequence(
    visibility: Option(Visibility),
    strike: Bool,
    notify: Option(Notification),
  )
}

/// The consequence of a settlement. A superseded decision changes nothing
/// and tells nobody: the edit's own decision will.
pub fn consequence(settlement: Settlement) -> Consequence {
  case settlement {
    Decided(Publish) ->
      Consequence(Some(Published), strike: False, notify: Some(YourPostIsLive))
    Decided(Hide(reason)) ->
      Consequence(
        Some(Hidden(reason)),
        strike: True,
        notify: Some(YourPostWasHidden(reason)),
      )
    Decided(Escalate(reason)) ->
      Consequence(
        Some(WithSafetyTeam(reason)),
        strike: False,
        notify: Some(YourPostIsWithTheSafetyTeam),
      )
    Superseded -> Consequence(None, strike: False, notify: None)
    Unreleased(why) ->
      Consequence(
        Some(HiddenPendingReview(why)),
        strike: False,
        notify: Some(YourPostAwaitsReview),
      )
  }
}

/// An author who joined less than a week ago.
pub fn is_new(author: Author) -> Bool {
  author.joined_days < 7
}

/// The author with one more strike, or one fewer when an appeal undoes a
/// hide. Strikes never go below zero.
pub fn strike(author: Author, by by: Int) -> Author {
  let strikes = author.strikes + by
  Author(..author, strikes: case strikes < 0 {
    True -> 0
    False -> strikes
  })
}

/// A sensitive violation goes to a senior moderator, never straight
/// through.
pub fn is_sensitive(violation: Violation) -> Bool {
  case violation {
    SelfHarm | Violence -> True
    Spam | Abuse -> False
  }
}

/// The stable name of a violation, as a policy fact and a card show it.
pub fn violation_name(violation: Violation) -> String {
  case violation {
    Spam -> "spam"
    Abuse -> "abuse"
    SelfHarm -> "self_harm"
    Violence -> "violence"
  }
}

/// The stable name of a category: `"clean"` or the violation's name.
pub fn category_name(category: Category) -> String {
  case category {
    Clean -> "clean"
    Breaks(violation) -> violation_name(violation)
  }
}

/// The stable name of an action's kind: `"publish"`, `"hide"` or
/// `"escalate"`.
pub fn action_name(action: Action) -> String {
  case action {
    Publish -> "publish"
    Hide(_) -> "hide"
    Escalate(_) -> "escalate"
  }
}

// -- Codecs ---------------------------------------------------------------------

pub fn violation_codec() -> Codec(Violation) {
  codec.string_enum([
    #("spam", Spam),
    #("abuse", Abuse),
    #("self_harm", SelfHarm),
    #("violence", Violence),
  ])
}

/// The decision point's output codec. It carries the schema a card shows,
/// so a correction form can be built without this module.
pub fn action_codec() -> Codec(Action) {
  codec.union({
    use publish <- codec.unit_variant("publish", Publish)
    use hide <- codec.variant("hide", violation_codec(), Hide)
    use escalate <- codec.variant("escalate", codec.string(), Escalate)
    codec.match(fn(action) {
      case action {
        Publish -> publish
        Hide(reason) -> hide(reason)
        Escalate(reason) -> escalate(reason)
      }
    })
  })
}

pub fn post_codec() -> Codec(Post) {
  use id <- codec.field("id", codec.string(), get: fn(p: Post) { p.id })
  use author <- codec.field("author", codec.string(), get: fn(p: Post) {
    p.author
  })
  use thread <- codec.field("thread", codec.string(), get: fn(p: Post) {
    p.thread
  })
  use text <- codec.field("text", codec.string(), get: fn(p: Post) { p.text })
  use revision <- codec.field("revision", codec.int(), get: fn(p: Post) {
    p.revision
  })
  codec.success(Post(id:, author:, thread:, text:, revision:))
}

pub fn author_codec() -> Codec(Author) {
  use id <- codec.field("id", codec.string(), get: fn(a: Author) { a.id })
  use joined_days <- codec.field("joined_days", codec.int(), get: fn(a: Author) {
    a.joined_days
  })
  use posts <- codec.field("posts", codec.int(), get: fn(a: Author) { a.posts })
  use strikes <- codec.field("strikes", codec.int(), get: fn(a: Author) {
    a.strikes
  })
  codec.success(Author(id:, joined_days:, posts:, strikes:))
}

pub fn thread_codec() -> Codec(Thread) {
  use id <- codec.field("id", codec.string(), get: fn(t: Thread) { t.id })
  use heated <- codec.field("heated", codec.bool(), get: fn(t: Thread) {
    t.heated
  })
  codec.success(Thread(id:, heated:))
}

fn unreleased_codec() -> Codec(Unreleased) {
  codec.string_enum([
    #("nobody_decided", NobodyDecided),
    #("moderator_rejected", ModeratorRejected),
    #("release_refused", ReleaseRefused),
  ])
}

pub fn visibility_codec() -> Codec(Visibility) {
  codec.union({
    use pending <- codec.unit_variant("pending", Pending)
    use published <- codec.unit_variant("published", Published)
    use hidden <- codec.variant("hidden", violation_codec(), Hidden)
    use safety <- codec.variant(
      "with_safety_team",
      codec.string(),
      WithSafetyTeam,
    )
    use review <- codec.variant(
      "hidden_pending_review",
      unreleased_codec(),
      HiddenPendingReview,
    )
    codec.match(fn(visibility) {
      case visibility {
        Pending -> pending
        Published -> published
        Hidden(reason) -> hidden(reason)
        WithSafetyTeam(reason) -> safety(reason)
        HiddenPendingReview(why) -> review(why)
      }
    })
  })
}

pub fn notification_codec() -> Codec(Notification) {
  codec.union({
    use live <- codec.unit_variant("live", YourPostIsLive)
    use hidden <- codec.variant("hidden", violation_codec(), YourPostWasHidden)
    use safety <- codec.unit_variant(
      "with_safety_team",
      YourPostIsWithTheSafetyTeam,
    )
    use review <- codec.unit_variant("awaits_review", YourPostAwaitsReview)
    use upheld <- codec.unit_variant("appeal_upheld", YourAppealWasUpheld)
    use dismissed <- codec.unit_variant(
      "appeal_dismissed",
      YourAppealWasDismissed,
    )
    codec.match(fn(notification) {
      case notification {
        YourPostIsLive -> live
        YourPostWasHidden(reason) -> hidden(reason)
        YourPostIsWithTheSafetyTeam -> safety
        YourPostAwaitsReview -> review
        YourAppealWasUpheld -> upheld
        YourAppealWasDismissed -> dismissed
      }
    })
  })
}

/// Encode a value as JSON text. Every codec here encodes every value of
/// its type, so an error is a defect in this module.
pub fn to_text(codec: Codec(a), value: a) -> String {
  case codec.to_json(codec, value) {
    Ok(encoded) -> json.to_string(encoded)
    Error(error) -> panic as codec.describe_encode_error(error)
  }
}

/// Decode JSON text written by `to_text`.
pub fn from_text(codec: Codec(a), text: String) -> Result(a, String) {
  codec.decode_json(codec, text)
  |> result.map_error(codec.describe_decode_error)
}
