//// Guided tours. Every playground first explains itself step by step, then
//// unlocks for free play.
////
//// A tour is either guided, at a step and paused or playing, or free. Each
//// transition bumps the tour's epoch. A playing tour schedules its next
//// advance under the current epoch, so an advance scheduled before a pause,
//// a click or a reset is recognised as stale and ignored.
////
//// A step's action is the list of the page's own messages it sends, computed
//// from the page model when the step runs. Tours therefore drive a
//// playground through the same verbs as its buttons.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute.{type Attribute, attribute, class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import site/browser
import site/context.{type Context}
import site/motion.{type Motion}

// STATE -----------------------------------------------------------------------

pub type Playback {
  Paused
  Playing
}

pub type Phase {
  Guided(step: Int, playback: Playback)
  Free
}

pub opaque type Tour {
  Tour(phase: Phase, epoch: Int)
}

/// The tours of one page, keyed by the page's own tour identifiers.
pub opaque type Tours(id) {
  Tours(tours: Dict(id, Tour))
}

const start = Tour(phase: Guided(step: 0, playback: Paused), epoch: 0)

pub fn new() -> Tours(id) {
  Tours(dict.new())
}

pub fn get(tours: Tours(id), id: id) -> Tour {
  case dict.get(tours.tours, id) {
    Ok(tour) -> tour
    Error(Nil) -> start
  }
}

pub fn phase(tour: Tour) -> Phase {
  tour.phase
}

pub fn epoch(tour: Tour) -> Int {
  tour.epoch
}

pub fn is_touring(tour: Tour) -> Bool {
  case tour.phase {
    Guided(..) -> True
    Free -> False
  }
}

fn put(tours: Tours(id), id: id, tour: Tour) -> Tours(id) {
  Tours(dict.insert(tours.tours, id, tour))
}

/// Pause every playing tour: the reader left the page or turned motion off.
pub fn pause_all(tours: Tours(id)) -> Tours(id) {
  Tours(
    dict.map_values(tours.tours, fn(_, tour) {
      case tour.phase {
        Guided(step:, playback: Playing) ->
          Tour(phase: Guided(step:, playback: Paused), epoch: tour.epoch + 1)
        _ -> tour
      }
    }),
  )
}

// SCRIPTS ---------------------------------------------------------------------

/// How long a step plays before the next one, unless the step says otherwise.
pub const default_ms = 3600

pub type Action(model, msg) {
  /// The step only narrates what is already on screen.
  Narrate
  /// The step sends these page messages, computed from the page model.
  Send(fn(model) -> List(msg))
}

pub type Step(model, msg) {
  Step(text: String, action: Action(model, msg), ms: Int)
}

pub type Script(model, msg) {
  Script(reset: fn(model) -> List(msg), steps: List(Step(model, msg)))
}

pub fn say(text: String) -> Step(model, msg) {
  Step(text:, action: Narrate, ms: default_ms)
}

pub fn act(text: String, action: fn(model) -> List(msg)) -> Step(model, msg) {
  Step(text:, action: Send(action), ms: default_ms)
}

/// Give a step its own playing time in milliseconds.
pub fn lasting(step: Step(model, msg), ms: Int) -> Step(model, msg) {
  Step(..step, ms:)
}

// TRANSITIONS -----------------------------------------------------------------

pub type Command {
  Next
  Back
  Play
  Pause
  Skip
  Replay
  /// A scheduled advance while playing, valid only for the epoch it names.
  Advance(epoch: Int)
}

/// Which step actions a transition runs against the page.
pub type Run {
  RunNothing
  RunStep(Int)
  /// Reset the playground, then run these steps in order.
  ResetThen(List(Int))
}

/// The outcome of a command, as data: the next tour, the actions to run, the
/// advance to schedule and whether to bring the card into view.
pub type Plan {
  Plan(tour: Tour, run: Run, schedule: Option(Int), bring_into_view: Bool)
}

