import fabric
import fabric/agent
import fabric/approvers as fabric_approvers
import fabric/reviewer
import fabric/run
import fabric/store
import gleam/erlang/process
import gleam/http/request
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleeunit
import http_gun
import http_gun/config as http_config
import http_gun/destination
import saga/execution
import saga/telemetry as saga_events
import sinal
import sinal/correlation
import sinal/fields
import support_desk
import support_desk/app.{type App}
import support_desk/approvers
import support_desk/desk
import support_desk/domain.{type Resolution}
import support_desk/events
import support_desk/ledger
import support_desk/provider
import support_desk/refund
import support_desk/services
import support_desk/shop
import support_desk/telemetry
import warden/resource
import warden/testing

pub fn main() -> Nil {
  gleeunit.main()
}

/// Each boot owns fresh listeners, recorders and an in-memory execution store.
/// Stopping one desk must release them before another desk is started.
pub fn repeated_stop_releases_owned_resources_test() {
  list.each([1, 2], fn(_) {
    let before = linked_processes()
    let handlers = ticket_handler_count()
    let assert Ok(app) = app.start()
    let owned = owned_since(before)
    let assert Ok(service_recorder) = process.subject_owner(app.services.calls)
    let assert Ok(provider_recorder) =
      process.subject_owner(app.provider.requests)
    // This independent client remains usable after app.client is stopped.
    let assert Ok(probe) =
      http_config.default()
      |> http_config.with_destination(destination.loopback_only())
      |> http_gun.start
    assert get(probe, app.services.base_url <> "/orders/A-100") |> result.is_ok
    assert get(probe, app.provider.base_url) |> result.is_ok
    let assert Ok(Nil) = app.stop(app)
    assert !process.is_alive(service_recorder)
    assert !process.is_alive(provider_recorder)
    assert store.readiness(app.desk.store) |> result.is_error
    assert get(probe, app.services.base_url <> "/orders/A-100")
      |> result.is_error
    assert get(probe, app.provider.base_url) |> result.is_error
    assert get(app.client, app.services.base_url) |> result.is_error
    assert ticket_handler_count() == handlers
    list.each(owned, assert_stopped)
    http_gun.stop(probe)
  })
}

pub fn rejected_configuration_unwinds_partial_startup_test() {
  let before = linked_processes()
  let handlers = ticket_handler_count()
  let acquired = process.new_subject()
  let refused =
    app.start_with(
      fn(spec) {
        // This public tuning callback runs after the other resources started.
        process.send(acquired, owned_since(before))
        agent.with_max_turns(spec, 0)
      },
      shop_deadline: duration.seconds(1),
    )
  let assert Error(error) = refused
  assert string.starts_with(error, "agent:")
  let assert Ok(owned) = process.receive(acquired, 1000)
  assert owned != []
  list.each(owned, assert_stopped)
  assert ticket_handler_count() == handlers
}

pub fn stopping_suspended_ticket_retires_its_store_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-stop-pending", "Refund A-100", 0)
  let _ = awaiting_refund_approval(handle)
  assert services.calls_matching(app.services, "POST /payments") == []
  let assert Ok(Nil) = app.stop(app)
  assert fabric.snapshot(handle) |> result.is_error
  assert desk.open_ticket(app.desk, session, "Refund A-100") |> result.is_error
}

pub fn stopping_active_refund_drains_before_releasing_borrowed_resources_test() {
  stop_active_refund(False)
}

pub fn forced_drain_waits_for_saga_cleanup_before_releasing_resources_test() {
  stop_active_refund(True)
}

