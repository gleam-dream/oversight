import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import pages/foundations/pipeline.{
  Advance, Burst, Clear, FastObservers, Flowing, Inline, Issued, Paused,
  Settings, SlowObserver, ViaForwarder, Wire,
}

fn run_for(sim: pipeline.Sim, settings: pipeline.Settings, seconds: Int) {
  list.fold(list.repeat(Nil, seconds * 20), sim, fn(sim, _) {
    pipeline.step(sim, settings, 0.05)
  })
}

const inline_fast = Settings(Inline, FastObservers, 6, Flowing)

const inline_slow = Settings(Inline, SlowObserver, 6, Flowing)

const routed_slow = Settings(ViaForwarder, SlowObserver, 6, Flowing)

const routed_fast = Settings(ViaForwarder, FastObservers, 6, Flowing)

pub fn fast_inline_observers_keep_up_test() {
  let sim = run_for(pipeline.new(), inline_fast, 5)
  assert sim.dropped == 0
  // Each event holds the handler for the trip plus the observer, so the
  // handler emits about once per 0.4 s instead of six times a second.
  assert sim.emitted >= 10
  assert sim.delivered >= sim.emitted - 1
}

pub fn a_slow_inline_observer_blocks_the_handler_test() {
  let sim = run_for(pipeline.new(), inline_slow, 10)
  // About one request per 0.85 s: trip plus the 500 ms observer.
  assert sim.emitted <= 13
  assert sim.blocked >. 9.0
  assert sim.dropped == 0
}

pub fn a_routed_handler_never_waits_and_a_full_forwarder_drops_test() {
  let sim = run_for(pipeline.new(), routed_slow, 10)
  assert sim.blocked == 0.0
  assert sim.handler == pipeline.Serving
  // The handler keeps its pace. Emits fall on 50 ms frames, so 6 per second
  // asked comes out as one event every 0.2 s.
  assert sim.emitted == 50
  assert list.length(pipeline.queue(sim)) == pipeline.capacity
  assert sim.dropped > 0
  assert accounted(sim)
}

/// Events not yet delivered or dropped. Delivered and dropped dots stay in
/// `sim.events` while they fade, so they are left out here.
fn in_flight(sim: pipeline.Sim) -> Int {
  list.count(sim.events, fn(event) {
    case event.stage {
      pipeline.Delivered(_) | pipeline.Dropped(_) -> False
      _ -> True
    }
  })
}

/// Every event emitted is counted exactly once: delivered, dropped or still
/// in flight.
fn accounted(sim: pipeline.Sim) -> Bool {
  sim.delivered + sim.dropped + in_flight(sim) == sim.emitted
}

pub fn every_event_is_counted_once_on_every_step_test() {
  let settings = [inline_fast, inline_slow, routed_slow, routed_fast]
  list.each(settings, fn(settings) {
    let sim = pipeline.run(pipeline.new(), Issued(1, settings, Burst))
    list.fold(list.repeat(Nil, 200), sim, fn(sim, _) {
      let sim = pipeline.step(sim, settings, 0.05)
      assert accounted(sim)
      sim
    })
  })
}

pub fn switching_to_inline_lets_the_forwarder_finish_its_queue_test() {
  let sim =
    pipeline.run(pipeline.new(), Issued(1, routed_fast, Burst))
    |> run_for(routed_fast, 1)
  assert list.length(pipeline.queue(sim)) == pipeline.capacity
  // New events now run inline; the twelve already queued still reach the
  // observer instead of waiting in the bypassed forwarder for ever.
  let sim = run_for(sim, inline_fast, 20)
  assert pipeline.queue(sim) == []
  assert accounted(sim)
  assert in_flight(sim) <= 1
}

/// The forwarder keeps up exactly when this model says it does: at a rate it
/// drains, nothing drops; above it, the queue fills and drops.
pub fn the_forwarder_drops_only_when_requests_outpace_it_test() {
  list.each([FastObservers, SlowObserver], fn(observer) {
    list.each(int.range(from: 1, to: 21, with: [], run: list.prepend), fn(rate) {
      let settings = Settings(ViaForwarder, observer, rate, Flowing)
      list.each([0.05, 1.0 /. 60.0], fn(dt) {
        let sim =
          list.fold(
            list.repeat(Nil, float_steps(60.0, dt)),
            pipeline.new(),
            fn(sim, _) { pipeline.step(sim, settings, dt) },
          )
        case pipeline.forwarder_keeps_up(settings) {
          True -> {
            assert sim.dropped == 0
            assert list.length(pipeline.queue(sim)) <= 1
          }
          False -> {
            assert sim.dropped > 0
          }
        }
      })
    })
  })
  assert pipeline.forwarder_keeps_up(Settings(..routed_fast, rate: 2))
  assert !pipeline.forwarder_keeps_up(Settings(..routed_fast, rate: 3))
  assert pipeline.forwarder_keeps_up(Settings(..routed_slow, rate: 1))
  assert !pipeline.forwarder_keeps_up(routed_fast)
}

