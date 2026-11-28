//// Module 1, the BEAM: processes, messages, mailboxes, links and fair
//// scheduling, with a process playground drawn live as a sequence chart and
//// a two-core scheduler.

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
import pages/beam/processes.{type Process, type Processes, type Trace}
import pages/beam/scheduler.{
  type Scheduling, type Workload, Cooperative, Preemptive, WellBehaved,
  WithGreedy,
}
import pages/beam/scheduler_widget
import site/booklets
import site/context.{type Context}
import site/msc
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  ProcessTour
  SchedulerTour
}

pub type Model {
  Model(
    processes: Processes,
    scheduling: Scheduling,
    workload: Workload,
    /// Commands sent to the live scheduler, as counters that only grow.
    scheduler_resets: Int,
    scheduler_advanced: Int,
    /// The latest advances asked of the scheduler, each with its settings.
    scheduler_recent: List(scheduler_widget.Advance),
    tours: tour.Tours(TourId),
  )
}

pub type Msg {
  ReaderPickedSender(Int)
  ReaderPickedRecipient(Int)
  ReaderSentMessage
  ReaderHandledMessage(Int)
  ReaderCrashedProcess(Int)
  ReaderRestartedProcess(Int)
  ReaderStartedProcess
  ReaderToggledLink
  ReaderResetProcesses
  ReaderPickedScheduling(Scheduling)
  ReaderToggledGreedy
  ReaderAdvancedScheduler
  /// A tour step with motion off: run the scheduler ahead so the step's
  /// effect shows in the still picture.
  TourHurriedScheduler(seconds: Int)
  TourResetScheduler
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(
    processes: processes.new(),
    scheduling: Preemptive,
    workload: WellBehaved,
    scheduler_resets: 0,
    scheduler_advanced: 0,
    scheduler_recent: [],
    tours: tour.new(),
  )
}

// UPDATE ----------------------------------------------------------------------

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  let on = fn(change) {
    #(Model(..model, processes: change(model.processes)), effect.none())
  }
  case msg {
    ReaderPickedSender(id) -> on(processes.pick_sender(_, id))
    ReaderPickedRecipient(id) -> on(processes.pick_recipient(_, id))
    ReaderSentMessage -> on(processes.send)
    ReaderHandledMessage(id) -> on(processes.handle(_, id))
    ReaderCrashedProcess(id) -> on(processes.crash(_, id))
    ReaderRestartedProcess(id) -> on(processes.restart(_, id))
    ReaderStartedProcess -> on(processes.spawn)
    ReaderToggledLink -> on(processes.toggle_link)
    ReaderResetProcesses -> on(fn(_) { processes.new() })
    ReaderPickedScheduling(scheduling) -> #(
      Model(..model, scheduling:),
      effect.none(),
    )
    ReaderToggledGreedy -> #(
      Model(..model, workload: case model.workload {
        WellBehaved -> WithGreedy
        WithGreedy -> WellBehaved
      }),
      effect.none(),
    )
    ReaderAdvancedScheduler -> #(advance_scheduler(model, 1), effect.none())
    TourHurriedScheduler(seconds) ->
      case context.animates(context) {
        True -> #(model, effect.none())
        False -> #(advance_scheduler(model, seconds), effect.none())
      }
    TourResetScheduler -> #(
      Model(..model, scheduler_resets: model.scheduler_resets + 1),
      effect.none(),
    )
    Tour(id, command) ->
      tour.update(driver(context), model, id, command, context.motion)
  }
}

fn scheduler_controls(model: Model) -> scheduler_widget.Controls {
  scheduler_widget.Controls(
    scheduling: model.scheduling,
    workload: model.workload,
    resets: model.scheduler_resets,
    advanced: model.scheduler_advanced,
    recent: model.scheduler_recent,
  )
}

