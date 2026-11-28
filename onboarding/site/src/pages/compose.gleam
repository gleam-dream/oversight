//// Module 10, the composition studio: ten Oversight applications step by
//// step, six composition patterns, a system builder with the nearest
//// example, and the durable checkout read as a telemetry trace.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set.{type Set}
import gleam/string
import lustre
import lustre/attribute.{attribute, class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import pages/compose/builder.{type Need}
import pages/compose/package.{type Actor, type Package, Uses}
import pages/compose/stepper.{type Stepper}
import pages/compose/systems.{type System}
import pages/compose/trace.{type Outcome}
import site/browser
import site/context.{type Context}
import site/msc
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  Systems
  Builder
  Trace
}

pub type Model {
  Model(
    /// The system being walked through, and where the walk is.
    system: System,
    walk: Stepper,
    /// What the reader's own system must do.
    needs: Set(Need),
    /// Which ending of the checkout the trace tells, and where the reader is.
    outcome: Outcome,
    trace: Stepper,
    tours: tour.Tours(TourId),
  )
}

pub type Msg {
  ReaderPickedSystem(System)
  ReaderSteppedBack
  ReaderSteppedForward
  ReaderPlayedSystem
  /// The next step of a played walk is due; valid only for its run.
  SystemStepDue(epoch: Int)
  ReaderToggledNeed(Need)
  ReaderClearedNeeds
  ReaderPickedOutcome(Outcome)
  ReaderSteppedTraceBack
  ReaderSteppedTraceForward
  ReaderScrubbedTrace(Int)
  ReaderPlayedTrace
  /// The next event of a played trace is due; valid only for its run.
  TraceEventDue(epoch: Int)
  Tour(TourId, tour.Command)
}

/// How long each step of a played walk shows.
const walk_ms = 1300

/// How long each event of a played trace shows.
const trace_ms = 800

const first_needs = [builder.BackgroundWork, builder.UndoableSteps]

pub fn init() -> Model {
  Model(
    system: systems.Checkout,
    walk: stepper.new(systems.step_count(systems.Checkout)),
    needs: set.from_list(first_needs),
    outcome: trace.Succeeds,
    trace: stepper.new(trace.length(trace.Succeeds)),
    tours: tour.new(),
  )
}

// UPDATE ----------------------------------------------------------------------

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  case msg {
    ReaderPickedSystem(system) -> #(
      Model(
        ..model,
        system:,
        walk: stepper.restart(model.walk, systems.step_count(system)),
      ),
      effect.none(),
    )
    ReaderSteppedBack -> #(
      Model(..model, walk: stepper.back(model.walk)),
      effect.none(),
    )
    ReaderSteppedForward -> #(
      Model(..model, walk: stepper.forward(model.walk)),
      effect.none(),
    )
    ReaderPlayedSystem -> {
      let walk = stepper.play(model.walk, context.motion)
      #(Model(..model, walk:), schedule(walk, walk_ms, SystemStepDue))
    }
    SystemStepDue(epoch) ->
      case stepper.tick(model.walk, epoch) {
        Ok(walk) -> #(
          Model(..model, walk:),
          schedule(walk, walk_ms, SystemStepDue),
        )
        Error(Nil) -> #(model, effect.none())
      }

    ReaderToggledNeed(need) -> {
      let needs = case set.contains(model.needs, need) {
        True -> set.delete(model.needs, need)
        False -> set.insert(model.needs, need)
      }
      #(Model(..model, needs:), effect.none())
    }
    ReaderClearedNeeds -> #(Model(..model, needs: set.new()), effect.none())

    ReaderPickedOutcome(outcome) -> #(
      Model(
        ..model,
        outcome:,
        trace: stepper.restart(model.trace, trace.length(outcome)),
      ),
      effect.none(),
    )
    ReaderSteppedTraceBack -> #(
      Model(..model, trace: stepper.back(model.trace)),
      effect.none(),
    )
    ReaderSteppedTraceForward -> #(
      Model(..model, trace: stepper.forward(model.trace)),
      effect.none(),
    )
    ReaderScrubbedTrace(n) -> #(
      Model(..model, trace: stepper.scrub(model.trace, n)),
      effect.none(),
    )
    ReaderPlayedTrace -> {
      let played = stepper.play(model.trace, context.motion)
      #(
        Model(..model, trace: played),
        schedule(played, trace_ms, TraceEventDue),
      )
    }
    TraceEventDue(epoch) ->
      case stepper.tick(model.trace, epoch) {
        Ok(played) -> #(
          Model(..model, trace: played),
          schedule(played, trace_ms, TraceEventDue),
        )
        Error(Nil) -> #(model, effect.none())
      }

    Tour(id, command) ->
      tour.update(driver(context), model, id, command, context.motion)
  }
}

