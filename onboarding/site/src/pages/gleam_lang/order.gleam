//// The same order modelled two ways. The loose record is the anti-pattern
//// on purpose: a status and two optional fields that nothing ties together.
//// The custom type has one variant per state, each with exactly its data.

pub type Status {
  Pending
  Paid
  Refunded
}

pub const statuses = [Pending, Paid, Refunded]

pub type Field {
  Empty
  Set
}

pub type LooseOrder {
  LooseOrder(status: Status, receipt: Field, refund: Field)
}

/// Whether the business has added the Disputed state yet.
pub type Business {
  ThreeStates
  DisputedAdded
}

pub fn toggle(field: Field) -> Field {
  case field {
    Empty -> Set
    Set -> Empty
  }
}

pub fn status_label(status: Status) -> String {
  case status {
    Pending -> "pending"
    Paid -> "paid"
    Refunded -> "refunded"
  }
}

pub fn field_label(field: Field) -> String {
  case field {
    Empty -> "empty"
    Set -> "set"
  }
}

/// What the loose record says about itself: the program accepts every
/// combination; only some of them happen to make sense.
pub type Verdict {
  ValidByLuck
  BugWaiting(why: String)
}

pub fn judge(order: LooseOrder) -> Verdict {
  case order {
    LooseOrder(Pending, Empty, Empty)
    | LooseOrder(Paid, Set, Empty)
    | LooseOrder(Refunded, Set, Set) -> ValidByLuck
    LooseOrder(Refunded, Empty, _) ->
      BugWaiting(
        "Refunded, but never paid? The program accepts it happily. Somewhere later, code that expects a receipt will crash or do something strange.",
      )
    LooseOrder(Pending, _, _) ->
      BugWaiting(
        "Pending, yet it already has a receipt or refund. Which field is the truth? Every reader has to guess.",
      )
    LooseOrder(Paid, _, Set) ->
      BugWaiting(
        "Paid and refunded at once? The data contradicts itself, and every function reading it needs a defensive check.",
      )
    LooseOrder(_, _, _) ->
      BugWaiting(
        "A required piece is missing for this status, and nothing in the program noticed.",
      )
  }
}

/// The custom-type variant as the playground names it.
pub fn variant_name(status: Status) -> String {
  case status {
    Pending -> "Pending"
    Paid -> "Paid(receipt)"
    Refunded -> "Refunded(receipt, refund)"
  }
}

pub fn variant_fields(status: Status) -> String {
  case status {
    Pending -> "no extra data"
    Paid -> "must carry a receipt"
    Refunded -> "must carry both"
  }
}

pub fn variant_why(status: Status) -> String {
  case status {
    Pending ->
      "Pending carries nothing, so a pending order can’t accidentally hold a receipt."
    Paid ->
      "You cannot build a Paid order without giving it a receipt. The compiler refuses."
    Refunded ->
      "A refund always comes with the receipt it reverses. \"Refunded but never paid\" is not expressible."
  }
}
