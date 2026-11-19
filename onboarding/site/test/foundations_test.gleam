import gleam/list
import gleam/string
import lustre/element
import pages/foundations.{
  AnatomyTour, CodecTour, DestinationTour, SinalTour, Tour,
}
import pages/foundations/codec
import pages/foundations/gun
import pages/foundations/pipeline.{
  Advance, Burst, Clear, FastObservers, Flowing, Inline, Paused, SlowObserver,
  ViaForwarder,
}
import site/context
import site/motion.{type Motion}
import site/progress
import site/tour.{Free, Guided, Paused as TourPaused}

fn send(
  model: foundations.Model,
  msg: foundations.Msg,
  motion: Motion,
) -> foundations.Model {
  foundations.update(model, msg, context.new(motion, progress.empty())).0
}

fn next(model, id, motion) {
  send(model, Tour(id, tour.Next), motion)
}

fn commands(model: foundations.Model) -> List(pipeline.Command) {
  model.issued |> list.reverse |> list.map(fn(issued) { issued.command })
}

// SINAL -----------------------------------------------------------------------

pub fn the_sinal_tour_moves_from_inline_to_the_forwarder_test() {
  let m = foundations.init()
  // Step 1 narrates the default: inline, fast, 6 per second.
  assert m.pipeline == pipeline.defaults
  let m = next(m, SinalTour, motion.On)
  assert m.pipeline.observer == SlowObserver
  assert m.pipeline.delivery == Inline
  let m = next(m, SinalTour, motion.On)
  assert m.pipeline.delivery == ViaForwarder
  let m = next(m, SinalTour, motion.On) |> next(SinalTour, motion.On)
  let m = next(m, SinalTour, motion.On)
  assert m.pipeline.observer == FastObservers
  // The last step lowers the rate below what the forwarder drains, so the
  // queue it promises to empty does empty.
  assert m.pipeline.rate == 1
  assert pipeline.forwarder_keeps_up(m.pipeline)
  // With motion on, nothing fast-forwards: only the burst is a command.
  assert commands(m) == [Burst]
  assert tour.phase(tour.get(m.tours, SinalTour)) == Guided(5, TourPaused)
  let m = next(m, SinalTour, motion.On)
  assert tour.phase(tour.get(m.tours, SinalTour)) == Free
}

pub fn without_motion_every_sinal_step_fast_forwards_test() {
  let m =
    list.fold([1, 2, 3, 4, 5], foundations.init(), fn(m, _) {
      next(m, SinalTour, motion.Off)
    })
  assert commands(m)
    == [Advance(2), Advance(2), Advance(2), Burst, Advance(1), Advance(2)]
  // Each command carries the settings in force when it was issued.
  let assert [slow_inline, slow_routed, ..] = list.reverse(m.issued)
  assert slow_inline.settings.delivery == Inline
  assert slow_inline.settings.observer == SlowObserver
  assert slow_routed.settings.delivery == ViaForwarder
}

pub fn the_queue_empties_after_the_last_sinal_step_test() {
  let m =
    list.fold([1, 2, 3, 4, 5], foundations.init(), fn(m, _) {
      next(m, SinalTour, motion.Off)
    })
  let sim = list.fold(list.reverse(m.issued), pipeline.new(), pipeline.run)
  let dropped = sim.dropped
  let sim =
    list.fold(list.repeat(Nil, 15 * 20), sim, fn(sim, _) {
      pipeline.step(sim, m.pipeline, 0.05)
    })
  assert pipeline.queue(sim) == []
  assert sim.dropped == dropped
}

pub fn the_slow_observer_button_says_500_ms_test() {
  let html =
    foundations.view(
      foundations.init(),
      context.new(motion.On, progress.empty()),
    )
    |> element.to_string
  assert string.contains(html, "Attach a slow observer (500 ms)")
  assert !string.contains(html, "(50 ms)")
}

pub fn going_back_clears_and_replays_the_sinal_steps_test() {
  let m =
    list.fold([1, 2, 3], foundations.init(), fn(m, _) {
      next(m, SinalTour, motion.Off)
    })
  let before = m.latest
  let m = send(m, Tour(SinalTour, tour.Back), motion.Off)
  assert m.pipeline.delivery == ViaForwarder
  assert m.pipeline.observer == SlowObserver
  let replayed =
    m.issued
    |> list.filter(fn(issued) { issued.sequence > before })
    |> list.reverse
    |> list.map(fn(issued) { issued.command })
  // The reset clears, then steps 2 and 3 fast-forward again.
  assert replayed == [Clear, Advance(2), Advance(2)]
}

pub fn the_reader_controls_the_pipeline_test() {
  let m = foundations.init()
  let m = send(m, foundations.ReaderSetRate(14), motion.On)
  assert m.pipeline.rate == 14
  let m = send(m, foundations.ReaderPausedPipeline, motion.On)
  assert m.pipeline.flow == Paused
  let m = send(m, foundations.ReaderResetPipeline, motion.On)
  assert m.pipeline.flow == Flowing
  assert commands(m) == [Clear]
  let m = send(m, foundations.ReaderSentBurst, motion.Off)
  assert commands(m) == [Clear, Burst, Advance(1)]
  let m = send(m, foundations.ReaderAdvancedOneSecond, motion.Off)
  assert commands(m) == [Clear, Burst, Advance(1), Advance(1)]
}

