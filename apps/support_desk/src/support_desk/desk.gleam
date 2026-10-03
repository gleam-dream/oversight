//// The support agent: three typed tools, a refund policy with a human
//// approval gate, and a typed final answer.
////
//// One json_blueprint codec per record (`support_desk/domain`) feeds one
//// `tool.Definition` per tool. Fabric derives the model's tool
//// declarations from it through its llm_wire adapter, decodes arguments
//// with it, and the policy matches the refund through it. No llm_wire tool
//// declaration is written here.

import fabric
import fabric/agent.{type Agent}
import fabric/llm
import fabric/policy
import fabric/run
import fabric/store.{type Store}
import fabric/tool
import fabric_saga
import gleam/erlang/process
import gleam/int
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import json/blueprint/codec
import llm_wire
import llm_wire/openai
import sinal/correlation.{type Correlation}
import support_desk/domain.{
  type Eligibility, type OrderQuery, type Resolution, Eligibility,
}
import support_desk/events
import support_desk/ledger.{type Ledger}
import support_desk/refund
import support_desk/shop.{
  type LookupError, type Shop, NoSuchOrder, OrdersUnavailable,
}

/// The per-ticket context every tool and policy decision receives.
pub type Session {
  Session(
    /// The ticket's correlation: the desk's `ticket.*` events carry it, and
    /// `open_ticket` starts the ticket's run with it, so fabric, the model
    /// calls, the tools' HTTP calls and the refund saga join it too.
    ticket: Correlation,
    /// Refunds of at least this many cents need a human approver; 0 means
    /// every refund does.
    approval_from_cents: Int,
    shop: Shop,
  )
}

pub type Desk {
  Desk(store: Store, agent: Agent(Session), shop: Shop, ledger: Ledger)
}

/// The requirement a refund approver answers.
pub const approver = run.Requirement("refund-approver", 1)

pub type Settings {
  Settings(
    /// The caller-owned client the model's requests go through.
    llm_client: http_gun.Client,
    /// Base URL of the OpenAI-compatible provider, ending in `/v1`.
    provider_url: String,
    shop: Shop,
    ledger: Ledger,
    limits: agent.Limits,
  )
}

pub fn start(settings: Settings) -> Result(Desk, String) {
  let runs = store.in_memory(process.new_name("support_desk_runs"))
  use Nil <- result.try(
    store.start(runs)
    |> result.map_error(fn(error) { "store: " <> string.inspect(error) }),
  )
  use agent <- result.map(build(settings))
  Desk(runs, agent, settings.shop, settings.ledger)
}

/// The one agent every ticket runs on. Each turn's request names its run's
/// correlation, and `fabric/llm.model` tags the client view with it.
pub fn build(settings: Settings) -> Result(Agent(Session), String) {
  let config =
    openai.new("sk-scripted")
    |> openai.config
    |> llm_wire.with_endpoint(settings.provider_url)
  let model = llm.model(settings.llm_client, config, "gpt-4.1-mini")
  let issue_refund =
    fabric_saga.tool(
      domain.issue_refund(),
      refund.workflow(settings.ledger),
      refund.config(),
      input: fn(session: Session, call, request) {
        refund.Refund(shop.correlated(session.shop, call.correlation), request)
      },
      explain: refund.explain,
      rollback_within: duration.seconds(5),
    )
  let tools = [
    tool.bind(
      domain.lookup_order(),
      fn(session: Session, call, query: OrderQuery) {
        shop.get_order(
          shop.correlated(session.shop, call.correlation),
          query.order_id,
        )
      },
      explain_lookup,
    ),
    tool.bind(
      domain.check_refund_eligibility(),
      fn(session: Session, call, query: OrderQuery) {
        shop.get_order(
          shop.correlated(session.shop, call.correlation),
          query.order_id,
        )
        |> result.map(eligibility)
      },
      explain_lookup,
    ),
    issue_refund,
  ]
  agent.new("support_desk", model, tools, refund_policy)
  |> agent.with_system_prompt(system_prompt())
  |> agent.with_limits(settings.limits)
  |> agent.build
  |> result.map_error(fn(errors) { "agent: " <> string.inspect(errors) })
}

/// A new ticket's session.
pub fn session(
  desk: Desk,
  ticket: Correlation,
  approval_from_cents: Int,
) -> Session {
  Session(ticket, approval_from_cents, desk.shop)
}

