import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import pages/compose
import pages/compose/builder
import pages/compose/package
import pages/compose/stepper
import pages/compose/systems
import pages/compose/trace
import site/context
import site/motion
import site/msc
import site/progress
import site/tour.{Free, Guided, Paused}

fn moving() -> context.Context {
  context.new(motion.On, progress.empty())
}

fn still() -> context.Context {
  context.new(motion.Off, progress.empty())
}

fn update(model: compose.Model, msg: compose.Msg) -> compose.Model {
  compose.update(model, msg, moving()).0
}

// STEPPER ---------------------------------------------------------------------

pub fn a_played_walk_ticks_to_its_end_and_stops_test() {
  let walk = stepper.play(stepper.new(3), motion.On)
  assert stepper.at(walk) == 1
  assert stepper.run(walk) == stepper.Playing
  let epoch = stepper.epoch(walk)
  let assert Ok(walk) = stepper.tick(walk, epoch)
  let assert Ok(walk) = stepper.tick(walk, epoch)
  assert stepper.at(walk) == 3
  assert stepper.run(walk) == stepper.Playing
  // The tick at the last step ends the run, as the reference's interval does.
  let assert Ok(walk) = stepper.tick(walk, epoch)
  assert stepper.at(walk) == 3
  assert stepper.run(walk) == stepper.Idle
  assert stepper.tick(walk, epoch) == Error(Nil)
}

pub fn without_motion_play_jumps_to_the_end_test() {
  let walk = stepper.play(stepper.new(7), motion.Off)
  assert stepper.at(walk) == 7
  assert stepper.run(walk) == stepper.Idle
}

pub fn a_tick_from_an_earlier_run_is_ignored_test() {
  let walk = stepper.play(stepper.new(5), motion.On)
  let stale = stepper.epoch(walk)
  let restarted = stepper.restart(walk, 5) |> stepper.play(motion.On)
  assert stepper.tick(restarted, stale) == Error(Nil)
  assert stepper.tick(stepper.stop(walk), stale) == Error(Nil)
}

pub fn stepping_stays_within_the_walk_test() {
  let walk = stepper.new(4)
  assert stepper.at(stepper.back(walk)) == 1
  assert stepper.at_start(walk)
  let walk = walk |> stepper.forward |> stepper.forward |> stepper.forward
  assert stepper.at(stepper.forward(walk)) == 4
  assert stepper.at_end(walk)
  assert stepper.at(stepper.scrub(walk, 99)) == 4
  assert stepper.at(stepper.scrub(walk, 0)) == 1
}

// SYSTEMS ---------------------------------------------------------------------

pub fn ten_systems_with_their_steps_test() {
  assert list.length(systems.all) == 10
  assert list.map(systems.all, systems.step_count)
    == [7, 5, 6, 5, 5, 6, 5, 5, 5, 5]
  assert list.length(systems.patterns) == 6
}

pub fn every_system_uses_the_packages_of_its_steps_test() {
  list.each(systems.all, fn(system) {
    let info = systems.info(system)
    list.each(info.steps, fn(step) {
      case step.0 {
        package.Uses(p) -> {
          assert list.contains(info.packages, p)
        }
        package.YourApp -> Nil
      }
    })
  })
}

// BUILDER ---------------------------------------------------------------------

pub fn durable_undoable_steps_point_to_checkout_test() {
  let design =
    builder.design(
      set.from_list([builder.BackgroundWork, builder.UndoableSteps]),
    )
  assert design.packages == [package.Sinal, package.Grind, package.Saga]
  assert design.patterns
    == ["A job drives a durable saga (checkout, financial recovery)."]
  assert option.map(design.nearest, fn(e) { e.name }) == Some("Checkout")
  assert list.length(design.yours) == 4
}

pub fn typed_answers_in_the_background_point_to_the_extractor_test() {
  let design =
    builder.design(
      set.from_list([builder.TypedModelAnswers, builder.BackgroundWork]),
    )
  assert design.packages
    == [
      package.Sinal,
      package.Blueprint,
      package.HttpGun,
      package.LlmWire,
      package.Grind,
    ]
  assert option.map(design.nearest, fn(e) { e.name })
    == Some("Invoice extractor")
  assert design.patterns
    == [
      "One Grind job per document; LLM Wire’s retry advice becomes a job retry (extractor).",
    ]
}