/// The next tick of a playing walk.
fn schedule(walk: Stepper, ms: Int, to_msg: fn(Int) -> Msg) -> Effect(Msg) {
  case stepper.run(walk) {
    stepper.Playing -> browser.after(ms, to_msg(stepper.epoch(walk)))
    stepper.Idle -> effect.none()
  }
}

/// Leaving the page pauses any playing tour and stops played walks.
pub fn leave(model: Model) -> Model {
  Model(
    ..model,
    walk: stepper.stop(model.walk),
    trace: stepper.stop(model.trace),
    tours: tour.pause_all(model.tours),
  )
}

/// This page has no real-time widgets.
pub fn register() -> Result(Nil, lustre.Error) {
  Ok(Nil)
}

// TOURS -----------------------------------------------------------------------

fn driver(context: Context) -> tour.Driver(TourId, Model, Msg) {
  tour.Driver(
    script:,
    key:,
    tours: fn(model: Model) { model.tours },
    set_tours: fn(model, tours) { Model(..model, tours:) },
    run: fn(model, msg) { update(model, msg, context) },
    to_msg: Tour,
  )
}

pub fn key(id: TourId) -> String {
  case id {
    Systems -> "systems"
    Builder -> "builder"
    Trace -> "trace"
  }
}

/// Replace the reader's needs with exactly these.
fn choose(needs: List(Need)) -> List(Msg) {
  [ReaderClearedNeeds, ..list.map(needs, ReaderToggledNeed)]
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  case id {
    Systems -> {
      let play = fn(system) {
        fn(_) { [ReaderPickedSystem(system), ReaderPlayedSystem] }
      }
      tour.Script(
        reset: fn(_) { [ReaderPickedSystem(systems.Checkout)] },
        steps: [
          tour.say(
            "Ten real applications from the Oversight repository. Lit chips are the packages each one uses.",
          ),
          tour.act(
            "Checkout: watch which package does what as the steps play. Grind keeps it durable; Saga keeps it ordered and undoable.",
            play(systems.Checkout),
          )
            |> tour.lasting(9800),
          tour.act(
            "Payout desk: an agent proposes, a decision point decides, a saga pays. Fabric never moves money itself.",
            play(systems.PayoutDesk),
          )
            |> tour.lasting(7600),
          tour.say("Pick any system and step through it yourself."),
        ],
      )
    }
    Builder ->
      tour.Script(reset: fn(_) { choose(first_needs) }, steps: [
        tour.say(
          "Tick what a system must do; get the packages, the patterns and the nearest example. This one needs durable, undoable steps: Grind plus Saga, like checkout.",
        ),
        tour.act(
          "A different system: typed answers from an LLM, run in the background. LLM Wire, JSON Blueprint, Grind: the invoice extractor.",
          fn(_) { choose([builder.TypedModelAnswers, builder.BackgroundWork]) },
        ),
        tour.act(
          "Add an agent with tools and a human approver: Fabric hands risky calls to a Decisions point.",
          fn(_) {
            choose([
              builder.TypedModelAnswers,
              builder.BackgroundWork,
              builder.AgentWithTools,
              builder.HumanApproval,
            ])
          },
        ),
        tour.say("Now design your own."),
      ])
    Trace -> {
      let to = fn(n) { fn(_) { [ReaderScrubbedTrace(n)] } }
      tour.Script(
        reset: fn(_) { [ReaderPickedOutcome(trace.Succeeds)] },
        steps: [
          tour.say(
            "The durable checkout as a trace. Event 1: Grind admitted the job in the same transaction as the order.",
          ),
          tour.act(
            "Grind claims the job and its handler starts the saga. Every arrow is a real Sinal event name.",
            to(3),
          ),
          tour.act(
            "Zoom into the charge: HTTP Gun reports milestones. gun_call_returned does not prove the provider got the request: the MaybeSent gap from module 4.",
            to(8),
          ),
          tour.act(
            "Meanwhile Grind’s renewer keeps the lease alive, then the response settles and the step is checkpointed.",
            to(12),
          ),
          tour.act(
            "The run completes and Grind stores the outcome in the job row: the durable truth.",
            to(16),
          ),
          tour.act(
            "Same trace when shipping fails: the undo events run newest first, then the run stops compensated. Scrub through it yourself.",
            fn(_) {
              [
                ReaderPickedOutcome(trace.ShippingFails),
                ReaderScrubbedTrace(18),
              ]
            },
          ),
        ],
      )
    }
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model, context: Context) -> Element(Msg) {
  let lab = fn(id, attributes, children) {
    tour.lab(model.tours, id, driver(context), context, attributes, children)
  }
  element.fragment([
    hero(),
    html.section([class("wrap sec")], [
      lab(Systems, [css("margin-top:0")], systems_lab(model)),
    ]),
    patterns(),
    html.section([class("wrap sec")], [
      lab(Builder, [css("margin-top:0")], builder_lab(model.needs)),
      capstone_intro(),
      lab(Trace, [], trace_lab(model)),
      ui.carry_forward(
        "A gleam-dream system is a few focused libraries plus your application code in between. Pick by job, join with the patterns, and keep the decisions in your own code.",
      ),
    ]),
  ])
}

fn hero() -> Element(Msg) {
  html.header([class("wrap"), css("padding-top:72px;padding-bottom:48px")], [
    html.div([class("k")], [
      html.text("Module 10 · Phase 4: putting it together"),
    ]),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:940px")],
      [html.text("Composition studio")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "You know the pieces. Now watch them combine. The systems below are the runnable applications in the Oversight repository, each one a few libraries joined by ordinary application code. Then design your own and see which packages it needs.",
      ),
    ]),
  ])
}

