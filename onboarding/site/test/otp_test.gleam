import gleam/list
import gleam/option.{None, Some}
import pages/otp
import pages/otp/cart
import pages/otp/libraries
import pages/otp/mailbox.{Call, Send}
import pages/otp/mailbox_widget
import pages/otp/supervision.{
  DatabasePool, HttpClient, JobRuntime, OneForAll, OneForOne, RestForOne,
  WebServer,
}
import site/context
import site/motion
import site/msc
import site/progress
import site/tour.{Free, Guided, Paused}

// THE CART ACTOR --------------------------------------------------------------

pub fn the_cart_handles_one_message_at_a_time_test() {
  let shop = cart.new() |> cart.handle_next
  assert shop.items == [cart.Item("Book", 12)]
  assert shop.version == 1
  assert list.length(shop.mailbox) == 3
  let shop = shop |> cart.handle_next |> cart.handle_next
  // "get total" is a call: it replies and leaves the state alone.
  assert shop.version == 2
  assert shop.last
    == cart.Handled(cart.Request(cart.Total, cart.RequestA), cart.Replied(20))
  assert list.last(shop.events)
    == Ok(msc.Message(2, 0, "reply €20", msc.Green, msc.Dashed))
  let shop = cart.handle_next(shop)
  assert shop.items == [cart.Item("Mug", 8)]
  assert shop.mailbox == []
  // An empty mailbox leaves the actor asleep.
  assert cart.handle_next(shop) == shop
}

pub fn removing_what_is_not_there_changes_nothing_test() {
  let shop =
    cart.Cart(..cart.new(), mailbox: [
      cart.Request(cart.Remove("Book"), cart.RequestA),
    ])
    |> cart.handle_next
  assert shop.version == 0
  assert cart.last_step(shop.last)
    == "\"remove Book\" → No Book in the cart, so nothing changed."
}

pub fn the_actor_chart_keeps_its_latest_nine_events_test() {
  let shop =
    list.fold(list.repeat(Nil, 6), cart.new(), fn(shop, _) {
      cart.handle_next(shop)
    })
  assert list.length(shop.events) == 9
}

// THE SUPERVISION TREE --------------------------------------------------------

fn statuses(tree: supervision.Tree) -> List(supervision.Status) {
  list.map(tree.children, fn(c) { c.status })
}

pub fn one_for_one_restarts_only_the_crashed_child_test() {
  let #(tree, restarting) = supervision.crash(supervision.new(0), HttpClient)
  assert restarting == [HttpClient]
  assert statuses(tree)
    == [
      supervision.Running,
      supervision.Crashed,
      supervision.Running,
      supervision.Running,
    ]
  let tree = supervision.restart(tree, tree.epoch, restarting)
  assert list.all(statuses(tree), fn(s) { s == supervision.Running })
  assert list.map(tree.children, fn(c) { c.pid }) == [201, 211, 203, 204]
  assert supervision.news_text(tree.news)
    == "Restarted HTTP client from a clean state. Its neighbours never noticed."
}

pub fn strategies_pick_who_restarts_test() {
  assert supervision.affected(RestForOne, HttpClient)
    == [HttpClient, JobRuntime, WebServer]
  assert supervision.affected(OneForAll, WebServer)
    == [DatabasePool, HttpClient, JobRuntime, WebServer]
  let tree = supervision.pick(supervision.new(0), RestForOne)
  let #(tree, _) = supervision.crash(tree, JobRuntime)
  assert statuses(tree)
    == [
      supervision.Running,
      supervision.Running,
      supervision.Crashed,
      supervision.Restarting,
    ]
}

pub fn a_fourth_crash_in_the_window_escalates_test() {
  let tree =
    list.fold(
      [HttpClient, HttpClient, JobRuntime],
      supervision.new(0),
      fn(t, c) { supervision.crash(t, c).0 },
    )
  assert supervision.shown_window(tree) == 3
  let #(tree, restarting) = supervision.crash(tree, DatabasePool)
  assert restarting == []
  assert tree.supervisor == supervision.GaveUp
  assert supervision.shown_window(tree) == 3
  assert statuses(tree)
    == [
      supervision.Crashed,
      supervision.Stopped,
      supervision.Stopped,
      supervision.Stopped,
    ]
  // A restart that was still pending changes nothing once the supervisor gave up.
  assert supervision.restart(tree, tree.epoch, [HttpClient]) == tree
  // Further crashes are ignored and waiting does not revive it.
  assert supervision.crash(tree, WebServer).0 == tree
  let waited = supervision.wait(tree)
  assert waited.window == 0
  assert waited.news == supervision.WaitedAfterGivingUp
}