/// Ask the live scheduler to run ahead under the current settings.
fn advance_scheduler(model: Model, seconds: Int) -> Model {
  let controls =
    scheduler_widget.ask_advance(scheduler_controls(model), seconds)
  Model(
    ..model,
    scheduler_advanced: controls.advanced,
    scheduler_recent: controls.recent,
  )
}

/// Leaving the page pauses any playing tour.
pub fn leave(model: Model) -> Model {
  Model(..model, tours: tour.pause_all(model.tours))
}

/// The live two-core scheduler.
pub fn register() -> Result(Nil, lustre.Error) {
  scheduler_widget.register()
}

fn driver(context: Context) -> tour.Driver(TourId, Model, Msg) {
  tour.Driver(
    script:,
    key: fn(id) {
      case id {
        ProcessTour -> "proc"
        SchedulerTour -> "sched"
      }
    },
    tours: fn(model: Model) { model.tours },
    set_tours: fn(model, tours) { Model(..model, tours:) },
    run: fn(model, msg) { update(model, msg, context) },
    to_msg: Tour,
  )
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  let send = fn(from, to) {
    [ReaderPickedSender(from), ReaderPickedRecipient(to), ReaderSentMessage]
  }
  case id {
    ProcessTour ->
      tour.Script(reset: fn(_) { [ReaderResetProcesses] }, steps: [
        tour.say(
          "Five processes, each with its own private memory and an empty mailbox. Press Next (or Play) to watch what a single message does.",
        ),
        tour.act(
          "web sends add_item to cart. The message is copied into cart’s mailbox, and web carries on immediately: sending never waits.",
          fn(_) { send(0, 1) },
        ),
        tour.act(
          "cart takes the message out of its mailbox and handles it. Only cart can ever touch cart’s state.",
          fn(_) { [ReaderHandledMessage(1)] },
        ),
        tour.act(
          "Now payment crashes. Its memory and mailbox vanish, and every other process keeps running untouched.",
          fn(_) { [ReaderCrashedProcess(2)] },
        ),
        tour.act(
          "web sends to the dead payment process. The send still \"succeeds\": the message is silently dropped (the lightning bolt in the chart).",
          fn(_) { send(0, 2) },
        ),
        tour.act(
          "Start payment again, then link it to cart. A link ties two processes’ fates together.",
          fn(_) { [ReaderRestartedProcess(2), ReaderToggledLink] },
        ),
        tour.act(
          "Crash cart: payment receives an EXIT signal and dies too. That is exactly how a supervisor notices failures, in the next module.",
          fn(_) { [ReaderCrashedProcess(1)] },
        ),
        tour.say(
          "The timeline below tells the whole story. Your turn: start processes, send messages, link and crash them.",
        ),
      ])
    SchedulerTour ->
      tour.Script(
        reset: fn(model: Model) {
          [
            ReaderPickedScheduling(Preemptive),
            TourResetScheduler,
            ..remove_greedy(model)
          ]
        },
        steps: [
          tour.say(
            "Two cores, four well-behaved processes. Each wakes when a message arrives, queues, works and sleeps again. Each square is one time slice; everyone gets a turn within a slice or two.",
          )
            |> tour.lasting(6000),
          tour.act(
            "Add a greedy process G that never stops working, on a cooperative runtime: it grabs a core and never gives it back. The run queue backs up and the longest wait climbs.",
            fn(model: Model) {
              list.flatten([
                [ReaderPickedScheduling(Cooperative)],
                add_greedy(model),
                [TourHurriedScheduler(8)],
              ])
            },
          )
            |> tour.lasting(8000),
          tour.act(
            "Same greedy process, BEAM style: the scheduler cuts it off when its work budget runs out, like everyone else. The queue drains and the longest wait drops right back down.",
            fn(_) {
              [ReaderPickedScheduling(Preemptive), TourHurriedScheduler(6)]
            },
          )
            |> tour.lasting(8000),
          tour.say(
            "That fairness is why one runaway loop can’t freeze a BEAM service. Try the switches yourself.",
          ),
        ],
      )
  }
}

