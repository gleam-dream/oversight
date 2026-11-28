//// The course map: the six-layer stack, how modules work, and the path
//// through all eleven modules.

import gleam/int
import gleam/list
import lustre/attribute.{attribute, class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import site/context.{type Context}
import site/progress
import site/route.{type Module}
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

/// The six layers, top to bottom as the stack is drawn.
pub type Layer {
  YourSystems
  BuildingBlocks
  FoundationsLayer
  GleamLayer
  OtpLayer
  BeamLayer
}

pub const layers = [
  YourSystems,
  BuildingBlocks,
  FoundationsLayer,
  GleamLayer,
  OtpLayer,
  BeamLayer,
]

pub type TourId {
  Stack
}

pub type Model {
  Model(selected: Layer, tours: tour.Tours(TourId))
}

pub type Msg {
  ReaderPickedLayer(Layer)
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(selected: YourSystems, tours: tour.new())
}

// UPDATE ----------------------------------------------------------------------

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  case msg {
    ReaderPickedLayer(layer) -> #(
      Model(..model, selected: layer),
      effect.none(),
    )
    Tour(id, command) ->
      tour.update(driver(context), model, id, command, context.motion)
  }
}

/// Leaving the page pauses any playing tour.
pub fn leave(model: Model) -> Model {
  Model(..model, tours: tour.pause_all(model.tours))
}

fn driver(context: Context) -> tour.Driver(TourId, Model, Msg) {
  tour.Driver(
    script:,
    key: fn(_) { "stack" },
    tours: fn(model: Model) { model.tours },
    set_tours: fn(model, tours) { Model(..model, tours:) },
    run: fn(model, msg) { update(model, msg, context) },
    to_msg: Tour,
  )
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  let pick = fn(layer) { fn(_) { [ReaderPickedLayer(layer)] } }
  case id {
    Stack ->
      tour.Script(reset: fn(_) { [ReaderPickedLayer(YourSystems)] }, steps: [
        tour.say(
          "The whole course on one screen: six layers, each leaning on the one below. Press Next or Play to climb from the bottom.",
        ),
        tour.act(
          "At the bottom, the BEAM: a virtual machine of tiny isolated processes that only talk by sending messages.",
          pick(BeamLayer),
        ),
        tour.act(
          "OTP adds proven patterns on top: actors hold state, supervisors restart what crashes.",
          pick(OtpLayer),
        ),
        tour.act(
          "Gleam adds types: errors become values, impossible states can’t be built, messages are checked by the compiler.",
          pick(GleamLayer),
        ),
        tour.act(
          "Three foundation libraries everything else uses: Sinal to observe, JSON Blueprint to shape data, HTTP Gun to reach the network.",
          pick(FoundationsLayer),
        ),
        tour.act(
          "The building blocks: models, tools, sign-in, mail, durable jobs, workflows, agents and human decisions.",
          pick(BuildingBlocks),
        ),
        tour.act(
          "And your application on top, owning every decision. Click any layer yourself, or start module 1.",
          pick(YourSystems),
        ),
      ])
  }
}

// CONTENT ---------------------------------------------------------------------

type LayerInfo {
  LayerInfo(
    n: String,
    name: String,
    tag: String,
    bg: String,
    fg: String,
    summary: String,
    gives: List(String),
    where_: String,
    href: String,
    cta: String,
  )
}

