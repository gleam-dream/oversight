//// The live Sinal pipeline: a Lustre component that steps the pure
//// simulation on every animation frame and redraws only its own SVG.
////
//// The page passes the reader's settings and its recent commands in one
//// `pipeline` attribute, and the motion setting in `motion`. With motion off
//// the widget draws its current state and moves only when commanded.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute.{type Attribute, attribute}
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/keyed
import lustre/element/svg
import pages/foundations/pipeline.{
  type Settings, type Sim, Delivered, Dropped, Inline, Observing, Queued,
  SlowObserver, ToForwarder, ToObserver, ToObserverInline, Waiting,
}
import site/live
import site/motion.{type Motion}

pub const tag = "gd-sinal"

pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
    live.on_motion(MotionChanged),
    component.on_attribute_change("pipeline", fn(value) {
      Ok(PageSentPipeline(value))
    }),
  ])
  |> lustre.register(tag)
}

/// The attribute that carries settings and commands to the widget.
pub fn pipeline_attribute(wire: pipeline.Wire) -> Attribute(msg) {
  attribute("pipeline", pipeline.encode(wire))
}

// MODEL -----------------------------------------------------------------------

type Presence {
  Attached
  Detached
}

type Widget {
  Widget(
    sim: Sim,
    settings: Settings,
    seen: Option(Int),
    motion: Motion,
    presence: Presence,
    frames: live.Frames,
  )
}

type Msg {
  Connected
  Disconnected
  MotionChanged(Motion)
  PageSentPipeline(String)
  Subscribed(Int)
  Frame(Float)
}

fn init(_: Nil) -> #(Widget, Effect(Msg)) {
  #(
    Widget(
      sim: pipeline.new(),
      settings: pipeline.defaults,
      seen: None,
      motion: motion.Off,
      presence: Detached,
      frames: live.Unsubscribed,
    ),
    effect.none(),
  )
}

// UPDATE ----------------------------------------------------------------------

fn update(widget: Widget, msg: Msg) -> #(Widget, Effect(Msg)) {
  case msg {
    Connected -> follow(Widget(..widget, presence: Attached))
    Disconnected -> stop(Widget(..widget, presence: Detached))
    MotionChanged(motion) -> follow(Widget(..widget, motion:))
    PageSentPipeline(text) ->
      case pipeline.decode(text) {
        Ok(wire) -> #(settle(receive(widget, wire)), effect.none())
        Error(Nil) -> #(widget, effect.none())
      }
    Subscribed(handle) ->
      case wants_frames(widget), widget.frames {
        True, live.Unsubscribed -> #(
          Widget(..widget, frames: live.Subscribed(handle)),
          effect.none(),
        )
        _, _ -> #(widget, live.unsubscribe(live.Subscribed(handle)))
      }
    Frame(dt) -> #(
      Widget(..widget, sim: pipeline.frame(widget.sim, widget.settings, dt)),
      effect.none(),
    )
  }
}

fn wants_frames(widget: Widget) -> Bool {
  widget.presence == Attached && widget.motion == motion.On
}

/// Subscribe to frames when attached with motion on; otherwise stop and draw
/// the current state, as the reference does on every repaint without motion.
fn follow(widget: Widget) -> #(Widget, Effect(Msg)) {
  case wants_frames(widget), widget.frames {
    True, live.Unsubscribed -> #(widget, live.subscribe(Frame, Subscribed))
    True, live.Subscribed(_) -> #(widget, effect.none())
    False, _ -> {
      let #(widget, effect) = stop(widget)
      #(settle(widget), effect)
    }
  }
}

fn stop(widget: Widget) -> #(Widget, Effect(Msg)) {
  #(
    Widget(..widget, frames: live.Unsubscribed),
    live.unsubscribe(widget.frames),
  )
}

/// Without motion, every change redraws with a zero-length frame.
fn settle(widget: Widget) -> Widget {
  case widget.motion, widget.presence {
    motion.Off, Attached ->
      Widget(..widget, sim: pipeline.frame(widget.sim, widget.settings, 0.0))
    _, _ -> widget
  }
}

/// Take the page's settings and run the commands not seen yet. The first
/// pipeline a widget sees only sets its baseline: earlier commands belonged
/// to an earlier visit.
fn receive(widget: Widget, wire: pipeline.Wire) -> Widget {
  let sim = case widget.seen {
    None -> widget.sim
    Some(seen) ->
      list.fold(pipeline.unseen(wire, seen), widget.sim, pipeline.run)
  }
  let seen = case widget.seen {
    None -> wire.latest
    Some(seen) -> int.max(seen, wire.latest)
  }
  Widget(..widget, sim:, settings: wire.settings, seen: Some(seen))
}

