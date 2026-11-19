//// Module 8, work that outlives a request: Grind jobs (a lifecycle you
//// drive, a live queue with leases, transactional admission) and Saga
//// workflows (one checkout, then two hundred).

import gleam/float
import gleam/int
import gleam/list
import lustre
import lustre/attribute.{attribute, class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import pages/durable_work/checkout.{
  type Crash, type Durability, type Payment, type Plan, type Screening,
  type Shipping, type StepState, type Stock, CrashAfterCharge, Durable, Local,
  NoCrash,
}
import pages/durable_work/checkouts.{type Rate, type Rates}
import pages/durable_work/job.{
  type Abandonment, type Job, HoldUncertain, ReplayAfterLeaseExpiry,
}
import pages/durable_work/queue_widget
import site/browser
import site/context.{type Context}
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  Grind
  Lease
  Tx
  Saga
  Sagax
}

/// How the order row and its email job reach the database.
pub type Admission {
  SameTransactionCommits
  SameTransactionRollsBack
  SeparateWritesWithCrash
}

/// How much of a checkout run is on screen.
pub type Run {
  NotRun
  /// Events up to `upto` are shown and nothing more is coming.
  Showing(upto: Int)
  /// Events up to `upto` are shown; the next arrives with tick `epoch`.
  Replaying(upto: Int, epoch: Int)
}

pub type Checkout {
  Checkout(
    plan: Plan,
    crash: Crash,
    durability: Durability,
    run: Run,
    /// Runs started so far; each run's ticks carry its number.
    started: Int,
  )
}

pub type Model {
  Model(
    job: Job,
    abandonment: Abandonment,
    queue: queue_widget.Controls,
    admission: Admission,
    checkout: Checkout,
    rates: Rates,
    runs: List(checkouts.Run),
    tours: tour.Tours(TourId),
  )
}

pub type Msg {
  ReaderJumpedTo(String)
  ReaderPickedAbandonment(Abandonment)
  ReaderDroveJob(job.Event)
  ReaderAddedJobs
  ReaderResetQueue
  ReaderPickedLeaseExpiry(Abandonment)
  /// "Advance 1 second" with motion off: five ticks of 220 ms.
  ReaderAdvancedQueue
  ReaderKilledWorker(Int)
  /// A tour step moves the queue on by this many ticks when motion is off;
  /// with motion on the queue is already running.
  TourHurriedQueue(Int)
  /// A tour step that says a lease expired moves the queue on until every
  /// abandoned lease has, with or without motion.
  TourAwaitedLeaseExpiry
  ReaderPickedAdmission(Admission)
  ReaderChoseStock(Stock)
  ReaderChoseScreening(Screening)
  ReaderChosePayment(Payment)
  ReaderChoseShipping(Shipping)
  ReaderToggledCrash
  ReaderToggledDurability
  ReaderRanCheckout
  ReaderResetCheckout
  CheckoutTicked(epoch: Int)
  ReaderMovedRate(Rate, Int)
  /// Load one of the two hundred runs into the checkout above and run it.
  ReaderPickedCheckout(Int)
  Tour(TourId, tour.Command)
}

fn fresh_checkout(started: Int) -> Checkout {
  Checkout(
    plan: checkout.happy,
    crash: NoCrash,
    durability: Durable,
    run: NotRun,
    started:,
  )
}

pub fn init() -> Model {
  Model(
    job: job.new(),
    abandonment: HoldUncertain,
    queue: queue_widget.controls(),
    admission: SameTransactionCommits,
    checkout: fresh_checkout(0),
    rates: checkouts.defaults,
    runs: checkouts.runs(checkouts.defaults),
    tours: tour.new(),
  )
}

// UPDATE ----------------------------------------------------------------------

