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
//// - saga: its own run counter, the workflow name and an optional
////   `Correlation` from `execution.with_correlation`. `fabric_saga.tool`
////   takes one `Config` at build time, so no per-ticket value reaches it.
//// - http_gun: a per-request id and the caller's `Correlation`
////   (`http_gun.with_correlation`), which is the ticket's own.
//// - llm_wire: stage, provider and outcome only; no id of any kind.
////
//// HTTP events of calls made with a ticket-correlated client carry the
//// ticket's `Correlation` and need no join. Fabric events are attributed
//// through the run id that `ticket.opened` pairs with the ticket's
//// correlation.

import fabric/observation as fabric_obs
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
  /// A fabric run id.
  FabricRun(String)
  /// One of the desk's own ticket events: the ticket and its fabric run.
  TicketRun(ticket: Correlation, run: String)
  /// Saga's own run number; no per-ticket id reaches saga's events.
  SagaRun(workflow: String, run: Int)
  /// An HTTP request, with the ticket its client was correlated with.
  HttpRequest(ticket: Option(Correlation))
  /// Nothing to join on.
  Unkeyed
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
