//// Collects the Sinal events of every package in the app and joins them per
//// delivery.
////
//// Each delivery job is submitted with `correlation.from_key(delivery_id)`.
//// grind stores it with the job and puts it in every job event and in the
//// handler's context; the worker passes it to http_gun and to the app's own
//// event. Every line is therefore keyed by the same `Correlation`, and lines
//// are ordered by the emitters' monotonic clock, not by arrival.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/order
import gleam/otp/actor
import gleam/string
import grind/telemetry as jobs
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
    /// The delivery's correlation (`correlation.from_key(delivery_id)`).
    correlation: Correlation,
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
    use correlation <- fields.include(correlation.required_field(), get: fn(m) {
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

// ---------------------------------------------------------------------------
// Collector
// ---------------------------------------------------------------------------

pub type Key {
  Correlated(Correlation)
  Unkeyed
}

pub type Line {
  /// `at` is the emitter's monotonic time where the event carries one, and
  /// the handler's otherwise.
  Line(
    seq: Int,
    at: Int,
    source: String,
    name: String,
    key: Key,
    detail: String,
  )
}

pub opaque type Collector {
  Collector(subject: Subject(Message))
}

pub opaque type Message {
  Record(at: Int, source: String, name: String, key: Key, detail: String)
  Snapshot(reply: Subject(List(Line)))
}

pub fn start() -> Collector {
  let assert Ok(started) =
    actor.new(#(0, []))
    |> actor.on_message(fn(state: #(Int, List(Line)), message) {
      let #(seq, lines) = state
      case message {
        Record(at, source, name, key, detail) ->
          actor.continue(
            #(seq + 1, [Line(seq + 1, at, source, name, key, detail), ..lines]),
          )
        Snapshot(reply) -> {
          process.send(reply, list.reverse(lines))
          actor.continue(state)
        }
      }
    })
    |> actor.start
  Collector(started.data)
}

pub fn lines(collector: Collector) -> List(Line) {
  process.call(collector.subject, 1000, Snapshot)
}

/// The lines of one delivery, in the order the emitters stamped them.
pub fn trace(collector: Collector, delivery_id: String) -> List(Line) {
  let key = Correlated(correlation.from_key(delivery_id))
  lines(collector)
  |> list.filter(fn(line) { line.key == key })
  |> list.sort(fn(a, b) {
    int.compare(a.at, b.at) |> order.break_tie(int.compare(a.seq, b.seq))
  })
}

pub fn format(line: Line) -> String {
  string.pad_end(line.source, 9, " ")
  <> string.pad_end(line.name, 30, " ")
  <> line.detail
}

/// Attach to every event of grind, http_gun, sinal and the app. Handlers run
/// in the emitting process (http_gun's pool and body processes, the worker)
/// or in grind's forwarder.
pub fn attach(collector: Collector) -> List(sinal.Attachment) {
  let c = collector
  [
    // grind lifecycle, keyed by the job's correlation
    watch_job(c, jobs.admitted(), "grind.job.admitted", fn(m) {
      #(m.ref, "state=" <> string.inspect(m.committed_state))
    }),
    watch_job(c, jobs.claimed(), "grind.job.claimed", fn(m) {
      #(m.ref, "attempt=" <> int.to_string(m.attempt.attempt))
    }),
    watch_job(c, jobs.acknowledged(), "grind.job.acknowledged", fn(m) {
      #(
        m.ref,
        "attempt="
          <> int.to_string(m.attempt.attempt)
          <> " proposed="
          <> string.inspect(m.proposed)
          <> " committed="
          <> string.inspect(m.committed_state),
      )
    }),
    watch_job(c, jobs.quarantined(), "grind.job.quarantined", fn(m) {
      #(m.ref, "replayed=" <> string.inspect(m.replayed))
    }),
    watch_job(c, jobs.resolved(), "grind.job.resolved", fn(m) { #(m.ref, "") }),
    watch_job(c, jobs.cancellation_decided(), "grind.job.cancellation", fn(m) {
      #(m.ref, "")
    }),
    watch_job(c, jobs.released(), "grind.job.released", fn(m) { #(m.ref, "") }),
    watch_job(
      c,
      jobs.contract_mismatch_recorded(),
      "grind.job.contract_mismatch",
      fn(m) { #(m.ref, "") },
    ),
    watch(c, jobs.prune_completed(), "grind.prune.completed", fn(_, _) {
      #(Unkeyed, "")
    }),
    watch(c, jobs.prune_failed(), "grind.prune.failed", fn(_, _) {
      #(Unkeyed, "")
    }),
    // grind diagnostics: operational; renewals name their job
    watch(c, jobs.renewal(), "grind.diag.renewal", fn(_, m) {
      #(Correlated(m.context.ref.correlation), "lease renewed")
    }),
    watch(c, jobs.acknowledgement(), "grind.diag.ack", fn(_, _) {
      #(Unkeyed, "")
    }),
    watch(c, jobs.acknowledgement_retry(), "grind.diag.ack_retry", fn(_, _) {
      #(Unkeyed, "")
    }),
    watch(c, jobs.checkout(), "grind.diag.checkout", fn(_, _) { #(Unkeyed, "") }),
    watch(c, jobs.claim_failed(), "grind.diag.claim_failed", fn(_, _) {
      #(Unkeyed, "")
    }),
    watch(c, jobs.capacity(), "grind.diag.capacity", fn(_, _) { #(Unkeyed, "") }),
    // http_gun lifecycle, keyed by the delivery's correlation
    watch(c, http_telemetry.event(), "http_gun.lifecycle", fn(_, m) {
      #(
        option.map(m.correlation, Correlated) |> option.unwrap(Unkeyed),
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
        Correlated(m.correlation),
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
  observe(collector, event, name, fn(m, d) {
    let #(key, detail) = describe(m, d)
    #(monotonic_ms(), key, detail)
  })
}

/// A grind job event: keyed by its job's correlation, stamped by grind.
fn watch_job(
  collector: Collector,
  event: sinal.Event(jobs.JobMeasurements, d),
  name: String,
  describe: fn(d) -> #(jobs.JobRef, String),
) -> sinal.Attachment {
  observe(collector, event, name, fn(m, d) {
    let #(ref, detail) = describe(d)
    #(m.monotonic_ms, Correlated(ref.correlation), detail)
  })
}

fn observe(
  collector: Collector,
  event: sinal.Event(m, d),
  name: String,
  describe: fn(m, d) -> #(Int, Key, String),
) -> sinal.Attachment {
  let source = case string.split_once(name, ".") {
    Ok(#(head, _)) -> head
    Error(Nil) -> name
  }
  sinal.observe_labelled(event, "webhooks.collector", fn(m, d) {
    let #(at, key, detail) = describe(m, d)
    process.send(collector.subject, Record(at, source, name, key, detail))
  })
}

@external(erlang, "webhooks_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

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
