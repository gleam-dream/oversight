//// Sinal subscriptions for every package in the portal, plus a collector
//// that follows one browser request across them.
////
//// - Hellhound emits `[hellhound, http, request]`, `[hellhound, login]`,
////   `[hellhound, refresh]` and `[hellhound, logout]` in the process that called
////   it, each carrying the `Correlation` of the `hellhound.with_correlation`
////   view that made the call.
//// - http_gun emits `[http_gun, lifecycle]` through a Sinal forwarder (a
////   different process), carrying the caller's optional `Correlation`; it
////   does so for the portal's billing calls and for Hellhound's provider calls.
//// - wisp, mist and pog emit nothing through Sinal.
////
//// A request makes one `Correlation` and hands it to Hellhound and to http_gun.
//// Nothing here maps processes to requests.

import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import hellhound/telemetry as hellhound_telemetry
import http_gun/telemetry as gun_telemetry
import sinal/collector
import sinal/correlation.{type Correlation}
import sinal/forwarder.{type Forwarder}

pub type Record {
  HellhoundHttp(
    correlation: Option(Correlation),
    method: String,
    path: String,
    outcome: String,
    duration_ms: Int,
  )
  /// `[hellhound, login]`, `[hellhound, refresh]` or `[hellhound, logout]`: the
  /// event name and its closed outcome.
  HellhoundSession(
    correlation: Option(Correlation),
    event: String,
    outcome: String,
  )
  GunLifecycle(correlation: Option(Correlation), milestone: String)
  ForwarderDropped(rejected: Int, lost: Int, unavailable: Int)
  /// The application began tracing a request (`begin_request`).
  RequestBegan(correlation: Correlation)
}

/// How many records the collector keeps; older records are overwritten.
pub const capacity = 4096

/// The http_gun forwarder and a `sinal/collector`, under one supervisor.
/// The collector's process attaches the handlers and owns them, so they
/// are attached exactly while it runs.
pub opaque type Telemetry {
  Telemetry(
    recent: collector.Collector(Record),
    forwarder: Forwarder,
    supervisor: Pid,
  )
}

/// Start the http_gun forwarder and the collector, which attaches handlers
/// to every package's events. `print` echoes each event as it arrives.
pub fn start(print: Bool) -> Result(Telemetry, String) {
  let recent =
    collector.new(process.new_name("sso_portal_telemetry"))
    |> collector.with_capacity(capacity)
  let forwarder = forwarder.new(process.new_name("sso_portal_http_gun_events"))
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(forwarder.supervised(forwarder))
  |> supervisor.add(collector.supervised(recent, sources(print)))
  |> supervisor.start
  |> result.map(fn(started) {
    Telemetry(recent:, forwarder:, supervisor: started.pid)
  })
  |> result.replace_error("telemetry did not start")
}

fn sources(print: Bool) -> List(collector.Source(Record)) {
  let keep = fn(record: Record) {
    case print {
      True -> io.println("    telemetry " <> describe(record))
      False -> Nil
    }
    record
  }
  [
    collector.source(hellhound_telemetry.http_request(), fn(m, r) {
      keep(HellhoundHttp(
        correlation: r.correlation,
        method: case r.method {
          hellhound_telemetry.Get -> "GET"
          hellhound_telemetry.Post -> "POST"
        },
        path: r.path,
        outcome: case r.outcome {
          hellhound_telemetry.Status(code) -> int.to_string(code)
          hellhound_telemetry.Failed(evidence:, reason:) ->
            "failed("
            <> hellhound_telemetry.transport_reason_name(reason)
            <> ", "
            <> case evidence {
              hellhound_telemetry.NotSent -> "not sent"
              hellhound_telemetry.MaybeSent -> "maybe sent"
            }
            <> ")"
        },
        duration_ms: m.duration_ms,
      ))
    }),
    collector.source(hellhound_telemetry.login(), fn(_, l) {
      keep(HellhoundSession(l.correlation, "login", string.inspect(l.outcome)))
    }),
    collector.source(hellhound_telemetry.refresh(), fn(_, r) {
      keep(HellhoundSession(r.correlation, "refresh", string.inspect(r.outcome)))
    }),
    collector.source(hellhound_telemetry.logout(), fn(_, l) {
      keep(HellhoundSession(
        l.correlation,
        "logout",
        string.inspect(l.revocation),
      ))
    }),
    collector.source(gun_telemetry.event(), fn(_timing, meta) {
      keep(GunLifecycle(
        correlation: meta.correlation,
        milestone: milestone(meta.milestone),
      ))
    }),
    collector.source(forwarder.dropped_event(), fn(d, _meta) {
      keep(ForwarderDropped(d.rejected, d.lost, d.unavailable))
    }),
  ]
}