fn lab_heading(
  tag: String,
  title: String,
  description: String,
  extra: List(Element(Msg)),
) -> Element(Msg) {
  html.div([class("labh")], [
    html.div([], [
      html.span([class("tag")], [html.text(tag)]),
      html.h2([css("font-size:28px;margin-top:10px")], [html.text(title)]),
      html.p([class("muted"), css("margin-top:6px;max-width:680px")], [
        html.text(description),
      ]),
    ]),
    ..extra
  ])
}

fn chip(style: String, text: String) -> Element(Msg) {
  html.span([class("chip"), css(style)], [html.text(text)])
}

// Real systems, step by step.

fn systems_lab(model: Model) -> List(Element(Msg)) {
  let info = systems.info(model.system)
  let at = stepper.at(model.walk)
  let current = case list.drop(info.steps, at - 1) {
    [#(actor, _), ..] -> Some(actor)
    [] -> None
  }
  [
    lab_heading(
      "Playground",
      "Real systems, step by step",
      "Pick a system. The lit chips are the packages it uses. Step through to see which package does what, and when.",
      [],
    ),
    html.div([class("split"), css("align-items:flex-start;gap:20px")], [
      html.div(
        [
          class("syslist"),
          css("flex:1 1 240px;display:flex;flex-direction:column;gap:6px"),
        ],
        list.map(systems.all, system_button(_, model.system)),
      ),
      html.div([css("flex:3 1 560px;min-width:0")], [
        html.h3([css("font-size:28px")], [html.text(info.name)]),
        html.p([class("muted"), css("margin-top:6px;font-size:16px")], [
          html.text(info.blurb),
        ]),
        html.div(
          [class("row"), css("gap:6px;margin-top:16px")],
          list.map(package.all, package_chip(_, info.packages, current)),
        ),
        html.div(
          [css("display:flex;flex-direction:column;gap:8px;margin-top:20px")],
          list.index_map(info.steps, fn(step, i) { flow_step(step, i, at) }),
        ),
        html.div(
          [class("row"), css("margin-top:16px;justify-content:space-between")],
          [
            html.div([class("row")], [
              html.button(
                [
                  attribute.type_("button"),
                  class("btn"),
                  event.on_click(ReaderSteppedBack),
                  attribute.disabled(stepper.at_start(model.walk)),
                ],
                [html.text("← Back")],
              ),
              html.button(
                [
                  attribute.type_("button"),
                  class("btn pri"),
                  event.on_click(ReaderSteppedForward),
                  attribute.disabled(stepper.at_end(model.walk)),
                ],
                [html.text("Next step →")],
              ),
              html.button(
                [
                  attribute.type_("button"),
                  class("btn sm"),
                  event.on_click(ReaderPlayedSystem),
                ],
                [html.text("Play")],
              ),
            ]),
            html.span([class("meta")], [
              html.text(
                "step "
                <> int.to_string(at)
                <> " of "
                <> int.to_string(stepper.total(model.walk)),
              ),
            ]),
          ],
        ),
        html.div([class("split tour-hide"), css("margin-top:16px;gap:12px")], [
          note_box(
            "background:#FFF7FC;border-color:#F3C6E6",
            "why this shape",
            info.why,
          ),
          note_box(
            "background:#FDF0DC;border-color:#F3D9B1",
            "the app still owns",
            info.owns,
          ),
        ]),
      ]),
    ]),
  ]
}

fn system_button(system: System, selected: System) -> Element(Msg) {
  let info = systems.info(system)
  let on = system == selected
  let #(bg, fg, border) = case on {
    True -> #("#17162B", "#FFFFFF", "#17162B")
    False -> #("#FFFFFF", "#17162B", "#E4E0D8")
  }
  html.button(
    [
      attribute.type_("button"),
      event.on_click(ReaderPickedSystem(system)),
      ui.pressed(on),
      css(
        "text-align:left;font:inherit;cursor:pointer;border-radius:12px;padding:10px 14px;min-height:56px;border:2px solid "
        <> border
        <> ";background:"
        <> bg
        <> ";color:"
        <> fg
        <> ";display:flex;flex-direction:column",
      ),
    ],
    [
      html.b([css("font-size:15px")], [html.text(info.name)]),
      html.span([class("tour-hide"), css("font-size:13px;opacity:.85")], [
        html.text(info.task),
      ]),
    ],
  )
}

