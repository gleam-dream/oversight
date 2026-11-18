//// The live Grind queue as a Lustre component. It owns the queue simulation,
//// ticks it every 220 ms of animation frames and redraws only itself.
////
//// The page owns the reader's setting (what happens when a lease expires)
//// and one-off commands: reset, six more jobs, advance some ticks, kill a
//// worker. They arrive as one ordered command list with increasing ids, so
//// the widget applies each exactly once and in the order the page issued
//// them, even when a tour issues several in one update.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute.{attribute, class}
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import pages/durable_work/job.{
  type Abandonment, HoldUncertain, ReplayAfterLeaseExpiry,
}
import pages/durable_work/queue.{
  type Queue, type Row, Alive, Available, Dead, Done, HeldUncertain, RetryLater,
  Running, Worker,
}
import site/live
import site/motion.{type Motion}
import site/ui.{css}

pub const tag = "gd-grind-queue"

// COMMANDS --------------------------------------------------------------------

pub type Command {
  Reset
  AddJobs
  Advance(ticks: Int)
  Kill(worker: Int)
  Expire(Abandonment)
}

/// Apply one command to the simulation.
pub fn apply(queue: Queue, command: Command) -> Queue {
  case command {
    Reset -> queue.new()
    AddJobs -> queue.add_jobs(queue)
    Advance(ticks) -> queue.advance(queue, ticks)
    Kill(worker) -> queue.kill_worker(queue, worker)
    Expire(expiry) -> queue.set_expiry(queue, expiry)
  }
}

