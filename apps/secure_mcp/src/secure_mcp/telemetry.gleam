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
//// - hellhound `[hellhound, http, request]` carries the request's correlation in
////   introspection mode (the verifier applies `hellhound.with_correlation`);
////   local JWT validation sends no request per token at all.

import gleam/erlang/process
import gleam/int
import gleam/option.{type Option}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import grind/job
import grind/telemetry as grind_telemetry
import hellhound/telemetry as hellhound_telemetry
import relay/telemetry as relay_telemetry
import sinal/collector
import sinal/correlation.{type Correlation}
import sinal/forwarder

// --- Collection --------------------------------------------------------------

pub type Line {
  Line(package: String, event: String, detail: String, pid: String)
}

/// How many lines the collector keeps; older lines are overwritten.
pub const capacity = 4096

/// A supervised `sinal/collector` over every package's events. Its process
/// attaches the handlers and owns them, so they are attached exactly while
/// it runs.
pub opaque type Collector {
  Collector(recent: collector.Collector(Line), supervisor: process.Pid)
}

/// Starts the collector under a supervisor of its own.
pub fn start() -> Result(Collector, String) {
  let recent =
    collector.new(process.new_name("secure_mcp_telemetry"))
    |> collector.with_capacity(capacity)
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(collector.supervised(recent, sources()))
  |> supervisor.start
  |> result.map(fn(started) { Collector(recent:, supervisor: started.pid) })
  |> result.replace_error("telemetry collector failed to start")
}

fn sources() -> List(collector.Source(Line)) {
  // Each line names the process its handler ran in: the emitter, or the
  // forwarder for a routed event.
  let record = fn(package, event, detail) {
    Line(package, event, detail, string.inspect(process.self()))
  }
  [
    collector.source(relay_telemetry.authorization_decided_event(), fn(_, m) {
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
    collector.source(relay_telemetry.http_rejected_event(), fn(_, m) {
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
    collector.source(relay_telemetry.request_admitted_event(), fn(_, m) {
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
    collector.source(relay_telemetry.invocation_started_event(), fn(_, m) {
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
    collector.source(
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
    collector.source(relay_telemetry.exchange_closed_event(), fn(_, m) {
      record(
        "relay",
        "exchange.closed",
        "exchange="
          <> int.to_string(m.exchange_id)
          <> " correlation="
          <> correlation.to_string(m.correlation),
      )
    }),
    collector.source(relay_telemetry.client_call_event(), fn(_, m) {
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
    collector.source(relay_telemetry.frame_rejected_event(), fn(_, m) {
      record(
        "relay",
        "frame.rejected",
        "exchange="
          <> int.to_string(m.exchange_id)
          <> " problem="
          <> string.inspect(m.problem),
      )
    }),
    collector.source(relay_telemetry.invocation_crashed_event(), fn(_, m) {
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
    collector.source(hellhound_telemetry.http_request(), fn(measure, r) {
      let outcome = case r.outcome {
        hellhound_telemetry.Status(code) -> int.to_string(code)
        hellhound_telemetry.Failed(evidence:, reason:) ->
          "failed "
          <> string.inspect(evidence)
          <> " "
          <> hellhound_telemetry.transport_reason_name(reason)
      }
      record(
        "hellhound",
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
    collector.source(grind_telemetry.admitted(), fn(_, m) {
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
    collector.source(grind_telemetry.claimed(), fn(_, m) {
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
    collector.source(grind_telemetry.acknowledged(), fn(_, m) {
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
    collector.source(forwarder.dropped_event(), fn(d, m) {
      record(
        "sinal",
        "forwarder.dropped",
        m.forwarder <> " rejected=" <> int.to_string(d.rejected),
      )
    }),
  ]
}

/// The lines the collector holds, oldest first: at most `capacity`. Empty
/// once it has stopped.
pub fn lines(telemetry: Collector) -> List(Line) {
  collector.entries(telemetry.recent)
}

/// Stops the collector and waits for it. Sinal detaches the handlers its
/// process owned.
pub fn stop(telemetry: Collector) -> Nil {
  shutdown(telemetry.supervisor)
}

@external(erlang, "secure_mcp_ffi", "shutdown")
fn shutdown(pid: process.Pid) -> Nil

fn optional(value: Option(Correlation)) -> String {
  option.map(value, correlation.to_string) |> option.unwrap("-")
}

pub fn format(line: Line) -> String {
  "  [" <> line.package <> "] " <> line.event <> " " <> line.detail
}