/// Starts the ticket's run under an id derived from the ticket, with the
/// ticket as its correlation. Opening a ticket twice returns the one run:
/// the second start is `AlreadyStarted` and stores nothing.
pub fn open_ticket(
  desk: Desk,
  session: Session,
  message: String,
) -> Result(fabric.Run(Session), fabric.StartError) {
  let key = "ticket-" <> correlation.to_string(session.ticket)
  use id <- result.try(
    run.parse_id(key)
    |> result.replace_error(fabric.StartRefused(
      "the ticket id is not a valid run id: " <> key,
    )),
  )
  case
    fabric.start(
      desk.store,
      desk.agent,
      id:,
      context: session,
      prompt: message,
      correlation: Some(session.ticket),
    )
  {
    Ok(handle) -> {
      events.opened(session.ticket, run.id_to_string(id))
      Ok(handle)
    }
    Error(fabric.AlreadyStarted(id)) ->
      fabric.open(desk.store, desk.agent, session, id)
      |> result.map_error(fn(error) {
        fabric.StartRefused(
          "the ticket's run cannot be opened: " <> string.inspect(error),
        )
      })
    Error(error) -> Error(error)
  }
}

/// The run's final answer, decoded with `answer`, recorded as the ticket's
/// `ticket.answered` event.
pub fn close(
  session: Session,
  handle: fabric.Run(Session),
  outcome: run.Outcome,
) -> Answer {
  let decoded = answer(outcome)
  let kind = case decoded {
    Resolved(_) -> events.AnsweredTyped
    Untyped(..) -> events.AnsweredUntyped
    Ended(_) -> events.AnsweredNothing
  }
  events.answered(session.ticket, run.id_to_string(fabric.id(handle)), kind)
  decoded
}

/// Refunds at or above the session's threshold wait for an approver.
pub fn refund_policy(
  session: Session,
  action: policy.Action,
) -> Result(policy.Decision, String) {
  use refund <- result.map(tool.input(domain.issue_refund(), action))
  case refund {
    Some(request) if request.amount_cents >= session.approval_from_cents ->
      policy.RequireApproval(approver)
    _ -> policy.Allow
  }
}

fn eligibility(order: domain.Order) -> Eligibility {
  case order.status {
    "delivered" ->
      Eligibility(order.order_id, True, order.total_cents, "delivered")
    status -> Eligibility(order.order_id, False, 0, "order is " <> status)
  }
}

/// Reads are safe to repeat, so every lookup failure is definite.
fn explain_lookup(error: LookupError) -> tool.Failure {
  case error {
    NoSuchOrder(id) -> tool.Explain("there is no order " <> id)
    OrdersUnavailable(detail) ->
      tool.Explain("the orders API is unavailable: " <> detail)
  }
}

// Typed final answer ------------------------------------------------------

pub type Answer {
  /// The agent finished with a `Resolution`.
  Resolved(Resolution)
  /// The agent finished with text that is not a `Resolution`.
  Untyped(text: String, problem: String)
  /// The run ended some other way.
  Ended(run.Outcome)
}

fn system_prompt() -> String {
  let assert Ok(schema) = codec.schema_json(domain.resolution())
  "You are a customer-support agent. Look the order up, check refund "
  <> "eligibility, and refund only when eligible. Never resubmit a refund "
  <> "whose outcome is unknown. Finish with one JSON object, and nothing "
  <> "else, matching this JSON Schema: "
  <> schema
}

/// The run's outcome as the desk's typed answer: Fabric returns text, so
/// the app decodes it with the same codec the schema came from.
pub fn answer(outcome: run.Outcome) -> Answer {
  case outcome {
    run.Completed(text) ->
      case codec.decode_json(domain.resolution(), text) {
        Ok(resolution) -> Resolved(resolution)
        Error(error) -> Untyped(text, codec.describe_decode_error(error))
      }
    other -> Ended(other)
  }
}

pub fn describe(resolution: Resolution) -> String {
  let outcome = case resolution.outcome {
    domain.Refunded -> "refunded"
    domain.Declined -> "declined"
    domain.NotEligible -> "not eligible"
    domain.RefundFailed -> "failed"
    domain.Unconfirmed -> "unconfirmed"
  }
  resolution.order_id
  <> " "
  <> outcome
  <> " ("
  <> int.to_string(resolution.refunded_cents)
  <> " cents): "
  <> resolution.message
}