/// The page's side of the widget: the current setting and the latest
/// commands, numbered.
pub type Controls {
  Controls(expiry: Abandonment, commands: List(#(Int, Command)), next: Int)
}

pub fn controls() -> Controls {
  Controls(expiry: HoldUncertain, commands: [], next: 1)
}

/// The page keeps the latest commands only; the widget reads them within a
/// render, long before this many pile up.
const kept = 32

pub fn issue(controls: Controls, command: Command) -> Controls {
  let expiry = case command {
    Reset -> HoldUncertain
    Expire(expiry) -> expiry
    _ -> controls.expiry
  }
  let commands = list.append(controls.commands, [#(controls.next, command)])
  let commands = list.drop(commands, int.max(0, list.length(commands) - kept))
  Controls(expiry:, commands:, next: controls.next + 1)
}

pub fn encode(controls: Controls) -> String {
  expiry_code(controls.expiry)
  <> "|"
  <> string.join(
    list.map(controls.commands, fn(entry) {
      int.to_string(entry.0) <> "=" <> command_code(entry.1)
    }),
    ";",
  )
}

fn expiry_code(expiry: Abandonment) -> String {
  case expiry {
    HoldUncertain -> "hold"
    ReplayAfterLeaseExpiry -> "replay"
  }
}

fn command_code(command: Command) -> String {
  case command {
    Reset -> "reset"
    AddJobs -> "add"
    Advance(ticks) -> "tick:" <> int.to_string(ticks)
    Kill(worker) -> "kill:" <> int.to_string(worker)
    Expire(expiry) -> expiry_code(expiry)
  }
}

pub fn decode(
  text: String,
) -> Result(#(Abandonment, List(#(Int, Command))), Nil) {
  case string.split_once(text, "|") {
    Error(Nil) -> Error(Nil)
    Ok(#(expiry, rest)) -> {
      use expiry <- result.try(decode_expiry(expiry))
      let entries = case rest {
        "" -> Ok([])
        _ -> list.try_map(string.split(rest, ";"), decode_entry)
      }
      use entries <- result.try(entries)
      Ok(#(expiry, entries))
    }
  }
}

fn decode_expiry(code: String) -> Result(Abandonment, Nil) {
  case code {
    "hold" -> Ok(HoldUncertain)
    "replay" -> Ok(ReplayAfterLeaseExpiry)
    _ -> Error(Nil)
  }
}

fn decode_entry(entry: String) -> Result(#(Int, Command), Nil) {
  use #(id, code) <- result.try(string.split_once(entry, "="))
  use id <- result.try(int.parse(id))
  use command <- result.try(case code {
    "reset" -> Ok(Reset)
    "add" -> Ok(AddJobs)
    "hold" | "replay" -> decode_expiry(code) |> result.map(Expire)
    _ ->
      case string.split_once(code, ":") {
        Ok(#("tick", n)) -> int.parse(n) |> result.map(Advance)
        Ok(#("kill", n)) -> int.parse(n) |> result.map(Kill)
        _ -> Error(Nil)
      }
  })
  Ok(#(id, command))
}

/// Apply the commands the widget has not seen yet. The first list a widget
/// sees only sets its baseline: those commands happened before it existed.
pub fn catch_up(
  queue: Queue,
  seen: Option(Int),
  expiry: Abandonment,
  commands: List(#(Int, Command)),
) -> #(Queue, Option(Int)) {
  let newest =
    list.fold(commands, option.unwrap(seen, 0), fn(top, entry) {
      int.max(top, entry.0)
    })
  let queue = case seen {
    None -> queue
    Some(previous) ->
      commands
      |> list.filter(fn(entry) { entry.0 > previous })
      |> list.fold(queue, fn(queue, entry) { apply(queue, entry.1) })
  }
  #(queue.set_expiry(queue, expiry), Some(newest))
}

// THE PAGE'S VIEW OF THE WIDGET -----------------------------------------------

/// The host element the page renders where the queue goes.
pub fn element(
  controls: Controls,
  motion: Motion,
  touring: Bool,
) -> Element(msg) {
  element.element(
    tag,
    [
      attribute("data-live", "lease"),
      class("live"),
      live.motion_attribute(motion),
      attribute("commands", encode(controls)),
      // Inherited into the shadow tree: the queue is inert while touring.
      css(case touring {
        True -> "display:block;pointer-events:none"
        False -> "display:block"
      }),
    ],
    [],
  )
}

// COMPONENT -------------------------------------------------------------------

type Presence {
  Detached
  Attached
  Subscribing
  Ticking(handle: Int)
}

pub opaque type Model {
  Model(
    queue: Queue,
    motion: Motion,
    presence: Presence,
    carry: Float,
    seen: Option(Int),
  )
}

pub opaque type Msg {
  Connected
  Disconnected
  MotionChanged(Motion)
  CommandsChanged(String)
  Subscribed(Int)
  Frame(Float)
  ReaderToggledWorker(Int)
}

pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
    live.on_motion(MotionChanged),
    component.on_attribute_change("commands", fn(value) {
      Ok(CommandsChanged(value))
    }),
  ])
  |> lustre.register(tag)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(
      queue: queue.new(),
      motion: motion.Off,
      presence: Detached,
      carry: 0.0,
      seen: None,
    ),
    effect.none(),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    Connected -> start(Model(..model, presence: Attached))
    Disconnected -> stop(Model(..model, presence: Detached))
    MotionChanged(motion) -> {
      let model = Model(..model, motion:)
      case motion {
        motion.On -> start(model)
        motion.Off -> stop(model)
      }
    }
    Subscribed(handle) ->
      case model.presence, model.motion {
        Subscribing, motion.On -> #(
          Model(..model, presence: Ticking(handle)),
          effect.none(),
        )
        Subscribing, motion.Off -> #(
          Model(..model, presence: Attached),
          live.unsubscribe(live.Subscribed(handle)),
        )
        _, _ -> #(model, live.unsubscribe(live.Subscribed(handle)))
      }
    Frame(dt) -> {
      let carry = model.carry +. dt
      let ticks = float.truncate(carry /. queue.tick_seconds)
      let carry = carry -. int.to_float(ticks) *. queue.tick_seconds
      #(
        Model(..model, carry:, queue: queue.advance(model.queue, ticks)),
        effect.none(),
      )
    }
    CommandsChanged(text) ->
      case decode(text) {
        Error(Nil) -> #(model, effect.none())
        Ok(#(expiry, commands)) -> {
          let #(queue, seen) =
            catch_up(model.queue, model.seen, expiry, commands)
          #(Model(..model, queue:, seen:), effect.none())
        }
      }
    ReaderToggledWorker(index) -> #(
      Model(..model, queue: queue.toggle_worker(model.queue, index)),
      effect.none(),
    )
  }
}

