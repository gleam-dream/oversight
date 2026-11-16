//// The two decision points bound to their gated tools, their published
//// policies and the PostgreSQL port.
////
//// - `payout`: the gated tool writes the payout instruction inside the
////   transaction that releases it. Its guard re-checks that the seller's
////   account is active, and the desk's release check (`checking`) refuses
////   an amount the available balance does not cover and records the
////   balance it compared on the release. Nothing here pays: the
////   settlement's follower starts the workflow that does (`jobs`).
//// - `risk`: consulted for a seller with a recent chargeback. A rule
////   recommends, its policy lets the answer through, and its gated tool
////   informs the payout that consulted it, in the same transaction.

import decisions.{type Desk, type Gated, Gated}
import decisions/fact
import decisions/store.{type Port}
import decisions/vocabulary.{
  type Ref, Manifest, ParentOccurrence, Recommendation, Ref, RuleFired, Rules,
  Subject, Trigger,
}
import gleam/int
import gleam/option.{Some}
import gleam/result
import gleam/time/duration.{type Duration}
import payout_desk/db
import payout_desk/domain.{type Payout, type Risk}
import pog

/// What the desks are built over.
pub type Desks {
  Desks(
    port: Port(pog.Connection),
    validity: Duration,
    /// A fault point for the tests: `True` makes the payout's guard lose
    /// its database connection once more. `fn() { False }` otherwise.
    guard_fault: fn() -> Bool,
  )
}

pub fn payout(desks: Desks) -> Desk(Payout, pog.Connection) {
  decisions.desk(
    domain.payout_point(validity: desks.validity),
    drives: fn(_) { write_instruction(desks) },
    under: db.current_policy(_, domain.payout_point_name),
    over: desks.port,
  )
  |> decisions.checking(with: covered)
  |> decisions.consulting(with: fn(tx, consultation) {
    // A point is consulted by name; this desk knows one.
    case consultation.point == domain.risk_point_name {
      True ->
        assess(desks, tx, consultation.occurrence, consultation.subject.id)
      False -> Error("no point answers " <> consultation.point)
    }
  })
}

pub fn risk(desks: Desks) -> Desk(Risk, pog.Connection) {
  decisions.desk(
    domain.risk_point(),
    drives: fn(_) { inform_payout(desks) },
    under: db.current_policy(_, domain.risk_point_name),
    over: desks.port,
  )
}

/// The release check: the seller's available balance covers the payout
/// that stands. The balance it compared is recorded on the release. A
/// balance that does not cover it refuses the release; a database that
/// does not answer says nothing about it (`Unsure`), so it is tried again.
fn covered(
  tx: pog.Connection,
  release: decisions.ToRelease(Payout),
) -> Result(List(Ref), decisions.Stop) {
  let payout = release.output
  use #(_, available) <- result.try(
    db.available(tx, payout.seller) |> result.map_error(unsure),
  )
  case available >= payout.amount_cents {
    True ->
      Ok([
        Ref(
          kind: "seller_available_cents",
          id: payout.seller,
          revision: int.to_string(available),
        ),
      ])
    False ->
      Error(
        decisions.Refuse(
          db.describe(db.Insufficient(available, payout.amount_cents)),
        ),
      )
  }
}

/// A database failure is no judgment about the release: try again.
fn unsure(error: db.DbError) -> decisions.Stop {
  decisions.Unsure(db.describe(error))
}

/// The payout's gated tool. Its guard re-checks that the seller's account
/// is active; the release check above compares the amount.
fn write_instruction(desks: Desks) -> Gated(Payout, pog.Connection) {
  Gated(
    name: "write_payout_instruction",
    guard: fn(tx, subject) {
      use Nil <- result.try(case desks.guard_fault() {
        True -> Error(decisions.Unsure("the database connection dropped"))
        False -> Ok(Nil)
      })
      use #(status, _) <- result.try(
        db.available(tx, subject.id) |> result.map_error(unsure),
      )
      case status {
        "active" ->
          Ok([Ref(kind: "seller_status", id: subject.id, revision: status)])
        _ -> Error(decisions.Refuse("the seller's account is " <> status))
      }
    },
    execute: fn(tx, released) {
      let payout: Payout = decisions.output(released)
      db.write_instruction(
        tx,
        db.Instruction(
          release_key: decisions.key(released),
          occurrence: decisions.occurrence_of(released),
          seller: payout.seller,
          order: payout.order,
          amount_cents: payout.amount_cents,
        ),
      )
      |> result.map_error(unsure)
    },
  )
}

/// The consult handler: the risk rule recommends about the seller, once
/// per consulting payout.
fn assess(
  desks: Desks,
  tx: pog.Connection,
  payout: String,
  seller: String,
) -> Result(Nil, String) {
  use chargebacks <- result.try(
    db.chargebacks_90_days(tx, seller) |> result.map_error(db.describe),
  )
  decisions.recommend_once(
    risk(desks),
    tx,
    key: "risk:" <> payout,
    proposal: decisions.proposal(
      trigger: Trigger(kind: "consultation", id: payout),
      about: Subject(kind: "seller", id: seller),
      context: Manifest(
        refs: [Ref("chargebacks_90_days", seller, int.to_string(chargebacks))],
        renderer: "risk-1",
      ),
      recommending: Recommendation(
        output: domain.assess_risk(chargebacks),
        by: Rules(name: "chargeback-rule", version: "1"),
        explanation: RuleFired("chargebacks_in_90_days"),
        signals: [],
        reads: [],
      ),
    )
      |> decisions.hanging_from(ParentOccurrence(payout)),
  )
  |> result.replace(Nil)
  |> result.map_error(decisions.describe)
}

/// The risk point's gated tool: its released answer becomes a fact of the
/// payout that consulted it.
fn inform_payout(desks: Desks) -> Gated(Risk, pog.Connection) {
  Gated(
    name: "inform_payout",
    guard: fn(_, _) { Ok([]) },
    execute: fn(tx, released) {
      use consulted_by <- result.try(case decisions.parent(released) {
        Some(ParentOccurrence(id:)) -> Ok(id)
        _ -> Error(decisions.Refuse("the risk answer hangs from no payout"))
      })
      let answer: Risk = decisions.output(released)
      decisions.inform(
        payout(desks),
        tx,
        occurrence: consulted_by,
        from: domain.risk_point_name,
        facts: [fact.set(domain.risk_level(), answer.level)],
      )
      |> result.replace(Nil)
      |> result.map_error(fn(refusal) {
        case decisions.disposition(refusal) {
          decisions.Transient | decisions.Retry ->
            decisions.Unsure(decisions.describe(refusal))
          decisions.Poisoned | decisions.Final ->
            decisions.Refuse(decisions.describe(refusal))
        }
      })
    },
  )
}
