//// Module 2, OTP: actors, send and call, supervision trees, and where the
//// gleam-dream libraries plug into the reader's own tree.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import lustre
import lustre/attribute.{attribute, class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import pages/otp/cart.{type Cart}
import pages/otp/libraries.{type Library}
import pages/otp/mailbox.{type Mode, Call, Send}
import pages/otp/mailbox_widget.{type Commands, Commands}
import pages/otp/restart_types.{type RestartType, type Table}
import pages/otp/signals.{type Bond, type Pair}
import pages/otp/supervision.{type Child, type Restart, type Strategy, type Tree}
import site/booklets
import site/browser
import site/context.{type Context}
import site/motion.{type Motion}
import site/msc
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  Actor
  LoadTour
  SignalsTour
  TreeTour
  RestartsTour
  Plug
}

/// The reader's settings for the real-time mailbox. The simulation itself
/// lives in the widget; the page sends it commands as growing counters.
pub type Load {
  Load(mode: Mode, rate: Int, paused: Bool, commands: Commands)
}

pub type Model {
  Model(
    cart: Cart,
    load: Load,
    pair: Pair,
    tree: Tree,
    table: Table,
    library: Library,
    tours: tour.Tours(TourId),
  )
}

pub type Msg {
  ReaderHandledNextMessage
  ReaderSentTwoRequestsAtOnce
  ReaderResetCart
  ReaderToggledMailboxPause
  ReaderResetMailbox
  ReaderPickedMode(Mode)
  ReaderSetRate(Int)
  ReaderAdvancedOneSecond
  ReaderPickedBond(Bond)
  ReaderEnded(signals.Ending)
  ReaderResetPair
  ReaderPickedStrategy(Strategy)
  ReaderCrashedChild(Child)
  /// The supervisor's restart, scheduled when a child crashed.
  SupervisorRestarted(Restart)
  ReaderLetFiveSecondsPass
  ReaderResetTree
  ReaderPickedRestartType(RestartType)
  ReaderEndedChild(restart_types.Ending)
  ReaderResetTable
  ReaderPickedLibrary(Library)
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(
    cart: cart.new(),
    load: Load(
      mode: Send,
      rate: 6,
      paused: False,
      commands: Commands(
        resets: 0,
        advances: 0,
        advance_mode: Send,
        advance_rate: 6,
      ),
    ),
    pair: signals.new(),
    tree: supervision.new(0),
    table: restart_types.new(),
    library: libraries.HttpGun,
    tours: tour.new(),
  )
}

// UPDATE ----------------------------------------------------------------------

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  let load = model.load
  let commands = load.commands
  case msg {
    ReaderHandledNextMessage -> #(
      Model(..model, cart: cart.handle_next(model.cart)),
      effect.none(),
    )
    ReaderSentTwoRequestsAtOnce -> #(
      Model(..model, cart: cart.burst(model.cart)),
      effect.none(),
    )
    ReaderResetCart -> #(Model(..model, cart: cart.new()), effect.none())

    ReaderToggledMailboxPause -> #(
      Model(..model, load: Load(..load, paused: !load.paused)),
      effect.none(),
    )
    ReaderResetMailbox -> #(
      Model(
        ..model,
        load: Load(
          ..load,
          paused: False,
          commands: Commands(..commands, resets: commands.resets + 1),
        ),
      ),
      effect.none(),
    )
    ReaderPickedMode(mode) -> #(
      Model(..model, load: Load(..load, mode:)),
      effect.none(),
    )
    ReaderSetRate(rate) -> #(
      Model(..model, load: Load(..load, rate: int.clamp(rate, 1, 12))),
      effect.none(),
    )
    ReaderAdvancedOneSecond -> #(
      Model(
        ..model,
        load: Load(
          ..load,
          commands: Commands(
            ..commands,
            advances: commands.advances + 1,
            advance_mode: load.mode,
            advance_rate: load.rate,
          ),
        ),
      ),
      effect.none(),
    )

    ReaderPickedBond(bond) -> #(
      Model(..model, pair: signals.pick(model.pair, bond)),
      effect.none(),
    )
    ReaderEnded(ending) -> #(
      Model(..model, pair: signals.end(model.pair, ending)),
      effect.none(),
    )
    ReaderResetPair -> #(
      Model(..model, pair: signals.reset(model.pair)),
      effect.none(),
    )

    ReaderPickedStrategy(strategy) -> #(
      Model(..model, tree: supervision.pick(model.tree, strategy)),
      effect.none(),
    )
    ReaderCrashedChild(child) -> {
      let #(tree, restart) = supervision.crash(model.tree, child)
      let restart = case restart {
        None -> effect.none()
        Some(restart) ->
          browser.after(supervision.restart_ms, SupervisorRestarted(restart))
      }
      #(Model(..model, tree:), restart)
    }
    SupervisorRestarted(restart) -> #(
      Model(..model, tree: supervision.restart(model.tree, restart)),
      effect.none(),
    )
    ReaderLetFiveSecondsPass -> #(
      Model(..model, tree: supervision.wait(model.tree)),
      effect.none(),
    )
    ReaderResetTree -> #(
      Model(..model, tree: supervision.reset(model.tree)),
      effect.none(),
    )

    ReaderPickedRestartType(restart) -> #(
      Model(..model, table: restart_types.pick(model.table, restart)),
      effect.none(),
    )
    ReaderEndedChild(ending) -> #(
      Model(..model, table: restart_types.try(model.table, ending)),
      effect.none(),
    )
    ReaderResetTable -> #(
      Model(..model, table: restart_types.reset(model.table)),
      effect.none(),
    )

    ReaderPickedLibrary(library) -> #(Model(..model, library:), effect.none())

    Tour(id, command) ->
      tour.update(driver(context), model, id, command, context.motion)
  }
}

/// Leaving the page pauses any playing tour.
pub fn leave(model: Model) -> Model {
  Model(..model, tours: tour.pause_all(model.tours))
}

/// Register the real-time mailbox widget.
pub fn register() -> Result(Nil, lustre.Error) {
  mailbox_widget.register()
}

// TOURS -----------------------------------------------------------------------

