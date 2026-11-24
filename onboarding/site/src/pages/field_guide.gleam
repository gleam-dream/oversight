//// Module 11, Field guide: Retrace, the tooling around the libraries, a
//// filterable glossary, a cheat sheet and a reading plan.

import gleam/int
import gleam/list
import gleam/result
import lustre
import lustre/attribute.{attribute, class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import pages/field_guide/glossary.{type Group}
import pages/field_guide/retrace.{type Classification, type Strategy}
import site/context.{type Context}
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  RetraceTour
}

pub type Model {
  Model(
    strategy: Strategy,
    email: Classification,
    /// How many recorded events the replay frame has applied, 0 to 6.
    position: Int,
    query: String,
    group: Group,
    tours: tour.Tours(TourId),
  )
}

pub type Msg {
  ReaderPickedStrategy(Strategy)
  ReaderClassifiedEmail(Classification)
  ReaderScrubbedTo(Int)
  ReaderFilteredTerms(String)
  ReaderPickedGroup(Group)
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(
    strategy: retrace.Deterministic,
    email: retrace.Private,
    position: retrace.length,
    query: "",
    group: glossary.AllTerms,
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
    ReaderPickedStrategy(strategy) -> #(
      Model(..model, strategy:),
      effect.none(),
    )
    ReaderClassifiedEmail(email) -> #(Model(..model, email:), effect.none())
    ReaderScrubbedTo(position) -> #(
      Model(..model, position: int.clamp(position, 0, retrace.length)),
      effect.none(),
    )
    ReaderFilteredTerms(query) -> #(Model(..model, query:), effect.none())
    ReaderPickedGroup(group) -> #(Model(..model, group:), effect.none())
    Tour(id, command) ->
      tour.update(driver(context), model, id, command, context.motion)
  }
}

/// Leaving the page pauses any playing tour.
pub fn leave(model: Model) -> Model {
  Model(..model, tours: tour.pause_all(model.tours))
}

/// This page has no real-time widget.
pub fn register() -> Result(Nil, lustre.Error) {
  Ok(Nil)
}

// TOURS -----------------------------------------------------------------------

fn driver(context: Context) -> tour.Driver(TourId, Model, Msg) {
  tour.Driver(
    script:,
    key: fn(_) { "retrace" },
    tours: fn(model: Model) { model.tours },
    set_tours: fn(model, tours) { Model(..model, tours:) },
    run: fn(model, msg) { update(model, msg, context) },
    to_msg: Tour,
  )
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  let send = fn(msgs) { fn(_) { msgs } }
  case id {
    RetraceTour ->
      tour.Script(
        reset: send([
          ReaderPickedStrategy(retrace.Deterministic),
          ReaderClassifiedEmail(retrace.Private),
          ReaderScrubbedTo(6),
        ]),
        steps: [
          tour.act(
            "A recorded cart session, rebuilt from typed events. The slider is the recording’s timeline.",
            send([ReaderScrubbedTo(0)]),
          ),
          tour.act(
            "Three events in: the cart opened and two items were added. The frame shows exactly what the app showed then.",
            send([ReaderScrubbedTo(3)]),
          ),
          tour.act(
            "Event 4 came from outside: the coupon service’s answer. Deterministic replay feeds that recorded result back through the same update function.",
            send([ReaderScrubbedTo(4)]),
          ),
          tour.act(
            "Protected-observation replay instead adopts the observations the app recorded after each step. Both need the exact build that recorded them.",
            send([ReaderPickedStrategy(retrace.ProtectedObservations)]),
          ),
          tour.act(
            "The email was classified private at capture, so it was never stored: no viewer setting can bring it back.",
            send([ReaderScrubbedTo(6), ReaderClassifiedEmail(retrace.Private)]),
          ),
          tour.act(
            "Only when your app marks it safe is it recorded at all. Privacy is decided before anything is stored. Scrub freely now.",
            send([ReaderClassifiedEmail(retrace.Safe)]),
          ),
        ],
      )
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model, context: Context) -> Element(Msg) {
  element.fragment([
    hero(),
    retrace_section(model, context),
    tooling(),
    glossary_section(model),
    cheat_sheet(),
    reading_plan(),
  ])
}

fn hero() -> Element(Msg) {
  html.header([class("wrap"), css("padding-top:72px;padding-bottom:48px")], [
    html.div([class("k")], [
      html.text("Module 11 · Phase 4: putting it together"),
    ]),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:940px")],
      [html.text("Field guide")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "The last pieces, then a reference to keep. Meet Retrace and the tooling around the libraries, look anything up in the glossary, and leave with a cheat sheet and a reading plan for the repositories.",
      ),
    ]),
  ])
}

