//// Attaches to the Sinal events of every package the app uses and collects
//// them, so one research request can be followed across packages.
////
//// What each package lets the app key an event on:
////
//// - the app itself (`events`): the research id as a `Correlation`, so no
////   binding is needed;
//// - grind: `job_id` (the handler is never told it; the app records job id
////   to research id at submission);
//// - fabric: `run` (issued by `fabric.start`; the app records it);
//// - http_gun: an opaque correlation `Id` the app mints with `new_id` and
////   attaches with `with_correlation` (the tool handlers do that per call);
//// - llm_wire: nothing (stage, provider, outcome);
//// - saga: `workflow` name and a per-VM `run: Int` that the app never sees
////   for a durable run (`durable.drive` hides the execution).

import fabric/observation as fabric_events
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import grind/observation as grind_events
import http_gun/telemetry as http_events
import llm_wire/telemetry as llm_events
import research_agent/events
import saga/observation as saga_events
import sinal
import sinal/correlation
import sinal/forwarder

/// What an event can be joined on.
pub type Key {
  /// The research id itself, from the app's own events (`events`).
  Research(String)
  Job(Int)
  Run(String)
  Http(http_events.Id)
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
  BindJob(Int, String)
  BindRun(String, String)
  BindHttp(http_events.Id, String)
  Snapshot(
    Subject(
      #(
        List(Observed),
        Dict(String, String),
        Dict(Int, String),
        Dict(http_events.Id, String),
      ),
    ),
  )
}

type State {
  State(
    events: List(Observed),
    runs: Dict(String, String),
    jobs: Dict(Int, String),
    http: Dict(http_events.Id, String),
    echo_events: Bool,
  )
}

