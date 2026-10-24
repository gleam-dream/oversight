// THROWAWAY: Can a caller-owned policy govern Fabric actions and approvals?
import lab/blueprint
import lab/fabric
import lab/fabric_agent as agent
import lab/fabric_turn
import lab/llm
import lab/llm_turn as model
import lab/value

pub type RequestContext {
  RequestContext(
    customer: String,
    approval_version: Int,
    policy_available: Bool,
  )
}

type LookupInput {
  LookupInput(String)
}

type DeleteInput {
  DeleteInput(String)
}

type PurchaseInput {
  PurchaseInput(customer: String, item: String)
}

type PanicDeleteInput {
  PanicDeleteInput(String)
}

type Receipt {
  Receipt(String)
}

type ServiceFault {
  CustomerMismatch
  ServiceUnavailable
}

type ServiceAction {
  LookupAction(String)
  DeleteAction(String)
  PurchaseAction(String, String)
}

type ScriptState {
  ScriptState(provider: String, turn: Int)
}

type SingleState {
  SingleState(provider: String)
}

pub fn probe() -> Nil {
  mixed_batch_probe()
  customer_b_recheck_probe()
  rejection_and_policy_failure_probe()
  boundary_and_domain_failure_probe()
  reconciliation_probe()
  budget_and_provider_failure_probe()
  malformed_provider_probe()
  incarnation_and_issued_report_probe()
  Nil
}

