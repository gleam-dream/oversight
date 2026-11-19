//// Module 3, "Pattern matching": one case expression that shows the main
//// kinds of pattern. The course's playground walks through it arm by arm.

import gleam/int
import gleam/list

// region: event
pub type Event {
  Pending
  Paid(items: List(String))
  Refunded(cents: Int, reason: String)
  Note(text: String)
}

// endregion

// region: describe
pub fn describe(event: Event) -> String {
  case event {
    Refunded(cents:, ..) if cents > 10_000 -> "Ask finance"
    Refunded(cents:, reason:) -> reason <> ", " <> int.to_string(cents)
    Paid(items: [only]) -> "One item: " <> only
    Paid(items: [first, ..rest]) -> first <> " +" <> count(rest)
    Note("order-" <> id) -> "About order " <> id
    Note(_) | Pending -> "Nothing to do"
  }
}

// endregion

fn count(items: List(String)) -> String {
  int.to_string(list.length(items))
}
