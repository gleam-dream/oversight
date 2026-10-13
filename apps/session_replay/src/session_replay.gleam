//// A small public consumer: the application owns cart rules and accepted events;
//// Retrace owns stream positions, compatibility checks and reconstruction.

import gleam/int
import gleam/io
import gleam/list
import gleam/result
import retrace

pub const contract = "cart-v1"

pub type Cart {
  Cart(quantity: Int)
}

pub type Message {
  Add(quantity: Int)
  Remove(quantity: Int)
}

pub type CartError {
  InvalidQuantity
  NotEnoughItems(available: Int, requested: Int)
}

/// Shared by the live application and replay. No clocks, IO or native calls.
pub fn reduce(cart: Cart, message: Message) -> Result(Cart, CartError) {
  case message {
    Add(quantity) if quantity > 0 -> Ok(Cart(cart.quantity + quantity))
    Remove(quantity) if quantity > 0 ->
      case quantity <= cart.quantity {
        True -> Ok(Cart(cart.quantity - quantity))
        False -> Error(NotEnoughItems(cart.quantity, quantity))
      }
    Add(_) | Remove(_) -> Error(InvalidQuantity)
  }
}

/// Record two known-valid transitions. Production callers handle these Results
/// and supply unique session IDs, safe state and a monotonic elapsed clock.
pub fn recording() -> #(
  retrace.Checkpoint(Cart),
  List(retrace.Entry(Message)),
  retrace.Checkpoint(Cart),
) {
  let initial_cart = Cart(0)
  let assert Ok(#(recorder, initial)) =
    retrace.start(retrace.Origin("cart-demo", contract), initial_cart)

  let assert Ok(cart) = reduce(initial_cart, Add(3))
  let assert Ok(#(recorder, first)) =
    retrace.record(recorder, Add(3), elapsed_ms: 100)

  let assert Ok(cart) = reduce(cart, Remove(1))
  let assert Ok(#(recorder, second)) =
    retrace.record(recorder, Remove(1), elapsed_ms: 650)

  #(initial, [first, second], retrace.checkpoint(recorder, cart))
}

pub fn restore(
  checkpoint: retrace.Checkpoint(Cart),
  entries: List(retrace.Entry(Message)),
) -> Result(Cart, retrace.Error(CartError)) {
  use player <- result.try(retrace.replay(checkpoint, contract, reduce))
  list.try_fold(entries, player, retrace.step) |> result.map(retrace.model)
}

pub fn main() {
  let #(initial, entries, final) = recording()
  let assert Ok(cart) = restore(initial, entries)
  assert cart == final.model
  io.println("Recorded cart: " <> int.to_string(final.model.quantity))
  io.println("Replayed cart: " <> int.to_string(cart.quantity))

  let assert [_, second] = entries
  let assert Error(retrace.OutOfOrder(expected, received)) =
    restore(initial, [second])
  io.println(
    "Gap refused: expected event "
    <> int.to_string(expected)
    <> ", received "
    <> int.to_string(received),
  )
}