fn info(layer: Layer) -> LayerInfo {
  case layer {
    YourSystems ->
      LayerInfo(
        n: "6",
        name: "Your systems",
        tag: "Checkout, support desk, research agent…",
        bg: "#17162B",
        fg: "#FFFFFF",
        summary: "The application you write. It owns the types, the policy, the database and every resource lifetime, and composes the libraries below in plain code.",
        gives: [
          "A product that survives crashes, retries and restarts",
          "Clear ownership: you decide, libraries execute",
          "Reference compositions to start from",
        ],
        where_: "Modules 10 and 11 assemble real systems from the pieces.",
        href: "#compose",
        cta: "Open the composition studio",
      )
    BuildingBlocks ->
      LayerInfo(
        n: "5",
        name: "Building blocks",
        tag: "LLM Wire, Relay, Hellhound, Correio, Grind, Saga, Fabric, Decisions, Retrace",
        bg: "#FCE7F3",
        fg: "#5E0B3A",
        summary: "Focused libraries for the hard parts of services: talking to models and tools, signing people in, sending mail, durable jobs, workflows, agents and human approval.",
        gives: [
          "Typed contracts at every boundary",
          "Honest evidence when an effect may or may not have happened",
          "Durable records you can recover from",
        ],
        where_: "Modules 7, 8 and 9 tour them by job to be done.",
        href: "#outside-world",
        cta: "Meet the building blocks",
      )
    FoundationsLayer ->
      LayerInfo(
        n: "4",
        name: "Foundations",
        tag: "Sinal, JSON Blueprint, HTTP Gun",
        bg: "#DDF3F0",
        fg: "#0B4A45",
        summary: "Three shared libraries almost every other package stands on: typed telemetry, typed JSON with schemas, and a bounded HTTP client.",
        gives: [
          "One way to observe everything (Sinal)",
          "One way to describe data shapes (JSON Blueprint)",
          "One way to reach the network (HTTP Gun)",
        ],
        where_: "Module 6 opens each one up.",
        href: "#foundations",
        cta: "Explore the foundations",
      )
    GleamLayer ->
      LayerInfo(
        n: "3",
        name: "Gleam",
        tag: "A typed language that compiles to the BEAM",
        bg: "#F9D7F0",
        fg: "#4A1340",
        summary: "A friendly, statically typed language. Errors are values, impossible states can’t be built, and messages between processes are checked by the compiler.",
        gives: [
          "Types for data, results and messages",
          "Exhaustive pattern matching",
          "Full access to Erlang and Elixir libraries",
        ],
        where_: "Module 3 covers what Gleam adds.",
        href: "#gleam",
        cta: "Learn what Gleam adds",
      )
    OtpLayer ->
      LayerInfo(
        n: "2",
        name: "OTP",
        tag: "Patterns for processes: actors, supervisors, applications",
        bg: "#DCD9FF",
        fg: "#241F6B",
        summary: "Battle-tested building patterns for processes. Actors hold state, supervisors restart what crashes, applications start and stop the whole tree.",
        gives: [
          "Supervision trees: failure becomes a restart",
          "Actors: one message at a time, no locks",
          "A standard place to plug every library in",
        ],
        where_: "Module 2 has a supervision simulator.",
        href: "#otp",
        cta: "Play with supervision",
      )
    BeamLayer ->
      LayerInfo(
        n: "1",
        name: "The BEAM",
        tag: "The virtual machine under Erlang, Elixir and Gleam",
        bg: "#2B2862",
        fg: "#FFFFFF",
        summary: "A runtime built for systems that never stop. Millions of tiny isolated processes share nothing and talk only by sending messages.",
        gives: [
          "Cheap, isolated processes",
          "Message passing instead of shared memory",
          "Fair, preemptive scheduling across all cores",
        ],
        where_: "Module 1 starts here.",
        href: "#beam",
        cta: "Start with the BEAM",
      )
  }
}

type Phase {
  Phase(label: String, title: String, colour: String, modules: List(Entry))
}

type Entry {
  Entry(module: Module, blurb: String, play: String)
}

