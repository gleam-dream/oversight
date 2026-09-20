// THROWAWAY: Can one retained Saga producer feed independent checks and a join?
import lab/blueprint
import lab/saga

pub type OrderId {
  OrderId(String)
}

pub type CreditReview {
  CreditReview(order: OrderId, clear: Bool)
}

pub type StockReview {
  StockReview(order: OrderId, available: Bool)
}

pub type ReviewResult {
  ReviewResult(order: OrderId, ready: Bool)
}

pub type WorkflowError {
  ReviewFailed
}

pub type UndoError {
  UndoFailed
}

pub fn order_review_graph() -> saga.Definition(
  String,
  ReviewResult,
  WorkflowError,
  UndoError,
) {
  let #(builder, request) =
    saga.begin(blueprint.text(), workflow_error_codec(), undo_error_codec())
  let #(builder, order) =
    require_add(
      builder,
      request,
      required_node_id("create-order"),
      order_definition(),
    )
  // Both checks consume the same retained producer port. There is one
  // create-order graph node and two incoming consumers of its output.
  let #(builder, credit) =
    require_add(
      builder,
      order,
      required_node_id("review-credit"),
      credit_definition(),
    )
  let #(builder, stock) =
    require_add(
      builder,
      order,
      required_node_id("review-stock"),
      stock_definition(),
    )
  let #(builder, checks) = require_pair(builder, credit, stock)
  let #(builder, result) =
    require_add(
      builder,
      checks,
      required_node_id("summarize-review"),
      summary_definition(),
    )
  require_finish(builder, result)
}

// The construction probe also exercises the dynamic rules that Gleam's port
// types alone cannot establish: forked ports are foreign, IDs are unique,
// and every retained node contributes to the selected result.
pub fn probe() -> Nil {
  let review = order_review_graph()
  let assert 5 = saga.node_count(review)
  let assert Ok(actual_dependencies) = saga.dependencies(review)
  let expected_dependencies = [
    saga.Dependency(saga.WorkflowInput, named_reference("create-order")),
    saga.Dependency(
      named_reference("create-order"),
      named_reference("review-credit"),
    ),
    saga.Dependency(
      named_reference("create-order"),
      named_reference("review-stock"),
    ),
    saga.Dependency(
      named_reference("review-credit"),
      saga.NodeAt(saga.PairAddress(0)),
    ),
    saga.Dependency(
      named_reference("review-stock"),
      saga.NodeAt(saga.PairAddress(0)),
    ),
    saga.Dependency(
      saga.NodeAt(saga.PairAddress(0)),
      named_reference("summarize-review"),
    ),
  ]
  let assert True =
    dependencies_match(actual_dependencies, expected_dependencies)

  let #(fork, source) =
    saga.begin(blueprint.text(), workflow_error_codec(), undo_error_codec())
  let same_node_id = required_node_id("forked-id")
  let #(left_builder, _order_port) =
    require_add(fork, source, same_node_id, order_definition())
  let #(_, foreign_text_port) =
    require_add(fork, source, same_node_id, echo_definition())
  let assert Error(saga.ForeignPort) =
    finish_as(left_builder, foreign_text_port, "foreign-port")

  let #(builder, first_port) =
    require_add(
      fork,
      source,
      required_node_id("first-copy"),
      order_definition(),
    )
  let #(builder, second_port) =
    require_add(
      builder,
      source,
      required_node_id("second-copy"),
      order_definition(),
    )
  let #(builder, both_orders) = require_pair(builder, first_port, second_port)
  let assert Ok(_reused) = finish_as(builder, both_orders, "reused-output")

  let #(with_first, first_output) =
    require_add(fork, source, required_node_id("kept"), order_definition())
  let #(with_orphan, _orphan_output) =
    require_add(
      with_first,
      source,
      required_node_id("orphan"),
      echo_definition(),
    )
  let assert Error(saga.UnreachableNode(_)) =
    finish_as(with_orphan, first_output, "orphan-output")

  let assert Error(saga.DuplicateNodeId(duplicate)) =
    duplicate_id_result(fork, source, same_node_id)
  let assert True = node_ids_match(same_node_id, duplicate)
  Nil
}

fn node_ids_match(left: saga.NodeId, right: saga.NodeId) -> Bool {
  left == right
}

fn dependencies_match(
  actual: List(saga.Dependency),
  expected: List(saga.Dependency),
) -> Bool {
  actual == expected
}

