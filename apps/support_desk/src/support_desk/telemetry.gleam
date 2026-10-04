//// Collects the Sinal events of every package the desk uses (fabric,
//// saga, http_gun and llm_wire; json_blueprint emits none) into one
//// timeline, and tries to follow one ticket across them.
////
//// What each package gives to join on:
////
//// - the desk itself: its own `Correlation` for the ticket, with the fabric
////   run id, in `ticket.opened` and `ticket.answered`.
//// - fabric: the run id and the run's `Correlation`, which the desk sets to
////   the ticket's when it starts the run.
//// - saga: its own run counter, the workflow name and the `Correlation`
////   that `fabric_saga.tool` sets from the tool call's.
//// - http_gun: a per-request id and the caller's `Correlation`
////   (`http_gun.with_correlation`): the tools set the call's.
//// - llm_wire: a call id and the `Correlation` of the http_gun client view
////   the call ran on: `fabric/llm` sets the run's per turn.
////
//// Every event of a ticket therefore carries the ticket's `Correlation`
//// and needs no join.

import fabric/telemetry as fabric_obs
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import http_gun/telemetry as http_obs
import llm_wire/telemetry as llm_obs
import saga/telemetry as saga_obs
import sinal
import sinal/correlation.{type Correlation}
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
  /// A fabric run id, with the ticket the run was started under.
  FabricRun(run: String, ticket: Correlation)
  /// One of the desk's own ticket events: the ticket and its fabric run.
  TicketRun(ticket: Correlation, run: String)
  /// Saga's own run number, with the ticket its run was configured with.
  SagaRun(workflow: String, run: Int, ticket: Correlation)
  /// An HTTP request, with the ticket its client was correlated with.
  HttpRequest(ticket: Option(Correlation))
  /// A model call, with the ticket its client view was correlated with.
  ModelCall(ticket: Option(Correlation))
}

pub type Observation {
  Observation(source: Source, name: String, key: Key, detail: String)
}

pub opaque type Telemetry {
  Telemetry(collector: Subject(Message), attachments: List(sinal.Attachment))
}

pub opaque type Message {
  Observed(Observation)
  Read(reply: Subject(List(Observation)))
}

/// Starts the collector and attaches to every event. http_gun emits
/// through `sinal.emit` like the other packages, so no forwarder is needed:
/// the handler only sends a message.
pub fn start() -> Result(Telemetry, String) {
  use collector <- result.map(start_collector())
  Telemetry(collector, handlers(collector))
}

pub fn observations(telemetry: Telemetry) -> List(Observation) {
  process.call(telemetry.collector, 1000, Read)
}

pub fn stop(telemetry: Telemetry) -> Nil {
  list.each(telemetry.attachments, fn(attachment) {
    let _ = sinal.detach(attachment)
    Nil
  })
}

/// The ticket an event belongs to: the correlation it carries.
pub fn ticket_of(observation: Observation) -> Option(Correlation) {
  case observation.key {
    TicketRun(owner, _) -> Some(owner)
    FabricRun(_, owner) -> Some(owner)
    SagaRun(_, _, owner) -> Some(owner)
    HttpRequest(owner) -> owner
    ModelCall(owner) -> owner
  }
}

/// The events attributable to one ticket: every event whose correlation
/// is the ticket's.
pub fn trail(telemetry: Telemetry, ticket: Correlation) -> List(Observation) {
  list.filter(observations(telemetry), fn(observation) {
    ticket_of(observation) == Some(ticket)
  })
}

/// The events that carry no ticket.
pub fn unattributed(observations: List(Observation)) -> List(Observation) {
  list.filter(observations, fn(observation) { ticket_of(observation) == None })
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
    FabricRun(id, _) -> "run " <> id
    TicketRun(ticket, run) ->
      "ticket " <> correlation.to_string(ticket) <> ", run " <> run
    SagaRun(workflow, run, _) -> workflow <> "#" <> int.to_string(run)
    HttpRequest(Some(ticket)) -> "ticket " <> correlation.to_string(ticket)
    HttpRequest(None) -> "uncorrelated"
    ModelCall(Some(ticket)) -> "ticket " <> correlation.to_string(ticket)
    ModelCall(None) -> "uncorrelated"
  }
  source <> " " <> observation.name <> " [" <> key <> "] " <> observation.detail
}

// Handlers ----------------------------------------------------------------