/// The milliseconds between two events of an animated checkout run.
const event_ms = 900

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  let none = fn(model) { #(model, effect.none()) }
  let issue = fn(command) {
    none(Model(..model, queue: queue_widget.issue(model.queue, command)))
  }
  case msg {
    ReaderJumpedTo(id) -> #(
      model,
      browser.jump_to(id, context.animates(context)),
    )
    ReaderPickedAbandonment(abandonment) -> none(Model(..model, abandonment:))
    ReaderDroveJob(event) ->
      none(Model(..model, job: job.apply(model.job, event, model.abandonment)))
    ReaderAddedJobs -> issue(queue_widget.AddJobs)
    ReaderResetQueue -> issue(queue_widget.Reset)
    ReaderPickedLeaseExpiry(expiry) -> issue(queue_widget.Expire(expiry))
    ReaderAdvancedQueue -> issue(queue_widget.Advance(5))
    ReaderKilledWorker(index) -> issue(queue_widget.Kill(index))
    TourHurriedQueue(ticks) ->
      case context.animates(context) {
        True -> none(model)
        False -> issue(queue_widget.Advance(ticks))
      }
    TourAwaitedLeaseExpiry -> issue(queue_widget.AdvanceUntilExpired)
    ReaderPickedAdmission(admission) -> none(Model(..model, admission:))
    ReaderChoseStock(stock) ->
      none(replan(model, checkout.Plan(..model.checkout.plan, stock:)))
    ReaderChoseScreening(screening) ->
      none(replan(model, checkout.Plan(..model.checkout.plan, screening:)))
    ReaderChosePayment(payment) ->
      none(replan(model, checkout.Plan(..model.checkout.plan, payment:)))
    ReaderChoseShipping(shipping) ->
      none(replan(model, checkout.Plan(..model.checkout.plan, shipping:)))
    ReaderToggledCrash -> {
      let crash = case model.checkout.crash {
        NoCrash -> CrashAfterCharge
        CrashAfterCharge -> NoCrash
      }
      none(
        Model(
          ..model,
          checkout: Checkout(..model.checkout, crash:, run: NotRun),
        ),
      )
    }
    ReaderToggledDurability -> {
      let durability = case model.checkout.durability {
        Durable -> Local
        Local -> Durable
      }
      none(
        Model(
          ..model,
          checkout: Checkout(..model.checkout, durability:, run: NotRun),
        ),
      )
    }
    ReaderRanCheckout -> run_checkout(model, context)
    ReaderResetCheckout ->
      none(Model(..model, checkout: fresh_checkout(model.checkout.started)))
    CheckoutTicked(epoch) -> tick_checkout(model, epoch)
    ReaderMovedRate(which, value) -> {
      let rates = checkouts.set_rate(model.rates, which, value)
      none(Model(..model, rates:, runs: checkouts.runs(rates)))
    }
    ReaderPickedCheckout(index) ->
      case list.drop(model.runs, index) {
        [] -> none(model)
        [picked, ..] -> {
          // The replay is the reader's own run: the checkout above leaves its
          // guided tour, which drops any advance it had scheduled.
          let #(model, unlocked) =
            tour.update(driver(context), model, Saga, tour.Skip, context.motion)
          let model =
            Model(
              ..model,
              checkout: Checkout(
                ..model.checkout,
                plan: picked.plan,
                crash: NoCrash,
                run: NotRun,
              ),
            )
          let #(model, effect) = run_checkout(model, context)
          #(
            model,
            effect.batch([
              unlocked,
              effect,
              browser.jump_to("saga", context.animates(context)),
            ]),
          )
        }
      }
    Tour(id, command) ->
      tour.update(driver(context), model, id, command, context.motion)
  }
}

/// A new behaviour for a step clears the run on screen.
fn replan(model: Model, plan: Plan) -> Model {
  Model(..model, checkout: Checkout(..model.checkout, plan:, run: NotRun))
}

fn events(c: Checkout) -> List(checkout.Event) {
  checkout.events(c.plan, c.crash, c.durability)
}

/// With motion, events appear one by one; without, the run shows at once.
fn run_checkout(model: Model, context: Context) -> #(Model, Effect(Msg)) {
  let c = model.checkout
  let started = c.started + 1
  case context.animates(context) {
    False -> #(
      Model(
        ..model,
        checkout: Checkout(
          ..c,
          started:,
          run: Showing(list.length(events(c)) - 1),
        ),
      ),
      effect.none(),
    )
    True -> #(
      Model(
        ..model,
        checkout: Checkout(..c, started:, run: Replaying(0, started)),
      ),
      browser.after(event_ms, CheckoutTicked(started)),
    )
  }
}

fn tick_checkout(model: Model, epoch: Int) -> #(Model, Effect(Msg)) {
  let c = model.checkout
  case c.run {
    Replaying(upto:, epoch: current) if current == epoch -> {
      let last = list.length(events(c)) - 1
      let next = upto + 1
      case next >= last {
        True -> #(
          Model(
            ..model,
            checkout: Checkout(..c, run: Showing(int.min(next, last))),
          ),
          effect.none(),
        )
        False -> #(
          Model(..model, checkout: Checkout(..c, run: Replaying(next, epoch))),
          browser.after(event_ms, CheckoutTicked(epoch)),
        )
      }
    }
    _ -> #(model, effect.none())
  }
}

/// Leaving the page (or turning motion off) pauses tours and freezes an
/// animated checkout where it is.
pub fn leave(model: Model) -> Model {
  let c = model.checkout
  let run = case c.run {
    Replaying(upto:, ..) -> Showing(upto)
    other -> other
  }
  Model(
    ..model,
    checkout: Checkout(..c, run:),
    tours: tour.pause_all(model.tours),
  )
}

