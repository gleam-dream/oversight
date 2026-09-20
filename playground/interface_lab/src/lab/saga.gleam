// THROWAWAY: Can a typed definition compose durable activities and approval?
import lab/blueprint.{type Codec, type DecodeError, type EncodeError}
import lab/value.{type Value}

pub type IdentityError {
  IdentityMustNotBeEmpty
  VersionMustBePositive
}

pub opaque type DefinitionId {
  DefinitionId(String)
}

pub fn definition_id(value: String) -> Result(DefinitionId, IdentityError) {
  case value {
    "" -> Error(IdentityMustNotBeEmpty)
    _ -> Ok(DefinitionId(value))
  }
}

pub opaque type StepId {
  StepId(String)
}

pub fn step_id(value: String) -> Result(StepId, IdentityError) {
  case value {
    "" -> Error(IdentityMustNotBeEmpty)
    _ -> Ok(StepId(value))
  }
}

pub opaque type Version {
  Version(Int)
}

pub fn version(value: Int) -> Result(Version, IdentityError) {
  case value {
    n if n > 0 -> Ok(Version(n))
    _ -> Error(VersionMustBePositive)
  }
}

pub type StepKind {
  ActivityStep
  ApprovalStep
  ChildStep
}

pub type StepDescriptor {
  StepDescriptor(
    id: StepId,
    version: Version,
    kind: StepKind,
    codec_versions: List(Version),
  )
}

pub type Dependency {
  Dependency(from: StepId, to: StepId)
}

pub type EdgeError {
  EdgeDecodeFailed(DecodeError)
  EdgeEncodeFailed(EncodeError)
}

// Executable adapters live with the deployed definition, never in snapshots.
type Edge {
  Edge(dependency: Dependency, adapt: fn(Value) -> Result(Value, EdgeError))
}

// A missing compensation is different from a no-op compensator.
pub type Compensation(i, o, u) {
  Uncompensated
  Compensate(fn(i, o) -> Result(Nil, u))
}

pub type NodeFailure {
  InputDidNotDecode(DecodeError)
  OutputDidNotEncode(EncodeError)
  BusinessFailure(Value)
  BusinessFailureDidNotEncode(EncodeError)
  NestedBusinessFailure(cause: Value, undo_failures: List(Value))
}

// Suspension and cancellation are control outcomes, never retryable failures.
pub type NodeWait {
  ApprovalPending
  ChildPending(child_run_id: String)
}

pub type NodeEvaluation {
  NodeFinished(Result(Value, NodeFailure))
  NodeWaiting(NodeWait)
  NodeCancelled(undo_failures: List(Value))
  NodeReconciliation(evidence: Value)
}

pub type ChildOutcome(o, e, u) {
  ChildSucceeded(o)
  ChildFailed(cause: e, undo_failures: List(u))
  ChildCancelled(undo_failures: List(u))
  ChildWaiting(child_run_id: String)
  ChildNeedsReconciliation(evidence: Value)
}

pub type NodeUndoFailure {
  UndoInputDidNotDecode(DecodeError)
  UndoOutputDidNotDecode(DecodeError)
  UndoBusinessFailure(Value)
  UndoFailureDidNotEncode(EncodeError)
}

type Maybe(a) {
  Missing
  Present(a)
}

type ErasedNode(e, u) {
  ErasedNode(
    descriptor: StepDescriptor,
    invoke: fn(Value) -> NodeEvaluation,
    compensate: Maybe(fn(Value, Value) -> Result(Nil, NodeUndoFailure)),
    validate_input: fn(Value) -> Result(Nil, DecodeError),
    validate_output: fn(Value) -> Result(Nil, DecodeError),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
  )
}

// A typed operation keeps executable code and codecs in the deployed factory.
// Its erased node captures a Value adapter; persisted state records stable ids
// and encoded outcomes, never these closures.
pub opaque type Activity(i, o, e, u) {
  Activity(
    node: ErasedNode(e, u),
    input_codec: Codec(i),
    output_codec: Codec(o),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
  )
}

