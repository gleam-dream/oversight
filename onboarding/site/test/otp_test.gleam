import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import pages/otp
import pages/otp/cart
import pages/otp/libraries
import pages/otp/mailbox.{Call, Send}
import pages/otp/mailbox_widget
import pages/otp/restart_types.{
  Crashes, FinishesNormally, Permanent, Removed, Restarted, Temporary, Transient,
}
import pages/otp/signals.{
  ACrashes, BCrashes, BFinishes, Link, Monitor, TrappedLink,
}
import pages/otp/supervision.{
  DatabasePool, HttpClient, JobRuntime, OneForAll, OneForOne, RestForOne,
  WebServer,
}
import site/booklets
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

pub fn a_caller_waiting_for_a_reply_sends_nothing_else_test() {
  // A's "get total" is a call, so the removal behind it comes from B.
  let assert [_, _, total, removal] = cart.new().mailbox
  assert total == cart.Request(cart.Total, cart.RequestA)
  assert removal == cart.Request(cart.Remove("Book"), cart.RequestB)
  assert list.drop(cart.new().events, 3)
    == [msc.send(1, 2, "remove Book", msc.Ink)]
  // While A's call waits in the mailbox, neither caller may burst.
  assert !cart.can_burst(cart.new())
  assert cart.burst(cart.new()) == cart.new()
  let answered =
    cart.new() |> cart.handle_next |> cart.handle_next |> cart.handle_next
  assert cart.can_burst(answered)
  let burst = cart.burst(answered)
  assert list.length(burst.mailbox) == 3
  // B's call is now queued: a second burst would send from a waiting caller.
  assert !cart.can_burst(burst)
  assert cart.burst(burst) == burst
}

// THE SUPERVISION TREE --------------------------------------------------------

fn statuses(tree: supervision.Tree) -> List(supervision.Status) {
  list.map(tree.children, fn(c) { c.status })
}

/// The restart a crash scheduled.
fn scheduled(
  crashed: #(supervision.Tree, option.Option(supervision.Restart)),
) -> #(supervision.Tree, supervision.Restart) {
  let assert #(tree, Some(restart)) = crashed
  #(tree, restart)
}

pub fn one_for_one_restarts_only_the_crashed_child_test() {
  let #(tree, restart) =
    supervision.crash(supervision.new(0), HttpClient) |> scheduled
  assert supervision.waiting_for(tree, restart) == [HttpClient]
  assert statuses(tree)
    == [
      supervision.Running,
      supervision.Crashed(restart.id),
      supervision.Running,
      supervision.Running,
    ]
  let tree = supervision.restart(tree, restart)
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
  let #(tree, restart) = supervision.crash(tree, JobRuntime) |> scheduled
  assert statuses(tree)
    == [
      supervision.Running,
      supervision.Running,
      supervision.Crashed(restart.id),
      supervision.Restarting(restart.id),
    ]
}

pub fn a_group_stops_in_reverse_start_order_and_starts_in_start_order_test() {
  let tree = supervision.pick(supervision.new(0), RestForOne)
  let #(tree, restart) = supervision.crash(tree, HttpClient) |> scheduled
  assert list.drop(tree.events, 2)
    == [
      msc.send(0, 4, "stop", msc.Amber),
      msc.send(0, 3, "stop", msc.Amber),
    ]
  let before = list.length(tree.events)
  let tree = supervision.restart(tree, restart)
  assert list.drop(tree.events, before)
    == [
      msc.send(0, 2, "start", msc.Green),
      msc.send(0, 3, "start", msc.Green),
      msc.send(0, 4, "start", msc.Green),
    ]
  let tree = supervision.pick(tree, OneForAll)
  let #(tree, _) = supervision.crash(tree, JobRuntime) |> scheduled
  assert list.reverse(tree.events) |> list.take(3)
    == [
      msc.send(0, 1, "stop", msc.Amber),
      msc.send(0, 2, "stop", msc.Amber),
      msc.send(0, 4, "stop", msc.Amber),
    ]
}

