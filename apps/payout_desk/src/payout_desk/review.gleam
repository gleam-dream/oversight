//// Learning from the recorded payouts: export each one as a self-contained
//// example, tally how often finance let the agent's proposal through and
//// how often it lowered the amount, and replay a stricter candidate model
//// against what finance decided.
////
//// A replay runs the candidate on the example alone: the request and the
//// reads the agent's model received, as they were recorded. It reaches no
//// database, no provider and no gated tool.

import decisions
import decisions/learning.{type Example, type Replay, type Tally, Archive}
import decisions/model.{type Model}
import decisions/occurrence.{type Occurrence}
import decisions/vocabulary.{Correct, Recommendation, RuleFired, Rules}
import decisions_postgres
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/time/timestamp
import payout_desk/domain.{type Payout, Payout}
import payout_desk/reads
import pog

/// What finance did with the agent's proposals.
pub type Summary {
  Summary(
    /// Agreement as `decisions/learning` counts it: of the payouts people
    /// let through, how many went through as the agent proposed.
    tally: Tally,
    /// Payouts where finance lowered the amount. The tally counts the
    /// rejections (`tally.rejected`).
    lowered: Int,
  )
}

/// Every recorded payout, read through its desk.
pub fn recorded(
  db: pog.Connection,
  desk: decisions.Desk(Payout, pog.Connection),
) -> Result(List(Occurrence(Payout)), String) {
  decisions_postgres.transaction(db, fn(tx) {
    use ids <- result.try(
      decisions_postgres.inspection().occurrences(tx, domain.payout_point_name)
      |> result.map_error(decisions.StoreFailed),
    )
    list.sort(ids, string.compare)
    |> list.try_map(fn(id) { decisions.read(desk, tx, occurrence: id) })
  })
  |> result.map_error(decisions_postgres.describe)
}

pub fn summary(known: List(Occurrence(Payout))) -> Summary {
  Summary(
    tally: learning.tally(known) |> learning.total,
    lowered: list.count(known, lowered),
  )
}

fn lowered(known: Occurrence(Payout)) -> Bool {
  list.any(occurrence.verdicts(known), fn(given) {
    case given.1 {
      Correct(output:, ..) ->
        output.amount_cents < known.recommendation.output.amount_cents
      _ -> False
    }
  })
}

/// Each payout as it was known now, with every input resolved from the
/// record. One the archive cannot resolve is left out and named.
pub fn export(
  db: pog.Connection,
  known: List(Occurrence(Payout)),
) -> #(List(Example(Payout)), List(#(String, learning.ExportError))) {
  let archive =
    Archive(
      render: fn(context) { Ok(context.renderer) },
      reads: fn(_) { [] },
      content: reads.content(db),
    )
  let now = timestamp.system_time()
  list.fold(known, #([], []), fn(done, k) {
    case learning.example(k, as_of: now, from: archive) {
      Ok(example) -> #([example, ..done.0], done.1)
      Error(error) -> #(done.0, [#(k.id, error), ..done.1])
    }
  })
  |> fn(done) { #(list.reverse(done.0), list.reverse(done.1)) }
}

/// A stricter payout rule: the seller bears the chargeback fee, so it
/// proposes what the dispute owes less the fee.
pub fn stricter() -> Model(Payout) {
  model.over(domain.read_case(), fn(case_: domain.Case) {
    Ok(
      Recommendation(
        output: Payout(
          seller: case_.request.seller,
          order: case_.request.order,
          amount_cents: case_.dispute.seller_owed_cents
            - case_.dispute.fee_cents,
          reason: "dispute correction, less the chargeback fee",
        ),
        by: Rules(name: "seller_bears_fee", version: "1"),
        explanation: RuleFired("owed_less_fee"),
        signals: [],
        reads: [],
      ),
    )
  })
}

/// What a candidate would have proposed for one payout, beside what was
/// recorded.
pub type Change {
  Change(
    occurrence: String,
    proposed_cents: Int,
    decided: Option(Int),
    candidate_cents: Result(Int, model.Failure),
  )
}

/// Replay `candidate` on the examples: its score against what finance let
/// through, and what it would have proposed for each payout.
pub fn replay(
  examples: List(Example(Payout)),
  candidate: Model(Payout),
) -> #(Replay, List(Change)) {
  let scored =
    learning.replay(examples, candidate, same: fn(a: Payout, b: Payout) {
      a.amount_cents == b.amount_cents
    })
  let changes =
    list.map(examples, fn(example) {
      let known = example.known
      Change(
        occurrence: known.id,
        proposed_cents: known.recommendation.output.amount_cents,
        decided: occurrence.final(known)
          |> option.map(fn(p: Payout) { p.amount_cents }),
        candidate_cents: model.run(
          candidate,
          known.context,
          learning.sources(example),
        )
          |> result.map(fn(r) { r.output.amount_cents }),
      )
    })
  #(scored, changes)
}
