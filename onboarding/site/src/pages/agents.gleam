//// Module 9, Agents & people in the loop: Fabric's policy gate and stores,
//// a Decisions decision point, and four hundred recommendations under one
//// policy.

import gleam/int
import gleam/list
import gleam/result
import lustre
import lustre/attribute.{attribute, class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import pages/agents/gate.{type Gate}
import pages/agents/ladder.{type Case}
import pages/agents/plug.{type Plug}
import pages/agents/point.{type Point, type Version}
import site/browser
import site/context.{type Context}
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  GateTour
  PlugTour
  PointTour
  LadderTour
}

pub type Model {
  Model(
    gate: Gate,
    plug: Plug,
    point: Point,
    /// The policy version the 400-recommendation view shows.
    ladder: Version,
    cases: List(Case),
    /// The case a keyboard reader has picked to send up, from 1.
    ladder_case: Int,
    tours: tour.Tours(TourId),
  )
}

pub type Msg {
  // The policy gate.
  ReaderSetRule(gate.Rule, gate.Decision)
  ReaderApprovedCall(gate.CallId)
  ReaderRejectedCall(gate.CallId)
  ReaderResetApprovals
  // Pull the plug.
  ReaderPickedStore(plug.Store)
  ReaderToggledInFlight
  ReaderKilledVm
  // The decision point.
  ReaderSetAmount(Int)
  ReaderSetConfidence(Int)
  ReaderPublishedVersion(Version)
  ReaderSetGatedTool(point.GatedTool)
  ReaderStartedOccurrence
  ReaderPerformed(point.Verb)
  /// Load one exact case into the decision point.
  CaseLoaded(amount: Int, confidence: Int, version: Version)
  // Up the ladder.
  ReaderPickedLadderVersion(Version)
  ReaderPickedLadderCase(Int)
  /// A dot was clicked: replay that case in the decision point above.
  ReaderSentCaseUp(Case)
  ReaderJumpedTo(String)
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(
    gate: gate.new(),
    plug: plug.new(),
    point: point.new(),
    ladder: point.V1,
    cases: ladder.cases(),
    ladder_case: 1,
    tours: tour.new(),
  )
}

// UPDATE ----------------------------------------------------------------------

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  let none = fn(model) { #(model, effect.none()) }
  case msg {
    ReaderSetRule(rule, decision) ->
      none(Model(..model, gate: gate.set_rule(model.gate, rule, decision)))
    // An answer the run no longer takes changes nothing.
    ReaderApprovedCall(call) -> none(answer(model, call, gate.Approved))
    ReaderRejectedCall(call) -> none(answer(model, call, gate.Rejected))
    ReaderResetApprovals ->
      none(Model(..model, gate: gate.reset_approvals(model.gate)))
    ReaderPickedStore(store) ->
      none(Model(..model, plug: plug.pick_store(model.plug, store)))
    ReaderToggledInFlight ->
      none(Model(..model, plug: plug.toggle_flight(model.plug)))
    ReaderKilledVm -> none(Model(..model, plug: plug.kill(model.plug)))
    ReaderSetAmount(amount) ->
      none(Model(..model, point: point.set_amount(model.point, amount)))
    ReaderSetConfidence(confidence) ->
      none(Model(..model, point: point.set_confidence(model.point, confidence)))
    ReaderPublishedVersion(version) ->
      none(Model(..model, point: point.publish(model.point, version)))
    ReaderSetGatedTool(tool) ->
      none(Model(..model, point: point.set_tool(model.point, tool)))
    ReaderStartedOccurrence ->
      none(Model(..model, point: point.start_again(model.point)))
    ReaderPerformed(verb) ->
      none(Model(..model, point: point.perform(model.point, verb)))
    CaseLoaded(amount:, confidence:, version:) ->
      none(
        Model(
          ..model,
          point: point.load(model.point, amount, confidence, version),
        ),
      )
    ReaderPickedLadderVersion(version) -> none(Model(..model, ladder: version))
    ReaderPickedLadderCase(number) ->
      none(
        Model(
          ..model,
          ladder_case: int.clamp(number, 1, list.length(model.cases)),
        ),
      )
    ReaderSentCaseUp(case_) -> #(
      Model(
        ..model,
        point: point.load(
          model.point,
          case_.amount,
          case_.confidence,
          model.ladder,
        ),
      ),
      browser.jump_to("refund-point", context.animates(context)),
    )
    ReaderJumpedTo(id) -> #(
      model,
      browser.jump_to(id, context.animates(context)),
    )
    Tour(id, command) ->
      tour.update(driver(context), model, id, command, context.motion)
  }
}

