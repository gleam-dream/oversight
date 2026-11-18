import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import pages/principles.{Model}
import pages/principles/bounds.{Provider}
import pages/principles/content
import pages/principles/happen
import pages/principles/herd
import site/context
import site/motion
import site/msc
import site/progress
import site/tour.{Free, Guided, Paused}

// THE THUNDERING HERD ---------------------------------------------------------

fn served(run: herd.Run) -> List(Int) {
  list.map(run.ticks, fn(t) { t.served })
}

fn rejected(run: herd.Run) -> List(Int) {
  list.map(run.ticks, fn(t) { t.rejected })
}

pub fn immediate_retries_swamp_the_service_test() {
  // Counts drawn from the reference's herdSim with the same seed.
  let run = herd.simulate(herd.Immediate)
  assert list.length(run.ticks) == 75
  assert run.attempts == 3631
  assert run.rejected == 3551
  assert run.peak == 80
  assert run.done_tick == Some(66)
  assert run.left == 0
  assert list.take(rejected(run), 4) == [27, 53, 80, 80]
  // Congestion: 80 arrivals leave capacity for one request a tick.
  assert list.take(list.drop(served(run), 10), 3) == [1, 1, 1]
  assert herd.done_label(run) == "6.7 s"
}

pub fn a_fixed_wait_comes_back_in_waves_test() {
  let run = herd.simulate(herd.FixedWait)
  assert run.attempts == 386
  assert run.rejected == 306
  assert run.peak == 27
  assert run.done_tick == Some(62)
  assert list.take(list.drop(served(run), 10), 4) == [3, 3, 3, 0]
}

pub fn exponential_backoff_leaves_clients_waiting_test() {
  let run = herd.simulate(herd.Exponential)
  assert run.attempts == 372
  assert run.rejected == 340
  assert run.peak == 27
  assert run.done_tick == None
  assert run.left == 48
  assert herd.done_label(run) == "not in 7.5 s (48 still waiting)"
}

pub fn jitter_spreads_the_retries_test() {
  let run = herd.simulate(herd.Jittered)
  assert run.attempts == 318
  assert run.rejected == 238
  assert run.peak == 32
  assert run.done_tick == Some(42)
  assert list.take(list.drop(served(run), 10), 8) == [6, 6, 6, 4, 6, 6, 6, 4]
  assert herd.done_label(run) == "4.3 s"
}

// DID IT HAPPEN? --------------------------------------------------------------

fn kinds(events: List(msc.Event)) -> List(String) {
  list.map(events, fn(e) {
    case e {
      msc.Message(..) -> "message"
      msc.Lost(..) -> "lost"
      msc.Note(label:, ..) -> label
      msc.Crash(..) -> "crash"
    }
  })
}

pub fn a_keyless_retry_after_a_charge_charges_twice_test() {
  let state =
    happen.initial()
    |> happen.break_at(happen.WhileProviderWorks)
    |> happen.retry
  assert state.note == happen.Retry(happen.ChargedTwice)
  let picture = happen.picture(state)
  assert picture.charges == 2
  assert list.map(picture.ledger, fn(r) { r.tone })
    == [happen.Charged, happen.Double]
  assert kinds(picture.events)
    == [
      "message", "charges the card", "lost", "MaybeSent", "message",
      "charges AGAIN", "message",
    ]
}

pub fn the_same_key_replays_the_stored_result_test() {
  let state =
    happen.initial()
    |> happen.break_at(happen.WhileProviderWorks)
    |> happen.toggle_key
    |> happen.retry
    |> happen.retry
  assert state.note == happen.Retry(happen.KeyReplayedOriginal)
  let picture = happen.picture(state)
  assert picture.charges == 1
  assert list.length(picture.ledger) == 3
  assert list.all(picture.ledger, fn(r) { r.key == "order-o1" })
}

pub fn retries_belong_to_their_break_and_key_test() {
  let state =
    happen.initial()
    |> happen.break_at(happen.WhileProviderWorks)
    |> happen.retry
    |> happen.retry
  assert happen.retries_shown(state) == 2
  // Turning the key on hides the keyless retries; turning it off again
  // shows them, as in the reference.
  let keyed = happen.toggle_key(state)
  assert happen.retries_shown(keyed) == 0
  assert happen.retries_shown(happen.toggle_key(keyed)) == 2
  // Picking the same moment again keeps them; another moment hides them.
  assert happen.retries_shown(happen.break_at(state, happen.WhileProviderWorks))
    == 2
  assert happen.retries_shown(happen.break_at(state, happen.WhileSending)) == 0
}

pub fn not_sent_makes_a_retry_safe_test() {
  let state =
    happen.initial()
    |> happen.break_at(happen.WhileConnecting)
    |> happen.retry
  assert happen.evidence(state.at) == happen.NotSent
  assert state.note == happen.Retry(happen.SafeBecauseNotSent)
  assert happen.picture(state).charges == 1
}

pub fn an_answered_call_with_a_key_stays_charged_once_test() {
  let state =
    happen.initial()
    |> happen.break_at(happen.Never)
    |> happen.toggle_key
    |> happen.retry
  assert state.note == happen.Retry(happen.SameKeyReplaysAnswer)
  assert happen.picture(state).charges == 1
}

pub fn the_journey_marks_the_break_test() {
  assert list.map(happen.journey(happen.WhileSending), fn(s) { s.mark })
    == [
      happen.Done, happen.Done, happen.ConnectionLost, happen.NotReached,
      happen.NotReached, happen.NotReached,
    ]
  assert list.all(happen.journey(happen.Never), fn(s) { s.mark == happen.Done })
}

// BOUNDS ----------------------------------------------------------------------

