//// Module 3, Gleam: impossible states, the Result railway and typed
//// mailboxes, each as a playground.

import gleam/int
import gleam/list
import gleam/set
import lustre
import lustre/attribute.{class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import pages/gleam_lang/cart.{type Candidate, type Sent}
import pages/gleam_lang/order.{
  type Business, type Field, type LooseOrder, type Status, DisputedAdded, Empty,
  LooseOrder, Paid, Refunded, Set, ThreeStates,
}
import pages/gleam_lang/railway.{type Failures}
import site/context.{type Context}
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  TypesTour
  RailTour
  MessagesTour
}

pub type Model {
  Model(
    loose: LooseOrder,
    variant: Status,
    business: Business,
    failures: Failures,
    sent: Sent,
    tours: tour.Tours(TourId),
  )
}

pub type Msg {
  ReaderPickedLooseStatus(Status)
  ReaderToggledReceipt
  ReaderToggledRefund
  ReaderPickedVariant(Status)
  ReaderToggledDisputed
  ReaderToggledStep(railway.Step)
  ReaderClearedFailures
  ReaderSentToCart(Candidate)
  ReaderClearedMailboxes
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(
    loose: LooseOrder(status: Refunded, receipt: Empty, refund: Set),
    variant: Paid,
    business: ThreeStates,
    failures: railway.none(),
    sent: [],
    tours: tour.new(),
  )
}

// UPDATE ----------------------------------------------------------------------

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  let loose = model.loose
  let model = case msg {
    ReaderPickedLooseStatus(status) ->
      Model(..model, loose: LooseOrder(..loose, status:))
    ReaderToggledReceipt ->
      Model(
        ..model,
        loose: LooseOrder(..loose, receipt: order.toggle(loose.receipt)),
      )
    ReaderToggledRefund ->
      Model(
        ..model,
        loose: LooseOrder(..loose, refund: order.toggle(loose.refund)),
      )
    ReaderPickedVariant(variant) -> Model(..model, variant:)
    ReaderToggledDisputed ->
      Model(..model, business: case model.business {
        ThreeStates -> DisputedAdded
        DisputedAdded -> ThreeStates
      })
    ReaderToggledStep(step) ->
      Model(..model, failures: railway.toggle(model.failures, step))
    ReaderClearedFailures -> Model(..model, failures: railway.none())
    ReaderSentToCart(candidate) ->
      Model(..model, sent: cart.send(model.sent, candidate))
    ReaderClearedMailboxes -> Model(..model, sent: [])
    Tour(..) -> model
  }
  case msg {
    Tour(id, command) ->
      tour.update(driver(context), model, id, command, context.motion)
    _ -> #(model, effect.none())
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
    key: fn(id) {
      case id {
        TypesTour -> "types"
        RailTour -> "rail"
        MessagesTour -> "msgs"
      }
    },
    tours: fn(model: Model) { model.tours },
    set_tours: fn(model, tours) { Model(..model, tours:) },
    run: fn(model, msg) { update(model, msg, context) },
    to_msg: Tour,
  )
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  case id {
    TypesTour ->
      tour.Script(
        reset: fn(model: Model) {
          list.flatten([
            loose_to(model, Refunded, Empty, Set),
            [ReaderPickedVariant(Paid)],
            case model.business {
              DisputedAdded -> [ReaderToggledDisputed]
              ThreeStates -> []
            },
          ])
        },
        steps: [
          tour.say(
            "The same order modelled two ways: a loose record of optional fields on the left, a custom type with one variant per state on the right.",
          ),
          tour.act(
            "Loose: status \"paid\" with a receipt and no refund. It makes sense, but only by luck. Nothing enforced it.",
            loose_to(_, Paid, Set, Empty),
          ),
          tour.act(
            "Now \"refunded\" with no receipt: refunded but never paid. The program accepts it happily. That’s a bug waiting for production.",
            loose_to(_, Refunded, Empty, Set),
          ),
          tour.act(
            "Typed: choose the Refunded variant. It must carry both a receipt and a refund, so the nonsense order simply can’t be built.",
            fn(_) { [ReaderPickedVariant(Refunded)] },
          ),
          tour.act(
            "The business adds a Disputed state. Loose model: zero warnings. Custom type: three compile errors, one for every place that must handle it.",
            fn(model: Model) {
              case model.business {
                ThreeStates -> [ReaderToggledDisputed]
                DisputedAdded -> []
              }
            },
          ),
          tour.say(
            "Make the compiler your first reviewer. Now try building nonsense on each side yourself.",
          ),
        ],
      )
    RailTour ->
      tour.Script(reset: fn(_) { [ReaderClearedFailures] }, steps: [
        tour.say(
          "Five steps to place an order. Each one returns Ok(value) or Error(reason).",
        ),
        tour.act(
          "When every step succeeds, the value rides the happy track to the end: Ok(receipt).",
          fn(_) { [ReaderClearedFailures] },
        ),
        tour.act(
          "Make \"Reserve stock\" fail: Error(OutOfStock) switches to the error track, and steps 4 and 5 never run.",
          fn(_) { [ReaderToggledStep(railway.ReserveStock)] },
        ),
        tour.act(
          "Now the charge fails instead. Notice the stock is already reserved: undoing earlier steps is Saga’s job, in module 8.",
          fn(_) {
            [ReaderClearedFailures, ReaderToggledStep(railway.ChargeCard)]
          },
        ),
        tour.say(
          "Errors are values, and the function’s type lists them. Flip the steps yourself.",
        ),
      ])
    MessagesTour ->
      tour.Script(reset: fn(_) { [ReaderClearedMailboxes] }, steps: [
        tour.say(
          "The cart only understands CartMessage: AddItem, RemoveItem and GetTotal. Watch both mailboxes as we send.",
        ),
        tour.act("Send AddItem(Pen). Both worlds accept and handle it.", fn(_) {
          [ReaderSentToCart(cart.AddItem)]
        }),
        tour.act(
          "Send ChargeCard(€20), a payment message, to the cart. Erlang accepts it and fails later at runtime. Gleam refuses to compile.",
          fn(_) { [ReaderSentToCart(cart.ChargeCard)] },
        ),
        tour.act(
          "Even a plain \"hello\" is caught before the program ever runs.",
          fn(_) { [ReaderSentToCart(cart.Hello)] },
        ),
        tour.say(
          "Typed mailboxes turn mystery crashes into compile errors. Send whatever you like now.",
        ),
      ])
  }
}

