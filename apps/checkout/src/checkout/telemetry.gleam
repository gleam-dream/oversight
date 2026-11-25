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
//// The collector is a named actor under the application's supervisor. The
//// handlers are attached once, by `attach`, and send to the name, so they
//// reach whichever collector process is running. A restarted collector
//// starts empty.
////
//// The collector keeps the newest `capacity` entries and counts the ones
//// it discards (`usage`), so its memory does not grow with the number of
//// orders. The bound is on what it holds, not on its mailbox: handlers
//// send without waiting, and recording an entry takes constant time.

import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
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
  Collector(
    name: Name(Message),
    capacity: Int,
    attachments: List(sinal.Attachment),
  )
}

/// How many entries the collector holds, and how many it has discarded
/// to stay within its capacity since it started.
pub type Usage {
  Usage(held: Int, dropped: Int)
}

pub opaque type Message {
  Record(Entry)
  Trace(order: Option(Correlation), reply: Subject(List(Entry)))
  ReadUsage(reply: Subject(Usage))
}

/// The correlation of an order, from its `domain.order_key`.
pub fn order(key: String) -> Correlation {
  correlation.from_key(key)
}

/// Attaches one handler per event descriptor. Each handler sends to the
/// collector registered under `name`; while none is running, the event is
/// dropped. Call once per application start and `detach` at its stop:
/// handlers are node-wide registrations, not processes, so no supervisor
/// removes them.
pub fn attach(name: Name(Message), capacity capacity: Int) -> Collector {
  Collector(name:, capacity:, attachments: attach_all(name))
}

/// The collector process, registered under the name given to `attach`.
/// It keeps the newest `capacity` entries.
pub fn supervised(collector: Collector) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    actor.new(empty(collector.capacity))
    |> actor.named(collector.name)
    |> actor.on_message(fn(held, message) {
      case message {
        Record(entry) -> actor.continue(push(held, entry))
        Trace(order, reply) -> {
          oldest_first(held)
          |> list.filter(fn(e) { e.order == order })
          |> process.send(reply, _)
          actor.continue(held)
        }
        ReadUsage(reply) -> {
          process.send(reply, Usage(held: held.size, dropped: held.dropped))
          actor.continue(held)
        }
      }
    })
    |> actor.start
    |> result.map(fn(started) { actor.Started(..started, data: Nil) })
  })
}

/// The newest entries, at most `capacity` of them, as a queue: an entry is
/// added to `newer` and the oldest is taken from `older`, which is refilled
/// by reversing `newer` when it runs out. Adding costs constant time on
/// average, whatever the capacity.
type Held {
  Held(
    capacity: Int,
    size: Int,
    dropped: Int,
    /// Oldest first.
    older: List(Entry),
    /// Newest first.
    newer: List(Entry),
  )
}

/// A capacity below 1 is treated as 1.
fn empty(capacity: Int) -> Held {
  Held(
    capacity: int.max(capacity, 1),
    size: 0,
    dropped: 0,
    older: [],
    newer: [],
  )
}

fn push(held: Held, entry: Entry) -> Held {
  let held = Held(..held, size: held.size + 1, newer: [entry, ..held.newer])
  case held.size > held.capacity {
    False -> held
    True -> drop_oldest(held)
  }
}

fn drop_oldest(held: Held) -> Held {
  case held.older {
    [_, ..older] ->
      Held(..held, size: held.size - 1, dropped: held.dropped + 1, older:)
    [] ->
      case list.reverse(held.newer) {
        [_, ..older] ->
          Held(
            ..held,
            size: held.size - 1,
            dropped: held.dropped + 1,
            older:,
            newer: [],
          )
        [] -> held
      }
  }
}

fn oldest_first(held: Held) -> List(Entry) {
  list.append(held.older, list.reverse(held.newer))
}

pub fn detach(collector: Collector) -> Nil {
  list.each(collector.attachments, fn(a) {
    let _ = sinal.detach(a)
    Nil
  })
}

/// Every collected event attributed to `order`, in arrival order.
pub fn trace(collector: Collector, order: Correlation) -> List(Entry) {
  // Forwarded events (http_gun, grind) arrive asynchronously.
  process.sleep(50)
  actor.call(process.named_subject(collector.name), 1000, Trace(Some(order), _))
}

/// How much the collector holds and how much it has discarded.
pub fn usage(collector: Collector) -> Usage {
  actor.call(process.named_subject(collector.name), 1000, ReadUsage)
}

/// Events that carried no correlation.
pub fn unattributed(collector: Collector) -> List(Entry) {
  actor.call(process.named_subject(collector.name), 1000, Trace(None, _))
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

/// Runs `send` and reports whether it returned. A handler that raises is
/// removed by telemetry for good, and a send to a name raises while no
/// process holds it, which is the case between a collector's exit and its
/// restart.
@external(erlang, "checkout_ffi", "attempt")
fn attempt(send: fn() -> Nil) -> Bool

fn attach_all(name: Name(Message)) -> List(sinal.Attachment) {
  let record = fn(source, order, line) {
    let _ =
      attempt(fn() {
        process.send(
          process.named_subject(name),
          Record(Entry(source, order, line)),
        )
      })
    Nil
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
