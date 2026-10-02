//// Sinal subscriptions for every package the app uses, plus two app events
//// that bridge the ids the packages do not share.
////
//// Correlation of one `/mcp` request across packages:
//// - app `[secure_mcp, mcp, request]`: correlation, Relay exchange_id, subject
////   (the app chose the exchange id, so it can join Relay's events);
//// - relay `[relay, request, admitted]` / `[relay, invocation, *]`:
////   exchange_id -> invocation_id; `tool_name` carries the JSON-RPC method;
//// - warden `[warden, http, request]`: no request or token id at all; it is
////   emitted synchronously in the wisp request process, so only the emitting
////   pid links it to the request;
//// - app `[secure_mcp, report, submitted]`: correlation -> job_id (Relay's
////   handler context carries neither exchange nor invocation id);
//// - grind `[grind, job, admitted | claimed | acknowledged]`: job_id.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import grind/job
import grind/observation as grind_observation
import relay/telemetry as relay_telemetry
import sinal
import sinal/correlation.{type Correlation}
import sinal/fields
import sinal/forwarder
import warden/observation as warden_observation

pub type McpRequest {
  McpRequest(
    correlation: Option(Correlation),
    exchange_id: Int,
    subject: String,
  )
}

pub type ReportSubmitted {
  ReportSubmitted(correlation: Option(Correlation), job_id: Int)
}

pub fn mcp_request_event() -> sinal.Event(Nil, McpRequest) {
  sinal.event(
    ["secure_mcp", "mcp", "request"],
    fields.empty(),
    fields.record({
      use correlation <- fields.parameter
      use exchange_id <- fields.parameter
      use subject <- fields.parameter
      McpRequest(correlation:, exchange_id:, subject:)
    })
      |> fields.and(correlation.field(), fn(m: McpRequest) { m.correlation })
      |> fields.and(fields.int("exchange_id"), fn(m) { m.exchange_id })
      |> fields.and(fields.string("subject"), fn(m) { m.subject })
      |> fields.build,
  )
}

pub fn report_submitted_event() -> sinal.Event(Nil, ReportSubmitted) {
  sinal.event(
    ["secure_mcp", "report", "submitted"],
    fields.empty(),
    fields.record({
      use correlation <- fields.parameter
      use job_id <- fields.parameter
      ReportSubmitted(correlation:, job_id:)
    })
      |> fields.and(correlation.field(), fn(m: ReportSubmitted) {
        m.correlation
      })
      |> fields.and(fields.int("job_id"), fn(m) { m.job_id })
      |> fields.build,
  )
}

pub fn mcp_request(
  correlation: Correlation,
  exchange_id: Int,
  subject: String,
) -> Nil {
  sinal.emit(
    mcp_request_event(),
    Nil,
    McpRequest(correlation: option.Some(correlation), exchange_id:, subject:),
  )
}

pub fn report_submitted(correlation: Correlation, job_id: Int) -> Nil {
  sinal.emit(
    report_submitted_event(),
    Nil,
    ReportSubmitted(correlation: option.Some(correlation), job_id:),
  )
}

// --- Collection --------------------------------------------------------------

pub type Line {
  Line(package: String, event: String, detail: String, pid: String)
}

type Message {
  Record(Line)
  Lines(Subject(List(Line)))
}

pub opaque type Collector {
  Collector(subject: Subject(Message), attachments: List(sinal.Attachment))
}

