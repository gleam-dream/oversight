//// The real-time scheduler: a Lustre component that owns the two-core
//// simulation and redraws only its own SVG on every frame.
////
//// The page passes one `controls` attribute: the scheduling style, whether
//// the greedy process is in, and two counters for one-off commands (reset,
//// advance one second). Settings and commands travel together so an advance
//// always runs under the settings the page had when it asked for it.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute.{type Attribute, attribute}
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/keyed
import lustre/element/svg
import pages/beam/scheduler.{
  type Process, type Scheduling, type Task, type Workload, Asleep, Cooperative,
  Preemptive, Ready, Running, WellBehaved, WithGreedy,
}
import site/live
import site/motion.{type Motion}

pub const tag = "gd-scheduler"

pub fn register() -> Result(Nil, lustre.Error) {
  lustre.register(
    lustre.component(init, update, view, [
      component.on_connect(Connected),
      component.on_disconnect(Disconnected),
      live.on_motion(MotionChanged),
      component.on_attribute_change("controls", fn(value) {
        decode(value) |> option.to_result(Nil) |> result.map(ControlsChanged)
      }),
    ]),
    tag,
  )
}

// ATTRIBUTES ------------------------------------------------------------------

/// What the page asks of the widget: settings, and counters that only grow.
pub type Controls {
  Controls(
    scheduling: Scheduling,
    workload: Workload,
    resets: Int,
    advances: Int,
  )
}

pub fn encode(controls: Controls) -> String {
  string.join(
    [
      case controls.scheduling {
        Cooperative -> "cooperative"
        Preemptive -> "preemptive"
      },
      case controls.workload {
        WellBehaved -> "calm"
        WithGreedy -> "greedy"
      },
      int.to_string(controls.resets),
      int.to_string(controls.advances),
    ],
    " ",
  )
}

pub fn decode(value: String) -> Option(Controls) {
  case string.split(value, " ") {
    [scheduling, workload, resets, advances] -> {
      let scheduling = case scheduling {
        "cooperative" -> Ok(Cooperative)
        "preemptive" -> Ok(Preemptive)
        _ -> Error(Nil)
      }
      let workload = case workload {
        "calm" -> Ok(WellBehaved)
        "greedy" -> Ok(WithGreedy)
        _ -> Error(Nil)
      }
      case scheduling, workload, int.parse(resets), int.parse(advances) {
        Ok(scheduling), Ok(workload), Ok(resets), Ok(advances) ->
          Some(Controls(scheduling:, workload:, resets:, advances:))
        _, _, _, _ -> None
      }
    }
    _ -> None
  }
}

/// The attributes the page puts on the widget's element.
pub fn attributes(controls: Controls, motion: Motion) -> List(Attribute(msg)) {
  [attribute("controls", encode(controls)), live.motion_attribute(motion)]
}

// MODEL -----------------------------------------------------------------------

/// The widget's place in the shared frame loop.
type Loop {
  Stopped
  Starting
  Following(handle: Int)
}

pub opaque type Model {
  Model(
    sim: scheduler.Sim,
    scheduling: Scheduling,
    workload: Workload,
    motion: Motion,
    connected: Bool,
    loop: Loop,
    seen_resets: Option(Int),
    seen_advances: Option(Int),
    /// Where each process token is drawn; tokens glide towards their place.
    shown: Dict(Task, #(Float, Float)),
    /// Simulated time not yet stepped, carried between frames.
    pending: Float,
  )
}

pub opaque type Msg {
  Connected
  Disconnected
  MotionChanged(Motion)
  ControlsChanged(Controls)
  Subscribed(Int)
  Frame(Float)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(
      sim: scheduler.new(),
      scheduling: Preemptive,
      workload: WellBehaved,
      motion: motion.Off,
      connected: False,
      loop: Stopped,
      seen_resets: None,
      seen_advances: None,
      shown: dict.new(),
      pending: 0.0,
    ),
    effect.none(),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Connected -> follow_frames(snap(Model(..model, connected: True)))
    Disconnected -> follow_frames(Model(..model, connected: False))
    MotionChanged(motion) -> follow_frames(snap(Model(..model, motion:)))
    ControlsChanged(controls) -> #(snap(apply(model, controls)), effect.none())
    Subscribed(handle) ->
      case model.loop {
        Starting -> #(Model(..model, loop: Following(handle)), effect.none())
        _ -> #(model, live.unsubscribe(live.Subscribed(handle)))
      }
    Frame(dt) -> #(frame(model, dt), effect.none())
  }
}

