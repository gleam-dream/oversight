//// Collects the Sinal events of every package in the app and joins them per
//// delivery.
////
//// The app's own event and every http_gun event carry the delivery id as the
//// shared Sinal `correlation` key: the worker passes the delivery's
//// `Correlation` to http_gun. grind does not carry a correlation yet: its
//// events carry `job_id`, and the delivery worker does not learn its job id.
//// The collector therefore keeps one join table the app fills in by hand:
//// job id -> delivery id (at submit time).

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/string
import grind/diagnostic
import grind/observation
import http_gun/telemetry as http_telemetry
import sinal
import sinal/correlation.{type Correlation}
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
    /// The delivery id, as the shared `correlation` key; `None` when the id
    /// is longer than `correlation.max_bytes`.
    correlation: Option(Correlation),
    tenant: String,
    outcome: Outcome,
    status: Option(Int),
  )
}

/// What one attempt decided, without the decision's payload.
pub type Outcome {
  Delivered
  Retried
  Snoozed
  Gone
  Refused
  Rejected
}

/// `[webhooks, delivery, attempted]`, emitted synchronously by the worker.
pub fn delivery_attempted() -> sinal.Event(AttemptMeasurements, AttemptMetadata) {
  let measurements = {
    use duration_ms <- fields.include(fields.int("duration_ms"), get: fn(m) {
      m.duration_ms
    })
    fields.success(AttemptMeasurements(duration_ms:))
  }
  let metadata = {
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use tenant <- fields.include(fields.string("tenant"), get: fn(m) {
      m.tenant
    })
    use outcome <- fields.include(
      fields.enum(
        "outcome",
        [Delivered, Retried, Snoozed, Gone, Refused, Rejected],
        outcome_name,
      ),
      get: fn(m) { m.outcome },
    )
    use status <- fields.include(
      fields.optional(fields.int("status")),
      get: fn(m) { m.status },
    )
    fields.success(AttemptMetadata(correlation:, tenant:, outcome:, status:))
  }
  sinal.event(["webhooks", "delivery", "attempted"], measurements, metadata)
}

pub fn outcome_name(outcome: Outcome) -> String {
  case outcome {
    Delivered -> "delivered"
    Retried -> "retry"
    Snoozed -> "snooze"
    Gone -> "gone"
    Refused -> "refused"
    Rejected -> "reject"
  }
}

/// The delivery's correlation: its id, when the id fits.
pub fn delivery_correlation(delivery_id: String) -> Option(Correlation) {
  correlation.from_string(delivery_id) |> option.from_result
}

// ---------------------------------------------------------------------------
// Collector
// ---------------------------------------------------------------------------

pub type Key {
  Job(Int)
  Correlated(Correlation)
  Unkeyed
}

pub type Line {
  Line(seq: Int, source: String, name: String, key: Key, detail: String)
}

pub opaque type Collector {
  Collector(subject: Subject(Message))
}

pub opaque type Message {
  Record(source: String, name: String, key: Key, detail: String)
  NoteJob(job_id: Int, delivery_id: String)
  Snapshot(reply: Subject(State))
}

pub opaque type State {
  State(seq: Int, lines: List(Line), jobs: Dict(Int, String))
}

pub fn start() -> Collector {
  let assert Ok(started) =
    actor.new(State(0, [], dict.new()))
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
        Snapshot(reply) -> {
          process.send(reply, state)
          actor.continue(state)
        }
      }
    })
    |> actor.start
  Collector(started.data)
}

pub fn note_job(collector: Collector, job_id: Int, delivery_id: String) -> Nil {
  process.send(collector.subject, NoteJob(job_id, delivery_id))
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
      Correlated(c) -> correlation.to_string(c) == delivery_id
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
    // http_gun lifecycle, keyed by the delivery's correlation
    watch(c, http_telemetry.event(), "http_gun.lifecycle", fn(_, m) {
      #(
        keyed(m.correlation),
        milestone(m.milestone) <> " mode=" <> string.inspect(m.mode),
      )
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
        keyed(m.correlation),
        outcome_name(m.outcome)
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
  sinal.observe(event, fn(m, d) {
    let #(key, detail) = describe(m, d)
    process.send(collector.subject, Record(source, name, key, detail))
  })
}

fn keyed(correlation: Option(Correlation)) -> Key {
  option.map(correlation, Correlated) |> option.unwrap(Unkeyed)
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