fn stop_active_refund(force_drain: Bool) -> Nil {
  let assert Ok(app) =
    app.start_with(fn(spec) { spec }, shop_deadline: duration.seconds(3))
  let app = case force_drain {
    False -> app
    True -> {
      // Exercise the public Store contract with the same app-owned callbacks.
      let assert Ok(Nil) = store.stop(app.desk.store)
      let assert Ok(runs) =
        store.in_memory(process.new_name("support_desk_short_drain"))
        |> store.with_drain(duration.milliseconds(1))
      let assert Ok(Nil) = store.start(runs)
      app.App(..app, desk: desk.Desk(..app.desk, store: runs))
    }
  }
  let assert Ok(ticket) = correlation.from_string("T-stop-active")
  let settled = process.new_subject()
  let attachment =
    sinal.observe(saga_events.run_stopped(), fn(_, metadata) {
      case metadata.correlation == ticket {
        True ->
          process.send(settled, #(
            metadata.outcome,
            ledger.entries(app.ledger),
            get(app.client, app.services.base_url <> "/orders/A-100")
              |> result.is_ok,
          ))
        False -> Nil
      }
    })
  let session = desk.session(ticket, 100_000)
  let assert Ok(_) = desk.open_ticket(app.desk, session, "Refund A-400")
  wait_for_payment(app.services, 300)
  let assert Ok(Nil) = app.stop(app)
  let assert Ok(#(outcome, entries, True)) = process.receive(settled, 1000)
  case force_drain {
    False -> {
      assert outcome == saga_events.OutcomeCompleted
      let assert [entry] = entries
      assert entry.order_id == "A-400"
    }
    True -> {
      assert outcome == saga_events.OutcomeCancelled
      assert entries == []
    }
  }
  let assert Ok(Nil) = sinal.detach(attachment)
  Nil
}

fn get(client: http_gun.Client, url: String) -> Result(http_gun.Buffered, Nil) {
  let assert Ok(request) = request.to(url)
  http_gun.send(client, request.set_body(request, <<>>))
  |> result.replace_error(Nil)
}

fn wait_for_payment(services: services.Services, attempts: Int) -> Nil {
  case services.calls_matching(services, "POST /payments/refunds A-400") {
    [] -> {
      assert attempts > 0
      process.sleep(10)
      wait_for_payment(services, attempts - 1)
    }
    [_] -> Nil
    _ -> panic as "the payment was submitted more than once"
  }
}

fn owned_since(before: List(process.Pid)) -> List(process.Pid) {
  linked_processes() |> list.filter(fn(pid) { !list.contains(before, pid) })
}

fn assert_stopped(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  let assert Ok(Nil) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  assert !process.is_alive(pid)
}

@external(erlang, "support_desk_lifecycle_test_ffi", "linked_processes")
fn linked_processes() -> List(process.Pid)

@external(erlang, "support_desk_lifecycle_test_ffi", "ticket_handler_count")
fn ticket_handler_count() -> Int

// Helpers -------------------------------------------------------------------

fn open(
  app: App,
  ticket: String,
  message: String,
  approval_from_cents: Int,
) -> #(desk.Session, fabric.Run(desk.Session, Resolution)) {
  let assert Ok(ticket) = correlation.from_string(ticket)
  let session = desk.session(ticket, approval_from_cents)
  let assert Ok(desk.Opened(run: handle, message: desk.Applied)) =
    desk.open_ticket(app.desk, session, message)
  #(session, handle)
}

/// The approver signs in at the scripted OIDC provider and holds the
/// access token it issued.
fn signed_in(app: App, subject: String) -> String {
  let assert Ok(credential) = app.sign_in(app, subject)
  credential
}

fn awaiting_refund_approval(
  handle: fabric.Run(desk.Session, Resolution),
) -> run.PendingApproval {
  let assert Ok(run.Suspended([pending], [])) =
    fabric.await(handle, within: duration.seconds(10))
  assert pending.tool == "issue_refund"
  assert pending.reference.requirement == desk.approver
  pending
}

