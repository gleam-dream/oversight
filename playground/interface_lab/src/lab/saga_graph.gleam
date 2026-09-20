// THROWAWAY: Can one Saga producer feed typed parallel checks and a join?
import lab/blueprint.{type Codec}
import lab/saga
import lab/value.{type Value}

pub type IdentityError {
  NodeIdentityMustNotBeEmpty
}

pub opaque type NodeId {
  NodeId(String)
}

pub fn node_id(value: String) -> Result(NodeId, IdentityError) {
  case value {
    "" -> Error(NodeIdentityMustNotBeEmpty)
    _ -> Ok(NodeId(value))
  }
}

pub type BuildError {
  ForeignPort
  DuplicateNodeId(NodeId)
  DuplicateStepId(String)
  UnreachableNode(NodeLabel)
}

pub type NodeLabel {
  InputPort
  DefinitionNode(NodeId)
  PairNode(Int)
}

pub type Dependency {
  Dependency(from: NodeLabel, to: NodeLabel)
}

pub type ScopedStepId {
  ScopedStepId(node: NodeId, step_id: String)
}

pub type InspectionError {
  MissingDependencyPort
}

pub type NodeBoundaryError {
  UnexpectedInputCount(Int)
  InputValueDidNotDecode(blueprint.DecodeError)
  InputValueDidNotEncode(blueprint.EncodeError)
  OutputValueDidNotEncode(blueprint.EncodeError)
}

pub type NodeOutcome(e, u) {
  NodeSucceeded(Value)
  NodeFailed(cause: e, undo_failures: List(u))
  NodeWaiting(child_run_id: String)
  NodeCancelled(undo_failures: List(u))
  NodeNeedsReconciliation(evidence: Value)
  NodeBoundaryFailed(NodeBoundaryError)
}

type Token {
  Token(Int)
}

type Maybe(a) {
  Missing
  Present(a)
}

type Node(e, u) {
  Node(
    token: Token,
    label: NodeLabel,
    inputs: List(Token),
    step_identities: List(ScopedStepId),
    evaluate: fn(List(Value)) -> NodeOutcome(e, u),
  )
}

// Fresh construction tokens are deliberately VM-local and never enter a
// Saga snapshot. Stable identities remain the caller's NodeId and Saga steps.
@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn fresh_token() -> Token {
  Token(unique_integer())
}

pub opaque type Port(a) {
  Port(token: Token, codec: Codec(a), label: NodeLabel)
}

pub opaque type Builder(i, e, u) {
  Builder(
    input_token: Token,
    input_codec: Codec(i),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
    nodes: List(Node(e, u)),
    node_ids: List(NodeId),
    step_identities: List(ScopedStepId),
    next_pair_label: Int,
  )
}

pub opaque type Graph(i, o, e, u) {
  Graph(
    input_token: Token,
    input_codec: Codec(i),
    output: Port(o),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
    nodes: List(Node(e, u)),
  )
}

// Begin a graph with a typed source port. Graph and port values are
// construction artifacts, not runnable Saga definitions.
pub fn begin(
  input: Codec(i),
  error: Codec(e),
  undo_error: Codec(u),
) -> #(Builder(i, e, u), Port(i)) {
  let token = fresh_token()
  #(
    Builder(token, input, error, undo_error, [], [], [], 0),
    Port(token, input, InputPort),
  )
}

