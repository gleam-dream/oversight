//// Module 4, How gleam-dream thinks: the seven habits every package shares,
//// with playgrounds for ownership, honest uncertainty, retry schedules,
//// typed definitions and bounded waits.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import lustre
import lustre/attribute.{attribute, class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import pages/principles/bounds.{type Provider, Provider}
import pages/principles/content.{
  type Definition, type Habit, type Owner, Library, YourApp,
}
import pages/principles/happen.{type Break}
import pages/principles/herd.{type Schedule}
import site/browser
import site/context.{type Context}
import site/msc
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  Sorter
  DidItHappen
  Herd
  DefineOnce
  Bounds
}

/// The herd chart either grows bar by bar under a numbered run, or is drawn.
pub type Drawing {
  Growing(run: Int, upto: Int)
  Drawn
}

pub type Model {
  Model(
    habit: Habit,
    /// The reader's guesses, by job index.
    sorted: Dict(Int, Owner),
    happen: happen.Happen,
    schedule: Schedule,
    drawing: Drawing,
    /// Herd runs started so far; a tick names its run, so stale ticks are
    /// ignored.
    runs: Int,
    definition: Definition,
    provider: Provider,
    tours: tour.Tours(TourId),
  )
}

pub type Msg {
  ReaderPickedHabit(Habit)
  ReaderSorted(job: Int, owner: Owner)
  ReaderResetSorter
  ReaderBrokeConnection(Break)
  ReaderPeekedBehindCurtain
  ReaderToggledKey
  ReaderRetriedCharge
  ChargeReset
  ReaderPickedSchedule(Schedule)
  ReaderReplayedHerd
  HerdTicked(run: Int)
  ReaderPickedDefinition(Definition)
  ReaderSetFirstToken(Int)
  ReaderSetLongestGap(Int)
  ReaderSetWholeCall(Int)
  ProviderBehaved(Provider)
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(
    habit: content.LibrariesNotAFramework,
    sorted: dict.new(),
    happen: happen.initial(),
    schedule: herd.Immediate,
    drawing: Drawn,
    runs: 0,
    definition: content.JsonCodec,
    provider: bounds.healthy,
    tours: tour.new(),
  )
}

/// Milliseconds between two bars of the growing herd chart.
const herd_tick_ms = 45

// UPDATE ----------------------------------------------------------------------

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  case msg {
    ReaderPickedHabit(habit) -> #(Model(..model, habit:), effect.none())

    ReaderSorted(job:, owner:) -> #(
      Model(..model, sorted: dict.insert(model.sorted, job, owner)),
      effect.none(),
    )
    ReaderResetSorter -> #(Model(..model, sorted: dict.new()), effect.none())

    ReaderBrokeConnection(at) -> happen_with(model, happen.break_at(_, at))
    ReaderPeekedBehindCurtain -> happen_with(model, happen.peek)
    ReaderToggledKey -> happen_with(model, happen.toggle_key)
    ReaderRetriedCharge -> happen_with(model, happen.retry)
    ChargeReset -> happen_with(model, fn(_) { happen.initial() })

    ReaderPickedSchedule(schedule) ->
      start_herd(Model(..model, schedule:), context)
    ReaderReplayedHerd -> start_herd(model, context)
    HerdTicked(run) ->
      case model.drawing {
        Growing(run: current, upto:) if current == run ->
          case upto + 1 >= herd.ticks {
            True -> #(Model(..model, drawing: Drawn), effect.none())
            False -> #(
              Model(..model, drawing: Growing(run:, upto: upto + 1)),
              browser.after(herd_tick_ms, HerdTicked(run)),
            )
          }
        _ -> #(model, effect.none())
      }

    ReaderPickedDefinition(definition) -> #(
      Model(..model, definition:),
      effect.none(),
    )

    ReaderSetFirstToken(seconds) -> #(
      Model(..model, provider: Provider(..model.provider, first_token: seconds)),
      effect.none(),
    )
    ReaderSetLongestGap(seconds) -> #(
      Model(..model, provider: Provider(..model.provider, longest_gap: seconds)),
      effect.none(),
    )
    ReaderSetWholeCall(seconds) -> #(
      Model(..model, provider: Provider(..model.provider, whole_call: seconds)),
      effect.none(),
    )
    ProviderBehaved(provider) -> #(Model(..model, provider:), effect.none())

    Tour(id, command) ->
      tour.update(driver(context), model, id, command, context.motion)
  }
}

fn happen_with(
  model: Model,
  change: fn(happen.Happen) -> happen.Happen,
) -> #(Model, Effect(Msg)) {
  #(Model(..model, happen: change(model.happen)), effect.none())
}

/// Draw the herd chart again from the first bar; without motion, draw it
/// whole at once.
fn start_herd(model: Model, context: Context) -> #(Model, Effect(Msg)) {
  let run = model.runs + 1
  case context.animates(context) {
    True -> #(
      Model(..model, runs: run, drawing: Growing(run:, upto: 0)),
      browser.after(herd_tick_ms, HerdTicked(run)),
    )
    False -> #(Model(..model, runs: run, drawing: Drawn), effect.none())
  }
}

/// Arriving on the page, or turning motion back on while here, grows the herd
/// chart again, as the reference does when the module mounts.
pub fn enter(model: Model, context: Context) -> #(Model, Effect(Msg)) {
  start_herd(model, context)
}