fn answer(model: Model, call: gate.CallId, answer: gate.Answer) -> Model {
  case gate.answer(model.gate, call, answer) {
    Ok(gate) -> Model(..model, gate:)
    Error(_) -> model
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
    GateTour -> "gate"
    PlugTour -> "plug"
    PointTour -> "point"
    LadderTour -> "p400"
  }
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  case id {
    GateTour -> {
      let default_policy = fn(_) {
        [
          ReaderSetRule(gate.SmallRefunds, gate.default_policy.small),
          ReaderSetRule(gate.LargeRefunds, gate.default_policy.large),
          ReaderSetRule(gate.ClosingAccounts, gate.default_policy.closing),
        ]
      }
      tour.Script(reset: default_policy, steps: [
        tour.say(
          "A support agent was asked to refund a €40 fee and a €650 charge and close an account. The model proposes four tool calls; your policy sees every one.",
        ),
        tour.act(
          "With this policy, the lookup and the €40 refund run, the €650 refund waits for a person, and closing the account is denied, with the model told why.",
          default_policy,
        ),
        tour.act(
          "A person approves the €650 refund. Only then does it run, and the run can finish.",
          fn(_) { [ReaderApprovedCall(gate.RefundSetupCharge)] },
        ),
        tour.act(
          "Now hand refunds over instead of running them. The run ends at once as HandedOver; the calls after it in the same reply are withdrawn.",
          fn(_) { [ReaderSetRule(gate.SmallRefunds, gate.refund_desk)] },
        ),
        tour.say(
          "The model proposes; your policy decides. Rewrite the policy yourself.",
        ),
      ])
    }
    PlugTour -> {
      let kill_with = fn(store) {
        fn(_) { [ReaderPickedStore(store), ReaderKilledVm] }
      }
      tour.Script(
        reset: fn(model: Model) {
          [
            ReaderPickedStore(plug.Directory),
            ..case model.plug.flight {
              plug.RefundInFlight -> []
              plug.NothingInFlight -> [ReaderToggledInFlight]
            }
          ]
        },
        steps: [
          tour.say(
            "A run is halfway through a refund when the VM dies. What survives depends on where the store keeps its records.",
          ),
          tour.act(
            "In-memory store: kill the VM and the run is simply gone, along with any record of the refund in flight.",
            kill_with(plug.InMemory),
          ),
          tour.act(
            "Directory store: the record is on disk, and recover(run id) takes over. The in-flight refund is marked uncertain and blocks dependent work.",
            kill_with(plug.Directory),
          ),
          tour.act(
            "PostgreSQL store: a leased store checks the old owner is gone before taking over. The production choice.",
            kill_with(plug.Postgres),
          ),
          tour.say(
            "Handles don’t own runs; the store does. Try the combinations yourself.",
          ),
        ],
      )
    }
    PointTour -> {
      // A tour presses an occurrence button by its label, if it is on offer.
      let go = fn(label) {
        fn(model: Model) {
          case point.find_verb(model.point, label) {
            Ok(verb) -> [ReaderPerformed(verb)]
            Error(Nil) -> []
          }
        }
      }
      tour.Script(
        reset: fn(_) {
          [CaseLoaded(40, 95, point.V1), ReaderSetGatedTool(point.Allows)]
        },
        steps: [
          tour.say(
            "A billing model recommends refunding a €40 fee at 95% confidence. The decision point takes it from here.",
          ),
          tour.act(
            "Policy v1 asks finance for everything. The occurrence now waits, with a card showing exactly what the model saw.",
            go("Read policy"),
          ),
          tour.act(
            "Bia approves. The refund is released to the gated tool, once, inside her verdict’s transaction.",
            go("Bia approves"),
          ),
          tour.act(
            "Publish v3: small, confident refunds proceed alone, but are held for a 10-minute undo window first.",
            fn(_) {
              [
                ReaderPublishedVersion(point.V3),
                ReaderPerformed(point.ReadPolicy),
              ]
            },
          ),
          tour.act(
            "Finance spots a problem and withdraws it during the hold. Nothing is released, and the record says who stopped it.",
            go("Finance withdraws"),
          ),
          tour.act(
            "v4 with a €600 refund: it takes two different people from finance. Every step lands in the append-only record.",
            fn(_) {
              [CaseLoaded(600, 95, point.V4), ReaderPerformed(point.ReadPolicy)]
            },
          ),
          tour.say(
            "Climb or descend the ladder yourself, then scroll down to see four hundred cases at once.",
          ),
        ],
      )
    }
    LadderTour -> {
      let pick = fn(version) { fn(_) { [ReaderPickedLadderVersion(version)] } }
      tour.Script(reset: pick(point.V1), steps: [
        tour.say(
          "Four hundred recommendations. Each dot is one refund; a red ring means the model was wrong about it.",
        ),
        tour.act(
          "v1: everything asks a person. Zero mistakes slip out, and finance spends hours clicking.",
          pick(point.V1),
        ),
        tour.act(
          "v2: the green zone (small and confident) proceeds alone. Most of the people-time disappears, and a few wrong ones slip through: that’s why one in ten is sampled.",
          pick(point.V2),
        ),
        tour.act(
          "v4: the hold gives a window to catch mistakes, and big refunds need two people.",
          pick(point.V4),
        ),
        tour.say(
          "Now go back down the ladder: click any dot to replay that exact refund in the playground above.",
        ),
      ])
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
    html.section(
      [class("wrap sec"), attribute.id("fabric"), attribute("tabindex", "-1")],
      [
        html.div([class("k")], [html.text("Fabric · bounded agents")]),
        html.h2([class("h2")], [
          html.text("An agent is a model, tools, a policy and limits"),
        ]),
        html.p([class("lead")], [
          html.text(
            "You build a checked agent from four things, then start runs in a ",
          ),
          html.b([], [html.text("store")]),
          html.text(
            ". The store keeps each run's record and supervises the runner doing the work. A handle only addresses a run: dropping it cancels nothing, and a run can be reopened by its id after a restart.",
          ),
        ]),
        cards([
          #(
            "model",
            "Proposes",
            "An LLM Wire provider or any custom model function. It suggests the next tool calls or a final answer.",
          ),
          #(
            "tools",
            "Act",
            "Typed tools with codecs. Each classifies its result: done, failed, or uncertain if it may have reached the world.",
          ),
          #(
            "policy",
            "Decides",
            "Your function sees every proposed action and answers Allow, Deny, RequireApproval or HandOver.",
          ),
          #(
            "limits",
            "Bound",
            "Max turns, model and tool timeouts, concurrent tool bodies, optional token and family budgets.",
          ),
        ]),
        lab(GateTour, [], gate_lab(model.gate)),
        lab(PlugTour, [], plug_lab(model.plug)),
        html.div([class("note"), css("margin-top:16px")], [
          html.b([], [html.text("Also in Fabric: graphs.")]),
          html.text(
            " Besides free-form agents, you can build conditional graphs with typed state: nodes route on typed results, wait for human signals, watch external jobs, start child runs and fork structured work, all durably recorded. A graph waits for another system as a signal instead of handing over.",
          ),
        ]),
      ],
    ),
    html.section(
      [
        class("wrap sec"),
        attribute.id("decisions"),
        attribute("tabindex", "-1"),
      ],
      [
        html.div([class("k")], [html.text("Decisions · decision points")]),
        html.h2([class("h2")], [
          html.text("Recommend, decide, release once, remember everything"),
        ]),
        html.p([class("lead")], [
          html.text("A "),
          html.b([], [html.text("decision point")]),
          html.text(
            " is a place where an output must not reach the world unchecked. A model (or a rule, or a person) recommends; a versioned policy either proceeds or asks a person; the final output is released at most once to a gated tool, inside your transaction. Every step is appended to a record, and that record is what you learn from.",
          ),
        ]),
        cards([
          #(
            "point",
            "The declaration",
            "The output type and codec, and the facts a policy may read. No thresholds live here.",
          ),
          #(
            "occurrence",
            "One case",
            "One recommendation about one subject, as append-only entries. Keyed, so a trigger delivered twice is one occurrence.",
          ),
          #(
            "policy",
            "Versioned data",
            "Rules over the facts. Publishing a stricter or looser version changes behaviour without a deploy.",
          ),
          #(
            "gated tool",
            "Released once",
            "The only path to the effect. It accepts nothing but a released output, at most once.",
          ),
        ]),
        lab(
          PointTour,
          [attribute.id("refund-point"), attribute("tabindex", "-1")],
          point_lab(model.point),
        ),
      ],
    ),
    html.section([class("wrap sec")], [
      lab(
        LadderTour,
        [css("margin-top:0")],
        ladder_lab(model.ladder, model.cases, model.ladder_case),
      ),
    ]),
    together(),
  ])
}