/// Subscribe to frames while connected with motion on; otherwise stop.
fn follow_frames(model: Model) -> #(Model, Effect(Msg)) {
  let wanted = model.connected && motion.is_on(model.motion)
  case wanted, model.loop {
    True, Stopped -> #(
      Model(..model, loop: Starting),
      live.subscribe(Frame, Subscribed),
    )
    False, Following(handle) -> #(
      Model(..model, loop: Stopped),
      live.unsubscribe(live.Subscribed(handle)),
    )
    False, Starting -> #(Model(..model, loop: Stopped), effect.none())
    _, _ -> #(model, effect.none())
  }
}

/// Apply new controls: a reset first, then the settings, then any advances
/// under those settings.
fn apply(model: Model, controls: Controls) -> Model {
  let #(reset, seen_resets) = live.is_new(model.seen_resets, controls.resets)
  let advances = case model.seen_advances {
    Some(previous) -> int.max(0, controls.advances - previous)
    None -> 0
  }
  let #(_, seen_advances) = live.is_new(model.seen_advances, controls.advances)
  let sim = case reset {
    True -> scheduler.new()
    False -> model.sim
  }
  let sim =
    scheduler.set_workload(sim, controls.workload)
    |> scheduler.run(int.to_float(advances), controls.scheduling)
  Model(
    ..model,
    sim:,
    scheduling: controls.scheduling,
    workload: controls.workload,
    seen_resets:,
    seen_advances:,
  )
}

/// Advance the simulation in whole steps and let tokens glide.
fn frame(model: Model, dt: Float) -> Model {
  let pending = model.pending +. dt
  let steps = float.truncate(pending /. scheduler.step_seconds)
  let sim =
    list.fold(list.repeat(Nil, steps), model.sim, fn(sim, _) {
      scheduler.step(sim, model.scheduling)
    })
  let pending = pending -. int.to_float(steps) *. scheduler.step_seconds
  let shown =
    targets(sim)
    |> dict.map_values(fn(task, target) {
      case dict.get(model.shown, task) {
        Ok(#(x, y)) -> #(
          x +. { target.0 -. x } *. 0.25,
          y +. { target.1 -. y } *. 0.25,
        )
        Error(Nil) -> target
      }
    })
  Model(..model, sim:, pending:, shown:)
}

/// Without motion, tokens sit exactly where they belong.
fn snap(model: Model) -> Model {
  case model.motion {
    motion.On -> model
    motion.Off -> Model(..model, shown: targets(model.sim))
  }
}

// LAYOUT ----------------------------------------------------------------------

const queue_head_x = 506.0

const queue_y = 132.0

const queue_gap = 34.0

const queue_shown = 9

/// Where each process belongs: asleep in the pool, in the run queue, or on
/// its core.
fn targets(sim: scheduler.Sim) -> Dict(Task, #(Float, Float)) {
  let queue = scheduler.queue(sim)
  list.fold(scheduler.processes(sim), dict.new(), fn(acc, process) {
    let place = case process.phase {
      Asleep(..) -> sleeping_place(process.task)
      Ready(..) -> {
        let index =
          list.take_while(queue, fn(p) { p.task != process.task })
          |> list.length
          |> int.min(queue_shown)
        #(queue_head_x -. int.to_float(index) *. queue_gap, queue_y)
      }
      Running(core:, ..) -> #(614.0, core_y(core) +. 40.0)
    }
    dict.insert(acc, process.task, place)
  })
}

fn sleeping_place(task: Task) -> #(Float, Float) {
  case task {
    scheduler.A -> #(70.0, 112.0)
    scheduler.B -> #(130.0, 112.0)
    scheduler.C -> #(70.0, 162.0)
    scheduler.D -> #(130.0, 162.0)
    scheduler.Greedy -> #(100.0, 210.0)
  }
}