/// Leaving the page pauses any playing tour and finishes the herd chart.
pub fn leave(model: Model) -> Model {
  Model(..model, drawing: Drawn, tours: tour.pause_all(model.tours))
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
    Sorter -> "sorter"
    DidItHappen -> "happen"
    Herd -> "herd"
    DefineOnce -> "defs"
    Bounds -> "bounds"
  }
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  let send = fn(msgs) { fn(_) { msgs } }
  case id {
    Sorter ->
      tour.Script(reset: send([ReaderResetSorter]), steps: [
        tour.say(
          "Every README has a sentence that starts \"Your application owns…\". Let’s sort a few jobs together.",
        ),
        tour.act(
          "Pooling and reusing HTTP connections: a mechanism, so the library owns it (HTTP Gun).",
          send([ReaderSorted(0, Library)]),
        ),
        tour.act(
          "Deciding whether to retry a failed payment: a decision, so your app owns it. HTTP Gun never retries on its own.",
          send([ReaderSorted(1, YourApp)]),
        ),
        tour.act(
          "Keeping the conversation history with a model: tempting to say \"library\"… but LLM Wire is a wire. The history is yours.",
          send([ReaderSorted(2, Library)]),
        ),
        tour.act(
          "The pattern: libraries own mechanisms, your app owns decisions and lifetimes. Sort the rest yourself.",
          send([ReaderResetSorter]),
        ),
      ])
    DidItHappen ->
      tour.Script(reset: send([ChargeReset]), steps: [
        tour.say(
          "We charge a card, and the network breaks at some point. The question: what can your code actually prove?",
        ),
        tour.act(
          "Break it while connecting. Not one byte left your machine: the evidence is NotSent, and a retry is completely safe.",
          send([ReaderBrokeConnection(happen.WhileConnecting)]),
        ),
        tour.act(
          "Break it after the request arrived, while the provider works. Your code sees MaybeSent. Peek behind the curtain: the card was charged.",
          send([
            ReaderBrokeConnection(happen.WhileProviderWorks),
            ReaderPeekedBehindCurtain,
          ]),
        ),
        tour.act(
          "Retry without an idempotency key. The provider sees a brand-new request: the ledger shows a second charge.",
          send([ReaderRetriedCharge]),
        ),
        tour.act(
          "Now turn the key on and retry. The provider has seen this key, replays the stored answer, and charges nothing new.",
          fn(model: Model) {
            case model.happen.key {
              happen.WithKey -> [ReaderRetriedCharge]
              happen.WithoutKey -> [ReaderToggledKey, ReaderRetriedCharge]
            }
          },
        ),
        tour.act(
          "Losing the reply looks exactly the same to your code. That’s why MaybeSent exists. Break the network yourself now.",
          send([ReaderBrokeConnection(happen.WhileReplyTravels)]),
        ),
      ])
    Herd ->
      tour.Script(reset: send([ReaderPickedSchedule(herd.Immediate)]), steps: [
        tour.say(
          "80 clients hit a service that is down for one second. What happens next depends only on their retry schedule.",
        ),
        tour.act(
          "Retry immediately: the crowd hammers the service every 100 ms. Look at all that red.",
          send([ReaderPickedSchedule(herd.Immediate)]),
        )
          |> tour.lasting(5200),
        tour.act(
          "Exponential backoff: fewer attempts, but clients that failed together retry together. Waves.",
          send([ReaderPickedSchedule(herd.Exponential)]),
        )
          |> tour.lasting(5200),
        tour.act(
          "Backoff with random jitter: the waves dissolve and retries fit under the capacity line.",
          send([ReaderPickedSchedule(herd.Jittered)]),
        )
          |> tour.lasting(5200),
        tour.say(
          "Your retry policy is yours to write, so add jitter. Compare all four yourself.",
        ),
      ])
    DefineOnce ->
      tour.Script(
        reset: send([ReaderPickedDefinition(content.JsonCodec)]),
        steps: [
          tour.say(
            "A recurring move: write one typed definition and let the library derive every use from it.",
          ),
          tour.act(
            "A JSON Blueprint codec gives you an encoder, a strict decoder and a JSON Schema.",
            send([ReaderPickedDefinition(content.JsonCodec)]),
          ),
          tour.act(
            "A Sinal event is shared by producers, typed observers and plain Erlang handlers.",
            send([ReaderPickedDefinition(content.TelemetryEvent)]),
          ),
          tour.act(
            "A Relay tool is declared, handled and called from the same definition.",
            send([ReaderPickedDefinition(content.McpTool)]),
          ),
          tour.act(
            "A Decisions point ties output, policy facts, the human card and the gated tool together.",
            send([ReaderPickedDefinition(content.DecisionPoint)]),
          ),
          tour.say(
            "Producer and consumer can’t drift apart: they share the same value. Explore the rest.",
          ),
        ],
      )
    Bounds ->
      tour.Script(reset: send([ProviderBehaved(bounds.healthy)]), steps: [
        tour.say(
          "LLM Wire’s three default timeouts for a model call. A healthy call stays inside all of them.",
        ),
        tour.act(
          "The provider takes 250 s to send anything: the 180 s first-progress timeout trips.",
          send([ProviderBehaved(Provider(250, 10, 300))]),
        ),
        tour.act(
          "It starts quickly but then goes quiet for 90 s mid-answer: the 60 s idle-gap timeout trips.",
          send([ProviderBehaved(Provider(20, 90, 300))]),
        ),
        tour.act(
          "Every chunk arrives in time, but the whole call runs 12 minutes: the 600 s whole-call limit trips.",
          send([ProviderBehaved(Provider(20, 10, 720))]),
        ),
        tour.say(
          "Every wait has an end, and a typed failure names which one. Drag the sliders yourself.",
        ),
      ])
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model, context: Context) -> Element(Msg) {
  let lab = fn(id, children) {
    tour.lab(model.tours, id, driver(context), context, [], children)
  }
  element.fragment([
    hero(),
    habits(model.habit),
    html.section([class("wrap sec")], [
      kicker("Habit 2 · ownership"),
      heading("Who owns what?"),
      lead(
        "Every README has a sentence that starts \"Your application owns…\". Sort these twelve jobs. Guess first, then read the reason.",
      ),
      lab(Sorter, sorter(model.sorted)),
    ]),
    html.section([class("wrap sec")], [
      kicker("Habit 5 · honest uncertainty"),
      heading("\"Did it happen?\" is a real answer"),
      lead(
        "When a call to the outside world breaks, the honest answer is often \"maybe\". gleam-dream never hides that. It tells you what it can prove, so you can choose a safe next move instead of guessing.",
      ),
      lab(DidItHappen, did_it_happen(model.happen)),
      honesty(),
    ]),
    html.section([class("wrap sec")], [
      kicker("Habit 5, continued · retrying wisely"),
      heading("When everyone retries at once"),
      html.p([class("lead")], [
        html.text(
          "Safe retries are only half the story. If a service blips and every client retries on the same schedule, the retries arrive together and knock it over again: the ",
        ),
        html.b([], [html.text("thundering herd")]),
        html.text(
          ". gleam-dream never retries behind your back, so the retry schedule is yours. LLM Wire's retry advice even passes on the provider's Retry-After.",
        ),
      ]),
      lab(Herd, herd_lab(model.schedule, model.drawing)),
    ]),
    html.section([class("wrap sec")], [
      kicker("Habit 3 · typed boundaries"),
      heading("Define once, use everywhere"),
      lead(
        "A recurring move: you write one typed definition, and the library derives every use from it. Producer and consumer can never drift apart, because they share the same value.",
      ),
      lab(DefineOnce, define_once(model.definition)),
    ]),
    html.section([class("wrap sec")], [
      kicker("Habit 4 · bounded by default"),
      heading("Every wait has an end"),
      lead(
        "Queues have capacities, bodies have size limits, calls have deadlines. Here are LLM Wire's three default timeouts for a model call. Make the provider misbehave and see which bound trips first.",
      ),
      lab(Bounds, bounded(model.provider)),
    ]),
    records_and_pure_cores(),
  ])
}