// Add one retained Saga definition after any existing typed port. The
// definition remains captured by its evaluator closure; this module does not
// schedule that closure or claim Saga's runtime semantics.
pub fn add(
  builder: Builder(i, e, u),
  input: Port(a),
  id: NodeId,
  definition: saga.Definition(a, b, e, u),
) -> Result(#(Builder(i, e, u), Port(b)), BuildError) {
  case contains_token(builder.input_token, builder.nodes, input.token) {
    False -> Error(ForeignPort)
    True ->
      case contains_node_id(id, builder.node_ids) {
        True -> Error(DuplicateNodeId(id))
        False -> {
          let raw_step_ids = descriptor_step_ids(saga.steps(definition))
          case first_duplicate(raw_step_ids, []) {
            Present(duplicate) -> Error(DuplicateStepId(duplicate))
            Missing -> {
              let step_ids = scope_step_ids(id, raw_step_ids)
              let output = saga.output_codec(definition)
              let node =
                Node(
                  fresh_token(),
                  DefinitionNode(id),
                  [input.token],
                  step_ids,
                  definition_evaluator(
                    input.codec,
                    saga.input_codec(definition),
                    output,
                    definition,
                  ),
                )
              let next =
                Builder(
                  ..builder,
                  nodes: append(builder.nodes, [node]),
                  node_ids: append(builder.node_ids, [id]),
                  step_identities: append(builder.step_identities, step_ids),
                )
              Ok(#(next, Port(node.token, output, node.label)))
            }
          }
        }
      }
  }
}

// Pair is a real codec-backed join node. It records both incoming edges and
// produces a tuple port that can feed another Saga definition.
pub fn pair(
  builder: Builder(i, e, u),
  left: Port(a),
  right: Port(b),
) -> Result(#(Builder(i, e, u), Port(#(a, b))), BuildError) {
  case
    contains_token(builder.input_token, builder.nodes, left.token),
    contains_token(builder.input_token, builder.nodes, right.token)
  {
    True, True -> {
      let token = fresh_token()
      let label = PairNode(builder.next_pair_label)
      let output = blueprint.pair(left.codec, right.codec)
      let node =
        Node(
          token,
          label,
          [left.token, right.token],
          [],
          pair_evaluator(left.codec, right.codec, output),
        )
      let next =
        Builder(
          ..builder,
          nodes: append(builder.nodes, [node]),
          next_pair_label: builder.next_pair_label + 1,
        )
      Ok(#(next, Port(token, output, label)))
    }
    _, _ -> Error(ForeignPort)
  }
}

// Selecting a final port seals the retained graph. It does not create a
// runnable saga.Definition because Saga's scheduler remains a separate owner.
pub fn finish(
  builder: Builder(i, e, u),
  output: Port(o),
) -> Result(Graph(i, o, e, u), BuildError) {
  case contains_token(builder.input_token, builder.nodes, output.token) {
    False -> Error(ForeignPort)
    True -> {
      let reachable =
        mark_reachable(output.token, builder.input_token, builder.nodes, [])
      case first_unreachable(builder.nodes, reachable) {
        Present(label) -> Error(UnreachableNode(label))
        Missing ->
          Ok(Graph(
            builder.input_token,
            builder.input_codec,
            output,
            builder.error_codec,
            builder.undo_error_codec,
            builder.nodes,
          ))
      }
    }
  }
}

pub fn node_count(graph: Graph(i, o, e, u)) -> Int {
  length(graph.nodes)
}

pub fn output_label(graph: Graph(i, o, e, u)) -> NodeLabel {
  graph.output.label
}

pub fn step_identities(graph: Graph(i, o, e, u)) -> List(ScopedStepId) {
  graph.nodes
  |> flatten_all_step_identities
}

pub fn dependencies(
  graph: Graph(i, o, e, u),
) -> Result(List(Dependency), InspectionError) {
  dependencies_from(graph.input_token, graph.nodes, graph.nodes)
}

fn definition_evaluator(
  source_codec: Codec(a),
  input_codec: Codec(a),
  output_codec: Codec(b),
  definition: saga.Definition(a, b, e, u),
) -> fn(List(Value)) -> NodeOutcome(e, u) {
  fn(inputs) {
    case inputs {
      [raw_input] ->
        case blueprint.decode(source_codec, raw_input) {
          Error(error) -> NodeBoundaryFailed(InputValueDidNotDecode(error))
          Ok(typed_input) ->
            case blueprint.encode(input_codec, typed_input) {
              Error(error) -> NodeBoundaryFailed(InputValueDidNotEncode(error))
              Ok(encoded_input) ->
                case blueprint.decode(input_codec, encoded_input) {
                  Error(error) ->
                    NodeBoundaryFailed(InputValueDidNotDecode(error))
                  Ok(value) ->
                    case saga.run_child(definition, value) {
                      saga.ChildSucceeded(output) ->
                        case blueprint.encode(output_codec, output) {
                          Ok(encoded) -> NodeSucceeded(encoded)
                          Error(error) ->
                            NodeBoundaryFailed(OutputValueDidNotEncode(error))
                        }
                      saga.ChildFailed(cause, undo_failures) ->
                        NodeFailed(cause, undo_failures)
                      saga.ChildCancelled(undo_failures) ->
                        NodeCancelled(undo_failures)
                      saga.ChildWaiting(run_id) -> NodeWaiting(run_id)
                      saga.ChildNeedsReconciliation(evidence) ->
                        NodeNeedsReconciliation(evidence)
                    }
                }
            }
        }
      other -> NodeBoundaryFailed(UnexpectedInputCount(length(other)))
    }
  }
}

fn pair_evaluator(
  left_codec: Codec(a),
  right_codec: Codec(b),
  pair_codec: Codec(#(a, b)),
) -> fn(List(Value)) -> NodeOutcome(e, u) {
  fn(inputs) {
    case inputs {
      [left, right] ->
        case blueprint.decode(left_codec, left) {
          Error(error) -> NodeBoundaryFailed(InputValueDidNotDecode(error))
          Ok(left_value) ->
            case blueprint.decode(right_codec, right) {
              Error(error) -> NodeBoundaryFailed(InputValueDidNotDecode(error))
              Ok(right_value) ->
                case blueprint.encode(pair_codec, #(left_value, right_value)) {
                  Ok(encoded) -> NodeSucceeded(encoded)
                  Error(error) ->
                    NodeBoundaryFailed(InputValueDidNotEncode(error))
                }
            }
        }
      other -> NodeBoundaryFailed(UnexpectedInputCount(length(other)))
    }
  }
}

fn contains_token(input: Token, nodes: List(Node(e, u)), token: Token) -> Bool {
  case input == token {
    True -> True
    False -> token_in_nodes(nodes, token)
  }
}

fn token_in_nodes(nodes: List(Node(e, u)), token: Token) -> Bool {
  case nodes {
    [] -> False
    [Node(found, _, _, _, _), ..rest] ->
      case found == token {
        True -> True
        False -> token_in_nodes(rest, token)
      }
  }
}

fn contains_node_id(id: NodeId, ids: List(NodeId)) -> Bool {
  case ids {
    [] -> False
    [found, ..rest] ->
      case id == found {
        True -> True
        False -> contains_node_id(id, rest)
      }
  }
}

fn first_duplicate(
  candidates: List(String),
  existing: List(String),
) -> Maybe(String) {
  case candidates {
    [] -> Missing
    [candidate, ..rest] ->
      case
        contains_string(candidate, existing) || contains_string(candidate, rest)
      {
        True -> Present(candidate)
        False -> first_duplicate(rest, existing)
      }
  }
}

fn contains_string(value: String, values: List(String)) -> Bool {
  case values {
    [] -> False
    [found, ..rest] ->
      case value == found {
        True -> True
        False -> contains_string(value, rest)
      }
  }
}

fn descriptor_step_ids(descriptors: List(saga.StepDescriptor)) -> List(String) {
  case descriptors {
    [] -> []
    [descriptor, ..rest] -> [
      saga.step_identity(descriptor),
      ..descriptor_step_ids(rest)
    ]
  }
}

fn scope_step_ids(
  node: NodeId,
  identities: List(String),
) -> List(ScopedStepId) {
  case identities {
    [] -> []
    [identity, ..rest] -> [
      ScopedStepId(node, identity),
      ..scope_step_ids(node, rest)
    ]
  }
}

fn flatten_all_step_identities(nodes: List(Node(e, u))) -> List(ScopedStepId) {
  case nodes {
    [] -> []
    [Node(_, _, _, identities, _), ..rest] ->
      append(identities, flatten_all_step_identities(rest))
  }
}

fn dependencies_from(
  input: Token,
  remaining: List(Node(e, u)),
  all_nodes: List(Node(e, u)),
) -> Result(List(Dependency), InspectionError) {
  case remaining {
    [] -> Ok([])
    [node, ..rest] ->
      case dependencies_for(node, input, all_nodes) {
        Error(error) -> Error(error)
        Ok(current) ->
          case dependencies_from(input, rest, all_nodes) {
            Error(error) -> Error(error)
            Ok(tail) -> Ok(append(current, tail))
          }
      }
  }
}

fn mark_reachable(
  target: Token,
  input: Token,
  nodes: List(Node(e, u)),
  reachable: List(Token),
) -> List(Token) {
  case token_in_list(target, reachable) {
    True -> reachable
    False -> {
      let with_target = [target, ..reachable]
      case target == input {
        True -> with_target
        False ->
          case inputs_for(target, nodes) {
            Missing -> with_target
            Present(inputs) ->
              mark_sources_reachable(inputs, input, nodes, with_target)
          }
      }
    }
  }
}

fn mark_sources_reachable(
  sources: List(Token),
  input: Token,
  nodes: List(Node(e, u)),
  reachable: List(Token),
) -> List(Token) {
  case sources {
    [] -> reachable
    [source, ..rest] -> {
      let next = mark_reachable(source, input, nodes, reachable)
      mark_sources_reachable(rest, input, nodes, next)
    }
  }
}

fn inputs_for(token: Token, nodes: List(Node(e, u))) -> Maybe(List(Token)) {
  case nodes {
    [] -> Missing
    [Node(found, _, inputs, _, _), ..rest] ->
      case token == found {
        True -> Present(inputs)
        False -> inputs_for(token, rest)
      }
  }
}

fn first_unreachable(
  nodes: List(Node(e, u)),
  reachable: List(Token),
) -> Maybe(NodeLabel) {
  case nodes {
    [] -> Missing
    [Node(token, label, _, _, _), ..rest] ->
      case token_in_list(token, reachable) {
        True -> first_unreachable(rest, reachable)
        False -> Present(label)
      }
  }
}

fn token_in_list(token: Token, tokens: List(Token)) -> Bool {
  case tokens {
    [] -> False
    [candidate, ..rest] ->
      case candidate == token {
        True -> True
        False -> token_in_list(token, rest)
      }
  }
}

fn dependencies_for(
  node: Node(e, u),
  input: Token,
  nodes: List(Node(e, u)),
) -> Result(List(Dependency), InspectionError) {
  let Node(_, label, sources, _, _) = node
  labels_for_sources(sources, input, nodes, label)
}

fn labels_for_sources(
  sources: List(Token),
  input: Token,
  nodes: List(Node(e, u)),
  target: NodeLabel,
) -> Result(List(Dependency), InspectionError) {
  case sources {
    [] -> Ok([])
    [source, ..rest] ->
      case label_for(source, input, nodes) {
        Missing -> Error(MissingDependencyPort)
        Present(label) ->
          case labels_for_sources(rest, input, nodes, target) {
            Error(error) -> Error(error)
            Ok(tail) -> Ok([Dependency(label, target), ..tail])
          }
      }
  }
}

fn label_for(
  token: Token,
  input: Token,
  nodes: List(Node(e, u)),
) -> Maybe(NodeLabel) {
  case token == input {
    True -> Present(InputPort)
    False -> label_in_nodes(token, nodes)
  }
}

fn label_in_nodes(token: Token, nodes: List(Node(e, u))) -> Maybe(NodeLabel) {
  case nodes {
    [] -> Missing
    [Node(found, label, _, _, _), ..rest] ->
      case found == token {
        True -> Present(label)
        False -> label_in_nodes(token, rest)
      }
  }
}

fn append(first: List(a), second: List(a)) -> List(a) {
  case first {
    [] -> second
    [head, ..tail] -> [head, ..append(tail, second)]
  }
}

fn length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + length(rest)
  }
}