/// The reader's own verbs that bring the loose record to this combination.
fn loose_to(
  model: Model,
  status: Status,
  receipt: Field,
  refund: Field,
) -> List(Msg) {
  list.flatten([
    [ReaderPickedLooseStatus(status)],
    case model.loose.receipt == receipt {
      True -> []
      False -> [ReaderToggledReceipt]
    },
    case model.loose.refund == refund {
      True -> []
      False -> [ReaderToggledRefund]
    },
  ])
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model, context: Context) -> Element(Msg) {
  let lab = fn(id, children) {
    tour.lab(model.tours, id, driver(context), context, [], children)
  }
  element.fragment([
    hero(),
    ideas(),
    html.section([class("wrap sec")], [
      lab(TypesTour, types_playground(model)),
    ]),
    html.section([class("wrap sec")], [
      html.div([class("k")], [html.text("Read · errors are values")]),
      html.h2([class("h2")], [html.text("The Result railway")]),
      html.p([class("lead")], [
        html.text(
          "Each step returns Ok or Error. Steps chain along the happy track, and the first error switches to the error track, skipping the rest. The function's type tells every caller exactly how it can fail.",
        ),
      ]),
      lab(RailTour, rail_playground(model.failures)),
    ]),
    html.section([class("wrap sec")], [
      html.div([class("k")], [html.text("Read · typed messages")]),
      html.h2([class("h2")], [html.text("Mailboxes with a type")]),
      html.p([class("lead")], [
        html.text(
          "In Erlang any process can send anything to anyone. In Gleam you send to a ",
        ),
        html.b([], [html.text("Subject")]),
        html.text(
          ": an address that only accepts one message type. Wrong messages become compile errors instead of mystery crashes.",
        ),
      ]),
      lab(MessagesTour, messages_playground(model.sent)),
    ]),
    wrappers(),
  ])
}

