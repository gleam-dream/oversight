// THROWAWAY: Can one Saga definition compose an agent, approval, child, and confirmation?
import lab/blueprint.{type Codec}
import lab/fabric
import lab/grind.{type Queue}
import lab/saga.{type Definition}
import lab/saga_checkpoint
import lab/saga_grind
import lab/value

pub type CheckoutProposal {
  CheckoutProposal(String)
}

pub type ApprovalAnswer {
  ApprovalAnswer(String)
}

pub type CheckoutReceipt {
  CheckoutReceipt(String)
}

pub type Confirmation {
  Confirmation(String)
}

pub type WorkflowFailure {
  WorkflowFailure(String)
}

pub type UndoFailure {
  UndoFailure(String)
}

// The bounded agent proposes. It does not execute the checkout effect.
fn propose_checkout(
  request: String,
) -> Result(CheckoutProposal, WorkflowFailure) {
  Ok(CheckoutProposal(request <> " (proposed checkout)"))
}

// The side effect belongs to the inner child definition. A denied decision is
// an explicit business outcome and never falls through to checkout execution.
fn execute_checkout(
  approval: saga.ApprovalResult(CheckoutProposal, ApprovalAnswer),
) -> Result(CheckoutReceipt, WorkflowFailure) {
  case approval.decision {
    saga.Denied -> Error(WorkflowFailure("checkout approval denied"))
    saga.Approved(_answer) -> {
      let CheckoutProposal(_proposed_checkout) = approval.input
      todo as "perform the approved original checkout, not a proposal echoed by the approver"
    }
  }
}

fn undo_checkout(
  approval: saga.ApprovalResult(CheckoutProposal, ApprovalAnswer),
  _receipt: CheckoutReceipt,
) -> Result(Nil, UndoFailure) {
  case approval.decision {
    saga.Denied -> Ok(Nil)
    saga.Approved(_answer) ->
      todo as "compensate checkout from its committed receipt in the child journal"
  }
}

fn draft_confirmation(
  receipt: CheckoutReceipt,
) -> Result(Confirmation, WorkflowFailure) {
  let CheckoutReceipt(value) = receipt
  Ok(Confirmation("Checkout confirmed: " <> value))
}

pub fn workflow_definition() -> Definition(
  String,
  Confirmation,
  WorkflowFailure,
  UndoFailure,
) {
  let identity = required_definition_id("checkout.assistant")
  let definition_version = required_version(1)
  let flow_error = workflow_failure_codec()
  let undo_error = undo_failure_codec()
  let answer = approval_answer_codec()
  let proposal = checkout_proposal_codec()
  let receipt = checkout_receipt_codec()
  let confirmation = confirmation_codec()
  let approval_input = saga.approval_result_codec(proposal, answer)
  let proposal_agent = fabric.bounded(propose_checkout, [])

  let proposal_activity =
    saga.activity(
      required_step_id("agent.propose-checkout"),
      required_version(1),
      saga.ActivityContract(
        saga.VersionedCodec(required_version(1), blueprint.text()),
        saga.VersionedCodec(required_version(1), proposal),
        saga.VersionedCodec(required_version(1), flow_error),
        saga.VersionedCodec(required_version(1), undo_error),
      ),
      fn(request) { fabric.invoke_agent(proposal_agent, request) },
      saga.Uncompensated,
    )
  let proposal_definition =
    saga.define(
      identity,
      definition_version,
      "checkout.assistant:v1:proposal",
      proposal_activity,
    )

  let approval_node =
    saga.approval(
      required_step_id("approval.checkout"),
      required_version(1),
      required_version(1),
      required_version(1),
      required_version(1),
      required_version(1),
      proposal,
      answer,
      flow_error,
      undo_error,
    )
  let approval_definition =
    saga.define_approval(
      identity,
      definition_version,
      "checkout.assistant:v1:approval",
      approval_node,
    )

  let checkout_activity =
    saga.activity(
      required_step_id("checkout.forward"),
      required_version(1),
      saga.ActivityContract(
        saga.VersionedCodec(required_version(1), approval_input),
        saga.VersionedCodec(required_version(1), receipt),
        saga.VersionedCodec(required_version(1), flow_error),
        saga.VersionedCodec(required_version(1), undo_error),
      ),
      execute_checkout,
      saga.Compensate(undo_checkout),
    )
  let checkout_definition =
    saga.define(
      required_definition_id("checkout.child"),
      required_version(1),
      "checkout.child:v1:forward+compensation",
      checkout_activity,
    )
  let checkout_child =
    saga.child(
      required_step_id("child.checkout"),
      required_version(1),
      required_version(1),
      required_version(1),
      required_version(1),
      required_version(1),
      checkout_definition,
    )
  let checkout_child_definition =
    saga.define(
      identity,
      definition_version,
      "checkout.assistant:v1:child",
      checkout_child,
    )

  let confirmation_activity =
    saga.activity(
      required_step_id("confirmation.draft"),
      required_version(1),
      saga.ActivityContract(
        saga.VersionedCodec(required_version(1), receipt),
        saga.VersionedCodec(required_version(1), confirmation),
        saga.VersionedCodec(required_version(1), flow_error),
        saga.VersionedCodec(required_version(1), undo_error),
      ),
      draft_confirmation,
      saga.Uncompensated,
    )
  let confirmation_definition =
    saga.define(
      identity,
      definition_version,
      "checkout.assistant:v1:confirmation",
      confirmation_activity,
    )

  let after_approval =
    saga.and_then(
      "checkout.assistant:v1:proposal+approval",
      proposal_definition,
      approval_definition,
    )
  let after_child =
    saga.and_then(
      "checkout.assistant:v1:proposal+approval+child",
      after_approval,
      checkout_child_definition,
    )
  saga.and_then(
    "checkout.assistant:v1:complete",
    after_child,
    confirmation_definition,
  )
}

