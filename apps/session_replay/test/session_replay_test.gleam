import gleeunit
import retrace
import session_replay as app

pub fn main() {
  gleeunit.main()
}

pub fn accepted_messages_reconstruct_native_cart_test() {
  let #(initial, entries, final) = app.recording()
  assert app.restore(initial, entries) == Ok(final.model)
  assert final.model == app.Cart(2)
}

pub fn checkpoint_continues_recording_and_replay_test() {
  let #(_, _, checkpoint) = app.recording()
  let assert Ok(recorder) = retrace.resume(checkpoint)
  let message = app.Add(2)
  let assert Ok(next) = app.reduce(checkpoint.model, message)
  let assert Ok(#(recorder, entry)) =
    retrace.record(recorder, message, elapsed_ms: 900)
  let assert Ok(player) = retrace.replay(checkpoint, app.contract, app.reduce)
  let assert Ok(player) = retrace.step(player, entry)
  assert retrace.model(player) == app.Cart(4)
  assert retrace.verify(player, retrace.checkpoint(recorder, next), fn(a, b) {
      a == b
    })
    == Ok(Nil)
}

pub fn gap_refusal_keeps_player_usable_test() {
  let #(initial, entries, final) = app.recording()
  let assert [first, second] = entries
  let assert Ok(player) = retrace.replay(initial, app.contract, app.reduce)
  assert retrace.step(player, second) == Error(retrace.OutOfOrder(1, 2))
  assert retrace.position(player) == 0
  let assert Ok(player) = retrace.step(player, first)
  let assert Ok(player) = retrace.step(player, second)
  assert retrace.model(player) == final.model
}

pub fn incompatible_contract_is_refused_test() {
  let #(initial, _, _) = app.recording()
  assert retrace.replay(initial, "cart-v2", app.reduce)
    == Error(retrace.DifferentContract("cart-v2", app.contract))
}

pub fn reducer_refusal_preserves_native_error_and_cursor_test() {
  let #(initial, entries, _) = app.recording()
  let assert [first, ..] = entries
  let assert Ok(player) = retrace.replay(initial, app.contract, app.reduce)
  let invalid = retrace.Entry(..first, event: app.Remove(1))
  assert retrace.step(player, invalid)
    == Error(retrace.ReductionFailed(1, app.NotEnoughItems(0, 1)))
  assert retrace.model(player) == app.Cart(0)
  assert retrace.position(player) == 0
  let assert Ok(player) = retrace.step(player, first)
  assert retrace.model(player) == app.Cart(3)
  assert app.reduce(app.Cart(2), app.Add(0)) == Error(app.InvalidQuantity)
  assert app.reduce(app.Cart(2), app.Remove(-1)) == Error(app.InvalidQuantity)
}