fn kicker(text: String) -> Element(Msg) {
  html.div([class("k")], [html.text(text)])
}

fn heading(text: String) -> Element(Msg) {
  html.h2([class("h2")], [html.text(text)])
}

fn lead(text: String) -> Element(Msg) {
  html.p([class("lead")], [html.text(text)])
}

/// A playground's header: its tag, title and description.
fn lab_head(
  tag: String,
  title: String,
  description: Element(Msg),
  aside: Element(Msg),
) -> Element(Msg) {
  html.div([class("labh")], [
    html.div([], [
      html.span([class("tag")], [html.text(tag)]),
      html.h2([css("font-size:28px;margin-top:10px")], [html.text(title)]),
      description,
    ]),
    aside,
  ])
}

/// A segmented control: one button per option, the selected one on.
fn segmented(
  choices: List(choice),
  selected: choice,
  label: fn(choice) -> String,
  pick: fn(choice) -> Msg,
  style: String,
) -> Element(Msg) {
  html.div(
    [class("seg"), css(style)],
    list.map(choices, fn(choice) {
      let on = choice == selected
      html.button(
        [
          attribute.type_("button"),
          ui.on_class("", on),
          ui.pressed(on),
          event.on_click(pick(choice)),
        ],
        [html.text(label(choice))],
      )
    }),
  )
}

fn hero() -> Element(Msg) {
  html.header([class("wrap"), css("padding-top:72px;padding-bottom:56px")], [
    kicker("Module 4 · Phase 2: the mental model"),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:940px")],
      [html.text("How gleam-dream thinks")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "gleam-dream is a family of independent libraries, not a framework. They were designed by the same hands, so they share a handful of habits. Learn these seven once and every README will read like a variation on a theme.",
      ),
    ]),
    html.div([class("card"), css("margin-top:32px;max-width:760px")], [
      html.div([class("k"), css("color:#5B5970")], [
        html.text("By the end you can"),
      ]),
      html.div(
        [css("display:flex;flex-direction:column;gap:6px;margin-top:10px")],
        list.map(
          [
            "→ say what a library owns and what your application owns",
            "→ read \"NotSent\", \"MaybeSent\" and \"Unknown\" and know the safe next move",
            "→ predict where a package puts limits, records and pure logic",
          ],
          fn(goal) { html.span([], [html.text(goal)]) },
        ),
      ),
    ]),
  ])
}

// THE SEVEN HABITS ------------------------------------------------------------