fn mixed_batch_probe() -> Nil {
  let assert Ok(Receipt("lookup:customer-a")) =
    execute_service(customer_a(1), LookupAction("customer-a"))
  let run = agent.run_id("workflow-7")
  let incarnation = must_incarnation("workflow-7-start-1")
  let limit = must_limit(3)
  let assert Ok(agent.InitialPendingActions(started)) =
    agent.start(
      run,
      incarnation,
      limit,
      mixed_provider("original-provider"),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [
    lookup_action,
    delete_action,
    purchase_action,
    ghost_action,
    panic_action,
  ] = agent.current_actions(started)
  let assert agent.Registered(fabric.Declaration("lookup", _schema)) =
    agent.action_registration(lookup_action)
  let assert agent.Unregistered("ghost") =
    agent.action_registration(ghost_action)
  let lookup_identity = agent.action_identity(lookup_action)
  let delete_identity = agent.action_identity(delete_action)
  let purchase_identity = agent.action_identity(purchase_action)
  let ghost_identity = agent.action_identity(ghost_action)
  let panic_identity = agent.action_identity(panic_action)

  let assert Ok(#(lookup_inspected, agent.InvocationPrepared(lookup_prepared))) =
    agent.inspect_action(started, customer_a(1), lookup_identity)
  let lookup_report = agent.execute_prepared(lookup_prepared)
  let assert agent.ModelVisible(
    model.ToolSucceeded(model.CallId("reused"), value.Text("lookup:customer-a")),
    agent.ToolSucceeded,
  ) = agent.report_outcome(lookup_report)
  let assert Ok(lookup_accepted) =
    agent.accept_report(lookup_inspected, lookup_report)
  let assert Error(agent.DuplicateReport(_)) =
    agent.accept_report(lookup_accepted, lookup_report)

  let assert Ok(#(delete_inspected, agent.ReportReady(delete_report))) =
    agent.inspect_action(lookup_accepted, customer_a(1), delete_identity)
  let assert agent.ModelVisible(
    model.ToolFailed(model.CallId("delete-1"), value.Text("delete_denied")),
    agent.AuthorizationDenied("delete_denied"),
  ) = agent.report_outcome(delete_report)
  let assert Ok(delete_accepted) =
    agent.accept_report(delete_inspected, delete_report)

  let assert Ok(#(approval_pending, agent.ApprovalRequired(approval_request))) =
    agent.inspect_action(delete_accepted, customer_a(1), purchase_identity)
  let first_reference = agent.approval_reference(approval_request)
  let assert agent.ApprovalRequirement("purchase", 1) =
    agent.approval_requirement(approval_request)
  let assert Ok(#(renewed, agent.ApprovalRequiredAgain(renewed_request))) =
    agent.answer_approval(
      approval_pending,
      customer_a(2),
      first_reference,
      agent.Approve,
    )
  let renewed_reference = agent.approval_reference(renewed_request)
  let assert Error(agent.StaleApprovalReference) =
    agent.answer_approval(
      renewed,
      customer_a(2),
      first_reference,
      agent.Approve,
    )
  let assert Ok(#(
    purchase_prepared_state,
    agent.ApprovalInvocationPrepared(purchase_prepared),
  )) =
    agent.answer_approval(
      renewed,
      customer_a(2),
      renewed_reference,
      agent.Approve,
    )
  let assert Error(agent.ApprovalAlreadyAnswered) =
    agent.answer_approval(
      purchase_prepared_state,
      customer_a(2),
      renewed_reference,
      agent.Approve,
    )
  let purchase_report = agent.execute_prepared(purchase_prepared)
  let assert agent.ModelVisible(
    model.ToolSucceeded(
      model.CallId("purchase-1"),
      value.Text("purchase:customer-a:item-1"),
    ),
    agent.ToolSucceeded,
  ) = agent.report_outcome(purchase_report)
  let assert Ok(purchase_accepted) =
    agent.accept_report(purchase_prepared_state, purchase_report)

  let assert Ok(#(ghost_inspected, agent.ReportReady(ghost_report))) =
    agent.inspect_action(purchase_accepted, customer_a(2), ghost_identity)
  let assert agent.ModelVisible(
    model.ToolFailed(model.CallId("ghost-1"), value.Text("unknown_tool")),
    agent.UnknownTool("ghost"),
  ) = agent.report_outcome(ghost_report)
  let assert Ok(ghost_accepted) =
    agent.accept_report(ghost_inspected, ghost_report)

  let assert Ok(#(panic_inspected, agent.ReportReady(panic_report))) =
    agent.inspect_action(ghost_accepted, customer_a(2), panic_identity)
  let assert agent.ModelVisible(
    model.ToolFailed(model.CallId("panic-1"), value.Text("panic_delete_denied")),
    agent.AuthorizationDenied("panic_delete_denied"),
  ) = agent.report_outcome(panic_report)
  let assert Ok(all_accepted) =
    agent.accept_report(panic_inspected, panic_report)

  let assert Ok(agent.MoreActions(second_turn)) =
    agent.continue_model(all_accepted)
  let assert 2 = agent.model_turns_used(second_turn)
  let assert Error(agent.ForeignReport(_)) =
    agent.accept_report(second_turn, lookup_report)
  let assert [reused_action] = agent.current_actions(second_turn)
  let reused_identity = agent.action_identity(reused_action)
  let assert agent.ActionIdentity(_, _, 2, model.CallId("reused")) =
    reused_identity
  let assert False = lookup_identity == reused_identity
  let assert Ok(#(second_inspected, agent.InvocationPrepared(second_prepared))) =
    agent.inspect_action(second_turn, customer_a(2), reused_identity)
  let second_report = agent.execute_prepared(second_prepared)
  let assert Ok(second_accepted) =
    agent.accept_report(second_inspected, second_report)
  let assert Ok(agent.AgentFinished(
    finished,
    value.Text("finished:original-provider"),
  )) = agent.continue_model(second_accepted)
  let assert 3 = agent.model_turns_used(finished)
  let assert Ok(agent.AlreadyFinishedAdvance(
    terminal_state,
    value.Text("finished:original-provider"),
  )) = agent.continue_model(finished)
  let assert 3 = agent.model_turns_used(terminal_state)
  Nil
}

fn customer_b_recheck_probe() -> Nil {
  let run = agent.run_id("purchase-check")
  let incarnation = must_incarnation("purchase-check-1")
  let call = purchase_call("shared-purchase", "panic-sentinel", "item-b")
  let assert Ok(agent.InitialPendingActions(started)) =
    agent.start(
      run,
      incarnation,
      must_limit(2),
      single_call_provider("b-recheck", call),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [action] = agent.current_actions(started)
  let identity = agent.action_identity(action)
  let assert Ok(#(pending, agent.ApprovalRequired(requested))) =
    agent.inspect_action(started, customer_a(1), identity)
  let reference = agent.approval_reference(requested)
  let assert Ok(#(denied_state, agent.ApprovalReportReady(report))) =
    agent.answer_approval(pending, customer_b(1), reference, agent.Approve)
  let assert agent.ModelVisible(
    model.ToolFailed(
      model.CallId("shared-purchase"),
      value.Text("purchase_denied_for_customer"),
    ),
    agent.AuthorizationDenied("purchase_denied_for_customer"),
  ) = agent.report_outcome(report)
  let assert Ok(accepted) = agent.accept_report(denied_state, report)
  let assert Ok(agent.AgentFinished(_, value.Text("single:b-recheck"))) =
    agent.continue_model(accepted)
  Nil
}

fn rejection_and_policy_failure_probe() -> Nil {
  let purchase = purchase_call("reject-purchase", "customer-a", "item-r")
  let assert Ok(agent.InitialPendingActions(started)) =
    agent.start(
      agent.run_id("reject-run"),
      must_incarnation("reject-run-1"),
      must_limit(2),
      single_call_provider("reject-provider", purchase),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [action] = agent.current_actions(started)
  let identity = agent.action_identity(action)
  let assert Ok(#(pending, agent.ApprovalRequired(requested))) =
    agent.inspect_action(started, customer_a(1), identity)
  let reference = agent.approval_reference(requested)
  let assert Ok(#(rejected_state, agent.ApprovalReportReady(rejected))) =
    agent.answer_approval(pending, customer_a(2), reference, agent.Reject)
  let assert agent.ModelVisible(
    model.ToolFailed(
      model.CallId("reject-purchase"),
      value.Text("approval_rejected"),
    ),
    agent.ApprovalRejected,
  ) = agent.report_outcome(rejected)
  let assert Ok(rejected_accepted) =
    agent.accept_report(rejected_state, rejected)
  let assert Ok(agent.AgentFinished(_, value.Text("single:reject-provider"))) =
    agent.continue_model(rejected_accepted)

  let lookup = lookup_call("policy-error", "customer-a")
  let assert Ok(agent.InitialPendingActions(policy_started)) =
    agent.start(
      agent.run_id("policy-error-run"),
      must_incarnation("policy-error-1"),
      must_limit(2),
      panic_continuation_provider("policy-error-provider", lookup),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [policy_action] = agent.current_actions(policy_started)
  let policy_identity = agent.action_identity(policy_action)
  let assert Ok(#(policy_inspected, agent.ReportReady(policy_report))) =
    agent.inspect_action(
      policy_started,
      RequestContext("customer-a", 1, False),
      policy_identity,
    )
  let assert agent.HostFailure(agent.PolicyFailed(agent.PolicyUnavailable)) =
    agent.report_outcome(policy_report)
  let assert Ok(policy_halted) =
    agent.accept_report(policy_inspected, policy_report)
  let assert Ok(agent.HostStoppedAdvance(_, _)) =
    agent.continue_model(policy_halted)
  Nil
}

fn boundary_and_domain_failure_probe() -> Nil {
  let boundary =
    model.ToolCall(
      model.CallId("boundary-output"),
      model.ToolName("boundary"),
      value.Text("customer-a"),
    )
  let assert Ok(agent.InitialPendingActions(boundary_started)) =
    agent.start(
      agent.run_id("boundary-run"),
      must_incarnation("boundary-run-1"),
      must_limit(2),
      panic_continuation_provider("boundary-provider", boundary),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [boundary_action] = agent.current_actions(boundary_started)
  let boundary_identity = agent.action_identity(boundary_action)
  let assert Ok(#(
    boundary_inspected,
    agent.InvocationPrepared(boundary_prepared),
  )) = agent.inspect_action(boundary_started, customer_a(1), boundary_identity)
  let boundary_report = agent.execute_prepared(boundary_prepared)
  let assert agent.HostFailure(agent.BoundaryFailed(agent.OutputEncodeFailed(_))) =
    agent.report_outcome(boundary_report)
  let assert Ok(boundary_halted) =
    agent.accept_report(boundary_inspected, boundary_report)
  let assert Ok(agent.HostStoppedAdvance(_, _)) =
    agent.continue_model(boundary_halted)

  let unavailable = lookup_call("domain-failure", "domain-failure")
  let assert Ok(agent.InitialPendingActions(domain_started)) =
    agent.start(
      agent.run_id("domain-run"),
      must_incarnation("domain-run-1"),
      must_limit(2),
      single_call_provider("domain-provider", unavailable),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [domain_action] = agent.current_actions(domain_started)
  let domain_identity = agent.action_identity(domain_action)
  let assert Ok(#(domain_inspected, agent.InvocationPrepared(domain_prepared))) =
    agent.inspect_action(
      domain_started,
      RequestContext("domain-failure", 1, True),
      domain_identity,
    )
  let domain_report = agent.execute_prepared(domain_prepared)
  let assert agent.ModelVisible(
    model.ToolFailed(
      model.CallId("domain-failure"),
      value.Text("service_unavailable"),
    ),
    agent.DomainToolFailed(value.Text("service_unavailable")),
  ) = agent.report_outcome(domain_report)
  let assert Ok(domain_accepted) =
    agent.accept_report(domain_inspected, domain_report)
  let assert Ok(agent.AgentFinished(_, value.Text("single:domain-provider"))) =
    agent.continue_model(domain_accepted)
  Nil
}

fn reconciliation_probe() -> Nil {
  let call = lookup_call("effect-call", "customer-a")
  let assert Ok(agent.InitialPendingActions(started)) =
    agent.start(
      agent.run_id("effect-run"),
      must_incarnation("effect-run-1"),
      must_limit(2),
      panic_continuation_provider("effect-provider", call),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [action] = agent.current_actions(started)
  let identity = agent.action_identity(action)
  let assert Ok(#(inspected, agent.InvocationPrepared(prepared))) =
    agent.inspect_action(started, customer_a(1), identity)
  let _lost_result = agent.execute_prepared(prepared)
  let uncertain =
    agent.report_unknown_effect(prepared, "dispatch reply timed out")
  let assert agent.OutcomeUnknown(effect) = agent.report_outcome(uncertain)
  let assert Ok(uncertain_state) = agent.accept_report(inspected, uncertain)
  let assert Ok(agent.ReconciliationRequiredAdvance(_, _)) =
    agent.continue_model(uncertain_state)
  let assert Ok(reconciled) =
    agent.reconcile_unknown_effect(
      uncertain_state,
      effect,
      model.ToolSucceeded(
        model.CallId("effect-call"),
        value.Text("lookup:customer-a"),
      ),
    )
  let assert 1 = agent.model_turns_used(reconciled)
  Nil
}

fn budget_and_provider_failure_probe() -> Nil {
  let call = lookup_call("budget-call", "customer-a")
  let assert Error(agent.ModelTurnLimitMustBePositive) =
    agent.max_model_turns(0)
  let assert Ok(agent.InitialPendingActions(budget_started)) =
    agent.start(
      agent.run_id("budget-run"),
      must_incarnation("budget-run-1"),
      must_limit(1),
      panic_continuation_provider("budget-provider", call),
      request(),
      service_registry(),
      service_policy,
    )
  let assert 0 = agent.model_turns_remaining(budget_started)
  let assert [budget_action] = agent.current_actions(budget_started)
  let budget_identity = agent.action_identity(budget_action)
  let assert Ok(#(same_budget, agent.BudgetBlocked)) =
    agent.inspect_action(budget_started, customer_a(1), budget_identity)
  let assert Ok(agent.BudgetExhausted(budget_evolved)) =
    agent.continue_model(same_budget)
  let assert 1 = agent.model_turns_used(budget_evolved)

  let assert Ok(agent.InitialPendingActions(failing_started)) =
    agent.start(
      agent.run_id("provider-error-run"),
      must_incarnation("provider-error-1"),
      must_limit(2),
      failing_provider(),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [failing_action] = agent.current_actions(failing_started)
  let failing_identity = agent.action_identity(failing_action)
  let assert Ok(#(failing_inspected, agent.InvocationPrepared(failing_prepared))) =
    agent.inspect_action(failing_started, customer_a(1), failing_identity)
  let failing_report = agent.execute_prepared(failing_prepared)
  let assert Ok(failing_accepted) =
    agent.accept_report(failing_inspected, failing_report)
  let assert Ok(agent.ProviderCallFailedAdvance(
    failed_state,
    llm.TransportUnavailable,
  )) = agent.continue_model(failing_accepted)
  let assert 2 = agent.model_turns_used(failed_state)
  let assert Ok(agent.ProviderCallFailedAdvance(
    rechecked,
    llm.TransportUnavailable,
  )) = agent.continue_model(failed_state)
  let assert 2 = agent.model_turns_used(rechecked)
  Nil
}

fn malformed_provider_probe() -> Nil {
  let assert Ok(agent.InitialPendingActions(started)) =
    agent.start(
      agent.run_id("protocol-run"),
      must_incarnation("protocol-run-1"),
      must_limit(2),
      duplicate_reply_provider(),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [action] = agent.current_actions(started)
  let identity = agent.action_identity(action)
  let assert Ok(#(inspected, agent.InvocationPrepared(prepared))) =
    agent.inspect_action(started, customer_a(1), identity)
  let report = agent.execute_prepared(prepared)
  let assert Ok(accepted) = agent.accept_report(inspected, report)
  let assert Ok(agent.ProviderProtocolFailedAdvance(
    failed,
    fabric_turn.DuplicateCallId(model.CallId("duplicate-next-turn")),
  )) = agent.continue_model(accepted)
  let assert 2 = agent.model_turns_used(failed)
  let assert Ok(agent.ProviderProtocolFailedAdvance(repeated, _)) =
    agent.continue_model(failed)
  let assert 2 = agent.model_turns_used(repeated)

  let assert Ok(agent.InitialPendingActions(empty_started)) =
    agent.start(
      agent.run_id("empty-protocol-run"),
      must_incarnation("empty-protocol-run-1"),
      must_limit(2),
      empty_reply_provider(),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [empty_action] = agent.current_actions(empty_started)
  let empty_identity = agent.action_identity(empty_action)
  let assert Ok(#(empty_inspected, agent.InvocationPrepared(empty_prepared))) =
    agent.inspect_action(empty_started, customer_a(1), empty_identity)
  let empty_report = agent.execute_prepared(empty_prepared)
  let assert Ok(empty_accepted) =
    agent.accept_report(empty_inspected, empty_report)
  let assert Ok(agent.ProviderProtocolFailedAdvance(
    empty_failed,
    fabric_turn.EmptyToolBatch,
  )) = agent.continue_model(empty_accepted)
  let assert 2 = agent.model_turns_used(empty_failed)
  let assert Ok(agent.ProviderProtocolFailedAdvance(
    empty_terminal,
    fabric_turn.EmptyToolBatch,
  )) = agent.continue_model(empty_failed)
  let assert 2 = agent.model_turns_used(empty_terminal)
  Nil
}

fn incarnation_and_issued_report_probe() -> Nil {
  let shared_run = agent.run_id("same-logical-run")
  let call_a = lookup_call("same-call", "customer-a")
  let call_b = lookup_call("same-call", "customer-b")
  let incarnation_a = must_incarnation("same-logical-run-start-1")
  let incarnation_b = must_incarnation("same-logical-run-start-2")
  let assert Ok(agent.InitialPendingActions(controller_a)) =
    agent.start(
      shared_run,
      incarnation_a,
      must_limit(2),
      single_call_provider("provider-a", call_a),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [action_a] = agent.current_actions(controller_a)
  let identity_a = agent.action_identity(action_a)
  let assert Ok(#(prepared_a_state, agent.InvocationPrepared(prepared_a))) =
    agent.inspect_action(controller_a, customer_a(1), identity_a)
  let report_a = agent.execute_prepared(prepared_a)

  let assert Ok(agent.InitialPendingActions(controller_b)) =
    agent.start(
      shared_run,
      incarnation_b,
      must_limit(2),
      single_call_provider("provider-b", call_b),
      request(),
      service_registry(),
      deny_everything,
    )
  let assert Error(agent.ForeignReport(_)) =
    agent.accept_report(controller_b, report_a)
  let assert Ok(#(same_report_state, agent.ReportReady(denied_report))) =
    agent.inspect_action(
      controller_b,
      customer_b(1),
      agent.action_identity(get_only_action(controller_b)),
    )
  let assert agent.ModelVisible(
    model.ToolFailed(model.CallId("same-call"), value.Text("deny_all")),
    agent.AuthorizationDenied("deny_all"),
  ) = agent.report_outcome(denied_report)
  let _ = prepared_a_state
  let _ = same_report_state

  let purchase = purchase_call("same-approval", "customer-a", "item")
  let assert Ok(agent.InitialPendingActions(approval_a)) =
    agent.start(
      shared_run,
      must_incarnation("same-logical-run-approval-start-1"),
      must_limit(2),
      single_call_provider("approval-provider-a", purchase),
      request(),
      service_registry(),
      service_policy,
    )
  let assert [approval_action_a] = agent.current_actions(approval_a)
  let assert Ok(#(
    approval_waiting_a,
    agent.ApprovalRequired(approval_request_a),
  )) =
    agent.inspect_action(
      approval_a,
      customer_a(1),
      agent.action_identity(approval_action_a),
    )
  let reference_a = agent.approval_reference(approval_request_a)
  let assert Ok(agent.InitialPendingActions(approval_b)) =
    agent.start(
      shared_run,
      must_incarnation("same-logical-run-approval-start-2"),
      must_limit(2),
      single_call_provider("approval-provider-b", purchase),
      request(),
      service_registry(),
      always_require_purchase,
    )
  let assert [approval_action_b] = agent.current_actions(approval_b)
  let assert Ok(#(approval_waiting_b, agent.ApprovalRequired(_))) =
    agent.inspect_action(
      approval_b,
      customer_a(1),
      agent.action_identity(approval_action_b),
    )
  let assert Error(agent.WrongApprovalReference) =
    agent.answer_approval(
      approval_waiting_b,
      customer_a(1),
      reference_a,
      agent.Approve,
    )
  let _ = approval_waiting_a

  let uncertain_call_a = lookup_call("same-effect", "customer-a")
  let uncertain_call_b = lookup_call("same-effect", "customer-b")
  let assert Ok(agent.InitialPendingActions(effect_a)) =
    agent.start(
      shared_run,
      must_incarnation("same-logical-run-effect-start-1"),
      must_limit(2),
      single_call_provider("effect-provider-a", uncertain_call_a),
      request(),
      service_registry(),
      allow_everything,
    )
  let assert [effect_action_a] = agent.current_actions(effect_a)
  let assert Ok(#(
    effect_prepared_state,
    agent.InvocationPrepared(effect_prepared),
  )) =
    agent.inspect_action(
      effect_a,
      customer_a(1),
      agent.action_identity(effect_action_a),
    )
  let effect_report = agent.report_unknown_effect(effect_prepared, "reply lost")
  let assert agent.OutcomeUnknown(effect_reference) =
    agent.report_outcome(effect_report)
  let assert Ok(effect_waiting_a) =
    agent.accept_report(effect_prepared_state, effect_report)
  let assert Ok(agent.InitialPendingActions(effect_b)) =
    agent.start(
      shared_run,
      must_incarnation("same-logical-run-effect-start-2"),
      must_limit(2),
      single_call_provider("effect-provider-b", uncertain_call_b),
      request(),
      service_registry(),
      allow_everything,
    )
  let assert [effect_action_b] = agent.current_actions(effect_b)
  let assert Ok(#(
    effect_prepared_b_state,
    agent.InvocationPrepared(effect_prepared_b),
  )) =
    agent.inspect_action(
      effect_b,
      customer_b(1),
      agent.action_identity(effect_action_b),
    )
  let effect_report_b =
    agent.report_unknown_effect(effect_prepared_b, "reply lost")
  let assert agent.OutcomeUnknown(effect_reference_b) =
    agent.report_outcome(effect_report_b)
  let assert Ok(effect_waiting_b) =
    agent.accept_report(effect_prepared_b_state, effect_report_b)
  let assert Error(agent.UnknownEffectIdentity(_)) =
    agent.reconcile_unknown_effect(
      effect_waiting_b,
      effect_reference,
      model.ToolSucceeded(
        model.CallId("same-effect"),
        value.Text("forged resolution"),
      ),
    )

  // The matching references succeed from those same waiting states. Each
  // continuation stays with its own provider despite sharing a native type.
  let assert Ok(effect_resolved_b) =
    agent.reconcile_unknown_effect(
      effect_waiting_b,
      effect_reference_b,
      model.ToolSucceeded(model.CallId("same-effect"), value.Text("resolved-b")),
    )
  let assert Ok(agent.AgentFinished(_, value.Text("single:effect-provider-b"))) =
    agent.continue_model(effect_resolved_b)
  let assert Ok(effect_resolved_a) =
    agent.reconcile_unknown_effect(
      effect_waiting_a,
      effect_reference,
      model.ToolSucceeded(model.CallId("same-effect"), value.Text("resolved-a")),
    )
  let assert Ok(agent.AgentFinished(_, value.Text("single:effect-provider-a"))) =
    agent.continue_model(effect_resolved_a)

  // Reuse an incarnation only to challenge exact issued-report matching. Hosts
  // must still issue a fresh one per independently started controller.
  let denied_call = lookup_call("same-label", "customer-a")
  let assert Ok(agent.InitialPendingActions(issued_controller)) =
    agent.start(
      agent.run_id("issued-report-run"),
      must_incarnation("issued-report-incarnation"),
      must_limit(2),
      single_call_provider("issued-provider", denied_call),
      request(),
      service_registry(),
      deny_everything,
    )
  let assert [issued_action] = agent.current_actions(issued_controller)
  let assert Ok(#(issued_state, agent.ReportReady(issued))) =
    agent.inspect_action(
      issued_controller,
      customer_a(1),
      agent.action_identity(issued_action),
    )
  let assert Ok(agent.InitialPendingActions(duplicate_controller)) =
    agent.start(
      agent.run_id("issued-report-run"),
      must_incarnation("issued-report-incarnation"),
      must_limit(2),
      single_call_provider("duplicate-provider", denied_call),
      request(),
      service_registry(),
      allow_everything,
    )
  let assert [duplicate_action] = agent.current_actions(duplicate_controller)
  let assert Ok(#(
    duplicate_prepared_state,
    agent.InvocationPrepared(duplicate_prepared),
  )) =
    agent.inspect_action(
      duplicate_controller,
      customer_a(1),
      agent.action_identity(duplicate_action),
    )
  let duplicate_report = agent.execute_prepared(duplicate_prepared)
  let assert Error(agent.ReportDoesNotMatchIssued(_)) =
    agent.accept_report(issued_state, duplicate_report)
  let _ = duplicate_prepared_state
  let _ = issued
  let _ = report_a
  Nil
}

fn service_registry() -> fabric.Registry(RequestContext) {
  let assert Ok(registry) =
    fabric.registry([
      fabric.context_tool(
        "lookup",
        lookup_codec(),
        receipt_codec(),
        fault_codec(),
        lookup_handler,
      ),
      fabric.context_tool(
        "delete",
        delete_codec(),
        receipt_codec(),
        fault_codec(),
        delete_handler,
      ),
      fabric.context_tool(
        "purchase",
        purchase_codec(),
        receipt_codec(),
        fault_codec(),
        purchase_handler,
      ),
      fabric.context_tool(
        "panic_delete",
        panic_delete_codec(),
        receipt_codec(),
        fault_codec(),
        panic_delete_handler,
      ),
      fabric.context_tool(
        "boundary",
        lookup_codec(),
        failing_receipt_codec(),
        fault_codec(),
        boundary_handler,
      ),
    ])
  registry
}

fn lookup_handler(
  context: RequestContext,
  input: LookupInput,
) -> Result(Receipt, ServiceFault) {
  let LookupInput(customer) = input
  execute_service(context, LookupAction(customer))
}

fn delete_handler(
  context: RequestContext,
  input: DeleteInput,
) -> Result(Receipt, ServiceFault) {
  let DeleteInput(customer) = input
  execute_service(context, DeleteAction(customer))
}

fn purchase_handler(
  context: RequestContext,
  input: PurchaseInput,
) -> Result(Receipt, ServiceFault) {
  case context.customer == "customer-b" {
    True -> panic as "purchase handler ran after current-context denial"
    False -> {
      let PurchaseInput(customer, item) = input
      execute_service(context, PurchaseAction(customer, item))
    }
  }
}

fn panic_delete_handler(
  _context: RequestContext,
  _input: PanicDeleteInput,
) -> Result(Receipt, ServiceFault) {
  panic as "denied action reached the typed handler"
}

fn boundary_handler(
  context: RequestContext,
  input: LookupInput,
) -> Result(Receipt, ServiceFault) {
  let LookupInput(customer) = input
  execute_service(context, LookupAction(customer))
}

// The same ordinary typed application function serves every concrete service
// handler; request context and policy remain caller-owned values.
fn execute_service(
  context: RequestContext,
  action: ServiceAction,
) -> Result(Receipt, ServiceFault) {
  case action {
    LookupAction(customer) -> service_result(context, "lookup", customer, "")
    DeleteAction(customer) -> service_result(context, "delete", customer, "")
    PurchaseAction(customer, item) ->
      service_result(context, "purchase", customer, item)
  }
}

fn service_result(
  context: RequestContext,
  operation: String,
  target_customer: String,
  item: String,
) -> Result(Receipt, ServiceFault) {
  case context.customer == target_customer {
    False -> Error(CustomerMismatch)
    True ->
      case target_customer == "domain-failure" {
        True -> Error(ServiceUnavailable)
        False -> {
          let suffix = case operation {
            "purchase" -> ":" <> item
            _ -> ""
          }
          Ok(Receipt(operation <> ":" <> target_customer <> suffix))
        }
      }
  }
}

fn service_policy(
  context: RequestContext,
  action: agent.ActionDescription,
) -> Result(agent.PolicyDecision, agent.PolicyError) {
  case context.policy_available {
    False -> Error(agent.PolicyUnavailable)
    True ->
      case agent.action_name(action) {
        "lookup" -> Ok(agent.Allow)
        "boundary" -> Ok(agent.Allow)
        "delete" -> Ok(agent.Deny("delete_denied"))
        "panic_delete" -> Ok(agent.Deny("panic_delete_denied"))
        "purchase" ->
          case context.customer == "customer-b" {
            True -> Ok(agent.Deny("purchase_denied_for_customer"))
            False ->
              Ok(
                agent.RequireApproval(agent.ApprovalRequirement(
                  "purchase",
                  context.approval_version,
                )),
              )
          }
        _ -> Ok(agent.Deny("unknown_action"))
      }
  }
}

fn allow_everything(
  _context: RequestContext,
  _action: agent.ActionDescription,
) -> Result(agent.PolicyDecision, agent.PolicyError) {
  Ok(agent.Allow)
}

fn deny_everything(
  _context: RequestContext,
  _action: agent.ActionDescription,
) -> Result(agent.PolicyDecision, agent.PolicyError) {
  Ok(agent.Deny("deny_all"))
}

fn always_require_purchase(
  _context: RequestContext,
  _action: agent.ActionDescription,
) -> Result(agent.PolicyDecision, agent.PolicyError) {
  Ok(agent.RequireApproval(agent.ApprovalRequirement("purchase", 1)))
}

fn lookup_codec() -> blueprint.Codec(LookupInput) {
  blueprint.imap(blueprint.text(), LookupInput, fn(input) {
    let LookupInput(customer) = input
    customer
  })
}

fn delete_codec() -> blueprint.Codec(DeleteInput) {
  blueprint.imap(blueprint.text(), DeleteInput, fn(input) {
    let DeleteInput(customer) = input
    customer
  })
}

fn purchase_codec() -> blueprint.Codec(PurchaseInput) {
  blueprint.imap(
    blueprint.pair(blueprint.text(), blueprint.text()),
    fn(pair) {
      let #(customer, item) = pair
      case customer {
        "panic-sentinel" -> panic as "approval recheck decoded a denied purchase"
        _ -> PurchaseInput(customer, item)
      }
    },
    fn(input) {
      let PurchaseInput(customer, item) = input
      #(customer, item)
    },
  )
}

fn panic_delete_codec() -> blueprint.Codec(PanicDeleteInput) {
  blueprint.imap(
    blueprint.text(),
    fn(_) { panic as "policy denial happened after input decoding" },
    fn(input) {
      let PanicDeleteInput(value) = input
      value
    },
  )
}

fn receipt_codec() -> blueprint.Codec(Receipt) {
  blueprint.imap(blueprint.text(), Receipt, fn(receipt) {
    let Receipt(text) = receipt
    text
  })
}

fn failing_receipt_codec() -> blueprint.Codec(Receipt) {
  blueprint.new(
    fn(_) { Error(blueprint.CannotEncode("output sentinel")) },
    fn(_) { Error(blueprint.CannotDecode("output sentinel")) },
  )
}

fn fault_codec() -> blueprint.Codec(ServiceFault) {
  blueprint.new(
    fn(fault) {
      case fault {
        CustomerMismatch -> Ok(value.Text("customer_mismatch"))
        ServiceUnavailable -> Ok(value.Text("service_unavailable"))
      }
    },
    fn(raw) {
      case raw {
        value.Text("customer_mismatch") -> Ok(CustomerMismatch)
        value.Text("service_unavailable") -> Ok(ServiceUnavailable)
        _ -> Error(blueprint.CannotDecode("unknown service fault"))
      }
    },
  )
}

fn mixed_provider(provider: String) -> model.Provider(ScriptState) {
  model.provider(
    fn(_request, _tools) {
      Ok(model.RequestsTools(ScriptState(provider, 1), mixed_calls()))
    },
    fn(state, results) {
      case state, results {
        ScriptState(expected, 1),
          [
            model.ToolSucceeded(
              model.CallId("reused"),
              value.Text("lookup:customer-a"),
            ),
            model.ToolFailed(
              model.CallId("delete-1"),
              value.Text("delete_denied"),
            ),
            model.ToolSucceeded(
              model.CallId("purchase-1"),
              value.Text("purchase:customer-a:item-1"),
            ),
            model.ToolFailed(
              model.CallId("ghost-1"),
              value.Text("unknown_tool"),
            ),
            model.ToolFailed(
              model.CallId("panic-1"),
              value.Text("panic_delete_denied"),
            ),
          ]
          if expected == provider
        ->
          Ok(
            model.RequestsTools(ScriptState(provider, 2), [
              lookup_call("reused", "customer-a"),
            ]),
          )
        ScriptState(expected, 2),
          [
            model.ToolSucceeded(
              model.CallId("reused"),
              value.Text("lookup:customer-a"),
            ),
          ]
          if expected == provider
        -> Ok(model.Final(value.Text("finished:" <> provider)))
        _, _ -> Error(llm.UnsupportedCapability)
      }
    },
  )
}

fn single_call_provider(
  provider: String,
  call: model.ToolCall,
) -> model.Provider(SingleState) {
  model.provider(
    fn(_request, _tools) {
      Ok(model.RequestsTools(SingleState(provider), [call]))
    },
    fn(state, _results) {
      case state {
        SingleState(expected) ->
          case expected == provider {
            True -> Ok(model.Final(value.Text("single:" <> provider)))
            False -> Error(llm.UnsupportedCapability)
          }
      }
    },
  )
}

fn failing_provider() -> model.Provider(SingleState) {
  model.provider(
    fn(_request, _tools) {
      Ok(
        model.RequestsTools(SingleState("fail"), [
          lookup_call("provider-failure", "customer-a"),
        ]),
      )
    },
    fn(_state, _results) { Error(llm.TransportUnavailable) },
  )
}

fn panic_continuation_provider(
  provider: String,
  call: model.ToolCall,
) -> model.Provider(SingleState) {
  model.provider(
    fn(_request, _tools) {
      Ok(model.RequestsTools(SingleState(provider), [call]))
    },
    fn(_state, _results) {
      panic as "blocked agent state invoked the model continuation"
    },
  )
}

fn duplicate_reply_provider() -> model.Provider(SingleState) {
  model.provider(
    fn(_request, _tools) {
      Ok(
        model.RequestsTools(SingleState("duplicate"), [
          lookup_call("protocol-call", "customer-a"),
        ]),
      )
    },
    fn(_state, _results) {
      let duplicate = lookup_call("duplicate-next-turn", "customer-a")
      Ok(model.RequestsTools(SingleState("duplicate"), [duplicate, duplicate]))
    },
  )
}

fn empty_reply_provider() -> model.Provider(SingleState) {
  model.provider(
    fn(_request, _tools) {
      Ok(
        model.RequestsTools(SingleState("empty"), [
          lookup_call("empty-protocol-call", "customer-a"),
        ]),
      )
    },
    fn(_state, _results) { Ok(model.RequestsTools(SingleState("empty"), [])) },
  )
}

fn mixed_calls() -> List(model.ToolCall) {
  [
    lookup_call("reused", "customer-a"),
    model.ToolCall(
      model.CallId("delete-1"),
      model.ToolName("delete"),
      value.Text("customer-a"),
    ),
    purchase_call("purchase-1", "customer-a", "item-1"),
    model.ToolCall(model.CallId("ghost-1"), model.ToolName("ghost"), value.Null),
    model.ToolCall(
      model.CallId("panic-1"),
      model.ToolName("panic_delete"),
      value.Text("sentinel"),
    ),
  ]
}

fn lookup_call(id: String, customer: String) -> model.ToolCall {
  model.ToolCall(
    model.CallId(id),
    model.ToolName("lookup"),
    value.Text(customer),
  )
}

fn purchase_call(id: String, customer: String, item: String) -> model.ToolCall {
  model.ToolCall(
    model.CallId(id),
    model.ToolName("purchase"),
    value.Array([value.Text(customer), value.Text(item)]),
  )
}

fn get_only_action(
  controller: agent.Controller(RequestContext, a),
) -> agent.ActionDescription {
  let assert [action] = agent.current_actions(controller)
  action
}

fn customer_a(version: Int) -> RequestContext {
  RequestContext("customer-a", version, True)
}

fn customer_b(version: Int) -> RequestContext {
  RequestContext("customer-b", version, True)
}

fn request() -> llm.Request {
  llm.Request([llm.User("Apply current caller policy to these actions")], 128)
}

fn must_limit(value: Int) -> agent.MaxModelTurns {
  let assert Ok(limit) = agent.max_model_turns(value)
  limit
}

fn must_incarnation(value: String) -> agent.Incarnation {
  let assert Ok(incarnation) = agent.trusted_incarnation(value)
  incarnation
}
