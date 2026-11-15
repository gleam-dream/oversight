//// Learning from the record: export the recorded registrations as
//// training examples, measure how often people agreed with the model,
//// replay the examples against another configuration, flag reads that no
//// longer match the world, and use agreement as the gate for publishing
//// policy version 2.
////
//// What a replay can answer: a configuration that sends the same request
//// bytes as the recorded call gets the recorded answer, so a change in how
//// the answer is read can be scored without a provider. A configuration
//// with another prompt sends other bytes; the record holds no answer for
//// them, and the replay reports each such example as unanswered
//// (`NotRecorded`). Scoring a new prompt needs a re-run against the
//// provider (`rerun`), on the recorded context, and its answers are new
//// evidence, not a replay of what happened.

import clinic_registration/desk
import clinic_registration/domain.{type Registration}
import clinic_registration/llm
import clinic_registration/store
import decisions.{type Desk}
import decisions/learning.{type Example, type Replay, type Tally, Archive}
import decisions/model
import decisions/occurrence.{type Occurrence}
import decisions/vocabulary.{type Ref}
import decisions_postgres/queue
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import http_gun
import pog

/// Every registration the record holds, in id order, read page by page
/// from the heads (`decisions_postgres/queue.occurrences_of`).
pub fn recorded(
  db: pog.Connection,
  desk: Desk(Registration, pog.Connection),
) -> Result(List(Occurrence(Registration)), String) {
  recorded_after(db, desk, None, [])
}

fn recorded_after(
  db: pog.Connection,
  desk: Desk(Registration, pog.Connection),
  after: Option(String),
  so_far: List(Occurrence(Registration)),
) -> Result(List(Occurrence(Registration)), String) {
  use page <- result.try(
    queue.occurrences_of(db, point: domain.point_name, limit: 100, after:)
    |> result.map_error(store.describe),
  )
  use read <- result.try(
    list.try_map(page, fn(summary) {
      decisions.read(desk, db, occurrence: summary.occurrence)
      |> result.map_error(decisions.describe)
    }),
  )
  let so_far = list.append(so_far, read)
  // A short page is the last one.
  case list.length(page) == 100, list.last(page) {
    True, Ok(last) -> recorded_after(db, desk, Some(last.occurrence), so_far)
    _, _ -> Ok(so_far)
  }
}

/// Where an example's parts come from. The prompt a provider was sent is
/// the request inside the exchange, which an example carries as a read.
/// `render` sees only the manifest, and the exchange is captured after the
/// manifest is built, so it cannot be one of the manifest's references:
/// `render` names the renderer.
pub fn archive(db: pog.Connection) -> learning.Archive {
  Archive(
    render: fn(manifest) { Ok("rendered by " <> manifest.renderer) },
    reads: llm.receipt,
    content: store.resolver(db),
  )
}

/// The recorded registrations as examples, each as it was known at
/// `as_of`.
pub fn export(
  db: pog.Connection,
  occurrences: List(Occurrence(Registration)),
  as_of as_of: Timestamp,
) -> Result(List(Example(Registration)), String) {
  list.try_map(occurrences, fn(known) {
    learning.example(known, as_of:, from: archive(db))
    |> result.map_error(describe_export_error)
  })
}

fn describe_export_error(error: learning.ExportError) -> String {
  case error {
    learning.NotYetRecommended -> "not recommended at that time"
    learning.RenderFailed(reason:) -> "render failed: " <> reason
    learning.MissingContent(ref:, failure:) ->
      "missing "
      <> ref.kind
      <> "("
      <> ref.id
      <> "): "
      <> model.describe(failure)
  }
}

/// The examples as `decision-example.v1` documents, as a training lake
/// keeps them.
pub fn documents(examples: List(Example(Registration))) -> List(Json) {
  list.filter_map(examples, fn(example) {
    learning.example_to_json(example, decisions.codec(domain.point()))
  })
}

