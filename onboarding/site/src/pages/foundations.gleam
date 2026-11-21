//// Module 6, Foundations: Sinal reports, JSON Blueprint describes, HTTP Gun
//// reaches. A live telemetry pipeline, the User codec, the anatomy of a
//// request and the destination policy.

import gleam/int
import gleam/list
import gleam/result
import lustre
import lustre/attribute.{attribute, class}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import pages/foundations/codec.{type Face, type Incoming}
import pages/foundations/gun.{type Part, type Policy}
import pages/foundations/pipeline.{
  type Delivery, type Settings, FastObservers, Flowing, Inline, Paused,
  SlowObserver, ViaForwarder,
}
import pages/foundations/sinal_widget
import site/browser
import site/context.{type Context}
import site/live
import site/motion
import site/tour
import site/ui.{css}

// MODEL -----------------------------------------------------------------------

pub type TourId {
  SinalTour
  CodecTour
  AnatomyTour
  DestinationTour
}

pub type Model {
  Model(
    /// The reader's pipeline settings; the live widget owns the simulation.
    pipeline: Settings,
    /// Commands sent to the widget, newest first, and the latest number.
    issued: List(pipeline.Issued),
    latest: Int,
    face: Face,
    /// The decoder input last picked; kept while another face shows.
    incoming: Incoming,
    part: Part,
    policy: Policy,
    tours: tour.Tours(TourId),
  )
}

pub type Msg {
  ReaderJumpedTo(String)
  ReaderPickedDelivery(Delivery)
  ReaderAttachedSlowObserver
  ReaderRemovedSlowObserver
  ReaderSetRate(Int)
  ReaderPausedPipeline
  ReaderResumedPipeline
  ReaderResetPipeline
  ReaderSentBurst
  ReaderAdvancedOneSecond
  /// A tour empties the pipeline without touching the reader's settings.
  TourClearedPipeline
  /// A tour moves the pipeline on two seconds when nothing animates.
  TourSkippedAhead
  ReaderPickedFace(Face)
  ReaderPickedIncoming(Incoming)
  ReaderPickedPart(Part)
  ReaderPickedPolicy(Policy)
  Tour(TourId, tour.Command)
}

pub fn init() -> Model {
  Model(
    pipeline: pipeline.defaults,
    issued: [],
    latest: 0,
    face: codec.Decode,
    incoming: codec.Valid,
    part: gun.ClientPool,
    policy: gun.DefaultPolicy,
    tours: tour.new(),
  )
}

/// The commands the widget can still need: enough for a tour going back
/// through every step at once.
const kept_commands = 12

// UPDATE ----------------------------------------------------------------------

pub fn update(
  model: Model,
  msg: Msg,
  context: Context,
) -> #(Model, Effect(Msg)) {
  let still = context.motion == motion.Off
  case msg {
    ReaderJumpedTo(id) -> #(
      model,
      browser.jump_to(id, context.animates(context)),
    )
    ReaderPickedDelivery(delivery) ->
      none(set(model, pipeline.Settings(..model.pipeline, delivery:)))
    ReaderAttachedSlowObserver ->
      none(set(
        model,
        pipeline.Settings(..model.pipeline, observer: SlowObserver),
      ))
    ReaderRemovedSlowObserver ->
      none(set(
        model,
        pipeline.Settings(..model.pipeline, observer: FastObservers),
      ))
    ReaderSetRate(rate) ->
      none(set(
        model,
        pipeline.Settings(..model.pipeline, rate: int.clamp(rate, 1, 20)),
      ))
    ReaderPausedPipeline ->
      none(set(model, pipeline.Settings(..model.pipeline, flow: Paused)))
    ReaderResumedPipeline ->
      none(set(model, pipeline.Settings(..model.pipeline, flow: Flowing)))
    ReaderResetPipeline ->
      set(model, pipeline.Settings(..model.pipeline, flow: Flowing))
      |> issue(pipeline.Clear)
      |> none
    ReaderSentBurst ->
      case still {
        True -> issue(model, pipeline.Burst) |> issue(pipeline.Advance(1))
        False -> issue(model, pipeline.Burst)
      }
      |> none
    ReaderAdvancedOneSecond -> none(issue(model, pipeline.Advance(1)))
    TourClearedPipeline -> none(issue(model, pipeline.Clear))
    TourSkippedAhead ->
      case still {
        True -> issue(model, pipeline.Advance(2))
        False -> model
      }
      |> none
    ReaderPickedFace(face) -> none(Model(..model, face:))
    ReaderPickedIncoming(incoming) -> none(Model(..model, incoming:))
    ReaderPickedPart(part) -> none(Model(..model, part:))
    ReaderPickedPolicy(policy) -> none(Model(..model, policy:))
    Tour(id, command) ->
      tour.update(driver(context), model, id, command, context.motion)
  }
}

