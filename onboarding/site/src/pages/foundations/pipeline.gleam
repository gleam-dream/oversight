//// The Sinal pipeline behind the live widget: a request handler emits one
//// event per finished request, and observers run either inline, inside the
//// handler, or behind a bounded forwarder that drops and counts what it
//// cannot hold.
////
//// Everything here is pure. The widget steps the simulation on every frame;
//// the page owns the reader's settings and sends one-off commands, both
//// carried to the widget in one attribute so they arrive together.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// SETTINGS --------------------------------------------------------------------

/// Where observers run.
pub type Delivery {
  /// Inside the handler, before emit returns.
  Inline
  /// In the forwarder's own process, after a bounded hand-off.
  ViaForwarder
}

pub type Observer {
  /// Fast observers: 50 ms each.
  FastObservers
  /// One slow observer: 500 ms each.
  SlowObserver
}

pub type Flow {
  Flowing
  Paused
}

/// What the reader chose. Rate is requests per second, from 1 to 20.
pub type Settings {
  Settings(delivery: Delivery, observer: Observer, rate: Int, flow: Flow)
}

pub const defaults =
  Settings(delivery: Inline, observer: FastObservers, rate: 6, flow: Flowing)

/// The forwarder of the widget holds 12 events so filling it is visible. The
/// real default capacity is 1,024.
pub const capacity = 12

pub const burst_size = 30

/// Seconds each observer run takes.
pub fn observer_seconds(observer: Observer) -> Float {
  case observer {
    FastObservers -> 0.05
    SlowObserver -> 0.5
  }
}

// SIMULATION ------------------------------------------------------------------

/// Where one event is. Stages that move carry the time they started.
pub type Stage {
  /// Inline: travelling from the handler straight to the observer.
  ToObserverInline(since: Float)
  /// Routed: travelling from the handler to the forwarder.
  ToForwarder(since: Float)
  /// Held in the forwarder's queue.
  Queued
  /// Routed: leaving the forwarder for the observer.
  ToObserver(since: Float)
  /// At the observer, waiting for it to be free.
  Waiting
  /// The observer is running on this event.
  Observing(since: Float)
  /// Delivered; fading out.
  Delivered(since: Float)
  /// The forwarder was full: dropped and counted; falling away.
  Dropped(since: Float)
}

/// One event. `drawn_x` is where the picture last drew a queued event, so a
/// queue that moves up slides instead of jumping.
pub type Event {
  Event(id: Int, stage: Stage, drawn_x: Option(Float))
}

/// Whether the handler is free or waiting for an inline observer to finish.
pub type Handler {
  Serving
  WaitingFor(event: Int)
}

pub type Sim {
  Sim(
    clock: Float,
    next_emit: Float,
    events: List(Event),
    last_id: Int,
    handler: Handler,
    injected: Int,
    emitted: Int,
    delivered: Int,
    dropped: Int,
    blocked: Float,
  )
}

pub fn new() -> Sim {
  Sim(
    clock: 0.0,
    next_emit: 0.0,
    events: [],
    last_id: 0,
    handler: Serving,
    injected: 0,
    emitted: 0,
    delivered: 0,
    dropped: 0,
    blocked: 0.0,
  )
}

/// The forwarder's queue, oldest first.
pub fn queue(sim: Sim) -> List(Event) {
  list.filter(sim.events, fn(event) { event.stage == Queued })
}