const phases = [
  Phase(
    label: "Phase 1",
    title: "The runtime",
    colour: "#2B2862",
    modules: [
      Entry(
        route.Beam,
        "Processes, messages, mailboxes and why nothing is shared.",
        "crash a process",
      ),
      Entry(
        route.Otp,
        "Actors, supervisors and the art of letting things crash.",
        "supervision tree",
      ),
      Entry(
        route.Gleam,
        "Types, results and messages the compiler can check.",
        "impossible states",
      ),
    ],
  ),
  Phase(
    label: "Phase 2",
    title: "The mental model",
    colour: "#B0186E",
    modules: [
      Entry(
        route.Principles,
        "Seven principles every package shares. Learn them once.",
        "did it happen?",
      ),
      Entry(
        route.Atlas,
        "All twelve libraries on one map, with what each owns.",
        "interactive map",
      ),
    ],
  ),
  Phase(
    label: "Phase 3",
    title: "The building blocks",
    colour: "#0F766E",
    modules: [
      Entry(
        route.Foundations,
        "Sinal, JSON Blueprint and HTTP Gun.",
        "emit, decode, request",
      ),
      Entry(
        route.OutsideWorld,
        "LLM Wire, Relay (MCP), Hellhound (sign-in) and Correio (email).",
        "four flows",
      ),
      Entry(
        route.DurableWork,
        "Grind jobs and Saga workflows.",
        "job lifecycle",
      ),
      Entry(
        route.Agents,
        "Fabric agents and Decisions decision points.",
        "policy gate",
      ),
    ],
  ),
  Phase(
    label: "Phase 4",
    title: "Putting it together",
    colour: "#B45309",
    modules: [
      Entry(
        route.Compose,
        "Real systems, step by step, and a builder for your own.",
        "system builder",
      ),
      Entry(
        route.FieldGuide,
        "Retrace, tooling, a glossary and a cheat sheet to keep.",
        "session replay",
      ),
    ],
  ),
]

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model, context: Context) -> Element(Msg) {
  element.fragment([
    hero(),
    html.section([class("wrap"), css("padding-bottom:72px")], [
      tour.lab(
        model.tours,
        Stack,
        driver(context),
        context,
        [css("padding:32px;margin-top:0")],
        [stack(model.selected)],
      ),
    ]),
    how_modules_work(),
    path(context),
    one_sentence(),
  ])
}

fn hero() -> Element(Msg) {
  html.header([class("wrap"), css("padding-top:80px;padding-bottom:56px")], [
    html.div([class("k")], [html.text("Onboarding for new developers")]),
    html.h1(
      [css("font-size:clamp(40px,6vw,76px);margin-top:16px;max-width:900px")],
      [html.text("From the BEAM to real systems")],
    ),
    html.p(
      [css("font-size:21px;max-width:760px;margin:24px 0 0"), class("muted")],
      [
        html.text(
          "A guided path through the runtime, the language and the gleam-dream libraries. You'll leave with a mental model you can navigate by: what each layer gives you, what each package owns, and how they snap together into real services.",
        ),
      ],
    ),
    html.div([css("display:flex;flex-wrap:wrap;gap:12px;margin-top:32px")], [
      html.a([class("btnl pri"), attribute.href("#beam")], [
        html.text("Start with the BEAM →"),
      ]),
      html.a([class("btnl sec"), attribute.href("#atlas")], [
        html.text("Jump to the package atlas"),
      ]),
    ]),
    html.div(
      [
        css("display:flex;flex-wrap:wrap;gap:24px;margin-top:40px"),
        class("muted"),
      ],
      [
        promise("No code required.", " Concepts, pictures and playgrounds."),
        promise("Self-paced.", " Every module stands alone."),
        promise("Progress saved.", " Mark modules done as you go."),
      ],
    ),
  ])
}

fn promise(lead: String, rest: String) -> Element(Msg) {
  html.span([], [
    html.b([css("color:#17162B")], [html.text(lead)]),
    html.text(rest),
  ])
}