fn start(model: Model) -> #(Model, Effect(Msg)) {
  case model.presence, model.motion {
    Attached, motion.On -> #(
      Model(..model, presence: Subscribing),
      live.subscribe(Frame, Subscribed),
    )
    _, _ -> #(model, effect.none())
  }
}

fn stop(model: Model) -> #(Model, Effect(Msg)) {
  let presence = case model.presence {
    Ticking(_) -> Attached
    other -> other
  }
  let effect = case model.presence {
    Ticking(handle) -> live.unsubscribe(live.Subscribed(handle))
    _ -> effect.none()
  }
  #(Model(..model, presence:, carry: 0.0), effect)
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Msg) {
  let q = model.queue
  let moving = motion.is_on(model.motion)
  html.div([], [
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px",
        ),
      ],
      list.append(
        list.index_map(q.workers, fn(w, i) { worker_card(q, w, i, moving) }),
        [
          renewer(q, moving),
        ],
      ),
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:8px;margin-top:16px",
        ),
      ],
      list.map(q.rows, row_card(q, _, moving)),
    ),
    html.div([class("split"), css("margin-top:14px;align-items:flex-start")], [
      html.div(
        [
          css(
            "display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;flex:1 1 360px",
          ),
        ],
        [
          counter("succeeded", q.done, "font-size:22px"),
          counter("uncertain", q.uncertain, "font-size:22px;color:#5C4300"),
          counter("replayed", q.replays, "font-size:22px"),
        ],
      ),
      html.div(
        [
          class("log"),
          css("flex:2 1 380px;min-height:0;max-height:150px;overflow:hidden"),
        ],
        list.map(q.log, fn(line) { html.div([class("l")], [html.text(line)]) }),
      ),
    ]),
  ])
}

fn counter(label: String, value: Int, style: String) -> Element(Msg) {
  html.div([class("box")], [
    html.div([class("meta")], [html.text(label)]),
    html.b([css(style)], [html.text(int.to_string(value))]),
  ])
}

fn transition(moving: Bool) -> String {
  case moving {
    True -> ";transition:width .22s linear"
    False -> ""
  }
}

fn percent(part: Int, whole: Int) -> String {
  case whole {
    0 -> "0"
    _ ->
      int.to_string(float.round(
        int.to_float(part) /. int.to_float(whole) *. 100.0,
      ))
  }
}

fn worker_card(
  q: Queue,
  worker: queue.Worker,
  index: Int,
  moving: Bool,
) -> Element(Msg) {
  let name = queue.name(index)
  let Worker(life:, job:) = worker
  let progress = case job {
    Some(id) ->
      case queue.row(q, id) {
        Some(queue.Row(state: Running(work:, work0:, ..), ..)) ->
          percent(work0 - work, work0)
        _ -> "0"
      }
    None -> "0"
  }
  let #(status, doing) = case life, job {
    Dead, Some(id) -> #(
      "dead",
      "Crashed holding job "
        <> int.to_string(id)
        <> ". Nobody renews that lease now.",
    )
    Dead, None -> #("dead", "Crashed.")
    Alive, Some(id) -> #("working", "Running job " <> int.to_string(id))
    Alive, None -> #("idle", "Waiting for work")
  }
  let #(sbg, sfg, bg, border, button, button_class) = case life {
    Alive -> #(
      "#E2F4E7",
      "#0E4D25",
      "#FFFFFF",
      "#E4E0D8",
      "Kill " <> name,
      "btn sm warn",
    )
    Dead -> #(
      "#FDECEA",
      "#7A1A12",
      "#FBF3F2",
      "#E9B8B2",
      "Restart " <> name,
      "btn sm",
    )
  }
  html.div(
    [
      css(
        "border-radius:14px;padding:14px;border:2px solid "
        <> border
        <> ";background:"
        <> bg
        <> ";display:flex;flex-direction:column;gap:6px",
      ),
    ],
    [
      html.div([class("row"), css("justify-content:space-between")], [
        html.b([class("mono")], [html.text(name)]),
        html.span(
          [class("chip"), css("background:" <> sbg <> ";color:" <> sfg)],
          [
            html.text(status),
          ],
        ),
      ]),
      html.span([css("font-size:14px")], [html.text(doing)]),
      html.div(
        [css("height:6px;border-radius:9px;background:#EDEFF3;overflow:hidden")],
        [
          html.div(
            [
              css(
                "height:6px;width:"
                <> progress
                <> "%;background:#1D4ED8"
                <> transition(moving),
              ),
            ],
            [],
          ),
        ],
      ),
      html.button(
        [
          attribute.type_("button"),
          class(button_class),
          event.on_click(ReaderToggledWorker(index)),
        ],
        [html.text(button)],
      ),
    ],
  )
}

