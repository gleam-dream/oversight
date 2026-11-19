//// The Retrace playground: a recorded cart session rebuilt from typed
//// events, frame by frame, under a replay strategy and a privacy choice the
//// app made at capture.

import gleam/int
import gleam/list
import gleam/string

pub type Strategy {
  Deterministic
  ProtectedObservations
}

pub const strategies = [Deterministic, ProtectedObservations]

pub fn strategy_label(strategy: Strategy) -> String {
  case strategy {
    Deterministic -> "Deterministic"
    ProtectedObservations -> "Protected observations"
  }
}

/// How the app classified the email field before anything was stored.
pub type Classification {
  Private
  Safe
}

pub type Origin {
  /// A message from the app itself.
  AppMessage
  /// The answer of an outside service, recorded as an external result.
  ExternalResult
}

/// The six recorded events, in order.
pub const recording = [
  #("open cart", AppMessage),
  #("add Book", AppMessage),
  #("add Mug", AppMessage),
  #("coupon SAVE10", ExternalResult),
  #("type email", AppMessage),
  #("checkout", AppMessage),
]

pub const length = 6

pub type Line {
  Line(name: String, price: String)
}

/// The cart as the replay frame shows it after `position` events.
pub type Frame {
  Frame(
    lines: List(Line),
    discount_label: String,
    discount: String,
    total: String,
    email: String,
    status: String,
  )
}

pub fn frame(position: Int, email: Classification) -> Frame {
  let items =
    [#(2, "Book", 1200), #(3, "Mug", 800)]
    |> list.filter(fn(item) { position >= item.0 })
  let subtotal = int.sum(list.map(items, fn(item) { item.2 }))
  let coupon = position >= 4
  let discount = case coupon {
    True -> { subtotal + 5 } / 10
    False -> 0
  }
  Frame(
    lines: case items {
      [] -> [Line(name: "empty", price: "")]
      _ ->
        list.map(items, fn(item) { Line(name: item.1, price: euros(item.2)) })
    },
    discount_label: case coupon {
      True -> "Coupon SAVE10"
      False -> "No coupon"
    },
    discount: case coupon {
      True -> "−" <> euros(discount)
      False -> ""
    },
    total: euros(subtotal - discount),
    email: case position >= 5, email {
      False, _ -> "(empty)"
      True, Private -> "•••• (excluded at capture)"
      True, Safe -> "ada@example.com"
    },
    status: case position {
      0 -> "nothing recorded yet"
      p if p >= 6 -> "checked out"
      _ -> "shopping"
    },
  )
}

/// An amount in cents as the reference prints it: no trailing zeros.
pub fn euros(cents: Int) -> String {
  let whole = int.to_string(cents / 100)
  case cents % 100 {
    0 -> "€" <> whole
    fraction -> {
      let cents = string.pad_start(int.to_string(fraction), 2, "0")
      "€" <> whole <> "." <> trim_zero(cents)
    }
  }
}

fn trim_zero(text: String) -> String {
  case string.ends_with(text, "0") {
    True -> string.drop_end(text, 1)
    False -> text
  }
}

/// How the frame was rebuilt, for the strategy and the privacy choice.
pub fn how(strategy: Strategy, email: Classification) -> String {
  let rebuilt = case strategy {
    Deterministic ->
      "Deterministic replay: the recorded safe messages, including the coupon service’s answer (an external result), were fed through the same pure update function, and the view rendered from the result. It needs the exact build that recorded it."
    ProtectedObservations ->
      "Protected-observation replay: after each transition the app recorded validated observations, the presence of values and the decisions it accepted, and the replay adopts them instead of re-running logic. It also needs the exact build."
  }
  rebuilt
  <> case email {
    Private ->
      " The email was classified private and excluded at capture, so no viewer setting can bring it back. Privacy is decided by your app before anything is stored."
    Safe ->
      " The email was recorded because your app classified it as safe. Viewer redaction alone can never make a recording private."
  }
}