/// Register the live Grind queue.
pub fn register() -> Result(Nil, lustre.Error) {
  queue_widget.register()
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
    Grind -> "grind"
    Lease -> "lease"
    Tx -> "tx"
    Saga -> "saga"
    Sagax -> "sagax"
  }
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  let send = fn(msgs) { fn(_) { msgs } }
  case id {
    Grind ->
      tour.Script(
        reset: send([
          ReaderPickedAbandonment(HoldUncertain),
          ReaderDroveJob(job.StartOver),
        ]),
        steps: [
          tour.say(
            "One job, mailer.send, allowed 3 attempts. Every change you see is a row update in PostgreSQL.",
          ),
          tour.act(
            "Submit it. Grind writes the row before anything runs: the job is now Queued.",
            send([ReaderDroveJob(job.SubmitNow)]),
          ),
          tour.act(
            "A coordinator for the mailers queue claims it under a lease and starts an attempt process: Executing, attempt 1.",
            send([ReaderDroveJob(job.Claim)]),
          ),
          tour.act(
            "The handler returns an error. Attempts remain, so the job becomes Retryable and waits out a backoff.",
            send([ReaderDroveJob(job.HandlerFails)]),
          ),
          tour.act(
            "The backoff passes and it’s claimed again: attempt 2.",
            send([
              ReaderDroveJob(job.BackoffPasses),
              ReaderDroveJob(job.Claim),
            ]),
          ),
          tour.act(
            "The node dies mid-attempt. Did the email go out? Grind won’t guess: by default the job is held as Uncertain.",
            send([ReaderDroveJob(job.NodeDies)]),
          ),
          tour.act(
            "An operator checks the mail provider and records an audited resolution: it was sent. Now drive a job yourself.",
            send([ReaderDroveJob(job.AuditSent)]),
          ),
        ],
      )
    Lease ->
      tour.Script(reset: send([ReaderResetQueue]), steps: [
        tour.act(
          "Three workers claim rows from the same table. Each claim skips rows other workers have locked, so no job is ever run twice at once.",
          send([TourHurriedQueue(10)]),
        ),
        tour.act(
          "Blue bars are leases. The pink heart is the renewer: every second, on its own connection, it tops up the leases of live workers.",
          send([TourHurriedQueue(10)]),
        )
          |> tour.lasting(4500),
        tour.act(
          "Kill W2 in the middle of a job. Nobody renews its lease now: watch its bar drain in red.",
          send([ReaderKilledWorker(1), TourHurriedQueue(8)]),
        )
          |> tour.lasting(4500),
        tour.act(
          "The lease expires with no result. By default Grind holds the job as Uncertain instead of guessing whether the email went out.",
          send([TourHurriedQueue(12), TourAwaitedLeaseExpiry]),
        )
          |> tour.lasting(4500),
        tour.act(
          "Switch to \"replay it\", for handlers that are safe to repeat, and kill W3. Its job goes back to the queue for another worker.",
          send([
            ReaderPickedLeaseExpiry(ReplayAfterLeaseExpiry),
            ReaderKilledWorker(2),
            TourHurriedQueue(20),
          ]),
        )
          |> tour.lasting(6000),
        tour.say(
          "The row is the truth, the process is just borrowed time. Kill and restart workers yourself.",
        ),
      ])
    Tx ->
      tour.Script(
        reset: send([ReaderPickedAdmission(SameTransactionCommits)]),
        steps: [
          tour.say(
            "A new order must send a confirmation email: an order row and a job row that should exist together or not at all.",
          ),
          tour.act(
            "Submit the job inside the order’s transaction and commit: both rows exist.",
            send([ReaderPickedAdmission(SameTransactionCommits)]),
          ),
          tour.act(
            "If the order insert fails, the transaction rolls back, and the job vanishes with it. No email about a phantom order.",
            send([ReaderPickedAdmission(SameTransactionRollsBack)]),
          ),
          tour.act(
            "Two separate writes with a crash in between: an order with no email, and nothing records the loss. That’s the bug transactional admission removes.",
            send([ReaderPickedAdmission(SeparateWritesWithCrash)]),
          ),
        ],
      )
    Saga ->
      tour.Script(reset: send([ReaderResetCheckout]), steps: [
        tour.say(
          "A checkout saga: reserve stock and run a fraud check in parallel, then charge, then ship.",
        ),
        tour.act(
          "Everything succeeds. The coordinator starts both ready steps at once, then follows the dependencies.",
          send([ReaderRanCheckout]),
        )
          |> tour.lasting(6500),
        tour.act(
          "Now shipping fails after the charge. Saga undoes what it knows succeeded, newest first: refund, then release the stock.",
          send([ReaderChoseShipping(checkout.CarrierRejects), ReaderRanCheckout]),
        )
          |> tour.lasting(8000),
        tour.act(
          "The charge result stays unknown even after retries with the same key. Nothing is undone: the run is held for reconciliation.",
          send([
            ReaderChoseShipping(checkout.Booked),
            ReaderChosePayment(checkout.StaysUnknown),
            ReaderRanCheckout,
          ]),
        )
          |> tour.lasting(8000),
        tour.act(
          "Crash the node after charging, in a local run: the run dies with its caller, mid-flight, with no record.",
          fn(model: Model) {
            list.flatten([
              [ReaderChosePayment(checkout.Paid)],
              case model.checkout.crash {
                NoCrash -> [ReaderToggledCrash]
                CrashAfterCharge -> []
              },
              case model.checkout.durability {
                Durable -> [ReaderToggledDurability]
                Local -> []
              },
              [ReaderRanCheckout],
            ])
          },
        )
          |> tour.lasting(6500),
        tour.act(
          "Same crash in durable mode: the checkpoint survives, the run resumes, and the charge is not repeated.",
          fn(model: Model) {
            case model.checkout.durability {
              Durable -> [ReaderRanCheckout]
              Local -> [ReaderToggledDurability, ReaderRanCheckout]
            }
          },
        )
          |> tour.lasting(8000),
        tour.say(
          "Mix the failures yourself, then scroll down to see two hundred runs at once.",
        ),
      ])
    Sagax ->
      tour.Script(
        reset: send(
          list.map(checkouts.all_rates, fn(which) {
            ReaderMovedRate(which, checkouts.rate(checkouts.defaults, which))
          }),
        ),
        steps: [
          tour.say(
            "Two hundred checkouts with realistic failure rates. Most complete; a few compensate; a couple stop at the first step.",
          ),
          tour.act(
            "A flaky payment provider: unknown results jump to 30%. Yellow appears: runs Saga refuses to guess about.",
            send([ReaderMovedRate(checkouts.UnknownRate, 30)]),
          ),
          tour.act(
            "A bad week for the carrier too: shipping fails 20% of the time, and amber compensations spread.",
            send([ReaderMovedRate(checkouts.ShippingRate, 20)]),
          ),
          tour.say(
            "However bad it gets, nobody is charged twice. Now move down the ladder: click any square to replay that exact checkout above.",
          ),
        ],
      )
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model, context: Context) -> Element(Msg) {
  let d = driver(context)
  element.fragment([
    hero(),
    html.section(
      [class("wrap sec"), attribute.id("grind"), attribute("tabindex", "-1")],
      [
        html.div([class("k")], [html.text("Grind · durable jobs")]),
        html.h2([class("h2")], [
          html.text("A job is a row first, a process second"),
        ]),
        html.p([class("lead")], [
          html.text(
            "When you submit a job, Grind writes a row. A per-queue coordinator claims rows into local capacity under a database ",
          ),
          html.b([], [html.text("lease")]),
          html.text(
            " and starts a short-lived attempt process to run your handler. The row, not the process, is the truth: if the node dies, the lease runs out and the job is still there.",
          ),
        ]),
        tour.lab(model.tours, Grind, d, context, [], lifecycle(model)),
        tour.lab(model.tours, Lease, d, context, [], lease(model, context)),
        tour.lab(model.tours, Tx, d, context, [], admission(model.admission)),
      ],
    ),
    html.section(
      [class("wrap sec"), attribute.id("saga"), attribute("tabindex", "-1")],
      [
        html.div([class("k")], [html.text("Saga · workflows with undo")]),
        html.h2([class("h2")], [
          html.text(
            "Steps that depend on each other, and a plan for when they fail",
          ),
        ]),
        html.p([class("lead")], [
          html.text(
            "You describe a workflow in Gleam: typed steps, what each needs, how to undo it, and what to do if its effect is uncertain. One coordinator process per run starts ready steps concurrently, records evidence, and on failure undoes the steps it knows succeeded, newest first.",
          ),
        ]),
        tour.lab(model.tours, Saga, d, context, [], saga(model.checkout)),
        tour.lab(model.tours, Sagax, d, context, [], ladder(model)),
        html.div([class("note"), css("margin-top:16px")], [
          html.b([], [html.text("What Saga can't do:")]),
          html.text(
            " make a provider's charge and your database commit one transaction. It only undoes steps it ",
          ),
          html.i([], [html.text("knows")]),
          html.text(
            " succeeded, gives every attempt of an effect the same idempotency key, and holds what it can't prove for your application to reconcile.",
          ),
        ]),
      ],
    ),
    which(),
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
      html.text("Module 8 · Phase 3: the building blocks"),
    ]),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:940px")],
      [html.text("Work that outlives a request")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "Some work can't finish while the user waits, or must survive a crash halfway through. ",
      ),
      html.b([], [html.text("Grind")]),
      html.text(" runs durable background jobs on PostgreSQL. "),
      html.b([], [html.text("Saga")]),
      html.text(
        " runs workflows of dependent steps and knows how to undo them. Together they're how money, stock and messages move exactly as intended.",
      ),
    ]),
    html.div([class("row"), css("margin-top:28px;gap:10px")], [
      pill(
        "grind",
        "text-decoration:none;color:#6B3404;background:#FDF0DC",
        "Grind · durable jobs",
      ),
      pill(
        "saga",
        "text-decoration:none;color:#6B3404;background:#FDF0DC",
        "Saga · workflows with undo",
      ),
      pill("which", "text-decoration:none;color:#17162B", "Which coordinator?"),
    ]),
  ])
}