fn driver(context: Context) -> tour.Driver(TourId, Model, Msg) {
  tour.Driver(
    script: script(_, context.motion),
    key: key,
    tours: fn(model: Model) { model.tours },
    set_tours: fn(model, tours) { Model(..model, tours:) },
    run: fn(model, msg) { update(model, msg, context) },
    to_msg: Tour,
  )
}

pub fn key(id: TourId) -> String {
  case id {
    Actor -> "actor"
    LoadTour -> "load"
    SignalsTour -> "signals"
    TreeTour -> "tree"
    RestartsTour -> "restarts"
    Plug -> "plug"
  }
}

pub fn script(id: TourId, motion: Motion) -> tour.Script(Model, Msg) {
  let send = fn(msgs) { fn(_) { msgs } }
  case id {
    Actor ->
      tour.Script(reset: send([ReaderResetCart]), steps: [
        tour.say(
          "A cart actor: a mailbox of four messages, a handler, and private state. Messages are handled strictly one at a time.",
        ),
        tour.act(
          "Handle \"add Book\": the handler takes the message and the current state, and returns the next state. Version 1.",
          send([ReaderHandledNextMessage]),
        ),
        tour.act(
          "Handle \"add Mug\". A send expects no answer, so nothing goes back.",
          send([ReaderHandledNextMessage]),
        ),
        tour.act(
          "\"get total\" is a call: the caller is waiting. The actor replies with €20 (the green dashed arrow) and its state doesn’t change.",
          send([ReaderHandledNextMessage]),
        ),
        tour.act(
          "Two requests arrive at the very same instant. No race, no lock: they simply queue up in the mailbox.",
          send([ReaderSentTwoRequestsAtOnce]),
        ),
        tour.act(
          "The actor works through them in order. Request B gets its reply only after request A’s message is done.",
          send([
            ReaderHandledNextMessage,
            ReaderHandledNextMessage,
            ReaderHandledNextMessage,
          ]),
        ),
        tour.say(
          "One process, one message at a time: that’s why actors need no locks. Now drive it yourself.",
        ),
      ])
    SignalsTour -> {
      let try = fn(bond, ending) {
        send([ReaderPickedBond(bond), ReaderEnded(ending)])
      }
      tour.Script(reset: send([ReaderPickedBond(signals.Link)]), steps: [
        tour.say(
          "Two processes, A and B. Every supervisor is built from the way two processes can be joined. Try each bond, and watch what reaches A.",
        ),
        tour.act(
          "A link. B crashes: its exit signal travels the link and kills A, which did nothing wrong. Links share fate.",
          try(signals.Link, signals.BCrashes),
        ),
        tour.act(
          "Same link, but B finishes its work normally. A normal exit kills nobody: links carry only abnormal exits.",
          try(signals.Link, signals.BFinishes),
        ),
        tour.act(
          "A monitor instead. B crashes and A just gets a ProcessDown message saying why. It keeps running.",
          try(signals.Monitor, signals.BCrashes),
        ),
        tour.act(
          "A link again, but A traps exits. B's crash arrives as an ExitMessage in A's mailbox: A survives and can start B again. That is a supervisor.",
          try(signals.TrappedLink, signals.BCrashes),
        ),
        tour.act(
          "Now A crashes. B was not trapping exits, so the link kills it. Trapping protects only the process that traps.",
          try(signals.TrappedLink, signals.ACrashes),
        ),
        tour.say(
          "Isolation contains a crash, a link carries the news, trapping turns it into a message. The next playground composes these into a tree.",
        ),
      ])
    }
    RestartsTour -> {
      let try = fn(restart, ending) {
        send([ReaderPickedRestartType(restart), ReaderEndedChild(ending)])
      }
      tour.Script(reset: send([ReaderResetTable]), steps: [
        tour.say(
          "The strategy says which children restart together. Each child's restart type says whether it comes back at all.",
        ),
        tour.act(
          "Permanent, the default. The child finishes its work normally, and the supervisor starts it again anyway: permanent means always.",
          try(restart_types.Permanent, restart_types.FinishesNormally),
        ),
        tour.act(
          "Transient: the child crashes. The job did not get done, so it is restarted.",
          try(restart_types.Transient, restart_types.Crashes),
        ),
        tour.act(
          "Transient again, but this time it finishes normally. The job is done, so the supervisor removes it.",
          try(restart_types.Transient, restart_types.FinishesNormally),
        ),
        tour.act(
          "Temporary: it crashes and is removed. Whoever started it handles the failure.",
          try(restart_types.Temporary, restart_types.Crashes),
        ),
        tour.say(
          "Two cells are still blank. Predict them, then try them yourself.",
        ),
      ])
    }
    TreeTour -> {
      let crash = fn(strategy, child) {
        send([ReaderPickedStrategy(strategy), ReaderCrashedChild(child)])
      }
      tour.Script(reset: send([ReaderResetTree]), steps: [
        tour.say(
          "A shop service. The root supervisor started four children in order and watches all of them.",
        ),
        tour.act(
          "One-for-one strategy. Crash the HTTP client: the supervisor gets an EXIT signal and restarts only that child.",
          crash(supervision.OneForOne, supervision.HttpClient),
        )
          |> tour.lasting(4200),
        tour.act(
          "Rest-for-one: crash the HTTP client again. Everything started after it is stopped and restarted too, in the original order.",
          crash(supervision.RestForOne, supervision.HttpClient),
        )
          |> tour.lasting(4200),
        tour.act(
          "One-for-all: crash the job runtime. Every child restarts, because these children only make sense together.",
          crash(supervision.OneForAll, supervision.JobRuntime),
        )
          |> tour.lasting(4200),
        tour.act(
          "Crash the database pool: a 4th crash inside the 5-second window. The window runs on simulated time, so real seconds never clear it. Restarting clearly isn’t helping, so the supervisor stops every child, crashes itself and escalates to its parent.",
          send([ReaderCrashedChild(supervision.DatabasePool)]),
        )
          |> tour.lasting(4200),
        tour.say(
          "Escalation is a feature: failure climbs the tree until a level that can handle it. Reset, and try your own crashes.",
        ),
      ])
    }
    LoadTour -> {
      let restart_at_three =
        send([ReaderResetMailbox, ReaderPickedMode(Send), ReaderSetRate(3)])
      tour.Script(reset: restart_at_three, steps: [
        tour.act(
          "Four request processes send messages to one actor that can handle 4 per second. At 3 per second it keeps up easily.",
          restart_at_three,
        ),
        tour.act(
          "Raise the rate to 8 per second with plain sends. Watch the mailbox fill and the oldest message wait longer and longer.",
          send([ReaderSetRate(8)]),
        )
          |> tour.lasting(7000),
        tour.act(
          "Still climbing. BEAM mailboxes have no limit, so a slow actor quietly eats memory until something breaks.",
          send(case motion {
            motion.Off -> [ReaderAdvancedOneSecond]
            motion.On -> []
          }),
        )
          |> tour.lasting(5000),
        tour.act(
          "Switch to call: each request process now waits for its reply (green) before sending again. New sends slow to the actor’s pace and the backlog drains.",
          // Without motion, two simulated seconds show replies coming back.
          send(case motion {
            motion.Off -> [
              ReaderPickedMode(Call),
              ReaderAdvancedOneSecond,
              ReaderAdvancedOneSecond,
            ]
            motion.On -> [ReaderPickedMode(Call)]
          }),
        )
          |> tour.lasting(8000),
        tour.say(
          "Waiting is backpressure. The libraries in this course make it explicit: bounded queues, pools and per-queue concurrency. Play with the rate yourself.",
        ),
      ])
    }
    Plug -> {
      let pick = fn(library) { send([ReaderPickedLibrary(library)]) }
      tour.Script(reset: pick(libraries.HttpGun), steps: [
        tour.say(
          "Your application’s root supervisor, with children that come from gleam-dream libraries.",
        ),
        tour.act(
          "HTTP Gun brings a pool process plus one short-lived process per open response.",
          pick(libraries.HttpGun),
        ),
        tour.act(
          "Grind brings a coordinator per queue, an attempt process per job run, and a lease renewer.",
          pick(libraries.Grind),
        ),
        tour.act(
          "Fabric brings a store that keeps run records and supervises runners.",
          pick(libraries.FabricStore),
        ),
        tour.say(
          "Every library gives you children; you decide where they live in your tree. Click the others.",
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
    shapes(),
    html.section([class("wrap sec")], [lab(Actor, [], actor(model.cart))]),
    html.section([class("wrap sec")], [
      lab(LoadTour, [css("margin-top:0")], load(model.load, context.motion)),
    ]),
    html.section([class("wrap sec")], [
      html.div([class("k")], [html.text("Read · let it crash")]),
      html.h2([class("h2")], [
        html.text("Separate the happy path from recovery"),
      ]),
      html.p([class("lead")], [
        html.text(
          "Instead of defending every line against every failure, write the normal case clearly and let unexpected errors crash the process. A supervisor, written once and tested by decades of telecom use, restarts it from a known good state.",
        ),
      ]),
      html.p([class("lead"), css("margin-top:12px")], [
        html.text(
          "A supervisor is no magic layered on the VM. It is three rules composed: isolation keeps a crash inside one process, a link carries the news of the crash, and trapping exits turns that news into a message. Try the three bonds first.",
        ),
      ]),
      lab(SignalsTour, [], signals_lab(model.pair)),
      lab(TreeTour, [], tree(model.tree)),
      choosing(),
      lab(RestartsTour, [], restarts_lab(model.table)),
    ]),
    misuses(),
    html.section([class("wrap sec")], [
      html.div([class("k")], [html.text("Read · your tree, their children")]),
      html.h2([class("h2")], [html.text("Where gleam-dream plugs in")]),
      html.p([class("lead")], [
        html.text(
          "No gleam-dream library starts hidden background processes of its own. Each hands you a ready-made child (usually a function called ",
        ),
        html.span([class("mono")], [html.text("supervised")]),
        html.text(
          "), and you place it in your tree. Click a library to see what it brings.",
        ),
      ]),
      lab(Plug, [], plugs(model.library)),
      booklets.card(
        booklets.resilience,
        "This module in depth: the three primitives, every supervisor option, restart intensity and escalation, dynamic children, and the anti-patterns above, with a chapter on how supervisors sit beside circuit breakers and Kubernetes. Its code is Elixir; the ideas carry over to gleam_otp.",
      ),
      ui.carry_forward(
        "Write the happy path and let supervisors handle the rest. Libraries give you children; your application decides where they live, when they start, and when they stop.",
      ),
    ]),
  ])
}

fn hero() -> Element(Msg) {
  html.header([class("wrap"), css("padding-top:72px;padding-bottom:56px")], [
    html.div([class("k")], [html.text("Module 2 · Phase 1: the runtime")]),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:900px")],
      [html.text("OTP: turning failure into a restart")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "OTP is the toolkit that ships with Erlang: a set of proven patterns for processes that hold state, watch each other and restart cleanly. Gleam uses it through the ",
      ),
      html.span([class("mono")], [html.text("gleam_otp")]),
      html.text(" and "),
      html.span([class("mono")], [html.text("gleam_erlang")]),
      html.text(" packages, and every gleam-dream library is built on it."),
    ]),
    html.div([class("card"), css("margin-top:32px;max-width:760px")], [
      html.div([class("k"), css("color:#5B5970")], [
        html.text("By the end you can explain"),
      ]),
      html.div(
        [css("display:flex;flex-direction:column;gap:6px;margin-top:10px")],
        [
          html.span([], [
            html.text("→ what an actor is, and why it needs no locks"),
          ]),
          html.span([], [
            html.text(
              "→ how links, monitors and trapped exits differ, and why a supervisor traps exits",
            ),
          ]),
          html.span([], [
            html.text(
              "→ how a supervisor decides what to restart, and when it gives up",
            ),
          ]),
          html.span([], [
            html.text(
              "→ which strategy and restart type a child needs, from what it depends on",
            ),
          ]),
          html.span([], [
            html.text(
              "→ where each gleam-dream library plugs into your application",
            ),
          ]),
        ],
      ),
    ]),
  ])
}

fn shapes() -> Element(Msg) {
  let card = fn(chip, title, body) {
    html.div([class("card")], [
      html.span([class("chip"), css("background:#DCD9FF;color:#241F6B")], [
        html.text(chip),
      ]),
      html.h3([], [html.text(title)]),
      html.p([], [html.text(body)]),
    ])
  }
  html.section([class("wrap sec")], [
    html.div([class("k")], [html.text("Read · the building patterns")]),
    html.h2([class("h2")], [html.text("Four shapes you'll see everywhere")]),
    html.p([class("lead")], [
      html.text(
        "OTP calls these \"behaviours\". You'll rarely write them from scratch, but every library in this course uses them, so it pays to recognise them.",
      ),
    ]),
    html.div([class("cards")], [
      card(
        "actor",
        "Actor",
        "A process with private state and a loop: take a message, compute the new state, maybe reply, repeat. Erlang calls it a gen_server.",
      ),
      card(
        "call · send",
        "Call or send",
        "\"Send\" delivers a message and moves on. \"Call\" sends and waits for a reply, always with a timeout, because the other side might be dead.",
      ),
      card(
        "supervisor",
        "Supervisor",
        "A process whose only job is to start children in order and restart them when they crash, following a strategy you choose.",
      ),
      card(
        "application",
        "Application",
        "The top of the tree. It starts the root supervisor and stops everything, in reverse order, when the program shuts down.",
      ),
    ]),
  ])
}

fn lab_head(
  tag: String,
  title: String,
  description: String,
  width: String,
  controls: Element(Msg),
) -> Element(Msg) {
  html.div([class("labh")], [
    html.div([], [
      html.span([class("tag")], [html.text(tag)]),
      html.h2([css("font-size:28px;margin-top:10px")], [html.text(title)]),
      html.p([class("muted"), css("margin-top:6px;max-width:" <> width)], [
        html.text(description),
      ]),
    ]),
    controls,
  ])
}

fn button(
  classes: String,
  msg: Msg,
  attributes: List(attribute.Attribute(Msg)),
  label: String,
) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      class(classes),
      event.on_click(msg),
      ..attributes
    ],
    [html.text(label)],
  )
}

