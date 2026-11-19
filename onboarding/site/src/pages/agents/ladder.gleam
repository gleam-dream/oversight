//// Up the ladder: four hundred refund recommendations under one policy
//// version. An illustrative model with seeded randomness: amounts and
//// confidences are simulated, and the model is wrong about as often as its
//// confidence says.

import gleam/float
import gleam/int
import gleam/list
import gleam/string
import pages/agents/point.{type Version}
import site/rng.{type Rng}

pub type Case {
  Case(
    /// The drawn amount before rounding, which places the dot.
    drawn_amount: Float,
    /// The drawn confidence before rounding, which places the dot.
    drawn_confidence: Float,
    amount: Int,
    confidence: Int,
    wrong: Bool,
    sampled: Bool,
  )
}

/// Who decides a case under a version.
pub type Route {
  ProceedsAlone
  AsksOne
  AsksTwo
}

pub type Tally {
  Tally(
    alone: Int,
    ask: Int,
    two: Int,
    /// Wrong recommendations that proceeded alone.
    slipped: Int,
    wrong: Int,
    /// Of those that slipped, the ones sampled for review afterwards.
    sampled_slipped: Int,
  )
}

/// The four hundred cases, always the same: seed 21, four draws per case.
pub fn cases() -> List(Case) {
  draw(rng.seed(21), 400, [])
}

fn draw(rng: Rng, count: Int, acc: List(Case)) -> List(Case) {
  case count {
    0 -> list.reverse(acc)
    _ -> {
      let #(r1, rng) = rng.next(rng)
      let #(r2, rng) = rng.next(rng)
      let #(r3, rng) = rng.next(rng)
      let #(r4, rng) = rng.next(rng)
      let drawn_amount = power(10.0, 1.0 +. power(r1, 1.6) *. 2.0)
      let amount = case drawn_amount <. 100.0 {
        True -> float.round(drawn_amount)
        False -> float.round(drawn_amount /. 5.0) * 5
      }
      let drawn_confidence = 100.0 -. power(r2, 1.8) *. 50.0
      let case_ =
        Case(
          drawn_amount:,
          drawn_confidence:,
          amount: int.clamp(amount, 10, 1000),
          confidence: int.clamp(float.round(drawn_confidence), 50, 100),
          wrong: r3 *. 100.0 >. drawn_confidence,
          sampled: r4 <. 0.1,
        )
      draw(rng, count - 1, [case_, ..acc])
    }
  }
}

fn power(base: Float, exponent: Float) -> Float {
  case float.power(base, exponent) {
    Ok(x) -> x
    Error(Nil) -> 0.0
  }
}

pub fn route(version: Version, case_: Case) -> Route {
  case
    point.proceeds(version, case_.amount, case_.confidence),
    point.needed(version, case_.amount, case_.confidence)
  {
    True, _ -> ProceedsAlone
    False, 2 -> AsksTwo
    False, _ -> AsksOne
  }
}

pub fn tally(version: Version, cases: List(Case)) -> Tally {
  use t, case_ <- list.fold(cases, Tally(0, 0, 0, 0, 0, 0))
  let route = route(version, case_)
  let t = case route {
    ProceedsAlone -> Tally(..t, alone: t.alone + 1)
    AsksOne -> Tally(..t, ask: t.ask + 1)
    AsksTwo -> Tally(..t, ask: t.ask + 1, two: t.two + 1)
  }
  case case_.wrong, route, case_.sampled {
    False, _, _ -> t
    True, ProceedsAlone, True ->
      Tally(
        ..t,
        wrong: t.wrong + 1,
        slipped: t.slipped + 1,
        sampled_slipped: t.sampled_slipped + 1,
      )
    True, ProceedsAlone, False ->
      Tally(..t, wrong: t.wrong + 1, slipped: t.slipped + 1)
    True, _, _ -> Tally(..t, wrong: t.wrong + 1)
  }
}

/// Minutes of finance's time at two minutes per approval.
pub fn minutes(tally: Tally) -> Int {
  { tally.ask + tally.two } * 2
}

pub fn minutes_text(minutes: Int) -> String {
  case minutes >= 60 {
    True -> fixed(int.to_float(minutes) /. 60.0, 1) <> " hours"
    False -> int.to_string(minutes) <> " minutes"
  }
}

pub fn safety_nets(version: Version, tally: Tally) -> String {
  case version {
    point.V1 ->
      "A person sees everything. Safe, and slow: nothing proceeds alone."
    point.V2 ->
      "One in ten of the cases that proceed alone is sampled for review after the fact ("
      <> int.to_string(tally.sampled_slipped)
      <> " of the wrong ones would be caught that way)."
    point.V3 ->
      "Sampling, plus a 10-minute hold: everything that proceeds alone can still be withdrawn by finance before release."
    point.V4 ->
      "Sampling, the hold, and two approvals from €500 (left of the dashed line is under €500)."
  }
}

pub fn ladder_label(version: Version) -> String {
  case version {
    point.V1 -> "v1 · Always ask"
    point.V2 -> "v2 · Small and sure"
    point.V3 -> "v3 · Undo window"
    point.V4 -> "v4 · Two for big"
  }
}

// GEOMETRY --------------------------------------------------------------------

/// Horizontal position of an amount on the log scale, €10 to €1,000.
pub fn x(amount: Float) -> Float {
  60.0 +. { log10(amount) -. 1.0 } /. 2.0 *. 660.0
}

/// Vertical position of a confidence, 100% at the top to 50% at the bottom.
pub fn y(confidence: Float) -> Float {
  20.0 +. { 100.0 -. confidence } /. 50.0 *. 260.0
}

// Dots sit at their drawn values, and the policy reads the rounded ones. So
// each policy threshold is drawn where rounding reaches it, and every dot
// sits on the side of a line that its route is on: a €498.21 draw rounds to
// €500, needs two approvals, and sits right of the dashed line.

/// The right edge of the zone that can proceed alone: drawn amounts below
/// €102.50 round to at most €100.
pub fn alone_right() -> Float {
  x(102.5)
}

/// The bottom edge of the zone that can proceed alone: drawn confidences
/// from 89.5% round to at least 90%.
pub fn alone_bottom() -> Float {
  y(89.5)
}

/// The dashed line from which v4 asks two people: drawn amounts from
/// €497.50 round to at least €500.
pub fn two_approvals_x() -> Float {
  x(497.5)
}

const ln_10 = 2.302585092994046

fn log10(x: Float) -> Float {
  case float.logarithm(x) {
    Ok(ln) -> ln /. ln_10
    Error(Nil) -> 0.0
  }
}

/// A number with a fixed count of decimals, as JavaScript's `toFixed` writes
/// it for the values this page shows.
pub fn fixed(x: Float, digits: Int) -> String {
  let scale = list.fold(list.repeat(10, digits), 1, int.multiply)
  let scaled = float.round(float.absolute_value(x) *. int.to_float(scale))
  let sign = case x <. 0.0 && scaled > 0 {
    True -> "-"
    False -> ""
  }
  let whole = int.to_string(scaled / scale)
  case digits <= 0 {
    True -> sign <> whole
    False ->
      sign
      <> whole
      <> "."
      <> string.pad_start(int.to_string(scaled % scale), digits, "0")
  }
}
