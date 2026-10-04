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

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import grind/job
import grind/telemetry as grind_telemetry
import http_gun/telemetry as http_telemetry
import saga/telemetry as saga_telemetry
import sinal
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
  Collector(subject: Subject(Message), attachments: List(sinal.Attachment))
}

type Message {
  Record(Entry)
  Trace(order: Option(Correlation), reply: Subject(List(Entry)))
}

/// The correlation of an order.
pub fn order(order_id: String) -> Correlation {
  correlation.from_key(order_id)
}

/// Starts the collector and attaches one handler per event descriptor.
pub fn start() -> Collector {
  let assert Ok(started) =
    actor.new([])
    |> actor.on_message(fn(entries, message) {
      case message {
        Record(entry) -> actor.continue([entry, ..entries])
        Trace(order, reply) -> {
          list.reverse(entries)
          |> list.filter(fn(e) { e.order == order })
          |> process.send(reply, _)
          actor.continue(entries)
        }
      }
    })
    |> actor.start
  let subject = started.data
  Collector(subject:, attachments: attach_all(subject))
}

pub fn stop(collector: Collector) -> Nil {
  list.each(collector.attachments, fn(a) {
    let _ = sinal.detach(a)
    Nil
  })
}

/// Every collected event attributed to `order`, in arrival order.
pub fn trace(collector: Collector, order: Correlation) -> List(Entry) {
  // Forwarded events (http_gun, grind) arrive asynchronously.
  process.sleep(50)
  actor.call(collector.subject, 1000, Trace(Some(order), _))
}

/// Events that carried no correlation.
pub fn unattributed(collector: Collector) -> List(Entry) {
  actor.call(collector.subject, 1000, Trace(None, _))
}

pub fn render(entry: Entry) -> String {
  let source = case entry.source {
    Saga -> "saga    "
    Http -> "http_gun"
    Grind -> "grind   "
  }
  source <> " " <> entry.line
}

// --- attachments ----------------------------------------------------------

fn attach_all(subject: Subject(Message)) -> List(sinal.Attachment) {
  let record = fn(source, order, line) {
    process.send(subject, Record(Entry(source, order, line)))
  }
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
    sinal.observe(saga_telemetry.run_started(), fn(_m, d) {
      record(Saga, Some(d.correlation), "run start " <> d.workflow)
    }),
    sinal.observe(saga_telemetry.run_stopped(), fn(m, d) {
      record(
        Saga,
        Some(d.correlation),
        "run stop "
          <> saga_telemetry.outcome_kind_name(d.outcome)
          <> " undone="
          <> int.to_string(m.undone),
      )
    }),
    sinal.observe(saga_telemetry.step_started(), fn(_m, d) {
      record(
        Saga,
        Some(d.correlation),
        "step start " <> d.step <> " attempt=" <> int.to_string(d.attempt),
      )
    }),
    sinal.observe(saga_telemetry.step_stopped(), fn(_m, d) {
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
    sinal.observe(saga_telemetry.compensation_stopped(), fn(_m, d) {
      record(
        Saga,
        Some(d.correlation),
        "compensate " <> d.step <> " " <> string.inspect(d.decision),
      )
    }),
    sinal.observe(saga_telemetry.undo_stopped(), fn(_m, d) {
      record(
        Saga,
        Some(d.correlation),
        "undo " <> d.step <> " " <> string.inspect(d.result),
      )
    }),
    sinal.observe(http_telemetry.event(), fn(_m, d) {
      record(Http, d.correlation, "request " <> string.inspect(d.milestone))
    }),
    sinal.observe(grind_telemetry.admitted(), fn(_m, d) {
      job(d.ref, "admitted state=" <> job.state_name(d.committed_state))
    }),
    sinal.observe(grind_telemetry.claimed(), fn(_m, d) {
      job(d.ref, "claimed attempt=" <> int.to_string(d.attempt.attempt))
    }),
    sinal.observe(grind_telemetry.acknowledged(), fn(_m, d) {
      job(d.ref, "acknowledged state=" <> job.state_name(d.committed_state))
    }),
    sinal.observe(grind_telemetry.quarantined(), fn(_m, d) {
      job(d.ref, "quarantined replayed=" <> string.inspect(d.replayed))
    }),
    sinal.observe(grind_telemetry.resolved(), fn(_m, d) {
      job(d.ref, "resolved " <> string.inspect(d.decision))
    }),
  ]
}