// The same definition can start locally or be submitted to Grind. Neither call
// returns Confirmation; both return a lifecycle handle that may be waiting.
pub fn start_locally(
  definition: Definition(String, Confirmation, WorkflowFailure, UndoFailure),
  input: String,
) -> Result(
  saga_checkpoint.Execution(Confirmation, WorkflowFailure, UndoFailure),
  saga_checkpoint.StartError,
) {
  saga_grind.run_local(definition, input)
}

pub fn submit_durably(
  queue: Queue,
  definition: Definition(String, Confirmation, WorkflowFailure, UndoFailure),
  input: String,
) -> Result(
  saga_grind.RunHandle(Confirmation, WorkflowFailure, UndoFailure),
  saga_grind.SubmitError,
) {
  saga_grind.submit(queue, definition, input)
}

// In a real child run, the runner returns an opaque receipt only when the host
// opts into compensation. Plain child completion is a separate public variant.
pub type CheckoutChildResult {
  PlainCheckout(CheckoutReceipt)
  CompensableCheckout(CheckoutReceipt, saga.CompensationReceipt)
}

fn string_codec(a: fn(String) -> t, b: fn(t) -> String) -> Codec(t) {
  blueprint.new(fn(item) { Ok(value.Text(b(item))) }, fn(raw) {
    case raw {
      value.Text(text) -> Ok(a(text))
      _ -> Error(blueprint.CannotDecode("Expected text"))
    }
  })
}

fn checkout_proposal_codec() -> Codec(CheckoutProposal) {
  string_codec(CheckoutProposal, fn(item) {
    let CheckoutProposal(text) = item
    text
  })
}

fn approval_answer_codec() -> Codec(ApprovalAnswer) {
  string_codec(ApprovalAnswer, fn(item) {
    let ApprovalAnswer(text) = item
    text
  })
}

fn checkout_receipt_codec() -> Codec(CheckoutReceipt) {
  string_codec(CheckoutReceipt, fn(item) {
    let CheckoutReceipt(text) = item
    text
  })
}

fn confirmation_codec() -> Codec(Confirmation) {
  string_codec(Confirmation, fn(item) {
    let Confirmation(text) = item
    text
  })
}

fn workflow_failure_codec() -> Codec(WorkflowFailure) {
  string_codec(WorkflowFailure, fn(item) {
    let WorkflowFailure(text) = item
    text
  })
}

fn undo_failure_codec() -> Codec(UndoFailure) {
  string_codec(UndoFailure, fn(item) {
    let UndoFailure(text) = item
    text
  })
}

fn required_definition_id(value: String) -> saga.DefinitionId {
  case saga.definition_id(value) {
    Ok(identity) -> identity
    Error(_) ->
      todo as "static interface fixture uses a non-empty definition identity"
  }
}

fn required_step_id(value: String) -> saga.StepId {
  case saga.step_id(value) {
    Ok(identity) -> identity
    Error(_) -> todo as "static interface fixture uses a non-empty step identity"
  }
}

fn required_version(value: Int) -> saga.Version {
  case saga.version(value) {
    Ok(version) -> version
    Error(_) -> todo as "static interface fixture uses a positive version"
  }
}