fn finish(handle: fabric.Run(desk.Session, Resolution)) -> Resolution {
  let assert Ok(run.Finished(run.Completed(resolution))) =
    fabric.await(handle, within: duration.seconds(10))
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

  let assert Ok(approver) =
    desk.approve(app.desk, handle, pending, signed_in(app, "alice"), session)
  assert reviewer.subject(approver) == "alice"
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
  // The answer's schema reached the provider as its output format, not as
  // prose in the prompt.
  assert string.contains(first, "\"type\":\"json_schema\"")
  assert !string.contains(first, "JSON Schema")
  // The approver is on the record, not in the saga's ledger entry.
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert Ok(refund) =
    list.find(snapshot.actions, fn(action) {
      action.call.name == "issue_refund"
    })
  let assert [
    run.Approval(
      reviewer: Some(who),
      answer: run.Approve,
      verifier: Some(verifier),
      ..,
    ),
  ] = refund.approvals
  assert reviewer.subject(who) == "alice"
  assert reviewer.issuer(who) == Some(testing.issuer(app.identity))
  // The name the approvers were built with.
  assert verifier == "warden"
  let assert Ok(Nil) = app.stop(app)
}

// Advanced configuration ----------------------------------------------------

pub fn refunds_below_the_threshold_skip_approval_test() {
  let assert Ok(app) =
    app.start_with(
      agent.with_max_turns(_, 6),
      shop_deadline: duration.seconds(1),
    )
  let #(_, handle) =
    open(app, "T-2", "Please refund order A-100, it arrived broken.", 5000)
  let resolved = finish(handle)
  assert resolved.outcome == domain.Refunded
  let assert [_] = ledger.entries(app.ledger)
  let assert Ok(Nil) = app.stop(app)
}

pub fn a_turn_limit_ends_the_run_without_a_typed_answer_test() {
  let assert Ok(app) =
    app.start_with(
      agent.with_max_turns(_, 2),
      shop_deadline: duration.seconds(1),
    )
  let #(_, handle) = open(app, "T-3", "Refund order A-100.", 0)
  let assert Ok(run.Finished(outcome)) =
    fabric.await(handle, within: duration.seconds(10))
  assert outcome == run.BudgetExhausted(run.TurnLimit(2))
  let assert Ok(Nil) = app.stop(app)
}

pub fn a_refused_answer_gets_one_corrective_turn_test() {
  let assert Ok(app) = app.start()
  let #(_, handle) = open(app, "T-14", "Refund order A-600 please.", 0)
  let resolved = finish(handle)
  assert resolved.outcome == domain.NotEligible
  // lookup, eligibility, the prose answer, and the corrected answer
  let requests = provider.requests(app.provider)
  assert list.length(requests) == 4
  let assert Ok(last) = list.last(requests)
  assert string.contains(last, "Your final answer could not be read")
  let assert Ok(Nil) = app.stop(app)
}

pub fn one_answer_attempt_ends_on_the_refused_answer_test() {
  let assert Ok(app) =
    app.start_with(
      fn(spec) { spec |> agent.with_answer_attempts(1) },
      shop_deadline: duration.seconds(1),
    )
  let #(session, handle) = open(app, "T-15", "Refund order A-600 please.", 0)
  let assert Ok(run.Finished(outcome)) =
    fabric.await(handle, within: duration.seconds(10))
  let assert run.AnswerInvalid(raw:, reason:) = outcome
  assert string.contains(raw, "cannot be refunded")
  assert reason != ""
  desk.close(session, handle, outcome)
  let assert Ok(answered) =
    telemetry.trail(app.telemetry, session.ticket)
    |> list.find(fn(o) { o.name == "ticket.answered" })
  assert answered.detail == "AnsweredUntyped"
  let assert Ok(Nil) = app.stop(app)
}

// Failure paths -------------------------------------------------------------

