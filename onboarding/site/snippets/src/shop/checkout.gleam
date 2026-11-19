//// Module 3, "The Result railway": every step returns a Result, and `use`
//// stops at the first Error.

import gleam/result

// region: checkout-error
pub type CheckoutError {
  BadRequest
  InvalidAmount
  OutOfStock
  Declined
  MailNotSent
}

// endregion

// region: checkout
pub fn checkout(request: Request) -> Result(Receipt, CheckoutError) {
  use order <- result.try(parse_request(request))
  use amount <- result.try(validate_amount(order))
  use hold <- result.try(reserve_stock(order))
  use charge <- result.try(charge_card(amount))
  send_receipt(order, hold, charge)
}

// endregion

pub type Request {
  Request(body: String)
}

pub type Order {
  Order(item: String, cents: Int)
}

pub type Hold {
  Hold(item: String)
}

pub type Charge {
  Charge(id: String)
}

pub type Receipt {
  Receipt(order: Order, charge: Charge)
}

fn parse_request(request: Request) -> Result(Order, CheckoutError) {
  case request.body {
    "" -> Error(BadRequest)
    item -> Ok(Order(item:, cents: 2000))
  }
}

fn validate_amount(order: Order) -> Result(Int, CheckoutError) {
  case order.cents > 0 {
    True -> Ok(order.cents)
    False -> Error(InvalidAmount)
  }
}

fn reserve_stock(order: Order) -> Result(Hold, CheckoutError) {
  Ok(Hold(item: order.item))
}

fn charge_card(cents: Int) -> Result(Charge, CheckoutError) {
  case cents < 100_000 {
    True -> Ok(Charge(id: "ch_1"))
    False -> Error(Declined)
  }
}

fn send_receipt(
  order: Order,
  _hold: Hold,
  charge: Charge,
) -> Result(Receipt, CheckoutError) {
  Ok(Receipt(order:, charge:))
}
