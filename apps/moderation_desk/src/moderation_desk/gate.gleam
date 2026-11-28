//// The autonomy ladder's gate. Before a policy version that lets more
//// posts through is published, the decisions moderators already made are
//// replayed against the candidate classifier and policy, in parallel
//// across the schedulers, with no network and no gated tool. The
//// candidate is published only when, among the posts it would let
//// through without a person, it agrees with the moderators often enough.
////
//// The library replays a model (`decisions_otp/replay`) and judges a
//// candidate model under a candidate policy on a recorded example
//// (`decisions/learning.candidate_under`): a candidate's autonomy is the
//// candidate policy's answer to the candidate model's output.

import decisions.{type Desk}
import decisions/learning.{type Example, Archive}
import decisions/model
import decisions/occurrence
import decisions/policy.{type Policy}
import decisions_otp/replay
import decisions_otp/store.{type Store, type Tx}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import moderation_desk/domain.{type Action}
import moderation_desk/models
import moderation_desk/point
import moderation_desk/wiring

/// A classifier version and the policy version that would go with it.
pub type Candidate {
  Candidate(name: String, classifier: String, policy: Policy)
}

/// What the application requires before it publishes a candidate.
pub type Threshold {
  Threshold(
    /// Agreement with the moderators, in per cent, among the examples the
    /// candidate policy would let through without a person.
    agreement_per_cent: Int,
    /// How many examples the candidate must let through at least, so that
    /// the agreement means something.
    at_least: Int,
  )
}

/// What the replay found.
pub type Report {
  Report(
    examples: Int,
    /// Examples where the candidate classifier's action equals the action
    /// moderators let through, over all judged examples.
    model_agreed: Int,
    model_judged: Int,
    /// Examples the candidate policy would let through without a person,
    /// and how many of those match the moderators.
    would_proceed: Int,
    agreed_on_proceed: Int,
    /// Examples the candidate could not answer from the record.
    unanswered: Int,
    /// Examples whose recorded author history has changed since: the
    /// author got a strike after the model read it.
    drifted: Int,
    /// How many processes the replay ran on.
    across: Int,
  )
}

/// Whether the candidate was published.
pub type Outcome {
  Published(report: Report)
  Held(report: Report)
}

/// The decisions moderators made, as self-contained examples: every
/// occurrence of the point with at least one verdict, as known now, read
/// a page at a time.
pub fn examples(
  s: Store,
  desk: Desk(Action, Tx),
) -> Result(List(Example(Action)), String) {
  let archive =
    Archive(
      render: fn(context) {
        Ok(
          context.renderer
          <> ":"
          <> string.join(list.map(context.refs, fn(ref) { ref.id }), ","),
        )
      },
      reads: fn(_) { [] },
      content: wiring.content(s),
    )
  let now = store.now(s)
  judged(s, desk, None, [])
  |> list.try_map(fn(known) {
    learning.example(known, as_of: now, from: archive)
    |> result.map_error(fn(error) { known.id <> ": " <> string.inspect(error) })
  })
}

fn judged(
  s: Store,
  desk: Desk(Action, Tx),
  after: Option(store.Cursor),
  so_far: List(occurrence.Occurrence(Action)),
) -> List(occurrence.Occurrence(Action)) {
  let page = store.occurrences_of(s, point.name, after:, limit: 500)
  let found =
    list.filter_map(page.ids, fn(id) {
      store.transaction(s, decisions.read(desk, _, occurrence: id))
      |> result.replace_error(Nil)
      |> result.try(fn(known) {
        case occurrence.verdicts(known) {
          [] -> Error(Nil)
          _ -> Ok(known)
        }
      })
    })
  let so_far = list.append(so_far, found)
  case page.next {
    Some(next) -> judged(s, desk, Some(next), so_far)
    None -> so_far
  }
}

/// Replay the examples against a candidate on `across` processes.
pub fn replay(
  s: Store,
  examples: List(Example(Action)),
  candidate: Candidate,
  across across: Int,
) -> Report {
  let model = models.candidate(candidate.classifier)
  let scored =
    replay.replay(examples, model, same: fn(a, b) { a == b }, across:)
  let proceeded =
    replay.map(examples, across, fn(example) {
      would_proceed(example, model, candidate.policy)
    })
    |> list.filter_map(fn(answer) {
      case answer {
        Ok(Some(agrees)) -> Ok(agrees)
        _ -> Error(Nil)
      }
    })
  let latest = fn(ref) { wiring.reading(s, fn(tx) { wiring.latest(tx)(ref) }) }
  Report(
    examples: list.length(examples),
    model_agreed: scored.tally.agreed,
    model_judged: scored.tally.judged,
    would_proceed: list.length(proceeded),
    agreed_on_proceed: list.count(proceeded, fn(agrees) { agrees }),
    unanswered: list.length(scored.unanswered),
    drifted: list.count(examples, fn(example) {
      list.any(example.known.recommendation.reads, fn(ref) {
        ref.kind == wiring.author_history && latest(ref) != ref.revision
      })
    }),
    across:,
  )
}

/// `Some(agrees)` when the candidate policy would let the candidate's
/// answer through without a person; `None` when it would ask, the
/// candidate cannot answer, or people let nothing through.
fn would_proceed(
  example: Example(Action),
  model: model.Model(Action),
  candidate: Policy,
) -> Option(Bool) {
  case
    learning.candidate_under(
      example,
      candidate: model,
      policy: candidate,
      point: point.declaration(),
    )
  {
    // An occurrence people only rejected let nothing through: it is not
    // judged, as `decisions/learning` does not judge it.
    Ok(#(recommendation, policy.Proceed(..))) ->
      occurrence.final(example.known)
      |> option.map(fn(passed) { passed == recommendation.output })
    Ok(_) | Error(_) -> None
  }
}

/// Whether the report clears the threshold.
pub fn clears(report: Report, threshold: Threshold) -> Bool {
  report.would_proceed >= threshold.at_least
  && report.agreed_on_proceed * 100
  >= threshold.agreement_per_cent * report.would_proceed
}

/// Replay, and publish the candidate's policy and classifier only when
/// the report clears the threshold.
pub fn publish_if_clear(
  s: Store,
  desk: Desk(Action, Tx),
  candidate: Candidate,
  threshold: Threshold,
  across across: Int,
) -> Result(Outcome, String) {
  use examples <- result.try(examples(s, desk))
  let report = replay(s, examples, candidate, across:)
  case clears(report, threshold) {
    False -> Ok(Held(report))
    True ->
      store.transaction(s, fn(tx) {
        wiring.publish(tx, candidate.policy, candidate.classifier)
        |> result.replace(Published(report))
        |> result.map_error(fn(faults) {
          "the candidate policy is not publishable: "
          <> string.join(list.map(faults, policy.describe), "; ")
        })
      })
  }
}

/// A report as one line for a person.
pub fn describe(report: Report) -> String {
  int.to_string(report.agreed_on_proceed)
  <> " of "
  <> int.to_string(report.would_proceed)
  <> " let through agree with the moderators; the classifier alone agrees on "
  <> int.to_string(report.model_agreed)
  <> " of "
  <> int.to_string(report.model_judged)
}
