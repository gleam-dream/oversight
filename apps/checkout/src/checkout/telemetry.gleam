//// Attaches to the Sinal events of every package the app uses (saga,
//// http_gun, grind) and collects them, so one order can be followed across
//// packages.
////
//// An order's correlation is a `sinal/correlation` value made from its
//// order id, and every package carries it in its own metadata:
//// - saga: `execution.with_correlation` (local runs) and
////   `durable.with_correlation` (durable runs);
//// - http_gun: `http_gun.with_correlation` on the client view;
//// - grind: `job.with_correlation` at submit, in every job event's `ref`.
////
//// The collector is Sinal's bounded collector, a child of the application's
//// supervisor. Its process attaches the handlers while it starts and owns
//// them: they are attached exactly while it runs, a restart attaches them
//// again under the same ids, and the application never attaches or
//// detaches a handler itself. It keeps the newest `capacity` entries in a
//// table that handlers write directly, so nothing queues in a mailbox and
//// its memory does not grow with the number of orders. A restarted
//// collector starts empty.

import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision
import gleam/string
import grind/job
import grind/telemetry as grind_telemetry
import http_gun/telemetry as http_telemetry
import saga/telemetry as saga_telemetry
import sinal/collector
import sinal/correlation.{type Correlation}

pub type Source {
  Saga
  Http
  Grind
}

pub type Entry {
  Entry(source: Source, order: Option(Correlation), line: String)
}

pub opaque type Collector {
  Collector(recent: collector.Collector(Entry))
}

/// The process name a collector registers under.
pub type CollectorName =
  Name(collector.Message(Entry))

/// How many entries the collector holds, and how many it has overwritten
/// to stay within its capacity since it started.
pub type Usage {
  Usage(held: Int, dropped: Int)
}

/// The correlation of an order, from its `domain.order_key`.
pub fn order(key: String) -> Correlation {
  correlation.from_key(key)
}

/// A collector registered under `name` that keeps the newest `capacity`
/// entries. It starts nothing; `supervised` runs it.
pub fn new(name: CollectorName, capacity capacity: Int) -> Collector {
  Collector(collector.new(name) |> collector.with_capacity(capacity))
}

/// The collector process, which attaches one handler per event while it
/// starts and owns them.
pub fn supervised(
  telemetry: Collector,
) -> supervision.ChildSpecification(collector.Collector(Entry)) {
  collector.supervised(telemetry.recent, sources())
}

/// Every collected event attributed to `order`, in arrival order.
pub fn trace(telemetry: Collector, order: Correlation) -> List(Entry) {
  // Forwarded events (http_gun, grind) arrive asynchronously.
  process.sleep(50)
  entries_of(telemetry, Some(order))
}

/// How much the collector holds and how much it has overwritten.
pub fn usage(telemetry: Collector) -> Usage {
  let held = list.length(collector.entries(telemetry.recent))
  Usage(held:, dropped: collector.recorded(telemetry.recent) - held)
}

/// Events that carried no correlation.
pub fn unattributed(telemetry: Collector) -> List(Entry) {
  entries_of(telemetry, None)
}

fn entries_of(telemetry: Collector, order: Option(Correlation)) -> List(Entry) {
  collector.entries(telemetry.recent)
  |> list.filter(fn(entry) { entry.order == order })
}

pub fn render(entry: Entry) -> String {
  let source = case entry.source {
    Saga -> "saga    "
    Http -> "http_gun"
    Grind -> "grind   "
  }
  source <> " " <> entry.line
}

// --- sources ----------------------------------------------------------------

fn sources() -> List(collector.Source(Entry)) {
  let record = Entry
  let job = fn(ref: grind_telemetry.JobRef, line) {
    record(
      Grind,
      Some(ref.correlation),
      "job "
        <> line
        <> " "
        <> ref.worker_id
        <> "#"
        <> int.to_string(ref.job_id)
        <> " queue="
        <> ref.queue,
    )
  }
  [
    collector.source(saga_telemetry.run_started(), fn(_m, d) {
      record(Saga, Some(d.correlation), "run start " <> d.workflow)
    }),
    collector.source(saga_telemetry.run_stopped(), fn(m, d) {
      record(
        Saga,
        Some(d.correlation),
        "run stop "
          <> saga_telemetry.outcome_kind_name(d.outcome)
          <> " undone="
          <> int.to_string(m.undone),
      )
    }),
    collector.source(saga_telemetry.step_started(), fn(_m, d) {
      record(
        Saga,
        Some(d.correlation),
        "step start " <> d.step <> " attempt=" <> int.to_string(d.attempt),
      )
    }),
    collector.source(saga_telemetry.step_stopped(), fn(_m, d) {
      record(
        Saga,
        Some(d.correlation),
        "step stop "
          <> d.step
          <> " attempt="
          <> int.to_string(d.attempt)
          <> " "
          <> string.inspect(d.result),
      )
    }),
    collector.source(saga_telemetry.compensation_stopped(), fn(_m, d) {
      record(
        Saga,
        Some(d.correlation),
        "compensate " <> d.step <> " " <> string.inspect(d.decision),
      )
    }),
    collector.source(saga_telemetry.undo_stopped(), fn(_m, d) {
      record(
        Saga,
        Some(d.correlation),
        "undo " <> d.step <> " " <> string.inspect(d.result),
      )
    }),
    collector.source(http_telemetry.event(), fn(_m, d) {
      record(Http, d.correlation, "request " <> string.inspect(d.milestone))
    }),
    collector.source(grind_telemetry.admitted(), fn(_m, d) {
      job(d.ref, "admitted state=" <> job.state_name(d.committed_state))
    }),
    collector.source(grind_telemetry.claimed(), fn(_m, d) {
      job(d.ref, "claimed attempt=" <> int.to_string(d.attempt.attempt))
    }),
    collector.source(grind_telemetry.acknowledged(), fn(_m, d) {
      job(d.ref, "acknowledged state=" <> job.state_name(d.committed_state))
    }),
    collector.source(grind_telemetry.quarantined(), fn(_m, d) {
      job(d.ref, "quarantined replayed=" <> string.inspect(d.replayed))
    }),
    collector.source(grind_telemetry.resolved(), fn(_m, d) {
      job(d.ref, "resolved " <> string.inspect(d.decision))
    }),
  ]
}
