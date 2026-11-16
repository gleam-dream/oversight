//// What follows a settlement. The runtime's dispatcher calls `settled`
//// once per settled occurrence, in the transaction that marks the
//// settlement delivered, so the post's visibility, the author's strike,
//// the safety case and the author's notification commit with that mark
//// or not at all.

import decisions.{type HandlerFailure}
import decisions/occurrence.{type Occurrence}
import decisions/vocabulary.{DeadlinePassed, Superseded}
import decisions_otp/store.{type Tx}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import moderation_desk/domain.{type Action, type Settlement}
import moderation_desk/wiring

/// The platform's reading of how an occurrence ended. `Error` for one
/// that has not settled.
pub fn settlement(known: Occurrence(Action)) -> Result(Settlement, Nil) {
  case known.status {
    occurrence.Released(final:, ..) -> Ok(domain.Decided(final))
    occurrence.Expired(cause: Superseded(_)) -> Ok(domain.Superseded)
    occurrence.Expired(cause: DeadlinePassed) ->
      Ok(domain.Unreleased(domain.NobodyDecided))
    occurrence.Rejected(_) -> Ok(domain.Unreleased(domain.ModeratorRejected))
    occurrence.Withdrawn(_) -> Ok(domain.TakenBack)
    occurrence.Refused(_) -> Ok(domain.Unreleased(domain.ReleaseRefused))
    occurrence.Recommended(_)
    | occurrence.Awaiting(_)
    | occurrence.Accepted(..)
    | occurrence.Held(..) -> Error(Nil)
  }
}

/// The revision of the post an occurrence is about, from its context.
pub fn revision_of(known: Occurrence(Action)) -> Result(Int, Nil) {
  list.find(known.context.refs, fn(ref) { ref.kind == "post" })
  |> result.try(fn(ref) { int.parse(ref.revision) })
}

/// Apply a settlement to the platform's state. A settlement about a
/// revision an edit has since replaced changes nothing: the edit's own
/// decision will. An edit supersedes what is expected, waiting or held,
/// but not what is released: a release committed just before the edit
/// can have its settlement delivered just after it, and that one must not
/// overwrite the new revision's visibility.
pub fn settled(
  tx: Tx,
  known: Occurrence(Action),
) -> Result(Nil, HandlerFailure) {
  use found <- result.try(
    settlement(known)
    |> result.replace_error(decisions.ApplicationFailed(
      "the occurrence " <> known.id <> " has not settled",
    )),
  )
  let post_id = known.subject.id
  use Nil <- result.try(
    wiring.lock_visibility(tx, post_id)
    |> result.map_error(fn(error) {
      decisions.DeskRefused(decisions.StoreFailed(error))
    }),
  )
  use post <- result.try(
    wiring.post(tx, post_id)
    |> result.replace_error(decisions.ApplicationFailed("no post " <> post_id)),
  )
  case revision_of(known) == Ok(post.revision) {
    False -> Ok(Nil)
    True -> {
      let consequence = domain.consequence(found)
      case consequence.visibility {
        Some(visibility) -> wiring.set_visibility(tx, post_id, visibility)
        None -> Nil
      }
      case consequence.strike, wiring.author(tx, post.author) {
        True, Ok(author) -> wiring.put_author(tx, domain.strike(author, by: 1))
        _, _ -> Nil
      }
      case found {
        domain.Decided(domain.Escalate(reason)) ->
          store.put(tx, wiring.safety, post_id, reason)
        _ -> Nil
      }
      case consequence.notify {
        Some(notification) -> wiring.notify(tx, post_id, known.id, notification)
        None -> Nil
      }
      Ok(Nil)
    }
  }
}
