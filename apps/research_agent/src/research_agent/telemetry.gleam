//// Attaches to the Sinal events of every package the app uses and collects
//// them, so one research request can be followed across packages.
////
//// What each package lets the app key an event on:
////
//// - the app itself (`events`): the research id as a `Correlation`, so no
////   binding is needed;
//// - grind: the job's correlation, which the app sets to the research id at
////   submission (`job.with_correlation`);
//// - saga: the correlation the job handler passes to the durable run
////   (`durable.with_correlation`);
//// - http_gun: the research id as a `Correlation`, attached with
////   `with_correlation` (the tool handlers take it from `tool.Call`);
//// - fabric: the correlation the job passes to `fabric.start`, carried by
////   every run event but `lease.lose`;
//// - llm_wire: the correlation of the HTTP client view `fabric/llm` tags
////   each model turn with, which is the run's, hence the research id.

import fabric/observation as fabric_events
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import grind/telemetry as grind_events
import http_gun/telemetry as http_events
import llm_wire/telemetry as llm_events
import research_agent/events
import saga/telemetry as saga_events
import sinal
import sinal/correlation
import sinal/forwarder

/// What an event can be joined on.
pub type Key {
  /// The research id itself, from every event that carries the research's
  /// `Correlation`: the app's own, Grind's, Saga's, Fabric's, llm_wire's and
  /// http_gun's.
  Research(String)
  Unkeyed
}

pub type Observed {
  Observed(source: String, name: String, key: Key, detail: String)
}

pub type Telemetry {
  Telemetry(collector: Subject(Message), attachments: List(sinal.Attachment))
}

pub opaque type Message {
  Record(Observed)
  Snapshot(Subject(List(Observed)))
}

type State {
  State(events: List(Observed), echo_events: Bool)
}