pub fn the_first_bound_to_trip_wins_test() {
  assert bounds.tripped(bounds.healthy) == None
  assert bounds.tripped(Provider(250, 10, 300)) == Some(bounds.FirstProgress)
  assert bounds.tripped(Provider(20, 90, 300)) == Some(bounds.IdleGap)
  assert bounds.tripped(Provider(20, 10, 720)) == Some(bounds.WholeCall)
  // The idle gap trips at first token + 60 s, after the whole-call limit here.
  assert bounds.tripped(Provider(560, 90, 900)) == Some(bounds.FirstProgress)
  assert bounds.tripped(Provider(100, 90, 700)) == Some(bounds.IdleGap)
}

// TOURS -----------------------------------------------------------------------

fn context() {
  context.new(motion.On, progress.empty())
}

fn send(model: principles.Model, id: principles.TourId, command: tour.Command) {
  principles.update(model, principles.Tour(id, command), context()).0
}

fn walk(model: principles.Model, id: principles.TourId, steps: Int) {
  list.fold(list.repeat(Nil, steps), model, fn(m, _) { send(m, id, tour.Next) })
}

fn phase(model: principles.Model, id: principles.TourId) {
  tour.phase(tour.get(model.tours, id))
}

pub fn the_sorter_tour_sorts_three_jobs_then_resets_test() {
  let model = walk(principles.init(), principles.Sorter, 3)
  assert dict.to_list(model.sorted)
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    == [#(0, content.Library), #(1, content.YourApp), #(2, content.Library)]
  let model = walk(model, principles.Sorter, 1)
  assert dict.size(model.sorted) == 0
  assert phase(model, principles.Sorter) == Guided(4, Paused)
  assert phase(walk(model, principles.Sorter, 1), principles.Sorter) == Free
}

pub fn the_happen_tour_charges_twice_then_replays_with_the_key_test() {
  let model = walk(principles.init(), principles.DidItHappen, 2)
  assert model.happen.at == happen.WhileProviderWorks
  assert model.happen.curtain == happen.Revealed
  let model = walk(model, principles.DidItHappen, 1)
  assert happen.picture(model.happen).charges == 2
  let model = walk(model, principles.DidItHappen, 1)
  assert model.happen.key == happen.WithKey
  assert model.happen.note == happen.Retry(happen.KeyReplayedOriginal)
  assert happen.picture(model.happen).charges == 1
  let model = walk(model, principles.DidItHappen, 1)
  assert model.happen.at == happen.WhileReplyTravels
  // Back resets and replays: the key is on again after one retry.
  let back = send(model, principles.DidItHappen, tour.Back)
  assert back.happen.at == happen.WhileProviderWorks
  assert back.happen.key == happen.WithKey
  assert happen.retries_shown(back.happen) == 1
}

pub fn the_herd_tour_picks_schedules_and_regrows_the_chart_test() {
  let model = walk(principles.init(), principles.Herd, 1)
  assert model.schedule == herd.Immediate
  assert model.drawing == principles.Growing(run: 1, upto: 0)
  let model = walk(model, principles.Herd, 2)
  assert model.schedule == herd.Jittered
  assert model.drawing == principles.Growing(run: 3, upto: 0)
  // A tick from an earlier run is ignored; the current run grows.
  let stale = principles.update(model, principles.HerdTicked(2), context()).0
  assert stale.drawing == model.drawing
  let grown = principles.update(model, principles.HerdTicked(3), context()).0
  assert grown.drawing == principles.Growing(run: 3, upto: 1)
  // Leaving the page draws the chart whole.
  assert principles.leave(grown).drawing == principles.Drawn
}

pub fn without_motion_the_herd_chart_is_drawn_at_once_test() {
  let still = context.new(motion.Off, progress.empty())
  let #(model, _) =
    principles.update(
      principles.init(),
      principles.ReaderPickedSchedule(herd.Exponential),
      still,
    )
  assert model.drawing == principles.Drawn
  assert model.schedule == herd.Exponential
}

pub fn the_herd_chart_stops_after_the_last_bar_test() {
  let model =
    Model(
      ..principles.init(),
      drawing: principles.Growing(run: 4, upto: 74),
      runs: 4,
    )
  let #(model, _) =
    principles.update(model, principles.HerdTicked(4), context())
  assert model.drawing == principles.Drawn
}

pub fn the_defs_tour_visits_four_definitions_test() {
  let model = walk(principles.init(), principles.DefineOnce, 4)
  assert model.definition == content.DecisionPoint
  let back = send(model, principles.DefineOnce, tour.Back)
  assert back.definition == content.McpTool
  assert list.length(principles.script(principles.DefineOnce).steps) == 6
}

pub fn the_bounds_tour_trips_each_bound_in_turn_test() {
  let model = walk(principles.init(), principles.Bounds, 1)
  assert bounds.tripped(model.provider) == Some(bounds.FirstProgress)
  let model = walk(model, principles.Bounds, 1)
  assert bounds.tripped(model.provider) == Some(bounds.IdleGap)
  let model = walk(model, principles.Bounds, 1)
  assert bounds.tripped(model.provider) == Some(bounds.WholeCall)
  let model = send(model, principles.Bounds, tour.Replay)
  assert model.provider == bounds.healthy
}

pub fn the_tours_have_the_reference_lengths_test() {
  assert list.map(
      [
        principles.Sorter,
        principles.DidItHappen,
        principles.Herd,
        principles.DefineOnce,
        principles.Bounds,
      ],
      fn(id) { list.length(principles.script(id).steps) },
    )
    == [5, 6, 5, 6, 5]
  assert list.map(principles.script(principles.Herd).steps, fn(s) { s.ms })
    == [3600, 5200, 5200, 5200, 3600]
}