// Inside an actor --------------------------------------------------------------

fn actor(shop: Cart) -> List(Element(Msg)) {
  let empty = shop.mailbox == []
  [
    lab_head(
      "Playground",
      "Inside an actor",
      "A shopping-cart actor. Messages queue up in its mailbox and it handles them strictly one at a time. Step through and watch the state change.",
      "660px",
      html.div([class("row")], [
        button(
          "btn",
          ReaderSentTwoRequestsAtOnce,
          [attribute.disabled(!cart.can_burst(shop))],
          "Two requests at the same instant",
        ),
        button("btn sm", ReaderResetCart, [], "Reset"),
      ]),
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px;align-items:stretch",
        ),
      ],
      [
        html.div(
          [class("box"), css("background:#F6F4FF;border-color:#DCD9FF")],
          [
            html.div([class("meta")], [html.text("1 · Mailbox")]),
            html.div(
              [
                css(
                  "display:flex;flex-direction:column;gap:6px;margin-top:10px;min-height:160px",
                ),
              ],
              [
                element.fragment(list.index_map(shop.mailbox, request)),
                case empty {
                  True ->
                    html.div([class("muted"), css("font-size:14px")], [
                      html.text(
                        "Empty. The actor sleeps until a message arrives, using no CPU.",
                      ),
                    ])
                  False -> element.none()
                },
              ],
            ),
          ],
        ),
        html.div(
          [
            class("box"),
            css(
              "display:flex;flex-direction:column;gap:12px;align-items:stretch;justify-content:center;text-align:center",
            ),
          ],
          [
            html.div([class("meta")], [html.text("2 · Handler")]),
            html.div(
              [
                css(
                  "font:600 15px 'JetBrains Mono',monospace;padding:16px;border-radius:12px;background:#17162B;color:#fff",
                ),
              ],
              [
                html.text("handle(message, state)"),
                html.br([]),
                html.text("→ new state"),
              ],
            ),
            html.div([css("font-size:15px;min-height:72px")], [
              html.text(cart.last_step(shop.last)),
            ]),
            button(
              "btn pri",
              ReaderHandledNextMessage,
              [attribute.disabled(empty), css("justify-content:center")],
              "Handle next message",
            ),
          ],
        ),
        html.div(
          [class("box"), css("background:#FDF0DC;border-color:#F3D9B1")],
          [
            html.div([class("meta")], [html.text("3 · State (private)")]),
            html.div(
              [
                css(
                  "display:flex;flex-direction:column;gap:6px;margin-top:10px",
                ),
              ],
              [
                element.fragment(
                  list.map(shop.items, fn(item) {
                    html.div(
                      [
                        css(
                          "display:flex;justify-content:space-between;padding:8px 12px;background:#fff;border-radius:10px",
                        ),
                      ],
                      [
                        html.span([], [html.text(item.name)]),
                        html.b([], [html.text("€" <> int.to_string(item.price))]),
                      ],
                    )
                  }),
                ),
                html.div(
                  [
                    css(
                      "display:flex;justify-content:space-between;padding:8px 12px;border-top:2px solid #17162B;margin-top:4px",
                    ),
                  ],
                  [
                    html.b([], [html.text("Total")]),
                    html.b([], [
                      html.text("€" <> int.to_string(cart.total(shop))),
                    ]),
                  ],
                ),
                html.div([class("meta"), css("margin-top:6px")], [
                  html.text(
                    "version "
                    <> int.to_string(shop.version)
                    <> " · only this actor can change it",
                  ),
                ]),
              ],
            ),
          ],
        ),
      ],
    ),
    html.div([class("card"), css("margin-top:16px;padding:16px")], [
      html.div([class("k"), css("margin-bottom:8px")], [
        html.text("Timeline · two callers, one actor"),
      ]),
      msc.Chart(
        ..msc.chart("a2", ["request A", "request B", "cart actor"], shop.events),
        lane_gap: 200,
        row: 34,
        numbers: True,
        aria: "Sequence chart of requests arriving at the cart actor and its replies",
      )
        |> msc.view,
    ]),
    html.div([class("note tour-hide"), css("margin-top:16px")], [
      html.b([], [html.text("Why no locks?")]),
      html.text(
        " Two requests \"at the same instant\" just become two messages in a row. The actor finishes one before it looks at the other, so its state is never half-updated. A \"call\" gets its reply sent back; a \"send\" gets none.",
      ),
    ]),
  ]
}

