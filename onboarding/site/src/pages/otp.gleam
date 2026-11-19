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
import pages/otp/supervision.{type Child, type Restart, type Strategy, type Tree}
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
  TreeTour
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
    tree: Tree,
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
  ReaderPickedStrategy(Strategy)
  ReaderCrashedChild(Child)
  /// The supervisor's restart, scheduled when a child crashed.
  SupervisorRestarted(Restart)
  ReaderLetFiveSecondsPass
  ReaderResetTree
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
    tree: supervision.new(0),
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
    TreeTour -> "tree"
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
      lab(TreeTour, [], tree(model.tree)),
    ]),
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
              "→ how a supervisor decides what to restart, and when it gives up",
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
      "A small shop service. Pick a restart strategy, then crash a child. Crash things more than 3 times in 5 seconds to see the supervisor give up and escalate. Those 5 seconds are simulated: real time never clears the window, only \"Let 5 seconds pass\" or Reset does.",
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
