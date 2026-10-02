//// Collects the Sinal events of every package the desk uses (fabric,
//// saga, http_gun and llm_wire; json_blueprint emits none) into one
//// timeline, and tries to follow one ticket across them.
////
//// What each package gives to join on:
////
//// - fabric: the run id, plus turn and call id for tool and approval
////   events.
//// - saga: its own run counter and the workflow name; nothing a caller
////   chose.
//// - http_gun: a per-request id and an optional caller correlation
////   (`http_gun.with_correlation`), an opaque VM-local value.
//// - llm_wire: stage, provider and outcome only; no id of any kind.
////
//// The desk registers each ticket's http_gun correlation here, so HTTP
//// events of calls made with a correlated client can be attributed. Fabric
//// events are attributed by the run id the app learns after `start`.

import fabric/observation as fabric_obs
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import http_gun/telemetry as http_obs
import llm_wire/telemetry as llm_obs
import saga/observation as saga_obs
import sinal
import sinal/forwarder

pub type Source {
  Fabric
  Saga
  HttpGun
  LlmWire
}

/// What an event can be joined on.
pub type Key {
  /// A fabric run id.
  FabricRun(String)
  /// Saga's own run number; no caller id reaches saga's events.
  SagaRun(workflow: String, run: Int)
  /// An HTTP request, with the ticket its correlation was registered for.
  HttpRequest(ticket: Option(String))
  /// Nothing to join on.
  Unkeyed
}

pub type Observation {
  Observation(source: Source, name: String, key: Key, detail: String)
}

pub opaque type Telemetry {
  Telemetry(
    collector: Subject(Message),
    forwarder: forwarder.Forwarder,
    attachments: List(sinal.Attachment),
  )
}

pub opaque type Message {
  Observed(Observation)
  ObservedHttp(name: String, correlation: Option(http_obs.Id), detail: String)
  Register(id: http_obs.Id, ticket: String)
  Read(reply: Subject(List(Observation)))
}

