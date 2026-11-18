//// A seeded pseudo-random generator (mulberry32), so illustrative models
//// draw the same picture on every visit. It reproduces the reference's
//// sequence exactly, using unsigned 32-bit arithmetic on plain integers.

import gleam/int
import gleam/list

pub opaque type Rng {
  Rng(state: Int)
}

const two_32 = 4_294_967_296

const two_16 = 65_536

pub fn seed(seed: Int) -> Rng {
  Rng(unsigned(seed))
}

/// The next number in [0, 1), and the generator to draw the one after.
pub fn next(rng: Rng) -> #(Float, Rng) {
  let a = { rng.state + 0x6D2B79F5 } % two_32
  let t = imul(xor(a, a / 32_768), int.bitwise_or(1, a) |> unsigned)
  let t =
    xor(
      { t + imul(xor(t, t / 128), int.bitwise_or(61, t) |> unsigned) } % two_32,
      t,
    )
  let out = xor(t, t / 16_384)
  #(int.to_float(out) /. int.to_float(two_32), Rng(a))
}

/// `count` numbers in [0, 1), in draw order.
pub fn take(rng: Rng, count: Int) -> #(List(Float), Rng) {
  take_loop(rng, count, [])
}

fn take_loop(rng: Rng, count: Int, acc: List(Float)) -> #(List(Float), Rng) {
  case count <= 0 {
    True -> #(list.reverse(acc), rng)
    False -> {
      let #(x, rng) = next(rng)
      take_loop(rng, count - 1, [x, ..acc])
    }
  }
}

fn unsigned(x: Int) -> Int {
  let x = x % two_32
  case x < 0 {
    True -> x + two_32
    False -> x
  }
}

fn xor(a: Int, b: Int) -> Int {
  unsigned(int.bitwise_exclusive_or(a, b))
}

/// Multiply two unsigned 32-bit values modulo 2^32 without losing precision.
fn imul(a: Int, b: Int) -> Int {
  let high = a / two_16
  let low = a % two_16
  { low * b + { high * b % two_16 } * two_16 } % two_32
}
