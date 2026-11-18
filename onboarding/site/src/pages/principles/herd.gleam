//// The thundering-herd model: 80 clients hit a service that is down for the
//// first second, then serves at most 6 requests per 100 ms tick, and fewer
//// when swamped (capacity drops when arrivals exceed twice capacity).
//// Turned-away clients retry on the reader's schedule.
////
//// An illustrative model with seeded randomness: it draws the reference's
//// picture exactly, using the same seed and the same order of draws.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import site/rng.{type Rng}

pub type Schedule {
  Immediate
  FixedWait
  Exponential
  Jittered
}

pub const schedules = [Immediate, FixedWait, Exponential, Jittered]

pub fn label(schedule: Schedule) -> String {
  case schedule {
    Immediate -> "Retry immediately"
    FixedWait -> "Wait 1 s"
    Exponential -> "Exponential backoff"
    Jittered -> "Backoff + jitter"
  }
}

/// The reference's short name for a schedule, used in the chart's label.
pub fn key(schedule: Schedule) -> String {
  case schedule {
    Immediate -> "imm"
    FixedWait -> "fixed"
    Exponential -> "expo"
    Jittered -> "jitter"
  }
}

pub const clients = 80

pub const capacity = 6

/// Ticks of 100 ms while the service is down.
pub const outage = 10

/// Ticks simulated: 7.5 seconds.
pub const ticks = 75

/// One 100 ms bar: requests served and requests turned away.
pub type Tick {
  Tick(served: Int, rejected: Int)
}

pub type Run {
  Run(
    ticks: List(Tick),
    attempts: Int,
    rejected: Int,
    /// The most arrivals in one tick.
    peak: Int,
    /// The tick by whose end every client was served, if any.
    done_tick: Option(Int),
    /// Clients still waiting after the last tick.
    left: Int,
  )
}

type Client {
  Waiting(next: Int, failures: Int)
  Served
}

type State {
  State(
    clients: Dict(Int, Client),
    rng: Rng,
    ticks: List(Tick),
    attempts: Int,
    rejected: Int,
    peak: Int,
    done_tick: Option(Int),
  )
}

pub fn simulate(schedule: Schedule) -> Run {
  let #(first, rng) = rng.take(rng.seed(7), clients)
  let clients =
    list.index_map(first, fn(x, i) {
      #(i, Waiting(next: floor(x *. 3.0), failures: 0))
    })
    |> dict.from_list
  let start =
    State(
      clients:,
      rng:,
      ticks: [],
      attempts: 0,
      rejected: 0,
      peak: 0,
      done_tick: None,
    )
  let end =
    list.fold(range(0, ticks - 1), start, fn(state, t) {
      step(state, t, schedule)
    })
  Run(
    ticks: list.reverse(end.ticks),
    attempts: end.attempts,
    rejected: end.rejected,
    peak: end.peak,
    done_tick: end.done_tick,
    left: dict.size(dict.filter(end.clients, fn(_, c) { c != Served })),
  )
}

fn step(state: State, t: Int, schedule: Schedule) -> State {
  let arriving =
    range(0, clients - 1)
    |> list.filter(fn(id) {
      case dict.get(state.clients, id) {
        Ok(Waiting(next:, ..)) -> next == t
        _ -> False
      }
    })
  let #(arriving, rng) = shuffle(arriving, state.rng)
  let n = list.length(arriving)
  let cap = case n > 2 * capacity {
    True -> int.max(1, capacity - { n - 2 * capacity } / 4)
    False -> capacity
  }
  let served = case t < outage {
    True -> 0
    False -> int.min(cap, n)
  }
  let #(clients, rng) =
    list.index_fold(arriving, #(state.clients, rng), fn(acc, id, i) {
      let #(clients, rng) = acc
      case i < served, dict.get(clients, id) {
        True, _ -> #(dict.insert(clients, id, Served), rng)
        False, Ok(Waiting(failures:, ..)) -> {
          let failures = failures + 1
          let #(delay, rng) = delay(schedule, failures, rng)
          #(dict.insert(clients, id, Waiting(next: t + delay, failures:)), rng)
        }
        False, _ -> #(clients, rng)
      }
    })
  let all_served = list.all(dict.values(clients), fn(c) { c == Served })
  State(
    clients:,
    rng:,
    ticks: [Tick(served:, rejected: n - served), ..state.ticks],
    attempts: state.attempts + n,
    rejected: state.rejected + n - served,
    peak: int.max(state.peak, n),
    done_tick: case state.done_tick, all_served {
      None, True -> Some(t)
      done, _ -> done
    },
  )
}

/// Ticks until the next attempt after `failures` failed attempts.
fn delay(schedule: Schedule, failures: Int, rng: Rng) -> #(Int, Rng) {
  case schedule {
    Immediate -> #(1, rng)
    FixedWait -> #(10, rng)
    Exponential -> #(backoff(failures), rng)
    Jittered -> {
      let #(x, rng) = rng.next(rng)
      #(1 + floor(x *. int.to_float(backoff(failures))), rng)
    }
  }
}

/// 4, 8, 16, then 32 ticks at most.
fn backoff(failures: Int) -> Int {
  case failures {
    1 -> 4
    2 -> 8
    3 -> 16
    _ -> 32
  }
}

/// Fisher-Yates from the end, drawing as the reference does.
fn shuffle(items: List(Int), rng: Rng) -> #(List(Int), Rng) {
  let n = list.length(items)
  let slots =
    list.index_map(items, fn(item, i) { #(i, item) }) |> dict.from_list
  let #(slots, rng) =
    list.fold(list.reverse(range(1, n - 1)), #(slots, rng), fn(acc, i) {
      let #(slots, rng) = acc
      let #(x, rng) = rng.next(rng)
      let j = floor(x *. int.to_float(i + 1))
      let assert Ok(a) = dict.get(slots, i)
      let assert Ok(b) = dict.get(slots, j)
      #(slots |> dict.insert(i, b) |> dict.insert(j, a), rng)
    })
  #(
    list.map(range(0, n - 1), fn(i) {
      let assert Ok(item) = dict.get(slots, i)
      item
    }),
    rng,
  )
}

/// The integers from `low` to `high` inclusive; empty when `high < low`.
fn range(low: Int, high: Int) -> List(Int) {
  case low > high {
    True -> []
    False -> [low, ..range(low + 1, high)]
  }
}

fn floor(x: Float) -> Int {
  float.truncate(float.floor(x))
}

/// When everyone was served, as the reference prints it.
pub fn done_label(run: Run) -> String {
  case run.done_tick {
    Some(t) -> {
      let tenths = t + 1
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> " s"
    }
    None -> "not in 7.5 s (" <> int.to_string(run.left) <> " still waiting)"
  }
}

pub fn note(schedule: Schedule) -> String {
  case schedule {
    Immediate ->
      "Immediate retries: the whole crowd hits the service every 100 ms. Overloaded, it serves even fewer than usual, so thousands of attempts are wasted and recovery drags on."
    FixedWait ->
      "A fixed one-second wait just moves the crowd: everyone comes back at the same moment, in waves."
    Exponential ->
      "Exponential backoff spaces the waves out, but clients that failed together stay in lockstep: still waves, now further apart."
    Jittered ->
      "Backoff plus random jitter breaks the lockstep. Retries spread out under the capacity line and far fewer are turned away."
  }
}