fn duplicate_id_result(
  builder: saga.Builder(String, WorkflowError, UndoError),
  source: saga.Port(String),
  id: saga.NodeId,
) -> Result(
  #(saga.Builder(String, WorkflowError, UndoError), saga.Port(OrderId)),
  saga.BuildError,
) {
  let assert Ok(#(after_first, _)) =
    saga.add_child(builder, source, id, order_definition())
  saga.add_child(after_first, source, id, order_definition())
}

fn order_definition() -> saga.Definition(
  String,
  OrderId,
  WorkflowError,
  UndoError,
) {
  definition(
    "orders.create",
    "create-order",
    blueprint.text(),
    order_id_codec(),
    fn(request) { Ok(OrderId("order:" <> request)) },
  )
}

fn credit_definition() -> saga.Definition(
  OrderId,
  CreditReview,
  WorkflowError,
  UndoError,
) {
  definition(
    "orders.credit-review",
    "credit-review",
    order_id_codec(),
    credit_review_codec(),
    fn(order) { Ok(CreditReview(order, True)) },
  )
}

fn stock_definition() -> saga.Definition(
  OrderId,
  StockReview,
  WorkflowError,
  UndoError,
) {
  definition(
    "orders.stock-review",
    "stock-review",
    order_id_codec(),
    stock_review_codec(),
    fn(order) { Ok(StockReview(order, True)) },
  )
}

fn summary_definition() -> saga.Definition(
  #(CreditReview, StockReview),
  ReviewResult,
  WorkflowError,
  UndoError,
) {
  definition(
    "orders.summarize-review",
    "summarize-review",
    blueprint.pair(credit_review_codec(), stock_review_codec()),
    review_result_codec(),
    fn(reviews) {
      let #(
        CreditReview(credit_order, clear),
        StockReview(stock_order, available),
      ) = reviews
      case credit_order == stock_order {
        True -> Ok(ReviewResult(credit_order, clear && available))
        False -> Error(ReviewFailed)
      }
    },
  )
}

fn echo_definition() -> saga.Definition(
  String,
  String,
  WorkflowError,
  UndoError,
) {
  definition(
    "orders.echo",
    "echo",
    blueprint.text(),
    blueprint.text(),
    fn(text) { Ok(text) },
  )
}

fn definition(
  identity: String,
  step: String,
  input: blueprint.Codec(a),
  output: blueprint.Codec(b),
  execute: fn(a) -> Result(b, WorkflowError),
) -> saga.Definition(a, b, WorkflowError, UndoError) {
  let step_version = required_version(1)
  let operation =
    saga.activity(
      required_step_id(step),
      step_version,
      saga.ActivityContract(
        saga.VersionedCodec(step_version, input),
        saga.VersionedCodec(step_version, output),
        saga.VersionedCodec(step_version, workflow_error_codec()),
        saga.VersionedCodec(step_version, undo_error_codec()),
      ),
      execute,
      saga.Uncompensated,
    )
  saga.define(
    required_definition_id(identity),
    step_version,
    identity <> ":v1",
    operation,
  )
}

fn order_id_codec() -> blueprint.Codec(OrderId) {
  blueprint.imap(blueprint.text(), OrderId, fn(order) {
    let OrderId(value) = order
    value
  })
}

fn credit_review_codec() -> blueprint.Codec(CreditReview) {
  blueprint.imap(
    blueprint.pair(order_id_codec(), blueprint.bool()),
    fn(pair) { CreditReview(pair.0, pair.1) },
    fn(review) {
      let CreditReview(order, clear) = review
      #(order, clear)
    },
  )
}

fn stock_review_codec() -> blueprint.Codec(StockReview) {
  blueprint.imap(
    blueprint.pair(order_id_codec(), blueprint.bool()),
    fn(pair) { StockReview(pair.0, pair.1) },
    fn(review) {
      let StockReview(order, available) = review
      #(order, available)
    },
  )
}

fn review_result_codec() -> blueprint.Codec(ReviewResult) {
  blueprint.imap(
    blueprint.pair(order_id_codec(), blueprint.bool()),
    fn(pair) { ReviewResult(pair.0, pair.1) },
    fn(result) {
      let ReviewResult(order, ready) = result
      #(order, ready)
    },
  )
}

fn workflow_error_codec() -> blueprint.Codec(WorkflowError) {
  blueprint.imap(blueprint.text(), fn(_) { ReviewFailed }, fn(_) {
    "review-failed"
  })
}

fn undo_error_codec() -> blueprint.Codec(UndoError) {
  blueprint.imap(blueprint.text(), fn(_) { UndoFailed }, fn(_) { "undo-failed" })
}

fn require_add(
  builder: saga.Builder(i, WorkflowError, UndoError),
  input: saga.Port(a),
  id: saga.NodeId,
  definition: saga.Definition(a, b, WorkflowError, UndoError),
) -> #(saga.Builder(i, WorkflowError, UndoError), saga.Port(b)) {
  let assert Ok(result) = saga.add_child(builder, input, id, definition)
  result
}

fn require_pair(
  builder: saga.Builder(i, WorkflowError, UndoError),
  left: saga.Port(a),
  right: saga.Port(b),
) -> #(saga.Builder(i, WorkflowError, UndoError), saga.Port(#(a, b))) {
  let assert Ok(result) = saga.pair(builder, left, right)
  result
}

fn require_finish(
  builder: saga.Builder(i, WorkflowError, UndoError),
  output: saga.Port(o),
) -> saga.Definition(i, o, WorkflowError, UndoError) {
  let assert Ok(result) = finish_as(builder, output, "orders.review-graph")
  result
}

fn finish_as(
  builder: saga.Builder(i, WorkflowError, UndoError),
  output: saga.Port(o),
  identity: String,
) -> Result(saga.Definition(i, o, WorkflowError, UndoError), saga.BuildError) {
  saga.finish(
    builder,
    output,
    required_definition_id(identity),
    required_version(1),
    identity <> ":v1",
  )
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