/// Attaches to every package's events and collects them in order.
pub fn start() -> Result(Collector, String) {
  use started <- result.try(
    actor.new([])
    |> actor.on_message(fn(lines, message) {
      case message {
        Record(line) -> actor.continue([line, ..lines])
        Lines(reply) -> {
          process.send(reply, list.reverse(lines))
          actor.continue(lines)
        }
      }
    })
    |> actor.start
    |> result.replace_error("telemetry collector failed to start"),
  )
  let subject = started.data
  let record = fn(package, event, detail) {
    process.send(
      subject,
      Record(Line(package, event, detail, string.inspect(process.self()))),
    )
  }
  let attachments = [
    sinal.observe(relay_telemetry.request_admitted_event(), fn(_, m) {
      record(
        "relay",
        "request.admitted",
        "exchange=" <> int.to_string(m.exchange_id) <> " method=" <> m.method,
      )
    }),
    sinal.observe(relay_telemetry.invocation_started_event(), fn(_, m) {
      record(
        "relay",
        "invocation.started",
        "exchange="
          <> int.to_string(m.exchange_id)
          <> " invocation="
          <> int.to_string(m.invocation_id)
          <> " tool_name="
          <> m.tool_name,
      )
    }),
    sinal.observe(
      relay_telemetry.invocation_completed_event(),
      fn(measurements, m) {
        record(
          "relay",
          "invocation.completed",
          "exchange="
            <> int.to_string(m.exchange_id)
            <> " invocation="
            <> int.to_string(m.invocation_id)
            <> " status="
            <> m.status
            <> " duration_ms="
            <> int.to_string(measurements.duration_ms),
        )
      },
    ),
    sinal.observe(relay_telemetry.frame_rejected_event(), fn(_, m) {
      record(
        "relay",
        "frame.rejected",
        "exchange=" <> int.to_string(m.exchange_id) <> " reason=" <> m.reason,
      )
    }),
    sinal.observe(relay_telemetry.invocation_crashed_event(), fn(_, m) {
      record(
        "relay",
        "invocation.crashed",
        "invocation=" <> int.to_string(m.invocation_id),
      )
    }),
    sinal.observe(warden_observation.http_request(), fn(measure, r) {
      let outcome = case r.outcome {
        warden_observation.Status(code) -> int.to_string(code)
        warden_observation.Failed(sent, class) ->
          "failed sent=" <> string.inspect(sent) <> " class=" <> class
      }
      record(
        "warden",
        "http.request",
        string.lowercase(string.inspect(r.method))
          <> " "
          <> r.path
          <> " -> "
          <> outcome
          <> " ("
          <> int.to_string(measure.duration_ms)
          <> " ms)",
      )
    }),
    sinal.observe(grind_observation.admitted(), fn(_, m) {
      record(
        "grind",
        "job.admitted",
        "job=" <> int.to_string(m.ref.job_id) <> " queue=" <> m.ref.queue,
      )
    }),
    sinal.observe(grind_observation.claimed(), fn(_, m) {
      record(
        "grind",
        "job.claimed",
        "job="
          <> int.to_string(m.ref.job_id)
          <> " attempt="
          <> int.to_string(m.attempt.attempt),
      )
    }),
    sinal.observe(grind_observation.acknowledged(), fn(_, m) {
      record(
        "grind",
        "job.acknowledged",
        "job="
          <> int.to_string(m.ref.job_id)
          <> " state="
          <> state_label(m.committed_state),
      )
    }),
    sinal.observe(forwarder.dropped_event(), fn(d, m) {
      record(
        "sinal",
        "forwarder.dropped",
        m.forwarder <> " rejected=" <> int.to_string(d.rejected),
      )
    }),
    sinal.observe(mcp_request_event(), fn(_, m) {
      record(
        "app",
        "mcp.request",
        "correlation="
          <> correlation_text(m.correlation)
          <> " exchange="
          <> int.to_string(m.exchange_id)
          <> " subject="
          <> m.subject,
      )
    }),
    sinal.observe(report_submitted_event(), fn(_, m) {
      record(
        "app",
        "report.submitted",
        "correlation="
          <> correlation_text(m.correlation)
          <> " job="
          <> int.to_string(m.job_id),
      )
    }),
  ]
  Ok(Collector(subject, attachments))
}

pub fn lines(collector: Collector) -> List(Line) {
  process.call(collector.subject, 1000, Lines)
}

pub fn stop(collector: Collector) -> Nil {
  list.each(collector.attachments, sinal.detach)
}

pub fn format(line: Line) -> String {
  "  [" <> line.package <> "] " <> line.event <> " " <> line.detail
}

fn state_label(state: job.State) -> String {
  string.lowercase(string.inspect(state))
}

fn correlation_text(value: Option(Correlation)) -> String {
  option.map(value, correlation.to_string) |> option.unwrap("-")
}
