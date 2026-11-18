//// The real-time "send or call" widget: a Lustre component that owns the
//// mailbox simulation and redraws only its own SVG on every frame.
////
//// The page passes the reader's settings as attributes (`mode`, `rate`,
//// `paused`, `motion`) and one-off commands as one `commands` attribute:
//// a reset counter, an advance counter and the mode and rate the latest
//// advance ran under. Keeping the commands in one attribute means a reset
//// and an advance sent in the same render run in that order.

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
import pages/otp/mailbox.{
  type Mode, type Sim, type Token, Call, Done, Flying, Queued, Replying, Send,
  Working,
}
import site/live
import site/motion.{type Motion}

pub const tag = "gd-mailbox"

pub fn register() -> Result(Nil, lustre.Error) {
  lustre.register(
    lustre.component(init, update, view, [
      component.on_connect(Connected),
      component.on_disconnect(Disconnected),
      live.on_motion(MotionChanged),
      component.on_attribute_change("mode", fn(value) {
        decode_mode(value) |> option.to_result(Nil) |> result.map(ModeChanged)
      }),
      live.on_int("rate", RateChanged),
      live.on_bool("paused", PausedChanged),
      component.on_attribute_change("commands", fn(value) {
        decode_commands(value)
        |> option.to_result(Nil)
        |> result.map(CommandsChanged)
      }),
    ]),
    tag,
  )
}

// ATTRIBUTES ------------------------------------------------------------------

/// One-off commands from the page, as counters that only grow.
pub type Commands {
  Commands(resets: Int, advances: Int, advance_mode: Mode, advance_rate: Int)
}

pub fn encode_mode(mode: Mode) -> String {
  case mode {
    Send -> "send"
    Call -> "call"
  }
}

pub fn decode_mode(value: String) -> Option(Mode) {
  case value {
    "send" -> Some(Send)
    "call" -> Some(Call)
    _ -> None
  }
}

pub fn encode_commands(commands: Commands) -> String {
  string.join(
    [
      int.to_string(commands.resets),
      int.to_string(commands.advances),
      encode_mode(commands.advance_mode),
      int.to_string(commands.advance_rate),
    ],
    " ",
  )
}

pub fn decode_commands(value: String) -> Option(Commands) {
  case string.split(value, " ") {
    [resets, advances, mode, rate] ->
      case
        int.parse(resets),
        int.parse(advances),
        decode_mode(mode),
        int.parse(rate)
      {
        Ok(resets), Ok(advances), Some(mode), Ok(rate) ->
          Some(Commands(
            resets:,
            advances:,
            advance_mode: mode,
            advance_rate: rate,
          ))
        _, _, _, _ -> None
      }
    _ -> None
  }
}

/// The attributes the page puts on the widget's element.
pub fn attributes(
  mode: Mode,
  rate: Int,
  paused: Bool,
  motion: Motion,
  commands: Commands,
) -> List(Attribute(msg)) {
  [
    attribute("mode", encode_mode(mode)),
    attribute("rate", int.to_string(rate)),
    live.bool_attribute("paused", paused),
    live.motion_attribute(motion),
    attribute("commands", encode_commands(commands)),
  ]
}

// MODEL -----------------------------------------------------------------------

/// The widget's place in the shared frame loop.
type Loop {
  Stopped
  Starting
  Running(handle: Int)
}

pub opaque type Model {
  Model(
    sim: Sim,
    mode: Mode,
    rate: Int,
    paused: Bool,
    motion: Motion,
    connected: Bool,
    loop: Loop,
    seen_resets: Option(Int),
    seen_advances: Option(Int),
  )
}