fn none(model: Model) -> #(Model, Effect(Msg)) {
  #(model, effect.none())
}

fn set(model: Model, settings: Settings) -> Model {
  Model(..model, pipeline: settings)
}

/// Send the widget a one-off command, stamped with the settings in force.
fn issue(model: Model, command: pipeline.Command) -> Model {
  let sequence = model.latest + 1
  let issued = pipeline.Issued(sequence:, settings: model.pipeline, command:)
  Model(
    ..model,
    latest: sequence,
    issued: list.take([issued, ..model.issued], kept_commands),
  )
}

/// Leaving the page pauses any playing tour.
pub fn leave(model: Model) -> Model {
  Model(..model, tours: tour.pause_all(model.tours))
}

/// Register the live Sinal pipeline.
pub fn register() -> Result(Nil, lustre.Error) {
  sinal_widget.register()
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
    SinalTour -> "sinal"
    CodecTour -> "codec"
    AnatomyTour -> "anatomy"
    DestinationTour -> "dest"
  }
}

pub fn script(id: TourId) -> tour.Script(Model, Msg) {
  let send = fn(msgs) { fn(_) { msgs } }
  case id {
    SinalTour ->
      tour.Script(
        reset: send([
          ReaderResetPipeline,
          ReaderPickedDelivery(Inline),
          ReaderRemovedSlowObserver,
          ReaderSetRate(6),
        ]),
        steps: [
          tour.act(
            "Every request the handler finishes emits an event. Right now observers are fast and run inline, inside the handler. Each dot is one event.",
            send([
              TourClearedPipeline,
              ReaderPickedDelivery(Inline),
              ReaderRemovedSlowObserver,
              ReaderSetRate(6),
            ]),
          ),
          tour.act(
            "Attach a slow observer (500 ms). The handler turns red: it can’t serve the next request until telemetry finishes. Throughput collapses to about 1 per second.",
            send([ReaderAttachedSlowObserver, TourSkippedAhead]),
          )
            |> tour.lasting(6500),
          tour.act(
            "Route the events through a forwarder. The handler is free again: it drops each event into the forwarder and moves on.",
            send([ReaderPickedDelivery(ViaForwarder), TourSkippedAhead]),
          )
            |> tour.lasting(6000),
          tour.act(
            "But with the slow observer the forwarder drains only about 1 per second. Its queue fills to the limit, then new events fall off and are counted. Watch the red drops.",
            send([TourSkippedAhead]),
          )
            |> tour.lasting(6000),
          tour.act(
            "A burst of 30 makes it obvious: bounded, best effort, never blocking the request.",
            send([ReaderSentBurst]),
          )
            |> tour.lasting(5000),
          tour.act(
            "Remove the slow observer and turn the rate down to 1 per second. The forwarder now drains faster than requests arrive, so the queue empties. Telemetry informs; it never decides. Your turn.",
            send([ReaderRemovedSlowObserver, ReaderSetRate(1), TourSkippedAhead]),
          ),
        ],
      )
    CodecTour ->
      tour.Script(
        reset: send([
          ReaderPickedFace(codec.Decode),
          ReaderPickedIncoming(codec.Valid),
        ]),
        steps: [
          tour.say(
            "One codec describes a User: name, age 0 to 150, optional email, and a role of admin or member.",
          ),
          tour.act(
            "Face one, encode: a Gleam value becomes JSON. The missing email is simply left out.",
            send([ReaderPickedFace(codec.Encode)]),
          ),
          tour.act(
            "Face two, decode: valid JSON becomes a typed User value.",
            send([
              ReaderPickedFace(codec.Decode),
              ReaderPickedIncoming(codec.Valid),
            ]),
          ),
          tour.act(
            "Age 200 is out of range: decoding fails with the exact path, $.age. Feed that straight back to a model.",
            send([ReaderPickedIncoming(codec.AgeTooHigh)]),
          ),
          tour.act(
            "Repeated keys in untrusted text are refused outright, so two systems can never disagree about which \"name\" counted.",
            send([ReaderPickedIncoming(codec.RepeatedKey)]),
          ),
          tour.act(
            "Face three, schema: the same rules, published as JSON Schema. Explore the cases yourself.",
            send([ReaderPickedFace(codec.Schema)]),
          ),
        ],
      )
    AnatomyTour ->
      tour.Script(reset: send([ReaderPickedPart(gun.ClientPool)]), steps: [
        tour.say(
          "One HTTP Gun request passes through five parts. Follow it left to right.",
        ),
        tour.act(
          "Your process sends. Only the process that opened a streamed body may read it.",
          send([ReaderPickedPart(gun.YourProcess)]),
        ),
        tour.act(
          "The client pool admits the request against your limits and leases a connection.",
          send([ReaderPickedPart(gun.ClientPool)]),
        ),
        tour.act(
          "A short-lived body owner coordinates this one response: limits, deadlines, cancellation.",
          send([ReaderPickedPart(gun.BodyOwner)]),
        ),
        tour.act(
          "Gun speaks HTTP/1.1 and HTTP/2 underneath; optional recorders and Sinal see everything.",
          send([ReaderPickedPart(gun.GunConnections)]),
        ),
        tour.say("Click any part for the details."),
      ])
    DestinationTour ->
      tour.Script(reset: send([ReaderPickedPolicy(gun.DefaultPolicy)]), steps: [
        tour.say(
          "Before connecting, HTTP Gun checks where each address really resolves.",
        ),
        tour.act(
          "The default policy: public addresses only. A name that resolves to a private network or cloud metadata is refused.",
          send([ReaderPickedPolicy(gun.DefaultPolicy)]),
        ),
        tour.act(
          "RequireTls also refuses plaintext HTTP, even to public hosts.",
          send([ReaderPickedPolicy(gun.RequireTls)]),
        ),
        tour.act(
          "Local tests opt into loopback explicitly. Nothing reaches localhost by accident. Try the policies yourself.",
          send([ReaderPickedPolicy(gun.LocalTests)]),
        ),
      ])
  }
}