fn renewer(q: Queue, moving: Bool) -> Element(Msg) {
  html.div(
    [
      css(
        "border-radius:14px;padding:14px;border:2px solid #E4E0D8;background:#FFFFFF;display:flex;flex-direction:column;gap:6px",
      ),
    ],
    [
      html.div([class("row"), css("justify-content:space-between")], [
        html.b([class("mono")], [html.text("renewer")]),
        html.span(
          [
            class(case moving {
              True -> "pulse"
              False -> ""
            }),
            css("color:#B0186E;font-weight:700"),
          ],
          [html.text("♥")],
        ),
      ]),
      html.span([css("font-size:14px")], [
        html.text(
          "Own database connection. Every second it extends the leases of live workers.",
        ),
      ]),
      html.span([class("meta")], [
        html.text(int.to_string(q.renewals) <> " renewals"),
      ]),
    ],
  )
}

fn row_card(q: Queue, row: Row, moving: Bool) -> Element(Msg) {
  let dead = queue.draining(q, row)
  let #(bg, fg, border) = case row.state {
    Available -> #("#FFFFFF", "#17162B", "#E4E0D8")
    Running(..) -> #("#E0E9FD", "#163A8A", "#B8CBF7")
    Done -> #("#E2F4E7", "#0E4D25", "#B9E2C4")
    HeldUncertain -> #("#FFF1C2", "#5C4300", "#E0B000")
    RetryLater(..) -> #("#FDF0DC", "#6B3404", "#F3D9B1")
  }
  let border = case dead {
    True -> "#B42318"
    False -> border
  }
  let label = case row.state, dead {
    Running(..), True -> "owner dead · lease draining"
    Running(..), False -> "running · attempt " <> int.to_string(row.attempts)
    Done, _ -> "succeeded"
    HeldUncertain, _ -> "Uncertain: held"
    RetryLater(..), _ -> "retry soon"
    Available, _ -> "available"
  }
  let #(owner, lease) = case row.state {
    Running(owner:, lease:, ..) -> #(
      queue.name(owner),
      percent(lease, queue.lease_ticks),
    )
    _ -> #("", "0")
  }
  let lease_colour = case dead {
    True -> "#B42318"
    False -> "#1D4ED8"
  }
  html.div(
    [
      css(
        "border-radius:10px;padding:8px 10px;background:"
        <> bg
        <> ";color:"
        <> fg
        <> ";border:2px solid "
        <> border
        <> ";min-height:74px;display:flex;flex-direction:column;gap:3px",
      ),
    ],
    [
      html.div([class("row"), css("justify-content:space-between;gap:4px")], [
        html.b([class("mono"), css("font-size:12px")], [
          html.text("job " <> int.to_string(row.id)),
        ]),
        html.span([class("mono"), css("font-size:11px")], [html.text(owner)]),
      ]),
      html.span([css("font-size:12px")], [html.text(label)]),
      html.div(
        [
          css(
            "height:5px;border-radius:9px;background:rgba(0,0,0,.08);overflow:hidden",
          ),
        ],
        [
          html.div(
            [
              css(
                "height:5px;width:"
                <> lease
                <> "%;background:"
                <> lease_colour
                <> transition(moving),
              ),
            ],
            [],
          ),
        ],
      ),
    ],
  )
}
