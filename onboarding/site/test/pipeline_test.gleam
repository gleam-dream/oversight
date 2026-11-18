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
  // Every event is accounted for: delivered, dropped or still in flight.
  assert sim.delivered + sim.dropped + list.length(sim.events) >= sim.emitted
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