fn habits(selected: Habit) -> Element(Msg) {
  let info = content.habit(selected)
  html.section([class("wrap sec")], [
    kicker("Read · the seven habits"),
    heading("One attitude, seven habits"),
    lead("Click a habit for the one-line version and where you'll meet it."),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;margin-top:24px",
        ),
      ],
      list.map(content.habits, fn(habit) {
        habit_button(habit, habit == selected)
      }),
    ),
    html.div([class("card"), css("margin-top:16px;padding:28px")], [
      kicker("Habit " <> int.to_string(info.n)),
      html.h3([css("font-size:26px;margin:8px 0 10px")], [
        html.text(info.title),
      ]),
      html.p([css("font-size:17px;max-width:860px")], [html.text(info.long)]),
      html.div([class("row"), css("margin-top:14px")], [
        html.span([class("meta")], [html.text("Seen in")]),
        element.fragment(
          list.map(info.seen, fn(s) {
            html.span([class("pill")], [html.text(s)])
          }),
        ),
      ]),
    ]),
  ])
}

fn habit_button(habit: Habit, on: Bool) -> Element(Msg) {
  let info = content.habit(habit)
  let #(bg, fg, border) = case on {
    True -> #("#17162B", "#FFFFFF", "#17162B")
    False -> #("#FFFFFF", "#17162B", "#E4E0D8")
  }
  html.button(
    [
      attribute.type_("button"),
      event.on_click(ReaderPickedHabit(habit)),
      ui.pressed(on),
      css(
        "text-align:left;font:inherit;cursor:pointer;border-radius:16px;padding:20px;border:2px solid "
        <> border
        <> ";background:"
        <> bg
        <> ";color:"
        <> fg
        <> ";display:flex;flex-direction:column;gap:6px;min-height:120px",
      ),
    ],
    [
      html.span(
        [class("mono"), css("font-size:13px;font-weight:600;opacity:.8")],
        [
          html.text("0" <> int.to_string(info.n)),
        ],
      ),
      html.b([css("font:600 19px 'Space Grotesk',sans-serif")], [
        html.text(info.title),
      ]),
      html.span([css("font-size:14px;opacity:.9")], [html.text(info.short)]),
    ],
  )
}

// THE OWNERSHIP SORTER --------------------------------------------------------

fn sorter(sorted: Dict(Int, Owner)) -> List(Element(Msg)) {
  let guesses =
    list.index_map(content.jobs, fn(job, i) { #(i, job, dict.get(sorted, i)) })
  let done = dict.size(sorted)
  let right =
    list.count(guesses, fn(g) {
      let #(_, job, guess) = g
      guess == Ok(job.owner)
    })
  let score = case done {
    0 -> "0 / 12 sorted"
    _ -> int.to_string(right) <> " / " <> int.to_string(done) <> " right"
  }
  [
    lab_head(
      "Playground",
      "Library or your app?",
      element.none(),
      html.div([class("row")], [
        html.span([class("mono"), css("font-weight:600")], [html.text(score)]),
        html.button(
          [
            attribute.type_("button"),
            class("btn sm"),
            event.on_click(ReaderResetSorter),
          ],
          [html.text("Reset")],
        ),
      ]),
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px",
        ),
      ],
      list.map(guesses, fn(g) {
        let #(i, job, guess) = g
        sort_card(i, job, guess)
      }),
    ),
    html.div([class("note"), css("margin-top:16px")], [
      html.b([], [html.text("The pattern:")]),
      html.text(" libraries own "),
      html.i([], [html.text("mechanisms")]),
      html.text(
        " (pooling, leasing, encoding, refreshing, recording). Your application owns ",
      ),
      html.i([], [html.text("decisions and lifetimes")]),
      html.text(" (policy, retries, accounts, pools, templates, exporters)."),
    ]),
  ]
}

fn sort_card(
  i: Int,
  job: content.Job,
  guess: Result(Owner, Nil),
) -> Element(Msg) {
  let #(bg, border) = case guess {
    Error(Nil) -> #("#FFFFFF", "#E4E0D8")
    Ok(owner) if owner == job.owner -> #("#F1FAF3", "#B9E2C4")
    Ok(_) -> #("#FEF6F5", "#E9B8B2")
  }
  let choice = fn(owner, text) {
    let on = guess == Ok(owner)
    html.button(
      [
        attribute.type_("button"),
        ui.on_class("btn sm", on),
        ui.pressed(on),
        event.on_click(ReaderSorted(i, owner)),
      ],
      [html.text(text)],
    )
  }
  let verdict = case guess, job.owner {
    Error(Nil), _ -> element.none()
    Ok(owner), right -> {
      let text = case owner == right, right {
        True, _ -> "Right."
        False, Library -> "Library, actually."
        False, YourApp -> "Your app, actually."
      }
      html.div([css("font-size:14px")], [
        html.b([], [html.text(text)]),
        html.text(" " <> job.why),
      ])
    }
  }
  html.div(
    [
      css(
        "border-radius:14px;padding:16px;border:1px solid "
        <> border
        <> ";background:"
        <> bg
        <> ";display:flex;flex-direction:column;gap:10px",
      ),
    ],
    [
      html.b([css("font-size:15px")], [html.text(job.task)]),
      html.div([class("row"), css("gap:8px")], [
        choice(Library, "Library"),
        choice(YourApp, "Your app"),
      ]),
      verdict,
    ],
  )
}

// DID IT HAPPEN? --------------------------------------------------------------

const green = "#E2F4E7"

const red = "#FDECEA"

const neutral = "#F1EEE8"