pub fn an_agent_with_an_approver_hands_over_to_decisions_test() {
  let design =
    builder.design(
      set.from_list([
        builder.TypedModelAnswers,
        builder.BackgroundWork,
        builder.AgentWithTools,
        builder.HumanApproval,
      ]),
    )
  assert design.patterns
    == [
      "Fabric hands risky calls over to a Decisions point (payout desk).",
      "Start agent runs from jobs and keep the Fabric store in PostgreSQL to survive restarts (research agent).",
    ]
  assert option.map(design.nearest, fn(e) { e.name })
    == Some("Clinic registration")
}

pub fn no_needs_no_design_test() {
  let design = builder.design(set.new())
  assert design.packages == []
  assert design.patterns == []
  assert design.nearest == None
  assert design.yours
    == [
      "policy and permissions",
      "resource lifetimes: pools, clients, supervisors",
    ]
}

pub fn sinal_comes_along_only_with_observed_packages_test() {
  let email = builder.design(set.from_list([builder.SendsEmail]))
  assert email.packages == [package.Correio]
  assert option.map(email.nearest, fn(e) { e.name }) == Some("Email portal")
  let durable_email =
    builder.design(set.from_list([builder.SendsEmail, builder.BackgroundWork]))
  assert durable_email.packages
    == [package.Sinal, package.Correio, package.Grind]
}

// TRACE -----------------------------------------------------------------------

pub fn the_trace_has_sixteen_or_eighteen_events_test() {
  assert trace.length(trace.Succeeds) == 16
  assert trace.length(trace.ShippingFails) == 18
}

pub fn the_trace_uses_real_event_names_test() {
  let names =
    trace.events(trace.ShippingFails)
    |> list.map(fn(e) { e.name })
    |> set.from_list
  assert names
    == set.from_list([
      "grind.job.admitted",
      "grind.job.claimed",
      "grind.job.acknowledged",
      "grind.diagnostic.renewal",
      "saga.run.start",
      "saga.run.stop",
      "saga.step.start",
      "saga.step.stop",
      "saga.step.undo.stop",
      "http_gun.lifecycle",
    ])
}

pub fn trace_labels_read_like_the_reference_test() {
  let reserve = trace.event_at(trace.Succeeds, 4)
  assert trace.name_list(reserve)
    == "[\"saga\", \"step\", \"start\"]  reserve_inventory"
  assert trace.short_label(reserve) == "saga.step.start (reserve)"
  let returned = trace.event_at(trace.Succeeds, 8)
  assert trace.short_label(returned) == "lifecycle: gun_call_returned"
  assert returned.fields == Some("milestone: GunCallReturned")
  let claimed = trace.event_at(trace.Succeeds, 2)
  assert trace.short_label(claimed) == "grind.job.claimed"
  assert trace.active_lane(claimed) == trace.GrindLane
  assert trace.name_list(claimed) == "[\"grind\", \"job\", \"claimed\"]"
}

pub fn the_trace_chart_marks_notes_and_the_active_lane_test() {
  let chart = trace.chart(trace.Succeeds, 2)
  assert chart.upto == Some(2)
  assert chart.active == Some(1)
  assert chart.lane_gap == 165
  assert chart.row == 26
  let assert [
    _,
    msc.Note(at: 1, label: "grind.job.claimed", colour: msc.Amber),
    ..
  ] = chart.events
}

// PAGE ------------------------------------------------------------------------

pub fn picking_a_system_restarts_its_walk_and_cancels_play_test() {
  let model = update(compose.init(), compose.ReaderPlayedSystem)
  let stale = stepper.epoch(model.walk)
  let model = update(model, compose.ReaderPickedSystem(systems.PayoutDesk))
  assert stepper.at(model.walk) == 1
  assert stepper.total(model.walk) == 5
  assert stepper.run(model.walk) == stepper.Idle
  let after = update(model, compose.SystemStepDue(stale))
  assert after == model
}

pub fn a_played_walk_advances_on_its_ticks_test() {
  let model = update(compose.init(), compose.ReaderPlayedSystem)
  let epoch = stepper.epoch(model.walk)
  let model =
    list.fold(list.repeat(Nil, 6), model, fn(m, _) {
      update(m, compose.SystemStepDue(epoch))
    })
  assert stepper.at(model.walk) == 7
  let model = update(model, compose.SystemStepDue(epoch))
  assert stepper.run(model.walk) == stepper.Idle
}