fn hero() -> Element(Msg) {
  let pill = fn(target, style, label) {
    ui.jump(target, ReaderJumpedTo, [class("pill"), css(style)], [
      html.text(label),
    ])
  }
  html.header([class("wrap"), css("padding-top:72px;padding-bottom:48px")], [
    html.div([class("k")], [
      html.text("Module 9 · Phase 3: the building blocks"),
    ]),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:940px")],
      [html.text("Agents & people in the loop")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "Models are great at proposing and unreliable at being trusted. ",
      ),
      html.b([], [html.text("Fabric")]),
      html.text(
        " runs bounded agents whose every action passes through your policy. ",
      ),
      html.b([], [html.text("Decisions")]),
      html.text(
        " turns \"should this go out?\" into a recorded decision point, where autonomy grows by publishing data rather than shipping code.",
      ),
    ]),
    html.div([class("row"), css("margin-top:28px;gap:10px")], [
      pill(
        "fabric",
        "text-decoration:none;color:#5E0B3A;background:#FCE7F3",
        "Fabric · bounded agents",
      ),
      pill(
        "decisions",
        "text-decoration:none;color:#5E0B3A;background:#FCE7F3",
        "Decisions · decision points",
      ),
      pill("together", "text-decoration:none;color:#17162B", "Together"),
    ]),
  ])
}