fn float_steps(seconds: Float, dt: Float) -> Int {
  float.round(seconds /. dt)
}

pub fn a_redraw_never_moves_the_pipeline_test() {
  // A reset with motion off redraws an empty pipeline: no event is emitted
  // until the reader advances it.
  let sim =
    run_for(pipeline.new(), routed_fast, 3)
    |> pipeline.run(Issued(1, routed_fast, Clear))
  assert pipeline.redraw(sim).emitted == 0
  assert pipeline.redraw(sim).events == []
  // A zero-length frame is not a redraw: it steps, and emits the event due.
  assert pipeline.frame(sim, routed_fast, 0.0).emitted == 1
  let sim = run_for(pipeline.new(), routed_slow, 3)
  let drawn = pipeline.redraw(sim)
  assert drawn.clock == sim.clock
  assert drawn.emitted == sim.emitted
  assert list.map(drawn.events, fn(event) { event.stage })
    == list.map(sim.events, fn(event) { event.stage })
}

pub fn the_forwarder_sends_one_event_at_a_time_test() {
  // As in the reference model: the forwarder hands the observer one event
  // per 0.3 s hop, so even fast observers drain under 3 per second.
  let sim =
    list.fold(list.repeat(Nil, 200), pipeline.new(), fn(sim, _) {
      let sim = pipeline.step(sim, routed_fast, 0.05)
      let sending =
        list.count(sim.events, fn(event) {
          case event.stage {
            pipeline.ToObserver(_) -> True
            _ -> False
          }
        })
      assert sending <= 1
      sim
    })
  assert sim.blocked == 0.0
  assert sim.delivered < 30
}

pub fn a_burst_is_emitted_at_once_when_routed_test() {
  let sim = run_for(pipeline.new(), routed_slow, 1)
  let before = sim.emitted
  let sim =
    pipeline.run(sim, Issued(1, routed_slow, Burst))
    |> pipeline.step(routed_slow, 0.05)
  assert sim.emitted >= before + pipeline.burst_size
}

pub fn a_burst_waits_for_the_handler_when_inline_test() {
  let sim =
    pipeline.run(pipeline.new(), Issued(1, inline_slow, Burst))
    |> pipeline.step(inline_slow, 0.05)
  assert sim.emitted == 1
  assert sim.injected == pipeline.burst_size - 1
}

pub fn paused_frames_stand_still_but_advance_still_runs_test() {
  let paused = Settings(..routed_slow, flow: Paused)
  let sim = pipeline.frame(pipeline.new(), paused, 0.05)
  assert sim.clock == 0.0
  let sim = pipeline.run(sim, Issued(1, paused, Advance(1)))
  assert sim.clock >. 0.99
  assert sim.emitted == 5
}

pub fn clear_starts_again_test() {
  let sim = run_for(pipeline.new(), routed_slow, 3)
  assert pipeline.run(sim, Issued(1, routed_slow, Clear)) == pipeline.new()
}

pub fn queued_events_slide_into_their_slots_test() {
  let sim = run_for(pipeline.new(), routed_slow, 3)
  assert list.all(pipeline.queue(sim), fn(event) { event.drawn_x == None })
  // The first drawn frame places each queued event in its slot.
  let sim = pipeline.ease(sim)
  let assert [first, second, ..] = pipeline.queue(sim)
  assert first.drawn_x == Some(352.0)
  assert second.drawn_x == Some(371.0)
}

pub fn the_wire_round_trips_test() {
  let wire =
    Wire(settings: routed_slow, latest: 7, recent: [
      Issued(7, inline_fast, Advance(2)),
      Issued(6, routed_slow, Burst),
      Issued(5, Settings(..inline_slow, flow: Paused, rate: 20), Clear),
    ])
  assert pipeline.decode(pipeline.encode(wire)) == Ok(wire)
  assert pipeline.decode(pipeline.encode(Wire(inline_fast, 0, [])))
    == Ok(Wire(inline_fast, 0, []))
  assert pipeline.decode("nonsense") == Error(Nil)
}

pub fn unseen_commands_run_oldest_first_test() {
  let wire =
    Wire(settings: routed_slow, latest: 7, recent: [
      Issued(7, inline_fast, Advance(2)),
      Issued(6, routed_slow, Burst),
      Issued(5, inline_slow, Clear),
    ])
  assert list.map(pipeline.unseen(wire, 5), fn(issued) { issued.sequence })
    == [6, 7]
  assert pipeline.unseen(wire, 7) == []
}
