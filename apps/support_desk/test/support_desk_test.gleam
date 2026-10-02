import fabric
import fabric/agent
import fabric/run
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import saga/execution
import support_desk
import support_desk/app.{type App}
import support_desk/desk
import support_desk/domain
import support_desk/ledger
import support_desk/provider
import support_desk/refund
import support_desk/services
import support_desk/shop
import support_desk/telemetry

pub fn main() -> Nil {
  gleeunit.main()
}

// Helpers -------------------------------------------------------------------

fn open(
  app: App,
  ticket: String,
  message: String,
  approval_from_cents: Int,
) -> #(desk.Session, fabric.Run(desk.Session)) {
  let session = desk.session(app.desk, ticket, approval_from_cents)
  telemetry.register(app.telemetry, session.correlation, ticket)
  let assert Ok(handle) = desk.open_ticket(app.desk, session, message)
  #(session, handle)
}

fn awaiting_refund_approval(
  handle: fabric.Run(desk.Session),
) -> run.PendingApproval {
  let assert Ok(run.Suspended([pending], [])) = fabric.await(handle, 10_000)
  assert pending.tool == "issue_refund"
  assert pending.reference.requirement == desk.approver
  pending
}

fn finish(handle: fabric.Run(desk.Session)) -> domain.Resolution {
  let assert Ok(run.Finished(outcome)) = fabric.await(handle, 10_000)
  let assert desk.Resolved(resolution) = desk.answer(outcome)
  resolution
}

// Common path ---------------------------------------------------------------

pub fn approved_refund_runs_the_saga_and_resolves_typed_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) =
    open(app, "T-1", "Please refund order A-100, it arrived broken.", 0)
  let pending = awaiting_refund_approval(handle)
  // Nothing is refunded before a person approves.
  assert services.calls_matching(app.services, "POST /payments") == []

  let assert Ok(_) =
    fabric.approve(
      handle,
      pending.reference,
      reviewer: Some("alice"),
      context: session,
    )
  let resolved = finish(handle)
  assert resolved.outcome == domain.Refunded
  assert resolved.refunded_cents == 2500
  let assert [entry] = ledger.entries(app.ledger)
  assert entry.refund_id == "rf_A-100"
  assert services.calls_matching(app.services, "POST")
    == ["POST /payments/refunds A-100", "POST /notify A-100"]

  // One codec per tool reached the provider as its declaration: the
  // refund amount's range came from `integer_between`.
  let assert [first, ..] = provider.requests(app.provider)
  assert string.contains(first, "\"name\":\"issue_refund\"")
  assert string.contains(first, "\"minimum\":1")
  // The approver is on the record, not in the saga's ledger entry.
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert Ok(refund) =
    list.find(snapshot.actions, fn(action) {
      action.call.name == "issue_refund"
    })
  let assert [run.Approval(reviewer: Some("alice"), answer: run.Approve, ..)] =
    refund.approvals
  app.stop(app)
}

// Advanced configuration ----------------------------------------------------

pub fn refunds_below_the_threshold_skip_approval_test() {
  let limits = agent.Limits(..agent.default_limits(), max_turns: 6)
  let assert Ok(app) = app.start_with(limits, shop_deadline_ms: 1000)
  let #(_, handle) =
    open(app, "T-2", "Please refund order A-100, it arrived broken.", 5000)
  let resolved = finish(handle)
  assert resolved.outcome == domain.Refunded
  let assert [_] = ledger.entries(app.ledger)
  app.stop(app)
}

pub fn a_turn_limit_ends_the_run_without_a_typed_answer_test() {
  let limits = agent.Limits(..agent.default_limits(), max_turns: 2)
  let assert Ok(app) = app.start_with(limits, shop_deadline_ms: 1000)
  let #(_, handle) = open(app, "T-3", "Refund order A-100.", 0)
  let assert Ok(run.Finished(outcome)) = fabric.await(handle, 10_000)
  assert desk.answer(outcome)
    == desk.Ended(run.BudgetExhausted(run.TurnLimit(2)))
  app.stop(app)
}

// Failure paths -------------------------------------------------------------

pub fn rejected_refund_is_explained_by_the_agent_test() {
  let assert Ok(app) = app.start()
  let #(_, handle) = open(app, "T-4", "Refund A-200 please.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(_) =
    fabric.reject(
      handle,
      pending.reference,
      reason: "over the goodwill limit",
      reviewer: Some("carol"),
    )
  let resolved = finish(handle)
  assert resolved.outcome == domain.Declined
  assert string.contains(resolved.message, "over the goodwill limit")
  assert services.calls_matching(app.services, "POST") == []
  app.stop(app)
}