fn cards(cards: List(#(String, String, String))) -> Element(Msg) {
  html.div(
    [class("cards")],
    list.map(cards, fn(card) {
      let #(chip, title, body) = card
      html.div([class("card")], [
        html.span([class("chip"), css("background:#FCE7F3;color:#5E0B3A")], [
          html.text(chip),
        ]),
        html.h3([], [html.text(title)]),
        html.p([], [html.text(body)]),
      ])
    }),
  )
}

fn lab_head(
  tag: String,
  title: String,
  width: String,
  description: List(Element(Msg)),
  button: Element(Msg),
) -> Element(Msg) {
  html.div([class("labh")], [
    html.div([], [
      html.span([class("tag")], [html.text(tag)]),
      html.h2([css("font-size:28px;margin-top:10px")], [html.text(title)]),
      html.p(
        [class("muted"), css("margin-top:6px;max-width:" <> width)],
        description,
      ),
    ]),
    button,
  ])
}

fn small_button(label: String, msg: Msg) -> Element(Msg) {
  html.button(
    [attribute.type_("button"), class("btn sm"), event.on_click(msg)],
    [html.text(label)],
  )
}

fn segment_button(label: String, on: Bool, msg: Msg) -> Element(Msg) {
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

fn meta(text: String) -> Element(Msg) {
  html.div([class("meta")], [html.text(text)])
}

// THE POLICY GATE -------------------------------------------------------------

fn gate_lab(model: Gate) -> List(Element(Msg)) {
  let #(status, why, bg, fg) = case gate.run(model) {
    gate.FinishedHandedOver -> #(
      "Finished: HandedOver",
      "No approval is left hanging and the model takes no further turn. When the decision is recorded, a follow-on run can continue the conversation from it.",
      "#EEE7FD",
      "#3B1785",
    )
    gate.SuspendedForApproval -> #(
      "Suspended: waiting for approval",
      "The run is stored data until someone answers. Approve or reject the yellow rows.",
      "#FFF1C2",
      "#5C4300",
    )
    gate.FinishedWithAnswer -> #(
      "Finished: typed answer",
      "The model wrote its final answer. Remember: a finished answer doesn’t prove every action succeeded. Check the run’s snapshot before calling it a business success.",
      "#E2F4E7",
      "#0E4D25",
    )
  }
  [
    lab_head(
      "Playground",
      "The policy gate",
      "700px",
      [
        html.text("A support agent got: "),
        html.i([], [
          html.text(
            "\"Refund Ana's late fee, the €650 setup charge, and close her account.\"",
          ),
        ]),
        html.text(
          " The model proposes four tool calls. Write the policy and watch every call pass through it.",
        ),
      ],
      small_button("Reset approvals", ReaderResetApprovals),
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:14px;margin-bottom:22px",
        ),
      ],
      list.map(gate.rules, fn(rule) {
        let current = gate.decision(model.policy, rule)
        html.div(
          [class("box"), css("background:#FFF7FC;border-color:#F3C6E6")],
          [
            html.div([class("meta"), css("margin-bottom:8px")], [
              html.text(gate.rule_label(rule)),
            ]),
            html.div(
              [class("seg")],
              list.map(gate.options(rule), fn(option) {
                let #(label, decision) = option
                segment_button(
                  label,
                  decision == current,
                  ReaderSetRule(rule, decision),
                )
              }),
            ),
          ],
        )
      }),
    ),
    html.div(
      [css("display:flex;flex-direction:column;gap:8px")],
      list.map(gate.outcomes(model), call_row),
    ),
    html.div(
      [
        css(
          "margin-top:16px;border-radius:14px;padding:18px 20px;background:"
          <> bg
          <> ";color:"
          <> fg,
        ),
      ],
      [
        html.div([class("meta"), css("color:inherit")], [
          html.text("run status"),
        ]),
        html.b([css("font-size:20px")], [html.text(status)]),
        html.p([css("font-size:15px;margin-top:4px")], [html.text(why)]),
      ],
    ),
  ]
}

fn call_row(pair: #(gate.CallId, gate.Outcome)) -> Element(Msg) {
  let #(call, outcome) = pair
  let allow = #("Allow", "#E2F4E7", "#0E4D25")
  let approval = #("RequireApproval", "#FFF1C2", "#5C4300")
  // Decision chip, effect text, row background and border.
  let #(#(decision, dbg, dfg), effect, bg, border) = case outcome {
    gate.Withdrawn -> #(
      #("—", "#EDEFF3", "#3B4452"),
      "Withdrawn: it was part of the same model reply and hadn’t started (NotStarted).",
      "#F6F7F9",
      "#E4E0D8",
    )
    gate.Ran(read_only: True) -> #(
      allow,
      "Ran. Read-only tools are always allowed here. The result goes back to the model.",
      "#FFFFFF",
      "#E4E0D8",
    )
    gate.Ran(read_only: False) -> #(
      allow,
      "Ran. The tool executed and its result went back to the model.",
      "#FFFFFF",
      "#E4E0D8",
    )
    gate.Denied(reason) -> #(
      #("Deny", "#FDECEA", "#7A1A12"),
      "Not run. The model sees the reason (\""
        <> reason
        <> "\") and the run continues.",
      "#FFFFFF",
      "#E4E0D8",
    )
    gate.HandedOver -> #(
      #("HandOver", "#EEE7FD", "#3B1785"),
      "Not run, ever. The run ends at once as HandedOver with this call’s action and arguments. Your app files it, for example to a decision point.",
      "#FFFFFF",
      "#3B1785",
    )
    gate.ApprovedThenRan -> #(
      approval,
      "Approved, then ran.",
      "#FFFFFF",
      "#E4E0D8",
    )
    gate.RejectedByPerson -> #(
      approval,
      "Rejected. The model is told and the run continues.",
      "#FFFFFF",
      "#E4E0D8",
    )
    gate.WaitingForPerson -> #(
      approval,
      "Waiting for a person. If only approvals remain, the run suspends as stored data: no process has to stay alive.",
      "#FFFFFF",
      "#E0B000",
    )
  }
  html.div(
    [
      css(
        "display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between;padding:14px 16px;border-radius:14px;background:"
        <> bg
        <> ";border:2px solid "
        <> border,
      ),
    ],
    [
      html.div([css("flex:1 1 260px")], [
        meta("turn " <> int.to_string(gate.turn(call))),
        html.b([class("mono"), css("font-size:15px")], [
          html.text(gate.call_text(call)),
        ]),
      ]),
      html.div([css("flex:0 0 auto")], [
        html.span(
          [class("chip"), css("background:" <> dbg <> ";color:" <> dfg)],
          [
            html.text(decision),
          ],
        ),
      ]),
      html.div([css("flex:2 1 300px;font-size:14px")], [html.text(effect)]),
      case outcome {
        gate.WaitingForPerson ->
          html.div([class("row"), css("gap:6px")], [
            small_button("Approve", ReaderApprovedCall(call)),
            html.button(
              [
                attribute.type_("button"),
                class("btn sm warn"),
                event.on_click(ReaderRejectedCall(call)),
              ],
              [html.text("Reject")],
            ),
          ])
        _ -> element.none()
      },
    ],
  )
}