pub opaque type Msg {
  Connected
  Disconnected
  MotionChanged(Motion)
  ModeChanged(Mode)
  RateChanged(Int)
  PausedChanged(Bool)
  CommandsChanged(Commands)
  Subscribed(Int)
  Frame(Float)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(
      sim: mailbox.new(),
      mode: Send,
      rate: 6,
      paused: False,
      motion: motion.Off,
      connected: False,
      loop: Stopped,
      seen_resets: None,
      seen_advances: None,
    ),
    effect.none(),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Connected -> follow_frames(look(Model(..model, connected: True)))
    Disconnected -> follow_frames(Model(..model, connected: False))
    MotionChanged(motion) -> follow_frames(look(Model(..model, motion:)))
    ModeChanged(mode) -> #(look(Model(..model, mode:)), effect.none())
    RateChanged(rate) -> #(look(Model(..model, rate:)), effect.none())
    PausedChanged(paused) -> #(look(Model(..model, paused:)), effect.none())
    CommandsChanged(commands) -> #(run(model, commands), effect.none())
    Subscribed(handle) ->
      case model.loop {
        Starting -> #(Model(..model, loop: Running(handle)), effect.none())
        // Frames are no longer wanted, or a subscription already runs.
        _ -> #(model, live.unsubscribe(live.Subscribed(handle)))
      }
    Frame(dt) -> {
      let sim = case model.paused {
        True -> model.sim
        False -> mailbox.step(model.sim, dt, model.mode, model.rate)
      }
      #(Model(..model, sim: mailbox.settle(sim)), effect.none())
    }
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
    False, Running(handle) -> #(
      Model(..model, loop: Stopped),
      live.unsubscribe(live.Subscribed(handle)),
    )
    False, Starting -> #(Model(..model, loop: Stopped), effect.none())
    _, _ -> #(model, effect.none())
  }
}

/// Without motion the widget is redrawn only when the page changes it, and
/// each redraw takes a zero-length step, as the reference's static draw
/// does: a message due at this very instant goes out, and the queue settles.
fn look(model: Model) -> Model {
  case model.motion, model.paused {
    motion.Off, False ->
      Model(
        ..model,
        sim: mailbox.step(model.sim, 0.0, model.mode, model.rate)
          |> mailbox.settle,
      )
    _, _ -> model
  }
}

