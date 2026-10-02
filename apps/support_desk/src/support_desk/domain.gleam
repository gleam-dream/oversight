//// The support desk's business records and their one set of JSON codecs.
////
//// Each codec is declared once here and used for everything: the fabric
//// tool definitions (which derive the schema the model sees), the policy's
//// typed match on a refund, the scripted services' wire bodies, and the
//// typed final `Resolution` parsed out of the agent's answer.

import fabric/tool
import json/blueprint/codec.{type Codec}

pub type OrderQuery {
  OrderQuery(order_id: String)
}

pub type Order {
  Order(order_id: String, customer: String, total_cents: Int, status: String)
}

pub type Eligibility {
  Eligibility(
    order_id: String,
    eligible: Bool,
    refundable_cents: Int,
    note: String,
  )
}

pub type RefundRequest {
  RefundRequest(order_id: String, amount_cents: Int, reason: String)
}

pub type RefundReceipt {
  RefundReceipt(
    refund_id: String,
    order_id: String,
    amount_cents: Int,
    ledger_entry: Int,
  )
}

pub type Outcome {
  Refunded
  Declined
  NotEligible
  RefundFailed
  Unconfirmed
}

/// The agent's typed final answer.
pub type Resolution {
  Resolution(
    order_id: String,
    outcome: Outcome,
    refunded_cents: Int,
    message: String,
  )
}

/// The largest refund the desk ever issues, in cents.
pub const max_refund_cents = 1_000_000

// Codecs ------------------------------------------------------------------

pub fn order_query() -> Codec(OrderQuery) {
  use order_id <- codec.field(
    "order_id",
    codec.string() |> codec.describe("Order id, A-123"),
    fn(query: OrderQuery) { query.order_id },
  )
  codec.success(OrderQuery(order_id:))
}

pub fn order() -> Codec(Order) {
  use order_id <- codec.field("order_id", codec.string(), fn(o: Order) {
    o.order_id
  })
  use customer <- codec.field("customer", codec.string(), fn(o: Order) {
    o.customer
  })
  use total_cents <- codec.field("total_cents", codec.int(), fn(o: Order) {
    o.total_cents
  })
  use status <- codec.field("status", codec.string(), fn(o: Order) { o.status })
  codec.success(Order(order_id:, customer:, total_cents:, status:))
}

pub fn eligibility() -> Codec(Eligibility) {
  use order_id <- codec.field("order_id", codec.string(), fn(e: Eligibility) {
    e.order_id
  })
  use eligible <- codec.field("eligible", codec.bool(), fn(e: Eligibility) {
    e.eligible
  })
  use refundable_cents <- codec.field(
    "refundable_cents",
    codec.int(),
    fn(e: Eligibility) { e.refundable_cents },
  )
  use note <- codec.field("note", codec.string(), fn(e: Eligibility) { e.note })
  codec.success(Eligibility(order_id:, eligible:, refundable_cents:, note:))
}

pub fn refund_request() -> Codec(RefundRequest) {
  use order_id <- codec.field("order_id", codec.string(), fn(r: RefundRequest) {
    r.order_id
  })
  use amount_cents <- codec.field(
    "amount_cents",
    codec.integer_between(1, max_refund_cents)
      |> codec.describe("Refund amount in cents"),
    fn(r: RefundRequest) { r.amount_cents },
  )
  use reason <- codec.field("reason", codec.string(), fn(r: RefundRequest) {
    r.reason
  })
  codec.success(RefundRequest(order_id:, amount_cents:, reason:))
}

pub fn refund_receipt() -> Codec(RefundReceipt) {
  use refund_id <- codec.field(
    "refund_id",
    codec.string(),
    fn(r: RefundReceipt) { r.refund_id },
  )
  use order_id <- codec.field("order_id", codec.string(), fn(r: RefundReceipt) {
    r.order_id
  })
  use amount_cents <- codec.field(
    "amount_cents",
    codec.int(),
    fn(r: RefundReceipt) { r.amount_cents },
  )
  use ledger_entry <- codec.field(
    "ledger_entry",
    codec.int(),
    fn(r: RefundReceipt) { r.ledger_entry },
  )
  codec.success(RefundReceipt(
    refund_id:,
    order_id:,
    amount_cents:,
    ledger_entry:,
  ))
}

pub fn outcome() -> Codec(Outcome) {
  codec.string_enum([
    #("refunded", Refunded),
    #("declined", Declined),
    #("not_eligible", NotEligible),
    #("failed", RefundFailed),
    #("unconfirmed", Unconfirmed),
  ])
}

pub fn resolution() -> Codec(Resolution) {
  use order_id <- codec.field("order_id", codec.string(), fn(r: Resolution) {
    r.order_id
  })
  use outcome <- codec.field("outcome", outcome(), fn(r: Resolution) {
    r.outcome
  })
  use refunded_cents <- codec.field(
    "refunded_cents",
    codec.int(),
    fn(r: Resolution) { r.refunded_cents },
  )
  use message <- codec.field("message", codec.string(), fn(r: Resolution) {
    r.message
  })
  codec.success(Resolution(order_id:, outcome:, refunded_cents:, message:))
}

// Tool definitions --------------------------------------------------------

pub fn lookup_order() -> tool.Definition(OrderQuery, Order) {
  tool.define(
    "lookup_order",
    "Look up an order: customer, total and status.",
    order_query(),
    order(),
  )
}

pub fn check_refund_eligibility() -> tool.Definition(OrderQuery, Eligibility) {
  tool.define(
    "check_refund_eligibility",
    "Say whether an order can be refunded, and for how much.",
    order_query(),
    eligibility(),
  )
}

pub fn issue_refund() -> tool.Definition(RefundRequest, RefundReceipt) {
  tool.define(
    "issue_refund",
    "Refund an order. Needs a human approver above the desk's limit.",
    refund_request(),
    refund_receipt(),
  )
}
