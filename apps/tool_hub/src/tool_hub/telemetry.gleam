//// Collects the Sinal events of every package the app uses and tries to
//// follow one question across them.
////
//// Join keys available today:
//// - fabric, http_gun, llm_wire and relay: the question's `Correlation`. The
////   assistant server gives each request one (`http.with_correlation`), the
////   handler reads it (`tool.correlation`) and starts the run under it
////   (`fabric.start`). Fabric puts it on every run event, on the provider's
////   HTTP Gun view (which llm_wire reads) and in every `tool.Call`, which the
////   tools put on the inventory client's Relay view.
//// - relay events of the inventory server: an exchange or invocation integer
////   only, because a Relay client's correlation does not cross the wire.
//// Fabric events also carry the run id, which names the question to follow.

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
  /// A fabric run id and the correlation its events carry.
  RunKey(run: String, correlation: Correlation)
  /// The `Correlation` of one question.
  CorrelationKey(Correlation)
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

type Message {
  Add(Record)
  Snapshot(Subject(List(Record)))
}

/// Attaches to every event. The handlers only send to the collector, so they
/// run in the emitting process and need no forwarder.
pub fn start() -> Telemetry {
  let assert Ok(collector) =
    actor.new([])
    |> actor.on_message(fn(records, message) {
      case message {
        Add(record) -> actor.continue([record, ..records])
        Snapshot(reply) -> {
          process.send(reply, list.reverse(records))
          actor.continue(records)
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
          llm_telemetry.event(),
          "tool_hub_llm_wire_event",
          fn(_, m) {
            add(
              "llm_wire",
              "observation",
              llm_telemetry.stage_name(m.stage)
                <> " "
                <> m.provider
                <> " "
                <> llm_telemetry.outcome_name(m.outcome),
              key_of(m.correlation, NoKey),
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
            add(
              "http_gun",
              "lifecycle",
              option.unwrap(client, "unlabelled")
                <> ": "
                <> string.inspect(mode)
                <> " "
                <> string.inspect(milestone),
              key_of(correlation, NoKey),
            )
          },
        ),
      ],
    ])
  Telemetry(sink, attachments)
}

fn key_of(correlation: Option(Correlation), otherwise: Key) -> Key {
  case correlation {
    Some(correlation) -> CorrelationKey(correlation)
    None -> otherwise
  }
}

pub fn records(telemetry: Telemetry) -> List(Record) {
  process.call(telemetry.collector, 1000, Snapshot)
}

/// Every record that a key joins to `run`, and every other record.
pub fn follow(telemetry: Telemetry, run: String) -> Followed {
  let records = records(telemetry)
  // The run's own events name its correlation.
  let correlations =
    list.filter_map(records, fn(record) {
      case record.key {
        RunKey(id, correlation) if id == run -> Ok(correlation)
        _ -> Error(Nil)
      }
    })
  let #(joined, unjoined) =
    list.partition(records, fn(record) {
      case record.key {
        RunKey(_, id) | CorrelationKey(id) -> list.contains(correlations, id)
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
    RunKey(..) -> " [run]"
    CorrelationKey(_) -> " [correlation]"
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
  let server = fn(listener) { option.unwrap(listener, "unlabelled") <> ": " }
  let tool = fn(tool) { option.unwrap(tool, "-") }
  [
    sinal.observe_labelled(
      relay_telemetry.frame_rejected_event(),
      "tool_hub_relay_frame_rejected_event",
      fn(_, m) {
        add(
          "relay",
          "frame.rejected",
          server(m.listener) <> string.inspect(m.problem),
          ExchangeKey(m.exchange_id),
        )
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.request_admitted_event(),
      "tool_hub_relay_request_admitted_event",
      fn(_, m) {
        add(
          "relay",
          "request.admitted",
          server(m.listener) <> m.method,
          key_of(m.correlation, ExchangeKey(m.exchange_id)),
        )
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.invocation_started_event(),
      "tool_hub_relay_invocation_started_event",
      fn(_, m) {
        add(
          "relay",
          "invocation.started",
          server(m.listener) <> m.method <> " tool=" <> tool(m.tool),
          key_of(m.correlation, InvocationKey(m.invocation_id)),
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
          server(m.listener)
            <> tool(m.tool)
            <> " "
            <> string.inspect(m.status)
            <> " in "
            <> int.to_string(measured.duration_ms)
            <> " ms",
          key_of(m.correlation, InvocationKey(m.invocation_id)),
        )
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.invocation_cancelled_event(),
      "tool_hub_relay_invocation_cancelled_event",
      fn(_, m) {
        add(
          "relay",
          "invocation.cancelled",
          server(m.listener) <> tool(m.tool),
          key_of(m.correlation, InvocationKey(m.invocation_id)),
        )
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.invocation_crashed_event(),
      "tool_hub_relay_invocation_crashed_event",
      fn(_, m) {
        add(
          "relay",
          "invocation.crashed",
          server(m.listener) <> tool(m.tool) <> " " <> string.inspect(m.reason),
          key_of(m.correlation, InvocationKey(m.invocation_id)),
        )
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.exchange_closed_event(),
      "tool_hub_relay_exchange_closed_event",
      fn(_, m) {
        add(
          "relay",
          "exchange.closed",
          server(m.listener),
          ExchangeKey(m.exchange_id),
        )
      },
    ),
    sinal.observe_labelled(
      relay_telemetry.client_call_event(),
      "tool_hub_relay_client_call_event",
      fn(measured, m) {
        add(
          "relay",
          "client.call",
          option.unwrap(m.client, "unlabelled")
            <> ": "
            <> m.method
            <> " tool="
            <> tool(m.tool)
            <> " "
            <> string.inspect(m.outcome)
            <> " in "
            <> int.to_string(measured.duration_ms)
            <> " ms",
          key_of(m.correlation, NoKey),
        )
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
      fn(_, m) {
        add("fabric", "run.start", m.agent, RunKey(m.run, m.correlation))
      },
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
          RunKey(m.run, m.correlation),
        )
      },
    ),
    sinal.observe_labelled(
      observation.tool_dispatched(),
      "tool_hub_fabric_tool_dispatched",
      fn(_, m) {
        add(
          "fabric",
          "tool.start",
          m.action.tool,
          RunKey(m.action.run, m.correlation),
        )
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
          RunKey(m.action.run, m.correlation),
        )
      },
    ),
    sinal.observe_labelled(
      observation.run_cancelled(),
      "tool_hub_fabric_run_cancelled",
      fn(_, m) { add("fabric", "run.cancel", "", RunKey(m.run, m.correlation)) },
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
          RunKey(m.run, m.correlation),
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