// PULL THE PLUG ---------------------------------------------------------------

fn plug_lab(model: Plug) -> List(Element(Msg)) {
  let in_flight = model.flight == plug.RefundInFlight
  let refund = plug.refund(model)
  let refund_bg = case refund {
    plug.LostWithTheRecord -> "#FDECEA"
    plug.MarkedUncertain -> "#FFF1C2"
    plug.NotKilledYet | plug.NothingWasInFlight -> "#FFFFFF"
  }
  let fact = fn(style, label, value) {
    html.div([class("box"), ..style], [
      meta(label),
      html.b([css("font-size:17px")], [html.text(value)]),
    ])
  }
  [
    html.div([class("labh")], [
      html.div([], [
        html.span([class("tag")], [html.text("Playground")]),
        html.h2([css("font-size:28px;margin-top:10px")], [
          html.text("Pull the plug"),
        ]),
        html.p([class("muted"), css("margin-top:6px;max-width:700px")], [
          html.text(
            "A run is mid-way through when the VM dies. What survives depends on the store's backend, and on whether a tool was talking to the outside world at that moment.",
          ),
        ]),
      ]),
    ]),
    html.div([class("row"), css("gap:16px;margin-bottom:18px")], [
      html.div(
        [class("seg")],
        list.map(plug.stores, fn(store) {
          segment_button(
            plug.store_label(store),
            store == model.store,
            ReaderPickedStore(store),
          )
        }),
      ),
      html.button(
        [
          attribute.type_("button"),
          class(case in_flight {
            True -> "btn warn"
            False -> "btn"
          }),
          ui.pressed(in_flight),
          event.on_click(ReaderToggledInFlight),
        ],
        [
          html.text(case in_flight {
            True -> "A refund call is in flight"
            False -> "No tool call in flight"
          }),
        ],
      ),
      html.button(
        [
          attribute.type_("button"),
          class("btn pri"),
          event.on_click(ReaderKilledVm),
        ],
        [html.text("Kill the VM")],
      ),
    ]),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px",
        ),
      ],
      [
        fact([], "run record", plug.record(model)),
        fact([], "after restart", plug.after_restart(model)),
        fact(
          [css("background:" <> refund_bg)],
          "the in-flight refund",
          plug.refund_text(refund),
        ),
      ],
    ),
    html.p([css("font-size:15px;margin-top:14px")], [
      html.text(plug.why(model)),
    ]),
  ]
}

// THE DECISION POINT ----------------------------------------------------------

