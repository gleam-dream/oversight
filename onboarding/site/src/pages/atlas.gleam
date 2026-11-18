//// Module 5, the package atlas: every package on one layered map, with a
//// filter by need, dependency highlighting and a detail panel.

import gleam/int
import gleam/list
import gleam/result
import lustre
import lustre/attribute.{class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import pages/atlas/packages.{
  type Filter, type Layer, type Need, type Package, BuildsOn, Everything,
  IsSelected, Serving, Unrelated, UsesIt,
}
import site/context.{type Context}
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  Map
}

pub type Model {
  Model(selected: Package, filter: Filter, tours: tour.Tours(TourId))
}

pub type Msg {
  ReaderPickedPackage(Package)
  /// Filter the map by a need and select the first package that serves it.
  ReaderPickedNeed(Need)
  ReaderShowedEverything
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(selected: packages.Fabric, filter: Everything, tours: tour.new())
}

// UPDATE ----------------------------------------------------------------------

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  case msg {
    ReaderPickedPackage(package) -> #(
      Model(..model, selected: package),
      effect.none(),
    )
    ReaderPickedNeed(need) -> #(
      Model(
        ..model,
        filter: Serving(need),
        selected: packages.first_serving(need)
          |> result.unwrap(model.selected),
      ),
      effect.none(),
    )
    ReaderShowedEverything -> #(
      Model(..model, filter: Everything),
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

/// This page has no real-time widgets.
pub fn register() -> Result(Nil, lustre.Error) {
  Ok(Nil)
}

fn driver(context: Context) -> tour.Driver(TourId, Model, Msg) {
  tour.Driver(
    script:,
    key: fn(_) { "atlas" },
    tours: fn(model: Model) { model.tours },
    set_tours: fn(model, tours) { Model(..model, tours:) },
    run: fn(model, msg) { update(model, msg, context) },
    to_msg: Tour,
  )
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  case id {
    Map ->
      tour.Script(
        reset: fn(_) {
          [ReaderPickedPackage(packages.Fabric), ReaderShowedEverything]
        },
        steps: [
          tour.say(
            "Twelve libraries and three tools, one row per layer. Lower rows are used by higher ones, never the other way round.",
          ),
          tour.act(
            "Sinal, at the bottom. The dashed tiles all use it: eight libraries emit Sinal events.",
            fn(_) { [ReaderPickedPackage(packages.Sinal)] },
          ),
          tour.act(
            "Fabric, near the top. The outlined tiles are what it builds on: HTTP Gun, JSON Blueprint, LLM Wire and Sinal.",
            fn(_) { [ReaderPickedPackage(packages.Fabric)] },
          ),
          tour.act(
            "Or start from the job. \"Call an LLM\" lights up LLM Wire, and everything else fades.",
            fn(_) { [ReaderPickedNeed(packages.CallModel)] },
          ),
          tour.act("\"Let a person decide\" leads to Decisions.", fn(_) {
            [ReaderPickedNeed(packages.PersonDecides)]
          }),
          tour.act(
            "Find a package by the job it does and the layer it sits on. Explore freely.",
            fn(_) { [ReaderShowedEverything] },
          ),
        ],
      )
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model, context: Context) -> Element(Msg) {
  element.fragment([
    hero(),
    html.section([class("wrap sec")], [
      tour.lab(
        model.tours,
        Map,
        driver(context),
        context,
        [css("margin-top:0")],
        [
          html.div([class("labh")], [
            html.div([], [
              html.span([class("tag")], [html.text("Playground")]),
              html.h2([css("font-size:28px;margin-top:10px")], [
                html.text("The map"),
              ]),
              html.p([class("muted"), css("margin-top:6px")], [
                html.text(
                  "Filter by what you need to do, or pick a package. Outlined tiles are what it builds on; dashed tiles use it.",
                ),
              ]),
            ]),
          ]),
          html.div([class("meta"), css("margin-bottom:8px")], [
            html.text("I need to…"),
          ]),
          html.div(
            [class("row"), css("gap:6px;margin-bottom:24px")],
            need_buttons(model.filter),
          ),
          html.div([class("split"), css("align-items:flex-start")], [
            html.div(
              [
                css(
                  "flex:3 1 560px;display:flex;flex-direction:column;gap:10px",
                ),
              ],
              list.map(packages.layers, row(_, model)),
            ),
            html.div([css("flex:2 1 340px;min-width:0")], [
              detail(model.selected),
            ]),
          ]),
        ],
      ),
    ]),
    notice(),
  ])
}

fn hero() -> Element(Msg) {
  html.header([class("wrap"), css("padding-top:72px;padding-bottom:48px")], [
    html.div([class("k")], [html.text("Module 5 · Phase 2: the mental model")]),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:900px")],
      [html.text("The package atlas")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "Twelve libraries and three tools on one map, arranged by layer. Lower layers are used by higher ones, never the other way round. Click any package to see what it owns, what it leaves to you, what it builds on, and where it shows up in real applications.",
      ),
    ]),
  ])
}