/// Starts the collector and attaches to every package's events. With
/// `echo_events`, each event is printed as it arrives.
pub fn start(echo_events: Bool) -> Telemetry {
  let assert Ok(started) =
    actor.new(State([], echo_events))
    |> actor.on_message(handle)
    |> actor.start
  let collector = started.data
  let record = fn(source, name, key, detail) {
    process.send(collector, Record(Observed(source, name, key, detail)))
  }
  let attachments = [
    // the app's own events: the research id is their correlation
    sinal.observe(events.state_changed(), fn(_, m: events.Transition) {
      record(
        "research_agent",
        "research.state",
        Research(correlation.to_string(m.correlation)),
        events.state_name(m.state),
      )
    }),
    // grind
    sinal.observe(
      grind_events.admitted(),
      fn(_, m: grind_events.AdmittedMetadata) {
        record(
          "grind",
          "job.admitted",
          job(m.ref),
          string.inspect(m.committed_state),
        )
      },
    ),
    sinal.observe(
      grind_events.claimed(),
      fn(_, m: grind_events.ClaimedMetadata) {
        record(
          "grind",
          "job.claimed",
          job(m.ref),
          "attempt " <> int.to_string(m.attempt.attempt),
        )
      },
    ),
    sinal.observe(
      grind_events.acknowledged(),
      fn(_, m: grind_events.AcknowledgedMetadata) {
        record(
          "grind",
          "job.acknowledged",
          job(m.ref),
          string.inspect(m.committed_state),
        )
      },
    ),
    sinal.observe(
      grind_events.quarantined(),
      fn(_, m: grind_events.QuarantinedMetadata) {
        record("grind", "job.quarantined", job(m.ref), case m.replayed {
          True -> "lease expired, replayed"
          False -> "lease expired, held uncertain"
        })
      },
    ),
    sinal.observe(
      grind_events.resolved(),
      fn(_, m: grind_events.ResolvedMetadata) {
        record("grind", "job.resolved", job(m.ref), string.inspect(m.decision))
      },
    ),
    sinal.observe(
      grind_events.cancellation_decided(),
      fn(_, m: grind_events.CancellationMetadata) {
        record(
          "grind",
          "job.cancellation_decided",
          job(m.ref),
          string.inspect(m.outcome),
        )
      },
    ),
    sinal.observe(
      grind_events.released(),
      fn(_, m: grind_events.ReleasedMetadata) {
        record(
          "grind",
          "job.released",
          job(m.ref),
          string.inspect(m.restored_state),
        )
      },
    ),
    // fabric
    sinal.observe(
      fabric_events.run_started(),
      fn(_, m: fabric_events.RunStarted) {
        record("fabric", "run.start", research(m.correlation), m.agent)
      },
    ),
    sinal.observe(
      fabric_events.run_recovered(),
      fn(_, m: fabric_events.RunRecovered) {
        record(
          "fabric",
          "run.recover",
          research(m.correlation),
          "incarnation " <> int.to_string(m.incarnation),
        )
      },
    ),
    sinal.observe(
      fabric_events.run_taken_over(),
      fn(_, m: fabric_events.RunTakenOver) {
        record(
          "fabric",
          "run.take_over",
          research(m.correlation),
          "from " <> m.previous_owner,
        )
      },
    ),
    sinal.observe(fabric_events.model_turn(), fn(_, m: fabric_events.ModelTurn) {
      record(
        "fabric",
        "model.stop",
        research(m.correlation),
        "turn " <> int.to_string(m.turn) <> " " <> string.inspect(m.result),
      )
    }),
    sinal.observe(
      fabric_events.tool_dispatched(),
      fn(_, m: fabric_events.ToolDispatched) {
        record("fabric", "tool.start", research(m.correlation), m.action.tool)
      },
    ),
    sinal.observe(
      fabric_events.tool_settled(),
      fn(_, m: fabric_events.ToolSettled) {
        record(
          "fabric",
          "tool.stop",
          research(m.correlation),
          m.action.tool <> " " <> string.inspect(m.disposition),
        )
      },
    ),
    sinal.observe(
      fabric_events.run_cancelled(),
      fn(_, m: fabric_events.RunCancelled) {
        record("fabric", "run.cancel", research(m.correlation), "")
      },
    ),
    sinal.observe(
      fabric_events.run_finished(),
      fn(_, m: fabric_events.RunFinished) {
        record(
          "fabric",
          "run.stop",
          research(m.correlation),
          string.inspect(m.outcome),
        )
      },
    ),
    sinal.observe(fabric_events.lease_lost(), fn(_, m: fabric_events.LeaseLost) {
      record("fabric", "lease.lose", Unkeyed, string.inspect(m.reason))
    }),
    // saga
    sinal.observe(saga_events.run_started(), fn(_, m: saga_events.RunMetadata) {
      record(
        "saga",
        "run.start",
        keyed(m.correlation),
        m.workflow <> " " <> option.unwrap(m.execution, "local"),
      )
    }),
    sinal.observe(
      saga_events.run_stopped(),
      fn(_, m: saga_events.RunStopMetadata) {
        record(
          "saga",
          "run.stop",
          keyed(m.correlation),
          m.workflow <> " " <> saga_events.outcome_kind_name(m.outcome),
        )
      },
    ),
    sinal.observe(
      saga_events.step_stopped(),
      fn(_, m: saga_events.StepStopMetadata) {
        record(
          "saga",
          "step.stop",
          keyed(m.correlation),
          m.step <> " " <> string.inspect(m.result),
        )
      },
    ),
    sinal.observe(
      saga_events.undo_stopped(),
      fn(_, m: saga_events.UndoMetadata) {
        record(
          "saga",
          "undo.stop",
          keyed(m.correlation),
          m.step <> " " <> string.inspect(m.result),
        )
      },
    ),
    // llm_wire
    // llm_wire reads the correlation from the model call's client view.
    sinal.observe(llm_events.event(), fn(_, m: llm_events.Metadata) {
      record(
        "llm_wire",
        llm_events.stage_name(m.stage),
        keyed(m.correlation),
        m.provider <> " " <> llm_events.outcome_name(m.outcome),
      )
    }),
    // http_gun (routed through the app's forwarder, `http_prefix`)
    sinal.observe(http_events.event(), fn(_, m: http_events.Metadata) {
      let key = keyed(m.correlation)
      case m.milestone {
        http_events.ResponseHeaders(status) ->
          record("http_gun", "response_headers", key, int.to_string(status))
        http_events.HttpTerminated(outcome) ->
          record("http_gun", "terminated", key, string.inspect(outcome))
        _ -> Nil
      }
    }),
    // sinal
    sinal.observe(
      forwarder.dropped_event(),
      fn(d: forwarder.Dropped, m: forwarder.DroppedMetadata) {
        record("sinal", "forwarder.dropped", Unkeyed, string.inspect(#(d, m)))
      },
    ),
  ]
  Telemetry(collector:, attachments:)
}

pub fn stop(telemetry: Telemetry) -> Nil {
  list.each(telemetry.attachments, fn(a) {
    let _ = sinal.detach(a)
    Nil
  })
}

fn job(ref: grind_events.JobRef) -> Key {
  Research(correlation.to_string(ref.correlation))
}

fn research(correlation: correlation.Correlation) -> Key {
  Research(correlation.to_string(correlation))
}

fn keyed(correlation: Option(correlation.Correlation)) -> Key {
  case correlation {
    Some(id) -> Research(correlation.to_string(id))
    None -> Unkeyed
  }
}

/// A research request's trail across packages, and how many events of each
/// source could not be attributed to any request.
pub type Trace {
  Trace(events: List(Observed), unattributed: List(#(String, Int)))
}

pub fn trace(telemetry: Telemetry, research: String) -> Trace {
  // Let in-flight forwarder deliveries land.
  process.sleep(100)
  let events = process.call(telemetry.collector, 2000, Snapshot)
  let owner = fn(key) {
    case key {
      Research(id) -> Ok(id)
      Unkeyed -> Error(Nil)
    }
  }
  let mine = list.filter(events, fn(e) { owner(e.key) == Ok(research) })
  let unattributed =
    events
    |> list.filter(fn(e) { result.is_error(owner(e.key)) })
    |> list.group(fn(e) { e.source })
    |> dict.map_values(fn(_, es) { list.length(es) })
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  Trace(events: mine, unattributed:)
}

pub fn sources(trace: Trace) -> List(String) {
  trace.events |> list.map(fn(e) { e.source }) |> list.unique
}

pub fn render(e: Observed) -> String {
  e.source <> " " <> e.name <> " " <> e.detail
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Record(observed) -> {
      case state.echo_events {
        True -> io.println("    [telemetry] " <> render(observed))
        False -> Nil
      }
      actor.continue(State(..state, events: [observed, ..state.events]))
    }
    Snapshot(reply) -> {
      process.send(reply, list.reverse(state.events))
      actor.continue(state)
    }
  }
}

/// The `[fabric]` prefix routed through the app's forwarder keeps Fabric's
/// handlers out of its runners (see `fabric/observation`).
pub fn fabric_prefix() -> List(String) {
  ["fabric"]
}

/// http_gun emits through `sinal.emit`; routing its prefix keeps the
/// handlers out of the client's pool and body processes.
pub fn http_prefix() -> List(String) {
  ["http_gun"]
}