/// Starts the collector and attaches to every package's events. With
/// `echo_events`, each event is printed as it arrives.
pub fn start(echo_events: Bool) -> Telemetry {
  let assert Ok(started) =
    actor.new(State([], dict.new(), dict.new(), dict.new(), echo_events))
    |> actor.on_message(handle)
    |> actor.start
  let collector = started.data
  let record = fn(source, name, key, detail) {
    process.send(collector, Record(Observed(source, name, key, detail)))
  }
  let attachments = [
    // the app's own events: the research id is their correlation
    sinal.observe(events.state_changed(), fn(_, m: events.Transition) {
      case m.correlation {
        Some(id) ->
          record(
            "research_agent",
            "research.state",
            Research(correlation.to_string(id)),
            events.state_name(m.state),
          )
        None -> Nil
      }
    }),
    // grind
    sinal.observe(
      grind_events.admitted(),
      fn(_, m: grind_events.AdmittedMetadata) {
        record(
          "grind",
          "job.admitted",
          Job(m.ref.job_id),
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
          Job(m.ref.job_id),
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
          Job(m.ref.job_id),
          string.inspect(m.committed_state),
        )
      },
    ),
    sinal.observe(
      grind_events.quarantined(),
      fn(_, m: grind_events.QuarantinedMetadata) {
        record("grind", "job.quarantined", Job(m.ref.job_id), "lease expired")
      },
    ),
    sinal.observe(
      grind_events.resolved(),
      fn(_, m: grind_events.ResolvedMetadata) {
        record(
          "grind",
          "job.resolved",
          Job(m.ref.job_id),
          string.inspect(m.decision),
        )
      },
    ),
    sinal.observe(
      grind_events.cancellation_decided(),
      fn(_, m: grind_events.CancellationMetadata) {
        record(
          "grind",
          "job.cancellation_decided",
          Job(m.ref.job_id),
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
          Job(m.ref.job_id),
          string.inspect(m.restored_state),
        )
      },
    ),
    // fabric
    sinal.observe(
      fabric_events.run_started(),
      fn(_, m: fabric_events.RunStarted) {
        record("fabric", "run.start", Run(m.run), m.agent)
      },
    ),
    sinal.observe(
      fabric_events.run_recovered(),
      fn(_, m: fabric_events.RunRecovered) {
        record(
          "fabric",
          "run.recover",
          Run(m.run),
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
          Run(m.run),
          "from " <> m.previous_owner,
        )
      },
    ),
    sinal.observe(fabric_events.model_turn(), fn(_, m: fabric_events.ModelTurn) {
      record(
        "fabric",
        "model.stop",
        Run(m.run),
        "turn " <> int.to_string(m.turn) <> " " <> string.inspect(m.result),
      )
    }),
    sinal.observe(
      fabric_events.tool_dispatched(),
      fn(_, m: fabric_events.ToolDispatched) {
        record("fabric", "tool.start", Run(m.action.run), m.action.tool)
      },
    ),
    sinal.observe(
      fabric_events.tool_settled(),
      fn(_, m: fabric_events.ToolSettled) {
        record(
          "fabric",
          "tool.stop",
          Run(m.action.run),
          m.action.tool <> " " <> string.inspect(m.disposition),
        )
      },
    ),
    sinal.observe(
      fabric_events.run_cancelled(),
      fn(_, m: fabric_events.RunCancelled) {
        record("fabric", "run.cancel", Run(m.run), "")
      },
    ),
    sinal.observe(
      fabric_events.run_finished(),
      fn(_, m: fabric_events.RunFinished) {
        record("fabric", "run.stop", Run(m.run), string.inspect(m.outcome))
      },
    ),
    sinal.observe(fabric_events.lease_lost(), fn(_, m: fabric_events.LeaseLost) {
      record("fabric", "lease.lose", Run(m.run), string.inspect(m.reason))
    }),
    // saga
    sinal.observe(saga_events.run_started(), fn(_, m: saga_events.RunMetadata) {
      record(
        "saga",
        "run.start",
        Unkeyed,
        m.workflow <> " run " <> int.to_string(m.run),
      )
    }),
    sinal.observe(
      saga_events.run_stopped(),
      fn(_, m: saga_events.RunStopMetadata) {
        record(
          "saga",
          "run.stop",
          Unkeyed,
          m.workflow <> " " <> string.inspect(m.outcome),
        )
      },
    ),
    sinal.observe(
      saga_events.step_stopped(),
      fn(_, m: saga_events.StepStopMetadata) {
        record(
          "saga",
          "step.stop",
          Unkeyed,
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
          Unkeyed,
          m.step <> " " <> string.inspect(m.result),
        )
      },
    ),
    // llm_wire
    sinal.observe(llm_events.observation_event(), fn(_, m: llm_events.Metadata) {
      record("llm_wire", m.stage, Unkeyed, m.provider <> " " <> m.outcome)
    }),
    // http_gun (only clients started with `observations: Some(forwarder)`)
    sinal.observe(http_events.event(), fn(_, m: http_events.Metadata) {
      let key = case m.correlation {
        Some(id) -> Http(id)
        None -> Unkeyed
      }
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

pub fn bind_job(
  telemetry: Option(Telemetry),
  job_id: Int,
  research: String,
) -> Nil {
  each(telemetry, BindJob(job_id, research))
}

pub fn bind_run(
  telemetry: Option(Telemetry),
  run: String,
  research: String,
) -> Nil {
  each(telemetry, BindRun(run, research))
}

pub fn bind_http(
  telemetry: Option(Telemetry),
  id: http_events.Id,
  research: String,
) -> Nil {
  each(telemetry, BindHttp(id, research))
}

fn each(telemetry: Option(Telemetry), message: Message) -> Nil {
  case telemetry {
    Some(t) -> process.send(t.collector, message)
    None -> Nil
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
  let #(events, runs, jobs, http) =
    process.call(telemetry.collector, 2000, Snapshot)
  let owner = fn(key) {
    case key {
      Research(id) -> Ok(id)
      Job(id) -> dict.get(jobs, id)
      Run(id) -> dict.get(runs, id)
      Http(id) -> dict.get(http, id)
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
    BindJob(id, research) ->
      actor.continue(
        State(..state, jobs: dict.insert(state.jobs, id, research)),
      )
    BindRun(id, research) ->
      actor.continue(
        State(..state, runs: dict.insert(state.runs, id, research)),
      )
    BindHttp(id, research) ->
      actor.continue(
        State(..state, http: dict.insert(state.http, id, research)),
      )
    Snapshot(reply) -> {
      process.send(reply, #(
        list.reverse(state.events),
        state.runs,
        state.jobs,
        state.http,
      ))
      actor.continue(state)
    }
  }
}

/// The `[fabric]` prefix routed through the app's forwarder keeps Fabric's
/// handlers out of its runners (see `fabric/observation`).
pub fn fabric_prefix() -> List(String) {
  ["fabric"]
}
