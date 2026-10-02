//// Attaches to the Sinal events of every package the app uses (saga,
//// http_gun, grind) and collects them, so one order can be followed across
//// packages.
////
//// An order's correlation is a `sinal/correlation` value made from its
//// order id. No package carries it yet, so each event is linked to it here:
//// - http_gun: an opaque `telemetry.Id` per order, created by this module
////   and attached to the client with `http_gun.with_correlation`;
//// - saga: local runs are linked by `execution.run_id`; durable runs expose
////   no run id at all, so they are linked by the *emitting process*, which
////   the Postgres saga storage reports when a runner claims an execution;
//// - grind: jobs are linked through `admitted.submission_id`, because the
////   app submits with a `SubmissionId` derived from the order id.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import grind/job
import grind/observation as grind_obs
import http_gun/telemetry as http_telemetry
import saga/observation as saga_obs
import sinal
import sinal/correlation.{type Correlation}

pub type Source {
  Saga
  Http
  Grind
}

/// What an event can be correlated by.
pub type Key {
  SagaRun(Int)
  Emitter(Pid)
  HttpCorrelation(http_telemetry.Id)
  GrindJob(Int)
}

pub type Entry {
  Entry(source: Source, keys: List(Key), line: String)
}

pub opaque type Collector {
  Collector(subject: Subject(Message), attachments: List(sinal.Attachment))
}

type State {
  State(
    entries: List(Entry),
    links: Dict(Key, Correlation),
    http_ids: Dict(Correlation, http_telemetry.Id),
  )
}

type Message {
  Record(Entry)
  Link(Key, Correlation)
  HttpId(order: Correlation, reply: Subject(http_telemetry.Id))
  Trace(order: Correlation, reply: Subject(List(Entry)))
  Unattributed(reply: Subject(List(Entry)))
}

/// The correlation of an order. The web layer refuses an order id that is
/// not a valid correlation (empty, or longer than 128 bytes).
pub fn order(order_id: String) -> Correlation {
  let assert Ok(order) = correlation.from_string(order_id)
  order
}

/// The order behind an id of the form `"<kind>:<order id>"`, as used for
/// saga execution ids and grind submission ids.
pub fn from_tagged_id(id: String) -> Result(Correlation, Nil) {
  use #(_, order_id) <- result.try(string.split_once(id, ":"))
  correlation.from_string(order_id) |> result.replace_error(Nil)
}

/// Starts the collector and attaches one handler per event descriptor.
pub fn start() -> Collector {
  let assert Ok(started) =
    actor.new(State([], dict.new(), dict.new()))
    |> actor.on_message(handle)
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

/// The http_gun correlation id for an order, created on first use.
pub fn http_id(collector: Collector, order: Correlation) -> http_telemetry.Id {
  actor.call(collector.subject, 1000, HttpId(order, _))
}

pub fn link(collector: Collector, key: Key, order: Correlation) -> Nil {
  actor.send(collector.subject, Link(key, order))
}

/// Every collected event attributed to `order`, in arrival order.
pub fn trace(collector: Collector, order: Correlation) -> List(Entry) {
  // Forwarded events (http_gun, grind) arrive asynchronously.
  process.sleep(50)
  actor.call(collector.subject, 1000, Trace(order, _))
}

/// Events that could not be attributed to any order.
pub fn unattributed(collector: Collector) -> List(Entry) {
  actor.call(collector.subject, 1000, Unattributed)
}

pub fn render(entry: Entry) -> String {
  let source = case entry.source {
    Saga -> "saga    "
    Http -> "http_gun"
    Grind -> "grind   "
  }
  source <> " " <> entry.line
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Record(entry) ->
      actor.continue(State(..state, entries: [entry, ..state.entries]))
    Link(key, order) ->
      actor.continue(
        State(..state, links: dict.insert(state.links, key, order)),
      )
    HttpId(order, reply) ->
      case dict.get(state.http_ids, order) {
        Ok(id) -> {
          process.send(reply, id)
          actor.continue(state)
        }
        Error(Nil) -> {
          let id = http_telemetry.new_id()
          process.send(reply, id)
          actor.continue(
            State(
              ..state,
              http_ids: dict.insert(state.http_ids, order, id),
              links: dict.insert(state.links, HttpCorrelation(id), order),
            ),
          )
        }
      }
    Trace(order, reply) -> {
      list.reverse(state.entries)
      |> list.filter(fn(e) { owner(state, e) == Some(order) })
      |> process.send(reply, _)
      actor.continue(state)
    }
    Unattributed(reply) -> {
      list.reverse(state.entries)
      |> list.filter(fn(e) { owner(state, e) == None })
      |> process.send(reply, _)
      actor.continue(state)
    }
  }
}

