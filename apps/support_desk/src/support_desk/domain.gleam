//// The support desk's business records and their one set of JSON codecs.
////
//// Each codec is declared once here and used for everything: the fabric
//// tool definitions (which derive the schema the model sees), the policy's
//// typed match on a refund, the scripted services' wire bodies, and the
//// typed final `Resolution` parsed out of the agent's answer.

import fabric/tool
import json/blueprint/codec.{type Codec, type Properties}

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
  codec.field("order_id", codec.string() |> codec.describe("Order id, A-123"))
  |> codec.imap(OrderQuery, fn(query) { query.order_id })
}

pub fn order() -> Codec(Order) {
  record4(
    codec.required("order_id", codec.string()),
    codec.required("customer", codec.string()),
    codec.required("total_cents", codec.int()),
    codec.required("status", codec.string()),
    Order,
    fn(o) { o.order_id },
    fn(o) { o.customer },
    fn(o) { o.total_cents },
    fn(o) { o.status },
  )
}

pub fn eligibility() -> Codec(Eligibility) {
  record4(
    codec.required("order_id", codec.string()),
    codec.required("eligible", codec.bool()),
    codec.required("refundable_cents", codec.int()),
    codec.required("note", codec.string()),
    Eligibility,
    fn(e) { e.order_id },
    fn(e) { e.eligible },
    fn(e) { e.refundable_cents },
    fn(e) { e.note },
  )
}

pub fn refund_request() -> Codec(RefundRequest) {
  let assert Ok(amount) = codec.integer_between(1, max_refund_cents)
  let assert Ok(request) =
    codec.record3(
      codec.required("order_id", codec.string()),
      codec.required(
        "amount_cents",
        amount |> codec.describe("Refund amount in cents"),
      ),
      codec.required("reason", codec.string()),
      RefundRequest,
      fn(r) { r.order_id },
      fn(r) { r.amount_cents },
      fn(r) { r.reason },
    )
  request
}

pub fn refund_receipt() -> Codec(RefundReceipt) {
  record4(
    codec.required("refund_id", codec.string()),
    codec.required("order_id", codec.string()),
    codec.required("amount_cents", codec.int()),
    codec.required("ledger_entry", codec.int()),
    RefundReceipt,
    fn(r) { r.refund_id },
    fn(r) { r.order_id },
    fn(r) { r.amount_cents },
    fn(r) { r.ledger_entry },
  )
}

pub fn outcome() -> Codec(Outcome) {
  let assert Ok(outcome) =
    codec.string_enum([
      #("refunded", Refunded),
      #("declined", Declined),
      #("not_eligible", NotEligible),
      #("failed", RefundFailed),
      #("unconfirmed", Unconfirmed),
    ])
  outcome
}

pub fn resolution() -> Codec(Resolution) {
  record4(
    codec.required("order_id", codec.string()),
    codec.required("outcome", outcome()),
    codec.required("refunded_cents", codec.int()),
    codec.required("message", codec.string()),
    Resolution,
    fn(r) { r.order_id },
    fn(r) { r.outcome },
    fn(r) { r.refunded_cents },
    fn(r) { r.message },
  )
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

// Glue: json_blueprint's record helpers stop at three fields. ------------

fn record4(
  a: Properties(a),
  b: Properties(b),
  c: Properties(c),
  d: Properties(d),
  construct: fn(a, b, c, d) -> r,
  get_a: fn(r) -> a,
  get_b: fn(r) -> b,
  get_c: fn(r) -> c,
  get_d: fn(r) -> d,
) -> Codec(r) {
  let assert Ok(ab) = codec.combine(a, b)
  let assert Ok(abc) = codec.combine(ab, c)
  let assert Ok(abcd) = codec.combine(abc, d)
  codec.object(abcd)
  |> codec.imap(
    fn(values) {
      let #(#(#(a, b), c), d) = values
      construct(a, b, c, d)
    },
    fn(r) { #(#(#(get_a(r), get_b(r)), get_c(r)), get_d(r)) },
  )
}