pub fn the_widget_keeps_only_recent_commands_test() {
  let m =
    list.fold(list.repeat(Nil, 30), foundations.init(), fn(m, _) {
      send(m, foundations.ReaderAdvancedOneSecond, motion.Off)
    })
  assert m.latest == 30
  assert list.length(m.issued) == 12
}

pub fn the_note_follows_the_settings_test() {
  let note =
    foundations.note(pipeline.Settings(Inline, SlowObserver, 9, Flowing))
  assert note
    == "Inline with a slow observer: the handler can’t serve the next request until telemetry finishes. Requests asked for 9/s; the handler now manages about 1 per second."
}

pub fn the_note_says_when_fast_observers_still_drop_test() {
  let routed_fast = pipeline.Settings(ViaForwarder, FastObservers, 6, Flowing)
  assert foundations.note(routed_fast)
    == "Routed with fast observers: the handler never waits, but this forwarder hands the observer one event at a time, under 3 per second. At 6/s requests arrive faster, so it still fills and drops. At 2/s or less it drains."
  assert foundations.note(pipeline.Settings(..routed_fast, rate: 2))
    == "Routed with fast observers: the forwarder drains faster than events arrive. Nothing waits and nothing drops."
  let routed_slow = pipeline.Settings(..routed_fast, observer: SlowObserver)
  assert string.starts_with(
    foundations.note(pipeline.Settings(..routed_slow, rate: 1)),
    "Routed with a slow observer at 1 request per second: the forwarder just keeps up.",
  )
  assert string.starts_with(
    foundations.note(routed_slow),
    "Routed: the handler hands events to the forwarder",
  )
}

// JSON BLUEPRINT --------------------------------------------------------------

pub fn the_codec_tour_shows_three_faces_test() {
  let m = foundations.init()
  assert m.face == codec.Decode
  let m = next(m, CodecTour, motion.On)
  assert m.face == codec.Encode
  let m = next(m, CodecTour, motion.On)
  assert m.face == codec.Decode
  assert m.incoming == codec.Valid
  let m = next(m, CodecTour, motion.On)
  assert m.incoming == codec.AgeTooHigh
  let m = next(m, CodecTour, motion.On)
  assert m.incoming == codec.RepeatedKey
  let m = next(m, CodecTour, motion.On)
  assert m.face == codec.Schema
  // The picked input is remembered while another face shows.
  assert m.incoming == codec.RepeatedKey
  let m = next(m, CodecTour, motion.On)
  assert tour.phase(tour.get(m.tours, CodecTour)) == Free
}

pub fn only_valid_json_decodes_test() {
  let decoded =
    list.filter(codec.incoming, fn(input) {
      codec.case_of(input).outcome == codec.Decoded
    })
  assert decoded == [codec.Valid]
}

// HTTP GUN --------------------------------------------------------------------

pub fn the_anatomy_tour_follows_the_request_test() {
  let m = foundations.init()
  assert m.part == gun.ClientPool
  let parts =
    list.fold([1, 2, 3, 4], #(m, []), fn(acc, _) {
      let m = next(acc.0, AnatomyTour, motion.On)
      #(m, [m.part, ..acc.1])
    }).1
    |> list.reverse
  assert parts
    == [gun.YourProcess, gun.ClientPool, gun.BodyOwner, gun.GunConnections]
}

fn admitted(policy: gun.Policy) -> List(String) {
  gun.destinations
  |> list.filter(fn(destination) {
    case gun.admit(policy, destination) {
      gun.Admitted(_) -> True
      gun.Refused(_) -> False
    }
  })
  |> list.map(fn(destination) { destination.url })
}

pub fn each_policy_admits_its_destinations_test() {
  assert admitted(gun.DefaultPolicy)
    == ["https://api.payments.example", "http://api.payments.example"]
  assert admitted(gun.RequireTls) == ["https://api.payments.example"]
  assert admitted(gun.LocalTests)
    == [
      "https://api.payments.example",
      "http://api.payments.example",
      "http://127.0.0.1:4000",
    ]
}

pub fn the_destination_tour_walks_the_policies_test() {
  let m =
    foundations.init()
    |> next(DestinationTour, motion.On)
    |> next(DestinationTour, motion.On)
  assert m.policy == gun.RequireTls
  let m = next(m, DestinationTour, motion.On)
  assert m.policy == gun.LocalTests
  let m = send(m, Tour(DestinationTour, tour.Skip), motion.On)
  assert m.policy == gun.LocalTests
  let m = send(m, Tour(DestinationTour, tour.Replay), motion.On)
  assert m.policy == gun.DefaultPolicy
}

pub fn tour_keys_match_the_reference_test() {
  assert list.map(
      [SinalTour, CodecTour, AnatomyTour, DestinationTour],
      foundations.key,
    )
    == ["sinal", "codec", "anatomy", "dest"]
}

pub fn the_tour_quotes_the_slow_drain_rate_of_the_model_test() {
  // One hop plus a slow observer run: a little over one event a second.
  let drain = pipeline.forwarder_drain(pipeline.SlowObserver)
  assert drain >. 1.0 && drain <. 1.5
  let narration =
    foundations.script(foundations.SinalTour).steps
    |> list.map(fn(step) { step.text })
    |> string.join(" ")
  assert string.contains(narration, "drains only about 1 per second")
}