pub fn activity(
  id: StepId,
  step_version: Version,
  input_codec_version: Version,
  output_codec_version: Version,
  error_codec_version: Version,
  undo_error_codec_version: Version,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  undo_error: Codec(u),
  execute: fn(i) -> Result(o, e),
  compensation: Compensation(i, o, u),
) -> Activity(i, o, e, u) {
  let descriptor =
    StepDescriptor(id, step_version, ActivityStep, [
      input_codec_version,
      output_codec_version,
      error_codec_version,
      undo_error_codec_version,
    ])
  let invoke = fn(raw_input) {
    case blueprint.decode(input, raw_input) {
      Error(decode_error) -> Error(InputDidNotDecode(decode_error))
      Ok(typed_input) ->
        case execute(typed_input) {
          Ok(typed_output) ->
            case blueprint.encode(output, typed_output) {
              Ok(encoded_output) -> Ok(encoded_output)
              Error(encode_error) -> Error(OutputDidNotEncode(encode_error))
            }
          Error(business_error) ->
            case blueprint.encode(error, business_error) {
              Ok(encoded_error) -> Error(BusinessFailure(encoded_error))
              Error(encode_error) ->
                Error(BusinessFailureDidNotEncode(encode_error))
            }
        }
    }
  }
  let undo = case compensation {
    Uncompensated -> Missing
    Compensate(compensate) ->
      Present(fn(raw_input, raw_output) {
        case blueprint.decode(input, raw_input) {
          Error(decode_error) -> Error(UndoInputDidNotDecode(decode_error))
          Ok(typed_input) ->
            case blueprint.decode(output, raw_output) {
              Error(decode_error) -> Error(UndoOutputDidNotDecode(decode_error))
              Ok(typed_output) ->
                case compensate(typed_input, typed_output) {
                  Ok(Nil) -> Ok(Nil)
                  Error(undo_failure) ->
                    case blueprint.encode(undo_error, undo_failure) {
                      Ok(encoded_error) ->
                        Error(UndoBusinessFailure(encoded_error))
                      Error(encode_error) ->
                        Error(UndoFailureDidNotEncode(encode_error))
                    }
                }
            }
        }
      })
  }
  Activity(
    ErasedNode(
      descriptor,
      fn(raw) { NodeFinished(invoke(raw)) },
      undo,
      validator(input),
      validator(output),
      error,
      undo_error,
    ),
    input,
    output,
    error,
    undo_error,
  )
}

pub type ApprovalDecision(a) {
  Approved(a)
  Denied
}

// The answer never replaces the trusted input that prompted approval.
pub type ApprovalResult(input, answer) {
  ApprovalResult(input: input, decision: ApprovalDecision(answer))
}