fn section_head(kicker: String, title: String) -> List(Element(Msg)) {
  [
    html.div([class("k")], [html.text(kicker)]),
    html.h2([class("h2")], [html.text(title)]),
  ]
}

// RETRACE ---------------------------------------------------------------------

fn retrace_section(model: Model, context: Context) -> Element(Msg) {
  let frame = retrace.frame(model.position, model.email)
  let private = model.email == retrace.Private
  let position = int.to_string(model.position)
  html.section(
    [class("wrap sec")],
    list.append(
      section_head(
        "Retrace · see what happened",
        "Replay a user's session, from typed events",
      ),
      [
        html.p([class("lead")], [
          html.text(
            "Retrace records the state and messages you explicitly select from a Lustre app, delivers them durably, and reconstructs the session later in an inert replay frame. It records your app's own typed events, never pixels, and only what you've classified as safe. It's experimental.",
          ),
        ]),
        tour.lab(model.tours, RetraceTour, driver(context), context, [], [
          html.div([class("labh")], [
            html.div([], [
              html.span([class("tag")], [html.text("Playground")]),
              html.h2([css("font-size:28px;margin-top:10px")], [
                html.text("Scrub through a recorded cart"),
              ]),
              html.p([class("muted"), css("margin-top:6px;max-width:680px")], [
                html.text(
                  "Drag along the recording. Switch replay strategy, and choose whether the email field counts as private.",
                ),
              ]),
            ]),
          ]),
          html.div([class("row"), css("gap:16px;margin-bottom:18px")], [
            html.div(
              [class("seg")],
              list.map(retrace.strategies, fn(strategy) {
                let on = strategy == model.strategy
                html.button(
                  [
                    attribute.type_("button"),
                    ui.on_class("", on),
                    ui.pressed(on),
                    event.on_click(ReaderPickedStrategy(strategy)),
                  ],
                  [html.text(retrace.strategy_label(strategy))],
                )
              }),
            ),
            html.button(
              [
                attribute.type_("button"),
                ui.on_class("btn", private),
                ui.pressed(private),
                event.on_click(
                  ReaderClassifiedEmail(case private {
                    True -> retrace.Safe
                    False -> retrace.Private
                  }),
                ),
              ],
              [
                html.text(case private {
                  True -> "Email: private (excluded)"
                  False -> "Email: safe to record"
                }),
              ],
            ),
          ]),
          html.label([css("display:flex;flex-direction:column;gap:8px")], [
            html.span([class("meta")], [
              html.text("recording position: event " <> position <> " of 6"),
            ]),
            html.input([
              attribute.type_("range"),
              attribute("min", "0"),
              attribute("max", "6"),
              attribute("step", "1"),
              attribute.value(position),
              event.on_input(fn(value) {
                ReaderScrubbedTo(result.unwrap(int.parse(value), model.position))
              }),
            ]),
          ]),
          html.div(
            [class("row"), css("gap:6px;margin:14px 0 20px")],
            list.index_map(retrace.recording, fn(event, i) {
              recorded_event(event, i, model.position)
            }),
          ),
          html.div([class("split"), css("align-items:stretch")], [
            html.div([class("box"), css("background:#F1EEE8;border:0")], [
              html.div([class("meta")], [
                html.text("replay frame (inert: buttons do nothing here)"),
              ]),
              replay_frame(frame),
            ]),
            html.div([class("box")], [
              html.div([class("meta")], [
                html.text("how this frame was rebuilt"),
              ]),
              html.p([css("font-size:15px;margin-top:8px")], [
                html.text(retrace.how(model.strategy, model.email)),
              ]),
            ]),
          ]),
        ]),
      ],
    ),
  )
}

fn recorded_event(
  event: #(String, retrace.Origin),
  index: Int,
  position: Int,
) -> Element(Msg) {
  let #(label, origin) = event
  let #(bg, fg) = case index < position, origin {
    True, retrace.ExternalResult -> #("#FFF1C2", "#17162B")
    True, retrace.AppMessage -> #("#E2F4E7", "#17162B")
    False, _ -> #("#F1EEE8", "#8A8698")
  }
  html.span([class("chip"), css("background:" <> bg <> ";color:" <> fg)], [
    html.text(int.to_string(index + 1) <> " · " <> label),
  ])
}