pub fn a_later_crash_supersedes_a_pending_restart_test() {
  // HTTP crashes under one-for-one; before its restart, the database pool
  // crashes under one-for-all and takes HTTP into the group restart.
  let #(tree, first) =
    supervision.crash(supervision.new(0), HttpClient) |> scheduled
  let tree = supervision.pick(tree, OneForAll)
  let #(tree, group) = supervision.crash(tree, DatabasePool) |> scheduled
  assert supervision.waiting_for(tree, first) == []
  assert supervision.waiting_for(tree, group)
    == [DatabasePool, HttpClient, JobRuntime, WebServer]
  // The older restart fires first and starts nobody.
  let early = supervision.restart(tree, first)
  assert early == tree
  // The group restart starts each child once, in start order.
  let tree = supervision.restart(early, group)
  assert list.all(statuses(tree), fn(s) { s == supervision.Running })
  assert list.map(tree.children, fn(c) { c.pid }) == [211, 212, 213, 214]
  assert list.map(tree.children, fn(c) { c.restarts }) == [1, 1, 1, 1]
  assert list.reverse(tree.events) |> list.take(4) |> list.reverse
    == [
      msc.send(0, 1, "start", msc.Green),
      msc.send(0, 2, "start", msc.Green),
      msc.send(0, 3, "start", msc.Green),
      msc.send(0, 4, "start", msc.Green),
    ]
  // Firing again changes nothing.
  assert supervision.restart(tree, group) == tree
}

pub fn independent_restarts_each_start_their_own_children_test() {
  let #(tree, http) =
    supervision.crash(supervision.new(0), HttpClient) |> scheduled
  let #(tree, web) = supervision.crash(tree, WebServer) |> scheduled
  let tree = supervision.restart(tree, http)
  assert statuses(tree)
    == [
      supervision.Running,
      supervision.Running,
      supervision.Running,
      supervision.Crashed(web.id),
    ]
  let tree = supervision.restart(tree, web)
  assert list.all(statuses(tree), fn(s) { s == supervision.Running })
}