fn did_it_happen(state: happen.Happen) -> List(Element(Msg)) {
  let at = state.at
  let picture = happen.picture(state)
  let #(ev_bg, ev_border) = case happen.evidence(at) {
    happen.Answered -> #("#E2F4E7", "#B9E2C4")
    happen.NotSent -> #("#E0E9FD", "#B8CBF7")
    happen.MaybeSent -> #("#FFF1C2", "#F0D277")
  }
  let curtain = case state.curtain {
    happen.Revealed ->
      element.fragment([
        html.div([css("font-size:20px;font-weight:600;margin:6px 0")], [
          html.text(happen.truth(at)),
        ]),
        html.p([css("font-size:14px"), class("muted")], [
          html.text(
            "In real life you can't see this panel. That's the whole problem.",
          ),
        ]),
      ])
    happen.Hidden ->
      element.fragment([
        html.p([css("font-size:14px;margin:8px 0"), class("muted")], [
          html.text("Hidden, just as it is from your code."),
        ]),
        html.button(
          [
            attribute.type_("button"),
            class("btn sm"),
            event.on_click(ReaderPeekedBehindCurtain),
          ],
          [html.text("Peek behind the curtain")],
        ),
      ])
  }
  let keyed = state.key == happen.WithKey
  let #(charged_bg, charged_fg) = case picture.charges {
    0 -> #(neutral, "#17162B")
    1 -> #(green, "#0E4D25")
    _ -> #(red, "#7A1A12")
  }
  let chart =
    msc.Chart(
      ..msc.chart(
        "h4",
        ["your app", "network", "payment provider"],
        list.drop(picture.events, list.length(picture.events) - 10),
      ),
      lane_gap: 210,
      row: 34,
      aria: "Sequence chart of the charge request, the provider effect and the reply",
    )
  [
    lab_head(
      "Playground",
      "Charge a card, break the network",
      html.p([class("muted"), css("margin-top:6px;max-width:680px")], [
        html.text(
          "Choose the moment the connection drops. See what your code can prove, what really happened at the provider, and what a retry would do.",
        ),
      ]),
      element.none(),
    ),
    html.div([class("meta"), css("margin-bottom:8px")], [
      html.text("The connection breaks…"),
    ]),
    segmented(
      happen.breaks,
      at,
      happen.label,
      ReaderBrokeConnection,
      "margin-bottom:20px",
    ),
    html.div(
      [
        class("tour-hide"),
        css(
          "display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:6px;margin-bottom:24px",
        ),
      ],
      list.map(happen.journey(at), stage),
    ),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px",
        ),
      ],
      [
        html.div(
          [
            class("box"),
            css("background:" <> ev_bg <> ";border-color:" <> ev_border),
          ],
          [
            html.div([class("meta")], [html.text("What your code can prove")]),
            html.div(
              [
                class("mono"),
                css("font-size:22px;font-weight:600;margin:6px 0"),
              ],
              [html.text(happen.evidence_label(at))],
            ),
            html.p([css("font-size:14px")], [html.text(happen.evidence_why(at))]),
          ],
        ),
        html.div([class("box")], [
          html.div([class("meta")], [
            html.text("What the provider actually did"),
          ]),
          curtain,
        ]),
        html.div(
          [class("box"), css("background:#F6F4FF;border-color:#DCD9FF")],
          [
            html.div([class("meta")], [html.text("The safe next move")]),
            html.p([css("font-size:15px;margin-top:6px")], [
              html.text(happen.safe_move(at)),
            ]),
          ],
        ),
      ],
    ),
    html.div(
      [css("margin-top:20px;border-top:1px solid #E4E0D8;padding-top:20px")],
      [
        html.div([class("row"), css("justify-content:space-between;gap:16px")], [
          html.div([class("row")], [
            html.button(
              [
                attribute.type_("button"),
                ui.on_class("btn", keyed),
                ui.pressed(keyed),
                event.on_click(ReaderToggledKey),
              ],
              [
                html.text(case keyed {
                  True -> "Idempotency key: on"
                  False -> "Idempotency key: off"
                }),
              ],
            ),
            html.button(
              [
                attribute.type_("button"),
                class("btn pri"),
                event.on_click(ReaderRetriedCharge),
              ],
              [html.text("Retry the charge")],
            ),
          ]),
          html.span([css("font-size:15px;max-width:520px")], [
            html.text(happen.note_text(state.note)),
          ]),
        ]),
      ],
    ),
    html.div([class("split"), css("margin-top:20px;align-items:flex-start")], [
      html.div([class("card"), css("flex:3 1 460px;padding:16px")], [
        html.div([class("k"), css("margin-bottom:6px")], [
          html.text("Timeline · request, effect, reply"),
        ]),
        html.p(
          [class("muted tour-hide"), css("font-size:13px;margin-bottom:6px")],
          [
            html.text(
              "The lightning bolt is where the connection died. Your code only ever sees the left column.",
            ),
          ],
        ),
        msc.view(chart),
      ]),
      html.div([class("card"), css("flex:2 1 320px;padding:16px")], [
        html.div([class("k")], [
          html.text("The provider's side · idempotency ledger"),
        ]),
        html.p(
          [class("muted tour-hide"), css("font-size:13px;margin:6px 0 10px")],
          [
            html.text(
              "Like Stripe, a provider that supports idempotency keys stores the first result for each key and replays it for repeats.",
            ),
          ],
        ),
        html.div(
          [css("display:flex;flex-direction:column;gap:6px")],
          list.map(picture.ledger, ledger_row),
        ),
        html.div(
          [
            css(
              "margin-top:12px;padding:10px 12px;border-radius:10px;background:"
              <> charged_bg
              <> ";color:"
              <> charged_fg
              <> ";font-weight:700",
            ),
          ],
          [html.text(happen.charged_text(picture.charges))],
        ),
      ]),
    ]),
  ]
}

