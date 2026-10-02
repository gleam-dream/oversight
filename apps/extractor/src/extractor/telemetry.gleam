//// Collects the Sinal events of every package the app uses and joins them
//// per document.
////
//// The packages share one correlation key only where they carry it. Grind
//// events carry `job_id`; the worker never learns its job id, so the app maps
//// job id to document id at submission. http_gun events carry the
//// `Correlation` the worker attaches to its client views: the document id
//// itself, so no table is needed. llm_wire events carry only
//// `stage/provider/outcome`, so the collector attributes them through the
//// emitting process, which works only when llm_wire emits in a process the
//// worker registered.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import grind/job
import grind/observation
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
  Record(source: Source, key: Key, summary: String)
}

/// What the event offers for correlation.
pub type Key {
  JobId(Int)
  HttpCorrelation(Option(Correlation))
  EmitterPid(Pid)
}

pub opaque type Message {
  Observed(Record)
  JobSubmitted(job_id: Int, document_id: String)
  WorkerProcess(pid: Pid, document_id: String)
  Snapshot(reply: Subject(State))
}

pub type State {
  State(
    records: List(Record),
    jobs: Dict(Int, String),
    processes: Dict(Pid, String),
  )
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
    actor.new(State([], dict.new(), dict.new()))
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
  let record = fn(source, key, summary) {
    process.send(subject, Observed(Record(source, key, summary)))
  }
  let attachments = [
    sinal.observe(observation.admitted(), fn(_, meta) {
      record(
        Grind,
        JobId(meta.ref.job_id),
        "admitted " <> state(meta.committed_state),
      )
    }),
    sinal.observe(observation.claimed(), fn(_, meta) {
      record(
        Grind,
        JobId(meta.ref.job_id),
        "claimed attempt " <> int.to_string(meta.attempt.attempt),
      )
    }),
    sinal.observe(observation.acknowledged(), fn(_, meta) {
      record(
        Grind,
        JobId(meta.ref.job_id),
        "acknowledged " <> state(meta.committed_state),
      )
    }),
    sinal.observe(observation.released(), fn(_, meta) {
      record(Grind, JobId(meta.ref.job_id), "released")
    }),
    sinal.observe(http_telemetry.event(), fn(_, meta) {
      record(Http, HttpCorrelation(meta.correlation), milestone(meta.milestone))
    }),
    sinal.observe(llm_telemetry.observation_event(), fn(_, meta) {
      record(
        Llm,
        EmitterPid(process.self()),
        meta.provider <> " " <> meta.stage <> " " <> meta.outcome,
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

pub fn job_submitted(
  collector: Collector,
  job_id: Int,
  document_id: String,
) -> Nil {
  process.send(collector.subject, JobSubmitted(job_id, document_id))
}

/// Called by the worker: the correlation for this attempt's http_gun client
/// views, and the worker process itself for llm_wire attribution. The
/// correlation is the document id, so every attempt of a document shares it.
/// An id that is empty or longer than 128 bytes cannot be a correlation;
/// that attempt's http_gun events get a fresh one and stay unattributed.
pub fn begin_attempt(collector: Collector, document_id: String) -> Correlation {
  process.send(collector.subject, WorkerProcess(process.self(), document_id))
  correlation.from_string(document_id)
  |> result.lazy_unwrap(correlation.unique)
}

pub fn snapshot(collector: Collector) -> State {
  process.call(collector.subject, 1000, Snapshot)
}

/// Every record attributable to one document, plus the records the
/// collector could not attribute to any document.
pub type Trace {
  Trace(attributed: List(Record), unattributed: List(Record))
}

pub fn trace(collector: Collector, document_id: String) -> Trace {
  let state = snapshot(collector)
  let #(attributed, rest) =
    list.partition(state.records, fn(record) {
      owner(state, record.key) == Some(document_id)
    })
  Trace(
    attributed:,
    unattributed: list.filter(rest, fn(record) {
      owner(state, record.key) == None
    }),
  )
}

fn owner(state: State, key: Key) -> Option(String) {
  case key {
    JobId(id) -> dict.get(state.jobs, id) |> option.from_result
    HttpCorrelation(Some(id)) -> Some(correlation.to_string(id))
    HttpCorrelation(None) -> None
    EmitterPid(pid) -> dict.get(state.processes, pid) |> option.from_result
  }
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

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Observed(record) ->
      actor.continue(State(..state, records: [record, ..state.records]))
    JobSubmitted(job_id, document_id) ->
      actor.continue(
        State(..state, jobs: dict.insert(state.jobs, job_id, document_id)),
      )
    WorkerProcess(pid, document_id) ->
      actor.continue(
        State(
          ..state,
          processes: dict.insert(state.processes, pid, document_id),
        ),
      )
    Snapshot(reply) -> {
      process.send(reply, State(..state, records: list.reverse(state.records)))
      actor.continue(state)
    }
  }
}

fn state(state: job.State) -> String {
  string.lowercase(string.inspect(state))
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