/// How often people let the model's registration through unchanged:
/// `decisions/learning.tally` over every recommender. An occurrence people
/// only rejected is not judged; the tally counts it as `rejected`.
pub fn agreement(occurrences: List(Occurrence(Registration))) -> Tally {
  learning.tally(occurrences) |> learning.total
}

/// The share of judged registrations people agreed with, counting each
/// rejection as a disagreement.
pub fn agreement_rate(agreement: Tally) -> Float {
  case agreement.judged + agreement.rejected {
    0 -> 0.0
    total -> int.to_float(agreement.agreed) /. int.to_float(total)
  }
}

/// Replay the examples against a configuration, answering the provider
/// call from the recorded exchanges.
pub fn replay(
  examples: List(Example(Registration)),
  configuration: llm.Configuration,
  provider: llm.Provider,
) -> Replay {
  learning.replay(
    examples,
    llm.replaying(configuration, provider),
    same: fn(a, b) { a == b },
  )
}

/// Run a configuration on the recorded contexts against the provider. Its
/// reads come from the record; its provider answers are new, and are kept
/// as evidence.
pub fn rerun(
  db: pog.Connection,
  examples: List(Example(Registration)),
  configuration: llm.Configuration,
  provider: llm.Provider,
  client: http_gun.Client,
) -> Replay {
  learning.replay(
    examples,
    llm.live(configuration, provider, client, llm.capture(db)),
    same: fn(a, b) { a == b },
  )
}

/// A read the model received that would answer differently now.
pub type Drift {
  Drift(
    occurrence: String,
    read: String,
    argument: String,
    recorded: Ref,
    now: String,
  )
}

/// Every read in the examples whose content has changed since the model
/// received it, by `latest` (`llm.latest`).
pub fn drift(
  examples: List(Example(Registration)),
  latest: fn(Ref) -> String,
) -> List(Drift) {
  list.flat_map(examples, fn(example) {
    list.filter_map(example.reads, fn(pair) {
      let read: learning.Read = pair.0
      let now = latest(read.result)
      case now == read.result.revision {
        True -> Error(Nil)
        False ->
          Ok(Drift(
            occurrence: example.known.id,
            read: read.name,
            argument: read.argument,
            recorded: read.result,
            now:,
          ))
      }
    })
  })
}

/// When the clinic trusts the model enough to let some registrations
/// proceed without reception.
pub type Gate {
  Gate(min_judged: Int, min_agreement: Float)
}

/// Why the gate stays closed.
pub type Closed {
  TooFewJudged(judged: Int, needed: Int)
  TooLittleAgreement(rate: Float, needed: Float)
}

pub fn check_gate(agreement: Tally, gate: Gate) -> Result(Nil, Closed) {
  let judged = agreement.judged + agreement.rejected
  let rate = agreement_rate(agreement)
  case judged < gate.min_judged, rate <. gate.min_agreement {
    True, _ -> Error(TooFewJudged(judged:, needed: gate.min_judged))
    False, True -> Error(TooLittleAgreement(rate:, needed: gate.min_agreement))
    False, False -> Ok(Nil)
  }
}

/// Why version 2 was not published.
pub type PromotionError {
  GateClosed(Closed)
  NotPublished(desk.PublishError)
}

/// Publish policy version 2 when the recorded agreement passes the gate.
pub fn promote(
  db: pog.Connection,
  agreement: Tally,
  gate: Gate,
) -> Result(Nil, PromotionError) {
  use Nil <- result.try(
    check_gate(agreement, gate) |> result.map_error(GateClosed),
  )
  desk.publish(db, domain.proceed_when_sure()) |> result.map_error(NotPublished)
}

/// The gate's verdict as one line.
pub fn describe_closed(closed: Closed) -> String {
  case closed {
    TooFewJudged(judged:, needed:) ->
      int.to_string(judged) <> " judged, " <> int.to_string(needed) <> " needed"
    TooLittleAgreement(rate:, needed:) ->
      percent(rate) <> " agreement, " <> percent(needed) <> " needed"
  }
}

/// A rate as a whole percentage.
pub fn percent(rate: Float) -> String {
  int.to_string(float.round(rate *. 100.0)) <> "%"
}
