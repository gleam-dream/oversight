// THROWAWAY: Can approval select one typed Saga branch without leaking branch ports?
import lab/blueprint
import lab/saga
import lab/saga_checkpoint as checkpoint
import lab/value

pub type Order {
  Order(sku: String, quantity: Int)
}

pub type Fulfilment {
  Placed(Order)
  Declined(Order)
}

pub fn approval_graph() -> saga.Definition(Order, Fulfilment, Nil, Nil) {
  let #(builder, request) = saga.begin(order_codec(), nil_codec(), nil_codec())
  let #(builder, approval) =
    require_add(
      builder,
      request,
      required_node_id("approval"),
      approval_definition(),
    )
  let #(builder, selection) =
    require_add(
      builder,
      approval,
      required_node_id("selector"),
      selector_definition(),
    )
  let #(builder, result) =
    require_choice(
      builder,
      selection,
      required_node_id("checkout-choice"),
      placed_definition(),
      declined_definition(),
      fulfilment_codec(),
    )
  require_finish(builder, result)
}

// The probe inspects only retained structure and the pure codec router. It
// never runs an approval node or a branch definition.
pub fn probe() -> Nil {
  let workflow = approval_graph()
  let assert 3 = saga.node_count(workflow)
  let assert Ok(actual_edges) = saga.dependencies(workflow)
  let expected_edges = [
    saga.Dependency(saga.WorkflowInput, named_reference("approval")),
    saga.Dependency(named_reference("approval"), named_reference("selector")),
    saga.Dependency(
      named_reference("selector"),
      named_reference("checkout-choice"),
    ),
  ]
  let exact_edges = actual_edges == expected_edges
  let assert True = exact_edges

  let original = Order("original-sku", 3)
  let left_raw =
    choice_input(saga.ApprovalResult(original, saga.Approved(True)))
  let assert Ok(saga.SelectedBranch(saga.LeftBranch, left_payload)) =
    saga.inspect_choice(workflow, required_node_id("checkout-choice"), left_raw)
  let assert Ok(expected_left_payload) =
    blueprint.encode(reversed_order_codec(), original)
  let left_uses_branch_wire = left_payload == expected_left_payload
  let assert True = left_uses_branch_wire
  let assert Ok(source_payload) = blueprint.encode(order_codec(), original)
  let source_and_branch_wires_differ = left_payload != source_payload
  let assert True = source_and_branch_wires_differ

  let right_raw =
    choice_input(saga.ApprovalResult(original, saga.Approved(False)))
  let assert Ok(saga.SelectedBranch(saga.RightBranch, right_payload)) =
    saga.inspect_choice(
      workflow,
      required_node_id("checkout-choice"),
      right_raw,
    )
  let assert Ok(expected_right_payload) =
    blueprint.encode(order_codec(), original)
  let right_uses_branch_wire = right_payload == expected_right_payload
  let assert True = right_uses_branch_wire

  let assert Ok(left_output) =
    blueprint.encode(fulfilment_codec(), Placed(original))
  let left_step_identity =
    saga.BranchStepId(
      saga.BranchAddress(
        saga.NamedAddress(required_node_id("checkout-choice")),
        saga.LeftBranch,
        saga.NamedAddress(required_node_id("checkout.place")),
      ),
      saga.LeftBranch,
      "checkout.place",
    )
  let branch_snapshot =
    checkpoint.StepSnapshot(
      identity: left_step_identity,
      input: left_payload,
      operation_version: 1,
      codec_versions: [1, 1, 1, 1],
      result: checkpoint.StepSucceeded(left_output),
      selected_branches: [
        checkpoint.BranchSelection(
          saga.NamedAddress(required_node_id("checkout-choice")),
          saga.LeftBranch,
        ),
      ],
      compensation: checkpoint.NotCompensable,
    )
  let assert [
    checkpoint.BranchSelection(
      saga.NamedAddress(checkpointed_choice),
      checkpointed_side,
    ),
  ] = branch_snapshot.selected_branches
  let assert True = checkpointed_choice == required_node_id("checkout-choice")
  let assert saga.LeftBranch = checkpointed_side

  let denied_raw = choice_input(saga.ApprovalResult(original, saga.Denied))
  let assert Ok(saga.SelectedBranch(saga.RightBranch, _)) =
    saga.inspect_choice(
      workflow,
      required_node_id("checkout-choice"),
      denied_raw,
    )

  let malformed = value.Array([value.Text("neither"), value.Text("payload")])
  let assert Error(saga.ChoiceInputRejected(_)) =
    saga.inspect_choice(
      workflow,
      required_node_id("checkout-choice"),
      malformed,
    )

  let expected_steps = [
    saga.ScopedStepId(
      saga.NamedAddress(required_node_id("approval")),
      "approval",
    ),
    saga.ScopedStepId(
      saga.ChildAddress(
        saga.NamedAddress(required_node_id("approval")),
        saga.NamedAddress(required_node_id("approval.collect")),
      ),
      "approval.collect",
    ),
    saga.ScopedStepId(
      saga.NamedAddress(required_node_id("selector")),
      "selector",
    ),
    saga.ScopedStepId(
      saga.ChildAddress(
        saga.NamedAddress(required_node_id("selector")),
        saga.NamedAddress(required_node_id("approval.select-branch")),
      ),
      "approval.select-branch",
    ),
    saga.ScopedStepId(
      saga.NamedAddress(required_node_id("checkout-choice")),
      "checkout-choice",
    ),
    saga.BranchStepId(
      saga.BranchAddress(
        saga.NamedAddress(required_node_id("checkout-choice")),
        saga.LeftBranch,
        saga.NamedAddress(required_node_id("checkout.place")),
      ),
      saga.LeftBranch,
      "checkout.place",
    ),
    saga.BranchStepId(
      saga.BranchAddress(
        saga.NamedAddress(required_node_id("checkout-choice")),
        saga.RightBranch,
        saga.NamedAddress(required_node_id("checkout.decline")),
      ),
      saga.RightBranch,
      "checkout.decline",
    ),
  ]
  let actual_steps = saga.step_identities(workflow)
  let exact_step_scopes = actual_steps == expected_steps
  let assert True = exact_step_scopes
  Nil
}

