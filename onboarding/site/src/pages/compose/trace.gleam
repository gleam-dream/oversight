//// The capstone: the durable checkout told only through the telemetry events
//// Grind, Saga and HTTP Gun emit. Event names and HTTP Gun's milestones are
//// the libraries' real ones; the order is reconstructed from the checkout
//// example's design, not recorded from a live run.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import site/msc

pub type Outcome {
  Succeeds
  ShippingFails
}

pub const outcomes = [Succeeds, ShippingFails]

pub fn outcome_label(outcome: Outcome) -> String {
  case outcome {
    Succeeds -> "Everything succeeds"
    ShippingFails -> "Shipping fails"
  }
}

/// The columns of the trace, left to right.
pub type Lane {
  App
  GrindLane
  SagaLane
  HttpGunLane
  Providers
}

pub const lanes = [App, GrindLane, SagaLane, HttpGunLane, Providers]

pub fn lane_label(lane: Lane) -> String {
  case lane {
    App -> "your app"
    GrindLane -> "Grind"
    SagaLane -> "Saga"
    HttpGunLane -> "HTTP Gun"
    Providers -> "providers"
  }
}

pub fn lane_index(lane: Lane) -> Int {
  case lane {
    App -> 0
    GrindLane -> 1
    SagaLane -> 2
    HttpGunLane -> 3
    Providers -> 4
  }
}

/// The library whose telemetry module emits an event.
pub type Emitter {
  Grind
  Saga
  HttpGun
}

pub type Emitted {
  Emitted(name: String, bg: String, fg: String, colour: msc.Colour)
}

pub fn emitter(by: Emitter) -> Emitted {
  case by {
    Grind -> Emitted("Grind", "#FDF0DC", "#6B3404", msc.Amber)
    Saga -> Emitted("Saga", "#FCE7F3", "#5E0B3A", msc.Pink)
    HttpGun -> Emitted("HTTP Gun", "#E0E9FD", "#163A8A", msc.Blue)
  }
}

/// Where an event shows on the chart: an arrow from one column to another,
/// or a mark on one column.
pub type Place {
  Between(from: Lane, to: Lane)
  At(Lane)
}

pub type Event {
  Event(
    place: Place,
    /// The telemetry event name, such as `saga.step.start`.
    name: String,
    /// The step or milestone it concerns, when the name alone does not say.
    subject: Option(String),
    by: Emitter,
    meaning: String,
    fields: Option(String),
  )
}

fn ev(
  place: Place,
  name: String,
  subject: Option(String),
  by: Emitter,
  meaning: String,
) -> Event {
  Event(place:, name:, subject:, by:, meaning:, fields: None)
}

fn with_fields(event: Event, fields: String) -> Event {
  Event(..event, fields: Some(fields))
}

fn admitted() -> Event {
  ev(
    Between(App, GrindLane),
    "grind.job.admitted",
    None,
    Grind,
    "The order row and the job row were written in one transaction. From here on, the work is durable.",
  )
  |> with_fields("job reference, committed state")
}

fn common() -> List(Event) {
  [
    admitted(),
    ev(
      At(GrindLane),
      "grind.job.claimed",
      None,
      Grind,
      "A queue coordinator claimed the job under a database lease and started an attempt process.",
    ),
    ev(
      Between(GrindLane, SagaLane),
      "saga.run.start",
      None,
      Saga,
      "The job’s handler drives the checkout saga by its stable execution id.",
    ),
    ev(
      Between(SagaLane, Providers),
      "saga.step.start",
      Some("reserve_inventory"),
      Saga,
      "The first step calls the inventory service (through HTTP Gun, condensed here).",
    ),
    ev(
      Between(Providers, SagaLane),
      "saga.step.stop",
      Some("reserve_inventory"),
      Saga,
      "Stock is held. The step is checkpointed and enters the undo journal.",
    ),
    ev(
      Between(SagaLane, HttpGunLane),
      "saga.step.start",
      Some("charge_payment"),
      Saga,
      "The charge step starts, with an idempotency key that every attempt reuses. Zooming into HTTP Gun for this one.",
    ),
    ev(
      At(HttpGunLane),
      "http_gun.lifecycle",
      Some("admission_granted"),
      HttpGun,
      "The client pool admitted the request and selected a connection.",
    )
      |> with_fields("request id, correlation, client, mode, milestone"),
    ev(
      Between(HttpGunLane, Providers),
      "http_gun.lifecycle",
      Some("gun_call_returned"),
      HttpGun,
      "Gun accepted the request. Notice what this does not prove: that the provider received it. That gap is MaybeSent.",
    )
      |> with_fields("milestone: GunCallReturned"),
    ev(
      At(GrindLane),
      "grind.diagnostic.renewal",
      None,
      Grind,
      "Meanwhile, the renewer extended the job’s lease on its own connection.",
    ),
    ev(
      Between(Providers, HttpGunLane),
      "http_gun.lifecycle",
      Some("response_headers"),
      HttpGun,
      "The response headers (status 200) passed HTTP Gun’s checks.",
    )
      |> with_fields("milestone: ResponseHeaders(200)"),
    ev(
      Between(HttpGunLane, SagaLane),
      "http_gun.lifecycle",
      Some("http_terminated"),
      HttpGun,
      "The exchange settled as Complete: HTTP finished. Whether the body means success is the app’s call.",
    )
      |> with_fields("milestone: HttpTerminated(Complete)"),
    ev(
      At(SagaLane),
      "saga.step.stop",
      Some("charge_payment"),
      Saga,
      "Payment confirmed and checkpointed.",
    ),
    ev(
      Between(SagaLane, Providers),
      "saga.step.start",
      Some("book_shipment"),
      Saga,
      "The last step books the carrier.",
    ),
  ]
}

