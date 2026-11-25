//// Collects the Sinal events of every package the app uses and joins them
//// per document.
////
//// The app submits each job with `correlation.from_key(document_id)`. Grind
//// events carry it as `ref.correlation`; the worker reads it from its
//// context and sets it once on the http_gun client views it passes to
//// http_gun and llm_wire, whose events read it from the view. All three
//// sources therefore carry the same correlation and need no table.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import grind/job
import grind/telemetry as grind_telemetry
import http_gun/telemetry as http_telemetry
import llm_wire/telemetry as llm_telemetry
import sinal/collector
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

/// How many records the collector keeps; older records are overwritten.
pub const capacity = 4096

/// The forwarder http_gun clients emit through and a `sinal/collector`,
/// under one supervisor. The collector's process attaches one handler per
/// observed event and owns them, so they are attached exactly while it
/// runs.
pub type Collector {
  Collector(
    recent: collector.Collector(Record),
    http_observations: forwarder.Forwarder,
    supervisor: process.Pid,
  )
}

/// Starts the forwarder and the collector under one supervisor.
pub fn start() -> Result(Collector, String) {
  let recent =
    collector.new(process.new_name("extractor_telemetry"))
    |> collector.with_capacity(capacity)
  let http_observations =
    forwarder.new(process.new_name("extractor_http_observations"))
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(forwarder.supervised(http_observations))
  |> supervisor.add(collector.supervised(recent, sources()))
  |> supervisor.start
  |> result.map(fn(started) {
    Collector(recent:, http_observations:, supervisor: started.pid)
  })
  |> result.replace_error("could not start the telemetry collector")
}

fn sources() -> List(collector.Source(Record)) {
  let record = Record
  [
    collector.source(grind_telemetry.admitted(), fn(_, meta) {
      record(
        Grind,
        Some(meta.ref.correlation),
        "admitted " <> job.state_name(meta.committed_state),
      )
    }),
    collector.source(grind_telemetry.claimed(), fn(_, meta) {
      record(
        Grind,
        Some(meta.ref.correlation),
        "claimed attempt " <> int.to_string(meta.attempt.attempt),
      )
    }),
    collector.source(grind_telemetry.acknowledged(), fn(_, meta) {
      record(
        Grind,
        Some(meta.ref.correlation),
        "acknowledged " <> job.state_name(meta.committed_state),
      )
    }),
    collector.source(grind_telemetry.released(), fn(_, meta) {
      record(Grind, Some(meta.ref.correlation), "released")
    }),
    collector.source(http_telemetry.event(), fn(_, meta) {
      record(
        Http,
        meta.correlation,
        option.unwrap(meta.client, "http") <> " " <> milestone(meta.milestone),
      )
    }),
    collector.source(llm_telemetry.event(), fn(_, meta) {
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
}

/// Stops the collector and the forwarder and waits for them. Sinal detaches
/// the handlers the collector's process owned.
pub fn stop(telemetry: Collector) -> Nil {
  stop_supervisor(telemetry.supervisor)
}

@external(erlang, "extractor_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil

/// The correlation a document's job carries, in every package's events.
/// An id that is empty or longer than 128 bytes becomes its SHA-256 digest.
pub fn document_correlation(document_id: String) -> Correlation {
  correlation.from_key(document_id)
}

/// The records the collector holds, oldest first: at most `capacity`.
/// Empty once it has stopped.
pub fn snapshot(telemetry: Collector) -> List(Record) {
  collector.entries(telemetry.recent)
}

/// Every record attributable to one document, plus the records the
/// collector could not attribute to any document.
pub type Trace {
  Trace(attributed: List(Record), unattributed: List(Record))
}

pub fn trace(telemetry: Collector, document_id: String) -> Trace {
  let records = snapshot(telemetry)
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
