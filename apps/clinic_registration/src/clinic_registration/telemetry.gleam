//// The application's own Sinal events, and a collector that keeps them
//// with the events of `decisions_postgres` (wake-ups and settlement
//// notices delivered, records set aside), so a run can be read in order.
////
//// | Event | When |
//// | --- | --- |
//// | `[clinic, message, admitted]` | An inbound message was kept, or found kept before |
//// | `[clinic, registration, recommended]` | A recommendation committed, with the status the policy gave it |
//// | `[clinic, registration, attempt_failed]` | The model failed and the attempt is on the record |
//// | `[clinic, verdict, given]` | A validator's verdict or review committed, or was refused |
//// | `[clinic, confirmation, reported]` | The confirmation's effect was reported |
////
//// Each is emitted after the transaction it describes committed. They are
//// observations: the record is what is true.

import decisions_postgres/telemetry as store_telemetry
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import sinal.{type Event}
import sinal/collector
import sinal/fields

/// How many things the event counts; always 1.
pub type Count {
  Count(count: Int)
}

pub type Admitted {
  Admitted(message: String, contact: String, duplicate: Bool)
}

pub type Recommended {
  Recommended(occurrence: String, status: String, policy_version: Int)
}

pub type AttemptFailed {
  AttemptFailed(occurrence: String, failure: String, attempts: Int, retry: Bool)
}

pub type Verdict {
  Verdict(
    occurrence: String,
    validator: String,
    verdict: String,
    outcome: String,
  )
}

pub type Reported {
  Reported(occurrence: String, effect: String)
}

fn count() -> fields.Fields(Count) {
  use count <- fields.include(fields.int("count"), get: fn(c: Count) { c.count })
  fields.success(Count(count:))
}

pub fn admitted() -> Event(Count, Admitted) {
  sinal.event(["clinic", "message", "admitted"], count(), {
    use message <- fields.include(
      fields.string("message"),
      get: fn(a: Admitted) { a.message },
    )
    use contact <- fields.include(fields.string("contact"), get: fn(a) {
      a.contact
    })
    use duplicate <- fields.include(fields.bool("duplicate"), get: fn(a) {
      a.duplicate
    })
    fields.success(Admitted(message:, contact:, duplicate:))
  })
}

pub fn recommended() -> Event(Count, Recommended) {
  sinal.event(["clinic", "registration", "recommended"], count(), {
    use occurrence <- fields.include(
      fields.string("occurrence"),
      get: fn(r: Recommended) { r.occurrence },
    )
    use status <- fields.include(fields.string("status"), get: fn(r) {
      r.status
    })
    use policy_version <- fields.include(
      fields.int("policy_version"),
      get: fn(r) { r.policy_version },
    )
    fields.success(Recommended(occurrence:, status:, policy_version:))
  })
}

pub fn attempt_failed() -> Event(Count, AttemptFailed) {
  sinal.event(["clinic", "registration", "attempt_failed"], count(), {
    use occurrence <- fields.include(
      fields.string("occurrence"),
      get: fn(a: AttemptFailed) { a.occurrence },
    )
    use failure <- fields.include(fields.string("failure"), get: fn(a) {
      a.failure
    })
    use attempts <- fields.include(fields.int("attempts"), get: fn(a) {
      a.attempts
    })
    use retry <- fields.include(fields.bool("retry"), get: fn(a) { a.retry })
    fields.success(AttemptFailed(occurrence:, failure:, attempts:, retry:))
  })
}

pub fn verdict_given() -> Event(Count, Verdict) {
  sinal.event(["clinic", "verdict", "given"], count(), {
    use occurrence <- fields.include(
      fields.string("occurrence"),
      get: fn(v: Verdict) { v.occurrence },
    )
    use validator <- fields.include(fields.string("validator"), get: fn(v) {
      v.validator
    })
    use verdict <- fields.include(fields.string("verdict"), get: fn(v) {
      v.verdict
    })
    use outcome <- fields.include(fields.string("outcome"), get: fn(v) {
      v.outcome
    })
    fields.success(Verdict(occurrence:, validator:, verdict:, outcome:))
  })
}

