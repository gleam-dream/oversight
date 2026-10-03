import fabric
import fabric/agent
import fabric/run
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit
import saga/execution
import sinal/correlation
import sinal/fields
import support_desk
import support_desk/app.{type App}
import support_desk/desk
import support_desk/domain
import support_desk/events
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
  let assert Ok(ticket) = correlation.from_string(ticket)
  let session = desk.session(app.desk, ticket, approval_from_cents)
  let assert Ok(handle) = desk.open_ticket(app.desk, session, message)
  #(session, handle)
}

fn awaiting_refund_approval(
  handle: fabric.Run(desk.Session),
) -> run.PendingApproval {
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, within: duration.seconds(10))
  assert pending.tool == "issue_refund"
  assert pending.reference.requirement == desk.approver
  pending
}

fn finish(handle: fabric.Run(desk.Session)) -> domain.Resolution {
  let assert Ok(run.Finished(outcome)) =
    fabric.await(handle, within: duration.seconds(10))
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
  let assert Ok(app) =
    app.start_with(limits, shop_deadline: duration.seconds(1))
  let #(_, handle) =
    open(app, "T-2", "Please refund order A-100, it arrived broken.", 5000)
  let resolved = finish(handle)
  assert resolved.outcome == domain.Refunded
  let assert [_] = ledger.entries(app.ledger)
  app.stop(app)
}

pub fn a_turn_limit_ends_the_run_without_a_typed_answer_test() {
  let limits = agent.Limits(..agent.default_limits(), max_turns: 2)
  let assert Ok(app) =
    app.start_with(limits, shop_deadline: duration.seconds(1))
  let #(_, handle) = open(app, "T-3", "Refund order A-100.", 0)
  let assert Ok(run.Finished(outcome)) =
    fabric.await(handle, within: duration.seconds(10))
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
  // step marks that error with `saga.unknown_when`, and fabric_saga turns
  // the unknown effect into an uncertain one: no model turn until reconciled.
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(handle, within: duration.seconds(10))
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

pub fn telemetry_follows_the_ticket_through_every_package_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-9", "Please refund order A-100.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(_) =
    fabric.approve(handle, pending.reference, reviewer: None, context: session)
  let assert Ok(run.Finished(outcome)) =
    fabric.await(handle, within: duration.seconds(10))
  let assert desk.Resolved(_) = desk.close(session, handle, outcome)
  let trail = telemetry.trail(app.telemetry, session.ticket)
  let names = list.map(trail, fn(o) { o.name })
  assert list.contains(names, "ticket.opened")
  assert list.contains(names, "ticket.answered")
  assert list.contains(names, "approval.request")
  assert list.contains(names, "run.stop")
  // The ticket is the run's correlation, so every package that takes one
  // carries it: fabric's events, the model's four turns (two HTTP events
  // each), the two lookups (two each) and, from the saga, the refund and
  // notify calls (two each).
  assert telemetry.count(trail, telemetry.HttpGun) == 16
  assert telemetry.count(trail, telemetry.Saga) > 0

  // Nothing is left over: the one ticket's trail is every event.
  let all = telemetry.observations(app.telemetry)
  assert telemetry.unattributed(all) == []
  assert list.length(trail) == list.length(all)
  app.stop(app)
}

pub fn one_agent_serves_two_tickets_and_keeps_their_events_apart_test() {
  let assert Ok(app) = app.start()
  let #(first, one) = open(app, "T-11", "Please refund order A-100.", 0)
  let #(second, two) = open(app, "T-12", "Order A-300 never worked.", 0)
  let one_pending = awaiting_refund_approval(one)
  let two_pending = awaiting_refund_approval(two)
  let assert Ok(_) =
    fabric.approve(one, one_pending.reference, reviewer: None, context: first)
  let assert Ok(_) =
    fabric.approve(two, two_pending.reference, reviewer: None, context: second)
  let _ = finish(one)
  let _ = finish(two)
  let all = telemetry.observations(app.telemetry)
  assert telemetry.unattributed(all) == []
  let first_trail = telemetry.trail(app.telemetry, first.ticket)
  let second_trail = telemetry.trail(app.telemetry, second.ticket)
  assert list.length(first_trail) + list.length(second_trail)
    == list.length(all)
  // The refund and notify calls of each ticket carry that ticket.
  assert list.any(first_trail, fn(o) { string.contains(o.detail, "201") })
  assert list.any(second_trail, fn(o) { string.contains(o.detail, "201") })
  app.stop(app)
}

pub fn opening_a_ticket_twice_returns_its_one_run_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-13", "Please refund order A-100.", 0)
  let assert Ok(again) = desk.open_ticket(app.desk, session, "a second try")
  assert fabric.id(again) == fabric.id(handle)
  let opened =
    telemetry.trail(app.telemetry, session.ticket)
    |> list.count(fn(o) { o.name == "ticket.opened" })
  assert opened == 1
  app.stop(app)
}

pub fn every_answer_kind_round_trips_through_the_event_fields_test() {
  let ticket = correlation.unique()
  list.each(
    [events.AnsweredTyped, events.AnsweredUntyped, events.AnsweredNothing],
    fn(answer) {
      let metadata = events.TicketAnswered(ticket, "run-1", answer)
      let raw = fields.encode(events.answer(), metadata)
      assert fields.decode(events.answer(), raw) == Ok(metadata)
    },
  )
}

pub fn the_turn_limit_is_recorded_as_an_answer_of_nothing_test() {
  let limits = agent.Limits(..agent.default_limits(), max_turns: 2)
  let assert Ok(app) =
    app.start_with(limits, shop_deadline: duration.seconds(1))
  let #(session, handle) = open(app, "T-10", "Refund order A-100.", 0)
  let assert Ok(run.Finished(outcome)) =
    fabric.await(handle, within: duration.seconds(10))
  let assert desk.Ended(_) = desk.close(session, handle, outcome)
  let trail = telemetry.trail(app.telemetry, session.ticket)
  let assert Ok(answered) =
    list.find(trail, fn(o) { o.name == "ticket.answered" })
  assert answered.detail == "AnsweredNothing"
  app.stop(app)
}

// Seam evidence: saga names a returned "may have happened" error ------------

pub fn saga_names_a_returned_unknown_payment_as_an_unknown_effect_test() {
  let assert Ok(app) = app.start()
  let request = domain.RefundRequest("A-400", 3000, "late provider")
  let workflow = refund.workflow(app.ledger)
  let assert Ok(outcome) =
    execution.run(
      workflow,
      refund.Refund(app.desk.shop, request),
      refund.config(),
    )
  // The provider took the refund and answered after the client deadline.
  // The step marks that error with `saga.unknown_when`, so saga records the
  // attempt as an unknown effect and, with no decider and no `on_unknown`,
  // ends the run `Unresolved` and undoes nothing; fabric_saga reports it as
  // uncertain rather than as a failure the model may retry.
  let assert execution.Unresolved(_, shop.PaymentOutcomeUnknown(_), settlement) =
    outcome
  assert settlement.undone == []
  let assert [
    execution.UnknownEffect(
      action: execution.StepAttempt(1),
      ending: execution.ActionReturnedUnknown,
      ..,
    ),
  ] = execution.unknown_effects(outcome)
  assert ledger.entries(app.ledger) == []
  app.stop(app)
}