// VIEW ------------------------------------------------------------------------

pub fn view(model: Model, context: Context) -> Element(Msg) {
  element.fragment([
    hero(),
    sinal_section(model, context),
    blueprint_section(model, context),
    gun_section(model, context),
  ])
}

fn lab(
  model: Model,
  id: TourId,
  context: Context,
  children: List(Element(Msg)),
) -> Element(Msg) {
  tour.lab(model.tours, id, driver(context), context, [], children)
}

fn hero() -> Element(Msg) {
  let pill = fn(target, style, text) {
    ui.jump(target, ReaderJumpedTo, [class("pill"), css(style)], [
      html.text(text),
    ])
  }
  html.header([class("wrap"), css("padding-top:72px;padding-bottom:48px")], [
    html.div([class("k")], [
      html.text("Module 6 · Phase 3: the building blocks"),
    ]),
    html.h1(
      [css("font-size:clamp(38px,5.5vw,64px);margin-top:14px;max-width:900px")],
      [html.text("Foundations: observe, shape, reach")],
    ),
    html.p([class("lead"), css("margin-top:20px;font-size:20px")], [
      html.text(
        "Three small libraries carry most of the ecosystem on their backs. ",
      ),
      html.b([], [html.text("Sinal")]),
      html.text(" lets everything report what it's doing. "),
      html.b([], [html.text("JSON Blueprint")]),
      html.text(" describes the shape of data at every boundary. "),
      html.b([], [html.text("HTTP Gun")]),
      html.text(" is the single, bounded door to the network."),
    ]),
    html.div([class("row"), css("margin-top:28px;gap:10px")], [
      pill(
        "sinal",
        "text-decoration:none;color:#0B4A45;background:#DDF3F0",
        "Sinal · telemetry",
      ),
      pill(
        "blueprint",
        "text-decoration:none;color:#0B4A45;background:#DDF3F0",
        "JSON Blueprint · data shapes",
      ),
      pill(
        "gun",
        "text-decoration:none;color:#163A8A;background:#E0E9FD",
        "HTTP Gun · the network",
      ),
    ]),
  ])
}

