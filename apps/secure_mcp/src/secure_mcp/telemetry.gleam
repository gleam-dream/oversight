//// Sinal subscriptions for every package the app uses, plus one app event
//// that bridges the id Relay does not share.
////
//// Correlation of one `/mcp` request across packages:
//// - app `[secure_mcp, mcp, request]`: correlation, Relay exchange_id, subject
////   (the app chose the exchange id, so it can join Relay's events);
//// - relay `[relay, request, admitted]` / `[relay, invocation, *]`:
////   exchange_id -> invocation_id; `tool_name` carries the JSON-RPC method;
//// - warden `[warden, http, request]`: no request or token id at all; it is
////   emitted synchronously in the wisp request process, so only the emitting
////   pid links it to the request;
//// - grind `[grind, job, admitted | claimed | acknowledged]`: the request's
////   correlation, because the tool submits its job with
////   `job.with_correlation`; no bridge event is needed.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import grind/job
import grind/telemetry as grind_telemetry
import relay/telemetry as relay_telemetry
import sinal
import sinal/correlation.{type Correlation}
import sinal/fields
import sinal/forwarder
import warden/observation as warden_observation

pub type McpRequest {
  McpRequest(correlation: Correlation, exchange_id: Int, subject: String)
}

pub fn mcp_request_event() -> sinal.Event(Nil, McpRequest) {
  sinal.event(["secure_mcp", "mcp", "request"], fields.empty(), {
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
      m.correlation
    })
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    use subject <- fields.include(fields.string("subject"), get: fn(m) {
      m.subject
    })
    fields.success(McpRequest(correlation:, exchange_id:, subject:))
  })
}

pub fn mcp_request(
  correlation: Correlation,
  exchange_id: Int,
  subject: String,
) -> Nil {
  sinal.emit(
    mcp_request_event(),
    Nil,
    McpRequest(correlation:, exchange_id:, subject:),
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
    sinal.observe(grind_telemetry.admitted(), fn(_, m) {
      record(
        "grind",
        "job.admitted",
        "job="
          <> int.to_string(m.ref.job_id)
          <> " queue="
          <> m.ref.queue
          <> " correlation="
          <> correlation.to_string(m.ref.correlation),
      )
    }),
    sinal.observe(grind_telemetry.claimed(), fn(_, m) {
      record(
        "grind",
        "job.claimed",
        "job="
          <> int.to_string(m.ref.job_id)
          <> " attempt="
          <> int.to_string(m.attempt.attempt)
          <> " correlation="
          <> correlation.to_string(m.ref.correlation),
      )
    }),
    sinal.observe(grind_telemetry.acknowledged(), fn(_, m) {
      record(
        "grind",
        "job.acknowledged",
        "job="
          <> int.to_string(m.ref.job_id)
          <> " state="
          <> job.state_name(m.committed_state)
          <> " correlation="
          <> correlation.to_string(m.ref.correlation),
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
          <> correlation.to_string(m.correlation)
          <> " exchange="
          <> int.to_string(m.exchange_id)
          <> " subject="
          <> m.subject,
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