/// A package chip, lit when the system uses it and outlined when it does
/// the current step.
fn package_chip(
  package: Package,
  used: List(Package),
  current: option.Option(Actor),
) -> Element(Msg) {
  let style = package.package_style(package)
  let used = list.contains(used, package)
  let now = current == Some(Uses(package))
  let border = case now, used {
    True, _ -> style.fg
    False, True -> style.bg
    False, False -> "#E4E0D8"
  }
  let #(bg, opacity) = case used {
    True -> #(style.bg, "1")
    False -> #("#FFFFFF", "0.35")
  }
  chip(
    "background:"
      <> bg
      <> ";color:"
      <> style.fg
      <> ";border:2px solid "
      <> border
      <> ";opacity:"
      <> opacity,
    style.name,
  )
}

fn flow_step(step: #(Actor, String), i: Int, at: Int) -> Element(Msg) {
  let #(actor, text) = step
  let style = package.style(actor)
  let #(bg, border) = case i == at - 1 {
    True -> #("#FFFFFF", "#17162B")
    False -> #("#FAF8F4", "#E4E0D8")
  }
  let opacity = case i < at {
    True -> "1"
    False -> "0.3"
  }
  html.div(
    [
      css(
        "display:flex;gap:14px;align-items:flex-start;padding:12px 14px;border-radius:14px;background:"
        <> bg
        <> ";border:2px solid "
        <> border
        <> ";opacity:"
        <> opacity,
      ),
    ],
    [
      html.span(
        [
          class("mono"),
          css("font-weight:600;font-size:13px;min-width:22px;padding-top:2px"),
        ],
        [html.text(int.to_string(i + 1))],
      ),
      chip(
        "background:" <> style.bg <> ";color:" <> style.fg <> ";flex:0 0 auto",
        style.name,
      ),
      html.span([css("font-size:15px")], [html.text(text)]),
    ],
  )
}

fn note_box(style: String, label: String, text: String) -> Element(Msg) {
  html.div([class("box"), css(style)], [
    html.div([class("meta")], [html.text(label)]),
    html.p([css("font-size:15px;margin-top:4px")], [html.text(text)]),
  ])
}

// Six composition patterns.

fn patterns() -> Element(Msg) {
  html.section([class("wrap sec")], [
    html.div([class("k")], [html.text("Read · recurring moves")]),
    html.h2([class("h2")], [html.text("Six composition patterns")]),
    html.p([class("lead")], [
      html.text(
        "The same joints show up again and again. Recognise them and new systems stop looking new.",
      ),
    ]),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px;margin-top:24px",
        ),
      ],
      list.map(systems.patterns, pattern_card),
    ),
  ])
}