fn lab_heading(
  tag: String,
  title: String,
  description: List(Element(Msg)),
) -> Element(Msg) {
  html.div([], [
    html.span([class("tag")], [html.text(tag)]),
    html.h2([css("font-size:28px;margin-top:10px")], [html.text(title)]),
    ..description
  ])
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

// SINAL -----------------------------------------------------------------------

fn sinal_section(model: Model, context: Context) -> Element(Msg) {
  let settings = model.pipeline
  let slow = settings.observer == SlowObserver
  let paused = settings.flow == Paused
  let rate = int.to_string(settings.rate)
  html.section(
    [class("wrap sec"), attribute.id("sinal"), attribute("tabindex", "-1")],
    [
      html.div([class("k")], [html.text("Sinal · typed telemetry")]),
      html.h2([class("h2")], [
        html.text("Report facts without slowing the work"),
      ]),
      html.p([class("lead")], [
        html.text(
          "You define an event once, with typed fields. Code emits it; observers react to it. Underneath, it's the same :telemetry registry Erlang and Elixir libraries already share, so their handlers can listen too. Observers normally run inside the emitting process. If they're slow, route them through a bounded ",
        ),
        html.b([], [html.text("forwarder")]),
        html.text("."),
      ]),
      lab(model, SinalTour, context, [
        html.div([class("labh")], [
          lab_heading("Real time", "Emit request.finished, live", [
            html.p([class("muted"), css("margin-top:6px;max-width:700px")], [
              html.text(
                "A request handler emits an event for every request it finishes. Attach a slow observer, then compare running observers inline against routing them through a bounded forwarder. To make it visible, this forwarder holds 12 events; the real default is 1,024.",
              ),
            ]),
          ]),
          html.div([class("row")], [
            html.button(
              [
                attribute.type_("button"),
                class("btn sm"),
                event.on_click(case paused {
                  True -> ReaderResumedPipeline
                  False -> ReaderPausedPipeline
                }),
              ],
              [
                html.text(case paused {
                  True -> "Resume"
                  False -> "Pause"
                }),
              ],
            ),
            html.button(
              [
                attribute.type_("button"),
                class("btn sm"),
                event.on_click(ReaderResetPipeline),
              ],
              [html.text("Reset")],
            ),
          ]),
        ]),
        html.div([class("row"), css("gap:14px;margin-bottom:10px")], [
          html.div([class("seg")], [
            segment(
              "Inline (no route)",
              settings.delivery == Inline,
              ReaderPickedDelivery(Inline),
            ),
            segment(
              "Routed via forwarder",
              settings.delivery == ViaForwarder,
              ReaderPickedDelivery(ViaForwarder),
            ),
          ]),
          html.button(
            [
              attribute.type_("button"),
              class(case slow {
                True -> "btn warn"
                False -> "btn"
              }),
              ui.pressed(slow),
              event.on_click(case slow {
                True -> ReaderRemovedSlowObserver
                False -> ReaderAttachedSlowObserver
              }),
            ],
            [
              html.text(case slow {
                True -> "Remove the slow observer"
                False -> "Attach a slow observer (500 ms)"
              }),
            ],
          ),
          html.label(
            [
              css(
                "display:flex;align-items:center;gap:10px;flex:1 1 220px;max-width:340px",
              ),
            ],
            [
              html.span([css("white-space:nowrap")], [
                html.b([], [html.text(rate)]),
                html.text(" requests/s"),
              ]),
              html.input([
                attribute.type_("range"),
                attribute("min", "1"),
                attribute("max", "20"),
                attribute("step", "1"),
                attribute.value(rate),
                event.on_input(fn(value) {
                  ReaderSetRate(result.unwrap(int.parse(value), settings.rate))
                }),
                css("flex:1"),
              ]),
            ],
          ),
        ]),
        element.element(
          sinal_widget.tag,
          [
            class("live"),
            attribute("data-live", "sinal"),
            css("display:block;width:100%"),
            live.motion_attribute(context.motion),
            sinal_widget.pipeline_attribute(pipeline.Wire(
              settings:,
              latest: model.latest,
              recent: model.issued,
            )),
          ],
          [],
        ),
        html.div([class("row"), css("margin-top:8px;gap:10px")], [
          html.button(
            [
              attribute.type_("button"),
              class("btn sm"),
              event.on_click(ReaderSentBurst),
            ],
            [html.text("Burst of 30 events")],
          ),
          case context.motion {
            motion.Off ->
              html.button(
                [
                  attribute.type_("button"),
                  class("btn sm"),
                  event.on_click(ReaderAdvancedOneSecond),
                ],
                [html.text("Advance 1 second")],
              )
            motion.On -> element.none()
          },
        ]),
        html.div([class("note"), css("margin-top:10px")], [
          html.text(note(settings)),
        ]),
      ]),
      html.div([class("note"), css("margin-top:16px;background:#FFF7E0")], [
        html.b([], [html.text("Two rules from the README:")]),
        html.text(
          " event names become permanent BEAM atoms, so write them in source code and never build them from input. And forwarding is best effort: never use a telemetry event as proof that something happened. That's what durable records are for.",
        ),
      ]),
    ],
  )
}

/// What the reader's settings mean, under the widget.
pub fn note(settings: Settings) -> String {
  let keeps_up = pipeline.forwarder_keeps_up(settings)
  case settings.delivery, settings.observer, keeps_up {
    Inline, SlowObserver, _ ->
      "Inline with a slow observer: the handler can’t serve the next request until telemetry finishes. Requests asked for "
      <> int.to_string(settings.rate)
      <> "/s; the handler now manages about 1 per second."
    Inline, FastObservers, _ ->
      "Inline with fast observers: they run inside the handler before emit returns. Simple, and the right default when observers are cheap."
    ViaForwarder, SlowObserver, False ->
      "Routed: the handler hands events to the forwarder and carries on at full speed. The forwarder can’t keep up with a slow observer either, so once it holds 12 it drops new events and counts them. Best effort, by design."
    ViaForwarder, SlowObserver, True ->
      "Routed with a slow observer at 1 request per second: the forwarder just keeps up. Ask for more and it fills, then drops new events and counts them."
    ViaForwarder, FastObservers, True ->
      "Routed with fast observers: the forwarder drains faster than events arrive. Nothing waits and nothing drops."
    ViaForwarder, FastObservers, False ->
      "Routed with fast observers: the handler never waits, but this forwarder hands the observer one event at a time, under 3 per second. At "
      <> int.to_string(settings.rate)
      <> "/s requests arrive faster, so it still fills and drops. At 2/s or less it drains."
  }
}

// JSON BLUEPRINT --------------------------------------------------------------

fn blueprint_section(model: Model, context: Context) -> Element(Msg) {
  html.section(
    [class("wrap sec"), attribute.id("blueprint"), attribute("tabindex", "-1")],
    [
      html.div([class("k")], [html.text("JSON Blueprint · data shapes")]),
      html.h2([class("h2")], [html.text("One codec, three faces")]),
      html.p([class("lead")], [
        html.text(
          "A codec describes a Gleam type's JSON shape: which fields exist, which are optional, which values are allowed. From that one definition you get an ",
        ),
        html.b([], [html.text("encoder")]),
        html.text(", a strict "),
        html.b([], [html.text("decoder")]),
        html.text(" and a "),
        html.b([], [html.text("JSON Schema")]),
        html.text(
          ". LLM Wire, Relay, Fabric and Decisions all accept codecs, which is why the schema a model sees always matches the decoder that checks its answer.",
        ),
      ]),
      lab(model, CodecTour, context, [
        html.div([class("labh")], [
          lab_heading("Playground", "The User codec", [
            html.p([class("muted"), css("margin-top:6px")], [
              html.text(
                "name (text) · age (whole number from 0 to 150) · email (optional) · role (admin or member)",
              ),
            ]),
          ]),
        ]),
        html.div(
          [class("seg"), css("margin-bottom:20px")],
          list.map(codec.faces, fn(face) {
            segment(
              codec.face_label(face),
              face == model.face,
              ReaderPickedFace(face),
            )
          }),
        ),
        case model.face {
          codec.Encode -> encode_face()
          codec.Decode -> decode_face(model.incoming)
          codec.Schema -> schema_face()
        },
      ]),
      html.div([class("note"), css("margin-top:16px")], [
        html.b([], [html.text("Mind the copy:")]),
        html.text(
          " sending a value to another process copies it whole, without the sharing it had in the process that built it. A Grind worker, a Fabric agent or a Relay tool list, with the codecs and closures it holds, is copied that way each time it moves, so bound its size in a test. JSON Blueprint's ",
        ),
        html.a(
          [
            attribute.href(
              "https://github.com/lostbean/json_blueprint/blob/main/docs/CODEC-PRACTICE.md",
            ),
          ],
          [html.text("codec practice guide")],
        ),
        html.text(
          " states the rule for any value that crosses a process, and how to test it.",
        ),
      ]),
    ],
  )
}

fn lines(texts: List(String)) -> List(Element(Msg)) {
  list.map(texts, html.text) |> list.intersperse(html.br([]))
}

fn encode_face() -> Element(Msg) {
  html.div([class("split"), css("align-items:center")], [
    html.div([class("box"), css("background:#FFF7FC;border-color:#F3C6E6")], [
      html.div([class("meta")], [html.text("Gleam value")]),
      html.div(
        [class("mono"), css("font-size:15px;margin-top:8px;line-height:1.7")],
        lines([
          "User",
          "· name: \"Ada\"",
          "· age: 36",
          "· email: None",
          "· role: Admin",
        ]),
      ),
    ]),
    html.div(
      [class("arrow"), css("flex:0 0 40px"), attribute("aria-hidden", "true")],
      [html.text("→")],
    ),
    html.div([class("box"), css("background:#17162B;color:#E8E6F5;border:0")], [
      html.div([class("meta"), css("color:#C9C6E0")], [html.text("JSON out")]),
      html.div(
        [
          class("mono"),
          // Ordinary spaces kept by pre-wrap, so a copied sample is valid JSON.
          css(
            "font-size:15px;margin-top:8px;line-height:1.7;white-space:pre-wrap",
          ),
        ],
        lines([
          "{ \"name\": \"Ada\",",
          "  \"age\": 36,",
          "  \"role\": \"admin\" }",
        ]),
      ),
      html.p([css("font-size:13px;margin-top:8px;color:#C9C6E0")], [
        html.text("The optional email is simply left out."),
      ]),
    ]),
  ])
}

fn decode_face(incoming: Incoming) -> Element(Msg) {
  let picked = codec.case_of(incoming)
  let #(bg, border) = case picked.outcome {
    codec.Decoded -> #("#F1FAF3", "#B9E2C4")
    codec.Refused -> #("#FEF6F5", "#E9B8B2")
  }
  element.fragment([
    html.div([class("meta"), css("margin-bottom:8px")], [
      html.text("Pick some incoming JSON"),
    ]),
    html.div(
      [class("row"), css("gap:6px;margin-bottom:16px")],
      list.map(codec.incoming, fn(input) {
        let on = input == incoming
        html.button(
          [
            attribute.type_("button"),
            ui.on_class("btn sm", on),
            ui.pressed(on),
            event.on_click(ReaderPickedIncoming(input)),
          ],
          [html.text(codec.case_of(input).label)],
        )
      }),
    ),
    html.div([class("split"), css("align-items:stretch")], [
      html.div(
        [class("box"), css("background:#17162B;color:#E8E6F5;border:0")],
        [
          html.div([class("meta"), css("color:#C9C6E0")], [html.text("JSON in")]),
          html.div(
            [
              class("mono"),
              css(
                "font-size:15px;margin-top:8px;white-space:pre-wrap;line-height:1.6",
              ),
            ],
            [html.text(picked.json)],
          ),
        ],
      ),
      html.div(
        [class("box"), css("background:" <> bg <> ";border-color:" <> border)],
        [
          html.div([class("meta")], [html.text("decode result")]),
          html.div(
            [
              class("mono"),
              css(
                "font-size:16px;font-weight:600;margin:8px 0;white-space:pre-wrap",
              ),
            ],
            [html.text(picked.result)],
          ),
          html.p([css("font-size:14px")], [html.text(picked.why)]),
        ],
      ),
    ]),
  ])
}