fn lab_head(
  tag: String,
  title: String,
  description: List(Element(Msg)),
  width: String,
  side: List(Element(Msg)),
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
    ..side
  ])
}

fn seg_button(label: String, on: Bool, msg: Msg) -> Element(Msg) {
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

fn log(lines: List(String), style: String) -> Element(Msg) {
  html.div(
    [class("log"), css(style)],
    list.map(lines, fn(line) { html.div([class("l")], [html.text(line)]) }),
  )
}

// GRIND LIFECYCLE -------------------------------------------------------------

fn lifecycle(model: Model) -> List(Element(Msg)) {
  let j = model.job
  [
    lab_head(
      "Playground",
      "Drive a job through its life",
      [
        html.text("Job: "),
        html.span([class("mono")], [html.text("mailer.send")]),
        html.text(", at most 3 attempts. Choose what happens at each stage."),
      ],
      "660px",
      [
        html.div([class("row")], [
          html.span([class("meta")], [html.text("If an attempt is abandoned:")]),
          html.div([class("seg")], [
            seg_button(
              "hold as Uncertain (default)",
              model.abandonment == HoldUncertain,
              ReaderPickedAbandonment(HoldUncertain),
            ),
            seg_button(
              "replay after lease expiry",
              model.abandonment == ReplayAfterLeaseExpiry,
              ReaderPickedAbandonment(ReplayAfterLeaseExpiry),
            ),
          ]),
        ]),
      ],
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:8px",
        ),
      ],
      list.map(job.shown, fn(entry) {
        let #(state, tiny) = entry
        let on = j.phase == job.Stored(state)
        let #(bg, fg, border) = case on, job.is_terminal(state) {
          True, _ -> #("#6B3404", "#FFFFFF", "#6B3404")
          False, True -> #("#FFFFFF", "#5B5970", "#E4E0D8")
          False, False -> #("#FFFFFF", "#17162B", "#E4E0D8")
        }
        html.div(
          [
            css(
              "border-radius:12px;padding:10px 12px;min-height:64px;background:"
              <> bg
              <> ";color:"
              <> fg
              <> ";border:2px solid "
              <> border
              <> ";display:flex;flex-direction:column;gap:2px",
            ),
          ],
          [
            html.b([class("mono"), css("font-size:13px")], [
              html.text(job.name(state)),
            ]),
            html.span([css("font-size:12px;opacity:.85")], [html.text(tiny)]),
          ],
        )
      }),
    ),
    html.div(
      [class("split with-log"), css("margin-top:20px;align-items:flex-start")],
      [
        html.div([css("flex:1 1 380px")], [
          html.div(
            [class("box"), css("background:#FDF0DC;border-color:#F3D9B1")],
            [
              html.div([class("meta")], [html.text("now")]),
              html.div(
                [css("font:600 24px 'Space Grotesk',sans-serif;margin:4px 0")],
                [
                  html.text(job.title(j.phase)),
                ],
              ),
              html.p([css("font-size:15px")], [html.text(job.why(j.phase))]),
              html.div([class("meta"), css("margin-top:8px")], [
                html.text(
                  "attempts used: "
                  <> int.to_string(j.attempts)
                  <> " / "
                  <> int.to_string(job.max_attempts),
                ),
              ]),
            ],
          ),
          html.div([class("meta"), css("margin:16px 0 8px")], [
            html.text("What happens next?"),
          ]),
          html.div(
            [css("display:flex;flex-direction:column;gap:8px")],
            list.map(job.choices(j), fn(choice) {
              html.button(
                [
                  attribute.type_("button"),
                  class(case choice.warn {
                    True -> "btn warn"
                    False -> "btn"
                  }),
                  event.on_click(ReaderDroveJob(choice.event)),
                  css("justify-content:flex-start"),
                ],
                [html.text(choice.label)],
              )
            }),
          ),
        ]),
        html.div([class("log-col"), css("flex:1 1 320px")], [
          html.div([class("meta"), css("margin-bottom:8px")], [
            html.text("The job's history (kept in PostgreSQL)"),
          ]),
          log(j.history, "min-height:300px"),
        ]),
      ],
    ),
  ]
}