pub fn rejected_refund_is_explained_by_the_agent_test() {
  let assert Ok(app) = app.start()
  let #(_, handle) = open(app, "T-4", "Refund A-200 please.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(_) =
    desk.reject(
      app.desk,
      handle,
      pending,
      signed_in(app, "carol"),
      reason: "over the goodwill limit",
    )
  let resolved = finish(handle)
  assert resolved.outcome == domain.Declined
  assert string.contains(resolved.message, "over the goodwill limit")
  assert services.calls_matching(app.services, "POST") == []
  let assert Ok(Nil) = app.stop(app)
}

pub fn failed_notification_compensates_the_refund_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-5", "Order A-300 never worked.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(_) =
    desk.approve(app.desk, handle, pending, signed_in(app, "alice"), session)
  let resolved = finish(handle)
  // The saga rolled back in reverse: ledger entry removed, refund voided,
  // and the saga recipe reported it as a definite failure the model explains.
  assert resolved.outcome == domain.RefundFailed
  assert string.contains(resolved.message, "voided")
  assert ledger.entries(app.ledger) == []
  assert services.calls_matching(app.services, "POST")
    == [
      "POST /payments/refunds A-300",
      "POST /notify A-300",
      "POST /payments/void rf_A-300",
    ]
  let assert Ok(Nil) = app.stop(app)
}

pub fn unknown_payment_outcome_pauses_the_run_until_reconciled_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-6", "Refund order A-400 please.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(_) =
    desk.approve(app.desk, handle, pending, signed_in(app, "alice"), session)
  // http_gun's deadline fired after the request may have been sent; the
  // step marks that error with `saga.unknown_when`, and the saga recipe turns
  // the unknown effect into an uncertain one: no model turn until reconciled.
  let assert Ok(run.Suspended([], [uncertain])) =
    fabric.await(handle, within: duration.seconds(10))
  assert uncertain.tool == "issue_refund"
  assert string.contains(uncertain.evidence, "refund_payment")
  assert ledger.entries(app.ledger) == []
  assert services.calls_matching(app.services, "POST /payments/void") == []

  let assert Ok(_) =
    fabric.reconcile(handle, uncertain.reference, support_desk.unconfirmed())
  let resolved = finish(handle)
  assert resolved.outcome == domain.Unconfirmed
  assert resolved.refunded_cents == 0
  let assert Ok(Nil) = app.stop(app)
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
  let assert Ok(Nil) = app.stop(app)
}

pub fn cancelling_while_awaiting_approval_refunds_nothing_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-8", "Refund order A-100.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(run.Finished(run.Cancelled)) = fabric.cancel(handle)
  // The pending approval is void: a late approver changes nothing.
  let assert Error(error) =
    desk.approve(app.desk, handle, pending, signed_in(app, "alice"), session)
  assert error == desk.Refused(fabric.RunEnded)
  assert services.calls_matching(app.services, "POST") == []
  assert ledger.entries(app.ledger) == []
  let assert Ok(Nil) = app.stop(app)
}

// Approver authentication ---------------------------------------------------

/// Answers the pending refund with `credential`, expects the desk to refuse
/// it before fabric sees it, and checks that nothing moved: the approval is
/// still pending, no approval is recorded and no refund was paid.
fn refused_and_still_pending(
  app: App,
  handle: fabric.Run(desk.Session, Resolution),
  session: desk.Session,
  credential: String,
) -> desk.AnswerError {
  let pending = awaiting_refund_approval(handle)
  let assert Error(error) =
    desk.approve(app.desk, handle, pending, credential, session)
  // The same approval can still be answered: fabric never saw the refusal.
  let _ = awaiting_refund_approval(handle)
  let assert Ok(snapshot) = fabric.snapshot(handle)
  let assert Ok(refund) =
    list.find(snapshot.actions, fn(action) {
      action.call.name == "issue_refund"
    })
  assert refund.approvals == []
  assert services.calls_matching(app.services, "POST") == []
  error
}

