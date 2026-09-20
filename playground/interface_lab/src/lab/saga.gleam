// THROWAWAY: Can a typed definition compose durable activities and approval?
import lab/blueprint.{type Codec, type DecodeError, type EncodeError}
import lab/value.{type Value}

pub type IdentityError {
  IdentityMustNotBeEmpty
  VersionMustBePositive
}

pub type BuildError {
  ForeignPort
  DuplicateNodeId(NodeId)
  DuplicateStepId(String)
  UnreachableNode(NodeLabel)
}

pub type NodeIdentityError {
  NodeIdentityMustNotBeEmpty
}

pub opaque type NodeId {
  NodeId(String)
}

pub fn node_id(value: String) -> Result(NodeId, NodeIdentityError) {
  case value {
    "" -> Error(NodeIdentityMustNotBeEmpty)
    _ -> Ok(NodeId(value))
  }
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
  ChoiceStep
  PairAdapterStep
  SequenceAdapterStep
}

pub type StepDescriptor {
  StepDescriptor(
    id: StepId,
    version: Version,
    kind: StepKind,
    codec_versions: List(Version),
  )
}

// Runtime tokens prove that a port came from this in-memory builder. They are
// freshly rekeyed during composition and never enter durable snapshots.
type Token {
  Token(Int)
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn fresh_token() -> Token {
  Token(unique_integer())
}

pub type NodeAddress {
  NamedAddress(NodeId)
  PairAddress(Int)
  SequenceBoundaryAddress
  SequenceLeft(NodeAddress)
  SequenceRight(NodeAddress)
  BranchAddress(owner: NodeAddress, side: BranchSide, nested: NodeAddress)
  ChildAddress(owner: NodeAddress, nested: NodeAddress)
}

pub type NodeLabel {
  InputPort
  ChildNode(NodeAddress)
  PairNode(NodeAddress)
  ChoiceNode(NodeAddress)
  ActivityNode(NodeAddress)
  ApprovalNode(NodeAddress)
  SequenceBoundaryNode(NodeAddress)
}

pub type NodeReference {
  WorkflowInput
  NodeAt(NodeAddress)
}

pub type Dependency {
  Dependency(from: NodeReference, to: NodeReference)
}

// A missing compensation is different from a no-op compensator.
pub type Compensation(i, o, u) {
  Uncompensated
  Compensate(fn(i, o) -> Result(Nil, u))
}

pub type ChildOutcome(o, e, u) {
  ChildSucceeded(o)
  ChildFailed(cause: e, undo_failures: List(u))
  ChildCancelled(undo_failures: List(u))
  ChildWaiting(child_run_id: String)
  ChildNeedsReconciliation(evidence: Value)
}

type Maybe(a) {
  Missing
  Present(a)
}

pub type BranchSide {
  LeftBranch
  RightBranch
}

pub type ScopedStepId {
  ScopedStepId(node: NodeAddress, step_id: String)
  BranchStepId(node: NodeAddress, branch: BranchSide, step_id: String)
}

pub type LocatedStep {
  LocatedStep(identity: ScopedStepId, descriptor: StepDescriptor)
}

pub type NodeBoundaryError {
  UnexpectedInputCount(Int)
  InputValueDidNotDecode(DecodeError)
  InputValueDidNotEncode(EncodeError)
  OutputValueDidNotEncode(EncodeError)
}

pub type NodeOutcome(e, u) {
  NodeSucceeded(Value)
  NodeFailed(cause: e, undo_failures: List(u))
  NodeWaiting(child_run_id: String)
  NodeAwaitingApproval
  NodeCancelled(undo_failures: List(u))
  NodeNeedsReconciliation(evidence: Value)
  NodeBoundaryFailed(NodeBoundaryError)
}

pub type CompensationError(u) {
  CompensationNotDeclared
  CompensationInputRejected(DecodeError)
  CompensationOutputRejected(DecodeError)
  CompensationFailed(u)
}

pub type InspectionError {
  MissingDependencyPort
  NotDirectActivity(NodeId)
  AmbiguousNodeId(NodeId)
}

pub type SelectionError {
  UnknownChoice(NodeId)
  AmbiguousChoice(NodeId)
  ChoiceInputRejected(NodeBoundaryError)
}

pub type SequenceProbeError {
  SequenceAdapterNotFound
  SequenceAdapterNotUnique
  SequenceAdapterRejected(NodeBoundaryError)
  SequenceAdapterUnexpectedOutcome
}

pub type Choice(l, r) {
  Left(l)
  Right(r)
}

pub type SelectedBranch {
  SelectedBranch(side: BranchSide, input: Value)
}

type Node(e, u) {
  Node(
    token: Token,
    address: NodeAddress,
    label: NodeLabel,
    inputs: List(Token),
    located_steps: List(LocatedStep),
    evaluate: fn(List(Value)) -> NodeOutcome(e, u),
    selection: Maybe(fn(Value) -> Result(SelectedBranch, NodeBoundaryError)),
    compensate: Maybe(fn(Value, Value) -> Result(Nil, CompensationError(u))),
    validate_inputs: List(fn(Value) -> Result(Nil, DecodeError)),
    validate_output: fn(Value) -> Result(Nil, DecodeError),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
  )
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
    next_pair_label: Int,
  )
}

// A typed operation keeps executable code and codecs in the deployed factory.
// It is lowered once into the canonical Saga Node when attached to a Builder.
pub opaque type Activity(i, o, e, u) {
  Activity(adapter: ActivityAdapter(i, o, e, u))
}

// Versions belong to durable boundaries, not to general Blueprint codecs.
pub type VersionedCodec(a) {
  VersionedCodec(version: Version, codec: Codec(a))
}