fn pattern_card(pattern: systems.Pattern) -> Element(Msg) {
  let last = list.length(pattern.chain) - 1
  html.div([class("card"), css("padding:20px")], [
    html.h3([css("font-size:19px")], [html.text(pattern.name)]),
    html.div(
      [class("row"), css("gap:4px;margin:12px 0")],
      list.index_map(pattern.chain, fn(actor, i) {
        let style = package.style(actor)
        html.span([css("display:inline-flex;align-items:center;gap:4px")], [
          chip("background:" <> style.bg <> ";color:" <> style.fg, style.name),
          html.span([class("muted"), attribute("aria-hidden", "true")], [
            html.text(case i < last {
              True -> "→"
              False -> ""
            }),
          ]),
        ])
      }),
    ),
    html.p([class("muted"), css("font-size:15px")], [html.text(pattern.text)]),
  ])
}

// Design your own system.

fn builder_lab(needs: Set(Need)) -> List(Element(Msg)) {
  let design = builder.design(needs)
  [
    lab_heading(
      "Playground",
      "Design your own system",
      "Tick what your system must do. You'll get the packages, the patterns that apply, the nearest example app to read, and what stays yours.",
      [
        html.button(
          [
            attribute.type_("button"),
            class("btn sm"),
            event.on_click(ReaderClearedNeeds),
          ],
          [html.text("Clear")],
        ),
      ],
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:8px",
        ),
      ],
      list.map(builder.needs, fn(need) {
        need_button(need, set.contains(needs, need))
      }),
    ),
    html.div([class("split"), css("margin-top:24px;align-items:flex-start")], [
      html.div([css("flex:2 1 420px")], [
        html.div([class("meta"), css("margin-bottom:8px")], [
          html.text("Packages"),
        ]),
        html.div([css("display:flex;flex-direction:column;gap:6px")], [
          element.fragment(list.map(design.packages, picked_package)),
          case design.packages {
            [] ->
              html.p([class("muted")], [
                html.text("Tick a requirement to start."),
              ])
            _ -> element.none()
          },
        ]),
      ]),
      html.div(
        [css("flex:1 1 300px;display:flex;flex-direction:column;gap:12px")],
        [
          html.div(
            [class("box"), css("background:#FFF7FC;border-color:#F3C6E6")],
            [
              html.div([class("meta")], [html.text("patterns that apply")]),
              element.fragment(
                list.map(design.patterns, fn(text) {
                  html.p([css("font-size:14px;margin-top:6px")], [
                    html.text("→ " <> text),
                  ])
                }),
              ),
              case design.patterns {
                [] ->
                  html.p(
                    [class("muted"), css("font-size:14px;margin-top:6px")],
                    [
                      html.text("None yet."),
                    ],
                  )
                _ -> element.none()
              },
            ],
          ),
          html.div(
            [class("box"), css("background:#E2F4E7;border-color:#B9E2C4")],
            [
              html.div([class("meta")], [html.text("nearest example to read")]),
              html.b([css("font-size:17px;display:block;margin-top:4px")], [
                html.text(case design.nearest {
                  Some(example) -> example.name
                  None -> "Pick a requirement"
                }),
              ]),
              html.span([css("font-size:14px")], [
                html.text(case design.nearest {
                  Some(_) ->
                    "Shares the most packages with your design. Open it in the Oversight repository."
                  None -> ""
                }),
              ]),
            ],
          ),
          html.div(
            [class("box"), css("background:#FDF0DC;border-color:#F3D9B1")],
            [
              html.div([class("meta")], [html.text("still yours")]),
              html.p([css("font-size:14px;margin-top:4px")], [
                html.text(string.join(design.yours, " · ")),
              ]),
            ],
          ),
        ],
      ),
    ]),
  ]
}

fn need_button(need: Need, on: Bool) -> Element(Msg) {
  let #(mark, bg, border) = case on {
    True -> #("✓", "#FFF7FC", "#B0186E")
    False -> #("+", "#FFFFFF", "#E4E0D8")
  }
  html.button(
    [
      attribute.type_("button"),
      event.on_click(ReaderToggledNeed(need)),
      ui.pressed(on),
      css(
        "text-align:left;font:inherit;cursor:pointer;border-radius:12px;padding:12px 14px;min-height:52px;border:2px solid "
        <> border
        <> ";background:"
        <> bg
        <> ";color:#17162B;display:flex;gap:10px;align-items:center",
      ),
    ],
    [
      html.span([class("mono"), css("font-weight:700;width:18px")], [
        html.text(mark),
      ]),
      html.span([css("font-size:15px")], [html.text(builder.label(need))]),
    ],
  )
}