fn stack(selected: Layer) -> Element(Msg) {
  let sel = info(selected)
  html.div([css("display:flex;flex-wrap:wrap;gap:32px")], [
    html.div([css("flex:1 1 420px;min-width:0")], [
      html.div([class("k")], [html.text("Playground · the whole picture")]),
      html.h2([css("font-size:32px;margin:10px 0 8px")], [
        html.text("Six layers, one stack"),
      ]),
      html.p([class("muted"), css("margin:0 0 20px")], [
        html.text(
          "Everything you'll learn sits on one of these layers. Each layer leans on the one below it. Click a layer to see what it gives you.",
        ),
      ]),
      html.div(
        [css("display:flex;flex-direction:column;gap:8px")],
        list.map(layers, fn(layer) { layer_button(layer, layer == selected) }),
      ),
    ]),
    html.div([css("flex:1 1 380px;min-width:0;display:flex")], [
      html.div(
        [
          css(
            "flex:1;border-radius:16px;padding:28px;background:"
            <> sel.bg
            <> ";color:"
            <> sel.fg
            <> ";display:flex;flex-direction:column;gap:16px",
          ),
        ],
        [
          html.div(
            [
              css(
                "font:600 12px 'JetBrains Mono',monospace;letter-spacing:.08em;text-transform:uppercase;opacity:.85",
              ),
            ],
            [html.text("Layer " <> sel.n)],
          ),
          html.h3([css("font-size:34px")], [html.text(sel.name)]),
          html.p([css("margin:0;font-size:18px")], [html.text(sel.summary)]),
          html.div([], [
            html.div(
              [
                css(
                  "font:600 12px 'JetBrains Mono',monospace;letter-spacing:.08em;text-transform:uppercase;opacity:.85;margin-bottom:8px",
                ),
              ],
              [html.text("It gives you")],
            ),
            element.fragment(
              list.map(sel.gives, fn(g) {
                html.div([css("display:flex;gap:10px;margin-bottom:6px")], [
                  html.span([attribute("aria-hidden", "true")], [html.text("→")]),
                  html.span([], [html.text(g)]),
                ])
              }),
            ),
          ]),
          html.div(
            [
              css(
                "margin-top:auto;padding-top:12px;border-top:1px solid currentColor;opacity:.95",
              ),
            ],
            [
              html.div([css("font-size:14px")], [html.text(sel.where_)]),
              html.a(
                [attribute.href(sel.href), css("color:inherit;font-weight:700")],
                [html.text(sel.cta <> " →")],
              ),
            ],
          ),
        ],
      ),
    ]),
  ])
}

fn layer_button(layer: Layer, on: Bool) -> Element(Msg) {
  let l = info(layer)
  html.button(
    [
      attribute.type_("button"),
      ui.on_class("layer", on),
      css("background:" <> l.bg <> ";color:" <> l.fg),
      event.on_click(ReaderPickedLayer(layer)),
      ui.pressed(on),
    ],
    [
      html.span([class("ln")], [html.text(l.n)]),
      html.span([css("display:flex;flex-direction:column")], [
        html.span([class("lt")], [html.text(l.name)]),
        html.span([class("ls")], [html.text(l.tag)]),
      ]),
    ],
  )
}

fn how_modules_work() -> Element(Msg) {
  let card = fn(chip_style, chip, title, body) {
    html.div([class("card")], [
      html.div([class("chip"), css(chip_style)], [html.text(chip)]),
      html.h3([css("font-size:20px;margin:14px 0 6px")], [html.text(title)]),
      html.p([class("muted"), css("margin:0;font-size:15px")], [html.text(body)]),
    ])
  }
  html.section([class("wrap"), css("padding-bottom:72px")], [
    html.div([class("k")], [html.text("How every module works")]),
    html.h2([css("font-size:32px;margin:10px 0 24px")], [
      html.text("Read a little, play a lot, carry one idea forward"),
    ]),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px",
        ),
      ],
      [
        card(
          "background:#EBEAFD;color:#2B2862",
          "1 · Read",
          "Short concepts",
          "A handful of cards, each a single idea in plain words.",
        ),
        card(
          "background:#FCE7F3;color:#8A1056",
          "2 · Play",
          "Playgrounds",
          "Crash processes, inject failures, flip policies. Watch what happens.",
        ),
        card(
          "background:#FDF0DC;color:#8A3F06",
          "3 · Tick off",
          "Mark it done",
          "When a module clicks, mark it done. Your progress stays in this browser.",
        ),
        card(
          "background:#DDF3F0;color:#0B5A54",
          "4 · Carry",
          "One key idea",
          "The sentence to remember when you open a real repository.",
        ),
      ],
    ),
  ])
}

