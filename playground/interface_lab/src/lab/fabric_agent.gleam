// THROWAWAY: Can an application inspect, authorize, and reconcile Fabric actions?
// This is a pure interface experiment. It makes no linearity or transport claim.
import lab/blueprint
import lab/fabric
import lab/fabric_llm
import lab/fabric_turn
import lab/llm
import lab/llm_turn as model
import lab/value.{type Value}

type Maybe(a) {
  Missing
  Found(a)
}

pub opaque type RunId {
  RunId(String)
}

pub fn run_id(value: String) -> RunId {
  RunId(value)
}

// The host issues a distinct incarnation for each independently started
// controller, including restarts with the same logical RunId. This pure
// playground accepts that trusted identity; it does not prove freshness.
pub opaque type Incarnation {
  Incarnation(String)
}

pub type IncarnationError {
  IncarnationMustNotBeEmpty
}

pub fn trusted_incarnation(
  value: String,
) -> Result(Incarnation, IncarnationError) {
  case value == "" {
    True -> Error(IncarnationMustNotBeEmpty)
    False -> Ok(Incarnation(value))
  }
}

pub opaque type MaxModelTurns {
  MaxModelTurns(Int)
}

pub type LimitError {
  ModelTurnLimitMustBePositive
}

pub fn max_model_turns(limit: Int) -> Result(MaxModelTurns, LimitError) {
  case limit > 0 {
    True -> Ok(MaxModelTurns(limit))
    False -> Error(ModelTurnLimitMustBePositive)
  }
}

pub type ActionIdentity {
  ActionIdentity(
    run: RunId,
    incarnation: Incarnation,
    turn: Int,
    call_id: model.CallId,
  )
}

pub type ActionRegistration {
  Registered(fabric.Declaration)
  Unregistered(String)
}

pub type ActionDescription {
  ActionDescription(
    identity: ActionIdentity,
    name: String,
    arguments: Value,
    registration: ActionRegistration,
  )
}

pub fn action_identity(action: ActionDescription) -> ActionIdentity {
  let ActionDescription(identity, _, _, _) = action
  identity
}

pub fn action_name(action: ActionDescription) -> String {
  let ActionDescription(_, name, _, _) = action
  name
}

pub fn action_arguments(action: ActionDescription) -> Value {
  let ActionDescription(_, _, arguments, _) = action
  arguments
}

pub fn action_registration(action: ActionDescription) -> ActionRegistration {
  let ActionDescription(_, _, _, registration) = action
  registration
}

pub type ApprovalRequirement {
  ApprovalRequirement(identity: String, version: Int)
}

pub type PolicyDecision {
  Allow
  Deny(reason: String)
  RequireApproval(ApprovalRequirement)
}

pub type PolicyError {
  PolicyUnavailable
  PolicyRejected(String)
}

pub type Policy(context) =
  fn(context, ActionDescription) -> Result(PolicyDecision, PolicyError)

pub type ApprovalAnswer {
  Approve
  Reject
}

pub type BoundaryFailure {
  InputDecodeFailed(blueprint.DecodeError)
  OutputEncodeFailed(blueprint.EncodeError)
  ErrorEncodeFailed(blueprint.EncodeError)
}

pub type ModelVisibleKind {
  ToolSucceeded
  DomainToolFailed(Value)
  AuthorizationDenied(String)
  ApprovalRejected
  UnknownTool(String)
  EffectReconciled
}

pub type HostFailure {
  PolicyFailed(PolicyError)
  BoundaryFailed(BoundaryFailure)
  RegistryMismatch(String)
}

// An unknown outcome is neither success nor failure. Only an adapter that has
// dispatched the prepared action and cannot establish its result should issue one.
pub opaque type UnknownEffect {
  UnknownEffect(identity: ActionIdentity, name: String, evidence: String)
}

pub fn unknown_effect_identity(effect: UnknownEffect) -> ActionIdentity {
  let UnknownEffect(identity, _, _) = effect
  identity
}

pub fn unknown_effect_name(effect: UnknownEffect) -> String {
  let UnknownEffect(_, name, _) = effect
  name
}

pub fn unknown_effect_evidence(effect: UnknownEffect) -> String {
  let UnknownEffect(_, _, evidence) = effect
  evidence
}