fn stage(s: happen.Stage) -> Element(Msg) {
  let #(bg, fg, border, mark) = case s.mark {
    happen.ConnectionLost -> #(red, "#7A1A12", "#B42318", "connection lost")
    happen.Done -> #(green, "#0E4D25", "transparent", "done")
    happen.NotReached -> #(neutral, "#5B5970", "transparent", "not reached")
  }
  html.div(
    [
      css(
        "border-radius:12px;padding:12px 10px;min-height:88px;background:"
        <> bg
        <> ";color:"
        <> fg
        <> ";border:2px solid "
        <> border
        <> ";font-size:13px;display:flex;flex-direction:column;gap:4px",
      ),
    ],
    [
      html.span([class("mono"), css("font-size:11px;opacity:.8")], [
        html.text(s.where),
      ]),
      html.b([], [html.text(s.label)]),
      html.span([], [html.text(mark)]),
    ],
  )
}

fn ledger_row(row: happen.Row) -> Element(Msg) {
  let bg = case row.tone {
    happen.Charged -> green
    happen.Quiet -> neutral
    happen.Double -> red
  }
  html.div(
    [
      css(
        "display:grid;grid-template-columns:44px 1fr;gap:8px;padding:8px 10px;border-radius:10px;background:"
        <> bg
        <> ";font-size:13px",
      ),
    ],
    [
      html.span([class("mono"), css("font-weight:600")], [
        html.text(row.request),
      ]),
      html.span([], [
        html.span([class("mono")], [html.text("key: " <> row.key)]),
        html.br([]),
        html.b([], [html.text(row.result)]),
      ]),
    ],
  )
}

fn honesty() -> Element(Msg) {
  let says = fn(package, words) {
    html.div([class("box")], [
      html.b([], [html.text(package)]),
      html.text(" "),
      html.span([class("muted"), css("font-size:14px")], [html.text(words)]),
    ])
  }
  html.div([css("margin-top:24px")], [
    html.div([class("meta"), css("margin-bottom:10px")], [
      html.text("The same honesty, in each package's own words"),
    ]),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:10px",
        ),
      ],
      [
        says("HTTP Gun", "failures carry NotSent or MaybeSent"),
        says("LLM Wire", "a MaybeSent call may already have cost tokens"),
        says("Correio", "Accepted · NotSent · Rejected · OutcomeUnknown"),
        says("Grind", "an Uncertain job waits for an audited resolution"),
        says("Saga", "an unknown effect can Hold for reconciliation"),
        says("Fabric", "an uncertain tool call blocks dependent work"),
        says(
          "Decisions",
          "a check answers Refuse, or Unsure when it can't tell",
        ),
        says("Relay · Hellhound", "client failures keep send evidence too"),
      ],
    ),
  ])
}

// THE THUNDERING HERD ---------------------------------------------------------

/// Pixels per request in the herd chart: 170 px for 80 requests.
const per_request = 2.125

fn herd_lab(schedule: Schedule, drawing: Drawing) -> List(Element(Msg)) {
  let run = herd.simulate(schedule)
  let upto = case drawing {
    Growing(upto:, ..) -> upto
    Drawn -> herd.ticks
  }
  let cap_y = num(180.0 -. int.to_float(herd.capacity) *. per_request)
  let label = fn(x, y, fill, extra, text) {
    svg.text(
      [
        attribute("x", x),
        attribute("y", y),
        class("msc-l"),
        attribute("fill", fill),
        ..extra
      ],
      text,
    )
  }
  let stat = fn(name, value, style) {
    html.div([class("box")], [
      html.div([class("meta")], [html.text(name)]),
      html.b([css(style)], [html.text(value)]),
    ])
  }
  [
    lab_head(
      "Simulation",
      "80 clients, one 1-second outage",
      html.p([class("muted"), css("margin-top:6px;max-width:700px")], [
        html.text(
          "The service is down for the first second, then serves at most 6 requests per 100 ms, and fewer when swamped, because overload eats capacity. Each bar is 100 ms: green requests were served, red were turned away and will retry. Pick a retry schedule.",
        ),
      ]),
      html.div([class("row")], [
        html.button(
          [
            attribute.type_("button"),
            class("btn sm"),
            event.on_click(ReaderReplayedHerd),
          ],
          [html.text("Replay")],
        ),
      ]),
    ),
    segmented(
      herd.schedules,
      schedule,
      herd.label,
      ReaderPickedSchedule,
      "margin-bottom:18px",
    ),
    html.div([css("overflow-x:auto")], [
      svg.svg(
        [
          attribute("viewBox", "0 0 800 220"),
          attribute("width", "100%"),
          css("min-width:600px;display:block"),
          attribute.role("img"),
          attribute.aria_label(
            "Bar chart of requests per 100 milliseconds after an outage, using the "
            <> herd.key(schedule)
            <> " retry schedule",
          ),
        ],
        [
          svg.rect([
            attribute("x", "40"),
            attribute("y", "10"),
            attribute("width", "100"),
            attribute("height", "170"),
            attribute("fill", "#FDECEA"),
          ]),
          label("46", "26", "#B42318", [], "outage"),
          element.fragment(
            list.index_map(run.ticks, fn(tick, i) { bar(tick, i, upto) }),
          ),
          svg.line([
            attribute("x1", "40"),
            attribute("x2", "790"),
            attribute("y1", cap_y),
            attribute("y2", cap_y),
            attribute("stroke", "#17162B"),
            attribute("stroke-dasharray", "5 4"),
            attribute("stroke-width", "1.5"),
          ]),
          label(
            "792",
            cap_y,
            "#17162B",
            [attribute("text-anchor", "end"), attribute("dy", "-6")],
            "capacity",
          ),
          svg.line([
            attribute("x1", "40"),
            attribute("x2", "790"),
            attribute("y1", "180"),
            attribute("y2", "180"),
            attribute("stroke", "#8A8698"),
          ]),
          label("40", "200", "#5B5970", [], "0 s"),
          label("290", "200", "#5B5970", [], "2.5 s"),
          label("540", "200", "#5B5970", [], "5 s"),
          label("760", "200", "#5B5970", [], "7.5 s"),
          svg.line([
            attribute("x1", int.to_string(40 + upto * 10)),
            attribute("x2", int.to_string(40 + upto * 10)),
            attribute("y1", "10"),
            attribute("y2", "180"),
            attribute("stroke", "#B0186E"),
            attribute("stroke-width", "2"),
          ]),
        ],
      ),
    ]),
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin-top:14px",
        ),
      ],
      [
        stat("attempts sent", int.to_string(run.attempts), "font-size:22px"),
        stat("peak in 100 ms", int.to_string(run.peak), "font-size:22px"),
        stat(
          "turned away",
          int.to_string(run.rejected),
          "font-size:22px;color:#B42318",
        ),
        stat("everyone served by", herd.done_label(run), "font-size:22px"),
      ],
    ),
    html.div([class("note"), css("margin-top:14px")], [
      html.text(herd.note(schedule)),
    ]),
    html.p([class("muted"), css("font-size:13px;margin-top:10px")], [
      html.text(
        "An illustrative model with seeded randomness: every visit draws the same picture.",
      ),
    ]),
  ]
}

