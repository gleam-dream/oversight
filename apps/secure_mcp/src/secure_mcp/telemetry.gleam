//// Sinal subscriptions for every package the app uses, plus two app events
//// that bridge the ids the packages do not share.
////
//// Correlation of one `/mcp` request across packages:
//// - app `[secure_mcp, mcp, request]`: request_id, Relay exchange_id, subject
////   (the app chose the exchange id, so it can join Relay's events);
//// - relay `[relay, request, admitted]` / `[relay, invocation, *]`:
////   exchange_id -> invocation_id; `tool_name` carries the JSON-RPC method;
//// - warden `[warden, http, request]`: no request or token id at all; it is
////   emitted synchronously in the wisp request process, so only the emitting
////   pid links it to the request;
//// - app `[secure_mcp, report, submitted]`: request_id -> job_id (Relay's
////   handler context carries neither exchange nor invocation id);
//// - grind `[grind, job, admitted | claimed | acknowledged]`: job_id.

import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import grind/job
import grind/observation as grind_observation
import relay/telemetry as relay_telemetry
import sinal
import sinal/fields
import sinal/forwarder
import warden/observation as warden_observation

pub type McpRequest {
  McpRequest(request_id: Int, exchange_id: Int, subject: String)
}

pub type ReportSubmitted {
  ReportSubmitted(request_id: Int, job_id: Int)
}

pub fn mcp_request_event() -> sinal.Event(Nil, McpRequest) {
  let assert Ok(head) =
    fields.pair(
      fields.int(atom.create("request_id")),
      fields.int(atom.create("exchange_id")),
    )
  let assert Ok(all) = fields.pair(head, fields.string(atom.create("subject")))
  let metadata =
    fields.imap(
      all,
      fn(t) {
        let #(#(request_id, exchange_id), subject) = t
        McpRequest(request_id:, exchange_id:, subject:)
      },
      fn(r) { #(#(r.request_id, r.exchange_id), r.subject) },
    )
  let assert Ok(event) =
    sinal.event(
      [atom.create("secure_mcp"), atom.create("mcp"), atom.create("request")],
      fields.empty(),
      metadata,
    )
  event
}

pub fn report_submitted_event() -> sinal.Event(Nil, ReportSubmitted) {
  let assert Ok(pair) =
    fields.pair(
      fields.int(atom.create("request_id")),
      fields.int(atom.create("job_id")),
    )
  let assert Ok(event) =
    sinal.event(
      [
        atom.create("secure_mcp"),
        atom.create("report"),
        atom.create("submitted"),
      ],
      fields.empty(),
      fields.imap(pair, fn(p) { ReportSubmitted(p.0, p.1) }, fn(r) {
        #(r.request_id, r.job_id)
      }),
    )
  event
}

pub fn mcp_request(request_id: Int, exchange_id: Int, subject: String) -> Nil {
  let _ =
    sinal.emit(
      mcp_request_event(),
      Nil,
      McpRequest(request_id:, exchange_id:, subject:),
    )
  Nil
}

pub fn report_submitted(request_id: Int, job_id: Int) -> Nil {
  let _ =
    sinal.emit(
      report_submitted_event(),
      Nil,
      ReportSubmitted(request_id:, job_id:),
    )
  Nil
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
  let attachments =
    [
      observe(
        "relay.admitted",
        relay_telemetry.request_admitted_event(),
        fn(_, m) {
          record(
            "relay",
            "request.admitted",
            "exchange="
              <> int.to_string(m.exchange_id)
              <> " method="
              <> m.method,
          )
        },
      ),
      observe(
        "relay.started",
        relay_telemetry.invocation_started_event(),
        fn(_, m) {
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
        },
      ),
      observe(
        "relay.completed",
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
      observe(
        "relay.rejected",
        relay_telemetry.frame_rejected_event(),
        fn(_, m) {
          record(
            "relay",
            "frame.rejected",
            "exchange="
              <> int.to_string(m.exchange_id)
              <> " reason="
              <> m.reason,
          )
        },
      ),
      observe(
        "relay.crashed",
        relay_telemetry.invocation_crashed_event(),
        fn(_, m) {
          record(
            "relay",
            "invocation.crashed",
            "invocation=" <> int.to_string(m.invocation_id),
          )
        },
      ),
      observe("warden.http", warden_observation.http_request(), fn(measure, r) {
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
      observe("grind.admitted", grind_observation.admitted(), fn(_, m) {
        record(
          "grind",
          "job.admitted",
          "job=" <> int.to_string(m.ref.job_id) <> " queue=" <> m.ref.queue,
        )
      }),
      observe("grind.claimed", grind_observation.claimed(), fn(_, m) {
        record(
          "grind",
          "job.claimed",
          "job="
            <> int.to_string(m.ref.job_id)
            <> " attempt="
            <> int.to_string(m.attempt.attempt),
        )
      }),
      observe("grind.acknowledged", grind_observation.acknowledged(), fn(_, m) {
        record(
          "grind",
          "job.acknowledged",
          "job="
            <> int.to_string(m.ref.job_id)
            <> " state="
            <> state_label(m.committed_state),
        )
      }),
      observe("sinal.dropped", forwarder.dropped_event(), fn(d, m) {
        record(
          "sinal",
          "forwarder.dropped",
          m.forwarder <> " rejected=" <> int.to_string(d.rejected),
        )
      }),
      observe("app.mcp", mcp_request_event(), fn(_, m) {
        record(
          "app",
          "mcp.request",
          "request="
            <> int.to_string(m.request_id)
            <> " exchange="
            <> int.to_string(m.exchange_id)
            <> " subject="
            <> m.subject,
        )
      }),
      observe("app.report", report_submitted_event(), fn(_, m) {
        record(
          "app",
          "report.submitted",
          "request="
            <> int.to_string(m.request_id)
            <> " job="
            <> int.to_string(m.job_id),
        )
      }),
    ]
    |> result.values
  Ok(Collector(subject, attachments))
}

fn observe(
  name: String,
  event: sinal.Event(m, d),
  handler: fn(m, d) -> Nil,
) -> Result(sinal.Attachment, Nil) {
  let assert Ok(id) =
    sinal.handler_id(
      "secure_mcp." <> name <> "." <> int.to_string(unique_integer()),
    )
  sinal.observe(id, event, handler) |> result.replace_error(Nil)
}

@external(erlang, "secure_mcp_dev_ffi", "unique")
fn unique_integer() -> Int

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