fn owner(state: State, entry: Entry) -> Option(Correlation) {
  list.find_map(entry.keys, fn(key) { dict.get(state.links, key) })
  |> option.from_result
}

// --- attachments ----------------------------------------------------------

fn attach_all(subject: Subject(Message)) -> List(sinal.Attachment) {
  let record = fn(source, keys, line) {
    process.send(subject, Record(Entry(source, keys, line)))
  }
  let saga_keys = fn(run) { [SagaRun(run), Emitter(process.self())] }
  [
    sinal.observe(saga_obs.run_started(), fn(_m, d) {
      record(Saga, saga_keys(d.run), "run start " <> d.workflow)
    }),
    sinal.observe(saga_obs.run_stopped(), fn(m, d) {
      record(
        Saga,
        saga_keys(d.run),
        "run stop "
          <> string.inspect(d.outcome)
          <> " undone="
          <> int.to_string(m.undone),
      )
    }),
    sinal.observe(saga_obs.step_started(), fn(_m, d) {
      record(
        Saga,
        saga_keys(d.run),
        "step start " <> d.step <> " attempt=" <> int.to_string(d.attempt),
      )
    }),
    sinal.observe(saga_obs.step_stopped(), fn(_m, d) {
      record(
        Saga,
        saga_keys(d.run),
        "step stop "
          <> d.step
          <> " attempt="
          <> int.to_string(d.attempt)
          <> " "
          <> string.inspect(d.result),
      )
    }),
    sinal.observe(saga_obs.compensation_stopped(), fn(_m, d) {
      record(
        Saga,
        saga_keys(d.run),
        "compensate " <> d.step <> " " <> string.inspect(d.decision),
      )
    }),
    sinal.observe(saga_obs.undo_stopped(), fn(_m, d) {
      record(
        Saga,
        saga_keys(d.run),
        "undo " <> d.step <> " " <> string.inspect(d.result),
      )
    }),
    sinal.observe(http_telemetry.event(), fn(_m, d) {
      let keys = case d.correlation {
        Some(id) -> [HttpCorrelation(id)]
        None -> []
      }
      record(Http, keys, "request " <> string.inspect(d.milestone))
    }),
    sinal.observe(grind_obs.admitted(), fn(_m, d) {
      // The submission id is "<kind>:<order id>"; nothing else in grind's
      // metadata identifies the application's order.
      case option.map(d.submission_id, from_tagged_id) {
        Some(Ok(order)) ->
          process.send(subject, Link(GrindJob(d.ref.job_id), order))
        _ -> Nil
      }
      record(
        Grind,
        [GrindJob(d.ref.job_id)],
        "job admitted "
          <> job_line(d.ref)
          <> " state="
          <> job.state_to_stored(d.committed_state),
      )
    }),
    sinal.observe(grind_obs.claimed(), fn(_m, d) {
      record(
        Grind,
        [GrindJob(d.ref.job_id)],
        "job claimed "
          <> job_line(d.ref)
          <> " attempt="
          <> int.to_string(d.attempt.attempt),
      )
    }),
    sinal.observe(grind_obs.acknowledged(), fn(_m, d) {
      record(
        Grind,
        [GrindJob(d.ref.job_id)],
        "job acknowledged "
          <> job_line(d.ref)
          <> " state="
          <> job.state_to_stored(d.committed_state),
      )
    }),
    sinal.observe(grind_obs.quarantined(), fn(_m, d) {
      record(
        Grind,
        [GrindJob(d.ref.job_id)],
        "job quarantined " <> job_line(d.ref),
      )
    }),
    sinal.observe(grind_obs.resolved(), fn(_m, d) {
      record(
        Grind,
        [GrindJob(d.ref.job_id)],
        "job resolved " <> job_line(d.ref) <> " " <> string.inspect(d.decision),
      )
    }),
  ]
}

fn job_line(ref: grind_obs.JobRef) -> String {
  ref.worker_id <> "#" <> int.to_string(ref.job_id) <> " queue=" <> ref.queue
}
