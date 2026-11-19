//// Module 3, "Make impossible states impossible": the same order, loose and
//// precise. The course shows the regions between `region:` and `endregion`.

import gleam/option.{type Option}

// region: loose-order
pub type LooseOrder {
  LooseOrder(
    // "pending", "paid", "refunded", or any other text at all
    status: String,
    receipt: Option(String),
    refund: Option(String),
  )
}

// endregion

// region: order
pub type Order {
  Pending
  Paid(receipt: Receipt)
  Refunded(receipt: Receipt, refund: Refund)
  Disputed(receipt: Receipt, case_id: String)
}

// endregion

pub type Receipt {
  Receipt(id: String)
}

pub type Refund {
  Refund(id: String)
}

// region: order-label
pub fn label(order: Order) -> String {
  case order {
    Pending -> "Waiting for payment"
    Paid(receipt:) -> "Paid, receipt " <> receipt.id
    Refunded(refund:, ..) -> "Refunded, refund " <> refund.id
  }
}
// endregion