// VIEW ------------------------------------------------------------------------

const red = "#B42318"

const muted = "#5B5970"

fn view(widget: Widget) -> Element(Msg) {
  let sim = widget.sim
  let settings = widget.settings
  let inline = settings.delivery == Inline
  let slow = settings.observer == SlowObserver
  let queued = list.length(pipeline.queue(sim))
  let blocked_now = case inline, sim.handler {
    True, pipeline.WaitingFor(_) -> True
    _, _ -> False
  }
  let progress = case pipeline.observing(sim) {
    Some(#(_, since)) ->
      fixed(
        float.min(
          110.0,
          { sim.clock -. since }
            /. pipeline.observer_seconds(settings.observer)
            *. 110.0,
        ),
        1,
      )
    None -> "0"
  }
  svg.svg(
    [
      attribute("viewBox", "0 0 860 220"),
      attribute("width", "100%"),
      attribute.role("img"),
      attribute.aria_label(
        "Animation of telemetry events flowing from a request handler to observers, inline or through a bounded forwarder",
      ),
      attribute(
        "style",
        "display:block;max-width:860px;margin:0 auto;font-family:Inter,system-ui,sans-serif",
      ),
    ],
    [
      svg.rect([
        attribute("x", "20"),
        attribute("y", "40"),
        attribute("width", "150"),
        attribute("height", "110"),
        attribute("rx", "14"),
        attribute("fill", "#F6F4FF"),
        attribute("stroke", case blocked_now && slow {
          True -> red
          False -> "#DCD9FF"
        }),
        attribute("stroke-width", "2"),
      ]),
      label(95, 66, 13, True, "#17162B", "request handler"),
      label(
        95,
        128,
        11,
        False,
        case blocked_now && slow {
          True -> red
          False -> muted
        },
        case blocked_now, slow {
          True, True -> "BLOCKED on telemetry"
          True, False -> "emitting"
          False, _ -> "serving requests"
        },
      ),
      forwarder(inline, queued),
      svg.rect([
        attribute("x", "672"),
        attribute("y", "40"),
        attribute("width", "180"),
        attribute("height", "110"),
        attribute("rx", "14"),
        attribute("fill", "#FFFFFF"),
        attribute("stroke", "#E4E0D8"),
        attribute("stroke-width", "2"),
      ]),
      label(762, 66, 13, True, "#17162B", case slow {
        True -> "slow observer · 500 ms"
        False -> "fast observers"
      }),
      svg.rect([
        attribute("x", "707"),
        attribute("y", "118"),
        attribute("width", "110"),
        attribute("height", "8"),
        attribute("rx", "4"),
        attribute("fill", "#EDEFF3"),
      ]),
      svg.rect([
        attribute("x", "707"),
        attribute("y", "118"),
        attribute("width", progress),
        attribute("height", "8"),
        attribute("rx", "4"),
        attribute("fill", red),
      ]),
      label(762, 142, 11, False, muted, case inline {
        True -> "runs inside the handler process"
        False -> "runs inside the forwarder process"
      }),
      svg.text(
        [
          attribute("x", "20"),
          attribute("y", "200"),
          attribute("font-size", "12"),
          attribute("font-weight", "600"),
          attribute("fill", "#17162B"),
        ],
        "emitted "
          <> int.to_string(sim.emitted)
          <> " · delivered "
          <> int.to_string(sim.delivered)
          <> " · dropped and counted "
          <> int.to_string(sim.dropped)
          <> " · handler blocked "
          <> fixed(sim.blocked, 1)
          <> " s",
      ),
      keyed.namespaced(
        "http://www.w3.org/2000/svg",
        "g",
        [],
        list.map(sim.events, fn(event) {
          #(int.to_string(event.id), dot(sim, event))
        }),
      ),
    ],
  )
}

fn forwarder(inline: Bool, queued: Int) -> Element(Msg) {
  svg.g(
    [
      attribute("opacity", case inline {
        True -> "0.25"
        False -> "1"
      }),
    ],
    [
      svg.rect([
        attribute("x", "330"),
        attribute("y", "50"),
        attribute("width", "250"),
        attribute("height", "90"),
        attribute("rx", "14"),
        attribute("fill", "#EAF7F5"),
        attribute("stroke", "#9FD6CF"),
        attribute("stroke-width", "2"),
      ]),
      label(
        455,
        72,
        13,
        True,
        "#0B4A45",
        "forwarder · holds " <> int.to_string(pipeline.capacity),
      ),
      // The honesty label stays visible while touring, when the playground's
      // description is hidden.
      label(
        455,
        42,
        10,
        False,
        "#5B5970",
        "12 slots here for visibility · the real default is 1,024",
      ),
      element.fragment(
        int.range(
          from: pipeline.capacity - 1,
          to: -1,
          with: [],
          run: fn(acc, i) { [slot(i), ..acc] },
        ),
      ),
      label(455, 134, 11, False, "#0B4A45", case inline {
        True -> "bypassed: observers run in the handler"
        False ->
          int.to_string(queued)
          <> " queued"
          <> case queued >= pipeline.capacity {
            True -> " · FULL: new events dropped"
            False -> ""
          }
      }),
    ],
  )
}

fn slot(i: Int) -> Element(Msg) {
  svg.rect([
    attribute("x", int.to_string(345 + i * 19)),
    attribute("y", "86"),
    attribute("width", "15"),
    attribute("height", "30"),
    attribute("rx", "4"),
    attribute("fill", "#FFFFFF"),
    attribute("stroke", "#C8E9E4"),
  ])
}

fn label(
  x: Int,
  y: Int,
  size: Int,
  bold: Bool,
  fill: String,
  text: String,
) -> Element(Msg) {
  svg.text(
    [
      attribute("x", int.to_string(x)),
      attribute("y", int.to_string(y)),
      attribute("text-anchor", "middle"),
      attribute("font-size", int.to_string(size)),
      case bold {
        True -> attribute("font-weight", "600")
        False -> attribute.none()
      },
      attribute("fill", fill),
    ],
    text,
  )
}

/// One event as a dot, positioned by its stage.
fn dot(sim: Sim, event: pipeline.Event) -> Element(Msg) {
  let t = sim.clock
  let along = fn(since, seconds) { float.min(1.0, { t -. since } /. seconds) }
  let teal = "#0F766E"
  let #(x, y, fill, opacity) = case event.stage {
    ToObserverInline(since) -> #(
      170.0 +. { 690.0 -. 170.0 } *. along(since, 0.35),
      101.0,
      teal,
      1.0,
    )
    ToForwarder(since) -> #(
      170.0 +. { 340.0 -. 170.0 } *. along(since, 0.3),
      101.0,
      teal,
      1.0,
    )
    Queued -> #(option.unwrap(event.drawn_x, 352.0), 101.0, teal, 1.0)
    ToObserver(since) -> #(
      580.0 +. { 690.0 -. 580.0 } *. along(since, 0.3),
      101.0,
      teal,
      1.0,
    )
    Waiting -> #(700.0, 101.0, teal, 1.0)
    Observing(_) -> #(765.0, 94.0, red, 1.0)
    Dropped(since) -> {
      let q = t -. since
      #(
        336.0 -. q *. 20.0,
        101.0 +. q *. q *. 160.0,
        red,
        float.max(0.0, 1.0 -. q /. 0.9),
      )
    }
    Delivered(since) -> #(
      765.0,
      94.0 -. { t -. since } *. 70.0,
      teal,
      float.max(0.0, 1.0 -. { t -. since } /. 0.3),
    )
  }
  svg.circle([
    attribute("r", "6.5"),
    attribute("cx", fixed(x, 1)),
    attribute("cy", fixed(y, 1)),
    attribute("fill", fill),
    attribute("opacity", fixed(opacity, 2)),
  ])
}

/// A number with a fixed count of decimals, as JavaScript's `toFixed`.
fn fixed(value: Float, decimals: Int) -> String {
  let scale = int.to_float(pow10(decimals))
  let scaled = float.round(float.absolute_value(value) *. scale)
  let sign = case value <. 0.0 && scaled > 0 {
    True -> "-"
    False -> ""
  }
  let whole = scaled / pow10(decimals)
  let part = scaled % pow10(decimals)
  case decimals {
    0 -> sign <> int.to_string(whole)
    _ ->
      sign
      <> int.to_string(whole)
      <> "."
      <> string.pad_start(int.to_string(part), decimals, "0")
  }
}

fn pow10(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 10 * pow10(n - 1)
  }
}