pub fn waiting_clears_the_restart_window_test() {
  let #(tree, _) = supervision.crash(supervision.new(0), WebServer)
  let tree = supervision.wait(tree)
  assert tree.window == 0
  assert tree.news == supervision.WindowCleared
}

pub fn a_restart_scheduled_before_a_reset_is_ignored_test() {
  let #(tree, restarting) = supervision.crash(supervision.new(0), HttpClient)
  let stale = tree.epoch
  let tree = supervision.reset(tree)
  assert supervision.restart(tree, stale, restarting) == tree
}

// THE MAILBOX SIMULATION ------------------------------------------------------

fn seconds(sim: mailbox.Sim, n: Int, mode: mailbox.Mode, rate: Int) {
  list.fold(list.repeat(Nil, n), sim, fn(sim, _) {
    mailbox.advance_second(sim, mode, rate)
  })
}

pub fn a_slow_rate_of_sends_keeps_the_mailbox_short_test() {
  let sim = seconds(mailbox.new(), 10, Send, 3)
  // Sends land on 0.05 s steps, so a third of a second becomes 0.35 s.
  assert sim.sent == 29
  assert mailbox.waiting(sim) <= 1
  assert list.all(mailbox.blocked(sim), fn(b) { !b })
}

pub fn sends_faster_than_the_actor_grow_the_mailbox_without_limit_test() {
  let sim = seconds(mailbox.new(), 10, Send, 8)
  // An eighth of a second becomes 0.15 s on 0.05 s steps.
  assert sim.sent == 67
  // The actor handles about four a second; the rest pile up.
  assert sim.handled >= 33 && sim.handled <= 40
  assert mailbox.waiting(sim) >= 25
  let later = seconds(sim, 10, Send, 8)
  assert mailbox.waiting(later) > mailbox.waiting(sim) + 20
  assert mailbox.oldest_wait(later) >. mailbox.oldest_wait(sim)
}

pub fn calls_self_limit_to_the_actor_pace_test() {
  let sim = seconds(mailbox.new(), 20, Call, 12)
  // Each caller waits for its reply, so the mailbox never outgrows them.
  assert mailbox.waiting(sim) <= 4
  assert sim.sent - sim.handled <= 4
  assert sim.handled >= 60
}

pub fn switching_to_call_drains_the_backlog_test() {
  let backlog = seconds(mailbox.new(), 10, Send, 8)
  let drained = seconds(backlog, 20, Call, 8)
  assert mailbox.waiting(drained) <= 4
}

pub fn the_actor_works_one_message_at_a_time_test() {
  let sim = seconds(mailbox.new(), 5, Send, 12)
  let working =
    list.filter(sim.tokens, fn(t) {
      case t.state {
        mailbox.Working(_) -> True
        _ -> False
      }
    })
  assert list.length(working) <= 1
  assert mailbox.busy(sim) != None
}

pub fn queued_messages_settle_into_their_slots_test() {
  let sim = seconds(mailbox.new(), 4, Send, 8)
  let shown =
    list.filter_map(mailbox.queue(sim), fn(t) {
      case t.state {
        mailbox.Queued(shown_x: Some(x), ..) -> Ok(x)
        _ -> Error(Nil)
      }
    })
  assert shown != []
  assert list.length(shown) <= mailbox.visible_slots + 1
}

// THE WIDGET'S ATTRIBUTES -----------------------------------------------------

pub fn commands_survive_their_attribute_test() {
  let commands = mailbox_widget.Commands(3, 7, Call, 11)
  assert mailbox_widget.decode_commands(mailbox_widget.encode_commands(commands))
    == Some(commands)
  assert mailbox_widget.decode_commands("1 2 shout 3") == None
}

pub fn numbers_print_like_to_fixed_test() {
  assert mailbox_widget.fixed(0.0, 1) == "0.0"
  assert mailbox_widget.fixed(12.25, 1) == "12.3"
  assert mailbox_widget.fixed(0.5, 2) == "0.50"
  assert mailbox_widget.fixed(622.0, 1) == "622.0"
}

// TOURS -----------------------------------------------------------------------

fn run(model: otp.Model, msg: otp.Msg, motion: motion.Motion) -> otp.Model {
  otp.update(model, msg, context.new(motion, progress.empty())).0
}