fn add_greedy(model: Model) -> List(Msg) {
  case model.workload {
    WellBehaved -> [ReaderToggledGreedy]
    WithGreedy -> []
  }
}

fn remove_greedy(model: Model) -> List(Msg) {
  case model.workload {
    WithGreedy -> [ReaderToggledGreedy]
    WellBehaved -> []
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model, context: Context) -> Element(Msg) {
  element.fragment([
    hero(),
    vocabulary(),
    html.section([class("wrap sec")], [
      tour.lab(model.tours, ProcessTour, driver(context), context, [], [
        process_playground(model.processes),
      ]),
      timeline(model.processes),
      html.div([class("note"), css("margin-top:16px")], [
        html.b([], [html.text("Notice:")]),
        html.text(
          " crashing a process never touches anyone else's memory. The only way failure spreads is one you chose on purpose: a link. That makes failure ",
        ),
        html.b([], [html.text("local and visible")]),
        html.text(", which is exactly what OTP builds on in the next module."),
      ]),
    ]),
    html.section([class("wrap sec")], [
      html.div([class("k")], [html.text("Read · fairness")]),
      html.h2([class("h2")], [
        html.text("Why one runaway loop can't freeze the system"),
      ]),
      html.p([class("lead")], [
        html.text(
          "Most runtimes trust code to give the CPU back. The BEAM doesn't. Each process gets a small work budget (counted in \"reductions\"), then the scheduler moves on. That's why a BEAM service stays responsive under load.",
        ),
      ]),
      tour.lab(model.tours, SchedulerTour, driver(context), context, [], [
        scheduler_playground(model, context),
      ]),
    ]),
    one_picture(),
  ])
}

fn hero() -> Element(Msg) {
  html.header([class("wrap"), css("padding-top:72px;padding-bottom:56px")], [
    html.div([class("k")], [html.text("Module 1 · Phase 1: the runtime")]),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:900px")],
      [html.text("The BEAM: a machine made of tiny computers")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "Erlang, Elixir and Gleam all run on the BEAM, a virtual machine built at Ericsson for telephone switches that had to stay up for years. Its big idea: build software out of many small, isolated processes that only talk by sending messages.",
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
            "→ what a BEAM process is, and why you can run millions of them",
            "→ why one process crashing doesn't corrupt the others",
            "→ how messages, mailboxes, links and schedulers fit together",
          ],
          fn(line) { html.span([], [html.text(line)]) },
        ),
      ),
    ]),
  ])
}

// VOCABULARY ------------------------------------------------------------------

type Shape {
  Circle(cx: String, cy: String, r: String)
  Path(d: String)
  Rect(x: String, y: String, width: String, height: String)
}

fn vocabulary() -> Element(Msg) {
  html.section([class("wrap sec")], [
    html.div([class("k")], [html.text("Read · six words to know")]),
    html.h2([class("h2")], [html.text("The vocabulary of the BEAM")]),
    html.p([class("lead")], [
      html.text(
        "Six ideas cover almost everything. Every library you'll meet later is made of these.",
      ),
    ]),
    html.div([class("cards")], [
      word(
        [Circle("12", "12", "8")],
        "Process",
        "Not an OS thread. A tiny unit of work with its own memory and garbage collector, a few KB in size. Starting one takes microseconds, so programs run thousands or millions.",
      ),
      word(
        [Path("M4 7h16v10H4z"), Path("M4 7l8 6 8-6")],
        "Message",
        "A value copied from one process to another. Sending is asynchronous: you send and move on. Nothing is shared, so there are no locks to get wrong.",
      ),
      word(
        [Path("M5 6h14M5 12h14M5 18h9")],
        "Mailbox",
        "Every process has a queue of incoming messages. It handles them one at a time, so its own state is never touched by two things at once.",
      ),
      word(
        [Path("M4 18V8M10 18V4M16 18v-7M22 18H2")],
        "Scheduler",
        "One per CPU core. Each process gets a small budget of work, then must step aside. No single process can starve the rest.",
      ),
      word(
        [Circle("7", "12", "4"), Circle("17", "12", "4")],
        "Link & monitor",
        "Ways to hear that another process died. A link ties two fates together. A monitor just delivers a \"it went down\" message.",
      ),
      word(
        [
          Rect("3", "4", "8", "7"),
          Rect("13", "13", "8", "7"),
          Path("M11 8h4v5"),
        ],
        "Node",
        "One running BEAM. Nodes can connect and message across machines. Most gleam-dream libraries deliberately stay on one node and use a database for anything shared.",
      ),
    ]),
  ])
}

