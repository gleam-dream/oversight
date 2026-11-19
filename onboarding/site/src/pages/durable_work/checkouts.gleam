//// Two hundred checkouts at once: an illustrative model with seeded
//// randomness. Each run draws five numbers and becomes one of four outcomes;
//// each keeps the plan that reproduces it in the single-checkout playground.

import gleam/int
import gleam/list
import pages/durable_work/checkout.{type Plan, Plan}
import site/rng

/// How often each step misbehaves, in percent.
pub type Rates {
  Rates(out_of_stock: Int, declined: Int, unknown: Int, shipping: Int)
}

pub type Rate {
  OutOfStockRate
  DeclinedRate
  UnknownRate
  ShippingRate
}

pub const defaults = Rates(out_of_stock: 5, declined: 8, unknown: 6, shipping: 4)

pub const all_rates = [OutOfStockRate, DeclinedRate, UnknownRate, ShippingRate]

pub fn rate(rates: Rates, which: Rate) -> Int {
  case which {
    OutOfStockRate -> rates.out_of_stock
    DeclinedRate -> rates.declined
    UnknownRate -> rates.unknown
    ShippingRate -> rates.shipping
  }
}

pub fn set_rate(rates: Rates, which: Rate, value: Int) -> Rates {
  let value = int.clamp(value, 0, 40)
  case which {
    OutOfStockRate -> Rates(..rates, out_of_stock: value)
    DeclinedRate -> Rates(..rates, declined: value)
    UnknownRate -> Rates(..rates, unknown: value)
    ShippingRate -> Rates(..rates, shipping: value)
  }
}

pub fn rate_label(which: Rate) -> String {
  case which {
    OutOfStockRate -> "Out of stock"
    DeclinedRate -> "Card declined"
    UnknownRate -> "Charge result unknown"
    ShippingRate -> "Shipping fails"
  }
}

pub type Kind {
  AllDone
  Compensated
  StoppedEarly
  Held
}

pub const kinds = [AllDone, Compensated, StoppedEarly, Held]

pub type Run {
  Run(kind: Kind, plan: Plan, retried: Bool)
}

pub const count = 200

/// The same two hundred runs for the same rates, on every visit.
pub fn runs(rates: Rates) -> List(Run) {
  let #(_, runs) =
    list.map_fold(list.repeat(Nil, count), rng.seed(11), fn(generator, _) {
      let #(draws, generator) = rng.take(generator, 5)
      #(generator, classify(list.map(draws, fn(d) { d *. 100.0 }), rates))
    })
  runs
}

fn classify(u: List(Float), rates: Rates) -> Run {
  let assert [u0, u1, u2, u3, u4] = u
  let below = fn(draw, percent) { draw <. int.to_float(percent) }
  let base = checkout.happy
  case below(u0, rates.out_of_stock), below(u1, rates.declined) {
    True, _ ->
      Run(StoppedEarly, Plan(..base, stock: checkout.OutOfStock), False)
    False, True ->
      Run(Compensated, Plan(..base, payment: checkout.Declined), False)
    False, False ->
      case below(u2, rates.unknown), u4 <. 60.0 {
        True, False ->
          Run(Held, Plan(..base, payment: checkout.StaysUnknown), True)
        unknown, _ -> {
          let payment = case unknown {
            True -> checkout.UnknownThenPaid
            False -> checkout.Paid
          }
          case below(u3, rates.shipping) {
            True ->
              Run(
                Compensated,
                Plan(..base, payment:, shipping: checkout.CarrierRejects),
                unknown,
              )
            False -> Run(AllDone, Plan(..base, payment:), unknown)
          }
        }
      }
  }
}

pub fn colour(kind: Kind) -> String {
  case kind {
    AllDone -> "#15803D"
    Compensated -> "#B45309"
    StoppedEarly -> "#8A8698"
    Held -> "#E0B000"
  }
}

pub fn label(kind: Kind) -> String {
  case kind {
    AllDone -> "Completed"
    Compensated -> "Compensated"
    StoppedEarly -> "Stopped early"
    Held -> "Held"
  }
}

pub fn what(kind: Kind) -> String {
  case kind {
    AllDone -> "every step succeeded"
    Compensated -> "a later step failed; completed steps undone, newest first"
    StoppedEarly -> "out of stock at the first step: nothing to undo"
    Held -> "the charge stayed unknown: held for your app to reconcile"
  }
}

pub fn tally(runs: List(Run), kind: Kind) -> Int {
  list.count(runs, fn(run) { run.kind == kind })
}

pub fn retried(runs: List(Run)) -> Int {
  list.count(runs, fn(run) { run.retried })
}