fn point_lab(model: Point) -> List(Element(Msg)) {
  let slider = fn(label, value, suffix, min, max, step, to_msg) {
    html.label([css("display:flex;flex-direction:column;gap:6px")], [
      html.span([], [
        html.b([], [html.text(label)]),
        html.text(suffix(int.to_string(value))),
      ]),
      html.input([
        attribute.type_("range"),
        attribute("min", min),
        attribute("max", max),
        attribute("step", step),
        attribute.value(int.to_string(value)),
        event.on_input(fn(raw) {
          to_msg(int.parse(raw) |> result.unwrap(value))
        }),
      ]),
    ])
  }
  let settled = point.is_settled(model)
  let path = model.occurrence.path
  let last = list.length(path) - 1
  let occurrence_buttons =
    list.append(
      list.map(point.verbs(model), fn(verb) {
        html.button(
          [
            attribute.type_("button"),
            class(case point.is_warning(verb) {
              True -> "btn warn"
              False -> "btn"
            }),
            event.on_click(ReaderPerformed(verb)),
          ],
          [html.text(point.verb_label(model, verb))],
        )
      }),
      case settled {
        True -> []
        False ->
          list.map(point.tools, fn(tool) {
            let on = tool == model.tool
            html.button(
              [
                attribute.type_("button"),
                ui.on_class("btn sm", on),
                ui.pressed(on),
                event.on_click(ReaderSetGatedTool(tool)),
              ],
              [html.text(point.tool_label(tool))],
            )
          })
      },
    )
  [
    lab_head(
      "Playground",
      "One refund, through the point",
      "700px",
      [
        html.text(
          "A billing model recommends refunding a fee. Set the amount, the model's confidence and the policy version, then play the person's part.",
        ),
      ],
      small_button("New occurrence", ReaderStartedOccurrence),
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:20px;margin-bottom:20px",
        ),
      ],
      [
        slider(
          "Amount:",
          model.amount,
          fn(v) { " €" <> v },
          "10",
          "1000",
          "1",
          ReaderSetAmount,
        ),
        slider(
          "Model confidence:",
          model.confidence,
          fn(v) { " " <> v <> "%" },
          "50",
          "100",
          "1",
          ReaderSetConfidence,
        ),
      ],
    ),
    html.div([class("meta"), css("margin-bottom:8px")], [
      html.text("Policy version (the autonomy ladder)"),
    ]),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:8px;margin-bottom:22px",
        ),
      ],
      list.map(point.versions, version_button(_, model.version)),
    ),
    html.div(
      [
        css(
          "display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-bottom:18px",
        ),
      ],
      list.index_map(path, fn(phase, i) {
        let current = i == last
        html.span([css("display:inline-flex;align-items:center;gap:6px")], [
          html.span(
            [
              class("chip"),
              css(
                "background:"
                <> case current {
                  True -> "#17162B"
                  False -> point.stage_colour(phase)
                }
                <> ";color:"
                <> case current {
                  True -> "#FFFFFF"
                  False -> "#17162B"
                }
                <> ";font-size:13px;padding:6px 12px",
              ),
            ],
            [html.text(point.stage(phase))],
          ),
          html.span([class("muted"), attribute("aria-hidden", "true")], [
            html.text(case current {
              True -> ""
              False -> "→"
            }),
          ]),
        ])
      }),
    ),
    html.div([class("split with-log"), css("align-items:flex-start")], [
      html.div(
        [
          class("box"),
          css("flex:2 1 400px;background:" <> point.background(model)),
        ],
        [
          meta("now"),
          html.b([css("font-size:20px")], [html.text(point.title(model))]),
          html.p([css("font-size:15px;margin-top:6px")], [
            html.text(point.why(model)),
          ]),
          html.div(
            [class("row"), css("margin-top:14px;gap:8px")],
            occurrence_buttons,
          ),
        ],
      ),
      html.div([class("log-col"), css("flex:1 1 280px")], [
        html.div([class("meta"), css("margin-bottom:8px")], [
          html.text("The record (append-only)"),
        ]),
        html.div(
          [class("log"), css("min-height:200px")],
          list.map(model.occurrence.entries, fn(entry) {
            html.div([class("l")], [html.text(entry)])
          }),
        ),
      ]),
    ]),
  ]
}

fn version_button(version: Version, current: Version) -> Element(Msg) {
  let on = version == current
  let #(bg, fg, border) = case on {
    True -> #("#5E0B3A", "#FFFFFF", "#5E0B3A")
    False -> #("#FFFFFF", "#17162B", "#E4E0D8")
  }
  html.button(
    [
      attribute.type_("button"),
      ui.pressed(on),
      event.on_click(ReaderPublishedVersion(version)),
      css(
        "text-align:left;font:inherit;cursor:pointer;border-radius:12px;padding:12px 14px;border:2px solid "
        <> border
        <> ";background:"
        <> bg
        <> ";color:"
        <> fg
        <> ";min-height:96px;display:flex;flex-direction:column;gap:4px",
      ),
    ],
    [
      html.b([], [html.text(point.version_name(version))]),
      html.span([css("font-size:13px")], [
        html.text(point.version_rule(version)),
      ]),
      html.span([class("mono"), css("font-size:11px;margin-top:auto")], [
        html.text(
          int.to_string(point.reach(version))
          <> " of 20 recent cases proceed alone",
        ),
      ]),
    ],
  )
}

// UP THE LADDER ---------------------------------------------------------------