fn request(r: cart.Request, index: Int) -> Element(Msg) {
  let bg = case index {
    0 -> "#FFFFFF"
    _ -> "#F6F4FF"
  }
  html.div(
    [
      css(
        "padding:8px 12px;border-radius:10px;background:"
        <> bg
        <> ";border:1px solid #DCD9FF;font:600 13px 'JetBrains Mono',monospace;display:flex;justify-content:space-between",
      ),
    ],
    [
      html.span([], [html.text(cart.label(r))]),
      html.span([css("opacity:.7")], [
        html.text(case cart.is_call(r) {
          True -> "call"
          False -> "send"
        }),
      ]),
    ],
  )
}

// Send or call -----------------------------------------------------------------

fn load(load: Load, motion: Motion) -> List(Element(Msg)) {
  let mode_button = fn(mode, label) {
    html.button(
      [
        attribute.type_("button"),
        ui.on_class("", load.mode == mode),
        ui.pressed(load.mode == mode),
        event.on_click(ReaderPickedMode(mode)),
      ],
      [html.text(label)],
    )
  }
  [
    lab_head(
      "Real time",
      "Send or call: a mailbox under load",
      "Four request processes talk to one actor that handles 4 messages a second. BEAM mailboxes have no size limit, so the only thing that can slow a sender down is the sender waiting. Turn up the rate, then switch between send and call.",
      "720px",
      html.div([class("row")], [
        button("btn sm", ReaderToggledMailboxPause, [], case load.paused {
          True -> "Resume"
          False -> "Pause"
        }),
        button("btn sm", ReaderResetMailbox, [], "Reset"),
      ]),
    ),
    html.div([class("row"), css("gap:18px;margin-bottom:10px")], [
      html.div([class("seg")], [
        mode_button(Send, "Send (fire and forget)"),
        mode_button(Call, "Call (wait for the reply)"),
      ]),
      html.label(
        [
          css(
            "display:flex;align-items:center;gap:10px;flex:1 1 260px;max-width:420px",
          ),
        ],
        [
          html.span([css("white-space:nowrap")], [
            html.b([], [html.text(int.to_string(load.rate))]),
            html.text(" per second"),
          ]),
          html.input([
            attribute.type_("range"),
            attribute("min", "1"),
            attribute("max", "12"),
            attribute("step", "1"),
            attribute.value(int.to_string(load.rate)),
            event.on_input(fn(value) {
              ReaderSetRate(int.parse(value) |> result.unwrap(load.rate))
            }),
            css("flex:1"),
          ]),
        ],
      ),
      case motion {
        motion.Off ->
          button("btn sm", ReaderAdvancedOneSecond, [], "Advance 1 second")
        motion.On -> element.none()
      },
    ]),
    element.element(
      mailbox_widget.tag,
      [
        attribute("data-live", "mailbox"),
        class("live"),
        css("width:100%;display:block"),
        ..mailbox_widget.attributes(
          load.mode,
          load.rate,
          load.paused,
          motion,
          load.commands,
        )
      ],
      [],
    ),
    html.div([class("note"), css("margin-top:10px")], [
      html.text(note(load)),
    ]),
  ]
}

