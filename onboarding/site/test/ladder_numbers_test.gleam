//// The scatter's numbers are written in pure Gleam; JavaScript's own
//// `Math.log10` and `toFixed` are the oracle, so every dot sits where the
//// reference drew it.

import gleam/float
import gleam/int
import gleam/list
import pages/agents/ladder

@external(javascript, "./ladder_numbers.ffi.mjs", "to_fixed")
fn js_fixed(x: Float, digits: Int) -> String

@external(javascript, "./ladder_numbers.ffi.mjs", "log10")
fn js_log10(x: Float) -> Float

fn js_x(amount: Float) -> Float {
  60.0 +. { js_log10(amount) -. 1.0 } /. 2.0 *. 660.0
}

pub fn every_dot_sits_where_the_reference_drew_it_test() {
  list.each(ladder.cases(), fn(c) {
    assert ladder.fixed(ladder.x(c.drawn_amount), 1)
      == js_fixed(js_x(c.drawn_amount), 1)
    // The reference's vertical scale: 100% at the top (20), 50% at 280.
    let expected_y = 20.0 +. { 100.0 -. c.drawn_confidence } /. 50.0 *. 260.0
    assert ladder.fixed(ladder.y(c.drawn_confidence), 1)
      == js_fixed(expected_y, 1)
  })
}

fn sweep(i: Int) -> Nil {
  case i > 20_000 {
    True -> Nil
    False -> {
      let x = int.to_float(i) /. 97.0
      assert ladder.fixed(x, 1) == js_fixed(x, 1)
      assert ladder.fixed(x /. 3.0, 2) == js_fixed(x /. 3.0, 2)
      sweep(i + 1)
    }
  }
}

pub fn fixed_matches_to_fixed_across_a_sweep_test() {
  sweep(0)
  assert ladder.fixed(0.0, 1) == "0.0"
  assert ladder.fixed(float.negate(2.25), 1) == js_fixed(-2.25, 1)
}
