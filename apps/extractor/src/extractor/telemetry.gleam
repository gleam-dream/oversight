//// Collects the Sinal events of every package the app uses and joins them
//// per document.
////
//// The app submits each job with `correlation.from_key(document_id)`. Grind
//// events carry it as `ref.correlation`; the worker reads it from its
//// context and sets it once on the http_gun client views it passes to
//// http_gun and llm_wire, whose events read it from the view. All three
//// sources therefore carry the same correlation and need no table.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import grind/job
import grind/telemetry as grind_telemetry
import http_gun/telemetry as http_telemetry
import llm_wire/telemetry as llm_telemetry
import sinal
import sinal/correlation.{type Correlation}
import sinal/forwarder

pub type Source {
  Grind
  Http
  Llm
}

pub type Record {
  Record(source: Source, correlation: Option(Correlation), summary: String)
}

pub opaque type Message {
  Observed(Record)
  Snapshot(reply: Subject(List(Record)))
}

pub type Collector {
  Collector(
    subject: Subject(Message),
    attachments: List(sinal.Attachment),
    http_observations: forwarder.Forwarder,
  )
}

/// Starts the collector, the forwarder http_gun clients emit through, and
/// one Sinal handler per observed event.
pub fn start() -> Result(Collector, String) {
  use subject <- result.try(
    actor.new([])
    |> actor.on_message(handle)
    |> actor.start
    |> result.map(fn(started) { started.data })
    |> result.replace_error("could not start the telemetry collector"),
  )
  let http_observations =
    forwarder.new(process.new_name("extractor_http_observations"))
  use _ <- result.try(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(forwarder.supervised(http_observations))
    |> supervisor.start
    |> result.replace_error("could not start the observation forwarder"),
  )
  let record = fn(source, correlation, summary) {
    process.send(subject, Observed(Record(source, correlation, summary)))
  }
  let attachments = [
    sinal.observe(grind_telemetry.admitted(), fn(_, meta) {
      record(
        Grind,
        Some(meta.ref.correlation),
        "admitted " <> job.state_name(meta.committed_state),
      )
    }),
    sinal.observe(grind_telemetry.claimed(), fn(_, meta) {
      record(
        Grind,
        Some(meta.ref.correlation),
        "claimed attempt " <> int.to_string(meta.attempt.attempt),
      )
    }),
    sinal.observe(grind_telemetry.acknowledged(), fn(_, meta) {
      record(
        Grind,
        Some(meta.ref.correlation),
        "acknowledged " <> job.state_name(meta.committed_state),
      )
    }),
    sinal.observe(grind_telemetry.released(), fn(_, meta) {
      record(Grind, Some(meta.ref.correlation), "released")
    }),
    sinal.observe(http_telemetry.event(), fn(_, meta) {
      record(
        Http,
        meta.correlation,
        option.unwrap(meta.client, "http") <> " " <> milestone(meta.milestone),
      )
    }),
    sinal.observe(llm_telemetry.event(), fn(_, meta) {
      record(
        Llm,
        meta.correlation,
        meta.provider
          <> " "
          <> llm_telemetry.stage_name(meta.stage)
          <> " "
          <> llm_telemetry.outcome_name(meta.outcome),
      )
    }),
  ]
  Ok(Collector(subject:, attachments:, http_observations:))
}

pub fn stop(collector: Collector) -> Nil {
  list.each(collector.attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
}

/// The correlation a document's job carries, in every package's events.
/// An id that is empty or longer than 128 bytes becomes its SHA-256 digest.
pub fn document_correlation(document_id: String) -> Correlation {
  correlation.from_key(document_id)
}

pub fn snapshot(collector: Collector) -> List(Record) {
  process.call(collector.subject, 1000, Snapshot)
}

/// Every record attributable to one document, plus the records the
/// collector could not attribute to any document.
pub type Trace {
  Trace(attributed: List(Record), unattributed: List(Record))
}

pub fn trace(collector: Collector, document_id: String) -> Trace {
  let records = snapshot(collector)
  let document_id = document_correlation(document_id) |> correlation.to_string
  let #(attributed, rest) =
    list.partition(records, fn(record) {
      option.map(record.correlation, correlation.to_string) == Some(document_id)
    })
  Trace(
    attributed:,
    unattributed: list.filter(rest, fn(record) { record.correlation == None }),
  )
}

pub fn count(records: List(Record), source: Source) -> Int {
  list.count(records, fn(record) { record.source == source })
}

pub fn render(record: Record) -> String {
  let source = case record.source {
    Grind -> "grind   "
    Http -> "http_gun"
    Llm -> "llm_wire"
  }
  source <> "  " <> record.summary
}

fn handle(
  records: List(Record),
  message: Message,
) -> actor.Next(List(Record), Message) {
  case message {
    Observed(record) -> actor.continue([record, ..records])
    Snapshot(reply) -> {
      process.send(reply, list.reverse(records))
      actor.continue(records)
    }
  }
}

fn milestone(milestone: http_telemetry.Milestone) -> String {
  case milestone {
    http_telemetry.AdmissionEntered -> "admission entered"
    http_telemetry.AdmissionWaiting -> "admission waiting"
    http_telemetry.AdmissionGranted -> "admission granted"
    http_telemetry.GunCallReturned -> "request handed to gun"
    http_telemetry.ResponseHeaders(status) ->
      "response headers " <> int.to_string(status)
    http_telemetry.HttpTerminated(outcome) ->
      "terminated " <> string.lowercase(string.inspect(outcome))
  }
}