pub fn an_approval_without_a_credential_is_refused_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-16", "Refund order A-100.", 0)
  let assert desk.NotAuthenticated(_) =
    refused_and_still_pending(app, handle, session, app.anonymous)
  // Rejecting needs the same authentication.
  let pending = awaiting_refund_approval(handle)
  let assert Error(desk.NotAuthenticated(_)) =
    desk.reject(app.desk, handle, pending, app.anonymous, reason: "no")
  // A signed-in approver then answers it.
  let assert Ok(_) =
    desk.approve(app.desk, handle, pending, signed_in(app, "alice"), session)
  assert finish(handle).outcome == domain.Refunded
  let assert Ok(Nil) = app.stop(app)
}

pub fn an_expired_token_is_refused_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-17", "Refund order A-100.", 0)
  let expired =
    testing.access_token("alice")
    |> testing.with_audiences([app.audience])
    |> testing.with_scopes(["approve:" <> desk.approver.name])
    |> testing.with_ttl(duration.seconds(-60))
    |> testing.issue_access_token(app.identity, _)
  let assert desk.NotAuthenticated(reason) =
    refused_and_still_pending(app, handle, session, expired)
  assert string.contains(reason, "expired")
  let assert Ok(Nil) = app.stop(app)
}

pub fn invalid_tokens_are_refused_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-18", "Refund order A-100.", 0)
  let mint = fn(spec) { testing.issue_access_token(app.identity, spec) }
  // Carries the approver scope, so only the forgery is at fault.
  let valid = fn() {
    testing.access_token("mallory")
    |> testing.with_audiences([app.audience])
    |> testing.with_scopes(["approve:" <> desk.approver.name])
  }
  let refuse = fn(token) {
    let assert desk.NotAuthenticated(_) =
      refused_and_still_pending(app, handle, session, token)
    Nil
  }
  // Unsigned, signed by an unpublished key, and not a token at all.
  refuse(mint(testing.forged(valid(), testing.UnsignedToken)))
  refuse(mint(testing.forged(valid(), testing.UnknownKey)))
  refuse("alice")
  // A token that claims another issuer.
  refuse(mint(testing.with_issuer(valid(), "https://evil.test")))
  // A genuine token minted for another resource.
  refuse(mint(testing.with_audiences(valid(), ["https://billing.test"])))
  let assert Ok(Nil) = app.stop(app)
}

pub fn a_signed_in_approver_without_the_scope_is_not_authorized_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-19", "Refund order A-100.", 0)
  // mallory signs in at the provider like anyone, but is granted `openid`
  // only. The token is genuine; it may not answer `refund-approver`.
  let mallory = signed_in(app, "mallory")
  let assert desk.NotAuthorized(reason) =
    refused_and_still_pending(app, handle, session, mallory)
  assert string.contains(reason, "approve:refund-approver")
  // Rejecting is refused the same way, and the approval stays pending.
  let pending = awaiting_refund_approval(handle)
  let assert Error(desk.NotAuthorized(_)) =
    desk.reject(app.desk, handle, pending, mallory, reason: "no")
  let _ = awaiting_refund_approval(handle)
  assert services.calls_matching(app.services, "POST") == []
  // alice, granted the scope, answers it.
  let assert Ok(_) =
    desk.approve(app.desk, handle, pending, signed_in(app, "alice"), session)
  assert finish(handle).outcome == domain.Refunded
  let assert Ok(Nil) = app.stop(app)
}

pub fn a_proof_from_other_approvers_is_refused_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-20", "Refund order A-100.", 0)
  let pending = awaiting_refund_approval(handle)
  // The same recipe built again over the same validator is other approvers:
  // only the value the agent was given answers.
  let again =
    approvers.warden_approvers(resource.new(app.warden, audience: app.audience))
  let assert Ok(proof) =
    fabric_approvers.check(
      again,
      signed_in(app, "alice"),
      pending.reference.requirement,
    )
  let assert Error(fabric.ProofRefused(fabric_approvers.OtherApprovers("warden"))) =
    fabric.approve(handle, pending.reference, proof:, context: session)
  let _ = awaiting_refund_approval(handle)
  assert services.calls_matching(app.services, "POST") == []
  let assert Ok(Nil) = app.stop(app)
}