fn approval_definition() -> saga.Definition(
  Order,
  saga.ApprovalResult(Order, Bool),
  Nil,
  Nil,
) {
  let version = required_version(1)
  let approval =
    saga.approval(
      required_step_id("approval.collect"),
      version,
      version,
      version,
      version,
      version,
      order_codec(),
      blueprint.bool(),
      nil_codec(),
      nil_codec(),
    )
  saga.define_approval(
    required_definition_id("checkout.approval"),
    version,
    "checkout.approval:v1",
    approval,
  )
}

fn selector_definition() -> saga.Definition(
  saga.ApprovalResult(Order, Bool),
  saga.Choice(Order, Order),
  Nil,
  Nil,
) {
  definition(
    "checkout.selector",
    "approval.select-branch",
    saga.approval_result_codec(order_codec(), blueprint.bool()),
    saga.choice_codec(order_codec(), order_codec()),
    fn(approval) { Ok(select_branch(approval)) },
  )
}

fn select_branch(
  approval: saga.ApprovalResult(Order, Bool),
) -> saga.Choice(Order, Order) {
  case approval.decision {
    saga.Approved(True) -> saga.Left(approval.input)
    saga.Approved(False) -> saga.Right(approval.input)
    saga.Denied -> saga.Right(approval.input)
  }
}

fn placed_definition() -> saga.Definition(Order, Fulfilment, Nil, Nil) {
  definition(
    "checkout.place",
    "checkout.place",
    reversed_order_codec(),
    placed_codec(),
    fn(order) { Ok(Placed(order)) },
  )
}

fn declined_definition() -> saga.Definition(Order, Fulfilment, Nil, Nil) {
  definition(
    "checkout.decline",
    "checkout.decline",
    order_codec(),
    declined_codec(),
    fn(order) { Ok(Declined(order)) },
  )
}

fn definition(
  identity: String,
  step: String,
  input: blueprint.Codec(a),
  output: blueprint.Codec(b),
  execute: fn(a) -> Result(b, Nil),
) -> saga.Definition(a, b, Nil, Nil) {
  let version = required_version(1)
  let activity =
    saga.activity(
      required_step_id(step),
      version,
      saga.ActivityContract(
        saga.VersionedCodec(version, input),
        saga.VersionedCodec(version, output),
        saga.VersionedCodec(version, nil_codec()),
        saga.VersionedCodec(version, nil_codec()),
      ),
      execute,
      saga.Uncompensated,
    )
  saga.define(
    required_definition_id(identity),
    version,
    identity <> ":v1",
    activity,
  )
}