fn hero() -> Element(Msg) {
  html.header([class("wrap"), css("padding-top:72px;padding-bottom:56px")], [
    html.div([class("k")], [html.text("Module 3 · Phase 1: the runtime")]),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:900px")],
      [html.text("Gleam: types on the BEAM")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "Gleam is a friendly, statically typed language that compiles to Erlang (and to JavaScript). You keep everything the BEAM and OTP give you, and the compiler catches whole classes of mistakes before the code ever runs. Every gleam-dream library is written in Gleam 1.18 or later and targets Erlang.",
      ),
    ]),
    html.div([class("card"), css("margin-top:32px;max-width:760px")], [
      html.div([class("k"), css("color:#5B5970")], [
        html.text("By the end you can explain"),
      ]),
      html.div(
        [css("display:flex;flex-direction:column;gap:6px;margin-top:10px")],
        list.map(
          [
            "→ how Gleam models data so impossible states can't even be built",
            "→ why errors are ordinary values, and what that means for library APIs",
            "→ how typed messages make actors safer than plain Erlang",
          ],
          fn(line) { html.span([], [html.text(line)]) },
        ),
      ),
    ]),
  ])
}

fn ideas() -> Element(Msg) {
  let idea = fn(chip, title, body) {
    html.div([class("card")], [
      html.span([class("chip"), css("background:#F9D7F0;color:#4A1340")], [
        html.text(chip),
      ]),
      html.h3([], [html.text(title)]),
      html.p([], [html.text(body)]),
    ])
  }
  html.section([class("wrap sec")], [
    html.div([class("k")], [html.text("Read · six ideas")]),
    html.h2([class("h2")], [html.text("What Gleam adds on top of the BEAM")]),
    html.div([class("cards")], [
      idea(
        "custom types",
        "One type, several shapes",
        "A type can have variants, each carrying exactly the data that case needs. \"Paid\" holds a receipt. \"Pending\" holds nothing.",
      ),
      idea(
        "pattern matching",
        "Every case handled",
        "When you branch on a type, the compiler checks you covered every variant. Add a new one and it shows you every place to update.",
      ),
      idea(
        "Result",
        "Errors are values",
        "A function that can fail returns either Ok(value) or Error(reason). No hidden exceptions: failure is written in the type.",
      ),
      idea(
        "Option",
        "No null",
        "\"Maybe there's a value\" is explicit: Some(value) or None. You can't forget to check, because the compiler won't let you.",
      ),
      idea(
        "immutability",
        "Values never change",
        "Updating means making a new value. That fits actors perfectly: the next state is simply the value the handler returns.",
      ),
      idea(
        "interop",
        "The whole BEAM is yours",
        "Gleam calls Erlang and Elixir libraries directly. gleam-dream wraps a few proven ones, like Gun and telemetry, behind typed APIs.",
      ),
    ]),
  ])
}

fn labh(title: String, body: String, body_style: String) -> Element(Msg) {
  html.div([], [
    html.span([class("tag")], [html.text("Playground")]),
    html.h2([css("font-size:28px;margin-top:10px")], [html.text(title)]),
    html.p([class("muted"), css(body_style)], [html.text(body)]),
  ])
}

fn toggle_button(on: Bool, msg: Msg, label: String) -> Element(Msg) {
  html.button(
    [attribute.type_("button"), ui.on_class("btn", on), event.on_click(msg)],
    [html.text(label)],
  )
}

// IMPOSSIBLE STATES -----------------------------------------------------------

