//// Collects the Sinal events of every package the app uses and tries to
//// follow one question across them.
////
//// Join keys available today:
//// - fabric: the run id on every agent event.
//// - http_gun: the `Correlation` the app passed to `with_correlation`, and the
////   client's label, which tells the provider client from any other client.
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
import gleam/string
import http_gun/telemetry as http_telemetry
import llm_wire/telemetry as llm_telemetry
import relay/telemetry as relay_telemetry
import sinal
import sinal/correlation.{type Correlation}

pub type Key {
  /// A fabric run id.
  RunKey(String)
  /// The `Correlation` the app gave http_gun for one question.
  HttpKey(Correlation)
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
  Telemetry(collector: Subject(Message), attachments: List(sinal.Attachment))
}

type State {
  State(records: List(Record), links: List(#(String, Correlation)))
}

type Message {
  Add(Record)
  Link(run: String, http: Correlation)
  Snapshot(Subject(State))
}

/// Attaches to every event. The handlers only send to the collector, so they
/// run in the emitting process and need no forwarder.
pub fn start() -> Telemetry {
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
  let attachments =
    list.flatten([
      relay_handlers(add),
      fabric_handlers(add),
      [
        sinal.observe_labelled(
          llm_telemetry.observation_event(),
          "tool_hub_llm_wire_observation_event",
          fn(_, m) {
            let llm_telemetry.Metadata(stage:, provider:, outcome:) = m
            add(
              "llm_wire",
              "observation",
              stage <> " " <> provider <> " " <> outcome,
              NoKey,
            )
          },
        ),
        sinal.observe_labelled(
          http_telemetry.event(),
          "tool_hub_http_gun_event",
          fn(_, m) {
            let http_telemetry.Metadata(
              correlation:,
              mode:,
              milestone:,
              client:,
              ..,
            ) = m
            let key = case correlation {
              Some(id) -> HttpKey(id)
              None -> NoKey
            }
            add(
              "http_gun",
              "lifecycle",
              option.unwrap(client, "unlabelled")
                <> ": "
                <> string.inspect(mode)
                <> " "
                <> string.inspect(milestone),
              key,
            )
          },
        ),
      ],
    ])
  Telemetry(sink, attachments)
}

/// Records which HTTP correlation a run's model calls carry.
pub fn link(telemetry: Telemetry, run: String, http: Correlation) -> Nil {
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
}

fn relay_handlers(
  add: fn(String, String, String, Key) -> Nil,
) -> List(sinal.Attachment) {
  [
    sinal.observe_labelled(
      relay_telemetry.frame_rejected_event(),
      "tool_hub_relay_frame_rejected_event",
      fn(_, m) {
        add("relay", "frame.rejected", m.reason, ExchangeKey(m.exchange_id))
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.request_admitted_event(),
      "tool_hub_relay_request_admitted_event",
      fn(_, m) {
        add("relay", "request.admitted", m.method, ExchangeKey(m.exchange_id))
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.invocation_started_event(),
      "tool_hub_relay_invocation_started_event",
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
    sinal.observe_labelled(
      relay_telemetry.invocation_completed_event(),
      "tool_hub_relay_invocation_completed_event",
      fn(measured, m) {
        add(
          "relay",
          "invocation.completed",
          m.status <> " in " <> int.to_string(measured.duration_ms) <> " ms",
          InvocationKey(m.invocation_id),
        )
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.invocation_cancelled_event(),
      "tool_hub_relay_invocation_cancelled_event",
      fn(_, m) {
        add("relay", "invocation.cancelled", "", InvocationKey(m.invocation_id))
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.invocation_crashed_event(),
      "tool_hub_relay_invocation_crashed_event",
      fn(_, m) {
        add(
          "relay",
          "invocation.crashed",
          m.reason,
          InvocationKey(m.invocation_id),
        )
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.exchange_closed_event(),
      "tool_hub_relay_exchange_closed_event",
      fn(_, m) {
        add("relay", "exchange.closed", "", ExchangeKey(m.exchange_id))
      },
    ),
  ]
}

fn fabric_handlers(
  add: fn(String, String, String, Key) -> Nil,
) -> List(sinal.Attachment) {
  [
    sinal.observe_labelled(
      observation.run_started(),
      "tool_hub_fabric_run_started",
      fn(_, m) { add("fabric", "run.start", m.agent, RunKey(m.run)) },
    ),
    sinal.observe_labelled(
      observation.model_turn(),
      "tool_hub_fabric_model_turn",
      fn(usage, m) {
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
      },
    ),
    sinal.observe_labelled(
      observation.tool_dispatched(),
      "tool_hub_fabric_tool_dispatched",
      fn(_, m) {
        add("fabric", "tool.start", m.action.tool, RunKey(m.action.run))
      },
    ),
    sinal.observe_labelled(
      observation.tool_settled(),
      "tool_hub_fabric_tool_settled",
      fn(_, m) {
        add(
          "fabric",
          "tool.stop",
          m.action.tool <> " " <> string.inspect(m.disposition),
          RunKey(m.action.run),
        )
      },
    ),
    sinal.observe_labelled(
      observation.run_cancelled(),
      "tool_hub_fabric_run_cancelled",
      fn(_, m) { add("fabric", "run.cancel", "", RunKey(m.run)) },
    ),
    sinal.observe_labelled(
      observation.run_finished(),
      "tool_hub_fabric_run_finished",
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