fn handlers(collector: Subject(Message)) -> List(sinal.Attachment) {
  let fabric = fn(name, key, detail) {
    process.send(collector, Observed(Observation(Fabric, name, key, detail)))
  }
  let saga = fn(name, workflow, run, ticket, detail) {
    process.send(
      collector,
      Observed(Observation(Saga, name, SagaRun(workflow, run, ticket), detail)),
    )
  }
  let ticket = fn(name, ticket, run, detail) {
    process.send(
      collector,
      Observed(Observation(Desk, name, TicketRun(ticket, run), detail)),
    )
  }
  [
    sinal.observe(events.ticket_opened(), fn(_, m) {
      ticket("ticket.opened", m.ticket, m.run, "")
    }),
    sinal.observe(events.ticket_answered(), fn(_, m) {
      ticket("ticket.answered", m.ticket, m.run, string.inspect(m.answer))
    }),
    sinal.observe(fabric_obs.run_started(), fn(_, m) {
      fabric("run.start", FabricRun(m.run, m.correlation), m.agent)
    }),
    sinal.observe(fabric_obs.model_turn(), fn(_, m) {
      fabric(
        "model.stop",
        FabricRun(m.run, m.correlation),
        "turn " <> int.to_string(m.turn) <> " " <> string.inspect(m.result),
      )
    }),
    sinal.observe(fabric_obs.approval_requested(), fn(_, m) {
      fabric(
        "approval.request",
        FabricRun(m.action.run, m.correlation),
        m.action.tool,
      )
    }),
    sinal.observe(fabric_obs.approval_answered(), fn(_, m) {
      fabric(
        "approval.answer",
        FabricRun(m.action.run, m.correlation),
        m.action.tool <> " " <> string.inspect(m.answer),
      )
    }),
    sinal.observe(fabric_obs.tool_dispatched(), fn(_, m) {
      fabric(
        "tool.start",
        FabricRun(m.action.run, m.correlation),
        m.action.tool <> " " <> m.action.call_id,
      )
    }),
    sinal.observe(fabric_obs.tool_settled(), fn(_, m) {
      fabric(
        "tool.stop",
        FabricRun(m.action.run, m.correlation),
        m.action.tool <> " " <> string.inspect(m.disposition),
      )
    }),
    sinal.observe(fabric_obs.settlement_refused(), fn(_, m) {
      fabric(
        "tool.settlement.refuse",
        FabricRun(m.action.run, m.correlation),
        m.summary,
      )
    }),
    sinal.observe(fabric_obs.run_cancelled(), fn(_, m) {
      fabric("run.cancel", FabricRun(m.run, m.correlation), "")
    }),
    sinal.observe(fabric_obs.run_finished(), fn(totals, m) {
      fabric(
        "run.stop",
        FabricRun(m.run, m.correlation),
        string.inspect(m.outcome)
          <> " after "
          <> int.to_string(totals.turns)
          <> " turns",
      )
    }),
    sinal.observe(saga_obs.run_started(), fn(_, m) {
      saga("run.start", m.workflow, m.run, m.correlation, "")
    }),
    sinal.observe(saga_obs.run_stopped(), fn(_, m) {
      saga(
        "run.stop",
        m.workflow,
        m.run,
        m.correlation,
        string.inspect(m.outcome),
      )
    }),
    sinal.observe(saga_obs.step_started(), fn(_, m) {
      saga("step.start", m.workflow, m.run, m.correlation, m.step)
    }),
    sinal.observe(saga_obs.step_stopped(), fn(_, m) {
      saga(
        "step.stop",
        m.workflow,
        m.run,
        m.correlation,
        m.step <> " " <> string.inspect(m.result),
      )
    }),
    sinal.observe(saga_obs.compensation_stopped(), fn(_, m) {
      saga(
        "step.compensate",
        m.workflow,
        m.run,
        m.correlation,
        m.step <> " " <> string.inspect(m.decision),
      )
    }),
    sinal.observe(saga_obs.undo_stopped(), fn(_, m) {
      saga(
        "step.undo",
        m.workflow,
        m.run,
        m.correlation,
        m.step <> " " <> string.inspect(m.result),
      )
    }),
    sinal.observe(http_obs.event(), fn(_, m) {
      let http = fn(name, detail) {
        process.send(
          collector,
          Observed(Observation(
            HttpGun,
            name,
            HttpRequest(m.correlation),
            detail,
          )),
        )
      }
      case m.milestone {
        // Only the outcome-bearing milestones; admission steps are noise.
        http_obs.ResponseHeaders(status) ->
          http("response.headers", int.to_string(status))
        http_obs.HttpTerminated(outcome) ->
          http("terminated", string.inspect(outcome))
        _ -> Nil
      }
    }),
    sinal.observe(llm_obs.event(), fn(_, m) {
      process.send(
        collector,
        Observed(Observation(
          LlmWire,
          llm_obs.stage_name(m.stage),
          ModelCall(m.correlation),
          m.provider <> " " <> llm_obs.outcome_name(m.outcome),
        )),
      )
    }),
  ]
}

// Collector ---------------------------------------------------------------

fn start_collector() -> Result(Subject(Message), String) {
  actor.new([])
  |> actor.on_message(fn(seen: List(Observation), message) {
    case message {
      Observed(observation) -> actor.continue([observation, ..seen])
      Read(reply) -> {
        process.send(reply, list.reverse(seen))
        actor.continue(seen)
      }
    }
  })
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error("could not start the telemetry collector")
}