pub type ReportOutcome {
  ModelVisible(model.ToolResult, ModelVisibleKind)
  HostFailure(HostFailure)
  OutcomeUnknown(UnknownEffect)
}

pub opaque type ActionReport {
  ActionReport(identity: ActionIdentity, outcome: ReportOutcome)
}

pub fn report_identity(report: ActionReport) -> ActionIdentity {
  let ActionReport(identity, _) = report
  identity
}

pub fn report_outcome(report: ActionReport) -> ReportOutcome {
  let ActionReport(_, outcome) = report
  outcome
}

pub opaque type ApprovalReference {
  ApprovalReference(
    identity: ActionIdentity,
    requirement: ApprovalRequirement,
    revision: Int,
  )
}

pub opaque type ApprovalRequest {
  ApprovalRequest(
    requirement: ApprovalRequirement,
    reference: ApprovalReference,
  )
}

pub fn approval_requirement(request: ApprovalRequest) -> ApprovalRequirement {
  let ApprovalRequest(requirement, _) = request
  requirement
}

pub fn approval_reference(request: ApprovalRequest) -> ApprovalReference {
  let ApprovalRequest(_, reference) = request
  reference
}

pub opaque type PreparedInvocation(context) {
  PreparedInvocation(
    registry: fabric.Registry(context),
    context: context,
    call: model.ToolCall,
    identity: ActionIdentity,
  )
}

type ActionStatus {
  Uninspected
  Prepared
  AwaitingApproval(ApprovalRequirement, Int)
  ReportIssued(ActionReport)
  Accepted(ActionReport)
  HostHalted(ActionReport)
  ReconciliationRequired(UnknownEffect)
}

type ActionSlot {
  ActionSlot(
    identity: ActionIdentity,
    call: model.ToolCall,
    status: ActionStatus,
  )
}

pub opaque type Controller(context, continuation) {
  Controller(
    run: RunId,
    incarnation: Incarnation,
    max_model_turns: Int,
    model_turns_used: Int,
    pending: fabric_turn.Pending(continuation),
    registry: fabric.Registry(context),
    policy: Policy(context),
    actions: List(ActionSlot),
    approval_revision: Int,
    model_call_failure: Maybe(llm.CallError),
    protocol_failure: Maybe(fabric_turn.TurnError),
    finished_output: Maybe(Value),
  )
}

pub type Started(context, continuation) {
  InitialFinished(Value)
  InitialPendingActions(Controller(context, continuation))
}

pub type AgentError {
  ModelTurnRejected(fabric_turn.TurnError)
}

pub fn start(
  run: RunId,
  incarnation: Incarnation,
  limit: MaxModelTurns,
  provider: model.Provider(continuation),
  request: llm.Request,
  registry: fabric.Registry(context),
  policy: Policy(context),
) -> Result(Started(context, continuation), AgentError) {
  let MaxModelTurns(max_model_turns) = limit
  case fabric_turn.begin(provider, request, fabric_llm.declarations(registry)) {
    Error(error) -> Error(ModelTurnRejected(error))
    Ok(fabric_turn.Finished(output)) -> Ok(InitialFinished(output))
    Ok(fabric_turn.NeedsTools(pending)) ->
      Ok(
        InitialPendingActions(Controller(
          run,
          incarnation,
          max_model_turns,
          1,
          pending,
          registry,
          policy,
          action_slots(run, incarnation, 1, fabric_turn.calls(pending)),
          0,
          Missing,
          Missing,
          Missing,
        )),
      )
  }
}

pub fn current_actions(
  controller: Controller(context, continuation),
) -> List(ActionDescription) {
  describe_actions(controller.registry, controller.actions, [])
}

pub fn model_turns_used(controller: Controller(context, continuation)) -> Int {
  controller.model_turns_used
}

pub fn model_turns_remaining(
  controller: Controller(context, continuation),
) -> Int {
  controller.max_model_turns - controller.model_turns_used
}

pub type ControllerBlocker {
  HostStopped(ActionReport)
  ReconciliationPending(UnknownEffect)
  ProviderCallFailed(llm.CallError)
  ProviderProtocolFailed(fabric_turn.TurnError)
  AlreadyFinished(Value)
}