pub type ActivityContract(i, o, e, u) {
  ActivityContract(
    input: VersionedCodec(i),
    output: VersionedCodec(o),
    error: VersionedCodec(e),
    undo_error: VersionedCodec(u),
  )
}

pub fn activity(
  id: StepId,
  step_version: Version,
  contract: ActivityContract(i, o, e, u),
  execute: fn(i) -> Result(o, e),
  compensation: Compensation(i, o, u),
) -> Activity(i, o, e, u) {
  let input_codec_version = contract.input.version
  let output_codec_version = contract.output.version
  let error_codec_version = contract.error.version
  let undo_error_codec_version = contract.undo_error.version
  let descriptor =
    StepDescriptor(id, step_version, ActivityStep, [
      input_codec_version,
      output_codec_version,
      error_codec_version,
      undo_error_codec_version,
    ])
  Activity(ActivityAdapter(descriptor, contract, execute, compensation))
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
    descriptor: StepDescriptor,
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
  Approval(descriptor, input, answer, error, undo_error)
}

pub opaque type Definition(i, o, e, u) {
  Definition(
    id: DefinitionId,
    version: Version,
    signature: String,
    input_token: Token,
    input_codec: Codec(i),
    output: Port(o),
    error_codec: Codec(e),
    undo_error_codec: Codec(u),
    nodes: List(Node(e, u)),
  )
}

// Boundary versions describe values persisted by an independent child owner.
// They do not claim to fingerprint or prove codec compatibility.
pub type BoundaryVersions {
  BoundaryVersions(
    input: Version,
    output: Version,
    error: Version,
    undo_error: Version,
  )
}

// The contract retains the deployed definition and the codecs that anchor its
// native output, failure, and compensation-failure types.
pub opaque type ChildContract(i, o, e, u) {
  ChildContract(
    definition: Definition(i, o, e, u),
    boundary_versions: BoundaryVersions,
  )
}

pub fn child_contract(
  definition: Definition(i, o, e, u),
  boundary_versions: BoundaryVersions,
) -> ChildContract(i, o, e, u) {
  ChildContract(definition, boundary_versions)
}

pub fn child_contract_definition(
  contract: ChildContract(i, o, e, u),
) -> Definition(i, o, e, u) {
  contract.definition
}

pub fn child_contract_identity(contract: ChildContract(i, o, e, u)) -> String {
  definition_identity(contract.definition)
}

pub fn child_contract_version(contract: ChildContract(i, o, e, u)) -> Int {
  definition_version_number(contract.definition)
}

pub fn child_contract_signature(contract: ChildContract(i, o, e, u)) -> String {
  definition_signature(contract.definition)
}

pub fn child_contract_input_codec(
  contract: ChildContract(i, o, e, u),
) -> Codec(i) {
  contract.definition.input_codec
}

pub fn child_contract_output_codec(
  contract: ChildContract(i, o, e, u),
) -> Codec(o) {
  contract.definition.output.codec
}

pub fn child_contract_error_codec(
  contract: ChildContract(i, o, e, u),
) -> Codec(e) {
  contract.definition.error_codec
}

pub fn child_contract_undo_error_codec(
  contract: ChildContract(i, o, e, u),
) -> Codec(u) {
  contract.definition.undo_error_codec
}

pub fn child_contract_boundary_versions(
  contract: ChildContract(i, o, e, u),
) -> #(Int, Int, Int, Int) {
  let BoundaryVersions(input, output, error, undo_error) =
    contract.boundary_versions
  #(
    version_number(input),
    version_number(output),
    version_number(error),
    version_number(undo_error),
  )
}

fn version_number(version: Version) -> Int {
  let Version(number) = version
  number
}