// GRIND QUEUE -----------------------------------------------------------------

fn lease(model: Model, context: Context) -> List(Element(Msg)) {
  let expiry = model.queue.expiry
  let touring = tour.is_touring(tour.get(model.tours, Lease))
  [
    lab_head(
      "Simulation",
      "Inside a queue: claims, leases, heartbeats",
      [
        html.text("Three workers on the "),
        html.span([class("mono")], [html.text("mailers")]),
        html.text(
          " queue. Each claims the next free row, skipping rows another worker has locked. A claim is a ",
        ),
        html.b([], [html.text("lease")]),
        html.text(
          " with a deadline; a separate renewer keeps live leases fresh. Kill a worker and watch what happens to its job.",
        ),
      ],
      "720px",
      [
        html.div([class("row")], [
          small_button("+ 6 jobs", ReaderAddedJobs),
          small_button("Reset", ReaderResetQueue),
        ]),
      ],
    ),
    html.div([class("row"), css("gap:12px;margin-bottom:16px")], [
      html.span([class("meta")], [html.text("When a lease expires")]),
      html.div([class("seg")], [
        seg_button(
          "hold as Uncertain (default)",
          expiry == HoldUncertain,
          ReaderPickedLeaseExpiry(HoldUncertain),
        ),
        seg_button(
          "replay it",
          expiry == ReplayAfterLeaseExpiry,
          ReaderPickedLeaseExpiry(ReplayAfterLeaseExpiry),
        ),
      ]),
      case context.animates(context) {
        True -> element.none()
        False -> small_button("Advance 1 second", ReaderAdvancedQueue)
      },
    ]),
    queue_widget.element(model.queue, context.motion, touring),
  ]
}

fn small_button(label: String, msg: Msg) -> Element(Msg) {
  html.button(
    [attribute.type_("button"), class("btn sm"), event.on_click(msg)],
    [html.text(label)],
  )
}

// TRANSACTIONAL ADMISSION -----------------------------------------------------

fn admission(current: Admission) -> List(Element(Msg)) {
  let #(order, job_row, why, order_bg, job_bg, verdict_bg, verdict) = case
    current
  {
    SameTransactionCommits -> #(
      "Order o-1",
      "mailer.send for o-1",
      "Committed together. The email will be sent for an order that really exists.",
      "#E2F4E7",
      "#E2F4E7",
      "#E2F4E7",
      "Consistent: both exist",
    )
    SameTransactionRollsBack -> #(
      "(nothing)",
      "(nothing)",
      "The order insert failed, so the whole transaction rolled back, job included. No email about an order that doesn’t exist.",
      "#F1EEE8",
      "#F1EEE8",
      "#E2F4E7",
      "Consistent: neither exists",
    )
    SeparateWritesWithCrash -> #(
      "Order o-1",
      "(nothing)",
      "Two separate writes, and the node crashed between them. The order is saved, but no email will ever be sent, and nothing records that it was supposed to be.",
      "#E2F4E7",
      "#FDECEA",
      "#FDECEA",
      "Inconsistent: a lost job",
    )
  }
  let table = fn(bg, label, value) {
    html.div([class("box"), css("background:" <> bg)], [
      html.div([class("meta")], [html.text(label)]),
      html.b([css("font-size:18px")], [html.text(value)]),
    ])
  }
  [
    lab_head(
      "Playground",
      "Submit in the same transaction",
      [
        html.text(
          "A new order should send a confirmation email. The order row and the email job must exist together or not at all.",
        ),
      ],
      "680px",
      [],
    ),
    html.div(
      [class("seg"), css("margin-bottom:20px")],
      list.map(
        [
          #(SameTransactionCommits, "Same transaction: commits"),
          #(SameTransactionRollsBack, "Same transaction: rolls back"),
          #(SeparateWritesWithCrash, "Two separate writes + crash"),
        ],
        fn(option) {
          seg_button(
            option.1,
            option.0 == current,
            ReaderPickedAdmission(option.0),
          )
        },
      ),
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px",
        ),
      ],
      [
        table(order_bg, "orders table", order),
        table(job_bg, "grind jobs table", job_row),
        table(verdict_bg, "result", verdict),
      ],
    ),
    html.p([css("font-size:15px;margin-top:14px")], [html.text(why)]),
  ]
}