/// One 100 ms bar: served in green below, turned away in red above. Bars
/// past the growing edge are flat.
fn bar(tick: herd.Tick, i: Int, upto: Int) -> Element(Msg) {
  let #(served, rejected) = case i < upto {
    True -> #(
      int.to_float(tick.served) *. per_request,
      int.to_float(tick.rejected) *. per_request,
    )
    False -> #(0.0, 0.0)
  }
  let x = int.to_string(41 + i * 10)
  element.fragment([
    svg.rect([
      attribute("x", x),
      attribute("y", num(180.0 -. served)),
      attribute("width", "8"),
      attribute("height", num(served)),
      attribute("fill", "#15803D"),
    ]),
    svg.rect([
      attribute("x", x),
      attribute("y", num(180.0 -. served -. rejected)),
      attribute("width", "8"),
      attribute("height", num(rejected)),
      attribute("fill", "#B42318"),
      attribute("opacity", "0.8"),
    ]),
  ])
}

/// Numbers as the reference prints them: integers without a decimal point.
fn num(x: Float) -> String {
  case float.floor(x) == x {
    True -> int.to_string(float.truncate(x))
    False -> float.to_string(x)
  }
}

// DEFINE ONCE -----------------------------------------------------------------

fn define_once(selected: Definition) -> List(Element(Msg)) {
  let info = content.definition(selected)
  [
    segmented(
      content.definitions,
      selected,
      fn(d) { content.definition(d).label },
      ReaderPickedDefinition,
      "margin-bottom:24px",
    ),
    html.div([css("display:flex;flex-wrap:wrap;gap:20px;align-items:center")], [
      html.div(
        [
          css(
            "flex:1 1 280px;border-radius:18px;padding:24px;background:"
            <> info.tint
            <> ";color:"
            <> info.ink,
          ),
        ],
        [
          html.div([class("k"), css("color:inherit")], [html.text(info.package)]),
          html.h3([css("font-size:28px;margin:8px 0")], [html.text(info.name)]),
          html.p([css("font-size:15px")], [html.text(info.what)]),
        ],
      ),
      html.div(
        [
          class("arrow"),
          css("font-size:28px"),
          attribute("aria-hidden", "true"),
        ],
        [html.text("→")],
      ),
      html.div(
        [css("flex:2 1 400px;display:flex;flex-direction:column;gap:8px")],
        list.map(info.uses, fn(use_) {
          let #(who, does) = use_
          html.div(
            [class("box"), css("display:flex;gap:12px;align-items:baseline")],
            [
              html.span(
                [
                  class("mono"),
                  css(
                    "font-size:12px;font-weight:600;color:"
                    <> info.ink
                    <> ";min-width:96px",
                  ),
                ],
                [html.text(who)],
              ),
              html.span([css("font-size:15px")], [html.text(does)]),
            ],
          )
        }),
      ),
    ]),
  ]
}

// BOUNDED BY DEFAULT ----------------------------------------------------------

