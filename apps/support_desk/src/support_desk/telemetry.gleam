//// Collects the Sinal events of every package the desk uses (fabric,
//// saga, http_gun and llm_wire; json_blueprint emits none) into one
//// timeline, and tries to follow one ticket across them.
////
//// What each package gives to join on:
////
//// - the desk itself: its own `Correlation` for the ticket, with the fabric
////   run id, in `ticket.opened` and `ticket.answered`.
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
//// events are attributed through the run id that `ticket.opened` pairs
//// with the ticket's correlation.

import fabric/observation as fabric_obs
import gleam/erlang/process.{type Subject}
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
import sinal/correlation.{type Correlation}
import sinal/forwarder
import support_desk/events

pub type Source {
  Desk
  Fabric
  Saga
  HttpGun
  LlmWire
}

/// What an event can be joined on.
pub type Key {
  /// A fabric run id.
  FabricRun(String)
  /// One of the desk's own ticket events: the ticket and its fabric run.
  TicketRun(ticket: Correlation, run: String)
  /// Saga's own run number; no caller id reaches saga's events.
  SagaRun(workflow: String, run: Int)
  /// An HTTP request, with the ticket its correlation was registered for.
  HttpRequest(ticket: Option(Correlation))
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
  Register(id: http_obs.Id, ticket: Correlation)
  Read(reply: Subject(List(Observation)))
}

