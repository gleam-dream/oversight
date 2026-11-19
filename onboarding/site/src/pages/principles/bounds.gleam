//// LLM Wire's three default timeouts for a model call, and which one a
//// misbehaving provider trips first.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// How the provider behaves, in seconds: when the first token arrives, how
/// long the stream then goes quiet, and when the call would end. Later chunks
/// arrive steadily. One call holds the first token and the gap after it, so
/// `first_token + first_gap <= whole_call`; the setters below keep it so.
pub type Provider {
  Provider(first_token: Int, first_gap: Int, whole_call: Int)
}

pub const healthy = Provider(first_token: 20, first_gap: 10, whole_call: 120)

/// The whole-call slider moves in steps of this many seconds.
pub const whole_call_step = 10

/// Move the first token, ending the call later if it no longer fits.
pub fn set_first_token(provider: Provider, seconds: Int) -> Provider {
  let first_token = int.max(seconds, 0)
  Provider(
    ..provider,
    first_token:,
    whole_call: fits(provider.whole_call, first_token + provider.first_gap),
  )
}

/// Move the gap after the first token, ending the call later if it no
/// longer fits.
pub fn set_first_gap(provider: Provider, seconds: Int) -> Provider {
  let first_gap = int.max(seconds, 0)
  Provider(
    ..provider,
    first_gap:,
    whole_call: fits(provider.whole_call, provider.first_token + first_gap),
  )
}

/// Move the end of the call, bringing the first token and then the gap after
/// it forward when they no longer fit.
pub fn set_whole_call(provider: Provider, seconds: Int) -> Provider {
  let whole_call = int.max(seconds, whole_call_step)
  let first_token = int.min(provider.first_token, whole_call)
  let first_gap = int.min(provider.first_gap, whole_call - first_token)
  Provider(first_token:, first_gap:, whole_call:)
}

/// The whole call, lengthened to the next slider step when `needed` is more.
fn fits(whole_call: Int, needed: Int) -> Int {
  case needed > whole_call {
    True -> { needed + whole_call_step - 1 } / whole_call_step * whole_call_step
    False -> whole_call
  }
}

pub type Bound {
  FirstProgress
  IdleGap
  WholeCall
}

/// The bound that trips first, if any. When two trip at the same moment, the
/// one listed first wins, as in the reference.
pub fn tripped(provider: Provider) -> Option(Bound) {
  let Provider(first_token:, first_gap:, whole_call:) = provider
  [
    #(first_token > 180, 180, FirstProgress),
    #(first_gap > 60, int.max(first_token, 0) + 60, IdleGap),
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
