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
import fabric/approvers.{type Approvers}
import fabric/llm
import fabric/policy
import fabric/reviewer.{type Reviewer}
import fabric/run
import fabric/store.{type Store}
import fabric/tool
import gleam/erlang/process
import gleam/int
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import llm_wire
import llm_wire/openai
import saga_tool
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
  )
}

pub type Desk {
  Desk(
    store: Store,
    agent: Agent(Session, Resolution),
    shop: Shop,
    ledger: Ledger,
    approvers: Approvers(String),
  )
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
    /// Who may answer an approval, built once at boot: the agent and
    /// `approve`/`reject` share this value, and a proof from any other
    /// approvers is refused.
    approvers: Approvers(String),
    /// Adjusts the agent's spec before it is built: the limits, for one.
    tune: fn(agent.Spec(Session, Resolution)) -> agent.Spec(Session, Resolution),
  )
}

pub fn start(settings: Settings) -> Result(Desk, String) {
  let runs = store.in_memory(process.new_name("support_desk_runs"))
  use Nil <- result.try(
    store.start(runs)
    |> result.map_error(fn(error) { "store: " <> string.inspect(error) }),
  )
  use agent <- result.map(build(settings))
  Desk(runs, agent, settings.shop, settings.ledger, settings.approvers)
}

/// The one agent every ticket runs on. Each turn's request names its run's
/// correlation, and `fabric/llm.model` tags the client view with it.
pub fn build(settings: Settings) -> Result(Agent(Session, Resolution), String) {
  let config =
    openai.new("sk-scripted")
    |> openai.config
    |> llm_wire.with_endpoint(settings.provider_url)
  let model = llm.model(settings.llm_client, config, "gpt-4.1-mini")
  let issue_refund =
    saga_tool.tool(
      domain.issue_refund(),
      refund.workflow(settings.shop, settings.ledger),
      refund.config(),
      input: fn(_, _, request) { request },
      explain: refund.explain,
      rollback_within: duration.seconds(5),
    )
  let tools = [
    tool.bind(
      domain.lookup_order(),
      fn(_, call, query: OrderQuery) {
        shop.get_order(
          shop.correlated(settings.shop, call.correlation),
          query.order_id,
        )
      },
      explain_lookup,
    )
      // A read is safe to start again after a crash.
      |> tool.with_replay(3),
    tool.bind(
      domain.check_refund_eligibility(),
      fn(_, call, query: OrderQuery) {
        shop.get_order(
          shop.correlated(settings.shop, call.correlation),
          query.order_id,
        )
        |> result.map(eligibility)
      },
      explain_lookup,
    )
      |> tool.with_replay(3),
    issue_refund,
  ]
  agent.new("support_desk", model, tools, refund_policy)
  |> agent.with_system_prompt(system_prompt)
  |> agent.with_answer(domain.resolution())
  |> agent.with_approvers(settings.approvers)
  |> settings.tune
  |> agent.build
  |> result.map_error(fn(errors) {
    "agent: " <> agent.describe_config_errors(errors)
  })
}

/// A new ticket's session.
pub fn session(ticket: Correlation, approval_from_cents: Int) -> Session {
  Session(ticket, approval_from_cents)
}

/// What `open_ticket` did with the message.
pub type Message {
  /// The ticket had no run: this message started it.
  Applied
  /// The ticket's run was started by this same message: a retried open.
  Repeated
  /// The ticket's run was started by another message. This one was not
  /// applied: Fabric has no command to add a message to a run, so the
  /// caller must tell the customer or open a new ticket.
  NotApplied
}

pub type Opened {
  Opened(run: fabric.Run(Session, Resolution), message: Message)
}