/// Stop the forwarder and the collector. Sinal detaches the handlers the
/// collector's process owned.
pub fn stop(telemetry: Telemetry) -> Nil {
  process.unlink(telemetry.supervisor)
  process.kill(telemetry.supervisor)
}

/// The forwarder to pass to `http_gun/config.with_observations`.
pub fn forwarder(telemetry: Telemetry) -> Forwarder {
  telemetry.forwarder
}

/// Start tracing a request: the correlation to give both
/// `hellhound.with_correlation` and `http_gun.with_correlation`. The
/// collector records that the request began.
pub fn begin_request(telemetry: Telemetry) -> Correlation {
  let request = correlation.unique()
  collector.record(telemetry.recent, RequestBegan(request))
  request
}

/// Every recorded event of the most recently traced request. http_gun
/// events arrive asynchronously, so this waits briefly first.
pub fn last_request_trace(telemetry: Telemetry) -> List(Record) {
  process.sleep(100)
  let all = records(telemetry)
  let last =
    list.fold(all, option.None, fn(last, record) {
      case record {
        RequestBegan(id) -> Some(id)
        _ -> last
      }
    })
  case last {
    option.None -> []
    Some(id) ->
      list.filter(all, fn(record) {
        case record {
          HellhoundHttp(correlation:, ..)
          | HellhoundSession(correlation:, ..)
          | GunLifecycle(correlation:, ..) -> correlation == Some(id)
          ForwarderDropped(..) | RequestBegan(..) -> False
        }
      })
  }
}

/// The records the collector holds, oldest first: at most `capacity`.
/// Empty once it has stopped.
pub fn records(telemetry: Telemetry) -> List(Record) {
  collector.entries(telemetry.recent)
}

pub fn describe(record: Record) -> String {
  case record {
    HellhoundHttp(method:, path:, outcome:, duration_ms:, ..) ->
      "[hellhound.http.request] "
      <> method
      <> " "
      <> path
      <> " -> "
      <> outcome
      <> " ("
      <> int.to_string(duration_ms)
      <> " ms)"
    HellhoundSession(event:, outcome:, ..) ->
      "[hellhound." <> event <> "] " <> outcome
    GunLifecycle(milestone:, correlation:) ->
      "[http_gun.lifecycle] "
      <> milestone
      <> case correlation {
        Some(_) -> " (correlated)"
        option.None -> " (uncorrelated)"
      }
    ForwarderDropped(rejected:, lost:, unavailable:) ->
      "[sinal.forwarder.dropped] rejected="
      <> int.to_string(rejected)
      <> " lost="
      <> int.to_string(lost)
      <> " unavailable="
      <> int.to_string(unavailable)
    RequestBegan(correlation:) ->
      "[request] began " <> correlation.to_string(correlation)
  }
}

fn milestone(m: gun_telemetry.Milestone) -> String {
  case m {
    gun_telemetry.AdmissionEntered -> "admission_entered"
    gun_telemetry.AdmissionWaiting -> "admission_waiting"
    gun_telemetry.AdmissionGranted -> "admission_granted"
    gun_telemetry.GunCallReturned -> "gun_call_returned"
    gun_telemetry.ResponseHeaders(status) ->
      "response_headers(" <> int.to_string(status) <> ")"
    gun_telemetry.HttpTerminated(outcome) ->
      "terminated(" <> string.inspect(outcome) <> ")"
  }
}