fn order_codec() -> blueprint.Codec(Order) {
  blueprint.imap(
    blueprint.pair(blueprint.text(), blueprint.int()),
    fn(pair) { Order(pair.0, pair.1) },
    fn(order) {
      let Order(sku, quantity) = order
      #(sku, quantity)
    },
  )
}

fn reversed_order_codec() -> blueprint.Codec(Order) {
  blueprint.imap(
    blueprint.pair(blueprint.int(), blueprint.text()),
    fn(pair) { Order(pair.1, pair.0) },
    fn(order) {
      let Order(sku, quantity) = order
      #(quantity, sku)
    },
  )
}

fn placed_codec() -> blueprint.Codec(Fulfilment) {
  blueprint.imap(
    blueprint.pair(order_codec(), blueprint.bool()),
    fn(pair) {
      case pair.1 {
        True -> Placed(pair.0)
        False -> Declined(pair.0)
      }
    },
    fn(outcome) {
      case outcome {
        Placed(order) -> #(order, True)
        Declined(order) -> #(order, False)
      }
    },
  )
}

fn declined_codec() -> blueprint.Codec(Fulfilment) {
  blueprint.imap(
    blueprint.pair(blueprint.bool(), order_codec()),
    fn(pair) {
      case pair.0 {
        True -> Placed(pair.1)
        False -> Declined(pair.1)
      }
    },
    fn(outcome) {
      case outcome {
        Placed(order) -> #(True, order)
        Declined(order) -> #(False, order)
      }
    },
  )
}

fn fulfilment_codec() -> blueprint.Codec(Fulfilment) {
  blueprint.imap(
    saga.choice_codec(order_codec(), order_codec()),
    fn(choice) {
      case choice {
        saga.Left(order) -> Placed(order)
        saga.Right(order) -> Declined(order)
      }
    },
    fn(outcome) {
      case outcome {
        Placed(order) -> saga.Left(order)
        Declined(order) -> saga.Right(order)
      }
    },
  )
}

fn nil_codec() -> blueprint.Codec(Nil) {
  blueprint.new(fn(_) { Ok(value.Null) }, fn(raw) {
    case raw {
      value.Null -> Ok(Nil)
      _ -> Error(blueprint.CannotDecode("Expected null"))
    }
  })
}

fn choice_input(approval: saga.ApprovalResult(Order, Bool)) -> value.Value {
  let assert Ok(raw) =
    blueprint.encode(
      saga.choice_codec(order_codec(), order_codec()),
      select_branch(approval),
    )
  raw
}

fn require_add(
  builder: saga.Builder(Order, Nil, Nil),
  input: saga.Port(a),
  id: saga.NodeId,
  definition: saga.Definition(a, b, Nil, Nil),
) -> #(saga.Builder(Order, Nil, Nil), saga.Port(b)) {
  let assert Ok(result) = saga.add_child(builder, input, id, definition)
  result
}

fn require_choice(
  builder: saga.Builder(Order, Nil, Nil),
  input: saga.Port(saga.Choice(Order, Order)),
  id: saga.NodeId,
  left: saga.Definition(Order, Fulfilment, Nil, Nil),
  right: saga.Definition(Order, Fulfilment, Nil, Nil),
  output: blueprint.Codec(Fulfilment),
) -> #(saga.Builder(Order, Nil, Nil), saga.Port(Fulfilment)) {
  let assert Ok(result) =
    saga.choose_children(builder, input, id, left, right, output)
  result
}

fn require_finish(
  builder: saga.Builder(Order, Nil, Nil),
  output: saga.Port(Fulfilment),
) -> saga.Definition(Order, Fulfilment, Nil, Nil) {
  let assert Ok(result) =
    saga.finish(
      builder,
      output,
      required_definition_id("checkout.approval-workflow"),
      required_version(1),
      "checkout.approval-workflow:v1",
    )
  result
}

fn named_reference(name: String) -> saga.NodeReference {
  saga.NodeAt(saga.NamedAddress(required_node_id(name)))
}

fn required_node_id(value: String) -> saga.NodeId {
  let assert Ok(id) = saga.node_id(value)
  id
}

fn required_definition_id(value: String) -> saga.DefinitionId {
  let assert Ok(id) = saga.definition_id(value)
  id
}

fn required_step_id(value: String) -> saga.StepId {
  let assert Ok(id) = saga.step_id(value)
  id
}

fn required_version(value: Int) -> saga.Version {
  let assert Ok(version) = saga.version(value)
  version
}