// SAGA CHECKOUT ---------------------------------------------------------------

fn upto(run: Run) -> Int {
  case run {
    NotRun -> -1
    Showing(upto:) -> upto
    Replaying(upto:, ..) -> upto
  }
}

/// What the outcome box says about the run on screen. An unfinished run that
/// was frozen (motion turned off, or the reader left) is paused: no more
/// events are coming.
pub fn outcome_label(c: Checkout) -> String {
  case checkout.snapshot(events(c), upto(c.run)).progress, c.run {
    checkout.NotStarted, _ -> "Not started"
    checkout.InFlight, Replaying(..) -> "Running…"
    checkout.InFlight, _ -> "Paused"
    checkout.Finished(outcome), _ -> checkout.outcome_text(outcome)
  }
}

fn saga(c: Checkout) -> List(Element(Msg)) {
  let snap = checkout.snapshot(events(c), upto(c.run))
  let plan = c.plan
  let choice = fn(label, options) {
    html.div([], [
      html.div([class("meta"), css("margin-bottom:6px")], [html.text(label)]),
      html.div(
        [class("seg")],
        list.map(options, fn(o: #(String, Bool, Msg)) {
          seg_button(o.0, o.1, o.2)
        }),
      ),
    ])
  }
  let crash_on = c.crash == CrashAfterCharge
  let durable = c.durability == Durable
  let outcome = outcome_label(c)
  let #(out_bg, out_fg) = case snap.progress {
    checkout.NotStarted | checkout.InFlight -> #("#F1EEE8", "#17162B")
    checkout.Finished(checkout.Completed) -> #("#E2F4E7", "#0E4D25")
    checkout.Finished(checkout.Aborted(_)) | checkout.Finished(checkout.Lost) -> #(
      "#FDECEA",
      "#7A1A12",
    )
    checkout.Finished(checkout.HeldForReconciliation) -> #("#FFF1C2", "#5C4300")
  }
  let arrow =
    html.div(
      [class("arrow"), attribute("aria-hidden", "true"), css("flex:0 0 32px")],
      [html.text("→")],
    )
  [
    lab_head(
      "Playground",
      "Checkout",
      [
        html.text(
          "Reserve stock and run a fraud check in parallel, then charge, then ship. Choose how each step behaves, then run it.",
        ),
      ],
      "680px",
      [
        html.div([class("row")], [
          html.button(
            [
              attribute.type_("button"),
              class("btn pri"),
              event.on_click(ReaderRanCheckout),
            ],
            [html.text("Run checkout")],
          ),
          small_button("Reset", ReaderResetCheckout),
        ]),
      ],
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px;margin-bottom:20px",
        ),
      ],
      [
        choice("Reserve stock", [
          #(
            "in stock",
            plan.stock == checkout.InStock,
            ReaderChoseStock(checkout.InStock),
          ),
          #(
            "out of stock",
            plan.stock == checkout.OutOfStock,
            ReaderChoseStock(checkout.OutOfStock),
          ),
        ]),
        choice("Fraud check", [
          #(
            "clear",
            plan.screening == checkout.Clear,
            ReaderChoseScreening(checkout.Clear),
          ),
          #(
            "flagged",
            plan.screening == checkout.Flagged,
            ReaderChoseScreening(checkout.Flagged),
          ),
        ]),
        choice("Charge payment", [
          #(
            "ok",
            plan.payment == checkout.Paid,
            ReaderChosePayment(checkout.Paid),
          ),
          #(
            "declined",
            plan.payment == checkout.Declined,
            ReaderChosePayment(checkout.Declined),
          ),
          #(
            "unknown, then ok",
            plan.payment == checkout.UnknownThenPaid,
            ReaderChosePayment(checkout.UnknownThenPaid),
          ),
          #(
            "stays unknown",
            plan.payment == checkout.StaysUnknown,
            ReaderChosePayment(checkout.StaysUnknown),
          ),
        ]),
        choice("Book shipment", [
          #(
            "ok",
            plan.shipping == checkout.Booked,
            ReaderChoseShipping(checkout.Booked),
          ),
          #(
            "fails",
            plan.shipping == checkout.CarrierRejects,
            ReaderChoseShipping(checkout.CarrierRejects),
          ),
        ]),
      ],
    ),
    html.div([class("row"), css("margin-bottom:20px;gap:16px")], [
      html.button(
        [
          attribute.type_("button"),
          class(case crash_on {
            True -> "btn warn"
            False -> "btn"
          }),
          ui.pressed(crash_on),
          event.on_click(ReaderToggledCrash),
        ],
        [
          html.text(case crash_on {
            True -> "Crash after charge: on"
            False -> "Crash the node after charging"
          }),
        ],
      ),
      html.button(
        [
          attribute.type_("button"),
          ui.on_class("btn", durable),
          ui.pressed(durable),
          event.on_click(ReaderToggledDurability),
        ],
        [
          html.text(case durable {
            True -> "Durable mode: on (checkpoints)"
            False -> "Durable mode: off (local run)"
          }),
        ],
      ),
    ]),
    html.div([css("display:flex;flex-wrap:wrap;gap:10px;align-items:center")], [
      html.div(
        [css("display:flex;flex-direction:column;gap:10px;flex:1 1 200px")],
        [
          step_node("Reserve stock", snap.reserve),
          step_node("Fraud check", snap.fraud),
        ],
      ),
      arrow,
      html.div([css("flex:1 1 200px")], [
        step_node("Charge payment", snap.charge),
      ]),
      arrow,
      html.div([css("flex:1 1 200px")], [step_node("Book shipment", snap.ship)]),
      arrow,
      html.div(
        [
          css(
            "flex:1 1 200px;border-radius:14px;padding:14px;min-height:80px;background:"
            <> out_bg
            <> ";color:"
            <> out_fg,
          ),
        ],
        [
          html.div([class("meta"), css("color:inherit")], [html.text("outcome")]),
          html.b([css("font-size:18px")], [html.text(outcome)]),
        ],
      ),
    ]),
    log(
      case snap.log {
        [] -> ["Press \"Run checkout\"."]
        lines -> lines
      },
      "margin-top:20px;min-height:120px",
    ),
  ]
}