pub fn a_fourth_crash_in_the_window_escalates_test() {
  let #(tree, pending) =
    list.fold(
      [HttpClient, HttpClient, JobRuntime],
      #(supervision.new(0), None),
      fn(acc, c) { supervision.crash(acc.0, c) },
    )
  assert supervision.shown_window(tree) == 3
  let #(tree, restart) = supervision.crash(tree, DatabasePool)
  assert restart == None
  assert tree.supervisor == supervision.GaveUp
  assert supervision.shown_window(tree) == 3
  assert statuses(tree)
    == [
      supervision.CrashedForGood,
      supervision.Stopped,
      supervision.Stopped,
      supervision.Stopped,
    ]
  // A restart that was still pending changes nothing once the supervisor gave up.
  let assert Some(pending) = pending
  assert supervision.restart(tree, pending) == tree
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
  let #(tree, restart) =
    supervision.crash(supervision.new(0), HttpClient) |> scheduled
  let tree = supervision.reset(tree)
  assert supervision.restart(tree, restart) == tree
  // The first restart of the new epoch has the same number, not the same epoch.
  let #(tree, _) = supervision.crash(tree, WebServer)
  assert supervision.restart(tree, restart) == tree
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

fn steps(sim: mailbox.Sim, n: Int, mode: mailbox.Mode, rate: Int) {
  list.fold(list.repeat(Nil, n), sim, fn(sim, _) {
    mailbox.step(sim, 0.05, mode, rate)
  })
}

pub fn callers_stay_blocked_after_switching_to_send_test() {
  // At 12 calls a second all four callers launch before any reply is back.
  let sim = mailbox.new() |> mailbox.step(0.0, Call, 12) |> steps(6, Call, 12)
  assert sim.sent == 4
  assert mailbox.blocked(sim) == [True, True, True, True]
  // Switching to send launches nothing until a reply frees a caller.
  let sim = steps(sim, 6, Send, 12)
  assert sim.sent == 4
  assert mailbox.blocked(sim) == [True, True, True, True]
  // Once replies are back, sends go out again.
  let sim = steps(sim, 40, Send, 12)
  assert sim.sent > 4
}

pub fn sends_skip_a_caller_waiting_for_its_reply_test() {
  // Caller 0 makes a call, then the reader switches to sends.
  let sim = mailbox.new() |> mailbox.step(0.0, Call, 12) |> steps(10, Send, 12)
  assert sim.sent >= 5
  assert list.first(mailbox.blocked(sim)) == Ok(True)
  assert list.all(sim.tokens, fn(t) { t.kind == Call || t.caller != 0 })
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

// LINKS, MONITORS AND TRAPPED EXITS -------------------------------------------

fn after(bond: signals.Bond, ending: signals.Ending) -> signals.Pair {
  signals.new() |> signals.pick(bond) |> signals.end(ending)
}

pub fn a_link_carries_an_abnormal_exit_both_ways_test() {
  let pair = after(Link, BCrashes)
  assert pair.a == signals.KilledByLink
  assert pair.b == signals.Crashed
  let pair = after(Link, ACrashes)
  assert pair.a == signals.Crashed
  assert pair.b == signals.KilledByLink
}

pub fn a_normal_exit_kills_nobody_test() {
  list.each([Link, Monitor, TrappedLink], fn(bond) {
    let pair = after(bond, BFinishes)
    assert pair.a == signals.Alive
    assert pair.b == signals.Finished
  })
}

pub fn a_monitor_observes_in_one_direction_test() {
  let pair = after(Monitor, BCrashes)
  assert pair.a == signals.Alive
  assert list.contains(
    pair.events,
    msc.Message(1, 0, "ProcessDown(Abnormal)", msc.Blue, msc.Dashed),
  )
  let pair = after(Monitor, ACrashes)
  assert pair.b == signals.Alive
}

pub fn trapping_protects_only_the_trapper_test() {
  let pair = after(TrappedLink, BCrashes)
  assert pair.a == signals.Alive
  assert list.contains(
    pair.events,
    msc.send(1, 0, "ExitMessage(Abnormal)", msc.Amber),
  )
  let pair = after(TrappedLink, ACrashes)
  assert pair.b == signals.KilledByLink
}

pub fn an_ended_pair_waits_for_a_reset_test() {
  let pair = after(Link, BCrashes)
  assert signals.end(pair, ACrashes) == pair
  let pair = signals.reset(pair)
  assert pair.bond == Link
  assert signals.running(pair)
  assert pair.events == []
}

// RESTART TYPES ---------------------------------------------------------------

pub fn restart_types_follow_gleam_otp_test() {
  assert restart_types.fate(Permanent, FinishesNormally) == Restarted
  assert restart_types.fate(Permanent, Crashes) == Restarted
  assert restart_types.fate(Transient, FinishesNormally) == Removed
  assert restart_types.fate(Transient, Crashes) == Restarted
  assert restart_types.fate(Temporary, FinishesNormally) == Removed
  assert restart_types.fate(Temporary, Crashes) == Removed
}

pub fn the_table_fills_in_as_the_reader_tries_test() {
  let table = restart_types.new()
  assert restart_types.remaining(table) == 6
  let table = restart_types.try(table, Crashes)
  assert restart_types.revealed(table, Permanent, Crashes)
  assert !restart_types.revealed(table, Permanent, FinishesNormally)
  // Trying the same combination again reveals nothing new.
  let table = restart_types.try(table, Crashes)
  assert restart_types.remaining(table) == 5
  let table =
    restart_types.pick(table, Temporary)
    |> restart_types.try(FinishesNormally)
  assert restart_types.remaining(table) == 4
  assert table.last == Some(restart_types.Trial(Temporary, FinishesNormally))
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
  let restart = fn(model: otp.Model) {
    let latest = supervision.Restart(model.tree.epoch, model.tree.last_restart)
    run(model, otp.SupervisorRestarted(latest), motion.On)
  }
  let model = restart(model)
  let model = next(model, otp.TreeTour, 1)
  assert model.tree.strategy == RestForOne
  let model = restart(model)
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
  // The call step runs two simulated seconds under call, so replies return.
  let model = still(model, tour.Next)
  assert model.load.mode == Call
  assert model.load.commands.advances == 3
  assert model.load.commands.advance_mode == Call
}

pub fn the_call_step_without_motion_shows_replies_test() {
  // The widget's simulation as the motion-off tour drives it.
  let sim =
    mailbox.new()
    |> mailbox.step(0.0, Send, 3)
    |> mailbox.step(0.0, Send, 8)
    |> mailbox.advance_second(Send, 8)
    |> mailbox.step(0.0, Call, 8)
    |> mailbox.advance_second(Call, 8)
    |> mailbox.advance_second(Call, 8)
  assert list.any(sim.tokens, fn(t) {
    case t.state {
      mailbox.Replying(_) -> True
      _ -> False
    }
  })
  assert mailbox.waiting(sim) == 0
}

pub fn the_restart_window_says_it_runs_on_simulated_time_test() {
  let assert Ok(escalation) =
    otp.script(otp.TreeTour, motion.On).steps |> list.drop(4) |> list.first
  assert string.contains(escalation.text, "simulated time")
  let page =
    otp.view(otp.init(), context.new(motion.On, progress.empty()))
    |> element.to_string
  assert string.contains(
    page,
    "Those 5 seconds are simulated: real time never clears the window",
  )
}

pub fn the_plug_tour_visits_three_libraries_test() {
  let model = next(otp.init(), otp.Plug, 2)
  assert model.library == libraries.Grind
  let model = next(model, otp.Plug, 1)
  assert model.library == libraries.FabricStore
  let model = run(model, otp.Tour(otp.Plug, tour.Back), motion.On)
  assert model.library == libraries.Grind
}

pub fn the_signals_tour_ends_with_the_trapper_alive_and_b_dead_test() {
  let model = next(otp.init(), otp.SignalsTour, 1)
  assert model.pair.a == signals.KilledByLink
  let model = next(model, otp.SignalsTour, 3)
  assert model.pair.bond == TrappedLink
  assert model.pair.a == signals.Alive
  let model = next(model, otp.SignalsTour, 1)
  assert model.pair.b == signals.KilledByLink
  let model = next(model, otp.SignalsTour, 2)
  assert phase(model, otp.SignalsTour) == Free
}

pub fn the_restarts_tour_leaves_two_cells_to_the_reader_test() {
  let model = next(otp.init(), otp.RestartsTour, 5)
  assert restart_types.remaining(model.table) == 2
  assert !restart_types.revealed(model.table, Permanent, Crashes)
  assert !restart_types.revealed(model.table, Temporary, FinishesNormally)
}

pub fn the_tree_states_the_gleam_otp_default_tolerance_test() {
  let page =
    otp.view(otp.init(), context.new(motion.On, progress.empty()))
    |> element.to_string
  assert string.contains(page, "default, changed with restart_tolerance, is 2")
}

pub fn modules_link_the_booklet_beside_the_course_test() {
  assert booklets.pdf(booklets.resilience)
    == "booklets/architecting-resilience.pdf"
  let page =
    otp.view(otp.init(), context.new(motion.On, progress.empty()))
    |> element.to_string
  assert string.contains(page, "booklets/architecting-resilience.pdf")
}

pub fn the_new_tours_have_their_keys_test() {
  assert list.map([otp.SignalsTour, otp.RestartsTour], otp.key)
    == ["signals", "restarts"]
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