/// The pure transition of one tour. `steps` lists each step's
/// `#(has_action, ms)`.
pub fn plan(
  tour: Tour,
  command: Command,
  steps: List(#(Bool, Int)),
  motion: Motion,
) -> Plan {
  let last = list.length(steps) - 1
  let ignore =
    Plan(tour:, run: RunNothing, schedule: None, bring_into_view: False)
  let to = fn(phase) { Tour(phase:, epoch: tour.epoch + 1) }
  case tour.phase, command {
    Free, Replay -> Plan(to(Guided(0, Paused)), ResetThen([0]), None, True)
    Free, _ -> ignore

    Guided(step:, ..), Next if step >= last ->
      Plan(to(Free), RunNothing, None, True)
    Guided(step:, ..), Next ->
      Plan(to(Guided(step + 1, Paused)), RunStep(step + 1), None, True)

    Guided(step: 0, ..), Back -> ignore
    Guided(step:, ..), Back ->
      Plan(
        to(Guided(step - 1, Paused)),
        ResetThen(between(1, step - 1)),
        None,
        True,
      )

    Guided(playback: Playing, ..), Play -> ignore
    Guided(..), Play if motion == motion.Off -> ignore
    Guided(step: 0, ..), Play ->
      case steps {
        [#(False, _), #(_, ms), ..] ->
          Plan(to(Guided(1, Playing)), RunStep(1), Some(ms), True)
        [#(_, ms), ..] ->
          Plan(to(Guided(0, Playing)), RunNothing, Some(ms), True)
        [] -> ignore
      }
    Guided(step:, ..), Play ->
      Plan(
        to(Guided(step, Playing)),
        RunNothing,
        Some(ms_at(steps, step)),
        True,
      )

    Guided(step:, playback: Playing), Pause ->
      Plan(to(Guided(step, Paused)), RunNothing, None, False)
    Guided(..), Pause -> ignore

    Guided(..), Skip -> Plan(to(Free), RunNothing, None, False)

    Guided(..), Replay ->
      Plan(to(Guided(0, Paused)), ResetThen([0]), None, True)

    Guided(step:, playback: Playing), Advance(epoch) if epoch == tour.epoch ->
      case step >= last {
        True -> Plan(to(Guided(step, Paused)), RunNothing, None, False)
        False ->
          Plan(
            to(Guided(step + 1, Playing)),
            RunStep(step + 1),
            Some(ms_at(steps, step + 1)),
            False,
          )
      }
    Guided(..), Advance(_) -> ignore
  }
}

/// The integers from `low` to `high` inclusive; empty when `high < low`.
fn between(low: Int, high: Int) -> List(Int) {
  case low > high {
    True -> []
    False -> [low, ..between(low + 1, high)]
  }
}

fn ms_at(steps: List(#(Bool, Int)), index: Int) -> Int {
  case list.drop(steps, index) {
    [#(_, ms), ..] -> ms
    [] -> default_ms
  }
}

// DRIVER ----------------------------------------------------------------------

/// Everything the engine needs to drive one page's tours.
pub type Driver(id, model, msg) {
  Driver(
    script: fn(id) -> Script(model, msg),
    key: fn(id) -> String,
    tours: fn(model) -> Tours(id),
    set_tours: fn(model, Tours(id)) -> model,
    run: fn(model, msg) -> #(model, Effect(msg)),
    to_msg: fn(id, Command) -> msg,
  )
}

/// Apply a command to one tour of a page and run whatever it implies.
pub fn update(
  driver: Driver(id, model, msg),
  model: model,
  id: id,
  command: Command,
  motion: Motion,
) -> #(model, Effect(msg)) {
  let script = driver.script(id)
  let shape =
    list.map(script.steps, fn(step) {
      case step.action {
        Narrate -> #(False, step.ms)
        Send(_) -> #(True, step.ms)
      }
    })
  let tour = get(driver.tours(model), id)
  let plan = plan(tour, command, shape, motion)
  let model = driver.set_tours(model, put(driver.tours(model), id, plan.tour))
  let #(model, effects) = case plan.run {
    RunNothing -> #(model, [])
    RunStep(index) -> run_step(driver, script, model, index, [])
    ResetThen(indices) -> {
      let #(model, effects) = send(driver, model, script.reset(model), [])
      list.fold(indices, #(model, effects), fn(acc, index) {
        run_step(driver, script, acc.0, index, acc.1)
      })
    }
  }
  let effects = case plan.schedule {
    Some(ms) -> [
      browser.after(ms, driver.to_msg(id, Advance(plan.tour.epoch))),
      ..effects
    ]
    None -> effects
  }
  let effects = case plan.bring_into_view {
    True -> [
      browser.bring_under_app_bar(driver.key(id), motion.is_on(motion)),
      ..effects
    ]
    False -> effects
  }
  #(model, effect.batch(effects))
}

fn run_step(
  driver: Driver(id, model, msg),
  script: Script(model, msg),
  model: model,
  index: Int,
  effects: List(Effect(msg)),
) -> #(model, List(Effect(msg))) {
  case list.drop(script.steps, index) {
    [Step(action: Send(action), ..), ..] ->
      send(driver, model, action(model), effects)
    _ -> #(model, effects)
  }
}

fn send(
  driver: Driver(id, model, msg),
  model: model,
  msgs: List(msg),
  effects: List(Effect(msg)),
) -> #(model, List(Effect(msg))) {
  list.fold(msgs, #(model, effects), fn(acc, msg) {
    let #(model, effect) = driver.run(acc.0, msg)
    #(model, [effect, ..acc.1])
  })
}

