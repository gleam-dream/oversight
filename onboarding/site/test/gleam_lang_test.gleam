import gleam/list
import pages/gleam_lang
import pages/gleam_lang/cart
import pages/gleam_lang/order.{
  BugWaiting, DisputedAdded, Empty, LooseOrder, Paid, Pending, Refunded, Set,
  ThreeStates, ValidByLuck,
}
import pages/gleam_lang/railway.{
  AllOk, ChargeCard, Failed, FailedAt, ParseRequest, RanOk, ReserveStock,
  SendReceipt, Skipped,
}
import site/context
import site/motion
import site/progress
import site/tour.{Free, Guided, Paused}

// IMPOSSIBLE STATES -----------------------------------------------------------

pub fn only_three_loose_combinations_make_sense_test() {
  let fields = [Empty, Set]
  let valid =
    list.flat_map(order.statuses, fn(status) {
      list.flat_map(fields, fn(receipt) {
        list.map(fields, fn(refund) { LooseOrder(status:, receipt:, refund:) })
      })
    })
    |> list.filter(fn(o) { order.judge(o) == ValidByLuck })
  assert valid
    == [
      LooseOrder(Pending, Empty, Empty),
      LooseOrder(Paid, Set, Empty),
      LooseOrder(Refunded, Set, Set),
    ]
}

pub fn refunded_but_never_paid_is_a_bug_waiting_test() {
  let assert BugWaiting(why) = order.judge(LooseOrder(Refunded, Empty, Set))
  assert why
    == "Refunded, but never paid? The program accepts it happily. Somewhere later, code that expects a receipt will crash or do something strange."
  let assert BugWaiting(why) = order.judge(LooseOrder(Paid, Empty, Empty))
  assert why
    == "A required piece is missing for this status, and nothing in the program noticed."
}

// RAILWAY ---------------------------------------------------------------------

pub fn every_step_succeeding_reaches_the_end_test() {
  let outcome = railway.outcome(railway.none())
  assert outcome == AllOk
  assert railway.result_label(outcome) == "Ok(receipt)"
  assert railway.ok_percent(outcome) == 100
  assert railway.error_start(outcome) == 100
}

pub fn the_first_failure_skips_the_rest_test() {
  let failures =
    railway.none()
    |> railway.toggle(SendReceipt)
    |> railway.toggle(ReserveStock)
  let outcome = railway.outcome(failures)
  assert outcome == FailedAt(2, ReserveStock)
  assert railway.result_label(outcome) == "Error(OutOfStock)"
  assert list.map(railway.tracks(failures), fn(entry) { entry.1 })
    == [RanOk, RanOk, Failed, Skipped, Skipped]
  assert railway.ok_percent(outcome) == 40
  assert railway.error_start(outcome) == 50
}

pub fn a_failed_charge_points_at_saga_test() {
  let outcome = railway.outcome(railway.toggle(railway.none(), ChargeCard))
  assert railway.note(outcome)
    == "Step 4 failed, so steps after it never ran. The caller receives Error(Declined) as a value and must decide what to do. Notice the stock is already reserved: undoing earlier steps is a job for Saga, in module 8."
  let first = railway.outcome(railway.toggle(railway.none(), ParseRequest))
  assert railway.ok_percent(first) == 0
  assert railway.error_start(first) == 10
}

// TYPED MESSAGES --------------------------------------------------------------

pub fn wrong_messages_fail_at_runtime_or_at_compile_time_test() {
  assert cart.gleam(cart.ChargeCard).0
    == "compile error: expected CartMessage, got PaymentMessage"
  assert cart.gleam(cart.Hello).0
    == "compile error: expected CartMessage, got String"
  assert cart.erlang(cart.AddItem).0 == "handled"
  assert cart.gleam(cart.GetTotal).0 == "compiles and is handled"
}

pub fn the_mailboxes_keep_the_latest_five_sends_test() {
  let sent =
    list.fold(cart.candidates, [], cart.send)
    |> list.fold(cart.candidates, _, cart.send)
  assert sent
    == [cart.Hello, cart.AddItem, cart.GetTotal, cart.ChargeCard, cart.Hello]
}

// TOURS -----------------------------------------------------------------------

fn send(
  model: gleam_lang.Model,
  id: gleam_lang.TourId,
  command: tour.Command,
) -> gleam_lang.Model {
  let context = context.new(motion.On, progress.empty())
  gleam_lang.update(model, gleam_lang.Tour(id, command), context).0
}

fn steps(
  model: gleam_lang.Model,
  id: gleam_lang.TourId,
  count: Int,
) -> gleam_lang.Model {
  list.fold(list.repeat(Nil, count), model, fn(m, _) { send(m, id, tour.Next) })
}

pub fn the_types_tour_builds_nonsense_then_adds_disputed_test() {
  let model = steps(gleam_lang.init(), gleam_lang.TypesTour, 1)
  assert model.loose == LooseOrder(Paid, Set, Empty)
  assert order.judge(model.loose) == ValidByLuck
  let model = steps(model, gleam_lang.TypesTour, 1)
  assert model.loose == LooseOrder(Refunded, Empty, Set)
  let model = steps(model, gleam_lang.TypesTour, 1)
  assert model.variant == Refunded
  let model = steps(model, gleam_lang.TypesTour, 1)
  assert model.business == DisputedAdded
  let model = send(model, gleam_lang.TypesTour, tour.Back)
  assert model.business == ThreeStates
  assert model.variant == Refunded
  let model = steps(model, gleam_lang.TypesTour, 3)
  assert tour.phase(tour.get(model.tours, gleam_lang.TypesTour)) == Free
}

pub fn the_rail_tour_moves_the_failure_to_the_charge_test() {
  let model = steps(gleam_lang.init(), gleam_lang.RailTour, 2)
  assert railway.outcome(model.failures) == FailedAt(2, ReserveStock)
  let model = steps(model, gleam_lang.RailTour, 1)
  assert railway.outcome(model.failures) == FailedAt(3, ChargeCard)
  assert tour.phase(tour.get(model.tours, gleam_lang.RailTour))
    == Guided(3, Paused)
}

pub fn the_messages_tour_sends_three_messages_test() {
  let model = steps(gleam_lang.init(), gleam_lang.MessagesTour, 3)
  assert model.sent == [cart.AddItem, cart.ChargeCard, cart.Hello]
  let model = send(model, gleam_lang.MessagesTour, tour.Replay)
  assert model.sent == []
  assert tour.phase(tour.get(model.tours, gleam_lang.MessagesTour))
    == Guided(0, Paused)
}