fn replay_frame(frame: retrace.Frame) -> Element(Msg) {
  let line = fn(style, left, right) {
    html.div([css(style)], [
      html.span([], [html.text(left)]),
      html.span([], [html.text(right)]),
    ])
  }
  let field = fn(style, name, value) {
    html.div([css(style)], [
      html.span([class("muted")], [html.text(name)]),
      html.text(" "),
      value,
    ])
  }
  html.div(
    [
      css(
        "background:#fff;border-radius:12px;padding:18px;margin-top:10px;display:flex;flex-direction:column;gap:8px",
      ),
    ],
    list.flatten([
      [
        html.b([css("font:600 18px 'Space Grotesk',sans-serif")], [
          html.text("Your cart"),
        ]),
      ],
      list.map(frame.lines, fn(l) {
        line(
          "display:flex;justify-content:space-between;font-size:15px",
          l.name,
          l.price,
        )
      }),
      [
        line(
          "display:flex;justify-content:space-between;font-size:15px;color:#15803D",
          frame.discount_label,
          frame.discount,
        ),
        line(
          "display:flex;justify-content:space-between;font-weight:700;border-top:1px solid #E4E0D8;padding-top:8px",
          "Total",
          frame.total,
        ),
        field(
          "font-size:14px;margin-top:6px",
          "Email:",
          html.span([class("mono")], [html.text(frame.email)]),
        ),
        field(
          "font-size:14px",
          "Status:",
          html.b([], [html.text(frame.status)]),
        ),
      ],
    ]),
  )
}

// TOOLING ---------------------------------------------------------------------

fn tooling() -> Element(Msg) {
  let card = fn(chip, name, body, repo) {
    let href = "https://github.com/gleam-dream/" <> repo
    html.div([class("card")], [
      html.span([class("chip"), css("background:#EDEFF3;color:#3B4452")], [
        html.text(chip),
      ]),
      html.h3([], [html.text(name)]),
      html.p([], [html.text(body)]),
      html.p([css("margin-top:10px")], [
        ui.external(href, [], [html.text("github.com/gleam-dream/" <> repo)]),
      ]),
    ])
  }
  html.section(
    [class("wrap sec")],
    list.append(
      section_head(
        "Tooling · around the libraries",
        "Three repositories that aren't libraries",
      ),
      [
        html.div([class("cards")], [
          card(
            "start here",
            "Oversight",
            "The catalogue of every library and fourteen runnable applications that compose them, with scripted providers and a disposable PostgreSQL. Read an app before you build a similar one.",
            "oversight",
          ),
          card(
            "build",
            "Gleam Nix",
            "Builds each Gleam dependency as its own Nix derivation from manifest.toml. Projects share compiled packages; editing your app rebuilds only your app.",
            "gleam-nix",
          ),
          card(
            "learn with AI",
            "Gleam Agent Tools",
            "Skills for AI coding agents that write Gleam: decision trees, red flags and primary sources, plus an optional language-server bridge.",
            "gleam-agent-tools",
          ),
        ]),
      ],
    ),
  )
}

// GLOSSARY --------------------------------------------------------------------

fn glossary_section(model: Model) -> Element(Msg) {
  let shown = glossary.filter(model.query, model.group)
  html.section(
    [class("wrap sec")],
    list.append(
      section_head("Reference · glossary", "Every term from the course"),
      [
        html.div([class("lab")], [
          html.label(
            [css("display:flex;flex-direction:column;gap:8px;max-width:480px")],
            [
              html.span([class("meta")], [html.text("Filter terms")]),
              html.input([
                attribute.type_("text"),
                attribute.value(model.query),
                event.on_input(ReaderFilteredTerms),
                attribute.placeholder("try: lease, hold, codec"),
                css(
                  "font:16px Inter,sans-serif;min-height:48px;padding:0 16px;border-radius:12px;border:1px solid #CFCBC2;background:#FAF8F4;color:#17162B",
                ),
              ]),
            ],
          ),
          html.div(
            [class("row"), css("gap:6px;margin:14px 0 18px")],
            list.map(glossary.groups, fn(group) {
              let on = group == model.group
              html.button(
                [
                  attribute.type_("button"),
                  ui.on_class("btn sm", on),
                  ui.pressed(on),
                  event.on_click(ReaderPickedGroup(group)),
                ],
                [html.text(glossary.group_label(group))],
              )
            }),
          ),
          html.div(
            [
              css(
                "display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:10px",
              ),
            ],
            list.map(shown, term_box),
          ),
          html.p([class("meta"), css("margin-top:12px")], [
            html.text(
              int.to_string(list.length(shown))
              <> " of "
              <> int.to_string(list.length(glossary.terms))
              <> " terms",
            ),
          ]),
        ]),
      ],
    ),
  )
}