fn types_playground(model: Model) -> List(Element(Msg)) {
  let loose = model.loose
  let #(verdict, why, bg, fg) = case order.judge(loose) {
    order.ValidByLuck -> #(
      "Accepted. Valid by luck.",
      "This one happens to make sense. Nothing stopped the other eleven.",
      "#F1EEE8",
      "#17162B",
    )
    order.BugWaiting(why:) -> #(
      "Accepted. A bug waiting to happen.",
      why,
      "#FDECEA",
      "#7A1A12",
    )
  }
  let disputed = model.business == DisputedAdded
  [
    html.div([class("labh")], [
      labh(
        "Make impossible states impossible",
        "The same order modelled two ways. On the left, a loose record of optional fields. On the right, a custom type with one variant per state. Try to build a nonsense order on each side.",
        "margin-top:6px;max-width:680px",
      ),
    ]),
    html.div([class("split")], [
      html.div([class("box"), css("padding:22px")], [
        html.div([class("meta")], [
          html.text("Loose record · status text + optional fields"),
        ]),
        html.div(
          [css("display:flex;flex-direction:column;gap:14px;margin-top:14px")],
          [
            html.div([], [
              html.div([class("meta"), css("margin-bottom:6px")], [
                html.text("status"),
              ]),
              html.div(
                [class("seg")],
                list.map(order.statuses, fn(status) {
                  html.button(
                    [
                      attribute.type_("button"),
                      ui.on_class("", loose.status == status),
                      event.on_click(ReaderPickedLooseStatus(status)),
                    ],
                    [html.text(order.status_label(status))],
                  )
                }),
              ),
            ]),
            html.div([class("row")], [
              toggle_button(
                loose.receipt == Set,
                ReaderToggledReceipt,
                "receipt: " <> order.field_label(loose.receipt),
              ),
              toggle_button(
                loose.refund == Set,
                ReaderToggledRefund,
                "refund id: " <> order.field_label(loose.refund),
              ),
            ]),
            html.div(
              [
                css(
                  "border-radius:12px;padding:14px 16px;background:"
                  <> bg
                  <> ";color:"
                  <> fg,
                ),
              ],
              [
                html.b([], [html.text(verdict)]),
                html.div([css("font-size:14px;margin-top:4px")], [
                  html.text(why),
                ]),
              ],
            ),
            html.div([class("meta")], [
              html.text("12 possible combinations · only 3 make sense"),
            ]),
          ],
        ),
      ]),
      html.div(
        [
          class("box"),
          css("padding:22px;background:#FFF7FC;border-color:#F3C6E6"),
        ],
        [
          html.div([class("meta")], [
            html.text("Custom type · Order = Pending | Paid | Refunded"),
          ]),
          html.div(
            [css("display:flex;flex-direction:column;gap:10px;margin-top:14px")],
            list.append(
              list.map(order.statuses, variant_button(_, model.variant)),
              [
                html.div(
                  [
                    css(
                      "border-radius:12px;padding:14px 16px;background:#E2F4E7;color:#0E4D25",
                    ),
                  ],
                  [
                    html.b([], [html.text("Always valid.")]),
                    html.div([css("font-size:14px;margin-top:4px")], [
                      html.text(order.variant_why(model.variant)),
                    ]),
                  ],
                ),
                html.div([class("meta")], [
                  html.text("exactly 3 possible shapes · all 3 make sense"),
                ]),
              ],
            ),
          ),
        ],
      ),
    ]),
    html.div(
      [css("margin-top:24px;border-top:1px solid #E4E0D8;padding-top:20px")],
      [
        html.div([class("row"), css("justify-content:space-between")], [
          html.div([], [
            html.b([], [
              html.text("Now the business adds a new state: Disputed."),
            ]),
            html.text(" "),
            html.span([class("muted")], [
              html.text("What tells you which code needs to change?"),
            ]),
          ]),
          html.button(
            [
              attribute.type_("button"),
              class(case disputed {
                True -> "btn on"
                False -> "btn pri"
              }),
              event.on_click(ReaderToggledDisputed),
            ],
            [
              html.text(case disputed {
                True -> "Remove Disputed"
                False -> "Add the Disputed state"
              }),
            ],
          ),
        ]),
        case disputed {
          True -> disputed_outcome()
          False -> element.none()
        },
      ],
    ),
  ]
}

fn variant_button(status: Status, selected: Status) -> Element(Msg) {
  let border = case status == selected {
    True -> "#B0186E"
    False -> "#E4E0D8"
  }
  html.button(
    [
      attribute.type_("button"),
      event.on_click(ReaderPickedVariant(status)),
      css(
        "text-align:left;font:inherit;cursor:pointer;border-radius:12px;padding:12px 16px;border:2px solid "
        <> border
        <> ";background:#fff;color:#17162B;min-height:48px",
      ),
    ],
    [
      html.b([class("mono")], [html.text(order.variant_name(status))]),
      html.text(" "),
      html.span([class("muted"), css("font-size:14px")], [
        html.text(order.variant_fields(status)),
      ]),
    ],
  )
}