fn need_buttons(filter: Filter) -> List(Element(Msg)) {
  let button = fn(label, on, msg) {
    html.button(
      [
        attribute.type_("button"),
        ui.on_class("btn sm", on),
        ui.pressed(on),
        event.on_click(msg),
      ],
      [html.text(label)],
    )
  }
  [
    button(
      packages.everything_label,
      filter == Everything,
      ReaderShowedEverything,
    ),
    ..list.map(packages.needs, fn(need) {
      button(
        packages.need_label(need),
        filter == Serving(need),
        ReaderPickedNeed(need),
      )
    })
  ]
}

fn row(layer: Layer, model: Model) -> Element(Msg) {
  let look = packages.look(layer)
  html.div(
    [
      css(
        "display:flex;flex-wrap:wrap;gap:10px;align-items:stretch;padding:12px;border-radius:16px;background:"
        <> look.band,
      ),
    ],
    [
      html.div(
        [
          css(
            "width:132px;display:flex;flex-direction:column;justify-content:center",
          ),
        ],
        [
          html.span(
            [
              class("mono"),
              css(
                "font-size:11px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:"
                <> look.ink,
              ),
            ],
            [html.text(look.name)],
          ),
          html.span(
            [css("font-size:12px;color:" <> look.ink <> ";opacity:.85")],
            [
              html.text(look.sub),
            ],
          ),
        ],
      ),
      ..list.map(packages.in_layer(layer), tile(_, model))
    ],
  )
}

fn tile(package: Package, model: Model) -> Element(Msg) {
  let p = packages.info(package)
  let relation = packages.relation(model.selected, package)
  let highlight = packages.look(packages.info(model.selected).layer).ink
  let #(rel, border_colour, border_style, shadow) = case relation {
    IsSelected -> #("selected", "#17162B", "solid", "0 5px 0 #17162B")
    BuildsOn -> #("builds on", highlight, "solid", "none")
    UsesIt -> #("uses it", highlight, "dashed", "none")
    Unrelated -> #("", "#E4E0D8", "solid", "none")
  }
  let opacity = case packages.serves(package, model.filter) {
    True -> "1"
    False -> "0.35"
  }
  html.button(
    [
      attribute.type_("button"),
      event.on_click(ReaderPickedPackage(package)),
      ui.pressed(relation == IsSelected),
      css(
        "flex:1 1 150px;text-align:left;font:inherit;cursor:pointer;border-radius:12px;padding:12px 14px;min-height:46px;background:#FFFFFF;color:#17162B;border:2px "
        <> border_style
        <> " "
        <> border_colour
        <> ";opacity:"
        <> opacity
        <> ";box-shadow:"
        <> shadow
        <> ";display:flex;flex-direction:column;gap:4px",
      ),
    ],
    [
      html.span(
        [
          css(
            "display:flex;justify-content:space-between;gap:8px;align-items:center",
          ),
        ],
        [
          html.b([css("font:600 16px 'Space Grotesk',sans-serif")], [
            html.text(p.name),
          ]),
          html.span([class("mono"), css("font-size:10px;color:#5B5970")], [
            html.text(rel),
          ]),
        ],
      ),
      html.span(
        [
          class("tour-hide"),
          css("font-size:13px;color:#5B5970;line-height:1.35"),
        ],
        [html.text(p.tiny)],
      ),
    ],
  )
}

const label_style =
  "font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;margin-bottom:6px"