fn schema_face() -> Element(Msg) {
  let cell = fn(text, mono) {
    html.div(
      [
        css("background:#fff;padding:10px 14px"),
        case mono {
          True -> class("mono")
          False -> attribute.none()
        },
      ],
      [html.text(text)],
    )
  }
  let head = fn(text) {
    html.div([css("background:#F1EEE8;padding:10px 14px;font-weight:600")], [
      html.text(text),
    ])
  }
  let row = fn(field, type_, rule, required) {
    [
      cell(field, True),
      cell(type_, False),
      cell(rule, False),
      cell(required, False),
    ]
  }
  element.fragment([
    html.div([css("overflow-x:auto")], [
      html.div(
        [
          css(
            "min-width:560px;display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:1px;background:#E4E0D8;border-radius:12px;overflow:hidden;font-size:15px",
          ),
        ],
        list.flatten([
          [head("field"), head("type"), head("rule"), head("required")],
          row("name", "string", "any text", "yes"),
          row("age", "integer", "0 to 150", "yes"),
          row("email", "string", "any text", "no"),
          row("role", "string enum", "\"admin\" or \"member\"", "yes"),
        ]),
      ),
    ]),
    html.p([class("muted"), css("font-size:15px;margin-top:12px")], [
      html.text(
        "This is published as a standard Draft 2020-12 JSON Schema. Hand it to a model as the shape of a structured answer or a tool's arguments, and the same codec checks what comes back.",
      ),
    ]),
  ])
}