fn note(load: Load) -> String {
  case load.mode, load.rate > 4 {
    Call, _ ->
      "Call: each request process waits for its reply before sending again. However high you set the rate, they can never outrun the actor: its speed sets the pace and the mailbox stays short. That is backpressure, and it comes free with waiting."
    Send, True ->
      "Send at "
      <> int.to_string(load.rate)
      <> "/s into an actor that handles 4/s: the mailbox grows by about "
      <> int.to_string(load.rate - 4)
      <> " messages every second, forever. Each message waits longer than the last and memory climbs until something gives. Nothing pushes back on a plain send."
    Send, False ->
      "Send at "
      <> int.to_string(load.rate)
      <> "/s: the actor keeps up, so the mailbox stays near empty. Now push the rate above 4."
  }
}

// Links, monitors and trapped exits -------------------------------------------

fn signals_lab(pair: Pair) -> List(Element(Msg)) {
  let process = fn(name, status) {
    let #(bg, fg) = case status {
      signals.Alive -> #("#DCD9FF", "#241F6B")
      signals.Finished -> #("#EDEFF3", "#3B4452")
      signals.Crashed | signals.KilledByLink -> #("#FDECEA", "#7A1A12")
    }
    html.div(
      [
        css(
          "padding:12px 18px;border-radius:12px;text-align:center;min-width:150px;background:"
          <> bg
          <> ";color:"
          <> fg,
        ),
      ],
      [
        html.b([], [html.text(name)]),
        html.div([css("font-size:13px;margin-top:4px")], [
          html.text(signals.status_label(status)),
        ]),
      ],
    )
  }
  let bond_line = case pair.bond {
    signals.Link -> "⟷ link"
    signals.Monitor -> "watches →"
    signals.TrappedLink -> "⟷ link · A traps exits"
  }
  let can = signals.running(pair)
  [
    lab_head(
      "Playground",
      "Links, monitors and trapped exits",
      "Join two processes one of three ways, then end one of them. Watch what reaches the other: death, a message, or nothing.",
      "660px",
      button("btn sm", ReaderResetPair, [], "Reset"),
    ),
    html.div([class("row"), css("margin-bottom:16px;gap:16px")], [
      html.span([class("meta")], [html.text("Bond")]),
      html.div(
        [class("seg")],
        list.map(signals.bonds, fn(bond) {
          html.button(
            [
              attribute.type_("button"),
              ui.on_class("", pair.bond == bond),
              ui.pressed(pair.bond == bond),
              event.on_click(ReaderPickedBond(bond)),
            ],
            [html.text(signals.bond_name(bond))],
          )
        }),
      ),
    ]),
    html.p([class("tour-hide"), css("margin-bottom:20px;font-size:15px")], [
      html.b([], [html.text(signals.bond_name(pair.bond) <> ":")]),
      html.text(" " <> signals.bond_description(pair.bond)),
    ]),
    html.div(
      [
        css(
          "display:flex;align-items:center;justify-content:center;gap:16px;flex-wrap:wrap",
        ),
      ],
      [
        process("A", pair.a),
        html.span([class("meta"), css("min-width:120px;text-align:center")], [
          html.text(bond_line),
        ]),
        process("B", pair.b),
      ],
    ),
    html.div(
      [class("row"), css("margin-top:20px;gap:8px;justify-content:center")],
      [
        button(
          "btn",
          ReaderEnded(signals.BCrashes),
          [attribute.disabled(!can)],
          "Crash B",
        ),
        button(
          "btn",
          ReaderEnded(signals.BFinishes),
          [attribute.disabled(!can)],
          "B finishes normally",
        ),
        button(
          "btn",
          ReaderEnded(signals.ACrashes),
          [attribute.disabled(!can)],
          "Crash A",
        ),
      ],
    ),
    html.div([class("card"), css("margin-top:20px;padding:16px")], [
      html.div([class("k"), css("margin-bottom:8px")], [
        html.text("Timeline · what each process saw"),
      ]),
      msc.Chart(
        ..msc.chart("sig", ["A", "B"], case pair.events {
          [] -> [msc.Note(0, "both running: end one to see signals", msc.Grey)]
          events -> events
        }),
        lane_gap: 220,
        row: 30,
        right_pad: 260,
        aria: "Sequence chart of exit signals and messages between two processes",
      )
        |> msc.view,
    ]),
    html.div([class("note"), css("margin-top:10px")], [
      html.text(signals.lesson(pair)),
    ]),
  ]
}