fn core_y(core: Int) -> Float {
  case core {
    0 -> 40.0
    _ -> 140.0
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  let sim = model.sim
  let waiting = list.length(scheduler.queue(sim))
  let wait_slices = float.round(scheduler.longest_wait(sim) /. scheduler.budget)
  svg.svg(
    [
      attribute("viewBox", "0 30 860 322"),
      attribute("width", "100%"),
      attribute.role("img"),
      attribute.aria_label(
        "Animation of processes waking, queueing for two cores, running and going back to sleep",
      ),
      attribute.style("display", "block"),
      attribute.style("max-width", "860px"),
      attribute.style("margin", "0 auto"),
      attribute.style("font-family", "Inter, system-ui, sans-serif"),
    ],
    [
      // Asleep: waiting for a message.
      box(20.0, 40.0, 170.0, 200.0, "#F6F4FF", "#DCD9FF"),
      text(105.0, 64.0, "middle", 13, "600", "#17162B", "asleep"),
      text(105.0, 82.0, "middle", 11, "", "#5B5970", "waiting for a message"),
      // The run queue.
      text(220.0, 108.0, "start", 11, "", "#5B5970", "run queue"),
      text(
        540.0,
        108.0,
        "end",
        11,
        "700",
        "#B42318",
        case waiting > queue_shown + 1 {
          True -> "+" <> int.to_string(waiting - queue_shown - 1) <> " more"
          False -> ""
        },
      ),
      box(206.0, 114.0, 334.0, 36.0, "#FFFFFF", "#DCD9FF"),
      text(
        373.0,
        172.0,
        "middle",
        11,
        "",
        "#8A8698",
        "ready → takes the next free core",
      ),
      // The cores.
      element.fragment(
        list.index_map(scheduler.running(sim), fn(process, core) {
          core_box(sim, model.scheduling, core, process)
        }),
      ),
      // Tokens.
      keyed.namespaced(
        "http://www.w3.org/2000/svg",
        "g",
        [],
        list.map(scheduler.processes(sim), fn(process) {
          #(scheduler.label(process.task), token(model, process))
        }),
      ),
      // Timelines: one square per time slice, newest on the right.
      element.fragment(
        list.index_map(scheduler.timelines(sim), fn(slices, core) {
          timeline(slices, core)
        }),
      ),
      text(80.0, 316.0, "start", 11, "", "#8A8698", "time →"),
      text(
        20.0,
        342.0,
        "start",
        12,
        "600",
        "#17162B",
        "run queue "
          <> int.to_string(waiting)
          <> " · longest wait for a normal process "
          <> int.to_string(wait_slices)
          <> case wait_slices == 1 {
          True -> " slice"
          False -> " slices"
        }
          <> " · core 1 busy "
          <> int.to_string(scheduler.busy(sim, 0))
          <> "% · core 2 busy "
          <> int.to_string(scheduler.busy(sim, 1))
          <> "%",
      ),
    ],
  )
}

fn core_box(
  sim: scheduler.Sim,
  scheduling: Scheduling,
  core: Int,
  process: Option(Process),
) -> Element(Msg) {
  let y = core_y(core)
  let name = "core " <> int.to_string(core + 1)
  let #(status, fill, width) = case process {
    None -> #("idle", "#D5D1C8", 0.0)
    Some(p) -> {
      let since = case p.phase {
        Running(since:, ..) -> since
        _ -> scheduler.clock(sim)
      }
      let elapsed = scheduler.clock(sim) -. since
      case scheduling {
        Preemptive -> {
          let left = float.max(0.0, 1.0 -. elapsed /. scheduler.budget)
          #("work budget left", "#B45309", left *. 170.0)
        }
        Cooperative -> #(
          "no budget · running "
            <> float.to_string(float.to_precision(elapsed, 1))
            <> " s",
          case p.task {
            scheduler.Greedy -> "#B42318"
            _ -> "#B45309"
          },
          170.0,
        )
      }
    }
  }
  element.fragment([
    box(580.0, y, 260.0, 80.0, "#FDF0DC", "#F3D9B1"),
    text(596.0, y +. 20.0, "start", 12, "600", "#17162B", name),
    svg.rect([
      attribute("x", "650"),
      attribute("y", float.to_string(y +. 36.0)),
      attribute("width", "170"),
      attribute("height", "8"),
      attribute("rx", "4"),
      attribute("fill", "#F3D9B1"),
    ]),
    svg.rect([
      attribute("x", "650"),
      attribute("y", float.to_string(y +. 36.0)),
      attribute("width", float.to_string(float.to_precision(width, 1))),
      attribute("height", "8"),
      attribute("rx", "4"),
      attribute("fill", fill),
    ]),
    text(650.0, y +. 62.0, "start", 10, "", "#5B5970", status),
  ])
}