/// The event the observer is running on, if any.
pub fn observing(sim: Sim) -> Option(#(Event, Float)) {
  list.find_map(sim.events, fn(event) {
    case event.stage {
      Observing(since) -> Ok(#(event, since))
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

const to_observer_inline = 0.35

const hop = 0.3

/// Advance the simulation by `dt` seconds under the given settings.
pub fn step(sim: Sim, settings: Settings, dt: Float) -> Sim {
  let t = sim.clock +. dt
  let inline = settings.delivery == Inline
  let sim = Sim(..sim, clock: t)
  let sim = emit_due(sim, settings, inline, dt)
  let sim = travel(sim)
  let sim = pick_up(sim, inline)
  let sim = finish(sim, observer_seconds(settings.observer))
  Sim(
    ..sim,
    events: list.filter(sim.events, fn(event) {
      case event.stage {
        Delivered(since) -> t -. since <=. 0.3
        Dropped(since) -> t -. since <=. 0.9
        _ -> True
      }
    }),
  )
}

fn emit(sim: Sim, inline: Bool) -> Sim {
  let id = sim.last_id + 1
  let stage = case inline {
    True -> ToObserverInline(sim.clock)
    False -> ToForwarder(sim.clock)
  }
  Sim(
    ..sim,
    last_id: id,
    events: list.append(sim.events, [Event(id:, stage:, drawn_x: None)]),
    emitted: sim.emitted + 1,
    handler: case inline {
      True -> WaitingFor(id)
      False -> sim.handler
    },
  )
}

fn interval(settings: Settings) -> Float {
  1.0 /. int.to_float(settings.rate)
}

fn emit_due(sim: Sim, settings: Settings, inline: Bool, dt: Float) -> Sim {
  let t = sim.clock
  case inline {
    True -> {
      let sim = case sim.handler {
        WaitingFor(_) -> Sim(..sim, blocked: sim.blocked +. dt)
        Serving -> sim
      }
      case sim.handler {
        WaitingFor(_) -> sim
        Serving ->
          case sim.injected > 0, t >=. sim.next_emit {
            True, _ -> emit(Sim(..sim, injected: sim.injected - 1), True)
            False, True ->
              emit(Sim(..sim, next_emit: t +. interval(settings)), True)
            False, False -> sim
          }
      }
    }
    False -> {
      let sim =
        list.fold(
          list.repeat(Nil, sim.injected),
          Sim(..sim, injected: 0),
          fn(sim, _) { emit(sim, False) },
        )
      case t >=. sim.next_emit {
        True -> Sim(..emit(sim, False), next_emit: t +. interval(settings))
        False -> sim
      }
    }
  }
}

/// Move every travelling event whose hop is over. A routed event that
/// reaches a full forwarder is dropped and counted.
fn travel(sim: Sim) -> Sim {
  let t = sim.clock
  let held = list.length(queue(sim))
  let #(events, _, dropped) =
    list.fold(sim.events, #([], held, 0), fn(acc, event) {
      let #(events, held, dropped) = acc
      let #(stage, held, dropped) = case event.stage {
        ToObserverInline(since) if t -. since >=. to_observer_inline -> #(
          Waiting,
          held,
          dropped,
        )
        ToForwarder(since) if t -. since >=. hop ->
          case held >= capacity {
            True -> #(Dropped(t), held, dropped + 1)
            False -> #(Queued, held + 1, dropped)
          }
        ToObserver(since) if t -. since >=. hop -> #(Waiting, held, dropped)
        stage -> #(stage, held, dropped)
      }
      #([Event(..event, stage:), ..events], held, dropped)
    })
  Sim(..sim, events: list.reverse(events), dropped: sim.dropped + dropped)
}

/// A free observer takes the first waiting event; otherwise a routed
/// forwarder sends its oldest queued event on, one at a time.
fn pick_up(sim: Sim, inline: Bool) -> Sim {
  let t = sim.clock
  case observing(sim) {
    Some(_) -> sim
    None ->
      case first_index(sim.events, fn(event) { event.stage == Waiting }) {
        Ok(index) -> set_stage(sim, index, Observing(t))
        Error(Nil) -> {
          let sending =
            list.any(sim.events, fn(event) {
              case event.stage {
                ToObserver(_) -> True
                _ -> False
              }
            })
          case inline || sending {
            True -> sim
            False ->
              case
                first_index(sim.events, fn(event) { event.stage == Queued })
              {
                Ok(index) -> set_stage(sim, index, ToObserver(t))
                Error(Nil) -> sim
              }
          }
        }
      }
  }
}

fn finish(sim: Sim, seconds: Float) -> Sim {
  let t = sim.clock
  case observing(sim) {
    Some(#(event, since)) if t -. since >=. seconds -> {
      let sim =
        Sim(..sim, delivered: sim.delivered + 1, handler: case sim.handler {
          WaitingFor(id) if id == event.id -> Serving
          handler -> handler
        })
      case first_index(sim.events, fn(e) { e.id == event.id }) {
        Ok(index) -> set_stage(sim, index, Delivered(t))
        Error(Nil) -> sim
      }
    }
    _ -> sim
  }
}

fn first_index(
  events: List(Event),
  wanted: fn(Event) -> Bool,
) -> Result(Int, Nil) {
  list.index_map(events, fn(event, index) { #(event, index) })
  |> list.find(fn(pair) { wanted(pair.0) })
  |> result.map(fn(pair) { pair.1 })
}

fn set_stage(sim: Sim, index: Int, stage: Stage) -> Sim {
  Sim(
    ..sim,
    events: list.index_map(sim.events, fn(event, i) {
      case i == index {
        True -> Event(..event, stage:)
        False -> event
      }
    }),
  )
}

/// Slide each queued event towards its slot, as the picture does once per
/// drawn frame.
pub fn ease(sim: Sim) -> Sim {
  let #(events, _) =
    list.fold(sim.events, #([], 0), fn(acc, event) {
      let #(events, slot) = acc
      case event.stage {
        Queued -> {
          let target = 352.0 +. int.to_float(slot) *. 19.0
          let x = case event.drawn_x {
            None -> target
            Some(x) -> x +. { target -. x } *. 0.3
          }
          #([Event(..event, drawn_x: Some(x)), ..events], slot + 1)
        }
        _ -> #([event, ..events], slot)
      }
    })
  Sim(..sim, events: list.reverse(events))
}

/// One drawn frame: step unless paused, then ease the queue into place.
pub fn frame(sim: Sim, settings: Settings, dt: Float) -> Sim {
  case settings.flow {
    Flowing -> step(sim, settings, dt)
    Paused -> sim
  }
  |> ease
}

// COMMANDS --------------------------------------------------------------------

/// A one-off command from the page.
pub type Command {
  /// Start again from an empty pipeline.
  Clear
  /// Run the simulation forward in 50 ms steps, even while paused.
  Advance(seconds: Int)
  /// Queue a burst of events for the handler to emit.
  Burst
}

/// A command as the page issued it, with the settings in force at that
/// moment, so a batch of commands replays exactly as the reader or tour
/// performed it.
pub type Issued {
  Issued(sequence: Int, settings: Settings, command: Command)
}

pub fn run(sim: Sim, issued: Issued) -> Sim {
  case issued.command {
    Clear -> new()
    Burst -> Sim(..sim, injected: sim.injected + burst_size)
    Advance(seconds) ->
      list.fold(list.repeat(Nil, seconds * 20), sim, fn(sim, _) {
        step(sim, issued.settings, 0.05)
      })
      |> ease
  }
}

// WIRE ------------------------------------------------------------------------

/// What the page sends the widget: the current settings, the latest command
/// number and the most recent commands, newest first.
pub type Wire {
  Wire(settings: Settings, latest: Int, recent: List(Issued))
}

pub fn encode(wire: Wire) -> String {
  [
    int.to_string(wire.latest),
    encode_settings(wire.settings),
    ..list.map(wire.recent, encode_issued)
  ]
  |> string.join(" ")
}

pub fn decode(text: String) -> Result(Wire, Nil) {
  case string.split(text, " ") {
    [latest, settings, ..recent] -> {
      use latest <- result.try(int.parse(latest))
      use settings <- result.try(decode_settings(string.split(settings, ",")))
      use recent <- result.try(list.try_map(recent, decode_issued))
      Ok(Wire(settings:, latest:, recent:))
    }
    _ -> Error(Nil)
  }
}

/// The commands of a wire that come after the last one seen, oldest first.
pub fn unseen(wire: Wire, seen: Int) -> List(Issued) {
  wire.recent
  |> list.filter(fn(issued) { issued.sequence > seen })
  |> list.reverse
}

fn encode_settings(settings: Settings) -> String {
  [
    case settings.delivery {
      Inline -> "inline"
      ViaForwarder -> "forwarder"
    },
    case settings.observer {
      FastObservers -> "fast"
      SlowObserver -> "slow"
    },
    int.to_string(settings.rate),
    case settings.flow {
      Flowing -> "flowing"
      Paused -> "paused"
    },
  ]
  |> string.join(",")
}

fn decode_settings(fields: List(String)) -> Result(Settings, Nil) {
  case fields {
    [delivery, observer, rate, flow] -> {
      use delivery <- result.try(case delivery {
        "inline" -> Ok(Inline)
        "forwarder" -> Ok(ViaForwarder)
        _ -> Error(Nil)
      })
      use observer <- result.try(case observer {
        "fast" -> Ok(FastObservers)
        "slow" -> Ok(SlowObserver)
        _ -> Error(Nil)
      })
      use rate <- result.try(int.parse(rate))
      use flow <- result.try(case flow {
        "flowing" -> Ok(Flowing)
        "paused" -> Ok(Paused)
        _ -> Error(Nil)
      })
      Ok(Settings(delivery:, observer:, rate:, flow:))
    }
    _ -> Error(Nil)
  }
}

fn encode_issued(issued: Issued) -> String {
  let command = case issued.command {
    Clear -> "clear"
    Burst -> "burst"
    Advance(seconds) -> "advance" <> int.to_string(seconds)
  }
  int.to_string(issued.sequence)
  <> ","
  <> encode_settings(issued.settings)
  <> ","
  <> command
}

fn decode_issued(text: String) -> Result(Issued, Nil) {
  case string.split(text, ",") {
    [sequence, delivery, observer, rate, flow, command] -> {
      use sequence <- result.try(int.parse(sequence))
      use settings <- result.try(
        decode_settings([delivery, observer, rate, flow]),
      )
      use command <- result.try(case command {
        "clear" -> Ok(Clear)
        "burst" -> Ok(Burst)
        "advance" <> seconds -> int.parse(seconds) |> result.map(Advance)
        _ -> Error(Nil)
      })
      Ok(Issued(sequence:, settings:, command:))
    }
    _ -> Error(Nil)
  }
}