// Choosing a strategy -----------------------------------------------------------

fn choosing() -> Element(Msg) {
  let card = fn(question, answer, example) {
    html.div([class("card")], [
      html.span([class("chip"), css("background:#DCD9FF;color:#241F6B")], [
        html.text(answer),
      ]),
      html.h3([], [html.text(question)]),
      html.p([], [html.text(example)]),
    ])
  }
  html.div([css("margin-top:40px")], [
    html.div([class("k")], [html.text("Read · choosing a strategy")]),
    html.h2([class("h2")], [html.text("Ask about dependencies, not failures")]),
    html.p([class("lead")], [
      html.text(
        "Every child can crash, so \"what might fail?\" picks nothing. Ask instead what each child needs from its siblings. The answer names the strategy, and the order of the children list states the dependencies.",
      ),
    ]),
    html.div([class("cards")], [
      card(
        "Does each child stand alone?",
        "one-for-one",
        "Independent services: a cache, a mailer, a metrics reporter. One crash should touch nobody else. This is the usual answer.",
      ),
      card(
        "Does each child depend on the ones started before it?",
        "rest-for-one",
        "A pipeline: a connection, then the reader that uses it, then the writer after the reader. A crash restarts that child and everything after it.",
      ),
      card(
        "Is the group useless unless all of it runs?",
        "one-for-all",
        "Tightly coupled peers that share state they cannot rebuild alone. Any crash restarts the whole group from a clean slate.",
      ),
    ]),
  ])
}

// Restart types -------------------------------------------------------------------

fn restarts_lab(table: Table) -> List(Element(Msg)) {
  let cell = fn(restart, ending) {
    let last = table.last == Some(restart_types.Trial(restart, ending))
    let #(text, bg, fg) = case restart_types.revealed(table, restart, ending) {
      False -> #("?", "#F4F2EE", "#8A8698")
      True ->
        case restart_types.fate(restart, ending) {
          restart_types.Restarted -> #("↻ restarted", "#E2F4E7", "#15803D")
          restart_types.Removed -> #("— removed", "#EDEFF3", "#3B4452")
        }
    }
    html.td([], [
      html.div(
        [
          css(
            "padding:10px;border-radius:10px;text-align:center;font-weight:600;background:"
            <> bg
            <> ";color:"
            <> fg
            <> case last {
              True -> ";outline:2px solid #241F6B"
              False -> ""
            },
          ),
        ],
        [html.text(text)],
      ),
    ])
  }
  let left = restart_types.remaining(table)
  [
    lab_head(
      "Playground",
      "Restart types",
      "One child under a supervisor. Give it a restart type, then let it finish or crash. Each answer lands in the table; fill in all six.",
      "660px",
      button("btn sm", ReaderResetTable, [], "Reset"),
    ),
    html.div([class("row"), css("margin-bottom:16px;gap:16px")], [
      html.span([class("meta")], [html.text("Restart type")]),
      html.div(
        [class("seg")],
        list.map(restart_types.restart_types, fn(restart) {
          html.button(
            [
              attribute.type_("button"),
              ui.on_class("", table.restart == restart),
              ui.pressed(table.restart == restart),
              event.on_click(ReaderPickedRestartType(restart)),
            ],
            [html.text(restart_types.restart_name(restart))],
          )
        }),
      ),
    ]),
    html.p([class("tour-hide"), css("margin-bottom:16px;font-size:15px")], [
      html.b([], [html.text(restart_types.restart_name(table.restart) <> ":")]),
      html.text(" " <> restart_types.restart_use(table.restart) <> "."),
    ]),
    html.div([class("row"), css("gap:8px;margin-bottom:20px")], [
      button(
        "btn",
        ReaderEndedChild(restart_types.FinishesNormally),
        [],
        "The child finishes normally",
      ),
      button(
        "btn",
        ReaderEndedChild(restart_types.Crashes),
        [],
        "The child crashes",
      ),
    ]),
    html.div([css("overflow-x:auto")], [
      html.table(
        [
          css(
            "width:100%;border-collapse:separate;border-spacing:6px;table-layout:fixed",
          ),
          attribute("aria-label", "Whether each restart type is restarted"),
        ],
        [
          html.thead([], [
            html.tr([], [
              html.th([css("width:120px")], []),
              ..list.map(restart_types.endings, fn(ending) {
                html.th([class("meta"), css("text-align:center")], [
                  html.text(restart_types.ending_name(ending)),
                ])
              })
            ]),
          ]),
          html.tbody(
            [],
            list.map(restart_types.restart_types, fn(restart) {
              html.tr([], [
                html.th(
                  [class("mono"), css("text-align:right;padding-right:8px")],
                  [
                    html.text(restart_types.restart_name(restart)),
                  ],
                ),
                ..list.map(restart_types.endings, fn(ending) {
                  cell(restart, ending)
                })
              ])
            }),
          ),
        ],
      ),
    ]),
    html.div([class("note"), css("margin-top:10px")], [
      html.text(
        restart_types.lesson(table)
        <> case left {
          0 -> " The table is complete."
          1 -> " One cell left."
          n -> " " <> int.to_string(n) <> " cells left."
        },
      ),
    ]),
  ]
}