fn step_node(name: String, state: StepState) -> Element(Msg) {
  let #(bg, fg, border, status) = case state {
    checkout.Idle -> #("#FFFFFF", "#5B5970", "#E4E0D8", "waiting")
    checkout.Running -> #("#FFFBF4", "#6B3404", "#B45309", "running…")
    checkout.Done -> #("#E2F4E7", "#0E4D25", "#B9E2C4", "done")
    checkout.Failed -> #("#FDECEA", "#7A1A12", "#B42318", "failed")
    checkout.Undone -> #("#EDEFF3", "#3B4452", "#B8C0CC", "undone")
    checkout.Unknown -> #("#FFF1C2", "#5C4300", "#E0B000", "unknown!")
    checkout.Held -> #(
      "#FFF1C2",
      "#5C4300",
      "#E0B000",
      "held for reconciliation",
    )
    checkout.Skipped -> #("#F6F7F9", "#8A8698", "#E4E0D8", "skipped")
  }
  html.div(
    [
      css(
        "border-radius:14px;padding:14px;min-height:80px;background:"
        <> bg
        <> ";color:"
        <> fg
        <> ";border:2px solid "
        <> border,
      ),
    ],
    [
      html.b([], [html.text(name)]),
      html.div([css("font-size:13px;margin-top:4px")], [html.text(status)]),
    ],
  )
}

// 200 CHECKOUTS ---------------------------------------------------------------

fn ladder(model: Model) -> List(Element(Msg)) {
  let runs = model.runs
  let mix =
    list.map(checkouts.kinds, fn(kind) { #(kind, checkouts.tally(runs, kind)) })
  [
    html.div([class("labh")], [
      html.div([], [
        html.span([class("tag")], [html.text("Up the ladder")]),
        html.h2([css("font-size:28px;margin-top:10px")], [
          html.text("200 checkouts at once"),
        ]),
        html.p([class("muted"), css("margin-top:6px;max-width:720px")], [
          html.text("One run shows "),
          html.i([], [html.text("how")]),
          html.text(" Saga behaves. Two hundred show "),
          html.i([], [html.text("what to expect")]),
          html.text(
            ". Set how often each step misbehaves; every square is one checkout. Click a square to replay that exact run in the checkout above.",
          ),
        ]),
      ]),
    ]),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:16px;margin-bottom:18px",
        ),
      ],
      list.map(checkouts.all_rates, fn(which) {
        let value = checkouts.rate(model.rates, which)
        html.label([css("display:flex;flex-direction:column;gap:6px")], [
          html.span([], [
            html.b([], [html.text(checkouts.rate_label(which) <> ":")]),
            html.text(" " <> int.to_string(value) <> "%"),
          ]),
          html.input([
            attribute.type_("range"),
            attribute("min", "0"),
            attribute("max", "40"),
            attribute("step", "1"),
            attribute.value(int.to_string(value)),
            event.on_input(fn(text) {
              case int.parse(text) {
                Ok(v) -> ReaderMovedRate(which, v)
                Error(Nil) -> ReaderMovedRate(which, value)
              }
            }),
          ]),
        ])
      }),
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(25,minmax(0,1fr));gap:3px;max-width:820px",
        ),
      ],
      list.index_map(runs, fn(run, i) {
        let title =
          "Checkout "
          <> int.to_string(i + 1)
          <> ": "
          <> checkouts.label(run.kind)
        html.button(
          [
            attribute.type_("button"),
            event.on_click(ReaderPickedCheckout(i)),
            attribute("title", title),
            attribute("aria-label", title),
            css(
              "aspect-ratio:1;border:0;border-radius:3px;background:"
              <> checkouts.colour(run.kind)
              <> ";padding:0;cursor:pointer;min-height:14px",
            ),
          ],
          [],
        )
      }),
    ),
    html.div(
      [
        css(
          "display:flex;height:22px;border-radius:8px;overflow:hidden;margin-top:16px;max-width:820px",
        ),
      ],
      list.map(mix, fn(entry) {
        html.div(
          [
            css(
              "width:"
              <> float.to_string(int.to_float(entry.1) /. 2.0)
              <> "%;background:"
              <> checkouts.colour(entry.0),
            ),
          ],
          [],
        )
      }),
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin-top:12px",
        ),
      ],
      list.map(mix, fn(entry) {
        let #(kind, n) = entry
        html.div([class("box"), css("border-left:0")], [
          html.div([class("row"), css("gap:8px")], [
            html.span(
              [
                css(
                  "width:12px;height:12px;border-radius:3px;background:"
                  <> checkouts.colour(kind),
                ),
              ],
              [],
            ),
            html.span([class("meta")], [html.text(checkouts.label(kind))]),
          ]),
          html.b([css("font-size:22px")], [html.text(int.to_string(n))]),
          html.p([class("muted"), css("font-size:13px;margin-top:2px")], [
            html.text(checkouts.what(kind)),
          ]),
        ])
      }),
    ),
    html.div([class("note"), css("margin-top:14px")], [
      html.b([], [html.text("Charged twice: 0.")]),
      html.text(
        " "
        <> int.to_string(checkouts.retried(runs))
        <> " of these runs lost the answer to a charge and retried it, always with the same idempotency key, so no customer paid twice. The held ones wait for a human or a reconciliation job, not a guess.",
      ),
    ]),
    html.p([class("muted"), css("font-size:13px;margin-top:10px")], [
      html.text(
        "An illustrative model: every square is a seeded random draw against the rates above, not a recorded checkout.",
      ),
    ]),
  ]
}

