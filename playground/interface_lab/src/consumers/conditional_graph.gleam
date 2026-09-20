// THROWAWAY: Can approval select one typed Saga branch without leaking branch ports?
import lab/blueprint
import lab/saga
import lab/saga_graph as graph
import lab/value

pub type Order {
  Order(sku: String, quantity: Int)
}

pub type Fulfilment {
  Placed(Order)
  Declined(Order)
}

pub fn approval_graph() -> graph.Graph(Order, Fulfilment, Nil, Nil) {
  let #(builder, request) = graph.begin(order_codec(), nil_codec(), nil_codec())
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
  let assert 3 = graph.node_count(workflow)
  let assert Ok(actual_edges) = graph.dependencies(workflow)
  let expected_edges = [
    graph.Dependency(
      graph.InputPort,
      graph.DefinitionNode(required_node_id("approval")),
    ),
    graph.Dependency(
      graph.DefinitionNode(required_node_id("approval")),
      graph.DefinitionNode(required_node_id("selector")),
    ),
    graph.Dependency(
      graph.DefinitionNode(required_node_id("selector")),
      graph.ChoiceNode(required_node_id("checkout-choice")),
    ),
  ]
  let exact_edges = actual_edges == expected_edges
  let assert True = exact_edges

  let original = Order("original-sku", 3)
  let left_raw =
    choice_input(saga.ApprovalResult(original, saga.Approved(True)))
  let assert Ok(graph.SelectedBranch(graph.LeftBranch, left_payload)) =
    graph.inspect_choice(
      workflow,
      required_node_id("checkout-choice"),
      left_raw,
    )
  let assert Ok(expected_left_payload) =
    blueprint.encode(reversed_order_codec(), original)
  let left_uses_branch_wire = left_payload == expected_left_payload
  let assert True = left_uses_branch_wire
  let assert Ok(source_payload) = blueprint.encode(order_codec(), original)
  let source_and_branch_wires_differ = left_payload != source_payload
  let assert True = source_and_branch_wires_differ

  let right_raw =
    choice_input(saga.ApprovalResult(original, saga.Approved(False)))
  let assert Ok(graph.SelectedBranch(graph.RightBranch, right_payload)) =
    graph.inspect_choice(
      workflow,
      required_node_id("checkout-choice"),
      right_raw,
    )
  let assert Ok(expected_right_payload) =
    blueprint.encode(order_codec(), original)
  let right_uses_branch_wire = right_payload == expected_right_payload
  let assert True = right_uses_branch_wire

  let denied_raw = choice_input(saga.ApprovalResult(original, saga.Denied))
  let assert Ok(graph.SelectedBranch(graph.RightBranch, _)) =
    graph.inspect_choice(
      workflow,
      required_node_id("checkout-choice"),
      denied_raw,
    )

  let malformed = value.Array([value.Text("neither"), value.Text("payload")])
  let assert Error(graph.ChoiceInputRejected(_)) =
    graph.inspect_choice(
      workflow,
      required_node_id("checkout-choice"),
      malformed,
    )

  let expected_steps = [
    graph.ScopedStepId(required_node_id("approval"), "approval.collect"),
    graph.ScopedStepId(required_node_id("selector"), "approval.select-branch"),
    graph.BranchStepId(
      required_node_id("checkout-choice"),
      graph.LeftBranch,
      "checkout.place",
    ),
    graph.BranchStepId(
      required_node_id("checkout-choice"),
      graph.RightBranch,
      "checkout.decline",
    ),
  ]
  let actual_steps = graph.step_identities(workflow)
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
  graph.Choice(Order, Order),
  Nil,
  Nil,
) {
  definition(
    "checkout.selector",
    "approval.select-branch",
    saga.approval_result_codec(order_codec(), blueprint.bool()),
    graph.choice_codec(order_codec(), order_codec()),
    fn(approval) { Ok(select_branch(approval)) },
  )
}

fn select_branch(
  approval: saga.ApprovalResult(Order, Bool),
) -> graph.Choice(Order, Order) {
  case approval.decision {
    saga.Approved(True) -> graph.Left(approval.input)
    saga.Approved(False) -> graph.Right(approval.input)
    saga.Denied -> graph.Right(approval.input)
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
      version,
      version,
      version,
      version,
      input,
      output,
      nil_codec(),
      nil_codec(),
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
    graph.choice_codec(order_codec(), order_codec()),
    fn(choice) {
      case choice {
        graph.Left(order) -> Placed(order)
        graph.Right(order) -> Declined(order)
      }
    },
    fn(outcome) {
      case outcome {
        Placed(order) -> graph.Left(order)
        Declined(order) -> graph.Right(order)
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
      graph.choice_codec(order_codec(), order_codec()),
      select_branch(approval),
    )
  raw
}

fn require_add(
  builder: graph.Builder(Order, Nil, Nil),
  input: graph.Port(a),
  id: graph.NodeId,
  definition: saga.Definition(a, b, Nil, Nil),
) -> #(graph.Builder(Order, Nil, Nil), graph.Port(b)) {
  let assert Ok(result) = graph.add(builder, input, id, definition)
  result
}

fn require_choice(
  builder: graph.Builder(Order, Nil, Nil),
  input: graph.Port(graph.Choice(Order, Order)),
  id: graph.NodeId,
  left: saga.Definition(Order, Fulfilment, Nil, Nil),
  right: saga.Definition(Order, Fulfilment, Nil, Nil),
  output: blueprint.Codec(Fulfilment),
) -> #(graph.Builder(Order, Nil, Nil), graph.Port(Fulfilment)) {
  let assert Ok(result) = graph.choose(builder, input, id, left, right, output)
  result
}

fn require_finish(
  builder: graph.Builder(Order, Nil, Nil),
  output: graph.Port(Fulfilment),
) -> graph.Graph(Order, Fulfilment, Nil, Nil) {
  let assert Ok(result) = graph.finish(builder, output)
  result
}

fn required_node_id(value: String) -> graph.NodeId {
  let assert Ok(id) = graph.node_id(value)
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