fn run(model: Model, commands: Commands) -> Model {
  let #(reset, seen_resets) = live.is_new(model.seen_resets, commands.resets)
  let advances = case model.seen_advances {
    Some(previous) -> int.max(0, commands.advances - previous)
    None -> 0
  }
  let #(_, seen_advances) = live.is_new(model.seen_advances, commands.advances)
  let sim = case reset {
    True -> mailbox.new()
    False -> model.sim
  }
  let sim =
    list.fold(list.repeat(Nil, advances), sim, fn(sim, _) {
      mailbox.advance_second(sim, commands.advance_mode, commands.advance_rate)
    })
  let model = Model(..model, sim:, seen_resets:, seen_advances:)
  case reset {
    True -> look(model)
    False -> model
  }
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  let sim = model.sim
  let call = model.mode == Call
  let blocked = mailbox.blocked(sim)
  let waiting = mailbox.waiting(sim)
  let lane_opacity = case call {
    True -> "1"
    False -> "0.15"
  }
  svg.svg(
    [
      attribute("viewBox", "0 0 860 236"),
      attribute("width", "100%"),
      attribute.role("img"),
      attribute.aria_label(
        "Animation of messages flowing from four request processes into an actor mailbox",
      ),
      attribute.style("display", "block"),
      attribute.style("max-width", "860px"),
      attribute.style("margin", "0 auto"),
      attribute.style("font-family", "Inter, system-ui, sans-serif"),
    ],
    [
      rect(20, 40, 150, 130, 14, "#F6F4FF", "#DCD9FF"),
      label(95, 64, "middle", 13, "600", "#17162B", "4 request processes"),
      element.fragment(
        list.index_map(blocked, fn(blocked, i) {
          svg.circle([
            attribute("cx", int.to_string(50 + i * 30)),
            attribute("cy", "96"),
            attribute("r", "10"),
            attribute("fill", case call && blocked {
              True -> "#7C4DCC"
              False -> "#FFFFFF"
            }),
            attribute("stroke", "#7C4DCC"),
            attribute("stroke-width", "2"),
          ])
        }),
      ),
      label(
        95,
        140,
        "middle",
        11,
        "",
        "#5B5970",
        case call, list.all(blocked, fn(b) { b }) {
          True, True -> "all 4 waiting for replies"
          True, False -> "calling, then waiting"
          False, _ -> "sending, never waiting"
        },
      ),
      dashed_line(172, 96, 420, "#D5D1C8", "1"),
      label(290, 84, "middle", 11, "", "#8A8698", "messages →"),
      dashed_line(172, 134, 640, "#B9E2C4", lane_opacity),
      svg.text(
        [
          attribute("x", "400"),
          attribute("y", "152"),
          attribute("text-anchor", "middle"),
          attribute("font-size", "11"),
          attribute("fill", "#15803D"),
          attribute("opacity", lane_opacity),
        ],
        "← replies",
      ),
      rect(420, 78, 214, 36, 8, "#FFFFFF", "#DCD9FF"),
      label(420, 70, "", 11, "", "#5B5970", "mailbox"),
      label(634, 70, "end", 11, "700", "#B42318", case waiting > 11 {
        True -> "+" <> int.to_string(waiting - 11) <> " more waiting"
        False -> ""
      }),
      rect(650, 40, 190, 130, 14, "#FDF0DC", "#F3D9B1"),
      label(745, 64, "middle", 13, "600", "#17162B", "actor · 4 per second"),
      bar(680, 122, "130", 8, 4, "#F3D9B1"),
      bar(680, 122, progress(sim), 8, 4, "#B45309"),
      bar(
        420,
        180,
        fixed(float.min(420.0, int.to_float(waiting * 3)), 1),
        10,
        5,
        case waiting > 20 {
          True -> "#B42318"
          False -> "#E0B000"
        },
      ),
      label(
        420,
        208,
        "",
        11,
        "",
        "#5B5970",
        "mailbox memory · "
          <> int.to_string(waiting)
          <> " message"
          <> case waiting == 1 {
          True -> ""
          False -> "s"
        }
          <> case waiting > 20 {
          True -> " and climbing: no limit"
          False -> ""
        },
      ),
      label(
        20,
        208,
        "",
        12,
        "600",
        "#17162B",
        "sent "
          <> int.to_string(sim.sent)
          <> " · handled "
          <> int.to_string(sim.handled)
          <> " · waiting "
          <> int.to_string(waiting)
          <> " · oldest waited "
          <> fixed(mailbox.oldest_wait(sim), 1)
          <> " s",
      ),
      keyed.namespaced(
        "http://www.w3.org/2000/svg",
        "g",
        [],
        tokens(sim, waiting),
      ),
    ],
  )
}

fn progress(sim: Sim) -> String {
  case mailbox.busy(sim) {
    Some(mailbox.Token(state: Working(since), ..)) ->
      fixed(
        float.min(130.0, { sim.clock -. since } /. mailbox.service *. 130.0),
        1,
      )
    _ -> "0"
  }
}

fn tokens(sim: Sim, waiting: Int) -> List(#(String, Element(Msg))) {
  let target = float.min(mailbox.slot_x(int.min(waiting, 10)), 600.0)
  let #(_, drawn) =
    list.map_fold(sim.tokens, 0, fn(index, token) {
      case token.state {
        Queued(..) -> #(index + 1, token_at(sim, token, index, target))
        _ -> #(index, token_at(sim, token, index, target))
      }
    })
  list.filter_map(drawn, fn(drawn) { drawn })
}

