//// LLM Wire's three default timeouts for a model call, and which one a
//// misbehaving provider trips first.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// How the provider behaves, in seconds.
pub type Provider {
  Provider(first_token: Int, longest_gap: Int, whole_call: Int)
}

pub const healthy = Provider(first_token: 20, longest_gap: 10, whole_call: 120)

pub type Bound {
  FirstProgress
  IdleGap
  WholeCall
}

/// The bound that trips first, if any. When two trip at the same moment, the
/// one listed first wins, as in the reference.
pub fn tripped(provider: Provider) -> Option(Bound) {
  let Provider(first_token:, longest_gap:, whole_call:) = provider
  [
    #(first_token > 180, 180, FirstProgress),
    #(longest_gap > 60, int.max(first_token, 0) + 60, IdleGap),
    #(whole_call > 600, 600, WholeCall),
  ]
  |> list.filter(fn(trip) { trip.0 })
  |> list.sort(fn(a, b) { int.compare(a.1, b.1) })
  |> list.first
  |> option.from_result
  |> option.map(fn(trip) { trip.2 })
}

pub fn title(bound: Option(Bound)) -> String {
  case bound {
    Some(FirstProgress) -> "Stopped: First-progress timeout (180 s)"
    Some(IdleGap) -> "Stopped: Idle-gap timeout (60 s)"
    Some(WholeCall) -> "Stopped: Whole-call timeout (600 s)"
    None -> "Completed within every bound"
  }
}

pub fn why(bound: Option(Bound)) -> String {
  let typed =
    " You get a typed failure naming the bound, plus advice on whether another attempt might help."
  case bound {
    Some(FirstProgress) ->
      "Nothing useful arrived within 180 seconds, so the call ended early instead of waiting the full 600."
      <> typed
    Some(IdleGap) ->
      "The stream went quiet for over a minute mid-answer. A stalled stream is treated as a failure, not waited on forever."
      <> typed
    Some(WholeCall) ->
      "Each chunk came in time, but the call as a whole ran past ten minutes."
      <> typed
    None ->
      "First progress, every gap and the total all stayed inside the defaults. Each one is configurable per call."
  }
}