fn ending(outcome: Outcome) -> List(Event) {
  case outcome {
    Succeeds -> [
      ev(
        Between(Providers, SagaLane),
        "saga.step.stop",
        Some("book_shipment"),
        Saga,
        "Shipment booked.",
      ),
      ev(
        Between(SagaLane, GrindLane),
        "saga.run.stop",
        None,
        Saga,
        "Every step succeeded; the run reports its terminal outcome.",
      ),
      ev(
        Between(GrindLane, App),
        "grind.job.acknowledged",
        None,
        Grind,
        "The attempt’s result is stored in the job row: the durable truth for this order.",
      ),
    ]
    ShippingFails -> [
      ev(
        Between(Providers, SagaLane),
        "saga.step.stop",
        Some("book_shipment"),
        Saga,
        "The carrier rejected the booking: the step stops with an error.",
      ),
      ev(
        Between(SagaLane, Providers),
        "saga.step.undo.stop",
        Some("charge_payment"),
        Saga,
        "Undo, newest first: the charge is refunded.",
      ),
      ev(
        Between(SagaLane, Providers),
        "saga.step.undo.stop",
        Some("reserve_inventory"),
        Saga,
        "Then the stock hold is released.",
      ),
      ev(
        Between(SagaLane, GrindLane),
        "saga.run.stop",
        None,
        Saga,
        "The run ends compensated, with every undo result kept as evidence.",
      ),
      ev(
        Between(GrindLane, App),
        "grind.job.acknowledged",
        None,
        Grind,
        "The attempt’s result is stored in the job row. The order fails cleanly, with nothing left half-done.",
      ),
    ]
  }
}

/// Every event of the trace, in order.
pub fn events(outcome: Outcome) -> List(Event) {
  list.append(common(), ending(outcome))
}

pub fn length(outcome: Outcome) -> Int {
  list.length(events(outcome))
}

/// The event at a 1-based position, kept within the trace.
pub fn event_at(outcome: Outcome, n: Int) -> Event {
  let all = events(outcome)
  let n = int.clamp(n, 1, list.length(all))
  case list.drop(all, n - 1) {
    [event, ..] -> event
    [] -> admitted()
  }
}

/// The event name as a Sinal event name list, as an operator sees it:
/// `["saga", "step", "start"]  reserve_inventory`.
pub fn name_list(event: Event) -> String {
  let parts =
    string.split(event.name, ".")
    |> list.map(fn(part) { "\"" <> part <> "\"" })
  "["
  <> string.join(parts, ", ")
  <> "]"
  <> case event.subject {
    Some(subject) -> "  " <> subject
    None -> ""
  }
}

/// The short label on the chart's arrow.
pub fn short_label(event: Event) -> String {
  case event.by, event.subject {
    HttpGun, Some(milestone) -> "lifecycle: " <> milestone
    _, Some(subject) -> {
      let head = case string.split(subject, "_") {
        [first, ..] -> first
        [] -> subject
      }
      event.name <> " (" <> head <> ")"
    }
    _, None -> event.name
  }
}

/// The lane to highlight for an event: where an arrow lands, or where a mark
/// sits.
pub fn active_lane(event: Event) -> Lane {
  case event.place {
    Between(to:, ..) -> to
    At(lane) -> lane
  }
}

/// The trace as a sequence chart up to event `upto`.
pub fn chart(outcome: Outcome, upto: Int) -> msc.Chart {
  let all = events(outcome)
  let total = list.length(all)
  let current = event_at(outcome, upto)
  msc.Chart(
    ..msc.chart("tr", list.map(lanes, lane_label), list.map(all, chart_event)),
    upto: Some(upto),
    lane_gap: 165,
    row: 26,
    numbers: True,
    active: Some(lane_index(active_lane(current))),
    aria: "Trace of the durable checkout as telemetry events, event "
      <> int.to_string(upto)
      <> " of "
      <> int.to_string(total),
  )
}

fn chart_event(event: Event) -> msc.Event {
  let colour = emitter(event.by).colour
  case event.place {
    Between(from:, to:) ->
      msc.send(lane_index(from), lane_index(to), short_label(event), colour)
    At(lane) -> msc.Note(lane_index(lane), short_label(event), colour)
  }
}