fn path(context: Context) -> Element(Msg) {
  html.section([class("wrap"), css("padding-bottom:72px")], [
    html.div([class("k")], [html.text("Your path · about 3¾ hours")]),
    html.h2([css("font-size:32px;margin:10px 0 8px")], [
      html.text("Four phases, eleven modules"),
    ]),
    html.p([class("muted"), css("margin:0 0 32px;max-width:720px")], [
      html.text(
        "Go in order the first time. Each phase builds the vocabulary the next one uses. Times assume you try every playground.",
      ),
    ]),
    element.fragment(list.map(phases, phase(_, context))),
  ])
}

fn phase(p: Phase, context: Context) -> Element(Msg) {
  html.div([css("margin-bottom:40px")], [
    html.div(
      [
        css(
          "display:flex;flex-wrap:wrap;align-items:baseline;gap:12px;margin-bottom:16px",
        ),
      ],
      [
        html.span(
          [class("chip"), css("background:" <> p.colour <> ";color:#fff")],
          [
            html.text(p.label),
          ],
        ),
        html.h3([css("font-size:24px")], [html.text(p.title)]),
        html.span([class("meta")], [html.text(phase_time(p))]),
      ],
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:16px",
        ),
      ],
      list.map(p.modules, entry(_, context)),
    ),
  ])
}

fn entry(e: Entry, context: Context) -> Element(Msg) {
  let done = case progress.is_done(context.progress, e.module) {
    True -> "✓ done · "
    False -> ""
  }
  html.a([class("mod"), attribute.href(route.href(route.Module(e.module)))], [
    html.span([class("mnum")], [
      html.span([], [
        html.text("Module " <> int.to_string(route.number(e.module))),
      ]),
      html.span([], [
        html.text(done <> int.to_string(route.minutes(e.module)) <> " min"),
      ]),
    ]),
    html.span([class("mt")], [html.text(route.module_title(e.module))]),
    html.span([class("muted"), css("font-size:15px")], [html.text(e.blurb)]),
    html.span(
      [css("font-size:13px;font-weight:600;color:#B0186E;margin-top:auto")],
      [html.text("Playground: " <> e.play)],
    ),
  ])
}

fn one_sentence() -> Element(Msg) {
  html.section([class("wrap"), css("padding-bottom:96px")], [
    html.div([class("dark")], [
      html.div([class("k"), css("color:#F9A8D4")], [
        html.text("The one-sentence version"),
      ]),
      html.p(
        [
          css(
            "font:600 clamp(24px,3vw,34px)/1.3 'Space Grotesk',sans-serif;margin:14px 0 0;max-width:900px",
          ),
        ],
        [
          html.text(
            "The BEAM gives you isolated processes, OTP turns failure into restarts, Gleam adds types, and gleam-dream adds twelve focused libraries that each own one mechanism while your application keeps every decision.",
          ),
        ],
      ),
      html.p([css("margin:20px 0 0;color:#C9C6E0;max-width:760px")], [
        html.text(
          "By module 11 that sentence should feel obvious. If any part of it doesn't yet, that's the module to start with.",
        ),
      ]),
      html.div([css("margin-top:28px")], [
        html.a(
          [
            class("btnl"),
            css("background:#fff;color:#17162B;border-color:#fff"),
            attribute.href("#beam"),
          ],
          [html.text("Begin →")],
        ),
      ]),
    ]),
  ])
}

/// A phase's time is the sum of its modules' times, so it cannot drift
/// from the module cards.
fn phase_time(phase: Phase) -> String {
  let minutes =
    list.fold(phase.modules, 0, fn(sum, e) { sum + route.minutes(e.module) })
  "about " <> int.to_string(minutes) <> " min"
}