fn word(icon: List(Shape), title: String, body: String) -> Element(Msg) {
  html.div([class("card")], [
    html.div([class("ico"), css("background:#EBEAFD")], [
      svg.svg(
        [
          attribute("width", "22"),
          attribute("height", "22"),
          attribute("viewBox", "0 0 24 24"),
          attribute("fill", "none"),
          attribute("stroke", "#2B2862"),
          attribute("stroke-width", "2"),
          attribute("aria-hidden", "true"),
        ],
        list.map(icon, shape),
      ),
    ]),
    html.h3([], [html.text(title)]),
    html.p([], [html.text(body)]),
  ])
}

fn shape(s: Shape) -> Element(Msg) {
  case s {
    Circle(cx:, cy:, r:) ->
      svg.circle([attribute("cx", cx), attribute("cy", cy), attribute("r", r)])
    Path(d:) -> svg.path([attribute("d", d)])
    Rect(x:, y:, width:, height:) ->
      svg.rect([
        attribute("x", x),
        attribute("y", y),
        attribute("width", width),
        attribute("height", height),
        attribute("rx", "1"),
      ])
  }
}

// PROCESS PLAYGROUND ----------------------------------------------------------

fn process_playground(p: Processes) -> Element(Msg) {
  element.fragment([
    html.div([class("labh")], [
      html.div([], [
        html.span([class("tag")], [html.text("Playground")]),
        html.h2([css("font-size:28px;margin-top:10px")], [
          html.text("Process playground"),
        ]),
        html.p([class("muted"), css("margin-top:6px;max-width:640px")], [
          html.text(
            "Send messages, let processes handle them, then crash one. Watch what survives. Try linking two processes before you crash one of them.",
          ),
        ]),
      ]),
      html.div([class("row")], [
        button("btn", ReaderStartedProcess, "+ Start a process"),
        button("btn sm", ReaderResetProcesses, "Reset"),
      ]),
    ]),
    html.div([class("split with-log"), css("gap:16px;align-items:flex-start")], [
      html.div([css("flex:2 1 520px")], [
        html.div([class("row"), css("margin-bottom:14px;gap:16px")], [
          chooser("From", p, p.sender, ReaderPickedSender),
          chooser("To", p, p.recipient, ReaderPickedRecipient),
          html.button(
            [
              attribute.type_("button"),
              class("btn pri"),
              event.on_click(ReaderSentMessage),
              css("align-self:flex-end"),
            ],
            [html.text("Send \"" <> processes.next_message(p) <> "\" →")],
          ),
        ]),
        html.div(
          [
            css(
              "display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px",
            ),
          ],
          list.map(p.processes, process_card(p, _)),
        ),
        html.div([class("row"), css("margin-top:14px")], [
          html.button(
            [
              attribute.type_("button"),
              ui.on_class("btn", p.link == processes.Linked),
              ui.pressed(p.link == processes.Linked),
              event.on_click(ReaderToggledLink),
            ],
            [
              html.text(case p.link {
                processes.Linked -> "Unlink cart ⇄ payment"
                processes.Unlinked -> "Link cart ⇄ payment"
              }),
            ],
          ),
          html.span([class("muted tour-hide"), css("font-size:14px")], [
            html.text(
              "A link ties two processes' fates: if one dies, the other gets an exit signal and dies too.",
            ),
          ]),
        ]),
      ]),
      html.div([class("log-col"), css("flex:1 1 300px")], [
        html.div([class("meta"), css("margin-bottom:6px")], [
          html.text("What just happened"),
        ]),
        html.div(
          [class("log"), css("min-height:300px")],
          list.map(p.log, fn(line) { html.div([class("l")], [html.text(line)]) }),
        ),
        html.p([class("muted"), css("font-size:13px;margin-top:10px")], [
          html.text(
            int.to_string(processes.running_count(p))
            <> " processes running here. A real BEAM node runs millions on a laptop.",
          ),
        ]),
      ]),
    ]),
  ])
}

