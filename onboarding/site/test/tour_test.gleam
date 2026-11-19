import gleam/list
import gleam/option.{None, Some}
import pages/start
import site/context
import site/motion
import site/progress
import site/tour.{Free, Guided, Paused, Playing}

/// A four-step script whose first step only narrates.
const shape = [#(False, 3600), #(True, 3600), #(True, 4200), #(True, 3600)]

fn at(step: Int, playback: tour.Playback) -> tour.Tour {
  // Walk a fresh tour to the wanted state through public commands.
  let tour = tour.get(tour.new(), Nil)
  let tour = case step {
    0 -> tour
    _ ->
      list.fold(list.repeat(Nil, step), tour, fn(t, _) {
        tour.plan(t, tour.Next, shape, motion.On).tour
      })
  }
  case playback {
    Paused -> tour
    Playing -> tour.plan(tour, tour.Play, shape, motion.On).tour
  }
}

pub fn a_tour_starts_guided_at_the_first_step_test() {
  assert tour.phase(tour.get(tour.new(), Nil)) == Guided(0, Paused)
}

pub fn next_runs_the_next_step_and_finishing_unlocks_test() {
  let plan = tour.plan(at(1, Paused), tour.Next, shape, motion.On)
  assert tour.phase(plan.tour) == Guided(2, Paused)
  assert plan.run == tour.RunStep(2)
  assert plan.bring_into_view
  let last = tour.plan(at(3, Paused), tour.Next, shape, motion.On)
  assert tour.phase(last.tour) == Free
  assert last.run == tour.RunNothing
}

pub fn back_resets_and_replays_up_to_the_previous_step_test() {
  let plan = tour.plan(at(3, Paused), tour.Back, shape, motion.On)
  assert tour.phase(plan.tour) == Guided(2, Paused)
  assert plan.run == tour.ResetThen([1, 2])
  let to_first = tour.plan(at(1, Paused), tour.Back, shape, motion.On)
  assert to_first.run == tour.ResetThen([])
  let at_start = tour.plan(at(0, Paused), tour.Back, shape, motion.On)
  assert at_start.tour == at(0, Paused)
}

pub fn play_from_a_narrated_start_jumps_to_the_first_action_test() {
  let plan = tour.plan(at(0, Paused), tour.Play, shape, motion.On)
  assert tour.phase(plan.tour) == Guided(1, Playing)
  assert plan.run == tour.RunStep(1)
  assert plan.schedule == Some(3600)
}

pub fn play_needs_motion_test() {
  let plan = tour.plan(at(1, Paused), tour.Play, shape, motion.Off)
  assert plan.tour == at(1, Paused)
  assert plan.schedule == None
}

pub fn an_advance_moves_on_and_schedules_the_next_step_test() {
  let playing = at(1, Playing)
  let plan =
    tour.plan(playing, tour.Advance(tour.epoch(playing)), shape, motion.On)
  assert tour.phase(plan.tour) == Guided(2, Playing)
  assert plan.run == tour.RunStep(2)
  // Step 2 lasts longer.
  assert plan.schedule == Some(4200)
  assert !plan.bring_into_view
}

pub fn a_stale_advance_is_ignored_test() {
  let playing = at(1, Playing)
  let stale = tour.epoch(playing)
  let paused = tour.plan(playing, tour.Pause, shape, motion.On).tour
  let resumed = tour.plan(paused, tour.Play, shape, motion.On).tour
  // The advance scheduled before the pause must not double-step the tour.
  let plan = tour.plan(resumed, tour.Advance(stale), shape, motion.On)
  assert plan.tour == resumed
  assert plan.run == tour.RunNothing
}

pub fn playing_stops_at_the_last_step_without_unlocking_test() {
  let last = at(3, Playing)
  let plan = tour.plan(last, tour.Advance(tour.epoch(last)), shape, motion.On)
  assert tour.phase(plan.tour) == Guided(3, Paused)
}

pub fn skip_unlocks_and_replay_restarts_test() {
  let free = tour.plan(at(2, Playing), tour.Skip, shape, motion.On).tour
  assert tour.phase(free) == Free
  let replay = tour.plan(free, tour.Replay, shape, motion.On)
  assert tour.phase(replay.tour) == Guided(0, Paused)
  assert replay.run == tour.ResetThen([0])
}

pub fn a_free_playground_ignores_tour_controls_test() {
  let free = tour.plan(at(2, Paused), tour.Skip, shape, motion.On).tour
  list.each([tour.Next, tour.Back, tour.Play, tour.Pause], fn(command) {
    assert tour.plan(free, command, shape, motion.On).tour == free
  })
}

pub fn pausing_all_tours_cancels_their_advances_test() {
  let tours = tour.new()
  let context = context.new(motion.On, progress.empty())
  let model = start.Model(..start.init(), tours:)
  let #(model, _) =
    start.update(model, start.Tour(start.Stack, tour.Play), context)
  let playing = tour.get(model.tours, start.Stack)
  assert tour.phase(playing) == Guided(1, Playing)
  let left = start.leave(model)
  assert tour.phase(tour.get(left.tours, start.Stack)) == Guided(1, Paused)
  let #(after, _) =
    start.update(
      left,
      start.Tour(start.Stack, tour.Advance(tour.epoch(playing))),
      context,
    )
  assert tour.phase(tour.get(after.tours, start.Stack)) == Guided(1, Paused)
}

// THE COURSE MAP TOUR ---------------------------------------------------------

fn send(model: start.Model, command: tour.Command) -> start.Model {
  let context = context.new(motion.On, progress.empty())
  start.update(model, start.Tour(start.Stack, command), context).0
}

pub fn the_stack_tour_climbs_from_the_bottom_test() {
  let model = send(start.init(), tour.Next)
  assert model.selected == start.BeamLayer
  let model = send(model, tour.Next)
  assert model.selected == start.OtpLayer
  let model = list.fold([1, 2, 3, 4], model, fn(m, _) { send(m, tour.Next) })
  assert model.selected == start.YourSystems
  assert tour.phase(tour.get(model.tours, start.Stack)) == Guided(6, Paused)
  let model = send(model, tour.Next)
  assert tour.phase(tour.get(model.tours, start.Stack)) == Free
}

pub fn going_back_replays_the_stack_tour_test() {
  let model =
    start.init()
    |> send(tour.Next)
    |> send(tour.Next)
    |> send(tour.Next)
  assert model.selected == start.GleamLayer
  let model = send(model, tour.Back)
  assert model.selected == start.OtpLayer
  let model = send(model, tour.Back) |> send(tour.Back)
  assert model.selected == start.YourSystems
}

pub fn the_stack_tour_has_seven_steps_test() {
  assert list.length(start.script(start.Stack).steps) == 7
}