// VIEW ------------------------------------------------------------------------

/// A playground card. While it tours, it carries the tour bar, is scaled to
/// fit the screen and its controls are inert; afterwards it offers a replay.
pub fn lab(
  tours: Tours(id),
  id: id,
  driver: Driver(id, model, msg),
  context: Context,
  attributes: List(Attribute(msg)),
  children: List(Element(msg)),
) -> Element(msg) {
  let tour = get(tours, id)
  let key = driver.key(id)
  let to_msg = fn(command) { driver.to_msg(id, command) }
  let script = driver.script(id)
  let zoom = case is_touring(tour) {
    True -> context.zoom(context, key)
    False -> 100
  }
  let zoom_attribute = case zoom < 100 {
    True -> attribute("data-rt-z", int.to_string(zoom))
    False -> attribute.none()
  }
  html.div(
    [
      class("lab"),
      attribute.classes([#("touring", is_touring(tour))]),
      attribute("data-tid", key),
      zoom_attribute,
      ..attributes
    ],
    [
      bar(tour, script, context.motion, to_msg),
      html.div(
        [
          class("lab-body"),
          case is_touring(tour) {
            True -> attribute("inert", "")
            False -> attribute.none()
          },
        ],
        children,
      ),
    ],
  )
}

/// The dark guided-tour bar, or the light free-play bar.
pub fn bar(
  tour: Tour,
  script: Script(model, msg),
  motion: Motion,
  to_msg: fn(Command) -> msg,
) -> Element(msg) {
  case tour.phase {
    Free ->
      html.div(
        [
          class("tourbar freebar row"),
          attribute.style("gap", "12px"),
          attribute.style("justify-content", "space-between"),
        ],
        [
          html.span([attribute.style("font-size", "14px")], [
            html.b([], [html.text("Free play.")]),
            html.text(" Everything is unlocked: try your own experiments."),
          ]),
          html.button(
            [
              attribute.type_("button"),
              class("btn sm tb"),
              event.on_click(to_msg(Replay)),
            ],
            [html.text("Replay the guided tour")],
          ),
        ],
      )
    Guided(step:, playback:) ->
      guided_bar(step, playback, script, motion, to_msg)
  }
}

fn guided_bar(
  step: Int,
  playback: Playback,
  script: Script(model, msg),
  motion: Motion,
  to_msg: fn(Command) -> msg,
) -> Element(msg) {
  let total = list.length(script.steps)
  let text = case list.drop(script.steps, step) {
    [current, ..] -> current.text
    [] -> ""
  }
  let playing = playback == Playing
  let play_button = case motion {
    motion.On ->
      html.button(
        [
          attribute.type_("button"),
          class("tbi tb"),
          event.on_click(
            to_msg(case playing {
              True -> Pause
              False -> Play
            }),
          ),
          attribute.aria_label(case playing {
            True -> "Pause"
            False -> "Play"
          }),
        ],
        [
          case playing {
            True -> pause_icon()
            False -> play_icon()
          },
        ],
      )
    motion.Off -> element.none()
  }
  html.div(
    [
      class("tourbar"),
      attribute.role("region"),
      attribute.aria_label("Guided tour"),
    ],
    [
      html.div([class("tb-top")], [
        html.span([class("tourn")], [
          html.text(int.to_string(step + 1) <> "/" <> int.to_string(total)),
        ]),
        html.p([class("tourtext"), attribute("aria-live", "polite")], [
          html.text(text),
        ]),
        html.div([class("tb-ctl")], [
          html.button(
            [
              attribute.type_("button"),
              class("tbi tb"),
              event.on_click(to_msg(Back)),
              attribute.disabled(step == 0),
              attribute.aria_label("Previous step"),
            ],
            [back_icon()],
          ),
          play_button,
          html.button(
            [
              attribute.type_("button"),
              class("tbn tb"),
              event.on_click(to_msg(Next)),
            ],
            [
              html.text(case step >= total - 1 {
                True -> "Finish and unlock"
                False -> "Next →"
              }),
            ],
          ),
        ]),
      ]),
      html.div([class("tb-foot")], [
        html.div(
          [class("tdots"), attribute("aria-hidden", "true")],
          list.index_map(script.steps, fn(s, k) {
            segment(k, s.ms, step, playing)
          }),
        ),
        html.button(
          [
            attribute.type_("button"),
            class("tblink tb"),
            event.on_click(to_msg(Skip)),
          ],
          [html.text("Skip tour · unlock controls")],
        ),
      ]),
    ],
  )
}

/// One progress segment. Earlier segments are full; the current one is full
/// while paused and fills over its step's duration while playing. Alternating
/// two identical keyframes restarts the fill on every step.
fn segment(index: Int, ms: Int, step: Int, playing: Bool) -> Element(msg) {
  let full = index < step || { index == step && !playing }
  let animation = case index == step && playing {
    True ->
      case step % 2 {
        1 -> "tfA "
        _ -> "tfB "
      }
      <> int.to_string(ms)
      <> "ms linear forwards"
    False -> "none"
  }
  html.span([], [
    html.i(
      [
        attribute.style("width", case full {
          True -> "100%"
          False -> "0%"
        }),
        attribute.style("animation", animation),
      ],
      [],
    ),
  ])
}

fn back_icon() -> Element(msg) {
  icon(16, [
    svg.path([
      attribute("d", "M10 3 L5 8 L10 13"),
      attribute("fill", "none"),
      attribute("stroke", "currentColor"),
      attribute("stroke-width", "2"),
      attribute("stroke-linecap", "round"),
      attribute("stroke-linejoin", "round"),
    ]),
  ])
}

fn play_icon() -> Element(msg) {
  icon(14, [
    svg.path([
      attribute("d", "M3 1.5 L12.5 7 L3 12.5 Z"),
      attribute("fill", "currentColor"),
    ]),
  ])
}

fn pause_icon() -> Element(msg) {
  icon(14, [
    svg.rect([
      attribute("x", "2.5"),
      attribute("y", "1.5"),
      attribute("width", "3.2"),
      attribute("height", "11"),
      attribute("rx", "1"),
      attribute("fill", "currentColor"),
    ]),
    svg.rect([
      attribute("x", "8.3"),
      attribute("y", "1.5"),
      attribute("width", "3.2"),
      attribute("height", "11"),
      attribute("rx", "1"),
      attribute("fill", "currentColor"),
    ]),
  ])
}

fn icon(size: Int, children: List(Element(msg))) -> Element(msg) {
  let size = int.to_string(size)
  svg.svg(
    [
      attribute("width", size),
      attribute("height", size),
      attribute("viewBox", "0 0 " <> size <> " " <> size),
      attribute("aria-hidden", "true"),
    ],
    children,
  )
}