fn ladder_lab(
  version: Version,
  cases: List(Case),
  picked: Int,
) -> List(Element(Msg)) {
  let tally = ladder.tally(version, cases)
  let v = point.number(version)
  let one = fn(x) { ladder.fixed(x, 1) }
  let label = fn(x, y, anchor, text) {
    svg.text(
      [
        attribute("x", x),
        attribute("y", y),
        class("msc-l"),
        attribute("fill", "#5B5970"),
        case anchor {
          "" -> attribute.none()
          _ -> attribute("text-anchor", anchor)
        },
      ],
      text,
    )
  }
  let key = fn(style, text) {
    html.span([], [
      html.span(
        [
          css(
            "display:inline-block;width:10px;height:10px;border-radius:9px;"
            <> style,
          ),
        ],
        [],
      ),
      html.text(text),
    ])
  }
  let stat = fn(style, label, value, rest) {
    html.div([class("box"), ..style], [
      meta(label),
      html.b([css("font-size:24px")], [html.text(value)]),
      html.text(" "),
      html.span([class("muted")], [html.text(rest)]),
    ])
  }
  [
    lab_head(
      "Up the ladder",
      "400 recommendations, one policy",
      "740px",
      [
        html.text(
          "Above, you walked one refund through the point. Here are four hundred at once: each dot is a recommendation, placed by amount and model confidence. Pick a policy version and see who decides what. Click any dot, or pick a case by number, to send that case to the single-refund playground above.",
        ),
      ],
      element.none(),
    ),
    html.div(
      [class("seg"), css("margin-bottom:16px")],
      list.map(point.versions, fn(option) {
        segment_button(
          ladder.ladder_label(option),
          option == version,
          ReaderPickedLadderVersion(option),
        )
      }),
    ),
    html.div([class("split"), css("align-items:flex-start")], [
      html.div([css("flex:3 1 520px;min-width:0;overflow-x:auto")], [
        svg.svg(
          [
            attribute("viewBox", "0 0 760 330"),
            attribute("width", "100%"),
            css("min-width:520px;display:block"),
            attribute.role("img"),
            attribute.aria_label(
              "Scatter plot of 400 recommendations by amount and confidence under policy version "
              <> int.to_string(v)
              <> ": "
              <> int.to_string(tally.alone)
              <> " proceed alone, "
              <> int.to_string(tally.ask)
              <> " ask finance",
            ),
          ],
          [
            svg.rect([
              attribute("x", "60"),
              attribute("y", "20"),
              attribute("width", one(ladder.alone_right() -. 60.0)),
              attribute("height", one(ladder.alone_bottom() -. 20.0)),
              attribute("fill", "#E2F4E7"),
              attribute("opacity", case v >= 2 {
                True -> "0.9"
                False -> "0"
              }),
            ]),
            svg.line([
              attribute("x1", one(ladder.two_approvals_x())),
              attribute("x2", one(ladder.two_approvals_x())),
              attribute("y1", "20"),
              attribute("y2", "280"),
              attribute("stroke", "#5E0B3A"),
              attribute("stroke-dasharray", "4 4"),
              attribute("opacity", case v >= 4 {
                True -> "0.8"
                False -> "0"
              }),
            ]),
            element.fragment(list.map(cases, dot(_, version))),
            svg.line([
              attribute("x1", "60"),
              attribute("x2", "720"),
              attribute("y1", "280"),
              attribute("y2", "280"),
              attribute("stroke", "#8A8698"),
            ]),
            svg.line([
              attribute("x1", "60"),
              attribute("x2", "60"),
              attribute("y1", "20"),
              attribute("y2", "280"),
              attribute("stroke", "#8A8698"),
            ]),
            label("60", "300", "", "€10"),
            label("390", "300", "middle", "€100"),
            label("720", "300", "end", "€1,000"),
            label("390", "322", "middle", "amount (log scale)"),
            label("52", "26", "end", "100%"),
            label("52", "154", "end", "75%"),
            label("52", "282", "end", "50%"),
          ],
        ),
        html.div([class("row"), css("gap:14px;margin-top:8px;font-size:13px")], [
          key("background:#15803D", " proceeds alone"),
          key("background:#7C4DCC", " asks one person"),
          key("background:#3B1785", " asks two"),
          key("border:2px solid #B42318", " model was wrong"),
        ]),
        case_picker(version, cases, picked),
      ]),
      html.div(
        [css("flex:2 1 280px;display:flex;flex-direction:column;gap:10px")],
        [
          stat(
            [],
            "proceed alone",
            int.to_string(tally.alone),
            "(" <> int.to_string(round_div(tally.alone, 4)) <> "%)",
          ),
          stat(
            [],
            "ask finance",
            int.to_string(tally.ask),
            "≈ "
              <> ladder.minutes_text(ladder.minutes(tally))
              <> " of people's time at 2 min each",
          ),
          stat(
            [
              css(
                "background:"
                <> case tally.slipped {
                  0 -> "#FFFFFF"
                  _ -> "#FEF6F5"
                },
              ),
            ],
            "wrong, and nobody looked first",
            int.to_string(tally.slipped),
            "of " <> int.to_string(tally.wrong) <> " wrong recommendations",
          ),
          html.div([class("box")], [
            meta("safety nets"),
            html.span([css("font-size:14px")], [
              html.text(ladder.safety_nets(version, tally)),
            ]),
          ]),
        ],
      ),
    ]),
    html.p([class("muted"), css("font-size:13px;margin-top:10px")], [
      html.text(
        "An illustrative model: amounts and confidences are simulated, and the model is wrong about as often as its confidence says. Real autonomy decisions come from the tallies Decisions keeps per recommender version.",
      ),
    ]),
  ]
}