// Misuses ---------------------------------------------------------------------------

fn misuses() -> Element(Msg) {
  let card = fn(title, wrong, fix) {
    html.div([class("card")], [
      html.span([class("chip"), css("background:#FDECEA;color:#B42318")], [
        html.text("anti-pattern"),
      ]),
      html.h3([], [html.text(title)]),
      html.p([], [html.text(wrong)]),
      html.p([css("margin-top:8px;color:#15803D")], [html.text(fix)]),
    ])
  }
  html.section([class("wrap sec")], [
    html.div([class("k")], [html.text("Read · what not to do")]),
    html.h2([class("h2")], [html.text("Four ways to misuse a process")]),
    html.p([class("lead")], [
      html.text(
        "Processes are cheap, which makes them easy to misuse. These four mistakes are common in every BEAM language, and each has a plain fix.",
      ),
    ]),
    html.div([class("cards")], [
      card(
        "A process outside the tree",
        "A long-lived process started with a bare spawn has no supervisor. When it dies, nothing restarts it, and at shutdown nothing stops it in order.",
        "Start everything that lives longer than a call under a supervisor, even if it should never be restarted.",
      ),
      card(
        "A process to organise code",
        "An actor that only runs pure functions makes every caller queue behind one mailbox, on one scheduler, for no state.",
        "Use a plain module. Reach for a process only for state, concurrency or failure isolation.",
      ),
      card(
        "A protocol scattered across callers",
        "When every caller builds an actor's messages itself, changing a message means changing every caller.",
        "Give the actor's module a public function per request. In Gleam, the typed Subject keeps the message type in one place.",
      ),
      card(
        "Large messages",
        "A message is copied into the receiver's heap, so its size is paid twice: once to copy it, again to collect it. Sending a whole data set to use one field pays for all of it.",
        "Send only what the receiver needs. Binaries over 64 bytes are shared by reference, not copied.",
      ),
    ]),
  ])
}

// Supervision tree -------------------------------------------------------------

fn tree(tree: Tree) -> List(Element(Msg)) {
  let gave_up = tree.supervisor == supervision.GaveUp
  let #(root_bg, root_fg, root_status) = case gave_up {
    True -> #("#FDECEA", "#7A1A12", "gave up, escalated")
    False -> #("#DCD9FF", "#241F6B", "watching 4 children")
  }
  let stem = html.div([css("width:2px;height:20px;background:#8A8698")], [])
  [
    lab_head(
      "Playground",
      "Supervision tree simulator",
      "A small shop service. Pick a restart strategy, then crash a child. Crash things more than 3 times in 5 seconds to see the supervisor give up and escalate. This supervisor is set to tolerate 3 restarts in 5 seconds; gleam_otp's default, changed with restart_tolerance, is 2. Those 5 seconds are simulated: real time never clears the window, only \"Let 5 seconds pass\" or Reset does.",
      "660px",
      button("btn sm", ReaderResetTree, [], "Reset"),
    ),
    html.div([class("row"), css("margin-bottom:24px;gap:16px")], [
      html.span([class("meta")], [html.text("Strategy")]),
      html.div(
        [class("seg")],
        list.map(supervision.strategies, fn(strategy) {
          html.button(
            [
              attribute.type_("button"),
              ui.on_class("", tree.strategy == strategy),
              ui.pressed(tree.strategy == strategy),
              event.on_click(ReaderPickedStrategy(strategy)),
            ],
            [html.text(supervision.strategy_name(strategy))],
          )
        }),
      ),
    ]),
    html.p([class("tour-hide"), css("margin-bottom:20px;font-size:15px")], [
      html.b([], [html.text(supervision.strategy_name(tree.strategy) <> ":")]),
      html.text(" " <> supervision.strategy_description(tree.strategy)),
    ]),
    html.div([css("display:flex;flex-direction:column;align-items:center")], [
      html.div(
        [
          css(
            "padding:12px 20px;border-radius:12px;background:#17162B;color:#fff;text-align:center;min-width:220px",
          ),
        ],
        [
          html.div([class("meta"), css("color:#C9C6E0")], [
            html.text("application"),
          ]),
          html.b([], [html.text("shop")]),
        ],
      ),
      stem,
      html.div(
        [
          css(
            "padding:12px 20px;border-radius:12px;background:"
            <> root_bg
            <> ";color:"
            <> root_fg
            <> ";text-align:center;min-width:260px;border:2px solid #241F6B",
          ),
        ],
        [
          html.div([class("meta"), css("color:inherit;opacity:.8")], [
            html.text(
              "root supervisor · " <> supervision.strategy_short(tree.strategy),
            ),
          ]),
          html.b([], [html.text(root_status)]),
          html.div([css("font-size:13px;margin-top:4px")], [
            html.text(
              "restarts in window: "
              <> int.to_string(supervision.shown_window(tree))
              <> " / 3",
            ),
          ]),
        ],
      ),
      stem,
      html.div([css("height:2px;background:#8A8698;width:76%")], []),
      html.div(
        [
          css(
            "display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;width:100%",
          ),
        ],
        list.index_map(tree.children, fn(state, i) { child(tree, state, i) }),
      ),
    ]),
    html.div([class("card"), css("margin-top:20px;padding:16px")], [
      html.div([class("k"), css("margin-bottom:8px")], [
        html.text("Timeline · what the supervisor saw and did"),
      ]),
      msc.Chart(
        ..msc.chart(
          "t2",
          ["supervisor", "DB pool", "HTTP client", "Job runtime", "Web server"],
          case tree.events {
            [] -> [
              msc.Note(
                0,
                "watching: crash a child to see signals here",
                msc.Grey,
              ),
            ]
            events -> events
          },
        ),
        lane_gap: 150,
        row: 27,
        numbers: True,
        aria: "Sequence chart of exit signals and restarts in the supervision tree",
      )
        |> msc.view,
    ]),
    html.div([class("row"), css("margin-top:20px;gap:16px")], [
      button(
        "btn",
        ReaderLetFiveSecondsPass,
        [],
        "Let 5 seconds pass (clear the window)",
      ),
      html.span([class("muted"), css("font-size:14px")], [
        html.text(supervision.news_text(tree.news)),
      ]),
    ]),
  ]
}