fn term_box(term: glossary.Term) -> Element(Msg) {
  let #(bg, fg) = glossary.tag_colours(term.tag)
  html.div([class("box")], [
    html.div([css("display:flex;justify-content:space-between;gap:8px")], [
      html.b([], [html.text(term.term)]),
      html.span(
        [
          class("chip"),
          css("background:" <> bg <> ";color:" <> fg <> ";font-size:10px"),
        ],
        [html.text(glossary.tag_label(term.tag))],
      ),
    ]),
    html.p([css("font-size:14px;margin-top:4px"), class("muted")], [
      html.text(term.definition),
    ]),
  ])
}

// CHEAT SHEET -----------------------------------------------------------------

fn cheat_sheet() -> Element(Msg) {
  let head = fn(text) {
    html.div([css("background:#F1EEE8;padding:12px;font-weight:600")], [
      html.text(text),
    ])
  }
  html.section(
    [class("wrap sec")],
    list.append(section_head("Reference · cheat sheet", "Reach for it when…"), [
      html.div([css("overflow-x:auto;margin-top:20px")], [
        html.div(
          [
            css(
              "min-width:760px;display:grid;grid-template-columns:160px 1fr 1fr;gap:1px;background:#E4E0D8;border-radius:14px;overflow:hidden;font-size:15px",
            ),
          ],
          list.flatten([
            [
              head("Package"),
              head("Reach for it when you need to…"),
              head("Remember"),
            ],
            list.flat_map(glossary.cheat_sheet, sheet_row),
          ]),
        ),
      ]),
    ]),
  )
}

fn sheet_row(entry: glossary.Entry) -> List(Element(Msg)) {
  let #(bg, fg) = glossary.tag_colours(entry.package)
  [
    html.div(
      [
        css("background:" <> bg <> ";padding:12px;font-weight:700;color:" <> fg),
      ],
      [html.text(glossary.tag_label(entry.package))],
    ),
    html.div([css("background:#fff;padding:12px")], [html.text(entry.when)]),
    html.div([css("background:#fff;padding:12px"), class("muted")], [
      html.text(entry.remember),
    ]),
  ]
}

// READING PLAN ----------------------------------------------------------------

const repositories = [
  #("sinal", "https://github.com/gleam-dream/sinal"),
  #("json_blueprint", "https://github.com/gleam-dream/json_blueprint"),
  #("http_gun", "https://github.com/gleam-dream/http_gun"),
  #("llm_wire", "https://github.com/gleam-dream/llm_wire"),
  #("relay", "https://github.com/gleam-dream/relay"),
  #("hellhound", "https://github.com/gleam-dream/hellhound"),
  #("correio", "https://github.com/gleam-dream/correio"),
  #("grind", "https://github.com/gleam-dream/grind"),
  #("saga", "https://github.com/gleam-dream/saga"),
  #("fabric", "https://github.com/gleam-dream/fabric"),
  #("decisions", "https://github.com/gleam-dream/decisions"),
  #("retrace", "https://github.com/gleam-dream/retrace"),
]

fn reading_plan() -> Element(Msg) {
  let day = fn(when, title, body) {
    html.div([class("card")], [
      html.div([class("meta")], [html.text(when)]),
      html.h3([css("font-size:19px;margin:8px 0")], [html.text(title)]),
      html.p([class("muted"), css("font-size:15px")], [html.text(body)]),
    ])
  }
  html.section(
    [class("wrap sec")],
    list.append(
      section_head("Where next", "A reading plan for your first week"),
      [
        html.div(
          [
            css(
              "display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;margin-top:24px",
            ),
          ],
          [
            day(
              "day 1",
              "Oversight README and app catalogue",
              "Pick the example closest to your work. Run its tests.",
            ),
            day(
              "day 2",
              "That app's main package READMEs",
              "Read \"When to use\", \"Capabilities\" and \"Operational limits\" first. That's the mental model in prose.",
            ),
            day(
              "day 3",
              "The design documents",
              "Each package keeps a design document under docs/design describing ownership and contracts.",
            ),
            day(
              "day 4+",
              "The compiled examples",
              "Every README excerpt comes from an examples folder that the build checks. Change one and run it.",
            ),
          ],
        ),
        html.div([class("row"), css("gap:8px;margin-top:20px")], [
          html.span([class("meta")], [html.text("Repositories")]),
          ..list.map(repositories, fn(repo) {
            ui.external(repo.1, [class("pill")], [html.text(repo.0)])
          })
        ]),
        html.div([class("key")], [
          html.div([class("k")], [html.text("The one-sentence version, again")]),
          html.p([], [
            html.text(
              "The BEAM gives you isolated processes, OTP turns failure into restarts, Gleam adds types, and gleam-dream adds twelve focused libraries that each own one mechanism while your application keeps every decision.",
            ),
          ]),
        ]),
      ],
    ),
  )
}
