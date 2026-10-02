//// Collects the Sinal events of every package in the app and joins them per
//// delivery.
////
//// No shared key crosses the packages: grind events carry `job_id`, http_gun
//// events carry an opaque `request_id` and an optional opaque correlation
//// `Id`, and the delivery worker learns neither its job id nor anything it
//// can put into http_gun's correlation. The collector therefore keeps two
//// join tables the app fills in by hand: job id -> delivery id (at submit
//// time) and http correlation Id -> delivery id (inside the worker).

import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import grind/diagnostic
import grind/observation
import http_gun/telemetry as http_telemetry
import sinal
import sinal/fields
import sinal/forwarder

// ---------------------------------------------------------------------------
// The app's own event
// ---------------------------------------------------------------------------

pub type AttemptMeasurements {
  AttemptMeasurements(duration_ms: Int)
}

pub type AttemptMetadata {
  AttemptMetadata(
    delivery_id: String,
    tenant: String,
    disposition: String,
    status: Option(Int),
  )
}

/// `[webhooks, delivery, attempted]`, emitted synchronously by the worker.
pub fn delivery_attempted() -> sinal.Event(AttemptMeasurements, AttemptMetadata) {
  let measurements =
    fields.imap(
      fields.int(atom.create("duration_ms")),
      AttemptMeasurements,
      fn(m) { m.duration_ms },
    )
  let assert Ok(status) = fields.optional(fields.int(atom.create("status")))
  let assert Ok(left) =
    fields.pair(
      fields.string(atom.create("delivery_id")),
      fields.string(atom.create("tenant")),
    )
  let assert Ok(right) =
    fields.pair(fields.string(atom.create("disposition")), status)
  let assert Ok(all) = fields.pair(left, right)
  let metadata =
    fields.imap(
      all,
      fn(v) { AttemptMetadata(v.0.0, v.0.1, v.1.0, v.1.1) },
      fn(m) { #(#(m.delivery_id, m.tenant), #(m.disposition, m.status)) },
    )
  let assert Ok(event) =
    sinal.event(
      [
        atom.create("webhooks"),
        atom.create("delivery"),
        atom.create("attempted"),
      ],
      measurements,
      metadata,
    )
  event
}

// ---------------------------------------------------------------------------
// Collector
// ---------------------------------------------------------------------------

pub type Key {
  Job(Int)
  Http(http_telemetry.Id)
  Delivery(String)
  Unkeyed
}

pub type Line {
  Line(seq: Int, source: String, name: String, key: Key, detail: String)
}

pub opaque type Collector {
  Collector(subject: Subject(Message), suffix: String)
}

pub opaque type Message {
  Record(source: String, name: String, key: Key, detail: String)
  NoteJob(job_id: Int, delivery_id: String)
  NoteHttp(id: http_telemetry.Id, delivery_id: String)
  Snapshot(reply: Subject(State))
}

pub opaque type State {
  State(
    seq: Int,
    lines: List(Line),
    jobs: Dict(Int, String),
    https: Dict(http_telemetry.Id, String),
  )
}

pub fn start() -> Collector {
  let assert Ok(started) =
    actor.new(State(0, [], dict.new(), dict.new()))
    |> actor.on_message(fn(state: State, message) {
      case message {
        Record(source, name, key, detail) ->
          actor.continue(
            State(..state, seq: state.seq + 1, lines: [
              Line(state.seq + 1, source, name, key, detail),
              ..state.lines
            ]),
          )
        NoteJob(job, delivery) ->
          actor.continue(
            State(..state, jobs: dict.insert(state.jobs, job, delivery)),
          )
        NoteHttp(id, delivery) ->
          actor.continue(
            State(..state, https: dict.insert(state.https, id, delivery)),
          )
        Snapshot(reply) -> {
          process.send(reply, state)
          actor.continue(state)
        }
      }
    })
    |> actor.start
  Collector(started.data, int.to_string(unique_int()))
}

pub fn note_job(collector: Collector, job_id: Int, delivery_id: String) -> Nil {
  process.send(collector.subject, NoteJob(job_id, delivery_id))
}

pub fn note_http(
  collector: Collector,
  id: http_telemetry.Id,
  delivery_id: String,
) -> Nil {
  process.send(collector.subject, NoteHttp(id, delivery_id))
}

pub fn lines(collector: Collector) -> List(Line) {
  let state = process.call(collector.subject, 1000, Snapshot)
  list.reverse(state.lines)
}

/// Lines that can be attributed to one delivery, in arrival order.
pub fn trace(collector: Collector, delivery_id: String) -> List(Line) {
  let state = process.call(collector.subject, 1000, Snapshot)
  state.lines
  |> list.reverse
  |> list.filter(fn(line) {
    case line.key {
      Job(job) -> dict.get(state.jobs, job) == Ok(delivery_id)
      Http(id) -> dict.get(state.https, id) == Ok(delivery_id)
      Delivery(d) -> d == delivery_id
      Unkeyed -> False
    }
  })
}

pub fn format(line: Line) -> String {
  string.pad_end(line.source, 9, " ")
  <> string.pad_end(line.name, 30, " ")
  <> line.detail
}

/// Attach to every event of grind, http_gun, sinal and the app. Handlers run
/// in the emitting process (sync events) or the producer's forwarder.
pub fn attach(collector: Collector) -> List(sinal.Attachment) {
  let c = collector
  [
    // grind lifecycle, keyed by job id
    watch(c, observation.admitted(), "grind.job.admitted", fn(_, m) {
      #(Job(m.ref.job_id), "state=" <> string.inspect(m.committed_state))
    }),
    watch(c, observation.claimed(), "grind.job.claimed", fn(_, m) {
      #(Job(m.ref.job_id), "attempt=" <> int.to_string(m.attempt.attempt))
    }),
    watch(c, observation.acknowledged(), "grind.job.acknowledged", fn(_, m) {
      #(
        Job(m.ref.job_id),
        "attempt="
          <> int.to_string(m.attempt.attempt)
          <> " proposed="
          <> string.inspect(m.proposed)
          <> " committed="
          <> string.inspect(m.committed_state),
      )
    }),
    watch(c, observation.quarantined(), "grind.job.quarantined", fn(_, m) {
      #(Job(m.ref.job_id), "")
    }),
    watch(c, observation.resolved(), "grind.job.resolved", fn(_, m) {
      #(Job(m.ref.job_id), "")
    }),
    watch(
      c,
      observation.cancellation_decided(),
      "grind.job.cancellation",
      fn(_, m) { #(Job(m.ref.job_id), "") },
    ),
    watch(c, observation.released(), "grind.job.released", fn(_, m) {
      #(Job(m.ref.job_id), "")
    }),
    watch(
      c,
      observation.contract_mismatch_recorded(),
      "grind.job.contract_mismatch",
      fn(_, m) { #(Job(m.ref.job_id), "") },
    ),
    watch(c, observation.prune_completed(), "grind.prune.completed", fn(_, _) {
      #(Unkeyed, "")
    }),
    watch(c, observation.prune_failed(), "grind.prune.failed", fn(_, _) {
      #(Unkeyed, "")
    }),
    // grind diagnostics: operational, not per delivery
    watch(c, diagnostic.renewal(), "grind.diag.renewal", fn(_, m) {
      #(Job(m.context.ref.job_id), "lease renewed")
    }),
    watch(c, diagnostic.acknowledgement(), "grind.diag.ack", fn(_, _) {
      #(Unkeyed, "")
    }),
    watch(
      c,
      diagnostic.acknowledgement_retry(),
      "grind.diag.ack_retry",
      fn(_, _) { #(Unkeyed, "") },
    ),
    watch(c, diagnostic.checkout(), "grind.diag.checkout", fn(_, _) {
      #(Unkeyed, "")
    }),
    watch(c, diagnostic.claim_failed(), "grind.diag.claim_failed", fn(_, _) {
      #(Unkeyed, "")
    }),
    watch(c, diagnostic.capacity(), "grind.diag.capacity", fn(_, _) {
      #(Unkeyed, "")
    }),
    // http_gun lifecycle, keyed by the correlation Id when one was set
    watch(c, http_telemetry.event(), "http_gun.lifecycle", fn(_, m) {
      let key = case m.correlation {
        Some(id) -> Http(id)
        None -> Unkeyed
      }
      #(key, milestone(m.milestone) <> " mode=" <> string.inspect(m.mode))
    }),
    // sinal's own drop accounting
    watch(c, forwarder.dropped_event(), "sinal.forwarder.dropped", fn(d, m) {
      #(
        Unkeyed,
        m.forwarder
          <> " rejected="
          <> int.to_string(d.rejected)
          <> " lost="
          <> int.to_string(d.lost),
      )
    }),
    // the app's own attempt event
    watch(c, delivery_attempted(), "webhooks.delivery.attempted", fn(ms, m) {
      #(
        Delivery(m.delivery_id),
        m.disposition
          <> " status="
          <> option.map(m.status, int.to_string) |> option.unwrap("-")
          <> " in "
          <> int.to_string(ms.duration_ms)
          <> "ms",
      )
    }),
  ]
}

pub fn detach(attachments: List(sinal.Attachment)) -> Nil {
  list.each(attachments, fn(a) {
    let _ = sinal.detach(a)
    Nil
  })
}

fn watch(
  collector: Collector,
  event: sinal.Event(m, d),
  name: String,
  describe: fn(m, d) -> #(Key, String),
) -> sinal.Attachment {
  let source = case string.split_once(name, ".") {
    Ok(#(head, _)) -> head
    Error(Nil) -> name
  }
  let assert Ok(id) =
    sinal.handler_id("webhooks-" <> collector.suffix <> "-" <> name)
  let assert Ok(attachment) =
    sinal.observe(id, event, fn(m, d) {
      let #(key, detail) = describe(m, d)
      process.send(collector.subject, Record(source, name, key, detail))
    })
  attachment
}

fn milestone(m: http_telemetry.Milestone) -> String {
  case m {
    http_telemetry.AdmissionEntered -> "admission_entered"
    http_telemetry.AdmissionWaiting -> "admission_waiting"
    http_telemetry.AdmissionGranted -> "admission_granted"
    http_telemetry.GunCallReturned -> "gun_call_returned"
    http_telemetry.ResponseHeaders(status) ->
      "response_headers status=" <> int.to_string(status)
    http_telemetry.HttpTerminated(outcome) ->
      "terminated " <> string.inspect(outcome)
  }
}

@external(erlang, "webhooks_ffi", "unique_int")
fn unique_int() -> Int