pub fn define(
  id: DefinitionId,
  definition_version: Version,
  structural_signature: String,
  activity: Activity(i, o, e, u),
) -> Definition(i, o, e, u) {
  let ActivityAdapter(descriptor, contract, _, _) = activity.adapter
  let StepId(activity_id) = descriptor.id
  let assert Ok(activity_node_id) = node_id(activity_id)
  let #(builder, input) =
    begin(contract.input.codec, contract.error.codec, contract.undo_error.codec)
  let assert Ok(#(builder, output)) =
    add_activity(builder, input, activity_node_id, activity)
  let assert Ok(definition) =
    finish(builder, output, id, definition_version, structural_signature)
  definition
}

pub fn define_approval(
  id: DefinitionId,
  definition_version: Version,
  structural_signature: String,
  approval: Approval(i, a, e, u),
) -> Definition(i, ApprovalResult(i, a), e, u) {
  let Approval(descriptor, approval_input, _answer, error, undo_error) =
    approval
  let StepId(approval_id) = descriptor.id
  let assert Ok(approval_node_id) = node_id(approval_id)
  let #(builder, input) = begin(approval_input, error, undo_error)
  let assert Ok(#(builder, output)) =
    add_approval(builder, input, approval_node_id, approval)
  let assert Ok(definition) =
    finish(builder, output, id, definition_version, structural_signature)
  definition
}

// An opaque child owns its internal scheduling and compensation. This plain
// child boundary carries only output; durable compensation authority is issued
// separately by its owner through the Grind adapter.
pub fn child(
  id: StepId,
  step_version: Version,
  input_codec_version: Version,
  output_codec_version: Version,
  error_codec_version: Version,
  undo_error_codec_version: Version,
  child_definition: Definition(i, o, e, u),
) -> Child(i, o, e, u) {
  let descriptor =
    StepDescriptor(id, step_version, ChildStep, [
      input_codec_version,
      output_codec_version,
      error_codec_version,
      undo_error_codec_version,
    ])
  Child(child_definition, descriptor)
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
  compose(first, second, structural_signature)
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
  definition.output.codec
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
  map(located_steps(definition), fn(step) { step.descriptor })
}

pub fn located_steps(definition: Definition(i, o, e, u)) -> List(LocatedStep) {
  flatten_located_steps(definition.nodes)
}

pub fn dependencies(
  definition: Definition(i, o, e, u),
) -> Result(List(Dependency), InspectionError) {
  dependencies_from(definition.input_token, definition.nodes, definition.nodes)
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

// The same opaque definition contains authored edges and retained operations.
// Construction tokens are local-only; `finish` returns this canonical type to
// both the checkpoint and queue boundaries.
pub fn begin(
  input: Codec(i),
  error: Codec(e),
  undo_error: Codec(u),
) -> #(Builder(i, e, u), Port(i)) {
  let token = fresh_token()
  #(
    Builder(token, input, error, undo_error, [], [], 0),
    Port(token, input, InputPort),
  )
}

pub fn finish(
  builder: Builder(i, e, u),
  output: Port(o),
  id: DefinitionId,
  definition_version: Version,
  structural_signature: String,
) -> Result(Definition(i, o, e, u), BuildError) {
  case contains_token(builder.input_token, builder.nodes, output.token) {
    False -> Error(ForeignPort)
    True -> {
      let reachable =
        mark_reachable(output.token, builder.input_token, builder.nodes, [])
      case first_unreachable(builder.nodes, reachable) {
        Present(label) -> Error(UnreachableNode(label))
        Missing ->
          Ok(Definition(
            id,
            definition_version,
            structural_signature,
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

pub fn add_activity(
  builder: Builder(i, e, u),
  input: Port(a),
  id: NodeId,
  activity: Activity(a, b, e, u),
) -> Result(#(Builder(i, e, u), Port(b)), BuildError) {
  let ActivityAdapter(descriptor, contract, execute, compensation) =
    activity.adapter
  let address = NamedAddress(id)
  let located =
    LocatedStep(ScopedStepId(address, step_identity(descriptor)), descriptor)
  let evaluate =
    activity_evaluator(
      input.codec,
      contract.input.codec,
      contract.output.codec,
      execute,
    )
  let undo =
    activity_compensator(input.codec, contract.output.codec, compensation)
  register_named_node(
    builder,
    input,
    id,
    address,
    ActivityNode(address),
    [located],
    evaluate,
    Missing,
    undo,
    [validator(input.codec)],
    validator(contract.output.codec),
    contract.output.codec,
    contract.error.codec,
    contract.undo_error.codec,
  )
}

pub fn add_approval(
  builder: Builder(i, e, u),
  input: Port(a),
  id: NodeId,
  approval: Approval(a, b, e, u),
) -> Result(#(Builder(i, e, u), Port(ApprovalResult(a, b))), BuildError) {
  let Approval(descriptor, approval_input, answer, error, undo_error) = approval
  let address = NamedAddress(id)
  let located =
    LocatedStep(ScopedStepId(address, step_identity(descriptor)), descriptor)
  let output = approval_result_codec(approval_input, answer)
  let evaluate = approval_evaluator(input.codec, approval_input)
  register_named_node(
    builder,
    input,
    id,
    address,
    ApprovalNode(address),
    [located],
    evaluate,
    Missing,
    Missing,
    [validator(input.codec)],
    validator(output),
    output,
    error,
    undo_error,
  )
}

pub fn add_child(
  builder: Builder(i, e, u),
  input: Port(a),
  id: NodeId,
  definition: Definition(a, b, e, u),
) -> Result(#(Builder(i, e, u), Port(b)), BuildError) {
  let address = NamedAddress(id)
  let descriptor =
    StepDescriptor(StepId(node_id_text(id)), definition.version, ChildStep, [
      definition.version,
    ])
  let located =
    append(
      [
        LocatedStep(
          ScopedStepId(address, step_identity(descriptor)),
          descriptor,
        ),
      ],
      child_step_metadata(address, located_steps(definition)),
    )
  register_named_node(
    builder,
    input,
    id,
    address,
    ChildNode(address),
    located,
    definition_evaluator(
      input.codec,
      definition.input_codec,
      definition.output.codec,
      definition,
    ),
    Missing,
    Missing,
    [validator(input.codec)],
    validator(definition.output.codec),
    definition.output.codec,
    definition.error_codec,
    definition.undo_error_codec,
  )
}

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
      let address = PairAddress(builder.next_pair_label)
      let token = fresh_token()
      let output = blueprint.pair(left.codec, right.codec)
      let descriptor = synthetic_descriptor("pair", PairAdapterStep)
      let node =
        Node(
          token,
          address,
          PairNode(address),
          [left.token, right.token],
          [LocatedStep(ScopedStepId(address, "pair"), descriptor)],
          pair_evaluator(left.codec, right.codec, output),
          Missing,
          Missing,
          [validator(left.codec), validator(right.codec)],
          validator(output),
          builder.error_codec,
          builder.undo_error_codec,
        )
      let next =
        Builder(
          ..builder,
          nodes: append(builder.nodes, [node]),
          next_pair_label: builder.next_pair_label + 1,
        )
      Ok(#(next, Port(token, output, PairNode(address))))
    }
    _, _ -> Error(ForeignPort)
  }
}

// The tagged codec is closed: malformed or unknown tags fail at the boundary.
pub fn choice_codec(left: Codec(l), right: Codec(r)) -> Codec(Choice(l, r)) {
  blueprint.new(
    fn(choice) {
      case choice {
        Left(item) -> encode_choice("left", left, item)
        Right(item) -> encode_choice("right", right, item)
      }
    },
    fn(raw) {
      case raw {
        value.Array([value.Text("left"), payload]) ->
          case blueprint.decode(left, payload) {
            Ok(item) -> Ok(Left(item))
            Error(error) -> Error(blueprint.DecodeAtIndex(1, error))
          }
        value.Array([value.Text("right"), payload]) ->
          case blueprint.decode(right, payload) {
            Ok(item) -> Ok(Right(item))
            Error(error) -> Error(blueprint.DecodeAtIndex(1, error))
          }
        _ ->
          Error(blueprint.CannotDecode("Expected tagged left or right choice"))
      }
    },
  )
}

pub fn choose_children(
  builder: Builder(i, e, u),
  input: Port(Choice(l, r)),
  id: NodeId,
  left: Definition(l, o, e, u),
  right: Definition(r, o, e, u),
  output: Codec(o),
) -> Result(#(Builder(i, e, u), Port(o)), BuildError) {
  case contains_token(builder.input_token, builder.nodes, input.token) {
    False -> Error(ForeignPort)
    True -> {
      let address = NamedAddress(id)
      let route =
        choice_router(input.codec, left.input_codec, right.input_codec)
      let descriptor = synthetic_descriptor(node_id_text(id), ChoiceStep)
      let steps = [
        LocatedStep(ScopedStepId(address, node_id_text(id)), descriptor),
        ..append(
          branch_step_metadata(address, LeftBranch, located_steps(left)),
          branch_step_metadata(address, RightBranch, located_steps(right)),
        )
      ]
      let evaluate = fn(inputs) {
        case inputs {
          [raw] ->
            case route(raw) {
              Error(error) -> NodeBoundaryFailed(error)
              Ok(SelectedBranch(LeftBranch, payload)) ->
                evaluate_branch(payload, left, output)
              Ok(SelectedBranch(RightBranch, payload)) ->
                evaluate_branch(payload, right, output)
            }
          other -> NodeBoundaryFailed(UnexpectedInputCount(length(other)))
        }
      }
      register_named_node(
        builder,
        input,
        id,
        address,
        ChoiceNode(address),
        steps,
        evaluate,
        Present(route),
        Missing,
        [validator(input.codec)],
        validator(output),
        output,
        builder.error_codec,
        builder.undo_error_codec,
      )
    }
  }
}

pub fn inspect_choice(
  definition: Definition(i, o, e, u),
  id: NodeId,
  raw: Value,
) -> Result(SelectedBranch, SelectionError) {
  inspect_choice_nodes(definition.nodes, id, raw)
}

pub fn probe_direct(
  definition: Definition(i, o, e, u),
  id: NodeId,
  raw: Value,
) -> Result(NodeOutcome(e, u), InspectionError) {
  case direct_node(definition.nodes, id) {
    Error(error) -> Error(error)
    Ok(node) -> Ok(node.evaluate([raw]))
  }
}

pub fn probe_compensation(
  definition: Definition(i, o, e, u),
  id: NodeId,
  raw_input: Value,
  raw_output: Value,
) -> Result(Nil, CompensationError(u)) {
  case direct_node(definition.nodes, id) {
    Error(_) -> Error(CompensationNotDeclared)
    Ok(node) ->
      case node.compensate {
        Missing -> Error(CompensationNotDeclared)
        Present(undo) -> undo(raw_input, raw_output)
      }
  }
}

// This pure probe calls only the retained wire adapter node. It does not run
// either activity around the adapter or claim to execute a workflow.
pub fn probe_sequence_boundary(
  definition: Definition(i, o, e, u),
  raw: Value,
) -> Result(Value, SequenceProbeError) {
  case sequence_adapters(definition.nodes) {
    [] -> Error(SequenceAdapterNotFound)
    [adapter] ->
      case adapter.evaluate([raw]) {
        NodeSucceeded(output) -> Ok(output)
        NodeBoundaryFailed(error) -> Error(SequenceAdapterRejected(error))
        _ -> Error(SequenceAdapterUnexpectedOutcome)
      }
    _ -> Error(SequenceAdapterNotUnique)
  }
}

pub fn node_count(definition: Definition(i, o, e, u)) -> Int {
  length(definition.nodes)
}

pub fn output_label(definition: Definition(i, o, e, u)) -> NodeLabel {
  definition.output.label
}

pub fn step_identities(
  definition: Definition(i, o, e, u),
) -> List(ScopedStepId) {
  map(located_steps(definition), fn(step) { step.identity })
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

// Child is not a direct activity and carries no automatic parent compensator.
pub opaque type Child(i, o, e, u) {
  Child(definition: Definition(i, o, e, u), descriptor: StepDescriptor)
}

pub fn define_child(
  id: DefinitionId,
  definition_version: Version,
  structural_signature: String,
  child: Child(i, o, e, u),
) -> Definition(i, o, e, u) {
  let Child(child_definition, descriptor) = child
  let StepId(child_id) = descriptor.id
  let assert Ok(child_node_id) = node_id(child_id)
  let #(builder, input) =
    begin(
      child_definition.input_codec,
      child_definition.error_codec,
      child_definition.undo_error_codec,
    )
  let address = NamedAddress(child_node_id)
  let located =
    LocatedStep(ScopedStepId(address, step_identity(descriptor)), descriptor)
  let evaluate = child_evaluator(child_definition)
  let assert Ok(#(builder, output)) =
    register_named_node(
      builder,
      input,
      child_node_id,
      address,
      ChildNode(address),
      [located],
      evaluate,
      Missing,
      Missing,
      [validator(child_definition.input_codec)],
      validator(child_definition.output.codec),
      child_definition.output.codec,
      child_definition.error_codec,
      child_definition.undo_error_codec,
    )
  let assert Ok(definition) =
    finish(builder, output, id, definition_version, structural_signature)
  definition
}

// These records expose retained typed callbacks for the graph adapter. They
// are laboratory factoring surfaces, not certificates of executed effects.
pub type ActivityAdapter(i, o, e, u) {
  ActivityAdapter(
    descriptor: StepDescriptor,
    contract: ActivityContract(i, o, e, u),
    execute: fn(i) -> Result(o, e),
    compensation: Compensation(i, o, u),
  )
}

pub fn activity_adapter(
  activity: Activity(i, o, e, u),
) -> ActivityAdapter(i, o, e, u) {
  activity.adapter
}

pub type ApprovalAdapter(i, a) {
  ApprovalAdapter(descriptor: StepDescriptor, input: Codec(i), answer: Codec(a))
}

pub fn approval_adapter(
  approval: Approval(i, a, e, u),
) -> ApprovalAdapter(i, a) {
  ApprovalAdapter(
    approval.descriptor,
    approval.input_codec,
    approval.answer_codec,
  )
}

fn register_named_node(
  builder: Builder(i, e, u),
  input: Port(a),
  id: NodeId,
  address: NodeAddress,
  label: NodeLabel,
  located: List(LocatedStep),
  evaluate: fn(List(Value)) -> NodeOutcome(e, u),
  selection: Maybe(fn(Value) -> Result(SelectedBranch, NodeBoundaryError)),
  compensate: Maybe(fn(Value, Value) -> Result(Nil, CompensationError(u))),
  validate_inputs: List(fn(Value) -> Result(Nil, DecodeError)),
  validate_output: fn(Value) -> Result(Nil, DecodeError),
  output: Codec(b),
  error_codec: Codec(e),
  undo_error_codec: Codec(u),
) -> Result(#(Builder(i, e, u), Port(b)), BuildError) {
  case contains_token(builder.input_token, builder.nodes, input.token) {
    False -> Error(ForeignPort)
    True ->
      case contains_node_id(id, builder.node_ids) {
        True -> Error(DuplicateNodeId(id))
        False -> {
          let token = fresh_token()
          let node =
            Node(
              token,
              address,
              label,
              [input.token],
              located,
              evaluate,
              selection,
              compensate,
              validate_inputs,
              validate_output,
              error_codec,
              undo_error_codec,
            )
          let next =
            Builder(
              ..builder,
              nodes: append(builder.nodes, [node]),
              node_ids: append(builder.node_ids, [id]),
            )
          Ok(#(next, Port(token, output, label)))
        }
      }
  }
}

fn activity_evaluator(
  source: Codec(a),
  target: Codec(a),
  output_codec: Codec(b),
  execute: fn(a) -> Result(b, e),
) -> fn(List(Value)) -> NodeOutcome(e, u) {
  fn(inputs) {
    case inputs {
      [raw] ->
        case direct_input(source, target, raw) {
          Error(error) -> NodeBoundaryFailed(error)
          Ok(typed) ->
            case execute(typed) {
              Error(error) -> NodeFailed(error, [])
              Ok(typed_output) ->
                case blueprint.encode(output_codec, typed_output) {
                  Ok(raw_output) -> NodeSucceeded(raw_output)
                  Error(error) ->
                    NodeBoundaryFailed(OutputValueDidNotEncode(error))
                }
            }
        }
      other -> NodeBoundaryFailed(UnexpectedInputCount(length(other)))
    }
  }
}

fn activity_compensator(
  source: Codec(a),
  output: Codec(b),
  compensation: Compensation(a, b, u),
) -> Maybe(fn(Value, Value) -> Result(Nil, CompensationError(u))) {
  case compensation {
    Uncompensated -> Missing
    Compensate(undo) ->
      Present(fn(raw_input, raw_output) {
        case blueprint.decode(source, raw_input) {
          Error(error) -> Error(CompensationInputRejected(error))
          Ok(input) ->
            case blueprint.decode(output, raw_output) {
              Error(error) -> Error(CompensationOutputRejected(error))
              Ok(output) ->
                case undo(input, output) {
                  Ok(Nil) -> Ok(Nil)
                  Error(error) -> Error(CompensationFailed(error))
                }
            }
        }
      })
  }
}

fn approval_evaluator(
  source: Codec(a),
  target: Codec(a),
) -> fn(List(Value)) -> NodeOutcome(e, u) {
  fn(inputs) {
    case inputs {
      [raw] ->
        case direct_input(source, target, raw) {
          Ok(_) -> NodeAwaitingApproval
          Error(error) -> NodeBoundaryFailed(error)
        }
      other -> NodeBoundaryFailed(UnexpectedInputCount(length(other)))
    }
  }
}

fn direct_input(
  source: Codec(a),
  target: Codec(a),
  raw: Value,
) -> Result(a, NodeBoundaryError) {
  case blueprint.decode(source, raw) {
    Error(error) -> Error(InputValueDidNotDecode(error))
    Ok(typed) ->
      case blueprint.encode(target, typed) {
        Error(error) -> Error(InputValueDidNotEncode(error))
        Ok(encoded) ->
          case blueprint.decode(target, encoded) {
            Ok(decoded) -> Ok(decoded)
            Error(error) -> Error(InputValueDidNotDecode(error))
          }
      }
  }
}

fn definition_evaluator(
  source: Codec(a),
  target: Codec(a),
  output: Codec(b),
  definition: Definition(a, b, e, u),
) -> fn(List(Value)) -> NodeOutcome(e, u) {
  fn(inputs) {
    case inputs {
      [raw] ->
        case direct_input(source, target, raw) {
          Error(error) -> NodeBoundaryFailed(error)
          Ok(typed) ->
            case run_child(definition, typed) {
              ChildSucceeded(result) ->
                case blueprint.encode(output, result) {
                  Ok(encoded) -> NodeSucceeded(encoded)
                  Error(error) ->
                    NodeBoundaryFailed(OutputValueDidNotEncode(error))
                }
              ChildFailed(cause, undo_failures) ->
                NodeFailed(cause, undo_failures)
              ChildCancelled(undo_failures) -> NodeCancelled(undo_failures)
              ChildWaiting(run_id) -> NodeWaiting(run_id)
              ChildNeedsReconciliation(evidence) ->
                NodeNeedsReconciliation(evidence)
            }
        }
      other -> NodeBoundaryFailed(UnexpectedInputCount(length(other)))
    }
  }
}

fn pair_evaluator(
  left: Codec(a),
  right: Codec(b),
  output: Codec(#(a, b)),
) -> fn(List(Value)) -> NodeOutcome(e, u) {
  fn(inputs) {
    case inputs {
      [raw_left, raw_right] ->
        case blueprint.decode(left, raw_left) {
          Error(error) -> NodeBoundaryFailed(InputValueDidNotDecode(error))
          Ok(left_value) ->
            case blueprint.decode(right, raw_right) {
              Error(error) -> NodeBoundaryFailed(InputValueDidNotDecode(error))
              Ok(right_value) ->
                case blueprint.encode(output, #(left_value, right_value)) {
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

fn synthetic_descriptor(id: String, kind: StepKind) -> StepDescriptor {
  StepDescriptor(StepId(id), Version(1), kind, [Version(1)])
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
    [Node(found, _, _, _, _, _, _, _, _, _, _, _), ..rest] ->
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

fn validator(codec: Codec(a)) -> fn(Value) -> Result(Nil, DecodeError) {
  fn(raw) {
    case blueprint.decode(codec, raw) {
      Ok(_) -> Ok(Nil)
      Error(error) -> Error(error)
    }
  }
}

fn flatten_located_steps(nodes: List(Node(e, u))) -> List(LocatedStep) {
  case nodes {
    [] -> []
    [Node(_, _, _, _, located, _, _, _, _, _, _, _), ..rest] ->
      append(located, flatten_located_steps(rest))
  }
}

fn child_step_metadata(
  owner: NodeAddress,
  steps: List(LocatedStep),
) -> List(LocatedStep) {
  case steps {
    [] -> []
    [LocatedStep(identity, descriptor), ..rest] -> {
      let nested = step_owner(identity)
      let scoped = case identity {
        ScopedStepId(_, step_id) ->
          ScopedStepId(ChildAddress(owner, nested), step_id)
        BranchStepId(_, branch, step_id) ->
          BranchStepId(ChildAddress(owner, nested), branch, step_id)
      }
      [LocatedStep(scoped, descriptor), ..child_step_metadata(owner, rest)]
    }
  }
}

fn branch_step_metadata(
  owner: NodeAddress,
  branch: BranchSide,
  steps: List(LocatedStep),
) -> List(LocatedStep) {
  case steps {
    [] -> []
    [LocatedStep(identity, descriptor), ..rest] -> {
      let scoped =
        BranchStepId(
          BranchAddress(owner, branch, step_owner(identity)),
          branch,
          step_name(identity),
        )
      [
        LocatedStep(scoped, descriptor),
        ..branch_step_metadata(owner, branch, rest)
      ]
    }
  }
}

fn step_owner(identity: ScopedStepId) -> NodeAddress {
  case identity {
    ScopedStepId(node, _) -> node
    BranchStepId(node, _, _) -> node
  }
}

fn step_name(identity: ScopedStepId) -> String {
  case identity {
    ScopedStepId(_, step_id) -> step_id
    BranchStepId(_, _, step_id) -> step_id
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

fn dependencies_for(
  node: Node(e, u),
  input: Token,
  nodes: List(Node(e, u)),
) -> Result(List(Dependency), InspectionError) {
  let Node(_, address, _, sources, _, _, _, _, _, _, _, _) = node
  dependencies_for_sources(sources, input, nodes, NodeAt(address))
}

fn dependencies_for_sources(
  sources: List(Token),
  input: Token,
  nodes: List(Node(e, u)),
  target: NodeReference,
) -> Result(List(Dependency), InspectionError) {
  case sources {
    [] -> Ok([])
    [source, ..rest] ->
      case reference_for(source, input, nodes) {
        Error(error) -> Error(error)
        Ok(reference) ->
          case dependencies_for_sources(rest, input, nodes, target) {
            Error(error) -> Error(error)
            Ok(tail) -> Ok([Dependency(reference, target), ..tail])
          }
      }
  }
}

fn reference_for(
  token: Token,
  input: Token,
  nodes: List(Node(e, u)),
) -> Result(NodeReference, InspectionError) {
  case token == input {
    True -> Ok(WorkflowInput)
    False ->
      case address_for(token, nodes) {
        Missing -> Error(MissingDependencyPort)
        Present(address) -> Ok(NodeAt(address))
      }
  }
}

fn address_for(token: Token, nodes: List(Node(e, u))) -> Maybe(NodeAddress) {
  case nodes {
    [] -> Missing
    [Node(found, address, _, _, _, _, _, _, _, _, _, _), ..rest] ->
      case token == found {
        True -> Present(address)
        False -> address_for(token, rest)
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
    [Node(found, _, _, inputs, _, _, _, _, _, _, _, _), ..rest] ->
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
    [Node(token, _, label, _, _, _, _, _, _, _, _, _), ..rest] ->
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

fn length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + length(rest)
  }
}

fn encode_choice(
  tag: String,
  codec: Codec(a),
  item: a,
) -> Result(Value, EncodeError) {
  case blueprint.encode(codec, item) {
    Ok(raw) -> Ok(value.Array([value.Text(tag), raw]))
    Error(error) -> Error(blueprint.EncodeAtIndex(1, error))
  }
}

fn choice_router(
  source: Codec(Choice(l, r)),
  left: Codec(l),
  right: Codec(r),
) -> fn(Value) -> Result(SelectedBranch, NodeBoundaryError) {
  fn(raw) {
    case blueprint.decode(source, raw) {
      Error(error) -> Error(InputValueDidNotDecode(error))
      Ok(Left(item)) -> encode_selected(LeftBranch, left, item)
      Ok(Right(item)) -> encode_selected(RightBranch, right, item)
    }
  }
}

fn encode_selected(
  side: BranchSide,
  codec: Codec(a),
  item: a,
) -> Result(SelectedBranch, NodeBoundaryError) {
  case blueprint.encode(codec, item) {
    Ok(raw) -> Ok(SelectedBranch(side, raw))
    Error(error) -> Error(InputValueDidNotEncode(error))
  }
}

fn evaluate_branch(
  raw_input: Value,
  definition: Definition(i, o, e, u),
  output: Codec(o),
) -> NodeOutcome(e, u) {
  case blueprint.decode(definition.input_codec, raw_input) {
    Error(error) -> NodeBoundaryFailed(InputValueDidNotDecode(error))
    Ok(input) ->
      case run_child(definition, input) {
        ChildSucceeded(output_value) ->
          case blueprint.encode(output, output_value) {
            Ok(encoded) -> NodeSucceeded(encoded)
            Error(error) -> NodeBoundaryFailed(OutputValueDidNotEncode(error))
          }
        ChildFailed(cause, undo_failures) -> NodeFailed(cause, undo_failures)
        ChildCancelled(undo_failures) -> NodeCancelled(undo_failures)
        ChildWaiting(run_id) -> NodeWaiting(run_id)
        ChildNeedsReconciliation(evidence) -> NodeNeedsReconciliation(evidence)
      }
  }
}

fn inspect_choice_nodes(
  nodes: List(Node(e, u)),
  id: NodeId,
  raw: Value,
) -> Result(SelectedBranch, SelectionError) {
  case matching_choice_routes(nodes, id) {
    [] -> Error(UnknownChoice(id))
    [route] ->
      case route(raw) {
        Ok(selected) -> Ok(selected)
        Error(error) -> Error(ChoiceInputRejected(error))
      }
    _ -> Error(AmbiguousChoice(id))
  }
}

fn matching_choice_routes(
  nodes: List(Node(e, u)),
  id: NodeId,
) -> List(fn(Value) -> Result(SelectedBranch, NodeBoundaryError)) {
  case nodes {
    [] -> []
    [node, ..rest] -> {
      let matches = case node.label, node.selection {
        ChoiceNode(address), Present(route) ->
          case address_contains_id(address, id) {
            True -> [route]
            False -> []
          }
        _, _ -> []
      }
      append(matches, matching_choice_routes(rest, id))
    }
  }
}

fn direct_node(
  nodes: List(Node(e, u)),
  id: NodeId,
) -> Result(Node(e, u), InspectionError) {
  case matching_direct_nodes(nodes, id) {
    [] -> Error(NotDirectActivity(id))
    [node] -> Ok(node)
    _ -> Error(AmbiguousNodeId(id))
  }
}

fn sequence_adapters(nodes: List(Node(e, u))) -> List(Node(e, u)) {
  case nodes {
    [] -> []
    [node, ..rest] -> {
      let matches = case node.label {
        SequenceBoundaryNode(_) -> [node]
        _ -> []
      }
      append(matches, sequence_adapters(rest))
    }
  }
}

fn matching_direct_nodes(
  nodes: List(Node(e, u)),
  id: NodeId,
) -> List(Node(e, u)) {
  case nodes {
    [] -> []
    [node, ..rest] -> {
      let matches = case node.label {
        ActivityNode(address) | ApprovalNode(address) ->
          case address_contains_id(address, id) {
            True -> [node]
            False -> []
          }
        _ -> []
      }
      append(matches, matching_direct_nodes(rest, id))
    }
  }
}

fn address_contains_id(address: NodeAddress, id: NodeId) -> Bool {
  case address {
    NamedAddress(found) -> found == id
    PairAddress(_) | SequenceBoundaryAddress -> False
    SequenceLeft(nested) | SequenceRight(nested) ->
      address_contains_id(nested, id)
    BranchAddress(owner, _, nested) ->
      address_contains_id(owner, id) || address_contains_id(nested, id)
    ChildAddress(owner, nested) ->
      address_contains_id(owner, id) || address_contains_id(nested, id)
  }
}

fn node_id_text(id: NodeId) -> String {
  let NodeId(value) = id
  value
}

fn child_evaluator(
  definition: Definition(i, o, e, u),
) -> fn(List(Value)) -> NodeOutcome(e, u) {
  fn(inputs) {
    case inputs {
      [raw] ->
        case blueprint.decode(definition.input_codec, raw) {
          Error(error) -> NodeBoundaryFailed(InputValueDidNotDecode(error))
          Ok(input) ->
            case run_child(definition, input) {
              ChildSucceeded(output) ->
                case blueprint.encode(definition.output.codec, output) {
                  Ok(encoded) -> NodeSucceeded(encoded)
                  Error(error) ->
                    NodeBoundaryFailed(OutputValueDidNotEncode(error))
                }
              ChildFailed(cause, undo_failures) ->
                NodeFailed(cause, undo_failures)
              ChildCancelled(undo_failures) -> NodeCancelled(undo_failures)
              ChildWaiting(run_id) -> NodeWaiting(run_id)
              ChildNeedsReconciliation(evidence) ->
                NodeNeedsReconciliation(evidence)
            }
        }
      other -> NodeBoundaryFailed(UnexpectedInputCount(length(other)))
    }
  }
}

fn compose(
  first: Definition(i, m, e, u),
  second: Definition(m, o, e, u),
  signature: String,
) -> Definition(i, o, e, u) {
  let input_token = fresh_token()
  let #(left_nodes, left_tokens) =
    rekey_nodes(first.nodes, first.input_token, input_token, LeftBranch)
  let left_output =
    Port(
      token_from_map(first.output.token, left_tokens),
      first.output.codec,
      prefix_label(first.output.label, LeftBranch),
    )
  let boundary =
    sequence_boundary(
      left_output,
      second.input_codec,
      first.error_codec,
      first.undo_error_codec,
    )
  let #(right_nodes, right_tokens) =
    rekey_nodes(second.nodes, second.input_token, boundary.token, RightBranch)
  let output =
    Port(
      token_from_map(second.output.token, right_tokens),
      second.output.codec,
      case second.output.token == second.input_token {
        True -> boundary.label
        False -> prefix_label(second.output.label, RightBranch)
      },
    )
  Definition(
    first.id,
    first.version,
    signature,
    input_token,
    first.input_codec,
    output,
    first.error_codec,
    first.undo_error_codec,
    append(left_nodes, [boundary, ..right_nodes]),
  )
}

fn rekey_nodes(
  nodes: List(Node(e, u)),
  old_input: Token,
  new_input: Token,
  side: BranchSide,
) -> #(List(Node(e, u)), List(#(Token, Token))) {
  rekey_nodes_from(nodes, [#(old_input, new_input)], side)
}

fn rekey_nodes_from(
  nodes: List(Node(e, u)),
  token_map: List(#(Token, Token)),
  side: BranchSide,
) -> #(List(Node(e, u)), List(#(Token, Token))) {
  case nodes {
    [] -> #([], token_map)
    [node, ..rest] -> {
      let Node(
        old_token,
        address,
        label,
        inputs,
        steps,
        evaluate,
        selection,
        compensate,
        validate_inputs,
        validate_output,
        error_codec,
        undo_error_codec,
      ) = node
      let token = fresh_token()
      let cloned =
        Node(
          token,
          prefix_address(address, side),
          prefix_label(label, side),
          map(inputs, fn(input) { token_from_map(input, token_map) }),
          map(steps, fn(step) { prefix_located_step(step, side) }),
          evaluate,
          selection,
          compensate,
          validate_inputs,
          validate_output,
          error_codec,
          undo_error_codec,
        )
      rekey_nodes_from(rest, append(token_map, [#(old_token, token)]), side)
      |> prepend_node(cloned)
    }
  }
}

fn prepend_node(
  result: #(List(Node(e, u)), List(#(Token, Token))),
  node: Node(e, u),
) -> #(List(Node(e, u)), List(#(Token, Token))) {
  let #(nodes, tokens) = result
  #([node, ..nodes], tokens)
}

fn token_from_map(token: Token, mappings: List(#(Token, Token))) -> Token {
  case mappings {
    [] -> token
    [#(source, target), ..rest] ->
      case token == source {
        True -> target
        False -> token_from_map(token, rest)
      }
  }
}

fn sequence_boundary(
  input: Port(m),
  target: Codec(m),
  error: Codec(e),
  undo_error: Codec(u),
) -> Node(e, u) {
  let address = SequenceBoundaryAddress
  let descriptor =
    synthetic_descriptor("sequence-boundary", SequenceAdapterStep)
  Node(
    fresh_token(),
    address,
    SequenceBoundaryNode(address),
    [input.token],
    [LocatedStep(ScopedStepId(address, "sequence-boundary"), descriptor)],
    fn(inputs) {
      case inputs {
        [raw] ->
          case blueprint.decode(input.codec, raw) {
            Error(decode_error) ->
              NodeBoundaryFailed(InputValueDidNotDecode(decode_error))
            Ok(value) ->
              case blueprint.encode(target, value) {
                Ok(encoded) -> NodeSucceeded(encoded)
                Error(encode_error) ->
                  NodeBoundaryFailed(InputValueDidNotEncode(encode_error))
              }
          }
        other -> NodeBoundaryFailed(UnexpectedInputCount(length(other)))
      }
    },
    Missing,
    Missing,
    [validator(input.codec)],
    validator(target),
    error,
    undo_error,
  )
}

fn prefix_address(address: NodeAddress, side: BranchSide) -> NodeAddress {
  case side {
    LeftBranch -> SequenceLeft(address)
    RightBranch -> SequenceRight(address)
  }
}

fn prefix_label(label: NodeLabel, side: BranchSide) -> NodeLabel {
  case label {
    InputPort -> InputPort
    ChildNode(address) -> ChildNode(prefix_address(address, side))
    PairNode(address) -> PairNode(prefix_address(address, side))
    ChoiceNode(address) -> ChoiceNode(prefix_address(address, side))
    ActivityNode(address) -> ActivityNode(prefix_address(address, side))
    ApprovalNode(address) -> ApprovalNode(prefix_address(address, side))
    SequenceBoundaryNode(address) ->
      SequenceBoundaryNode(prefix_address(address, side))
  }
}

fn prefix_located_step(step: LocatedStep, side: BranchSide) -> LocatedStep {
  let LocatedStep(identity, descriptor) = step
  let prefixed = case identity {
    ScopedStepId(node, id) -> ScopedStepId(prefix_address(node, side), id)
    BranchStepId(node, branch, id) ->
      BranchStepId(prefix_address(node, side), branch, id)
  }
  LocatedStep(prefixed, descriptor)
}