fn token_at(
  sim: Sim,
  token: Token,
  queue_index: Int,
  target: Float,
) -> Result(#(String, Element(Msg)), Nil) {
  let home = int.to_float(50 + token.caller * 30)
  let along = fn(since) {
    float.min(1.0, { sim.clock -. since } /. mailbox.travel)
  }
  let placed = case token.state {
    Flying(since) ->
      Ok(#(home +. { target -. home } *. along(since), 96.0, "#7C4DCC", 1.0))
    Queued(shown_x:, ..) ->
      case queue_index > mailbox.visible_slots {
        True -> Error(Nil)
        False ->
          Ok(#(
            option.unwrap(shown_x, mailbox.slot_x(queue_index)),
            96.0,
            "#7C4DCC",
            1.0,
          ))
      }
    Working(_) -> Ok(#(745.0, 96.0, "#B45309", 1.0))
    Replying(since) ->
      Ok(#(745.0 -. { 745.0 -. home } *. along(since), 134.0, "#15803D", 1.0))
    Done(since) -> {
      let age = sim.clock -. since
      Ok(#(
        745.0,
        96.0 -. age *. 60.0,
        "#B45309",
        float.max(0.0, 1.0 -. age /. mailbox.fade),
      ))
    }
  }
  case placed {
    Error(Nil) -> Error(Nil)
    Ok(#(x, y, fill, opacity)) ->
      Ok(#(
        int.to_string(token.id),
        svg.circle([
          attribute("r", "7"),
          attribute("cx", fixed(x, 1)),
          attribute("cy", fixed(y, 1)),
          attribute("fill", fill),
          attribute("opacity", fixed(opacity, 2)),
        ]),
      ))
  }
}

fn rect(
  x: Int,
  y: Int,
  width: Int,
  height: Int,
  rx: Int,
  fill: String,
  stroke: String,
) -> Element(Msg) {
  svg.rect([
    attribute("x", int.to_string(x)),
    attribute("y", int.to_string(y)),
    attribute("width", int.to_string(width)),
    attribute("height", int.to_string(height)),
    attribute("rx", int.to_string(rx)),
    attribute("fill", fill),
    attribute("stroke", stroke),
  ])
}

fn bar(
  x: Int,
  y: Int,
  width: String,
  height: Int,
  rx: Int,
  fill: String,
) -> Element(Msg) {
  svg.rect([
    attribute("x", int.to_string(x)),
    attribute("y", int.to_string(y)),
    attribute("width", width),
    attribute("height", int.to_string(height)),
    attribute("rx", int.to_string(rx)),
    attribute("fill", fill),
  ])
}

fn dashed_line(
  x1: Int,
  y: Int,
  x2: Int,
  stroke: String,
  opacity: String,
) -> Element(Msg) {
  svg.line([
    attribute("x1", int.to_string(x1)),
    attribute("y1", int.to_string(y)),
    attribute("x2", int.to_string(x2)),
    attribute("y2", int.to_string(y)),
    attribute("stroke", stroke),
    attribute("stroke-width", "2"),
    attribute("stroke-dasharray", "4 5"),
    attribute("opacity", opacity),
  ])
}

fn label(
  x: Int,
  y: Int,
  anchor: String,
  size: Int,
  weight: String,
  fill: String,
  text: String,
) -> Element(Msg) {
  svg.text(
    [
      attribute("x", int.to_string(x)),
      attribute("y", int.to_string(y)),
      case anchor {
        "" -> attribute.none()
        _ -> attribute("text-anchor", anchor)
      },
      attribute("font-size", int.to_string(size)),
      case weight {
        "" -> attribute.none()
        _ -> attribute("font-weight", weight)
      },
      attribute("fill", fill),
    ],
    text,
  )
}

/// A non-negative number with a fixed count of decimals, like `toFixed`.
pub fn fixed(x: Float, digits: Int) -> String {
  let scale = int.product(list.repeat(10, digits))
  let scaled = float.round(float.absolute_value(x) *. int.to_float(scale))
  let sign = case x <. 0.0 && scaled > 0 {
    True -> "-"
    False -> ""
  }
  let whole = int.to_string(scaled / scale)
  case digits {
    0 -> sign <> whole
    _ ->
      sign
      <> whole
      <> "."
      <> string.pad_start(int.to_string(scaled % scale), digits, "0")
  }
}