type State {
  State(tickets: List(#(http_obs.Id, Correlation)), seen: List(Observation))
}

/// Starts the collector and a supervised forwarder for http_gun's
/// observations, and attaches to every event.
pub fn start() -> Result(Telemetry, String) {
  use collector <- result.try(start_collector())
  let fwd = forwarder.new(process.new_name("support_desk_http_events"))
  use _ <- result.map(
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(forwarder.supervised(fwd))
    |> supervisor.start
    |> result.replace_error("could not start the event forwarder"),
  )
  Telemetry(collector, fwd, handlers(collector))
}

/// The forwarder to put in `http_gun/config.Config.observations`.
pub fn forwarder(telemetry: Telemetry) -> forwarder.Forwarder {
  telemetry.forwarder
}

/// Attributes HTTP events carrying `id` to `ticket`.
pub fn register(
  telemetry: Telemetry,
  id: http_obs.Id,
  ticket: Correlation,
) -> Nil {
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

/// The events attributable to one ticket: its own events, its fabric
/// run's events and its correlated HTTP requests. Saga and llm_wire events
/// never qualify.
pub fn trail(telemetry: Telemetry, ticket: Correlation) -> List(Observation) {
  let all = observations(telemetry)
  let runs =
    list.filter_map(all, fn(observation) {
      case observation.key {
        TicketRun(owner, run) if owner == ticket -> Ok(run)
        _ -> Error(Nil)
      }
    })
  list.filter(all, fn(observation) {
    case observation.key {
      TicketRun(owner, _) -> owner == ticket
      FabricRun(id) -> list.contains(runs, id)
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
    Desk -> "desk    "
    Fabric -> "fabric  "
    Saga -> "saga    "
    HttpGun -> "http_gun"
    LlmWire -> "llm_wire"
  }
  let key = case observation.key {
    FabricRun(id) -> "run " <> id
    TicketRun(ticket, run) ->
      "ticket " <> correlation.to_string(ticket) <> ", run " <> run
    SagaRun(workflow, run) -> workflow <> "#" <> int.to_string(run)
    HttpRequest(Some(ticket)) -> "ticket " <> correlation.to_string(ticket)
    HttpRequest(None) -> "uncorrelated"
    Unkeyed -> "-"
  }
  source <> " " <> observation.name <> " [" <> key <> "] " <> observation.detail
}

// Handlers ----------------------------------------------------------------

fn handlers(collector: Subject(Message)) -> List(sinal.Attachment) {
  let fabric = fn(name, key, detail) {
    process.send(collector, Observed(Observation(Fabric, name, key, detail)))
  }
  let saga = fn(name, workflow, run, detail) {
    process.send(
      collector,
      Observed(Observation(Saga, name, SagaRun(workflow, run), detail)),
    )
  }
  let ticket = fn(name, metadata_ticket, run, detail) {
    case metadata_ticket {
      Some(ticket) ->
        process.send(
          collector,
          Observed(Observation(Desk, name, TicketRun(ticket, run), detail)),
        )
      None -> Nil
    }
  }
  [
    sinal.observe(events.ticket_opened(), fn(_, m) {
      ticket("ticket.opened", m.ticket, m.run, "")
    }),
    sinal.observe(events.ticket_answered(), fn(_, m) {
      ticket("ticket.answered", m.ticket, m.run, string.inspect(m.answer))
    }),
    sinal.observe(fabric_obs.run_started(), fn(_, m) {
      fabric("run.start", FabricRun(m.run), m.agent)
    }),
    sinal.observe(fabric_obs.model_turn(), fn(_, m) {
      fabric(
        "model.stop",
        FabricRun(m.run),
        "turn " <> int.to_string(m.turn) <> " " <> string.inspect(m.result),
      )
    }),
    sinal.observe(fabric_obs.approval_requested(), fn(_, m) {
      fabric("approval.request", FabricRun(m.action.run), m.action.tool)
    }),
    sinal.observe(fabric_obs.approval_answered(), fn(_, m) {
      fabric(
        "approval.answer",
        FabricRun(m.action.run),
        m.action.tool <> " " <> string.inspect(m.answer),
      )
    }),
    sinal.observe(fabric_obs.tool_dispatched(), fn(_, m) {
      fabric(
        "tool.start",
        FabricRun(m.action.run),
        m.action.tool <> " " <> m.action.call_id,
      )
    }),
    sinal.observe(fabric_obs.tool_settled(), fn(_, m) {
      fabric(
        "tool.stop",
        FabricRun(m.action.run),
        m.action.tool <> " " <> string.inspect(m.disposition),
      )
    }),
    sinal.observe(fabric_obs.settlement_refused(), fn(_, m) {
      fabric("tool.settlement.refuse", FabricRun(m.action.run), m.summary)
    }),
    sinal.observe(fabric_obs.run_cancelled(), fn(_, m) {
      fabric("run.cancel", FabricRun(m.run), "")
    }),
    sinal.observe(fabric_obs.run_finished(), fn(totals, m) {
      fabric(
        "run.stop",
        FabricRun(m.run),
        string.inspect(m.outcome)
          <> " after "
          <> int.to_string(totals.turns)
          <> " turns",
      )
    }),
    sinal.observe(saga_obs.run_started(), fn(_, m) {
      saga("run.start", m.workflow, m.run, "")
    }),
    sinal.observe(saga_obs.run_stopped(), fn(_, m) {
      saga("run.stop", m.workflow, m.run, string.inspect(m.outcome))
    }),
    sinal.observe(saga_obs.step_started(), fn(_, m) {
      saga("step.start", m.workflow, m.run, m.step)
    }),
    sinal.observe(saga_obs.step_stopped(), fn(_, m) {
      saga(
        "step.stop",
        m.workflow,
        m.run,
        m.step <> " " <> string.inspect(m.result),
      )
    }),
    sinal.observe(saga_obs.compensation_stopped(), fn(_, m) {
      saga(
        "step.compensate",
        m.workflow,
        m.run,
        m.step <> " " <> string.inspect(m.decision),
      )
    }),
    sinal.observe(saga_obs.undo_stopped(), fn(_, m) {
      saga(
        "step.undo",
        m.workflow,
        m.run,
        m.step <> " " <> string.inspect(m.result),
      )
    }),
    sinal.observe(http_obs.event(), fn(_, m) {
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
    sinal.observe(llm_obs.observation_event(), fn(_, m) {
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
