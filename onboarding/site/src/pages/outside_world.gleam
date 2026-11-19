//// Module 7, the outside world: LLM Wire, Relay, Hellhound and Correio as
//// step-through sequence charts with options that change each flow's path.

import gleam/int
import gleam/list
import lustre
import lustre/attribute.{class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import pages/outside_world/flows.{type Choice, type Flow, type Walk}
import site/context.{type Context}
import site/msc
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  Flows
}

pub type Model {
  Model(walk: Walk, tours: tour.Tours(TourId))
}

pub type Msg {
  ReaderPickedFlow(Flow)
  ReaderChose(Choice)
  ReaderSteppedBack
  ReaderSteppedForward
  ReaderShowedAll
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(walk: flows.start, tours: tour.new())
}

// UPDATE ----------------------------------------------------------------------

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  let walk = model.walk
  let walked = fn(walk) { #(Model(..model, walk:), effect.none()) }
  case msg {
    ReaderPickedFlow(flow) -> walked(flows.pick_flow(walk, flow))
    ReaderChose(choice) -> walked(flows.flip(walk, choice))
    ReaderSteppedBack -> walked(flows.back(walk))
    ReaderSteppedForward -> walked(flows.forward(walk))
    ReaderShowedAll -> walked(flows.show_all(walk))
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
    key: fn(_) { "flows" },
    tours: fn(model: Model) { model.tours },
    set_tours: fn(model, tours) { Model(..model, tours:) },
    run: fn(model, msg) { update(model, msg, context) },
    to_msg: Tour,
  )
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  case id {
    Flows ->
      tour.Script(
        reset: fn(_) {
          [
            ReaderPickedFlow(flows.LlmWireFlow),
            ..list.map(flows.as_choices(flows.default_choices), ReaderChose)
          ]
        },
        steps: [
          tour.say(
            "Four libraries at the edge of your service. Each column is a participant, each arrow a message, time flows down. Colours show who owns the step: amber your app, violet the library.",
          ),
          tour.act(
            "LLM Wire. Your app builds a request; prepare validates and encodes it with no network at all; then one bounded call goes out through HTTP Gun.",
            fn(_) {
              [
                ReaderPickedFlow(flows.LlmWireFlow),
                ReaderSteppedForward,
                ReaderSteppedForward,
              ]
            },
          ),
          tour.act(
            "The model asks for a tool. Watch the arrows return to your app: you authorize and run every tool, then call again. The loop is yours.",
            fn(_) { [ReaderShowedAll] },
          ),
          tour.act(
            "Relay without a valid token: the request is rejected at admission and never reaches a handler.",
            fn(_) {
              [
                ReaderPickedFlow(flows.RelayFlow),
                ReaderChose(flows.ChooseToken(flows.MissingToken)),
                ReaderShowedAll,
              ]
            },
          ),
          tour.act(
            "Hellhound: sign-in goes through the identity provider, Hellhound checks everything, and your app sets its own session cookie.",
            fn(_) { [ReaderPickedFlow(flows.HellhoundFlow), ReaderShowedAll] },
          ),
          tour.act(
            "Correio: a send can end in four ways. OutcomeUnknown is module 4’s MaybeSent again: don’t assume either way.",
            fn(_) {
              [
                ReaderPickedFlow(flows.CorreioFlow),
                ReaderChose(flows.ChooseOutcome(flows.OutcomeUnknown)),
                ReaderShowedAll,
              ]
            },
          ),
          tour.say(
            "Step through any flow and flip the options to explore other paths.",
          ),
        ],
      )
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model, context: Context) -> Element(Msg) {
  element.fragment([
    hero(),
    four_libraries(),
    html.section([class("wrap sec")], [
      tour.lab(
        model.tours,
        Flows,
        driver(context),
        context,
        [css("margin-top:0")],
        playground(model.walk),
      ),
    ]),
    shared_shape(),
  ])
}

fn hero() -> Element(Msg) {
  html.header([class("wrap"), css("padding-top:72px;padding-bottom:48px")], [
    html.div([class("k")], [
      html.text("Module 7 · Phase 3: the building blocks"),
    ]),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:940px")],
      [html.text("The outside world: models, tools, people, mail")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "Four libraries sit at the edge of your service, where it talks to something it doesn't control: a model provider, an agent calling your tools, an identity provider, a mail server. Each one shows the same habits from module 4: a typed boundary, explicit limits, honest outcomes, and your app in charge.",
      ),
    ]),
  ])
}

