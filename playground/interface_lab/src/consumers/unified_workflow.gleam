// THROWAWAY: Can one opaque Saga definition serve sequential, graph, checkpoint, and queue APIs?
import consumers/codec_connections
import consumers/conditional_graph
import consumers/shared_graph
import lab/blueprint
import lab/grind.{type Queue}
import lab/saga
import lab/saga_checkpoint as checkpoint
import lab/saga_grind
import lab/value

pub type Failure {
  NeverFails
}

// Composition retains two occurrences of the same opaque definition. Their
// runtime tokens and stable addresses must become distinct in the result.
pub fn repeated_definition() -> saga.Definition(
  String,
  String,
  Failure,
  Failure,
) {
  let version = required_version(1)
  let step_id = required_step_id("repeat.echo")
  let identity = required_definition_id("repeat.echo-definition")
  let codec = failure_codec()
  let contract =
    saga.ActivityContract(
      saga.VersionedCodec(version, blueprint.text()),
      saga.VersionedCodec(version, blueprint.text()),
      saga.VersionedCodec(version, codec),
      saga.VersionedCodec(version, codec),
    )
  let activity =
    saga.activity(
      step_id,
      version,
      contract,
      fn(text) { Ok(text) },
      saga.Uncompensated,
    )
  let definition =
    saga.define(identity, version, "repeat.echo-definition:v1", activity)
  saga.and_then("repeat.echo-twice:v1", definition, definition)
}

pub fn probe() -> Nil {
  let repeated = repeated_definition()
  let assert 3 = saga.node_count(repeated)
  let assert [left, boundary, right] = saga.steps(repeated)
  let assert 1 = saga.step_version_number(left)
  let assert [1, 1, 1, 1] = saga.codec_version_numbers(left)
  let assert saga.SequenceAdapterStep = boundary.kind
  let assert 1 = saga.step_version_number(boundary)
  let assert [1] = saga.codec_version_numbers(boundary)
  let assert saga.ActivityStep = right.kind
  let assert 1 = saga.step_version_number(right)
  let assert [1, 1, 1, 1] = saga.codec_version_numbers(right)

  let repeated_node = saga.NamedAddress(required_node_id("repeat.echo"))
  let left_node = saga.SequenceLeft(repeated_node)
  let right_node = saga.SequenceRight(repeated_node)
  let expected_steps = [
    saga.ScopedStepId(left_node, "repeat.echo"),
    saga.ScopedStepId(saga.SequenceBoundaryAddress, "sequence-boundary"),
    saga.ScopedStepId(right_node, "repeat.echo"),
  ]
  let actual_steps = saga.step_identities(repeated)
  let assert True = actual_steps == expected_steps
  let assert Error(saga.AmbiguousNodeId(_)) =
    saga.probe_direct(
      repeated,
      required_node_id("repeat.echo"),
      value.Text("must not select an arbitrary occurrence"),
    )
  let expected_dependencies = [
    saga.Dependency(saga.WorkflowInput, saga.NodeAt(left_node)),
    saga.Dependency(
      saga.NodeAt(left_node),
      saga.NodeAt(saga.SequenceBoundaryAddress),
    ),
    saga.Dependency(
      saga.NodeAt(saga.SequenceBoundaryAddress),
      saga.NodeAt(right_node),
    ),
  ]
  let actual_dependencies = result_dependencies(repeated)
  let assert True = actual_dependencies == expected_dependencies

  // This sequence keeps the same native type while changing its wire shape:
  // the first output is plain text and the next operation accepts boxed text.
  let adapted = codec_connections.example()
  let assert Ok(value.Object([#("text", value.Text("between steps"))])) =
    saga.probe_sequence_boundary(adapted, value.Text("between steps"))
  let assert Error(saga.SequenceAdapterRejected(_)) =
    saga.probe_sequence_boundary(adapted, value.Int(1))

  let identity_after =
    saga.and_then("repeat.then-identity:v1", repeated, identity_definition())
  let assert saga.SequenceBoundaryNode(saga.SequenceBoundaryAddress) =
    saga.output_label(identity_after)
  Nil
}

// These entry points are compile-time witnesses: shared graphs, conditional
// definitions, and the sequential workflow all use the same opaque Definition
// accepted by checkpoint and Grind. The TODO runtime boundaries are not called
// by probe().
pub fn start_shared(
  input: String,
) -> Result(
  checkpoint.Execution(
    shared_graph.ReviewResult,
    shared_graph.WorkflowError,
    shared_graph.UndoError,
  ),
  checkpoint.StartError,
) {
  checkpoint.start(shared_graph.order_review_graph(), input)
}

pub fn submit_shared(
  queue: Queue,
  input: String,
) -> Result(
  saga_grind.RunHandle(
    shared_graph.ReviewResult,
    shared_graph.WorkflowError,
    shared_graph.UndoError,
  ),
  saga_grind.SubmitError,
) {
  saga_grind.submit(queue, shared_graph.order_review_graph(), input)
}

pub fn start_conditional(
  input: conditional_graph.Order,
) -> Result(
  checkpoint.Execution(conditional_graph.Fulfilment, Nil, Nil),
  checkpoint.StartError,
) {
  checkpoint.start(conditional_graph.approval_graph(), input)
}

pub fn submit_conditional(
  queue: Queue,
  input: conditional_graph.Order,
) -> Result(
  saga_grind.RunHandle(conditional_graph.Fulfilment, Nil, Nil),
  saga_grind.SubmitError,
) {
  saga_grind.submit(queue, conditional_graph.approval_graph(), input)
}

fn result_dependencies(
  definition: saga.Definition(i, o, e, u),
) -> List(saga.Dependency) {
  let assert Ok(dependencies) = saga.dependencies(definition)
  dependencies
}

fn failure_codec() -> blueprint.Codec(Failure) {
  blueprint.imap(blueprint.text(), fn(_) { NeverFails }, fn(_) { "none" })
}

fn identity_definition() -> saga.Definition(String, String, Failure, Failure) {
  let version = required_version(1)
  let codec = failure_codec()
  let #(builder, input) = saga.begin(blueprint.text(), codec, codec)
  let assert Ok(definition) =
    saga.finish(
      builder,
      input,
      required_definition_id("identity"),
      version,
      "identity:v1",
    )
  definition
}

fn required_definition_id(value: String) -> saga.DefinitionId {
  let assert Ok(id) = saga.definition_id(value)
  id
}

fn required_node_id(value: String) -> saga.NodeId {
  let assert Ok(id) = saga.node_id(value)
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