// HTTP GUN --------------------------------------------------------------------

fn gun_section(model: Model, context: Context) -> Element(Msg) {
  let selected = gun.part_info(model.part)
  html.section(
    [class("wrap sec"), attribute.id("gun"), attribute("tabindex", "-1")],
    [
      html.div([class("k")], [html.text("HTTP Gun · the network")]),
      html.h2([class("h2")], [html.text("A client that tells the truth")]),
      html.p([class("lead")], [
        html.text(
          "HTTP Gun moves bytes, enforces limits and reports exactly what happened. It deliberately doesn't interpret statuses, retry, follow redirects or speak protocols like SSE: those belong to adapters such as LLM Wire, or to your app. Click a part of the client to see its job.",
        ),
      ]),
      lab(model, AnatomyTour, context, [
        html.div([class("labh")], [
          lab_heading("Explore", "Anatomy of a request", []),
        ]),
        html.div(
          [
            css(
              "display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px;align-items:stretch",
            ),
          ],
          list.index_map(gun.parts, fn(part, i) {
            part_button(part, i, part == model.part)
          }),
        ),
        html.div(
          [
            class("box"),
            css(
              "margin-top:12px;background:#F6F4FF;border-color:#DCD9FF;font-size:16px",
            ),
          ],
          [
            html.b([], [html.text(selected.name <> ".")]),
            html.text(" " <> selected.long),
          ],
        ),
      ]),
      lab(model, DestinationTour, context, [
        html.div([class("labh")], [
          lab_heading("Playground", "Destination policy", [
            html.p([class("muted"), css("margin-top:6px;max-width:680px")], [
              html.text(
                "Before connecting, HTTP Gun checks where an address really resolves. When a model or a user chooses the URL, this is what keeps them out of your private network.",
              ),
            ]),
          ]),
        ]),
        html.div([class("row"), css("gap:16px;margin-bottom:16px")], [
          html.span([class("meta")], [html.text("Policy")]),
          html.div(
            [class("seg")],
            list.map(gun.policies, fn(policy) {
              segment(
                gun.policy_label(policy),
                policy == model.policy,
                ReaderPickedPolicy(policy),
              )
            }),
          ),
        ]),
        html.div(
          [css("display:flex;flex-direction:column;gap:8px")],
          list.map(gun.destinations, destination_row(_, model.policy)),
        ),
        html.p([class("muted"), css("font-size:14px;margin-top:12px")], [
          html.text(
            "The research-agent example goes one step further: its tool policy parses every URL the model picks and only admits one host and path prefix.",
          ),
        ]),
      ]),
      ui.carry_forward(
        "Sinal reports, Blueprint describes, Gun reaches. Each is bounded, each is typed, and each leaves the decisions to your application.",
      ),
    ],
  )
}