fn child(
  tree: Tree,
  state: supervision.ChildState,
  index: Int,
) -> Element(Msg) {
  let #(status_bg, status_fg, border, bg) = case state.status {
    supervision.Running -> #("#E2F4E7", "#0E4D25", "#B9E2C4", "#FFFFFF")
    supervision.Crashed(..) | supervision.CrashedForGood -> #(
      "#FDECEA",
      "#7A1A12",
      "#E9B8B2",
      "#FBF3F2",
    )
    supervision.Restarting(..) -> #("#FDF0DC", "#6B3404", "#F3D9B1", "#FFFBF4")
    supervision.Stopped -> #("#EDEFF3", "#3B4452", "#D5D9E0", "#F6F7F9")
  }
  let order = case index {
    0 -> "first"
    1 -> "second"
    2 -> "third"
    _ -> "fourth"
  }
  html.div([css("display:flex;flex-direction:column;align-items:center")], [
    html.div([css("width:2px;height:20px;background:#8A8698")], []),
    html.div(
      [
        css(
          "width:100%;box-sizing:border-box;border-radius:14px;padding:14px;border:2px solid "
          <> border
          <> ";background:"
          <> bg
          <> ";display:flex;flex-direction:column;gap:6px;min-height:136px",
        ),
      ],
      [
        html.div([class("meta")], [
          html.text(
            "child " <> int.to_string(index + 1) <> " · started " <> order,
          ),
        ]),
        html.b([], [html.text(supervision.child_name(state.child))]),
        html.span([class("muted tour-hide"), css("font-size:13px")], [
          html.text(supervision.child_what(state.child)),
        ]),
        html.span(
          [
            class("chip"),
            css(
              "background:"
              <> status_bg
              <> ";color:"
              <> status_fg
              <> ";align-self:flex-start",
            ),
          ],
          [html.text(supervision.status_label(state.status))],
        ),
        html.span([class("meta"), css("font-size:12px")], [
          html.text(
            "pid #"
            <> int.to_string(state.pid)
            <> " · restarted "
            <> int.to_string(state.restarts)
            <> "×",
          ),
        ]),
        button(
          "btn sm warn",
          ReaderCrashedChild(state.child),
          [
            attribute.disabled(!supervision.can_crash(tree, state)),
            css("margin-top:auto"),
          ],
          "Crash it",
        ),
      ],
    ),
  ])
}

// Where gleam-dream plugs in ---------------------------------------------------

fn plugs(selected: Library) -> List(Element(Msg)) {
  let chosen = libraries.info(selected)
  [
    html.div([class("split"), css("align-items:flex-start")], [
      html.div([css("flex:1 1 420px")], [
        html.div(
          [
            css(
              "padding:12px 16px;border-radius:12px;background:#17162B;color:#fff;margin-bottom:8px",
            ),
          ],
          [
            html.span([class("meta"), css("color:#C9C6E0")], [
              html.text("your application"),
            ]),
            html.text(" · "),
            html.b([], [html.text("root supervisor")]),
          ],
        ),
        html.div(
          [
            css(
              "display:flex;flex-direction:column;gap:8px;padding-left:24px;border-left:2px solid #8A8698;margin-left:16px",
            ),
          ],
          list.map(libraries.all, fn(library) {
            plug_button(library, library == selected)
          }),
        ),
      ]),
      html.div([css("flex:1 1 340px")], [
        html.div(
          [
            css(
              "border-radius:16px;padding:24px;background:"
              <> chosen.tint
              <> ";color:"
              <> chosen.ink,
            ),
          ],
          [
            html.div([class("k"), css("color:inherit")], [
              html.text(chosen.layer),
            ]),
            html.h3([css("font-size:28px;margin:8px 0")], [
              html.text(chosen.name),
            ]),
            html.p([css("font-size:16px")], [html.text(chosen.brings)]),
            html.div(
              [
                css(
                  "margin-top:16px;padding-top:12px;border-top:1px solid currentColor;font-size:15px",
                ),
              ],
              [
                html.b([], [html.text("You decide:")]),
                html.text(" " <> chosen.you),
              ],
            ),
          ],
        ),
      ]),
    ]),
  ]
}

fn plug_button(library: Library, on: Bool) -> Element(Msg) {
  let l = libraries.info(library)
  let #(bg, border) = case on {
    True -> #(l.tint, l.ink)
    False -> #("#FFFFFF", "#E4E0D8")
  }
  html.button(
    [
      attribute.type_("button"),
      ui.pressed(on),
      event.on_click(ReaderPickedLibrary(library)),
      css(
        "text-align:left;display:flex;justify-content:space-between;align-items:center;gap:12px;min-height:52px;padding:10px 14px;border-radius:12px;border:2px solid "
        <> border
        <> ";background:"
        <> bg
        <> ";color:#17162B;font:inherit;cursor:pointer",
      ),
    ],
    [
      html.span([], [
        html.b([], [html.text(l.name)]),
        html.text(" "),
        html.span([class("muted"), css("font-size:14px")], [
          html.text("· " <> l.short),
        ]),
      ]),
      html.span(
        [class("chip"), css("background:" <> l.tint <> ";color:" <> l.ink)],
        [html.text(l.layer)],
      ),
    ],
  )
}