/// Starts the ticket's run under an id derived from the ticket, with the
/// ticket as its correlation. Opening a ticket twice returns its one run
/// and stores nothing; `message` says whether this call's text reached it.
pub fn open_ticket(
  desk: Desk,
  session: Session,
  message: String,
) -> Result(Opened, fabric.Error) {
  let id = run.id_from_parts("ticket", [correlation.to_string(session.ticket)])
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
      Ok(Opened(handle, Applied))
    }
    Error(fabric.AlreadyStarted(id, same_input:)) ->
      fabric.open(desk.store, desk.agent, session, id)
      |> result.map(
        Opened(_, case same_input {
          True -> Repeated
          False -> NotApplied
        }),
      )
    Error(error) -> Error(error)
  }
}

/// Records the run's end as the ticket's `ticket.answered` event.
pub fn close(
  session: Session,
  handle: fabric.Run(Session, Resolution),
  outcome: run.Outcome(Resolution),
) -> Nil {
  let kind = case outcome {
    run.Completed(_) -> events.AnsweredTyped
    run.AnswerInvalid(..) -> events.AnsweredUntyped
    _ -> events.AnsweredNothing
  }
  events.answered(session.ticket, run.id_to_string(fabric.id(handle)), kind)
}

/// Why the desk did not record an answer to an approval.
pub type AnswerError {
  /// The credential proves no identity: absent, malformed, forged, expired
  /// or issued for another audience. Nothing reached fabric (401).
  NotAuthenticated(reason: String)
  /// The approver is authenticated but their token lacks the scope for this
  /// requirement. Nothing reached fabric (403).
  NotAuthorized(reason: String)
  /// The identity provider's keys are unreachable, so nothing was decided.
  /// Trying again may succeed (503).
  Unavailable(reason: String)
  /// The approver is authorized, and fabric refused the command.
  Refused(fabric.Error)
}

pub fn describe_answer_error(error: AnswerError) -> String {
  case error {
    NotAuthenticated(reason) -> "not authenticated: " <> reason
    NotAuthorized(reason) -> "not authorized: " <> reason
    Unavailable(reason) -> "the identity provider is unavailable: " <> reason
    Refused(error) -> fabric.describe_error(error)
  }
}

/// Approves a pending refund as the person the bearer token authenticates,
/// when the token carries `approve:<requirement name>`. A token that does
/// not never reaches fabric. Returns the reviewer that fabric recorded.
pub fn approve(
  desk: Desk,
  handle: fabric.Run(Session, Resolution),
  pending: run.PendingApproval,
  credential credential: String,
  context session: Session,
) -> Result(Reviewer, AnswerError) {
  use proof <- result.try(check(desk, pending, credential))
  fabric.approve(handle, pending.reference, proof:, context: session)
  |> result.map(fn(_) { approvers.reviewer(proof) })
  |> result.map_error(Refused)
}

/// Rejects a pending refund as the person the bearer token authenticates,
/// under the same scope check as `approve`.
pub fn reject(
  desk: Desk,
  handle: fabric.Run(Session, Resolution),
  pending: run.PendingApproval,
  credential credential: String,
  reason reason: String,
) -> Result(Reviewer, AnswerError) {
  use proof <- result.try(check(desk, pending, credential))
  fabric.reject(handle, pending.reference, proof:, reason:)
  |> result.map(fn(_) { approvers.reviewer(proof) })
  |> result.map_error(Refused)
}

fn check(
  desk: Desk,
  pending: run.PendingApproval,
  credential: String,
) -> Result(approvers.Proof, AnswerError) {
  approvers.check(desk.approvers, credential, pending.reference.requirement)
  |> result.map_error(fn(denial) {
    case denial {
      approvers.NotAuthenticated(reason) -> NotAuthenticated(reason)
      approvers.NotAuthorized(reason) -> NotAuthorized(reason)
      approvers.Unavailable(reason) -> Unavailable(reason)
    }
  })
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

const system_prompt = "You are a customer-support agent. Look the order up, check refund eligibility, and refund only when eligible. Never resubmit a refund whose outcome is unknown."

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