fn button(classes: String, msg: Msg, label: String) -> Element(Msg) {
  html.button([attribute.type_("button"), class(classes), event.on_click(msg)], [
    html.text(label),
  ])
}

fn chooser(
  label: String,
  p: Processes,
  selected: Int,
  pick: fn(Int) -> Msg,
) -> Element(Msg) {
  html.div([], [
    html.div([class("meta"), css("margin-bottom:6px")], [html.text(label)]),
    html.div(
      [class("seg")],
      list.map(processes.choices(p), fn(process) {
        html.button(
          [
            attribute.type_("button"),
            ui.on_class("", process.id == selected),
            ui.pressed(process.id == selected),
            event.on_click(pick(process.id)),
          ],
          [html.text(process.name)],
        )
      }),
    ),
  ])
}

fn process_card(p: Processes, process: Process) -> Element(Msg) {
  let alive = processes.is_alive(process)
  let linked = processes.is_linked(p, process.id)
  let mailbox = processes.mailbox(process)
  let border = case linked, alive {
    True, _ -> "#B0186E"
    False, True -> "#E4E0D8"
    False, False -> "#E9B8B2"
  }
  let #(background, status, status_bg, status_fg) = case alive {
    True -> #("#FFFFFF", "running", "#E2F4E7", "#0E4D25")
    False -> #("#FBF3F2", "crashed", "#FDECEA", "#7A1A12")
  }
  let link_note = case linked, alive {
    True, _ ->
      case process.id == 1 {
        True -> "linked ⇄ payment"
        False -> "linked ⇄ cart"
      }
    False, True -> "pid #" <> int.to_string(100 + process.id)
    False, False -> "no longer exists"
  }
  html.div(
    [
      css(
        "border-radius:16px;padding:14px;border:2px solid "
        <> border
        <> ";background:"
        <> background
        <> ";display:flex;flex-direction:column;gap:10px;min-height:150px",
      ),
    ],
    [
      html.div(
        [css("display:flex;justify-content:space-between;align-items:center")],
        [
          html.b([class("mono"), css("font-size:15px")], [
            html.text(process.name),
          ]),
          html.span(
            [
              class("chip"),
              css("background:" <> status_bg <> ";color:" <> status_fg),
            ],
            [html.text(status)],
          ),
        ],
      ),
      html.div([class("meta"), css("font-size:12px")], [html.text(link_note)]),
      html.div([css("font-size:12px"), class("muted")], [
        html.text("Mailbox (" <> int.to_string(list.length(mailbox)) <> ")"),
      ]),
      html.div(
        [css("display:flex;flex-wrap:wrap;gap:4px;min-height:28px")],
        list.map(mailbox, fn(message) {
          html.span([class("chip"), css("background:#EBEAFD;color:#2B2862")], [
            html.text(message),
          ])
        }),
      ),
      html.div([class("meta"), css("font-size:12px")], [
        html.text("handled: " <> int.to_string(processes.handled(process))),
      ]),
      html.div([class("row"), css("gap:6px;margin-top:auto")], case alive {
        True -> [
          html.button(
            [
              attribute.type_("button"),
              class("btn sm"),
              event.on_click(ReaderHandledMessage(process.id)),
              attribute.disabled(mailbox == []),
            ],
            [html.text("Handle one")],
          ),
          button("btn sm warn", ReaderCrashedProcess(process.id), "Crash"),
        ]
        False -> [
          button("btn sm", ReaderRestartedProcess(process.id), "Start again"),
        ]
      }),
    ],
  )
}