// WHICH COORDINATOR -----------------------------------------------------------

fn which() -> Element(Msg) {
  let coordinator = fn(card_bg, chip_style, chip, question, body) {
    html.div([class("card"), css("background:" <> card_bg)], [
      html.span([class("chip"), css(chip_style)], [html.text(chip)]),
      html.h3([css("font-size:20px;margin:10px 0 6px")], [html.text(question)]),
      html.p([class("muted"), css("font-size:15px")], [html.text(body)]),
    ])
  }
  let stage = fn(bg, title, body) {
    html.div([class("box"), css("background:" <> bg)], [
      html.b([], [html.text(title)]),
      html.p([css("font-size:14px;margin-top:4px")], [html.text(body)]),
    ])
  }
  let amber = "background:#FDF0DC;color:#6B3404"
  let pink = "background:#FCE7F3;color:#5E0B3A"
  html.section(
    [class("wrap sec"), attribute.id("which"), attribute("tabindex", "-1")],
    [
      html.div([class("k")], [html.text("Read · choosing a coordinator")]),
      html.h2([class("h2")], [html.text("Which one coordinates this work?")]),
      html.p([class("lead")], [
        html.text(
          "Four packages coordinate work over time. They don't compete; each answers a different question, and real systems often stack two.",
        ),
      ]),
      html.div(
        [
          css(
            "display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;margin-top:24px",
          ),
        ],
        [
          coordinator(
            "#FFFBF4",
            amber,
            "Grind",
            "\"Do this one thing, durably.\"",
            "One unit of work that must survive restarts, with retries and scheduling. Email, webhook delivery, a provider callback.",
          ),
          coordinator(
            "#FFFBF4",
            amber,
            "Saga",
            "\"Do these steps, in order, or undo.\"",
            "Known steps with dependencies, concurrency and compensation. Reserve, charge, ship.",
          ),
          coordinator(
            "#FFF7FC",
            pink,
            "Fabric",
            "\"Let a model choose the next move.\"",
            "An agent loop, or a graph that routes on typed results and waits for signals. Module 9.",
          ),
          coordinator(
            "#FFF7FC",
            pink,
            "Decisions",
            "\"Should this output be released?\"",
            "One recommendation, a policy, maybe a person, and a release at most once. Module 9.",
          ),
        ],
      ),
      html.div([class("card"), css("margin-top:16px")], [
        html.h3([css("font-size:20px;margin-bottom:12px")], [
          html.text("The classic stack: a job drives a saga"),
        ]),
        html.div(
          [
            css(
              "display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:8px;align-items:stretch",
            ),
          ],
          [
            stage(
              "#F6F4FF",
              "1 · Request",
              "Insert the order and submit a Grind job in one transaction.",
            ),
            stage(
              "#FDF0DC",
              "2 · Job runs",
              "The handler drives a durable saga by a stable execution id.",
            ),
            stage(
              "#FDF0DC",
              "3 · Saga checkpoints",
              "Each completed step is saved; uncertain ones get a resolver.",
            ),
            stage(
              "#E2F4E7",
              "4 · Crash? Resume.",
              "Grind redelivers the job if replay is enabled for it or an operator authorizes it; the saga reconnects and continues.",
            ),
          ],
        ),
        html.p([class("muted"), css("font-size:14px;margin-top:12px")], [
          html.text(
            "This is the checkout and financial-recovery examples in Oversight. The research agent adds Fabric in the middle.",
          ),
        ]),
      ]),
      ui.carry_forward(
        "Durable work is a record you can resume, not a process you hope survives. Grind keeps single jobs; Saga keeps dependent steps and their undo; both hold what they can't prove.",
      ),
    ],
  )
}