fn token(model: Model, process: Process) -> Element(Msg) {
  let #(x, y) = case dict.get(model.shown, process.task) {
    Ok(place) -> place
    Error(Nil) -> sleeping_place(process.task)
  }
  let #(bg, fg) = scheduler.colours(process.task)
  let opacity = case process.phase {
    Asleep(..) -> "0.55"
    _ -> "1"
  }
  let x = float.to_string(float.to_precision(x, 1))
  let y_text = float.to_string(float.to_precision(y +. 4.5, 1))
  let y = float.to_string(float.to_precision(y, 1))
  svg.g([attribute("opacity", opacity)], [
    svg.circle([
      attribute("cx", x),
      attribute("cy", y),
      attribute("r", "14"),
      attribute("fill", bg),
      attribute("stroke", fg),
      attribute("stroke-width", "1.5"),
    ]),
    svg.text(
      [
        attribute("x", x),
        attribute("y", y_text),
        attribute("text-anchor", "middle"),
        attribute("font-size", "13"),
        attribute("font-weight", "700"),
        attribute("fill", fg),
      ],
      scheduler.label(process.task),
    ),
  ])
}

fn timeline(slices: List(Option(Task)), core: Int) -> Element(Msg) {
  let y = 244.0 +. int.to_float(core) *. 32.0
  // Right-align so the newest slice sits at the right edge.
  let offset = scheduler.timeline - list.length(slices)
  element.fragment([
    text(
      20.0,
      y +. 18.0,
      "start",
      11,
      "",
      "#5B5970",
      "core " <> int.to_string(core + 1),
    ),
    element.fragment(
      list.index_map(slices, fn(slot, i) {
        let x = 80.0 +. int.to_float(offset + i) *. 48.0
        let #(bg, fg, label) = case slot {
          Some(task) -> {
            let #(bg, fg) = scheduler.colours(task)
            #(bg, fg, scheduler.label(task))
          }
          None -> #("#F1EEE8", "#8A8698", "·")
        }
        svg.g([], [
          svg.rect([
            attribute("x", float.to_string(x)),
            attribute("y", float.to_string(y)),
            attribute("width", "44"),
            attribute("height", "26"),
            attribute("rx", "6"),
            attribute("fill", bg),
          ]),
          svg.text(
            [
              attribute("x", float.to_string(x +. 22.0)),
              attribute("y", float.to_string(y +. 17.5)),
              attribute("text-anchor", "middle"),
              attribute("font-size", "12"),
              attribute("font-weight", "600"),
              attribute("fill", fg),
            ],
            label,
          ),
        ])
      }),
    ),
  ])
}

fn box(
  x: Float,
  y: Float,
  w: Float,
  h: Float,
  fill: String,
  stroke: String,
) -> Element(Msg) {
  svg.rect([
    attribute("x", float.to_string(x)),
    attribute("y", float.to_string(y)),
    attribute("width", float.to_string(w)),
    attribute("height", float.to_string(h)),
    attribute("rx", "12"),
    attribute("fill", fill),
    attribute("stroke", stroke),
  ])
}

fn text(
  x: Float,
  y: Float,
  anchor: String,
  size: Int,
  weight: String,
  fill: String,
  content: String,
) -> Element(Msg) {
  svg.text(
    [
      attribute("x", float.to_string(x)),
      attribute("y", float.to_string(y)),
      attribute("text-anchor", anchor),
      attribute("font-size", int.to_string(size)),
      case weight {
        "" -> attribute.none()
        w -> attribute("font-weight", w)
      },
      attribute("fill", fill),
    ],
    content,
  )
}