// TIMELINE --------------------------------------------------------------------

fn timeline(p: Processes) -> Element(Msg) {
  let shown = list.take(p.processes, 6)
  let lane = fn(id) {
    list.index_fold(shown, Error(Nil), fn(found, process, index) {
      case process.id == id {
        True -> Ok(index)
        False -> found
      }
    })
  }
  let events = list.filter_map(p.trace, chart_event(_, lane))
  let count = case events {
    [] -> ""
    _ -> "last " <> int.to_string(list.length(events)) <> " events"
  }
  let chart =
    msc.Chart(
      ..msc.chart(
        "p1",
        list.map(shown, fn(process) { process.name }),
        case events {
          [] -> [msc.Note(0, "nothing yet: send a message", msc.Grey)]
          _ -> events
        },
      ),
      lane_gap: 150,
      numbers: True,
      aria: "Sequence chart of messages, crashes and restarts between the processes",
    )
  html.div([class("card"), css("margin-top:16px")], [
    html.div(
      [class("row"), css("justify-content:space-between;margin-bottom:8px")],
      [
        html.div([], [
          html.div([class("k")], [html.text("The same story as a timeline")]),
          html.p([class("muted"), css("font-size:14px;margin-top:4px")], [
            html.text(
              "A message sequence chart: each column is a process, time flows down. It redraws live as you play.",
            ),
          ]),
        ]),
        html.span([class("meta")], [html.text(count)]),
      ],
    ),
    msc.view(chart),
  ])
}

/// A trace event as the chart draws it, when every process it names has a
/// lane.
fn chart_event(
  trace: Trace,
  lane: fn(Int) -> Result(Int, Nil),
) -> Result(msc.Event, Nil) {
  case trace {
    processes.Delivered(from:, to:, message:) -> {
      use from <- result.try(lane(from))
      use to <- result.try(lane(to))
      Ok(msc.send(from, to, message, msc.Ink))
    }
    processes.Dropped(from:, to:, message:) -> {
      use from <- result.try(lane(from))
      use to <- result.try(lane(to))
      Ok(msc.Lost(from, to, message <> " (dropped)", msc.Grey))
    }
    processes.HandledOne(at:, message:) -> {
      use at <- result.try(lane(at))
      Ok(msc.Note(at, "handles " <> message, msc.Blue))
    }
    processes.CrashedHere(at:) -> {
      use at <- result.try(lane(at))
      Ok(msc.Crash(at, "crashes"))
    }
    processes.ExitSignal(from:, to:) -> {
      use from <- result.try(lane(from))
      use to <- result.try(lane(to))
      Ok(msc.Message(from, to, "EXIT signal", msc.Red, msc.Dashed))
    }
    processes.DiedToo(at:) -> {
      use at <- result.try(lane(at))
      Ok(msc.Crash(at, "dies too"))
    }
    processes.StartedAgain(at:) -> {
      use at <- result.try(lane(at))
      Ok(msc.Note(at, "started again", msc.Green))
    }
  }
}

// SCHEDULER PLAYGROUND --------------------------------------------------------

