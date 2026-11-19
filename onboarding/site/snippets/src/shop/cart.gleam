//// Module 3, "Mailboxes with a type": a cart's messages as a custom type, so
//// a Subject only accepts what the cart understands.

import gleam/erlang/process.{type Subject}

// region: cart-message
pub type CartMessage {
  AddItem(name: String, cents: Int)
  RemoveItem(name: String)
  GetTotal(reply_to: Subject(Int))
}

// endregion

// region: cart-send
pub fn fill(cart: Subject(CartMessage)) -> Int {
  process.send(cart, AddItem("Pen", 250))
  process.call(cart, 1000, GetTotal)
}
// endregion