pub fn effect_reported() -> Event(Count, Reported) {
  sinal.event(["clinic", "confirmation", "reported"], count(), {
    use occurrence <- fields.include(
      fields.string("occurrence"),
      get: fn(r: Reported) { r.occurrence },
    )
    use effect <- fields.include(fields.string("effect"), get: fn(r) {
      r.effect
    })
    fields.success(Reported(occurrence:, effect:))
  })
}

/// Emit one event, counting 1.
pub fn emit(event: Event(Count, metadata), metadata: metadata) -> Nil {
  sinal.emit(event, Count(1), metadata)
}

// -- The collector -------------------------------------------------------------

/// How many lines the collector keeps; older lines are overwritten.
pub const capacity = 4096

/// A supervised `sinal/collector` over every event above and the events of
/// `decisions_postgres`. Its process attaches the handlers and owns them,
/// so they are attached exactly while the application runs.
pub opaque type Collector {
  Collector(recent: collector.Collector(String), supervisor: process.Pid)
}

/// Start the collector under a supervisor of its own.
pub fn start() -> Result(Collector, String) {
  let recent =
    collector.new(process.new_name("clinic_telemetry"))
    |> collector.with_capacity(capacity)
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(collector.supervised(recent, sources()))
  |> supervisor.start
  |> result.map(fn(started) { Collector(recent:, supervisor: started.pid) })
  |> result.replace_error("the telemetry collector did not start")
}

fn sources() -> List(collector.Source(String)) {
  [
    collector.source(admitted(), fn(_, a) {
      "message "
      <> a.message
      <> " from "
      <> a.contact
      <> case a.duplicate {
        True -> " delivered again, nothing admitted"
        False -> " admitted"
      }
    }),
    collector.source(recommended(), fn(_, r) {
      "recommended "
      <> r.occurrence
      <> ": "
      <> r.status
      <> " under policy v"
      <> int.to_string(r.policy_version)
    }),
    collector.source(attempt_failed(), fn(_, a) {
      "attempt "
      <> int.to_string(a.attempts)
      <> " for "
      <> a.occurrence
      <> " failed: "
      <> a.failure
      <> case a.retry {
        True -> " (will retry)"
        False -> " (gave up)"
      }
    }),
    collector.source(verdict_given(), fn(_, v) {
      v.validator
      <> " "
      <> v.verdict
      <> " "
      <> v.occurrence
      <> ": "
      <> v.outcome
    }),
    collector.source(effect_reported(), fn(_, r) {
      "confirmation for " <> r.occurrence <> ": " <> r.effect
    }),
    collector.source(store_telemetry.wake_delivered(), fn(_, d) {
      "wake-up delivered for "
      <> d.occurrence
      <> " ("
      <> int.to_string(d.lag_ms)
      <> " ms late)"
    }),
    collector.source(store_telemetry.settlement_delivered(), fn(_, s) {
      "settlement notice delivered for " <> s.occurrence
    }),
    collector.source(store_telemetry.set_aside(), fn(_, s) {
      "set aside " <> s.occurrence <> ": " <> s.reason
    }),
  ]
}

/// The lines the collector holds, oldest first: at most `capacity`. Empty
/// once the collector has stopped.
pub fn lines(telemetry: Collector) -> List(String) {
  collector.entries(telemetry.recent)
}

/// The lines that mention `text`.
pub fn mentioning(telemetry: Collector, text: String) -> List(String) {
  lines(telemetry) |> list.filter(string.contains(_, text))
}

/// Stop the collector's supervisor and wait for it. Sinal detaches the
/// handlers the collector's process owned.
pub fn stop(telemetry: Collector) -> Nil {
  stop_supervisor(telemetry.supervisor)
}

@external(erlang, "clinic_registration_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil
