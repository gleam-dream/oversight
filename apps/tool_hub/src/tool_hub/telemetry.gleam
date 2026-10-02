//// Collects the Sinal events of every package the app uses and tries to
//// follow one question across them.
////
//// Join keys available today:
//// - fabric: the run id on every agent event.
//// - http_gun: an opaque correlation id the app chose (`with_correlation`).
//// - relay: an exchange or invocation integer, with no server name and no
////   link to the tool handler that ran.
//// - llm_wire: none; only stage, provider and outcome.

import fabric/model
import fabric/observation
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/string
import http_gun/telemetry as http_telemetry
import llm_wire/telemetry as llm_telemetry
import relay/telemetry as relay_telemetry
import sinal
import sinal/forwarder

pub type Key {
  /// A fabric run id.
  RunKey(String)
  /// An http_gun correlation id.
  HttpKey(http_telemetry.Id)
  /// A Relay exchange id (per HTTP POST).
  ExchangeKey(Int)
  /// A Relay invocation id.
  InvocationKey(Int)
  NoKey
}

pub type Record {
  Record(package: String, event: String, detail: String, key: Key)
}

/// The records of one question, split by whether a key joins them to it.
pub type Followed {
  Followed(joined: List(Record), unjoined: List(Record))
}

pub opaque type Telemetry {
  Telemetry(
    collector: Subject(Message),
    attachments: List(sinal.Attachment),
    forwarder: forwarder.Forwarder,
    supervisor: process.Pid,
  )
}

type State {
  State(records: List(Record), links: List(#(String, http_telemetry.Id)))
}

type Message {
  Add(Record)
  Link(run: String, http: http_telemetry.Id)
  Snapshot(Subject(State))
}

/// Attaches to every event and starts the forwarder http_gun requires.
/// `prefix` keeps handler ids unique when several collectors coexist.
pub fn start(prefix: String) -> Telemetry {
  let assert Ok(collector) =
    actor.new(State([], []))
    |> actor.on_message(fn(state, message) {
      case message {
        Add(record) ->
          actor.continue(State(..state, records: [record, ..state.records]))
        Link(run, http) ->
          actor.continue(State(..state, links: [#(run, http), ..state.links]))
        Snapshot(reply) -> {
          process.send(
            reply,
            State(..state, records: list.reverse(state.records)),
          )
          actor.continue(state)
        }
      }
    })
    |> actor.start
  let sink = collector.data
  let add = fn(package, event, detail, key) {
    process.send(sink, Add(Record(package, event, detail, key)))
  }
  // http_gun only delivers observations through a forwarder, which needs a
  // supervisor; nothing else here does.
  let assert Ok(http_forwarder) =
    forwarder.new(process.new_name(prefix <> "_http_observations"), 1024)
  let assert Ok(started) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(forwarder.supervised(http_forwarder))
    |> supervisor.start
  process.unlink(started.pid)

  let attachments =
    list.flatten([
      relay_handlers(prefix, add),
      fabric_handlers(prefix, add),
      [
        attach(prefix, "llm_wire", llm_telemetry.observation_event(), fn(_, m) {
          let llm_telemetry.Metadata(stage:, provider:, outcome:) = m
          add(
            "llm_wire",
            "observation",
            stage <> " " <> provider <> " " <> outcome,
            NoKey,
          )
        }),
        attach(prefix, "http_gun", http_telemetry.event(), fn(_, m) {
          let http_telemetry.Metadata(correlation:, mode:, milestone:, ..) = m
          let key = case correlation {
            Some(id) -> HttpKey(id)
            None -> NoKey
          }
          add(
            "http_gun",
            "lifecycle",
            string.inspect(mode) <> " " <> string.inspect(milestone),
            key,
          )
        }),
        attach(prefix, "sinal", forwarder.dropped_event(), fn(dropped, m) {
          add(
            "sinal",
            "forwarder.dropped",
            string.inspect(#(dropped, m)),
            NoKey,
          )
        }),
      ],
    ])
  Telemetry(sink, attachments, http_forwarder, started.pid)
}

pub fn http_forwarder(telemetry: Telemetry) -> forwarder.Forwarder {
  telemetry.forwarder
}

/// Records which HTTP correlation a run's model calls carry.
pub fn link(telemetry: Telemetry, run: String, http: http_telemetry.Id) -> Nil {
  process.send(telemetry.collector, Link(run, http))
}

pub fn records(telemetry: Telemetry) -> List(Record) {
  snapshot(telemetry).records
}

fn snapshot(telemetry: Telemetry) -> State {
  process.call(telemetry.collector, 1000, Snapshot)
}

/// Every record that a key joins to `run`, and every other record.
pub fn follow(telemetry: Telemetry, run: String) -> Followed {
  let State(records:, links:) = snapshot(telemetry)
  let http_ids =
    list.filter_map(links, fn(link) {
      case link.0 == run {
        True -> Ok(link.1)
        False -> Error(Nil)
      }
    })
  let #(joined, unjoined) =
    list.partition(records, fn(record) {
      case record.key {
        RunKey(id) -> id == run
        HttpKey(id) -> list.contains(http_ids, id)
        _ -> False
      }
    })
  Followed(joined, unjoined)
}

pub fn count(records: List(Record), package: String) -> Int {
  list.count(records, fn(record) { record.package == package })
}

pub fn has(records: List(Record), package: String, event: String) -> Bool {
  list.any(records, fn(record) {
    record.package == package && record.event == event
  })
}

pub fn render(record: Record) -> String {
  let key = case record.key {
    RunKey(_) -> " [run]"
    HttpKey(_) -> " [http correlation]"
    ExchangeKey(id) -> " [exchange " <> int.to_string(id) <> "]"
    InvocationKey(id) -> " [invocation " <> int.to_string(id) <> "]"
    NoKey -> ""
  }
  record.package <> " " <> record.event <> ": " <> record.detail <> key
}

pub fn stop(telemetry: Telemetry) -> Nil {
  list.each(telemetry.attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
  stop_process(telemetry.supervisor)
}

@external(erlang, "tool_hub_ffi", "stop_process")
fn stop_process(pid: process.Pid) -> Nil

fn attach(
  prefix: String,
  name: String,
  event: sinal.Event(m, d),
  handler: fn(m, d) -> Nil,
) -> sinal.Attachment {
  let assert Ok(id) = sinal.handler_id(prefix <> "." <> name)
  let assert Ok(attachment) = sinal.observe(id, event, handler)
  attachment
}

fn relay_handlers(
  prefix: String,
  add: fn(String, String, String, Key) -> Nil,
) -> List(sinal.Attachment) {
  [
    attach(
      prefix,
      "relay.frame_rejected",
      relay_telemetry.frame_rejected_event(),
      fn(_, m) {
        add("relay", "frame.rejected", m.reason, ExchangeKey(m.exchange_id))
      },
    ),
    attach(
      prefix,
      "relay.request_admitted",
      relay_telemetry.request_admitted_event(),
      fn(_, m) {
        add("relay", "request.admitted", m.method, ExchangeKey(m.exchange_id))
      },
    ),
    attach(
      prefix,
      "relay.invocation_started",
      relay_telemetry.invocation_started_event(),
      fn(_, m) {
        add(
          "relay",
          "invocation.started",
          "tool_name="
            <> m.tool_name
            <> " exchange="
            <> int.to_string(m.exchange_id),
          InvocationKey(m.invocation_id),
        )
      },
    ),
    attach(
      prefix,
      "relay.invocation_completed",
      relay_telemetry.invocation_completed_event(),
      fn(measured, m) {
        add(
          "relay",
          "invocation.completed",
          m.status <> " in " <> int.to_string(measured.duration_ms) <> " ms",
          InvocationKey(m.invocation_id),
        )
      },
    ),
    attach(
      prefix,
      "relay.invocation_cancelled",
      relay_telemetry.invocation_cancelled_event(),
      fn(_, m) {
        add("relay", "invocation.cancelled", "", InvocationKey(m.invocation_id))
      },
    ),
    attach(
      prefix,
      "relay.invocation_crashed",
      relay_telemetry.invocation_crashed_event(),
      fn(_, m) {
        add(
          "relay",
          "invocation.crashed",
          m.reason,
          InvocationKey(m.invocation_id),
        )
      },
    ),
    attach(
      prefix,
      "relay.exchange_closed",
      relay_telemetry.exchange_closed_event(),
      fn(_, m) {
        add("relay", "exchange.closed", "", ExchangeKey(m.exchange_id))
      },
    ),
  ]
}

fn fabric_handlers(
  prefix: String,
  add: fn(String, String, String, Key) -> Nil,
) -> List(sinal.Attachment) {
  [
    attach(prefix, "fabric.run_started", observation.run_started(), fn(_, m) {
      add("fabric", "run.start", m.agent, RunKey(m.run))
    }),
    attach(prefix, "fabric.model_turn", observation.model_turn(), fn(usage, m) {
      add(
        "fabric",
        "model.stop",
        "turn "
          <> int.to_string(m.turn)
          <> " "
          <> string.inspect(m.result)
          <> usage_text(usage),
        RunKey(m.run),
      )
    }),
    attach(
      prefix,
      "fabric.tool_dispatched",
      observation.tool_dispatched(),
      fn(_, m) {
        add("fabric", "tool.start", m.action.tool, RunKey(m.action.run))
      },
    ),
    attach(prefix, "fabric.tool_settled", observation.tool_settled(), fn(_, m) {
      add(
        "fabric",
        "tool.stop",
        m.action.tool <> " " <> string.inspect(m.disposition),
        RunKey(m.action.run),
      )
    }),
    attach(
      prefix,
      "fabric.run_cancelled",
      observation.run_cancelled(),
      fn(_, m) { add("fabric", "run.cancel", "", RunKey(m.run)) },
    ),
    attach(
      prefix,
      "fabric.run_finished",
      observation.run_finished(),
      fn(totals, m) {
        add(
          "fabric",
          "run.stop",
          string.inspect(m.outcome)
            <> " after "
            <> int.to_string(totals.turns)
            <> " turns, "
            <> int.to_string(totals.unreported_replies)
            <> " without usage",
          RunKey(m.run),
        )
      },
    ),
  ]
}

fn usage_text(usage: Option(model.Usage)) -> String {
  case usage {
    Some(usage) -> " (" <> string.inspect(usage) <> ")"
    None -> " (usage not reported)"
  }
}