/// Send a case up by number: the keyboard way to do what clicking a dot does,
/// without four hundred tab stops.
fn case_picker(
  version: Version,
  cases: List(Case),
  picked: Int,
) -> Element(Msg) {
  case list.drop(cases, picked - 1) {
    [case_, ..] ->
      html.div([class("row"), css("gap:10px;margin-top:12px;font-size:14px")], [
        html.label([attribute.for("ladder-case"), class("meta")], [
          html.text("Case"),
        ]),
        html.input([
          attribute.id("ladder-case"),
          attribute.type_("number"),
          attribute.min("1"),
          attribute.max(int.to_string(list.length(cases))),
          attribute.value(int.to_string(picked)),
          css("width:72px;min-height:36px;font:inherit"),
          event.on_input(fn(value) {
            ReaderPickedLadderCase(int.parse(value) |> result.unwrap(picked))
          }),
        ]),
        html.span([class("muted")], [
          html.text(
            "€"
            <> int.to_string(case_.amount)
            <> " at "
            <> int.to_string(case_.confidence)
            <> "% · "
            <> route_words(ladder.route(version, case_)),
          ),
        ]),
        html.button(
          [
            attribute.type_("button"),
            class("btn sm"),
            event.on_click(ReaderSentCaseUp(case_)),
          ],
          [html.text("Send this case up")],
        ),
      ])
    [] -> element.none()
  }
}

fn route_words(route: ladder.Route) -> String {
  case route {
    ladder.ProceedsAlone -> "proceeds alone"
    ladder.AsksOne -> "asks one person"
    ladder.AsksTwo -> "asks two"
  }
}

/// `Math.round(n / d)` for non-negative integers.
fn round_div(n: Int, d: Int) -> Int {
  { 2 * n + d } / { 2 * d }
}

fn dot(case_: Case, version: Version) -> Element(Msg) {
  let route = ladder.route(version, case_)
  let fill = case route {
    ladder.ProceedsAlone -> "#15803D"
    ladder.AsksTwo -> "#3B1785"
    ladder.AsksOne -> "#7C4DCC"
  }
  let #(stroke, width) = case case_.wrong {
    True -> #("#B42318", "2")
    False -> #("#FFFFFF", "1")
  }
  // A circle with a title child; `svg.circle` takes no children.
  element.namespaced(
    "http://www.w3.org/2000/svg",
    "circle",
    [
      attribute("cx", ladder.fixed(ladder.x(case_.drawn_amount), 1)),
      attribute("cy", ladder.fixed(ladder.y(case_.drawn_confidence), 1)),
      attribute("r", "4.5"),
      attribute("fill", fill),
      attribute("stroke", stroke),
      attribute("stroke-width", width),
      event.on_click(ReaderSentCaseUp(case_)),
      css("cursor:pointer"),
    ],
    [
      svg.title([], [
        html.text(
          "€"
          <> int.to_string(case_.amount)
          <> " at "
          <> int.to_string(case_.confidence)
          <> "%"
          <> case case_.wrong {
            True -> " · model wrong"
            False -> ""
          }
          <> case route {
            ladder.ProceedsAlone -> " · proceeds alone"
            _ -> " · asks finance"
          },
        ),
      ]),
    ],
  )
}

// TOGETHER --------------------------------------------------------------------

fn together() -> Element(Msg) {
  let move = fn(style, step, title, body) {
    html.div([class("box"), css(style)], [
      meta(step),
      html.b([], [html.text(title)]),
      html.p([css("font-size:14px;margin-top:4px")], [html.text(body)]),
    ])
  }
  html.section(
    [class("wrap sec"), attribute.id("together"), attribute("tabindex", "-1")],
    [
      html.div([class("k")], [html.text("Read · Fabric + Decisions + Saga")]),
      html.h2([class("h2")], [html.text("The payout desk, in five moves")]),
      html.p([class("lead")], [
        html.text(
          "The richest example in Oversight combines everything in this module. A marketplace pays its sellers, and nobody wants an agent moving money on its own say-so.",
        ),
      ]),
      html.div(
        [
          css(
            "display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px;margin-top:24px",
          ),
        ],
        [
          move(
            "background:#FCE7F3;border-color:#F3C6E6",
            "1 · Fabric",
            "Investigate",
            "A support agent reads the dispute and proposes propose_payout.",
          ),
          move(
            "background:#FCE7F3;border-color:#F3C6E6",
            "2 · Fabric policy",
            "Hand over",
            "The policy hands the call over. The run ends; nothing is paid.",
          ),
          move(
            "background:#FFF7FC;border-color:#F3C6E6",
            "3 · Decisions",
            "Decide",
            "The payout point applies a versioned policy: small won disputes proceed after an undo window; large ones need two from finance.",
          ),
          move(
            "background:#FDF0DC;border-color:#F3D9B1",
            "4 · Saga",
            "Pay",
            "The released payout runs as a saga with an idempotency key; Grind delivers the wake-ups.",
          ),
          move(
            "background:#E2F4E7;border-color:#B9E2C4",
            "5 · Fabric again",
            "Tell the seller",
            "A follow-on run can continue the conversation from the decision.",
          ),
        ],
      ),
      ui.carry_forward(
        "Models propose; policy decides; people step in where policy says; effects happen once; everything is on the record. Fabric runs the agent, Decisions owns the decision.",
      ),
    ],
  )
}