fn bounded(provider: Provider) -> List(Element(Msg)) {
  let tripped = bounds.tripped(provider)
  let #(bg, fg) = case tripped {
    Some(_) -> #("#FFF1C2", "#5C4300")
    None -> #("#E2F4E7", "#0E4D25")
  }
  [
    html.div(
      [
        css(
          "display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:20px",
        ),
      ],
      [
        slider(
          "Time to first token:",
          provider.first_token,
          #(0, 300, 10),
          "limit 180 s",
          ReaderSetFirstToken,
        ),
        slider(
          "Longest gap between chunks:",
          provider.longest_gap,
          #(0, 120, 5),
          "limit 60 s",
          ReaderSetLongestGap,
        ),
        slider(
          "Whole call:",
          provider.whole_call,
          #(10, 900, 10),
          "limit 600 s",
          ReaderSetWholeCall,
        ),
      ],
    ),
    html.div(
      [
        css(
          "margin-top:20px;border-radius:14px;padding:18px 20px;background:"
          <> bg
          <> ";color:"
          <> fg,
        ),
      ],
      [
        html.b([css("font-size:18px")], [html.text(bounds.title(tripped))]),
        html.p([css("font-size:15px;margin-top:4px")], [
          html.text(bounds.why(tripped)),
        ]),
      ],
    ),
    html.div([class("row"), css("margin-top:16px;gap:8px")], [
      html.span([class("meta")], [html.text("Other bounds you'll meet")]),
      ..list.map(
        [
          "Sinal forwarder · 1,024 events",
          "HTTP Gun · body & batch limits",
          "JSON Blueprint · byte limit on untrusted text",
          "Grind · per-node queue concurrency",
          "Saga · per-run concurrency, deadlines",
          "Fabric · turns, timeouts, token budgets",
        ],
        fn(bound) { html.span([class("pill")], [html.text(bound)]) },
      )
    ]),
  ]
}

fn slider(
  name: String,
  seconds: Int,
  range: #(Int, Int, Int),
  limit: String,
  to_msg: fn(Int) -> Msg,
) -> Element(Msg) {
  let #(min, max, step) = range
  html.label([css("display:flex;flex-direction:column;gap:8px")], [
    html.span([], [
      html.b([], [html.text(name)]),
      html.text(" " <> int.to_string(seconds) <> " s"),
    ]),
    html.input([
      attribute.type_("range"),
      attribute("min", int.to_string(min)),
      attribute("max", int.to_string(max)),
      attribute("step", int.to_string(step)),
      attribute.value(int.to_string(seconds)),
      event.on_input(fn(value) {
        case int.parse(value) {
          Ok(seconds) -> to_msg(seconds)
          Error(Nil) -> to_msg(seconds)
        }
      }),
    ]),
    html.span([class("meta")], [html.text(limit)]),
  ])
}

// RECORDS AND PURE CORES ------------------------------------------------------

fn records_and_pure_cores() -> Element(Msg) {
  let box = fn(style, children) {
    html.div([class("box"), css(style)], children)
  }
  let down =
    html.div([class("arrow"), attribute("aria-hidden", "true")], [
      html.text("↓"),
    ])
  html.section([class("wrap sec")], [
    kicker("Habits 6 & 7 · records and pure cores"),
    heading("Truth lives in records; logic lives in pure functions"),
    html.div([class("split"), css("margin-top:24px")], [
      html.div([class("card")], [
        html.h3([css("font-size:22px;margin-bottom:12px")], [
          html.text("Durable rows are the truth"),
        ]),
        html.div([css("display:flex;flex-direction:column;gap:10px")], [
          box("background:#E2F4E7;border-color:#B9E2C4", [
            html.b([], [html.text("Source of truth")]),
            html.p([css("font-size:14px;margin-top:4px")], [
              html.text(
                "Rows in your database: Grind job outcomes, Saga checkpoints, Fabric run records, Decisions entries. Decide business questions from these.",
              ),
            ]),
          ]),
          box("background:#F1EEE8", [
            html.b([], [html.text("Signals")]),
            html.p([css("font-size:14px;margin-top:4px")], [
              html.text(
                "Sinal events are best effort. Under load a forwarder drops and counts. Use them for dashboards and alerts, never to decide whether money moved.",
              ),
            ]),
          ]),
        ]),
      ]),
      html.div([class("card")], [
        html.h3([css("font-size:22px;margin-bottom:12px")], [
          html.text("Pure core, thin process shell"),
        ]),
        html.div(
          [
            css(
              "display:flex;flex-direction:column;gap:8px;align-items:stretch",
            ),
          ],
          [
            box("text-align:center", [
              html.b([], [html.text("Events in")]),
              html.text(" "),
              html.span([class("muted")], [
                html.text("requests, replies, timeouts"),
              ]),
            ]),
            down,
            box("text-align:center;background:#FCE7F3;border-color:#F3C6E6", [
              html.b([], [html.text("Pure function")]),
              html.br([]),
              html.span([css("font-size:14px")], [
                html.text("(state, event) → new state + effects to perform"),
              ]),
            ]),
            down,
            box("text-align:center;background:#DCD9FF;border-color:#C6C1FA", [
              html.b([], [html.text("Thin OTP process")]),
              html.text(" "),
              html.span([css("font-size:14px")], [
                html.text("performs the effects"),
              ]),
            ]),
          ],
        ),
        html.p([class("muted"), css("font-size:14px;margin-top:12px")], [
          html.text(
            "Relay's runtime actor runs a pure reducer. Fabric pairs a pure controller with a thin runner. Decisions' core is pure, with optional OTP and PostgreSQL packages around it. The logic can be tested and replayed without starting a single process.",
          ),
        ]),
      ]),
    ]),
    ui.carry_forward(
      "Libraries own mechanisms; your app owns decisions and lifetimes. Everything is typed, bounded and honest about what it can prove, and the durable record, not the log, is the truth.",
    ),
  ])
}
