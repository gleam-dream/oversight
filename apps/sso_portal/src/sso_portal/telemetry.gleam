//// Sinal subscriptions for every package in the portal, plus the glue needed
//// to follow one browser request across them.
////
//// - Warden emits `[warden, http, request]` synchronously in the process that
////   called it (the wisp request process), with no correlation field.
//// - http_gun emits `[http_gun, lifecycle]` through a Sinal forwarder (a
////   different process), carrying an optional correlation `Id`.
//// - wisp, mist and pog emit nothing through Sinal.
////
//// To join the two, each request registers `self()` with a fresh http_gun
//// correlation id; Warden events are attributed by emitting pid, http_gun
//// events by correlation.

import gleam/dict.{type Dict}
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
import sinal/forwarder.{type Forwarder}
import warden/observation

pub type Record {
  WardenHttp(
    /// The request that emitted it, resolved from the emitting pid.
    request: Option(gun_telemetry.Id),
    method: String,
    path: String,
    outcome: String,
    duration_ms: Int,
  )
  GunLifecycle(correlation: Option(gun_telemetry.Id), milestone: String)
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
  State(
    records: List(Record),
    links: Dict(Pid, gun_telemetry.Id),
    last: Option(gun_telemetry.Id),
    echo_: Bool,
  )
}

type Message {
  Add(Record)
  AddWarden(Pid, Record)
  Link(Pid, gun_telemetry.Id)
  All(reply: Subject(#(List(Record), Option(gun_telemetry.Id))))
}

/// Start the collector and the http_gun forwarder, and attach handlers to
/// every package's events. `print` echoes each event as it arrives.
pub fn start(print: Bool) -> Result(Telemetry, String) {
  use collector <- result.try(
    actor.new(State([], dict.new(), option.None, print))
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
  let warden_attachment =
    sinal.observe(observation.http_request(), fn(m, r) {
      process.send(
        collector,
        AddWarden(
          process.self(),
          WardenHttp(
            request: option.None,
            method: case r.method {
              observation.Get -> "GET"
              observation.Post -> "POST"
            },
            path: r.path,
            outcome: case r.outcome {
              observation.Status(code) -> int.to_string(code)
              observation.Failed(sent:, class:) ->
                "failed(" <> class <> ", sent=" <> string.inspect(sent) <> ")"
            },
            duration_ms: m.duration_ms,
          ),
        ),
      )
    })
  let gun_attachment =
    sinal.observe(gun_telemetry.event(), fn(_timing, meta) {
      process.send(
        collector,
        Add(GunLifecycle(
          correlation: meta.correlation,
          milestone: milestone(meta.milestone),
        )),
      )
    })
  let drop_attachment =
    sinal.observe(forwarder.dropped_event(), fn(d, _meta) {
      process.send(
        collector,
        Add(ForwarderDropped(d.rejected, d.lost, d.unavailable)),
      )
    })
  Ok(Telemetry(
    collector:,
    forwarder:,
    attachments: [warden_attachment, gun_attachment, drop_attachment],
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

/// The forwarder to put in `http_gun/config.Config(observations:)`.
pub fn forwarder(telemetry: Telemetry) -> Forwarder {
  telemetry.forwarder
}

/// Start tracing the calling request process: returns the correlation id to
/// attach to http_gun calls with `http_gun.with_correlation`.
pub fn begin_request(telemetry: Telemetry) -> gun_telemetry.Id {
  let id = gun_telemetry.new_id()
  process.send(telemetry.collector, Link(process.self(), id))
  id
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
          WardenHttp(request:, ..) -> request == Some(id)
          GunLifecycle(correlation:, ..) -> correlation == Some(id)
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
    AddWarden(pid, record) ->
      case record {
        WardenHttp(..) ->
          collect(
            state,
            Add(
              WardenHttp(
                ..record,
                request: option.from_result(dict.get(state.links, pid)),
              ),
            ),
          )
        _ -> collect(state, Add(record))
      }
    // A mist connection process serves several keep-alive requests, so the
    // link is replaced by the newest request on that process.
    Link(pid, id) ->
      actor.continue(
        State(..state, links: dict.insert(state.links, pid, id), last: Some(id)),
      )
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