fn scheduler_playground(model: Model, context: Context) -> Element(Msg) {
  let scheduling = model.scheduling
  let workload = model.workload
  let greedy = workload == WithGreedy
  let controls = scheduler_controls(model)
  element.fragment([
    html.div([class("labh")], [
      html.div([], [
        html.span([class("tag")], [html.text("Playground")]),
        html.h2([css("font-size:28px;margin-top:10px")], [
          html.text("Two cores, five processes"),
        ]),
        html.p([class("muted"), css("margin-top:6px;max-width:640px")], [
          html.text(
            "Processes wake when a message arrives, wait in the run queue for a free core, work, and sleep again. Each square is one time slice on a core. Add a greedy process that never stops working, then switch between scheduling styles.",
          ),
        ]),
      ]),
    ]),
    html.div([class("row"), css("gap:16px;margin-bottom:20px")], [
      html.div([class("seg")], [
        style_button(Cooperative, "Cooperative (most runtimes)", scheduling),
        style_button(Preemptive, "Preemptive (the BEAM)", scheduling),
      ]),
      html.button(
        [
          attribute.type_("button"),
          class(case greedy {
            True -> "btn warn"
            False -> "btn"
          }),
          ui.pressed(greedy),
          event.on_click(ReaderToggledGreedy),
        ],
        [
          html.text(case greedy {
            True -> "Remove the greedy process"
            False -> "Add a greedy process (G)"
          }),
        ],
      ),
      case context.animates(context) {
        True -> element.none()
        False ->
          html.button(
            [
              attribute.type_("button"),
              class("btn sm"),
              event.on_click(ReaderAdvancedScheduler),
            ],
            [html.text("Advance 1 second")],
          )
      },
    ]),
    element.element(
      scheduler_widget.tag,
      [
        attribute("data-live", "scheduler"),
        class("live"),
        css("display:block;width:100%"),
        ..scheduler_widget.attributes(controls, context.motion)
      ],
      [],
    ),
    html.div([class("note"), css("margin-top:16px")], [
      html.text(scheduler.note(scheduling, workload)),
    ]),
  ])
}

fn style_button(
  style: Scheduling,
  label: String,
  current: Scheduling,
) -> Element(Msg) {
  html.button(
    [
      attribute.type_("button"),
      ui.on_class("", style == current),
      ui.pressed(style == current),
      event.on_click(ReaderPickedScheduling(style)),
    ],
    [html.text(label)],
  )
}

// SUMMARY ---------------------------------------------------------------------

fn one_picture() -> Element(Msg) {
  let tile = fn(style, meta_style, n, title, body_style, body) {
    html.div([class("box"), css(style)], [
      html.div([class("meta"), meta_style], [html.text(n)]),
      html.b([], [html.text(title)]),
      html.p([css(body_style)], [html.text(body)]),
    ])
  }
  html.section([class("wrap sec")], [
    html.div([class("k")], [html.text("Read · the BEAM in one picture")]),
    html.h2([class("h2")], [html.text("What you now know, from the bottom up")]),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-top:24px",
        ),
      ],
      [
        tile(
          "background:#2B2862;color:#fff;border:0",
          css("color:#C9C6E0"),
          "1",
          "Cores",
          "font-size:14px;color:#C9C6E0;margin-top:4px",
          "One scheduler per core shares time fairly.",
        ),
        tile(
          "background:#3E3A86;color:#fff;border:0",
          css("color:#D9D6F2"),
          "2",
          "Processes",
          "font-size:14px;color:#D9D6F2;margin-top:4px",
          "Isolated memory, cheap to start, cheap to kill.",
        ),
        tile(
          "background:#5651A8;color:#fff;border:0",
          css("color:#E6E4F8"),
          "3",
          "Messages",
          "font-size:14px;color:#E6E4F8;margin-top:4px",
          "Copied values, queued in mailboxes, handled one at a time.",
        ),
        tile(
          "background:#DCD9FF;color:#241F6B;border:0",
          attribute.none(),
          "4",
          "Links & monitors",
          "font-size:14px;margin-top:4px",
          "Failure becomes a signal another process can act on. Next module: OTP.",
        ),
      ],
    ),
    booklets.card(
      booklets.resilience,
      "Chapter 1 takes this module further: why a process costs 2.6 KB where a thread reserves megabytes, how messages are copied, and how links, monitors and trapped exits make failure a message another process can act on.",
    ),
    ui.carry_forward(
      "On the BEAM you don't try to prevent every failure. You contain it. A process is the unit of concurrency, of state and of failure.",
    ),
  ])
}