pub fn leaving_stops_played_walks_test() {
  let model =
    compose.init()
    |> update(compose.ReaderPlayedSystem)
    |> update(compose.ReaderPlayedTrace)
  let left = compose.leave(model)
  assert stepper.run(left.walk) == stepper.Idle
  assert stepper.run(left.trace) == stepper.Idle
}

pub fn scrubbing_the_trace_stays_within_it_test() {
  let model = update(compose.init(), compose.ReaderScrubbedTrace(40))
  assert stepper.at(model.trace) == 16
  let model = update(model, compose.ReaderPickedOutcome(trace.ShippingFails))
  assert stepper.at(model.trace) == 1
  assert stepper.total(model.trace) == 18
}

// TOURS -----------------------------------------------------------------------

fn send(
  model: compose.Model,
  id: compose.TourId,
  command: tour.Command,
  context: context.Context,
) -> compose.Model {
  compose.update(model, compose.Tour(id, command), context).0
}

fn phase(model: compose.Model, id: compose.TourId) -> tour.Phase {
  tour.phase(tour.get(model.tours, id))
}

pub fn tour_keys_match_the_reference_test() {
  assert compose.key(compose.Systems) == "systems"
  assert compose.key(compose.Builder) == "builder"
  assert compose.key(compose.Trace) == "trace"
}

pub fn the_systems_tour_plays_checkout_then_the_payout_desk_test() {
  let go = fn(m) { send(m, compose.Systems, tour.Next, moving()) }
  let model = go(compose.init())
  assert model.system == systems.Checkout
  assert stepper.run(model.walk) == stepper.Playing
  assert stepper.at(model.walk) == 1
  let model = go(model)
  assert model.system == systems.PayoutDesk
  assert stepper.run(model.walk) == stepper.Playing
  let model = go(model)
  assert phase(model, compose.Systems) == Guided(3, Paused)
  let model = go(model)
  assert phase(model, compose.Systems) == Free
  // Back from the payout desk replays the checkout step.
  let back =
    compose.init()
    |> go
    |> go
    |> send(compose.Systems, tour.Back, moving())
  assert back.system == systems.Checkout
}

pub fn the_systems_tour_without_motion_shows_every_step_test() {
  let model = send(compose.init(), compose.Systems, tour.Next, still())
  assert stepper.at(model.walk) == 7
  assert stepper.run(model.walk) == stepper.Idle
}

pub fn the_builder_tour_changes_the_needs_test() {
  let go = fn(m) { send(m, compose.Builder, tour.Next, moving()) }
  let model = go(compose.init())
  assert model.needs
    == set.from_list([builder.TypedModelAnswers, builder.BackgroundWork])
  let model = go(model)
  assert model.needs
    == set.from_list([
      builder.TypedModelAnswers,
      builder.BackgroundWork,
      builder.AgentWithTools,
      builder.HumanApproval,
    ])
  let model = go(model) |> go
  assert phase(model, compose.Builder) == Free
  let replay = send(model, compose.Builder, tour.Replay, moving())
  assert replay.needs
    == set.from_list([builder.BackgroundWork, builder.UndoableSteps])
}

pub fn the_trace_tour_scrubs_to_its_events_test() {
  let go = fn(m) { send(m, compose.Trace, tour.Next, moving()) }
  let model = go(compose.init())
  assert stepper.at(model.trace) == 3
  let model = go(model)
  assert stepper.at(model.trace) == 8
  let model = go(model)
  assert stepper.at(model.trace) == 12
  let model = go(model)
  assert stepper.at(model.trace) == 16
  assert model.outcome == trace.Succeeds
  let model = go(model)
  assert model.outcome == trace.ShippingFails
  assert stepper.at(model.trace) == 18
  let back = send(model, compose.Trace, tour.Back, moving())
  assert back.outcome == trace.Succeeds
  assert stepper.at(back.trace) == 16
  assert phase(go(model), compose.Trace) == Free
}

pub fn a_job_drives_a_saga_only_with_replay_opted_in_test() {
  let assert Ok(pattern) =
    list.find(systems.patterns, fn(p) { p.name == "A job drives a saga" })
  assert string.contains(pattern.text, "ReplayAfterLeaseExpiry opted in")
  assert string.contains(pattern.text, "holds the job as Uncertain")
  assert string.contains(pattern.text, "stable id")
}
