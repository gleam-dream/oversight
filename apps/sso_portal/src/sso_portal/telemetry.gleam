//// Sinal subscriptions for every package in the portal, plus a collector
//// that follows one browser request across them.
////
//// - Warden emits `[warden, http, request]`, `[warden, login]`,
////   `[warden, refresh]` and `[warden, logout]` in the process that called
////   it, each carrying the `Correlation` of the `warden.with_correlation`
////   view that made the call.
//// - http_gun emits `[http_gun, lifecycle]` through a Sinal forwarder (a
////   different process), carrying the caller's optional `Correlation`; it
////   does so for the portal's billing calls and for Warden's provider calls.
//// - wisp, mist and pog emit nothing through Sinal.
////
//// A request makes one `Correlation` and hands it to Warden and to http_gun.
//// Nothing here maps processes to requests.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import http_gun/telemetry as gun_telemetry
import sinal
import sinal/correlation.{type Correlation}
import sinal/forwarder.{type Forwarder}
import warden/telemetry as warden_telemetry

pub type Record {
  WardenHttp(
    correlation: Option(Correlation),
    method: String,
    path: String,
    outcome: String,
    duration_ms: Int,
  )
  /// `[warden, login]`, `[warden, refresh]` or `[warden, logout]`: the
  /// event name and its closed outcome.
  WardenSession(
    correlation: Option(Correlation),
    event: String,
    outcome: String,
  )
  GunLifecycle(correlation: Option(Correlation), milestone: String)
  ForwarderDropped(rejected: Int, lost: Int, unavailable: Int)
}

pub opaque type Telemetry {
  Telemetry(
    collector: Subject(Message),
    forwarder: Forwarder,
    attachments: List(sinal.Attachment),
    supervisor: Pid,
  )
}

type State {
  State(records: List(Record), last: Option(Correlation), echo_: Bool)
}

type Message {
  Add(Record)
  Begin(Correlation)
  All(reply: Subject(#(List(Record), Option(Correlation))))
}

/// Start the collector and the http_gun forwarder, and attach handlers to
/// every package's events. `print` echoes each event as it arrives.
pub fn start(print: Bool) -> Result(Telemetry, String) {
  use collector <- result.try(
    actor.new(State([], option.None, print))
    |> actor.on_message(collect)
    |> actor.start
    |> result.map(fn(started) { started.data })
    |> result.replace_error("collector did not start"),
  )
  let forwarder = forwarder.new(process.new_name("sso_portal_http_gun_events"))
  use sup <- result.try(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(forwarder.supervised(forwarder))
    |> supervisor.start
    |> result.replace_error("forwarder did not start"),
  )
  let warden_http =
    sinal.observe_labelled(
      warden_telemetry.http_request(),
      "sso_portal_warden",
      fn(m, r) {
        process.send(
          collector,
          Add(WardenHttp(
            correlation: r.correlation,
            method: case r.method {
              warden_telemetry.Get -> "GET"
              warden_telemetry.Post -> "POST"
            },
            path: r.path,
            outcome: case r.outcome {
              warden_telemetry.Status(code) -> int.to_string(code)
              warden_telemetry.Failed(evidence:, reason:) ->
                "failed("
                <> warden_telemetry.transport_reason_name(reason)
                <> ", "
                <> case evidence {
                  warden_telemetry.NotSent -> "not sent"
                  warden_telemetry.MaybeSent -> "maybe sent"
                }
                <> ")"
            },
            duration_ms: m.duration_ms,
          )),
        )
      },
    )
  let warden_login =
    sinal.observe_labelled(
      warden_telemetry.login(),
      "sso_portal_warden_login",
      fn(_, l) {
        process.send(
          collector,
          Add(WardenSession(l.correlation, "login", string.inspect(l.outcome))),
        )
      },
    )
  let warden_refresh =
    sinal.observe_labelled(
      warden_telemetry.refresh(),
      "sso_portal_warden_refresh",
      fn(_, r) {
        process.send(
          collector,
          Add(WardenSession(r.correlation, "refresh", string.inspect(r.outcome))),
        )
      },
    )
  let warden_logout =
    sinal.observe_labelled(
      warden_telemetry.logout(),
      "sso_portal_warden_logout",
      fn(_, l) {
        process.send(
          collector,
          Add(WardenSession(
            l.correlation,
            "logout",
            string.inspect(l.revocation),
          )),
        )
      },
    )
  let gun_attachment =
    sinal.observe_labelled(
      gun_telemetry.event(),
      "sso_portal_http_gun",
      fn(_timing, meta) {
        process.send(
          collector,
          Add(GunLifecycle(
            correlation: meta.correlation,
            milestone: milestone(meta.milestone),
          )),
        )
      },
    )
  let drop_attachment =
    sinal.observe_labelled(
      forwarder.dropped_event(),
      "sso_portal_dropped",
      fn(d, _meta) {
        process.send(
          collector,
          Add(ForwarderDropped(d.rejected, d.lost, d.unavailable)),
        )
      },
    )
  Ok(Telemetry(
    collector:,
    forwarder:,
    attachments: [
      warden_http,
      warden_login,
      warden_refresh,
      warden_logout,
      gun_attachment,
      drop_attachment,
    ],
    supervisor: sup.pid,
  ))
}

pub fn stop(telemetry: Telemetry) -> Nil {
  list.each(telemetry.attachments, fn(a) {
    let _ = sinal.detach(a)
    Nil
  })
  process.unlink(telemetry.supervisor)
  process.kill(telemetry.supervisor)
}

/// The forwarder to pass to `http_gun/config.with_observations`.
pub fn forwarder(telemetry: Telemetry) -> Forwarder {
  telemetry.forwarder
}

/// Start tracing a request: the correlation to give both
/// `warden.with_correlation` and `http_gun.with_correlation`.
pub fn begin_request(telemetry: Telemetry) -> Correlation {
  let request = correlation.unique()
  process.send(telemetry.collector, Begin(request))
  request
}

/// Every recorded event of the most recently traced request. http_gun
/// events arrive asynchronously, so this waits briefly first.
pub fn last_request_trace(telemetry: Telemetry) -> List(Record) {
  process.sleep(100)
  let #(records, last) = actor.call(telemetry.collector, 1000, All)
  case last {
    option.None -> []
    Some(id) ->
      list.filter(records, fn(record) {
        case record {
          WardenHttp(correlation:, ..)
          | WardenSession(correlation:, ..)
          | GunLifecycle(correlation:, ..) -> correlation == Some(id)
          ForwarderDropped(..) -> False
        }
      })
  }
}

/// All events recorded so far, oldest first.
pub fn records(telemetry: Telemetry) -> List(Record) {
  actor.call(telemetry.collector, 1000, All).0
}

pub fn describe(record: Record) -> String {
  case record {
    WardenHttp(method:, path:, outcome:, duration_ms:, ..) ->
      "[warden.http.request] "
      <> method
      <> " "
      <> path
      <> " -> "
      <> outcome
      <> " ("
      <> int.to_string(duration_ms)
      <> " ms)"
    WardenSession(event:, outcome:, ..) ->
      "[warden." <> event <> "] " <> outcome
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
  }
}

fn collect(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Add(record) -> {
      case state.echo_ {
        True -> io.println("    telemetry " <> describe(record))
        False -> Nil
      }
      actor.continue(State(..state, records: [record, ..state.records]))
    }
    Begin(id) -> actor.continue(State(..state, last: Some(id)))
    All(reply) -> {
      process.send(reply, #(list.reverse(state.records), state.last))
      actor.continue(state)
    }
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