fn part_button(part: Part, index: Int, on: Bool) -> Element(Msg) {
  let info = gun.part_info(part)
  let #(bg, fg, border) = case on {
    True -> #("#163A8A", "#FFFFFF", "#163A8A")
    False -> #("#E0E9FD", "#163A8A", "#C9D7FA")
  }
  html.button(
    [
      attribute.type_("button"),
      event.on_click(ReaderPickedPart(part)),
      ui.pressed(on),
      css(
        "font:inherit;cursor:pointer;text-align:left;border-radius:14px;padding:14px;min-height:96px;background:"
        <> bg
        <> ";color:"
        <> fg
        <> ";border:2px solid "
        <> border
        <> ";display:flex;flex-direction:column;gap:4px",
      ),
    ],
    [
      html.span([class("mono"), css("font-size:11px;opacity:.8")], [
        html.text("0" <> int.to_string(index + 1)),
      ]),
      html.b([], [html.text(info.name)]),
      html.span([css("font-size:13px;opacity:.85")], [html.text(info.tiny)]),
    ],
  )
}

fn destination_row(
  destination: gun.Destination,
  policy: Policy,
) -> Element(Msg) {
  let #(verdict, why, bg, border) = case gun.admit(policy, destination) {
    gun.Admitted(why) -> #("Admitted", why, "#F1FAF3", "#B9E2C4")
    gun.Refused(why) -> #("Refused", why, "#FEF6F5", "#E9B8B2")
  }
  html.div(
    [
      css(
        "display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between;padding:12px 16px;border-radius:12px;background:"
        <> bg
        <> ";border:1px solid "
        <> border,
      ),
    ],
    [
      html.span([], [
        html.b([class("mono"), css("font-size:14px")], [
          html.text(destination.url),
        ]),
        html.text(" "),
        html.span([class("muted"), css("font-size:13px")], [
          html.text("→ " <> destination.resolves),
        ]),
      ]),
      html.span([css("font-size:14px")], [
        html.b([], [html.text(verdict)]),
        html.text(" · " <> why),
      ]),
    ],
  )
}