fn disputed_outcome() -> Element(Msg) {
  let mono = fn(text) { html.span([class("mono")], [html.text(text)]) }
  html.div([class("split"), css("margin-top:16px")], [
    html.div([class("box"), css("background:#FBF3F2;border-color:#E9B8B2")], [
      html.b([], [html.text("Loose record:")]),
      html.text(" the compiler sees a new piece of text. "),
      html.b([], [html.text("0 warnings.")]),
      html.text(
        " The receipt email, the refunds screen and the accounting export all quietly do the wrong thing. You find out in production.",
      ),
    ]),
    html.div([class("box"), css("background:#E2F4E7;border-color:#B9E2C4")], [
      html.b([], [html.text("Custom type:")]),
      html.text(" the build fails with "),
      html.b([], [html.text("3 clear errors")]),
      html.text(", one per place that matches on Order: "),
      mono("emails"),
      html.text(", "),
      mono("refunds_screen"),
      html.text(", "),
      mono("accounting_export"),
      html.text(". Fix them and ship."),
    ]),
  ])
}

// RESULT RAILWAY --------------------------------------------------------------

fn rail_playground(failures: Failures) -> List(Element(Msg)) {
  let outcome = railway.outcome(failures)
  let ok_pct = int.to_string(railway.ok_percent(outcome))
  let err_start = int.to_string(railway.error_start(outcome))
  let #(out_bg, out_fg) = case outcome {
    railway.AllOk -> #("#E2F4E7", "#0E4D25")
    railway.FailedAt(..) -> #("#FDECEA", "#7A1A12")
  }
  [
    html.div([class("labh")], [
      labh(
        "Place an order",
        "Make any step fail and follow the result.",
        "margin-top:6px",
      ),
      html.button(
        [
          attribute.type_("button"),
          class("btn sm"),
          event.on_click(ReaderClearedFailures),
        ],
        [html.text("All succeed")],
      ),
    ]),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px",
        ),
      ],
      list.index_map(railway.tracks(failures), fn(entry, index) {
        rail_step(index, entry.0, entry.1, set.contains(failures, entry.0))
      }),
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-top:16px",
        ),
      ],
      [
        html.div(
          [css("grid-column:1/-1;display:flex;flex-direction:column;gap:6px")],
          [
            html.div(
              [
                css(
                  "height:10px;border-radius:99px;background:linear-gradient(90deg,#15803D "
                  <> ok_pct
                  <> "%,#E4E0D8 "
                  <> ok_pct
                  <> "%)",
                ),
              ],
              [],
            ),
            html.div(
              [
                css(
                  "height:10px;border-radius:99px;background:linear-gradient(90deg,#E4E0D8 "
                  <> err_start
                  <> "%,#B42318 "
                  <> err_start
                  <> "%)",
                ),
              ],
              [],
            ),
            html.div([class("row"), css("justify-content:space-between")], [
              html.span([class("meta")], [
                html.text("happy track (Ok) on top · error track below"),
              ]),
              html.span(
                [
                  class("mono"),
                  css(
                    "font-weight:600;padding:6px 12px;border-radius:8px;background:"
                    <> out_bg
                    <> ";color:"
                    <> out_fg,
                  ),
                ],
                [html.text(railway.result_label(outcome))],
              ),
            ]),
          ],
        ),
      ],
    ),
    html.div([class("note"), css("margin-top:16px")], [
      html.text(railway.note(outcome)),
    ]),
  ]
}

fn rail_step(
  index: Int,
  step: railway.Step,
  track: railway.Track,
  failing: Bool,
) -> Element(Msg) {
  let #(state, bg, border, fg) = case track {
    railway.RanOk -> #("Ok → next step", "#E2F4E7", "#B9E2C4", "#0E4D25")
    railway.Failed -> #(
      "Error(" <> railway.error(step) <> ")",
      "#FDECEA",
      "#B42318",
      "#7A1A12",
    )
    railway.Skipped -> #("skipped: never runs", "#F1EEE8", "#E4E0D8", "#5B5970")
  }
  html.div([css("display:flex;flex-direction:column;gap:8px")], [
    html.div(
      [
        css(
          "border-radius:14px;padding:14px;min-height:120px;background:"
          <> bg
          <> ";border:2px solid "
          <> border
          <> ";color:"
          <> fg
          <> ";display:flex;flex-direction:column;gap:6px",
        ),
      ],
      [
        html.span([class("meta"), css("color:inherit;opacity:.8")], [
          html.text("step " <> int.to_string(index + 1)),
        ]),
        html.b([], [html.text(railway.name(step))]),
        html.span([css("font-size:13px")], [html.text(state)]),
      ],
    ),
    html.button(
      [
        attribute.type_("button"),
        class(case failing {
          True -> "btn sm on"
          False -> "btn sm warn"
        }),
        event.on_click(ReaderToggledStep(step)),
      ],
      [
        html.text(case failing {
          True -> "Make it succeed"
          False -> "Make it fail"
        }),
      ],
    ),
  ])
}