fn picked_package(package: Package) -> Element(Msg) {
  let style = package.package_style(package)
  html.div(
    [
      css(
        "display:flex;gap:12px;align-items:baseline;padding:10px 14px;border-radius:12px;background:"
        <> style.bg,
      ),
    ],
    [
      html.b([css("min-width:120px;color:" <> style.fg)], [
        html.text(style.name),
      ]),
      html.span([css("font-size:14px")], [html.text(builder.reason(package))]),
    ],
  )
}

// Capstone: read a trace.

fn capstone_intro() -> Element(Msg) {
  html.div([css("margin-top:72px")], [
    html.div([class("k")], [html.text("Capstone · read a trace")]),
    html.h2([class("h2")], [
      html.text("Watch checkout through its own telemetry"),
    ]),
    html.p([class("lead")], [
      html.text(
        "Every library you met reports what it is doing through Sinal. Here is the durable checkout told only through the events Grind, Saga and HTTP Gun emit, the way an operator reads a trace. Each column is a component; each arrow is an event, labelled with its real name.",
      ),
    ]),
  ])
}

fn trace_lab(model: Model) -> List(Element(Msg)) {
  let at = stepper.at(model.trace)
  let total = stepper.total(model.trace)
  let shown = trace.event_at(model.outcome, at)
  let by = trace.emitter(shown.by)
  [
    html.div([class("labh")], [
      html.div([], [
        html.span([class("tag")], [html.text("Trace")]),
        html.h2([css("font-size:24px;margin-top:10px"), class("mono")], [
          html.text("POST /orders"),
        ]),
      ]),
      html.div(
        [class("seg")],
        list.map(trace.outcomes, fn(outcome) {
          let on = outcome == model.outcome
          html.button(
            [
              attribute.type_("button"),
              ui.on_class("", on),
              ui.pressed(on),
              event.on_click(ReaderPickedOutcome(outcome)),
            ],
            [html.text(trace.outcome_label(outcome))],
          )
        }),
      ),
    ]),
    msc.view(trace.chart(model.outcome, at)),
    html.div([class("box"), css("margin-top:14px;border:2px solid #17162B")], [
      html.div([class("row"), css("justify-content:space-between;gap:10px")], [
        html.span([class("mono"), css("font-size:16px;font-weight:700")], [
          html.text(trace.name_list(shown)),
        ]),
        chip(
          "background:" <> by.bg <> ";color:" <> by.fg,
          "emitted by " <> by.name,
        ),
      ]),
      html.p([css("font-size:15px;margin-top:8px")], [html.text(shown.meaning)]),
      case shown.fields {
        Some(fields) ->
          html.p([class("meta"), css("margin-top:6px")], [
            html.text("fields: " <> fields),
          ])
        None -> element.none()
      },
    ]),
    html.div(
      [
        class("row"),
        css("margin-top:14px;justify-content:space-between;gap:12px"),
      ],
      [
        html.div([class("row")], [
          html.button(
            [
              attribute.type_("button"),
              class("btn"),
              event.on_click(ReaderSteppedTraceBack),
              attribute.disabled(stepper.at_start(model.trace)),
            ],
            [html.text("← Back")],
          ),
          html.button(
            [
              attribute.type_("button"),
              class("btn pri"),
              event.on_click(ReaderSteppedTraceForward),
              attribute.disabled(stepper.at_end(model.trace)),
            ],
            [html.text("Next event →")],
          ),
          html.button(
            [
              attribute.type_("button"),
              class("btn sm"),
              event.on_click(ReaderPlayedTrace),
            ],
            [html.text("Play")],
          ),
        ]),
        html.label(
          [
            css(
              "display:flex;align-items:center;gap:10px;flex:1 1 260px;max-width:420px",
            ),
          ],
          [
            html.span([class("meta")], [
              html.text(
                "event " <> int.to_string(at) <> " of " <> int.to_string(total),
              ),
            ]),
            html.input([
              attribute.type_("range"),
              attribute("min", "1"),
              attribute("max", int.to_string(total)),
              attribute("step", "1"),
              attribute.value(int.to_string(at)),
              event.on_input(fn(value) {
                case int.parse(value) {
                  Ok(n) -> ReaderScrubbedTrace(n)
                  Error(Nil) -> ReaderScrubbedTrace(at)
                }
              }),
              css("flex:1"),
            ]),
          ],
        ),
      ],
    ),
    html.p([class("muted"), css("font-size:13px;margin-top:12px")], [
      html.text(
        "Event names and HTTP Gun's milestones are the real ones from each library's telemetry module. The order of events is reconstructed from the checkout example's design, not recorded from a live run, so treat timings as illustrative.",
      ),
    ]),
  ]
}
