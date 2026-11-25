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
////   that `saga_tool.tool` sets from the tool call's.
//// - http_gun: a per-request id and the caller's `Correlation`
////   (`http_gun.with_correlation`): the tools set the call's.
//// - llm_wire: a call id and the `Correlation` of the http_gun client view
////   the call ran on: `fabric/llm` sets the run's per turn.
////
//// Every event of a ticket therefore carries the ticket's `Correlation`
//// and needs no join.

import fabric/telemetry as fabric_obs
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor as supervisor
import gleam/result
import gleam/string
import http_gun/telemetry as http_obs
import llm_wire/telemetry as llm_obs
import saga/telemetry as saga_obs
import sinal
import sinal/collector
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

/// How many observations the collector keeps; older ones are overwritten.
pub const capacity = 4096

/// A supervised `sinal/collector` over every event. Its process attaches
/// the handlers and owns them, so they are attached exactly while it runs.
pub opaque type Telemetry {
  Telemetry(recent: collector.Collector(Observation), supervisor: process.Pid)
}

/// Starts the collector under a supervisor of its own. http_gun emits
/// through `sinal.emit` like the other packages, so no forwarder is needed:
/// the handler only writes one entry.
pub fn start() -> Result(Telemetry, String) {
  let recent =
    collector.new(process.new_name("support_desk_telemetry"))
    |> collector.with_capacity(capacity)
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(collector.supervised(recent, sources()))
  |> supervisor.start
  |> result.map(fn(started) { Telemetry(recent:, supervisor: started.pid) })
  |> result.replace_error("could not start the telemetry collector")
}

/// The observations the collector holds, oldest first: at most
/// `capacity`. Empty once it has stopped.
pub fn observations(telemetry: Telemetry) -> List(Observation) {
  collector.entries(telemetry.recent)
}

/// Stops the collector and waits for it. Sinal detaches the handlers its
/// process owned.
pub fn stop(telemetry: Telemetry) -> Nil {
  let monitor = process.monitor(telemetry.supervisor)
  process.unlink(telemetry.supervisor)
  process.kill(telemetry.supervisor)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive_forever
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

fn sources() -> List(collector.Source(Observation)) {
  let fabric = fn(name, key, detail) { Observation(Fabric, name, key, detail) }
  let saga = fn(name, workflow, run, ticket, detail) {
    Observation(Saga, name, SagaRun(workflow, run, ticket), detail)
  }
  let ticket = fn(name, ticket, run, detail) {
    Observation(Desk, name, TicketRun(ticket, run), detail)
  }
  [
    collector.source(events.ticket_opened(), fn(_, m) {
      ticket("ticket.opened", m.ticket, m.run, "")
    }),
    collector.source(events.ticket_answered(), fn(_, m) {
      ticket("ticket.answered", m.ticket, m.run, string.inspect(m.answer))
    }),
    collector.source(fabric_obs.run_started(), fn(_, m) {
      fabric("run.start", FabricRun(m.run, m.correlation), m.agent)
    }),
    collector.source(fabric_obs.model_turn(), fn(_, m) {
      fabric(
        "model.stop",
        FabricRun(m.run, m.correlation),
        "turn " <> int.to_string(m.turn) <> " " <> string.inspect(m.result),
      )
    }),
    collector.source(fabric_obs.approval_requested(), fn(_, m) {
      fabric(
        "approval.request",
        FabricRun(m.action.run, m.correlation),
        m.action.tool,
      )
    }),
    collector.source(fabric_obs.approval_answered(), fn(_, m) {
      fabric(
        "approval.answer",
        FabricRun(m.action.run, m.correlation),
        m.action.tool <> " " <> string.inspect(m.answer),
      )
    }),
    collector.source(fabric_obs.tool_dispatched(), fn(_, m) {
      fabric(
        "tool.start",
        FabricRun(m.action.run, m.correlation),
        m.action.tool <> " " <> m.action.call_id,
      )
    }),
    collector.source(fabric_obs.tool_settled(), fn(_, m) {
      fabric(
        "tool.stop",
        FabricRun(m.action.run, m.correlation),
        m.action.tool <> " " <> string.inspect(m.disposition),
      )
    }),
    collector.source(fabric_obs.settlement_refused(), fn(_, m) {
      fabric(
        "tool.settlement.refuse",
        FabricRun(m.action.run, m.correlation),
        m.summary,
      )
    }),
    collector.source(fabric_obs.run_cancelled(), fn(_, m) {
      fabric("run.cancel", FabricRun(m.run, m.correlation), "")
    }),
    collector.source(fabric_obs.run_finished(), fn(totals, m) {
      fabric(
        "run.stop",
        FabricRun(m.run, m.correlation),
        string.inspect(m.outcome)
          <> " after "
          <> int.to_string(totals.turns)
          <> " turns",
      )
    }),
    collector.source(saga_obs.run_started(), fn(_, m) {
      saga("run.start", m.workflow, m.run, m.correlation, "")
    }),
    collector.source(saga_obs.run_stopped(), fn(_, m) {
      saga(
        "run.stop",
        m.workflow,
        m.run,
        m.correlation,
        string.inspect(m.outcome),
      )
    }),
    collector.source(saga_obs.step_started(), fn(_, m) {
      saga("step.start", m.workflow, m.run, m.correlation, m.step)
    }),
    collector.source(saga_obs.step_stopped(), fn(_, m) {
      saga(
        "step.stop",
        m.workflow,
        m.run,
        m.correlation,
        m.step <> " " <> string.inspect(m.result),
      )
    }),
    collector.source(saga_obs.compensation_stopped(), fn(_, m) {
      saga(
        "step.compensate",
        m.workflow,
        m.run,
        m.correlation,
        m.step <> " " <> string.inspect(m.decision),
      )
    }),
    collector.source(saga_obs.undo_stopped(), fn(_, m) {
      saga(
        "step.undo",
        m.workflow,
        m.run,
        m.correlation,
        m.step <> " " <> string.inspect(m.result),
      )
    }),
    collector.source_with(fn(keep) {
      use _, m <- sinal.subscription(http_obs.event())
      let http = fn(name, detail) {
        keep(Observation(HttpGun, name, HttpRequest(m.correlation), detail))
      }
      case m.client, m.milestone {
        // Hellhound's own client ("hellhound") sends the approvers' sign-in and
        // key requests. They belong to a person's sign-in, which spans
        // tickets, so they are not a ticket's events.
        Some("hellhound"), _ -> Nil
        // Only the outcome-bearing milestones; admission steps are noise.
        _, http_obs.ResponseHeaders(status) ->
          http("response.headers", int.to_string(status))
        _, http_obs.HttpTerminated(outcome) ->
          http("terminated", string.inspect(outcome))
        _, _ -> Nil
      }
    }),
    collector.source(llm_obs.event(), fn(_, m) {
      Observation(
        LlmWire,
        llm_obs.stage_name(m.stage),
        ModelCall(m.correlation),
        m.provider <> " " <> llm_obs.outcome_name(m.outcome),
      )
    }),
  ]
}