// TYPED MESSAGES --------------------------------------------------------------

fn messages_playground(sent: Sent) -> List(Element(Msg)) {
  let column = fn(box_style, title, verdict) {
    html.div([class("box"), box_style], [
      html.div([class("meta")], [html.text(title)]),
      html.div(
        [
          css(
            "display:flex;flex-direction:column;gap:6px;margin-top:10px;min-height:140px",
          ),
        ],
        list.map(sent, fn(candidate) {
          let #(note, bg) = verdict(candidate)
          html.div(
            [
              css(
                "padding:8px 12px;border-radius:10px;background:"
                <> bg
                <> ";font-size:14px",
              ),
            ],
            [
              html.b([class("mono")], [html.text(cart.label(candidate))]),
              html.text(" · " <> note),
            ],
          )
        }),
      ),
    ])
  }
  [
    html.div([class("labh")], [
      labh(
        "Send to the cart",
        "The cart accepts AddItem, RemoveItem and GetTotal. Send it something else.",
        "margin-top:6px",
      ),
      html.button(
        [
          attribute.type_("button"),
          class("btn sm"),
          event.on_click(ReaderClearedMailboxes),
        ],
        [html.text("Clear")],
      ),
    ]),
    html.div(
      [class("row"), css("margin-bottom:20px")],
      list.map(cart.candidates, fn(candidate) {
        html.button(
          [
            attribute.type_("button"),
            class("btn"),
            event.on_click(ReaderSentToCart(candidate)),
          ],
          [html.text("Send " <> cart.label(candidate))],
        )
      }),
    ),
    html.div([class("split")], [
      column(attribute.none(), "Untyped mailbox (plain Erlang)", cart.erlang),
      column(
        css("background:#FFF7FC;border-color:#F3C6E6"),
        "Subject(CartMessage) in Gleam",
        cart.gleam,
      ),
    ]),
  ]
}

// WRAPPERS --------------------------------------------------------------------

fn wrappers() -> Element(Msg) {
  let wrapper = fn(chip_style, chip, verb, engine, rest) {
    html.div([class("box")], [
      html.span([class("chip"), css(chip_style)], [html.text(chip)]),
      html.p([css("margin-top:8px;font-size:15px")], [
        html.text(verb),
        html.b([], [html.text(engine)]),
        html.text(rest),
      ]),
    ])
  }
  html.section([class("wrap sec")], [
    html.div([class("k")], [
      html.text("Read · Gleam meets the rest of the BEAM"),
    ]),
    html.h2([class("h2")], [html.text("Typed wrappers over proven engines")]),
    html.p([class("lead")], [
      html.text(
        "Several gleam-dream libraries wrap battle-tested Erlang code behind a typed surface. You get the reliability of the original and the safety of Gleam.",
      ),
    ]),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;margin-top:24px",
        ),
      ],
      [
        wrapper(
          "background:#DDF3F0;color:#0B4A45",
          "HTTP Gun",
          "wraps ",
          "Gun",
          ", Erlang's HTTP/1.1 and HTTP/2 client",
        ),
        wrapper(
          "background:#DDF3F0;color:#0B4A45",
          "Sinal",
          "wraps ",
          ":telemetry",
          ", the event registry Erlang and Elixir libraries share",
        ),
        wrapper(
          "background:#FDF0DC;color:#6B3404",
          "Grind",
          "uses ",
          "pog / pgo",
          " for PostgreSQL connections",
        ),
        wrapper(
          "background:#EEE7FD;color:#3B1785",
          "Correio",
          "uses ",
          "gen_smtp",
          " for SMTP delivery",
        ),
      ],
    ),
    html.div([class("note"), css("margin-top:16px")], [
      html.b([], [html.text("One BEAM detail to remember:")]),
      html.text(
        " atoms (the BEAM's named constants) are never garbage-collected. Sinal turns event names into atoms, so those names belong in source code, never built from user input. You'll see a few warnings like this: they're where the BEAM's rules show through the types.",
      ),
    ]),
    ui.carry_forward(
      "Make the compiler your first reviewer: model states as types, return errors as values, and type your messages. gleam-dream APIs follow these rules all the way down.",
    ),
  ])
}