pub fn approval_result_codec(
  input: Codec(i),
  answer: Codec(a),
) -> Codec(ApprovalResult(i, a)) {
  blueprint.imap(
    blueprint.pair(input, approval_decision_codec(answer)),
    fn(pair) { ApprovalResult(pair.0, pair.1) },
    fn(result) { #(result.input, result.decision) },
  )
}

// Approval is a distinct node kind. Reaching it suspends until a typed signal
// is accepted by saga_checkpoint; the node does not turn waiting into failure.
pub opaque type Approval(i, a, e, u) {
  Approval(
    node: ErasedNode(e, u),
    input_codec: Codec(i),
    answer_codec: Codec(a),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
  )
}

pub fn approval(
  id: StepId,
  step_version: Version,
  input_codec_version: Version,
  answer_codec_version: Version,
  error_codec_version: Version,
  undo_error_codec_version: Version,
  input: Codec(i),
  answer: Codec(a),
  error: Codec(e),
  undo_error: Codec(u),
) -> Approval(i, a, e, u) {
  let descriptor =
    StepDescriptor(id, step_version, ApprovalStep, [
      input_codec_version,
      answer_codec_version,
      error_codec_version,
      undo_error_codec_version,
    ])
  Approval(
    ErasedNode(
      descriptor,
      fn(_input) { NodeWaiting(ApprovalPending) },
      Missing,
      validator(input),
      validator(approval_result_codec(input, answer)),
      error,
      undo_error,
    ),
    input,
    answer,
    error,
    undo_error,
  )
}

// A plain child result cannot be used where a compensation receipt is required.
// The receipt addresses the child's own run journal; no outer auto-undo occurs.
pub type ChildCompletion(o) {
  CompletedPlain(o)
  CompletedWithCompensation(o, CompensationReceipt)
}

pub opaque type CompensationReceipt {
  CompensationReceipt(child_run_id: String, child_revision: Int)
}

pub type ChildCompensationError {
  ChildCompensationUnavailable
  ChildCompensationFailed(Value)
}

pub fn request_child_compensation(
  _receipt: CompensationReceipt,
) -> Result(Nil, ChildCompensationError) {
  todo as "request compensation from the child runner; the child owns its journal"
}

pub opaque type Definition(i, o, e, u) {
  Definition(
    id: DefinitionId,
    version: Version,
    signature: String,
    input_codec: Codec(i),
    output_codec: Codec(o),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
    nodes: List(ErasedNode(e, u)),
    edges: List(Edge),
  )
}

pub fn define(
  id: DefinitionId,
  definition_version: Version,
  structural_signature: String,
  activity: Activity(i, o, e, u),
) -> Definition(i, o, e, u) {
  let Activity(node, input, output, error, undo_error) = activity
  Definition(
    id,
    definition_version,
    structural_signature,
    input,
    output,
    error,
    undo_error,
    [node],
    [],
  )
}

pub fn define_approval(
  id: DefinitionId,
  definition_version: Version,
  structural_signature: String,
  approval: Approval(i, a, e, u),
) -> Definition(i, ApprovalResult(i, a), e, u) {
  let Approval(node, input, answer, error, undo_error) = approval
  let encoded_node =
    ErasedNode(
      node.descriptor,
      fn(raw_input) {
        case blueprint.decode(input, raw_input) {
          Error(decode_error) ->
            NodeFinished(Error(InputDidNotDecode(decode_error)))
          Ok(_) -> NodeWaiting(ApprovalPending)
        }
      },
      Missing,
      validator(input),
      validator(approval_result_codec(input, answer)),
      error,
      undo_error,
    )
  Definition(
    id,
    definition_version,
    structural_signature,
    input,
    approval_result_codec(input, answer),
    error,
    undo_error,
    [encoded_node],
    [],
  )
}

// An opaque child owns its internal scheduling and compensation. This plain
// child result carries only output; compensation-enabled completion remains a
// separate ChildCompletion(CompensationReceipt) boundary.
pub fn child(
  id: StepId,
  step_version: Version,
  input_codec_version: Version,
  output_codec_version: Version,
  error_codec_version: Version,
  undo_error_codec_version: Version,
  child_definition: Definition(i, o, e, u),
) -> Activity(i, o, e, u) {
  let descriptor =
    StepDescriptor(id, step_version, ChildStep, [
      input_codec_version,
      output_codec_version,
      error_codec_version,
      undo_error_codec_version,
    ])
  let invoke = fn(raw_input) {
    case blueprint.decode(child_definition.input_codec, raw_input) {
      Error(error) -> NodeFinished(Error(InputDidNotDecode(error)))
      Ok(input) ->
        case execute_child(child_definition, input) {
          ChildSucceeded(output) ->
            case blueprint.encode(child_definition.output_codec, output) {
              Ok(encoded) -> NodeFinished(Ok(encoded))
              Error(error) -> NodeFinished(Error(OutputDidNotEncode(error)))
            }
          ChildFailed(cause, undo_failures) ->
            case
              blueprint.encode(child_definition.error_codec, cause),
              encode_many(child_definition.undo_error_codec, undo_failures)
            {
              Ok(encoded), Ok(undo) ->
                NodeFinished(Error(NestedBusinessFailure(encoded, undo)))
              Error(error), _ ->
                NodeFinished(Error(BusinessFailureDidNotEncode(error)))
              _, Error(error) ->
                NodeFinished(Error(BusinessFailureDidNotEncode(error)))
            }
          ChildCancelled(undo_failures) ->
            case encode_many(child_definition.undo_error_codec, undo_failures) {
              Ok(undo) -> NodeCancelled(undo)
              Error(error) ->
                NodeFinished(Error(BusinessFailureDidNotEncode(error)))
            }
          ChildWaiting(run_id) -> NodeWaiting(ChildPending(run_id))
          ChildNeedsReconciliation(evidence) -> NodeReconciliation(evidence)
        }
    }
  }
  Activity(
    ErasedNode(
      descriptor,
      invoke,
      Missing,
      validator(child_definition.input_codec),
      validator(child_definition.output_codec),
      child_definition.error_codec,
      child_definition.undo_error_codec,
    ),
    child_definition.input_codec,
    child_definition.output_codec,
    child_definition.error_codec,
    child_definition.undo_error_codec,
  )
}

fn execute_child(
  _definition: Definition(i, o, e, u),
  _input: i,
) -> ChildOutcome(o, e, u) {
  todo as "run the retained child definition through its own local or durable executor"
}

// The signatures prove the edge types. Construction also records the nodes and
// dependency, with each heterogeneous node retaining its own typed Value codec.
pub fn and_then(
  structural_signature: String,
  first: Definition(i, m, e, u),
  second: Definition(m, o, e, u),
) -> Definition(i, o, e, u) {
  let adapt = fn(raw) {
    case blueprint.decode(first.output_codec, raw) {
      Error(error) -> Error(EdgeDecodeFailed(error))
      Ok(typed) ->
        case blueprint.encode(second.input_codec, typed) {
          Error(error) -> Error(EdgeEncodeFailed(error))
          Ok(encoded) -> Ok(encoded)
        }
    }
  }
  let edge = dependency_between(first.nodes, second.nodes, adapt)
  Definition(
    first.id,
    first.version,
    structural_signature,
    first.input_codec,
    second.output_codec,
    first.error_codec,
    first.undo_error_codec,
    append(first.nodes, second.nodes),
    append(first.edges, append(edge, second.edges)),
  )
}

pub fn encode_input(
  definition: Definition(i, o, e, u),
  input: i,
) -> Result(Value, EncodeError) {
  blueprint.encode(definition.input_codec, input)
}

// Codec accessors let a graph adapter retain typed definitions without
// reaching into this module's representation.
pub fn input_codec(definition: Definition(i, o, e, u)) -> Codec(i) {
  definition.input_codec
}

pub fn output_codec(definition: Definition(i, o, e, u)) -> Codec(o) {
  definition.output_codec
}

// The graph prototype retains this typed call boundary. Execution remains a
// runtime responsibility; this adapter does not add a scheduler.
pub fn run_child(
  definition: Definition(i, o, e, u),
  input: i,
) -> ChildOutcome(o, e, u) {
  execute_child(definition, input)
}

pub fn definition_identity(definition: Definition(i, o, e, u)) -> String {
  let DefinitionId(identity) = definition.id
  identity
}

pub fn definition_version_number(definition: Definition(i, o, e, u)) -> Int {
  let Version(value) = definition.version
  value
}

// Caller-asserted metadata for this experiment; not a computed fingerprint.
pub fn definition_signature(definition: Definition(i, o, e, u)) -> String {
  definition.signature
}

pub fn steps(definition: Definition(i, o, e, u)) -> List(StepDescriptor) {
  map(definition.nodes, fn(node) { node.descriptor })
}

pub fn dependencies(definition: Definition(i, o, e, u)) -> List(Dependency) {
  map(definition.edges, fn(edge) { edge.dependency })
}

pub fn step_identity(descriptor: StepDescriptor) -> String {
  let StepId(identity) = descriptor.id
  identity
}

pub fn step_version_number(descriptor: StepDescriptor) -> Int {
  let Version(value) = descriptor.version
  value
}

pub fn codec_version_numbers(descriptor: StepDescriptor) -> List(Int) {
  map(descriptor.codec_versions, fn(version) {
    let Version(value) = version
    value
  })
}

pub opaque type LocalPlan(i, o, e, u) {
  LocalPlan(run: fn(i) -> Result(o, e), compensate: fn(i, o) -> Result(Nil, u))
}

pub fn local_plan(
  run: fn(i) -> Result(o, e),
  compensate: fn(i, o) -> Result(Nil, u),
) -> LocalPlan(i, o, e, u) {
  LocalPlan(run, compensate)
}

pub fn local_and_then(
  first: LocalPlan(i, m, e, u),
  second: LocalPlan(m, o, e, u),
) -> LocalPlan(i, o, e, u) {
  LocalPlan(
    fn(input) {
      case first.run(input) {
        Error(error) -> Error(error)
        Ok(middle) -> second.run(middle)
      }
    },
    fn(_input, _output) {
      todo as "the local executor must retain intermediate values before compensating a composed plan"
    },
  )
}

pub type LocalFailure(e, u) {
  LocalFailed(cause: e, undo_failures: List(u))
  LocalCancelled(undo_failures: List(u))
}

pub fn run_local(
  _plan: LocalPlan(i, o, e, u),
  _input: i,
) -> Result(o, LocalFailure(e, u)) {
  todo as "local execution must track successes and apply the declared compensation policy"
}

fn approval_decision_codec(answer: Codec(a)) -> Codec(ApprovalDecision(a)) {
  blueprint.new(
    fn(decision) {
      case decision {
        Approved(answer_value) ->
          case blueprint.encode(answer, answer_value) {
            Error(error) -> Error(error)
            Ok(encoded) -> Ok(value.Object([#("approved", encoded)]))
          }
        Denied -> Ok(value.Object([#("denied", value.Bool(True))]))
      }
    },
    fn(raw) {
      case raw {
        value.Object([#("approved", encoded)]) ->
          case blueprint.decode(answer, encoded) {
            Error(error) -> Error(error)
            Ok(decoded) -> Ok(Approved(decoded))
          }
        value.Object([#("denied", value.Bool(True))]) -> Ok(Denied)
        _ -> Error(blueprint.CannotDecode("Expected approval decision"))
      }
    },
  )
}

fn dependency_between(
  producers: List(ErasedNode(e, u)),
  consumers: List(ErasedNode(e, u)),
  adapt: fn(Value) -> Result(Value, EdgeError),
) -> List(Edge) {
  case last(producers), first(consumers) {
    Present(from), Present(to) -> [
      Edge(Dependency(from.descriptor.id, to.descriptor.id), adapt),
    ]
    _, _ -> []
  }
}

fn validator(codec: Codec(a)) -> fn(Value) -> Result(Nil, DecodeError) {
  fn(raw) {
    case blueprint.decode(codec, raw) {
      Ok(_) -> Ok(Nil)
      Error(error) -> Error(error)
    }
  }
}

fn first(items: List(a)) -> Maybe(a) {
  case items {
    [] -> Missing
    [head, ..] -> Present(head)
  }
}

fn last(items: List(a)) -> Maybe(a) {
  case items {
    [] -> Missing
    [only] -> Present(only)
    [_, ..rest] -> last(rest)
  }
}

fn append(first: List(a), second: List(a)) -> List(a) {
  case first {
    [] -> second
    [head, ..tail] -> [head, ..append(tail, second)]
  }
}

fn map(items: List(a), transform: fn(a) -> b) -> List(b) {
  case items {
    [] -> []
    [head, ..tail] -> [transform(head), ..map(tail, transform)]
  }
}

fn encode_many(
  codec: Codec(a),
  items: List(a),
) -> Result(List(Value), EncodeError) {
  case items {
    [] -> Ok([])
    [head, ..tail] ->
      case blueprint.encode(codec, head) {
        Error(error) -> Error(error)
        Ok(encoded) ->
          case encode_many(codec, tail) {
            Error(error) -> Error(error)
            Ok(rest) -> Ok([encoded, ..rest])
          }
      }
  }
}