pub fn failed_notification_compensates_the_refund_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-5", "Order A-300 never worked.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, reviewer: None, context: session)
  let resolved = finish(handle)
  // The saga rolled back in reverse: ledger entry removed, refund voided,
  // and fabric_saga reported it as a definite failure the model explains.
  assert resolved.outcome == domain.RefundFailed
  assert string.contains(resolved.message, "voided")
  assert ledger.entries(app.ledger) == []
  assert services.calls_matching(app.services, "POST")
    == [
      "POST /payments/refunds A-300",
      "POST /notify A-300",
      "POST /payments/void rf_A-300",
    ]
  app.stop(app)
}

pub fn unknown_payment_outcome_pauses_the_run_until_reconciled_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-6", "Refund order A-400 please.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, reviewer: None, context: session)
  // http_gun's deadline fired after the request may have been sent; the
  // saga held the step instead of compensating, and fabric_saga turned
  // `Unresolved` into an uncertain effect: no model turn until reconciled.
  let assert Ok(run.Suspended([], [uncertain])) = fabric.await(handle, 10_000)
  assert uncertain.tool == "issue_refund"
  assert string.contains(uncertain.evidence, "refund_payment")
  assert ledger.entries(app.ledger) == []
  assert services.calls_matching(app.services, "POST /payments/void") == []

  let assert Ok(_) =
    fabric.reconcile(handle, uncertain.reference, support_desk.unconfirmed)
  let resolved = finish(handle)
  assert resolved.outcome == domain.Unconfirmed
  assert resolved.refunded_cents == 0
  app.stop(app)
}

pub fn invalid_tool_input_never_reaches_the_policy_test() {
  let assert Ok(app) = app.start()
  let #(_, handle) = open(app, "T-7", "I want my money back for A-500.", 0)
  let resolved = finish(handle)
  assert resolved.outcome == domain.RefundFailed
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert Ok(refund) =
    list.find(snapshot.actions, fn(action) {
      action.call.name == "issue_refund"
    })
  let assert run.InvalidArguments(detail) = refund.state
  assert detail != ""
  assert refund.approvals == []
  assert services.calls_matching(app.services, "POST") == []
  app.stop(app)
}

pub fn cancelling_while_awaiting_approval_refunds_nothing_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-8", "Refund order A-100.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(run.Finished(run.Cancelled)) = fabric.cancel(handle)
  // The pending approval is void: a late approver changes nothing.
  let assert Error(fabric.RunEnded) =
    fabric.approve(
      handle,
      pending.reference,
      reviewer: Some("alice"),
      context: session,
    )
  assert services.calls_matching(app.services, "POST") == []
  assert ledger.entries(app.ledger) == []
  app.stop(app)
}

// Telemetry -----------------------------------------------------------------

pub fn telemetry_follows_agent_and_tool_http_but_not_the_saga_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-9", "Please refund order A-100.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, reviewer: None, context: session)
  let _ = finish(handle)
  let run_id = run.id_to_string(fabric.id(handle))
  let trail = telemetry.trail(app.telemetry, "T-9", run_id)
  let names = list.map(trail, fn(o) { o.name })
  // Fabric's events carry the run id; the lookups' HTTP calls carry the
  // ticket's correlation because the tool handler receives the session.
  assert list.contains(names, "approval.request")
  assert list.contains(names, "run.stop")
  assert telemetry.count(trail, telemetry.HttpGun) == 4

  let all = telemetry.observations(app.telemetry)
  // The saga ran (3 steps), but nothing in its events names the ticket or
  // run, and its HTTP calls (refund, notify) are uncorrelated, like every
  // model call.
  assert telemetry.count(all, telemetry.Saga) > 0
  assert telemetry.count(trail, telemetry.Saga) == 0
  assert telemetry.count(trail, telemetry.LlmWire) == 0
  let uncorrelated =
    list.count(all, fn(o) { o.key == telemetry.HttpRequest(None) })
  assert uncorrelated > 0
  app.stop(app)
}

// Seam evidence: saga calls a returned "may have happened" error known ------

pub fn saga_reports_a_returned_unknown_payment_as_known_unless_held_test() {
  let assert Ok(app) = app.start()
  let shop = app.desk.shop
  let request = domain.RefundRequest("A-400", 3000, "late provider")
  let aborting = refund.workflow_with(shop, app.ledger, refund.AbortUnknown)
  let assert Ok(outcome) = execution.run(aborting, request, refund.config())
  // The provider did take the refund, yet saga reports a clean, fully
  // known failure: fabric_saga would hand the model a definite `Explain`.
  let assert execution.Failed(
    execution.StepFailed(_, shop.PaymentOutcomeUnknown(_)),
    _,
  ) = outcome
  assert execution.unknown_effects(outcome) == []

  let holding = refund.workflow_with(shop, app.ledger, refund.HoldUnknown)
  let assert Ok(execution.Unresolved(..) as held) =
    execution.run(holding, request, refund.config())
  assert execution.unknown_effects(held) == []
  app.stop(app)
}