fn four_libraries() -> Element(Msg) {
  let card = fn(chip, title, body) {
    html.div([class("card")], [
      html.span([class("chip"), css("background:#EEE7FD;color:#3B1785")], [
        html.text(chip),
      ]),
      html.h3([], [html.text(title)]),
      html.p([], [html.text(body)]),
    ])
  }
  html.section([class("wrap sec")], [
    html.div([class("cards"), css("margin-top:0")], [
      card(
        "LLM Wire",
        "Talk to a model",
        "One typed, bounded call to OpenAI, Anthropic or Google. You own the loop around it.",
      ),
      card(
        "Relay",
        "Speak MCP",
        "Expose typed tools to agents, or call another MCP server, over HTTP or stdio.",
      ),
      card(
        "Hellhound",
        "Know who's there",
        "OIDC sign-in, OAuth tokens and JWT checks, through an identity provider you already use.",
      ),
      card(
        "Correio",
        "Send mail",
        "Transactional email and passwordless verification, kept deliberately separate.",
      ),
    ]),
  ])
}

fn playground(walk: Walk) -> List(Element(Msg)) {
  let script = flows.script(walk.flow, walk.choices)
  let current = flows.current(walk)
  let total = list.length(script.steps)
  [
    html.div([class("labh")], [
      html.div([], [
        html.span([class("tag")], [html.text("Playground")]),
        html.h2([css("font-size:28px;margin-top:10px")], [
          html.text("Step through each flow"),
        ]),
        html.p([class("muted"), css("margin-top:6px;max-width:680px")], [
          html.text(
            "Each column is a participant. Step forward to watch the message move. Flip the options to explore other paths. Tags show who owns each step.",
          ),
        ]),
      ]),
    ]),
    html.div(
      [class("seg"), css("margin-bottom:20px")],
      list.map(flows.flows, fn(flow) {
        segment(
          flows.flow_label(flow),
          flow == walk.flow,
          ReaderPickedFlow(flow),
        )
      }),
    ),
    html.p(
      [
        class("tour-hide"),
        css("font-size:16px;max-width:860px;margin-bottom:16px"),
      ],
      [html.text(script.intro)],
    ),
    html.div(
      [class("row"), css("gap:12px;margin-bottom:20px")],
      list.map(flows.option_rows(walk.flow, walk.choices), option_row(_, walk)),
    ),
    msc.view(flows.chart(walk)),
    step_box(walk),
    html.div(
      [class("row"), css("margin-top:20px;justify-content:space-between")],
      [
        html.div([class("row")], [
          html.button(
            [
              attribute.type_("button"),
              class("btn"),
              event.on_click(ReaderSteppedBack),
              attribute.disabled(current <= 1),
            ],
            [html.text("← Back")],
          ),
          html.button(
            [
              attribute.type_("button"),
              class("btn pri"),
              event.on_click(ReaderSteppedForward),
              attribute.disabled(current >= total),
            ],
            [html.text("Next step →")],
          ),
          html.button(
            [
              attribute.type_("button"),
              class("btn sm"),
              event.on_click(ReaderShowedAll),
            ],
            [html.text("Show all")],
          ),
        ]),
        html.span([class("meta")], [
          html.text(
            "step " <> int.to_string(current) <> " of " <> int.to_string(total),
          ),
        ]),
      ],
    ),
    html.div([class("note tour-hide"), css("margin-top:16px")], [
      html.b([], [html.text("Takeaway:")]),
      html.text(" " <> script.takeaway),
    ]),
  ]
}

fn segment(label: String, on: Bool, msg: Msg) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      ui.on_class("", on),
      ui.pressed(on),
      event.on_click(msg),
    ],
    [html.text(label)],
  )
}

fn option_row(row: flows.OptionRow, walk: Walk) -> Element(Msg) {
  html.div([class("row"), css("gap:8px")], [
    html.span([class("meta")], [html.text(row.label)]),
    html.div(
      [class("seg")],
      list.map(row.choices, fn(choice) {
        let #(label, choice) = choice
        segment(
          label,
          flows.is_chosen(walk.choices, choice),
          ReaderChose(choice),
        )
      }),
    ),
  ])
}

