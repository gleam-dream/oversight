//// Sending to the cart through an untyped mailbox and through a typed
//// Subject(CartMessage). Both sides see the same sends; only the verdicts
//// differ.

import gleam/list

/// What the reader can try to send to the cart.
pub type Candidate {
  AddItem
  GetTotal
  ChargeCard
  Hello
}

pub const candidates = [AddItem, GetTotal, ChargeCard, Hello]

/// How a send fares in each world.
pub type Fate {
  /// A CartMessage: handled in Erlang, compiles and is handled in Gleam.
  Understood
  /// Not a CartMessage: accepted then lost or fatal in Erlang, a compile
  /// error in Gleam. Carries the type it actually has.
  WrongType(actual: String)
}

pub fn fate(candidate: Candidate) -> Fate {
  case candidate {
    AddItem | GetTotal -> Understood
    ChargeCard -> WrongType("PaymentMessage")
    Hello -> WrongType("String")
  }
}

pub fn label(candidate: Candidate) -> String {
  case candidate {
    AddItem -> "AddItem(Pen)"
    GetTotal -> "GetTotal(reply_to)"
    ChargeCard -> "ChargeCard(€20)"
    Hello -> "\"hello\""
  }
}

/// The latest sends, oldest first, at most five.
pub type Sent =
  List(Candidate)

const shown = 5

pub fn send(sent: Sent, candidate: Candidate) -> Sent {
  let sent = list.append(sent, [candidate])
  list.drop(sent, list.length(sent) - shown)
}

/// The untyped mailbox's note and background for one send.
pub fn erlang(candidate: Candidate) -> #(String, String) {
  case fate(candidate) {
    Understood -> #("handled", "#F1EEE8")
    WrongType(_) -> #(
      "accepted into the mailbox… then ignored forever or crashes the cart at runtime",
      "#FDECEA",
    )
  }
}

/// The typed Subject's note and background for one send.
pub fn gleam(candidate: Candidate) -> #(String, String) {
  case fate(candidate) {
    Understood -> #("compiles and is handled", "#E2F4E7")
    WrongType(actual) -> #(
      "compile error: expected CartMessage, got " <> actual,
      "#FFF1C2",
    )
  }
}