type State {
  State(tickets: List(#(http_obs.Id, String)), seen: List(Observation))
}

/// Starts the collector and a supervised forwarder for http_gun's
/// observations, and attaches to every event.
pub fn start() -> Result(Telemetry, String) {
  use collector <- result.try(start_collector())
  use fwd <- result.try(
    forwarder.new(process.new_name("support_desk_http_events"), 1024)
    |> result.replace_error("invalid forwarder capacity"),
  )
  use _ <- result.try(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(forwarder.supervised(fwd))
    |> supervisor.start
    |> result.replace_error("could not start the event forwarder"),
  )
  let suffix = string.inspect(reference.new())
  use attachments <- result.map(
    list.try_map(handlers(collector), fn(attach) { attach(suffix) }),
  )
  Telemetry(collector, fwd, attachments)
}

/// The forwarder to put in `http_gun/config.Config.observations`.
pub fn forwarder(telemetry: Telemetry) -> forwarder.Forwarder {
  telemetry.forwarder
}

/// Attributes HTTP events carrying `id` to `ticket`.
pub fn register(telemetry: Telemetry, id: http_obs.Id, ticket: String) -> Nil {
  process.send(telemetry.collector, Register(id, ticket))
}

pub fn observations(telemetry: Telemetry) -> List(Observation) {
  // http_gun delivers through the forwarder: let it drain first.
  process.sleep(50)
  process.call(telemetry.collector, 1000, Read)
}

pub fn stop(telemetry: Telemetry) -> Nil {
  list.each(telemetry.attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
}

/// The events attributable to one ticket: its fabric run's events and its
/// correlated HTTP requests. Saga and llm_wire events never qualify.
pub fn trail(
  telemetry: Telemetry,
  ticket: String,
  run_id: String,
) -> List(Observation) {
  observations(telemetry)
  |> list.filter(fn(observation) {
    case observation.key {
      FabricRun(id) -> id == run_id
      HttpRequest(Some(owner)) -> owner == ticket
      _ -> False
    }
  })
}

/// Events seen per source, attributable or not.
pub fn count(observations: List(Observation), source: Source) -> Int {
  list.count(observations, fn(observation) { observation.source == source })
}

pub fn render(observation: Observation) -> String {
  let source = case observation.source {
    Fabric -> "fabric  "
    Saga -> "saga    "
    HttpGun -> "http_gun"
    LlmWire -> "llm_wire"
  }
  let key = case observation.key {
    FabricRun(id) -> "run " <> id
    SagaRun(workflow, run) -> workflow <> "#" <> int.to_string(run)
    HttpRequest(Some(ticket)) -> "ticket " <> ticket
    HttpRequest(None) -> "uncorrelated"
    Unkeyed -> "-"
  }
  source <> " " <> observation.name <> " [" <> key <> "] " <> observation.detail
}

// Handlers ----------------------------------------------------------------

fn handlers(
  collector: Subject(Message),
) -> List(fn(String) -> Result(sinal.Attachment, String)) {
  let fabric = fn(name, key, detail) {
    process.send(collector, Observed(Observation(Fabric, name, key, detail)))
  }
  let saga = fn(name, workflow, run, detail) {
    process.send(
      collector,
      Observed(Observation(Saga, name, SagaRun(workflow, run), detail)),
    )
  }
  [
    observe("fabric.run.start", fabric_obs.run_started(), fn(_, m) {
      fabric("run.start", FabricRun(m.run), m.agent)
    }),
    observe("fabric.model.stop", fabric_obs.model_turn(), fn(_, m) {
      fabric(
        "model.stop",
        FabricRun(m.run),
        "turn " <> int.to_string(m.turn) <> " " <> string.inspect(m.result),
      )
    }),
    observe(
      "fabric.approval.request",
      fabric_obs.approval_requested(),
      fn(_, m) {
        fabric("approval.request", FabricRun(m.action.run), m.action.tool)
      },
    ),
    observe("fabric.approval.answer", fabric_obs.approval_answered(), fn(_, m) {
      fabric(
        "approval.answer",
        FabricRun(m.action.run),
        m.action.tool <> " " <> string.inspect(m.answer),
      )
    }),
    observe("fabric.tool.start", fabric_obs.tool_dispatched(), fn(_, m) {
      fabric(
        "tool.start",
        FabricRun(m.action.run),
        m.action.tool <> " " <> m.action.call_id,
      )
    }),
    observe("fabric.tool.stop", fabric_obs.tool_settled(), fn(_, m) {
      fabric(
        "tool.stop",
        FabricRun(m.action.run),
        m.action.tool <> " " <> string.inspect(m.disposition),
      )
    }),
    observe("fabric.settlement", fabric_obs.settlement_refused(), fn(_, m) {
      fabric("tool.settlement.refuse", FabricRun(m.action.run), m.summary)
    }),
    observe("fabric.run.cancel", fabric_obs.run_cancelled(), fn(_, m) {
      fabric("run.cancel", FabricRun(m.run), "")
    }),
    observe("fabric.run.stop", fabric_obs.run_finished(), fn(totals, m) {
      fabric(
        "run.stop",
        FabricRun(m.run),
        string.inspect(m.outcome)
          <> " after "
          <> int.to_string(totals.turns)
          <> " turns",
      )
    }),
    observe("saga.run.start", saga_obs.run_started(), fn(_, m) {
      saga("run.start", m.workflow, m.run, "")
    }),
    observe("saga.run.stop", saga_obs.run_stopped(), fn(_, m) {
      saga("run.stop", m.workflow, m.run, string.inspect(m.outcome))
    }),
    observe("saga.step.start", saga_obs.step_started(), fn(_, m) {
      saga("step.start", m.workflow, m.run, m.step)
    }),
    observe("saga.step.stop", saga_obs.step_stopped(), fn(_, m) {
      saga(
        "step.stop",
        m.workflow,
        m.run,
        m.step <> " " <> string.inspect(m.result),
      )
    }),
    observe("saga.compensate", saga_obs.compensation_stopped(), fn(_, m) {
      saga(
        "step.compensate",
        m.workflow,
        m.run,
        m.step <> " " <> string.inspect(m.decision),
      )
    }),
    observe("saga.undo", saga_obs.undo_stopped(), fn(_, m) {
      saga(
        "step.undo",
        m.workflow,
        m.run,
        m.step <> " " <> string.inspect(m.result),
      )
    }),
    observe("http_gun.lifecycle", http_obs.event(), fn(_, m) {
      case m.milestone {
        // Only the outcome-bearing milestones; admission steps are noise.
        http_obs.ResponseHeaders(status) ->
          process.send(
            collector,
            ObservedHttp(
              "response.headers",
              m.correlation,
              int.to_string(status),
            ),
          )
        http_obs.HttpTerminated(outcome) ->
          process.send(
            collector,
            ObservedHttp("terminated", m.correlation, string.inspect(outcome)),
          )
        _ -> Nil
      }
    }),
    observe("llm_wire.observation", llm_obs.observation_event(), fn(_, m) {
      process.send(
        collector,
        Observed(Observation(
          LlmWire,
          m.stage,
          Unkeyed,
          m.provider <> " " <> m.outcome,
        )),
      )
    }),
  ]
}

fn observe(
  name: String,
  event: sinal.Event(m, d),
  handler: fn(m, d) -> Nil,
) -> fn(String) -> Result(sinal.Attachment, String) {
  fn(suffix) {
    let assert Ok(id) = sinal.handler_id("support_desk." <> name <> suffix)
    sinal.observe(id, event, handler)
    |> result.map_error(fn(error) {
      "could not attach " <> name <> ": " <> string.inspect(error)
    })
  }
}

// Collector ---------------------------------------------------------------

fn start_collector() -> Result(Subject(Message), String) {
  actor.new(State([], []))
  |> actor.on_message(fn(state: State, message) {
    case message {
      Observed(observation) ->
        actor.continue(State(..state, seen: [observation, ..state.seen]))
      ObservedHttp(name, correlation, detail) -> {
        let ticket =
          option.then(correlation, fn(id) {
            list.key_find(state.tickets, id) |> option.from_result
          })
        let observation =
          Observation(HttpGun, name, HttpRequest(ticket), detail)
        actor.continue(State(..state, seen: [observation, ..state.seen]))
      }
      Register(id, ticket) ->
        actor.continue(
          State(..state, tickets: [#(id, ticket), ..state.tickets]),
        )
      Read(reply) -> {
        process.send(reply, list.reverse(state.seen))
        actor.continue(state)
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error("could not start the telemetry collector")
}