fn step_box(walk: Walk) -> Element(Msg) {
  case flows.current_step(walk) {
    Error(Nil) -> element.none()
    Ok(step) -> {
      let look = flows.look(step.owner)
      html.div(
        [
          class("box"),
          css("margin-top:14px;background:#FFFFFF;border:2px solid #17162B"),
        ],
        [
          html.div([class("row"), css("justify-content:space-between")], [
            html.b([css("font-size:17px")], [
              html.text(
                int.to_string(flows.current(walk)) <> ". " <> step.title,
              ),
            ]),
            html.span(
              [
                class("chip"),
                css("background:" <> look.background <> ";color:" <> look.ink),
              ],
              [html.text(look.label)],
            ),
          ]),
          html.p([css("font-size:15px;margin-top:6px")], [html.text(step.text)]),
        ],
      )
    }
  }
}

/// The comparison table: rows of traits, one column per library.
const shape = [
  #("Typed boundary", [
    "answer and tool codecs",
    "one tool definition, both sides",
    "checked identity, decoded claims",
    "validated message values",
  ]),
  #("Bounded", [
    "call, first-progress, idle timeouts",
    "deadlines, bounded listings",
    "one request per exchange call",
    "bounded SMTP, bounded capture",
  ]),
  #("Honest outcome", [
    "send evidence, retry advice",
    "succeeded, refused or needs input",
    "no-send vs maybe-sent",
    "Accepted, NotSent, Rejected, OutcomeUnknown",
  ]),
  #("Your app owns", [
    "history, tools, retries",
    "handlers, verifier, policy",
    "accounts, cookies, permissions",
    "templates, what verification unlocks",
  ]),
  #("Network via", [
    "your HTTP Gun client",
    "HTTP Gun (client), mist (server)",
    "HTTP Gun",
    "gen_smtp or the Postmark adapter",
  ]),
]

fn shared_shape() -> Element(Msg) {
  let cell = "padding:12px;text-align:left;vertical-align:top;"
  let head = fn(text) {
    html.th(
      [
        attribute.scope("col"),
        css(cell <> "background:#F1EEE8;font-weight:600"),
      ],
      [html.text(text)],
    )
  }
  html.section([class("wrap sec")], [
    html.div([class("k")], [html.text("Read · the shape they share")]),
    html.h2([class("h2")], [html.text("Same edges, same rules")]),
    html.div([css("overflow-x:auto;margin-top:24px")], [
      html.div(
        [
          css(
            "min-width:760px;background:#E4E0D8;border-radius:14px;overflow:hidden;font-size:14px",
          ),
        ],
        [
          html.table(
            [
              css(
                "width:100%;border-collapse:separate;border-spacing:1px;table-layout:fixed",
              ),
            ],
            [
              html.thead([], [
                html.tr([], [
                  html.td([css(cell <> "background:#F1EEE8;width:21.5%")], []),
                  ..list.map(flows.flows, fn(flow) {
                    head(flows.flow_label(flow))
                  })
                ]),
              ]),
              html.tbody(
                [],
                list.map(shape, fn(row) {
                  let #(trait, cells) = row
                  html.tr([], [
                    html.th(
                      [
                        attribute.scope("row"),
                        css(cell <> "background:#fff;font-weight:600"),
                      ],
                      [html.text(trait)],
                    ),
                    ..list.map(cells, fn(text) {
                      html.td([css(cell <> "background:#fff")], [
                        html.text(text),
                      ])
                    })
                  ])
                }),
              ),
            ],
          ),
        ],
      ),
    ]),
    html.div([class("note"), css("margin-top:16px")], [
      html.b([], [html.text("Making edges durable.")]),
      html.text(
        " None of these four retries on its own or keeps an outbox. When a model call, a webhook or an email must survive a crash, wrap it in a ",
      ),
      html.b([], [html.text("Grind")]),
      html.text(" job or a "),
      html.b([], [html.text("Saga")]),
      html.text(" step. That's module 8."),
    ]),
    ui.carry_forward(
      "At every edge, the library speaks the protocol and reports the truth. Your app decides who may act, what the result means, and what to try next.",
    ),
  ])
}