fn next(model: otp.Model, id: otp.TourId, times: Int) -> otp.Model {
  list.fold(list.repeat(Nil, times), model, fn(m, _) {
    run(m, otp.Tour(id, tour.Next), motion.On)
  })
}

fn phase(model: otp.Model, id: otp.TourId) -> tour.Phase {
  tour.phase(tour.get(model.tours, id))
}

pub fn the_actor_tour_handles_the_burst_in_order_test() {
  let model = next(otp.init(), otp.Actor, 3)
  assert model.cart.version == 2
  assert cart.total(model.cart) == 20
  let model = next(model, otp.Actor, 1)
  assert list.length(model.cart.mailbox) == 3
  let model = next(model, otp.Actor, 1)
  // remove Book, add Pen, then B's call answered with €11.
  assert model.cart.mailbox == []
  assert model.cart.items == [cart.Item("Mug", 8), cart.Item("Pen", 3)]
  assert list.last(model.cart.events)
    == Ok(msc.Message(2, 1, "reply €11", msc.Green, msc.Dashed))
  let model = next(model, otp.Actor, 2)
  assert phase(model, otp.Actor) == Free
}

pub fn going_back_in_the_actor_tour_replays_from_a_fresh_cart_test() {
  let model = next(otp.init(), otp.Actor, 4)
  let model = run(model, otp.Tour(otp.Actor, tour.Back), motion.On)
  assert phase(model, otp.Actor) == Guided(3, Paused)
  assert model.cart.version == 2
  assert list.length(model.cart.mailbox) == 1
}

pub fn the_tree_tour_ends_in_escalation_test() {
  let model = next(otp.init(), otp.TreeTour, 1)
  assert model.tree.strategy == OneForOne
  // Let the supervisor restart in between, as a playing tour would.
  let restart = fn(model: otp.Model, children) {
    run(model, otp.SupervisorRestarted(model.tree.epoch, children), motion.On)
  }
  let model = restart(model, [HttpClient])
  let model = next(model, otp.TreeTour, 1)
  assert model.tree.strategy == RestForOne
  let model = restart(model, [HttpClient, JobRuntime, WebServer])
  let model = next(model, otp.TreeTour, 1)
  assert model.tree.strategy == OneForAll
  assert model.tree.window == 3
  let model = next(model, otp.TreeTour, 1)
  assert model.tree.supervisor == supervision.GaveUp
  let model = next(model, otp.TreeTour, 2)
  assert phase(model, otp.TreeTour) == Free
}

pub fn the_load_tour_raises_the_rate_then_calls_test() {
  let model = next(otp.init(), otp.LoadTour, 1)
  assert model.load.rate == 8
  assert model.load.mode == Send
  let model = next(model, otp.LoadTour, 2)
  assert model.load.mode == Call
  // With motion on, the widget runs in real time: no advance commands.
  assert model.load.commands.advances == 0
  let model = run(model, otp.Tour(otp.LoadTour, tour.Replay), motion.On)
  assert model.load.rate == 3
  assert model.load.mode == Send
  assert model.load.commands.resets == 2
}

pub fn without_motion_the_load_tour_advances_the_widget_test() {
  let still = fn(model, command) {
    run(model, otp.Tour(otp.LoadTour, command), motion.Off)
  }
  let model = otp.init() |> still(tour.Next) |> still(tour.Next)
  assert model.load.commands.advances == 1
  assert model.load.commands.advance_mode == Send
  assert model.load.commands.advance_rate == 8
}

pub fn the_plug_tour_visits_three_libraries_test() {
  let model = next(otp.init(), otp.Plug, 2)
  assert model.library == libraries.Grind
  let model = next(model, otp.Plug, 1)
  assert model.library == libraries.FabricStore
  let model = run(model, otp.Tour(otp.Plug, tour.Back), motion.On)
  assert model.library == libraries.Grind
}

pub fn tour_scripts_keep_the_reference_lengths_test() {
  let lengths =
    list.map([otp.Actor, otp.LoadTour, otp.TreeTour, otp.Plug], fn(id) {
      list.length(otp.script(id, motion.On).steps)
    })
  assert lengths == [7, 5, 6, 5]
  assert list.map([otp.Actor, otp.LoadTour, otp.TreeTour, otp.Plug], otp.key)
    == ["actor", "load", "tree", "plug"]
}
