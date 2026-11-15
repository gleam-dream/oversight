//// Where the platform's users reach the decision point: a post arrives,
//// a post is edited, an author appeals. Each is one transaction over the
//// store, so the post, its trigger and anything the record says commit
//// together.

import decisions.{type Desk}
import decisions/occurrence
import decisions/store as port
import decisions/vocabulary.{Assessment, Ref, Right, Wrong}
import decisions_otp/store.{type Store, type Tx}
import gleam/bool
import gleam/list
import gleam/option.{Some}
import gleam/result
import moderation_desk/domain.{type Action, type Post, Post}
import moderation_desk/models
import moderation_desk/point
import moderation_desk/scripted
import moderation_desk/telemetry
import moderation_desk/wiring
import sinal

/// Seed the platform's authors and threads, and publish policy version 1
/// with classifier version 1, unless a policy is already published: a
/// seeded store is left as it is.
pub fn seed(s: Store) -> Result(Nil, String) {
  store.transaction(s, fn(tx) {
    use <- bool.guard(result.is_ok(wiring.current_policy(tx)), Ok(Nil))
    list.each(scripted.authors(), wiring.put_author(tx, _))
    list.each(scripted.threads(), wiring.put_thread(tx, _))
    wiring.publish(tx, point.version_1(), "1")
    |> result.replace_error("policy version 1 is not publishable")
  })
}

/// What receiving a post did.
pub type Receipt {
  /// The post's revision is admitted and its trigger is in the backlog.
  Admitted
  /// This revision was already admitted; nothing was written.
  Duplicate
}

/// A post revision arrives. Admission is by key under a lock, so two
/// deliveries of one revision, at once or apart, admit it once.
pub fn receive(
  s: Store,
  post: Post,
  source source: String,
) -> Result(Receipt, String) {
  let key = wiring.key(post)
  let outcome =
    store.transaction(s, fn(tx) {
      use Nil <- result.try(
        store.lock(tx, "intake:" <> key) |> result.map_error(store_text),
      )
      case store.get(tx, wiring.intake, key) {
        Ok(_) -> Ok(Duplicate)
        Error(Nil) -> {
          wiring.put_post(tx, post)
          wiring.set_visibility(tx, post.id, domain.Pending)
          admit(s, tx, post) |> result.replace(Admitted)
        }
      }
    })
  case outcome {
    Ok(receipt) ->
      sinal.emit(
        telemetry.post_received(),
        telemetry.Count(1),
        telemetry.Received(
          source:,
          post: post.id,
          duplicate: receipt == Duplicate,
        ),
      )
    Error(_) -> Nil
  }
  outcome
}

fn admit(s: Store, tx: Tx, post: Post) -> Result(Nil, String) {
  let key = wiring.key(post)
  store.put(tx, wiring.intake, key, "admitted")
  store.backlog(s).submit(tx, key, models.payload(post))
  |> result.map_error(store_text)
}

fn store_text(error: port.StoreError) -> String {
  port.describe(error)
}

/// What an edit did.
pub type Edited {
  Edited(post: Post, superseded: Int)
}

/// The author edits a post. The new revision is admitted, and every
/// waiting recommendation about the post expires as superseded in the
/// same transaction. The post's row names its latest revision, and both
/// this transaction and the one that recommends lock it, so a worker
/// still classifying the old revision recommends nothing
/// (`moderation_desk/models`).
pub fn edit(
  s: Store,
  desk: Desk(Action, Tx),
  post_id: String,
  text: String,
) -> Result(Edited, String) {
  store.transaction(s, fn(tx) {
    // Occurrences first, then the post's row, then its visibility. A
    // settlement takes an occurrence before the visibility, and a
    // recommending transaction takes the post's row before an occurrence
    // that does not exist yet, so no two of them wait for each other.
    use done <- result.try(
      decisions.happened(desk, tx, point.edited, about: wiring.subject(post_id))
      |> result.map_error(decisions.describe),
    )
    use Nil <- result.try(
      wiring.lock_post(tx, post_id) |> result.map_error(store_text),
    )
    use Nil <- result.try(
      wiring.lock_visibility(tx, post_id) |> result.map_error(store_text),
    )
    use current <- result.try(
      wiring.post(tx, post_id) |> result.replace_error("no post " <> post_id),
    )
    let next = Post(..current, text:, revision: current.revision + 1)
    wiring.put_post(tx, next)
    wiring.set_visibility(tx, post_id, domain.Pending)
    use Nil <- result.map(admit(s, tx, next))
    Edited(post: next, superseded: list.length(done.expired))
  })
}

/// What an appeal found.
pub type Appeal {
  /// The hide was wrong: the post is published again and the strike
  /// undone.
  Upheld
  /// The hide stands.
  Dismissed
}

/// The author appeals the decision about the current revision of a post,
/// and a senior has judged the appeal. The judgement is an assessment on
/// the released occurrence: it changes no verdict and no output, and
/// counts toward the recommender's accuracy. An upheld appeal publishes
/// the post again.
pub fn appeal(
  s: Store,
  desk: Desk(Action, Tx),
  post_id: String,
  judged: Appeal,
) -> Result(Nil, String) {
  store.transaction(s, fn(tx) {
    use post <- result.try(
      wiring.post(tx, post_id) |> result.replace_error("no post " <> post_id),
    )
    let key = wiring.key(post)
    use known <- result.try(
      decisions.read(desk, tx, occurrence: key)
      |> result.map_error(decisions.describe),
    )
    use Nil <- result.try(
      wiring.lock_visibility(tx, post_id) |> result.map_error(store_text),
    )
    use action <- result.try(case known.status {
      occurrence.Released(final: domain.Publish, ..) ->
        Error("a published post has nothing to appeal")
      occurrence.Released(final:, ..) -> Ok(final)
      _ -> Error("the decision about " <> post_id <> " released nothing")
    })
    use _ <- result.try(
      decisions.assess(
        desk,
        tx,
        occurrence: key,
        finding: Assessment(
          finding: case judged {
            Upheld -> Wrong(truth: Some(domain.Publish))
            Dismissed -> Right
          },
          evidence: Ref(kind: "appeal", id: post_id, revision: "1"),
          source: "appeals",
          known_at: store.now(s),
        ),
      )
      |> result.map_error(decisions.describe),
    )
    case judged {
      Upheld -> {
        wiring.set_visibility(tx, post_id, domain.Published)
        case action, wiring.author(tx, post.author) {
          domain.Hide(_), Ok(author) ->
            wiring.put_author(tx, domain.strike(author, by: -1))
          _, _ -> Nil
        }
        wiring.notify(tx, post_id, key, domain.YourAppealWasUpheld)
      }
      Dismissed ->
        wiring.notify(tx, post_id, key, domain.YourAppealWasDismissed)
    }
    Ok(Nil)
  })
}
