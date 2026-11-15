//// The marketplace the narrated run and the tests start from: Dora sells
//// on it; finance staff hold `finance`; Hana is head of finance; Fiona
//// works in support and in finance, and she is the one who asks.

import gleam/list
import gleam/result
import payout_desk/db
import payout_desk/domain.{Dispute, Order, Request}
import pog

pub const dora = "dora"

/// Who asks for payouts on sellers' behalf.
pub const fiona = "fiona"

pub fn staff() -> List(#(String, List(String))) {
  [
    #(fiona, ["support", domain.finance]),
    #("bia", [domain.finance]),
    #("carl", [domain.finance]),
    #("ana", [domain.finance]),
    #("hana", [domain.head_of_finance]),
    #("sam", ["support"]),
  ]
}

/// Dora, her balance, her history and her staff.
pub fn seed(db: pog.Connection) -> Result(Nil, db.DbError) {
  use Nil <- result.try(db.put_seller(db, dora, 200_000))
  use Nil <- result.try(db.add_paid_out(db, dora, 15_000))
  use Nil <- result.try(db.add_paid_out(db, dora, 9000))
  list.try_each(staff(), fn(person) { db.put_staff(db, person.0, person.1) })
}

/// An order of Dora's whose dispute ended with `status`, owing her
/// `owed_cents`, of which `fee_cents` is the chargeback fee.
pub fn disputed(
  db: pog.Connection,
  order order: String,
  status status: String,
  owed_cents owed_cents: Int,
  fee_cents fee_cents: Int,
) -> Result(Nil, db.DbError) {
  use Nil <- result.try(db.put_order(
    db,
    Order(
      id: order,
      seller: dora,
      total_cents: owed_cents * 2,
      status: "delivered",
    ),
  ))
  db.put_dispute(
    db,
    Dispute(
      order:,
      status:,
      seller_owed_cents: owed_cents,
      fee_cents:,
      note: "the buyer was refunded part of the order; the chargeback fee is in what remains",
    ),
  )
}

/// Dora's request about `order`.
pub fn request(id: String, order: String) -> domain.Request {
  Request(
    id:,
    seller: dora,
    order:,
    text: "My order "
      <> order
      <> " was disputed and I was paid nothing. Please correct my payout.",
  )
}