fn detail(package: Package) -> Element(Msg) {
  let p = packages.info(package)
  let look = packages.look(p.layer)
  let dep_names = list.map(p.deps, fn(d) { packages.info(d).name })
  let dep_none = case dep_names {
    [] -> "Nothing else in gleam-dream"
    _ -> ""
  }
  let apps_none = case p.apps, p.layer {
    [_, ..], _ -> ""
    [], packages.Tooling -> "Used to build and run them"
    [], _ -> "None yet"
  }
  html.div(
    [
      css(
        "border-radius:20px;padding:26px;background:"
        <> look.tint
        <> ";color:"
        <> look.ink
        <> ";display:flex;flex-direction:column;gap:14px",
      ),
    ],
    [
      html.div([class("row"), css("justify-content:space-between")], [
        html.span([class("k"), css("color:inherit")], [html.text(look.name)]),
        html.span([class("chip"), css("background:#FFFFFF;color:#17162B")], [
          html.text(p.status),
        ]),
      ]),
      html.h3([css("font-size:32px")], [html.text(p.name)]),
      html.p([css("font-size:16px")], [html.text(p.one)]),
      arrows("It owns", p.owns),
      arrows("You own", p.you),
      chips(
        "Builds on",
        dep_names,
        "background:#FFFFFF;color:#17162B",
        dep_none,
      ),
      chips(
        "Seen in example apps",
        p.apps,
        "background:rgba(255,255,255,.7);color:#17162B",
        apps_none,
      ),
      html.div(
        [
          class("tour-hide"),
          css(
            "font-size:14px;border-top:1px solid currentColor;padding-top:12px",
          ),
        ],
        [html.b([], [html.text("Not for:")]), html.text(" " <> p.not_for)],
      ),
      ui.external(
        p.repo,
        [
          class("tour-hide"),
          css("color:inherit;font-weight:700;font-size:14px"),
        ],
        [html.text("Open the repository →")],
      ),
    ],
  )
}

fn arrows(label: String, items: List(String)) -> Element(Msg) {
  html.div([], [
    html.div([class("mono"), css(label_style)], [html.text(label)]),
    ..list.map(items, fn(x) {
      html.div([css("font-size:14px;margin-bottom:4px")], [
        html.text("→ " <> x),
      ])
    })
  ])
}

fn chips(
  label: String,
  items: List(String),
  chip_style: String,
  none: String,
) -> Element(Msg) {
  html.div([], [
    html.div([class("mono"), css(label_style)], [html.text(label)]),
    html.div([class("row"), css("gap:6px")], [
      element.fragment(
        list.map(items, fn(x) {
          html.span([class("chip"), css(chip_style)], [html.text(x)])
        }),
      ),
      html.span([css("font-size:14px")], [html.text(none)]),
    ]),
  ])
}

fn notice() -> Element(Msg) {
  let card = fn(chip_style, chip, title, body) {
    html.div([class("card")], [
      html.span([class("chip"), css(chip_style)], [html.text(chip)]),
      html.h3([], [html.text(title)]),
      html.p([], body),
    ])
  }
  let sinal_count = list.length(packages.used_by(packages.Sinal))
  html.section([class("wrap sec")], [
    html.div([class("k")], [html.text("Read · what the map tells you")]),
    html.h2([class("h2")], [html.text("Three things to notice")]),
    html.div([class("cards")], [
      card(
        "background:#DDF3F0;color:#0B4A45",
        "Sinal",
        "Observability is built in",
        [
          html.text(
            int.to_string(sinal_count)
            <> " of the 11 other libraries emit Sinal events. Attach observers once and you can see inside HTTP calls, jobs, workflows and agents alike.",
          ),
        ],
      ),
      card(
        "background:#DDF3F0;color:#0B4A45",
        "JSON Blueprint",
        "Data crossing a boundary is typed",
        [
          html.text(
            "Wherever data meets a model, a protocol or a stored record (LLM Wire, Relay, Fabric, Decisions), JSON Blueprint codecs describe its shape and generate the schema.",
          ),
        ],
      ),
      card(
        "background:#E0E9FD;color:#163A8A",
        "HTTP Gun",
        "One door to the network",
        [
          html.text(
            "LLM Wire, Relay, Hellhound and Fabric all reach the network through an HTTP Gun client that ",
          ),
          html.i([], [html.text("your")]),
          html.text(
            " application starts. One place to set limits and destination rules.",
          ),
        ],
      ),
    ]),
    html.div([class("note"), css("margin-top:16px")], [
      html.b([], [html.text("Storage is opt-in.")]),
      html.text(
        " Most libraries run in memory out of the box. PostgreSQL support comes as separate adapter packages (Saga, Fabric, Hellhound, Correio and Decisions each have one), and they borrow your connection pool. Grind is the exception: it is built on PostgreSQL.",
      ),
    ]),
    ui.carry_forward(
      "Find a package by the job it does and the layer it sits on. Lower layers are shared plumbing; higher layers coordinate work, and your application sits on top of them all.",
    ),
  ])
}
