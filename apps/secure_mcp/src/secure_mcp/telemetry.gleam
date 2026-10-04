//// Sinal subscriptions for every package the app uses.
////
//// Correlation of one `/mcp` request across packages, with no app event:
//// - relay `[relay, authorization, decided]`, `[relay, request, admitted]`
////   and `[relay, invocation, *]` carry the request's correlation: the app's
////   `x-request-id`, else the Relay client's `x-correlation-id`, else a fresh
////   value;
//// - grind `[grind, job, admitted | claimed | acknowledged]` carry the same
////   correlation, because the tool submits its job with
////   `job.with_correlation(tool.correlation(call))`;
//// - warden `[warden, http, request]` carries the request's correlation in
////   introspection mode (the verifier applies `warden.with_correlation`);
////   local JWT validation sends no request per token at all.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import grind/job
import grind/telemetry as grind_telemetry
import relay/telemetry as relay_telemetry
import sinal
import sinal/correlation.{type Correlation}
import sinal/forwarder
import warden/telemetry as warden_telemetry

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
    sinal.observe(relay_telemetry.authorization_decided_event(), fn(_, m) {
      record(
        "relay",
        "authorization.decided",
        "verifier="
          <> m.verifier
          <> " decision="
          <> string.inspect(m.decision)
          <> " correlation="
          <> correlation.to_string(m.correlation),
      )
    }),
    sinal.observe(relay_telemetry.http_rejected_event(), fn(_, m) {
      record(
        "relay",
        "http.rejected",
        "status="
          <> int.to_string(m.status)
          <> " reason="
          <> string.inspect(m.reason)
          <> " correlation="
          <> correlation.to_string(m.correlation),
      )
    }),
    sinal.observe(relay_telemetry.request_admitted_event(), fn(_, m) {
      record(
        "relay",
        "request.admitted",
        "exchange="
          <> int.to_string(m.exchange_id)
          <> " method="
          <> m.method
          <> " correlation="
          <> correlation.to_string(m.correlation),
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
          <> " tool="
          <> option.unwrap(m.tool, "-")
          <> " correlation="
          <> correlation.to_string(m.correlation),
      )
    }),
    sinal.observe(
      relay_telemetry.invocation_completed_event(),
      fn(measurements, m) {
        record(
          "relay",
          "invocation.completed",
          "invocation="
            <> int.to_string(m.invocation_id)
            <> " status="
            <> string.inspect(m.status)
            <> " duration_ms="
            <> int.to_string(measurements.duration_ms)
            <> " correlation="
            <> correlation.to_string(m.correlation),
        )
      },
    ),
    sinal.observe(relay_telemetry.exchange_closed_event(), fn(_, m) {
      record(
        "relay",
        "exchange.closed",
        "exchange="
          <> int.to_string(m.exchange_id)
          <> " correlation="
          <> correlation.to_string(m.correlation),
      )
    }),
    sinal.observe(relay_telemetry.client_call_event(), fn(_, m) {
      record(
        "relay",
        "client.call",
        "method="
          <> m.method
          <> " outcome="
          <> string.inspect(m.outcome)
          <> " correlation="
          <> correlation.to_string(m.correlation),
      )
    }),
    sinal.observe(relay_telemetry.frame_rejected_event(), fn(_, m) {
      record(
        "relay",
        "frame.rejected",
        "exchange="
          <> int.to_string(m.exchange_id)
          <> " problem="
          <> string.inspect(m.problem),
      )
    }),
    sinal.observe(relay_telemetry.invocation_crashed_event(), fn(_, m) {
      record(
        "relay",
        "invocation.crashed",
        "invocation="
          <> int.to_string(m.invocation_id)
          <> " reason="
          <> string.inspect(m.reason)
          <> " correlation="
          <> correlation.to_string(m.correlation),
      )
    }),
    sinal.observe(warden_telemetry.http_request(), fn(measure, r) {
      let outcome = case r.outcome {
        warden_telemetry.Status(code) -> int.to_string(code)
        warden_telemetry.Failed(evidence:, reason:) ->
          "failed "
          <> string.inspect(evidence)
          <> " "
          <> warden_telemetry.transport_reason_name(reason)
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
          <> " ms) correlation="
          <> optional(r.correlation),
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
  ]
  Ok(Collector(subject, attachments))
}

pub fn lines(collector: Collector) -> List(Line) {
  process.call(collector.subject, 1000, Lines)
}

pub fn stop(collector: Collector) -> Nil {
  list.each(collector.attachments, sinal.detach)
}

fn optional(value: Option(Correlation)) -> String {
  option.map(value, correlation.to_string) |> option.unwrap("-")
}

pub fn format(line: Line) -> String {
  "  [" <> line.package <> "] " <> line.event <> " " <> line.detail
}