pub type Inspection(context) {
  InvocationPrepared(PreparedInvocation(context))
  ReportReady(ActionReport)
  ApprovalRequired(ApprovalRequest)
  BudgetBlocked
  InspectionBlocked(ControllerBlocker)
}

pub type InspectionError {
  UnknownAction(ActionIdentity)
  ActionAlreadyInspected(ActionIdentity)
}

pub fn inspect_action(
  controller: Controller(context, continuation),
  context: context,
  identity: ActionIdentity,
) -> Result(
  #(Controller(context, continuation), Inspection(context)),
  InspectionError,
) {
  case
    controller_blocker(
      controller.actions,
      controller.model_call_failure,
      controller.protocol_failure,
      controller.finished_output,
    )
  {
    Found(blocker) -> Ok(#(controller, InspectionBlocked(blocker)))
    Missing ->
      case model_turns_remaining(controller) > 0 {
        False -> Ok(#(controller, BudgetBlocked))
        True ->
          case find_action(controller.actions, identity) {
            Missing -> Error(UnknownAction(identity))
            Found(ActionSlot(_, _, Uninspected) as slot) ->
              inspect_unseen(controller, context, identity, slot)
            Found(_) -> Error(ActionAlreadyInspected(identity))
          }
      }
  }
}

fn inspect_unseen(
  controller: Controller(context, continuation),
  context: context,
  identity: ActionIdentity,
  slot: ActionSlot,
) -> Result(
  #(Controller(context, continuation), Inspection(context)),
  InspectionError,
) {
  let ActionSlot(_, call, _) = slot
  let name = call_name(call)
  case find_declaration(fabric.declarations(controller.registry), name) {
    Missing -> {
      let report = unknown_tool_report(identity, call, name)
      Ok(report_transition(controller, identity, report))
    }
    Found(declaration) ->
      case
        controller.policy(
          context,
          describe_action(identity, call, Registered(declaration)),
        )
      {
        Error(error) -> {
          let report = policy_failure_report(identity, error)
          Ok(report_transition(controller, identity, report))
        }
        Ok(Allow) -> {
          let assert Found(actions) =
            replace_status(controller.actions, identity, Prepared)
          let next = Controller(..controller, actions: actions)
          let prepared =
            PreparedInvocation(controller.registry, context, call, identity)
          Ok(#(next, InvocationPrepared(prepared)))
        }
        Ok(Deny(reason)) -> {
          let report = denied_report(identity, call, reason)
          Ok(report_transition(controller, identity, report))
        }
        Ok(RequireApproval(requirement)) -> {
          let revision = controller.approval_revision + 1
          let reference = ApprovalReference(identity, requirement, revision)
          let request = ApprovalRequest(requirement, reference)
          let assert Found(actions) =
            replace_status(
              controller.actions,
              identity,
              AwaitingApproval(requirement, revision),
            )
          let next =
            Controller(
              ..controller,
              actions: actions,
              approval_revision: revision,
            )
          Ok(#(next, ApprovalRequired(request)))
        }
      }
  }
}

// Calling this function means dispatch was attempted and the caller cannot
// establish its result. It records uncertainty; it never invents a tool result.
pub fn report_unknown_effect(
  prepared: PreparedInvocation(context),
  evidence: String,
) -> ActionReport {
  let PreparedInvocation(_, _, call, identity) = prepared
  ActionReport(
    identity,
    OutcomeUnknown(UnknownEffect(identity, call_name(call), evidence)),
  )
}

// This is the only function that invokes a registered tool. It does not advance
// the provider; the caller must separately accept its returned report.
pub fn execute_prepared(prepared: PreparedInvocation(context)) -> ActionReport {
  let PreparedInvocation(registry, context, call, identity) = prepared
  let name = call_name(call)
  case fabric.dispatch(registry, context, name, call.arguments) {
    Ok(output) ->
      ActionReport(
        identity,
        ModelVisible(model.ToolSucceeded(call.id, output), ToolSucceeded),
      )
    Error(fabric.UnknownTool(unknown_name)) ->
      ActionReport(identity, HostFailure(RegistryMismatch(unknown_name)))
    Error(fabric.InvocationFailed(fabric.ActionFailed(error))) ->
      ActionReport(
        identity,
        ModelVisible(model.ToolFailed(call.id, error), DomainToolFailed(error)),
      )
    Error(fabric.InvocationFailed(fabric.InputRejected(error))) ->
      ActionReport(
        identity,
        HostFailure(BoundaryFailed(InputDecodeFailed(error))),
      )
    Error(fabric.InvocationFailed(fabric.OutputRejected(error))) ->
      ActionReport(
        identity,
        HostFailure(BoundaryFailed(OutputEncodeFailed(error))),
      )
    Error(fabric.InvocationFailed(fabric.ErrorRejected(error))) ->
      ActionReport(
        identity,
        HostFailure(BoundaryFailed(ErrorEncodeFailed(error))),
      )
  }
}

pub type ReportAcceptanceError {
  ForeignReport(ActionIdentity)
  ReportCallIdMismatch(ActionIdentity)
  DuplicateReport(ActionIdentity)
  ReportDoesNotMatchIssued(ActionIdentity)
  ReportNotReady(ActionIdentity)
  ReconciliationMismatch(ActionIdentity)
  UnknownEffectIdentity(ActionIdentity)
}

pub fn accept_report(
  controller: Controller(context, continuation),
  report: ActionReport,
) -> Result(Controller(context, continuation), ReportAcceptanceError) {
  let ActionReport(identity, outcome) = report
  case identity_incarnation(identity) == controller.incarnation {
    False -> Error(ForeignReport(identity))
    True ->
      case find_action(controller.actions, identity) {
        Missing -> Error(ForeignReport(identity))
        Found(ActionSlot(_, _, Accepted(_))) -> Error(DuplicateReport(identity))
        Found(ActionSlot(_, _, HostHalted(_))) ->
          Error(DuplicateReport(identity))
        Found(ActionSlot(_, _, ReconciliationRequired(_))) ->
          Error(DuplicateReport(identity))
        Found(ActionSlot(_, _, Uninspected)) -> Error(ReportNotReady(identity))
        Found(ActionSlot(_, _, AwaitingApproval(_, _))) ->
          Error(ReportNotReady(identity))
        Found(ActionSlot(_, _, ReportIssued(issued))) ->
          case issued == report {
            False -> Error(ReportDoesNotMatchIssued(identity))
            True ->
              validate_and_apply_report(controller, identity, report, outcome)
          }
        Found(ActionSlot(_, _, Prepared)) ->
          validate_and_apply_report(controller, identity, report, outcome)
      }
  }
}

fn validate_and_apply_report(
  controller: Controller(context, continuation),
  identity: ActionIdentity,
  report: ActionReport,
  outcome: ReportOutcome,
) -> Result(Controller(context, continuation), ReportAcceptanceError) {
  case model_result_matches_identity(outcome, identity) {
    False -> Error(ReportCallIdMismatch(identity))
    True -> apply_report_outcome(controller, identity, report, outcome)
  }
}

fn apply_report_outcome(
  controller: Controller(context, continuation),
  identity: ActionIdentity,
  report: ActionReport,
  outcome: ReportOutcome,
) -> Result(Controller(context, continuation), ReportAcceptanceError) {
  case outcome {
    ModelVisible(_, _) ->
      update_action_status(controller, identity, Accepted(report))
    HostFailure(_) ->
      update_action_status(controller, identity, HostHalted(report))
    OutcomeUnknown(effect) ->
      case unknown_effect_identity(effect) == identity {
        False -> Error(ReconciliationMismatch(identity))
        True ->
          update_action_status(
            controller,
            identity,
            ReconciliationRequired(effect),
          )
      }
  }
}

// Reconciliation supplies a known result from outside this pure controller.
// It is deliberately separate from inspection, invocation, and report acceptance.
pub fn reconcile_unknown_effect(
  controller: Controller(context, continuation),
  effect: UnknownEffect,
  result: model.ToolResult,
) -> Result(Controller(context, continuation), ReportAcceptanceError) {
  let identity = unknown_effect_identity(effect)
  case identity_incarnation(identity) == controller.incarnation {
    False -> Error(UnknownEffectIdentity(identity))
    True ->
      case model.result_id(result) == identity_call_id(identity) {
        False -> Error(ReportCallIdMismatch(identity))
        True ->
          case find_action(controller.actions, identity) {
            Missing -> Error(UnknownEffectIdentity(identity))
            Found(ActionSlot(_, _, ReconciliationRequired(current_effect))) ->
              case current_effect == effect {
                False -> Error(ReconciliationMismatch(identity))
                True -> {
                  let report =
                    ActionReport(
                      identity,
                      ModelVisible(result, EffectReconciled),
                    )
                  update_action_status(controller, identity, Accepted(report))
                }
              }
            Found(_) -> Error(UnknownEffectIdentity(identity))
          }
      }
  }
}

pub type ApprovalAnswerError {
  WrongApprovalReference
  StaleApprovalReference
  ApprovalAlreadyAnswered
}

pub type ApprovalResolution(context) {
  ApprovalInvocationPrepared(PreparedInvocation(context))
  ApprovalReportReady(ActionReport)
  ApprovalRequiredAgain(ApprovalRequest)
  ApprovalBlocked(ControllerBlocker)
}

pub fn answer_approval(
  controller: Controller(context, continuation),
  current_context: context,
  reference: ApprovalReference,
  answer: ApprovalAnswer,
) -> Result(
  #(Controller(context, continuation), ApprovalResolution(context)),
  ApprovalAnswerError,
) {
  let ApprovalReference(identity, reference_requirement, reference_revision) =
    reference
  case identity_incarnation(identity) == controller.incarnation {
    False -> Error(WrongApprovalReference)
    True ->
      case
        controller_blocker(
          controller.actions,
          controller.model_call_failure,
          controller.protocol_failure,
          controller.finished_output,
        )
      {
        Found(blocker) -> Ok(#(controller, ApprovalBlocked(blocker)))
        Missing ->
          case find_action(controller.actions, identity) {
            Missing ->
              case identity_run(identity) == controller.run {
                True -> Error(StaleApprovalReference)
                False -> Error(WrongApprovalReference)
              }
            Found(
              ActionSlot(_, _, AwaitingApproval(requirement, revision)) as slot,
            ) ->
              case
                requirement == reference_requirement
                && revision == reference_revision
              {
                False -> Error(StaleApprovalReference)
                True ->
                  recheck_approval(
                    controller,
                    current_context,
                    identity,
                    slot,
                    requirement,
                    answer,
                  )
              }
            Found(_) -> Error(ApprovalAlreadyAnswered)
          }
      }
  }
}

fn recheck_approval(
  controller: Controller(context, continuation),
  current_context: context,
  identity: ActionIdentity,
  slot: ActionSlot,
  old_requirement: ApprovalRequirement,
  answer: ApprovalAnswer,
) -> Result(
  #(Controller(context, continuation), ApprovalResolution(context)),
  ApprovalAnswerError,
) {
  let ActionSlot(_, call, _) = slot
  let registration =
    action_registration_for(controller.registry, call_name(call))
  case registration {
    Unregistered(name) ->
      Ok(report_resolution(
        controller,
        identity,
        unknown_tool_report(identity, call, name),
      ))
    Registered(declaration) ->
      case
        controller.policy(
          current_context,
          describe_action(identity, call, Registered(declaration)),
        )
      {
        Error(error) ->
          Ok(report_resolution(
            controller,
            identity,
            policy_failure_report(identity, error),
          ))
        Ok(Deny(reason)) ->
          Ok(report_resolution(
            controller,
            identity,
            denied_report(identity, call, reason),
          ))
        Ok(Allow) ->
          case answer {
            Approve ->
              Ok(prepare_resolution(controller, current_context, identity, call))
            Reject ->
              Ok(report_resolution(
                controller,
                identity,
                rejected_report(identity, call),
              ))
          }
        Ok(RequireApproval(new_requirement)) ->
          case new_requirement == old_requirement {
            False -> {
              case answer {
                Reject ->
                  Ok(report_resolution(
                    controller,
                    identity,
                    rejected_report(identity, call),
                  ))
                Approve -> {
                  let revision = controller.approval_revision + 1
                  let reference =
                    ApprovalReference(identity, new_requirement, revision)
                  let request = ApprovalRequest(new_requirement, reference)
                  let assert Found(actions) =
                    replace_status(
                      controller.actions,
                      identity,
                      AwaitingApproval(new_requirement, revision),
                    )
                  let next =
                    Controller(
                      ..controller,
                      actions: actions,
                      approval_revision: revision,
                    )
                  Ok(#(next, ApprovalRequiredAgain(request)))
                }
              }
            }
            True ->
              case answer {
                Approve ->
                  Ok(prepare_resolution(
                    controller,
                    current_context,
                    identity,
                    call,
                  ))
                Reject ->
                  Ok(report_resolution(
                    controller,
                    identity,
                    rejected_report(identity, call),
                  ))
              }
          }
      }
  }
}

fn prepare_resolution(
  controller: Controller(context, continuation),
  current_context: context,
  identity: ActionIdentity,
  call: model.ToolCall,
) -> #(Controller(context, continuation), ApprovalResolution(context)) {
  let assert Found(actions) =
    replace_status(controller.actions, identity, Prepared)
  let next = Controller(..controller, actions: actions)
  let prepared =
    PreparedInvocation(controller.registry, current_context, call, identity)
  #(next, ApprovalInvocationPrepared(prepared))
}

fn report_resolution(
  controller: Controller(context, continuation),
  identity: ActionIdentity,
  report: ActionReport,
) -> #(Controller(context, continuation), ApprovalResolution(context)) {
  let assert Found(actions) =
    replace_status(controller.actions, identity, ReportIssued(report))
  #(Controller(..controller, actions: actions), ApprovalReportReady(report))
}

pub type Advance(context, continuation) {
  AgentFinished(Controller(context, continuation), Value)
  MoreActions(Controller(context, continuation))
  BudgetExhausted(Controller(context, continuation))
  HostStoppedAdvance(Controller(context, continuation), ActionReport)
  ReconciliationRequiredAdvance(
    Controller(context, continuation),
    UnknownEffect,
  )
  ProviderCallFailedAdvance(Controller(context, continuation), llm.CallError)
  ProviderProtocolFailedAdvance(
    Controller(context, continuation),
    fabric_turn.TurnError,
  )
  AlreadyFinishedAdvance(Controller(context, continuation), Value)
}

pub type AdvanceError {
  ActionReportsOutstanding
  ModelAdvanceRejected(fabric_turn.TurnError)
}

pub fn continue_model(
  controller: Controller(context, continuation),
) -> Result(Advance(context, continuation), AdvanceError) {
  case
    controller_blocker(
      controller.actions,
      controller.model_call_failure,
      controller.protocol_failure,
      controller.finished_output,
    )
  {
    Found(HostStopped(report)) -> Ok(HostStoppedAdvance(controller, report))
    Found(ReconciliationPending(effect)) ->
      Ok(ReconciliationRequiredAdvance(controller, effect))
    Found(ProviderCallFailed(error)) ->
      Ok(ProviderCallFailedAdvance(controller, error))
    Found(ProviderProtocolFailed(error)) ->
      Ok(ProviderProtocolFailedAdvance(controller, error))
    Found(AlreadyFinished(output)) ->
      Ok(AlreadyFinishedAdvance(controller, output))
    Missing ->
      case model_turns_remaining(controller) > 0 {
        False -> Ok(BudgetExhausted(controller))
        True ->
          case accepted_results(controller.actions, []) {
            Missing -> Error(ActionReportsOutstanding)
            Found(results) -> advance_pending(controller, results)
          }
      }
  }
}

fn advance_pending(
  controller: Controller(context, continuation),
  results: List(model.ToolResult),
) -> Result(Advance(context, continuation), AdvanceError) {
  case fabric_turn.resume(controller.pending, results) {
    Error(fabric_turn.ModelFailed(error)) -> {
      let used = controller.model_turns_used + 1
      let next =
        Controller(
          ..controller,
          model_turns_used: used,
          model_call_failure: Found(error),
        )
      Ok(ProviderCallFailedAdvance(next, error))
    }
    Error(fabric_turn.EmptyToolBatch) ->
      protocol_failure_advance(controller, fabric_turn.EmptyToolBatch)
    Error(fabric_turn.DuplicateCallId(call_id)) ->
      protocol_failure_advance(controller, fabric_turn.DuplicateCallId(call_id))
    Error(error) -> Error(ModelAdvanceRejected(error))
    Ok(fabric_turn.Finished(output)) -> {
      let next =
        Controller(
          ..controller,
          model_turns_used: controller.model_turns_used + 1,
          finished_output: Found(output),
        )
      Ok(AgentFinished(next, output))
    }
    Ok(fabric_turn.NeedsTools(pending)) -> {
      let turn = controller.model_turns_used + 1
      Ok(MoreActions(
        Controller(
          ..controller,
          model_turns_used: turn,
          pending: pending,
          actions: action_slots(
            controller.run,
            controller.incarnation,
            turn,
            fabric_turn.calls(pending),
          ),
        ),
      ))
    }
  }
}

fn protocol_failure_advance(
  controller: Controller(context, continuation),
  error: fabric_turn.TurnError,
) -> Result(Advance(context, continuation), AdvanceError) {
  let next =
    Controller(
      ..controller,
      model_turns_used: controller.model_turns_used + 1,
      protocol_failure: Found(error),
    )
  Ok(ProviderProtocolFailedAdvance(next, error))
}

fn action_slots(
  run: RunId,
  incarnation: Incarnation,
  turn: Int,
  calls: List(model.ToolCall),
) -> List(ActionSlot) {
  case calls {
    [] -> []
    [call, ..rest] -> [
      ActionSlot(
        ActionIdentity(run, incarnation, turn, call.id),
        call,
        Uninspected,
      ),
      ..action_slots(run, incarnation, turn, rest)
    ]
  }
}

fn describe_actions(
  registry: fabric.Registry(context),
  actions: List(ActionSlot),
  reversed: List(ActionDescription),
) -> List(ActionDescription) {
  case actions {
    [] -> reverse(reversed, [])
    [ActionSlot(identity, call, _), ..rest] ->
      describe_actions(registry, rest, [
        describe_action(
          identity,
          call,
          action_registration_for(registry, call_name(call)),
        ),
        ..reversed
      ])
  }
}

fn describe_action(
  identity: ActionIdentity,
  call: model.ToolCall,
  registration: ActionRegistration,
) -> ActionDescription {
  ActionDescription(identity, call_name(call), call.arguments, registration)
}

fn action_registration_for(
  registry: fabric.Registry(context),
  name: String,
) -> ActionRegistration {
  case find_declaration(fabric.declarations(registry), name) {
    Missing -> Unregistered(name)
    Found(declaration) -> Registered(declaration)
  }
}

fn find_declaration(
  declarations: List(fabric.Declaration),
  name: String,
) -> Maybe(fabric.Declaration) {
  case declarations {
    [] -> Missing
    [fabric.Declaration(declaration_name, _) as declaration, ..rest] ->
      case declaration_name == name {
        True -> Found(declaration)
        False -> find_declaration(rest, name)
      }
  }
}

fn call_name(call: model.ToolCall) -> String {
  let model.ToolName(name) = call.name
  name
}

fn identity_call_id(identity: ActionIdentity) -> model.CallId {
  let ActionIdentity(_, _, _, call_id) = identity
  call_id
}

fn identity_run(identity: ActionIdentity) -> RunId {
  let ActionIdentity(run, _, _, _) = identity
  run
}

fn identity_incarnation(identity: ActionIdentity) -> Incarnation {
  let ActionIdentity(_, incarnation, _, _) = identity
  incarnation
}

fn model_result_matches_identity(
  outcome: ReportOutcome,
  identity: ActionIdentity,
) -> Bool {
  case outcome {
    ModelVisible(result, _) ->
      model.result_id(result) == identity_call_id(identity)
    HostFailure(_) -> True
    OutcomeUnknown(effect) -> unknown_effect_identity(effect) == identity
  }
}

fn find_action(
  actions: List(ActionSlot),
  identity: ActionIdentity,
) -> Maybe(ActionSlot) {
  case actions {
    [] -> Missing
    [ActionSlot(action_identity, _, _) as slot, ..rest] ->
      case action_identity == identity {
        True -> Found(slot)
        False -> find_action(rest, identity)
      }
  }
}

fn replace_status(
  actions: List(ActionSlot),
  identity: ActionIdentity,
  status: ActionStatus,
) -> Maybe(List(ActionSlot)) {
  case actions {
    [] -> Missing
    [ActionSlot(action_identity, call, _) as slot, ..rest] ->
      case action_identity == identity {
        True -> Found([ActionSlot(action_identity, call, status), ..rest])
        False ->
          case replace_status(rest, identity, status) {
            Missing -> Missing
            Found(updated) -> Found([slot, ..updated])
          }
      }
  }
}

fn update_action_status(
  controller: Controller(context, continuation),
  identity: ActionIdentity,
  status: ActionStatus,
) -> Result(Controller(context, continuation), ReportAcceptanceError) {
  case replace_status(controller.actions, identity, status) {
    Missing -> Error(ForeignReport(identity))
    Found(actions) -> Ok(Controller(..controller, actions: actions))
  }
}

fn accepted_results(
  actions: List(ActionSlot),
  reversed: List(model.ToolResult),
) -> Maybe(List(model.ToolResult)) {
  case actions {
    [] -> Found(reverse(reversed, []))
    [ActionSlot(_, _, Accepted(report)), ..rest] ->
      case report_outcome(report) {
        ModelVisible(result, _) -> accepted_results(rest, [result, ..reversed])
        _ -> Missing
      }
    [_slot, ..] -> Missing
  }
}

fn controller_blocker(
  actions: List(ActionSlot),
  call_failure: Maybe(llm.CallError),
  protocol_failure: Maybe(fabric_turn.TurnError),
  finished_output: Maybe(Value),
) -> Maybe(ControllerBlocker) {
  case call_failure {
    Found(error) -> Found(ProviderCallFailed(error))
    Missing ->
      case protocol_failure {
        Found(error) -> Found(ProviderProtocolFailed(error))
        Missing ->
          case finished_output {
            Found(output) -> Found(AlreadyFinished(output))
            Missing -> action_blocker(actions)
          }
      }
  }
}

fn action_blocker(actions: List(ActionSlot)) -> Maybe(ControllerBlocker) {
  case actions {
    [] -> Missing
    [ActionSlot(_, _, HostHalted(report)), ..] -> Found(HostStopped(report))
    [ActionSlot(_, _, ReconciliationRequired(effect)), ..] ->
      Found(ReconciliationPending(effect))
    [ActionSlot(_, _, ReportIssued(report)), ..rest] ->
      case report_outcome(report) {
        HostFailure(_) -> Found(HostStopped(report))
        OutcomeUnknown(effect) -> Found(ReconciliationPending(effect))
        ModelVisible(_, _) -> action_blocker(rest)
      }
    [_slot, ..rest] -> action_blocker(rest)
  }
}

fn denied_report(
  identity: ActionIdentity,
  call: model.ToolCall,
  reason: String,
) -> ActionReport {
  ActionReport(
    identity,
    ModelVisible(
      model.ToolFailed(call.id, value.Text(reason)),
      AuthorizationDenied(reason),
    ),
  )
}

fn unknown_tool_report(
  identity: ActionIdentity,
  call: model.ToolCall,
  name: String,
) -> ActionReport {
  ActionReport(
    identity,
    ModelVisible(
      model.ToolFailed(call.id, value.Text("unknown_tool")),
      UnknownTool(name),
    ),
  )
}

fn policy_failure_report(
  identity: ActionIdentity,
  error: PolicyError,
) -> ActionReport {
  ActionReport(identity, HostFailure(PolicyFailed(error)))
}

fn rejected_report(
  identity: ActionIdentity,
  call: model.ToolCall,
) -> ActionReport {
  ActionReport(
    identity,
    ModelVisible(
      model.ToolFailed(call.id, value.Text("approval_rejected")),
      ApprovalRejected,
    ),
  )
}

fn report_transition(
  controller: Controller(context, continuation),
  identity: ActionIdentity,
  report: ActionReport,
) -> #(Controller(context, continuation), Inspection(context)) {
  let assert Found(actions) =
    replace_status(controller.actions, identity, ReportIssued(report))
  #(Controller(..controller, actions: actions), ReportReady(report))
}

fn reverse(items: List(a), reversed: List(a)) -> List(a) {
  case items {
    [] -> reversed
    [item, ..rest] -> reverse(rest, [item, ..reversed])
  }
}