// Telemetry -----------------------------------------------------------------

pub fn telemetry_follows_the_ticket_through_every_package_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-9", "Please refund order A-100.", 0)
  let pending = awaiting_refund_approval(handle)
  let assert Ok(_) =
    desk.approve(app.desk, handle, pending, signed_in(app, "alice"), session)
  let assert Ok(run.Finished(outcome)) =
    fabric.await(handle, within: duration.seconds(10))
  let assert run.Completed(_) = outcome
  desk.close(session, handle, outcome)
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
  let assert Ok(Nil) = app.stop(app)
}

pub fn one_agent_serves_two_tickets_and_keeps_their_events_apart_test() {
  let assert Ok(app) = app.start()
  let #(first, one) = open(app, "T-11", "Please refund order A-100.", 0)
  let #(second, two) = open(app, "T-12", "Order A-300 never worked.", 0)
  let one_pending = awaiting_refund_approval(one)
  let two_pending = awaiting_refund_approval(two)
  let assert Ok(_) =
    desk.approve(app.desk, one, one_pending, signed_in(app, "alice"), first)
  let assert Ok(_) =
    desk.approve(app.desk, two, two_pending, signed_in(app, "alice"), second)
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
  let assert Ok(Nil) = app.stop(app)
}

pub fn opening_a_ticket_twice_returns_its_one_run_test() {
  let assert Ok(app) = app.start()
  let #(session, handle) = open(app, "T-13", "Please refund order A-100.", 0)
  // The same message again is a retried open; another one is a follow-up
  // that Fabric cannot add to the run, and the desk says so.
  let assert Ok(desk.Opened(run: retried, message: desk.Repeated)) =
    desk.open_ticket(app.desk, session, "Please refund order A-100.")
  assert fabric.id(retried) == fabric.id(handle)
  let assert Ok(desk.Opened(run: again, message: desk.NotApplied)) =
    desk.open_ticket(app.desk, session, "a second try")
  assert fabric.id(again) == fabric.id(handle)
  let opened =
    telemetry.trail(app.telemetry, session.ticket)
    |> list.count(fn(o) { o.name == "ticket.opened" })
  assert opened == 1
  let assert Ok(Nil) = app.stop(app)
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
  let assert Ok(app) =
    app.start_with(
      agent.with_max_turns(_, 2),
      shop_deadline: duration.seconds(1),
    )
  let #(session, handle) = open(app, "T-10", "Refund order A-100.", 0)
  let assert Ok(run.Finished(outcome)) =
    fabric.await(handle, within: duration.seconds(10))
  desk.close(session, handle, outcome)
  let trail = telemetry.trail(app.telemetry, session.ticket)
  let assert Ok(answered) =
    list.find(trail, fn(o) { o.name == "ticket.answered" })
  assert answered.detail == "AnsweredNothing"
  let assert Ok(Nil) = app.stop(app)
}

// Seam evidence: saga names a returned "may have happened" error ------------

pub fn saga_names_a_returned_unknown_payment_as_an_unknown_effect_test() {
  let assert Ok(app) = app.start()
  let request = domain.RefundRequest("A-400", 3000, "late provider")
  let workflow = refund.workflow(app.desk.shop, app.ledger)
  let assert Ok(outcome) = execution.run(workflow, request, refund.config())
  // The provider took the refund and answered after the client deadline.
  // The step marks that error with `saga.unknown_when`, so saga records the
  // attempt as an unknown effect and, with no decider and no `on_unknown`,
  // ends the run `Unresolved` and undoes nothing; the saga recipe reports it as
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
  let assert Ok(Nil) = app.stop(app)
}
