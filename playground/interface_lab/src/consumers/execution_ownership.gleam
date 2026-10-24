// THROWAWAY: Direct callbacks are scripted; no scheduler or child runtime runs.
import lab/blueprint
import lab/grind.{type Queue}
import lab/saga
import lab/saga_checkpoint as checkpoint
import lab/saga_grind
import lab/value

pub type Failure {
  Offline
}

pub type UndoFailure {
  UnexpectedReceipt
}

pub fn direct_definition() -> saga.Definition(
  Int,
  saga.ApprovalResult(Int, Bool),
  Failure,
  UndoFailure,
) {
  let error_codec = unavailable_error_codec()
  let undo_codec = unavailable_undo_codec()
  let operation = operation()
  let #(builder, input) = saga.begin(blueprint.int(), error_codec, undo_codec)
  let assert Ok(#(builder, output)) =
    saga.add_activity(builder, input, id("direct"), operation)
  let approval =
    saga.approval(
      step("approval"),
      version(),
      version(),
      version(),
      version(),
      version(),
      blueprint.int(),
      blueprint.bool(),
      error_codec,
      undo_codec,
    )
  let assert Ok(#(builder, approved)) =
    saga.add_approval(builder, output, id("approval"), approval)
  let assert Ok(flow) =
    saga.finish(builder, approved, definition_id(), version(), "direct:v1")
  flow
}

pub fn start_direct(
  input: Int,
) -> Result(
  checkpoint.Execution(saga.ApprovalResult(Int, Bool), Failure, UndoFailure),
  checkpoint.StartError,
) {
  checkpoint.start(direct_definition(), input)
}

pub fn submit_direct(
  queue: Queue,
  input: Int,
) -> Result(
  saga_grind.RunHandle(saga.ApprovalResult(Int, Bool), Failure, UndoFailure),
  saga_grind.SubmitError,
) {
  saga_grind.submit(queue, direct_definition(), input)
}

pub fn probe() -> Nil {
  let error_codec = unavailable_error_codec()
  let undo_codec = unavailable_undo_codec()
  let operation = operation()
  let flow = direct_definition()
  let assert Ok(saga.NodeSucceeded(value.Int(4))) =
    saga.probe_direct(flow, id("direct"), value.Int(3))
  // These codecs intentionally cannot encode errors. In-process callbacks
  // preserve native errors rather than passing through a wire roundtrip.
  let assert Ok(saga.NodeFailed(Offline, [])) =
    saga.probe_direct(flow, id("direct"), value.Int(-1))
  let assert Ok(Nil) =
    saga.probe_compensation(flow, id("direct"), value.Int(3), value.Int(4))
  let assert Error(saga.CompensationFailed(UnexpectedReceipt)) =
    saga.probe_compensation(flow, id("direct"), value.Int(3), value.Int(5))
  let assert Error(saga.CompensationOutputRejected(_)) =
    saga.probe_compensation(flow, id("direct"), value.Int(3), value.Text("bad"))
  let assert Ok(saga.NodeAwaitingApproval) =
    saga.probe_direct(flow, id("approval"), value.Int(4))
  let assert Ok(saga.NodeBoundaryFailed(_)) =
    saga.probe_direct(flow, id("approval"), value.Text("bad"))
  let assert Ok(def_id) = saga.definition_id("child")
  let child_definition = saga.define(def_id, version(), "child:v1", operation)
  let #(builder, input) = saga.begin(blueprint.int(), error_codec, undo_codec)
  let assert Ok(#(builder, output)) =
    saga.add_child(builder, input, id("child"), child_definition)
  let assert Ok(child_flow) =
    saga.finish(builder, output, definition_id(), version(), "child-flow:v1")
  let assert Error(saga.NotDirectActivity(_)) =
    saga.probe_direct(child_flow, id("child"), value.Int(3))
  let assert Error(saga.CompensationNotDeclared) =
    saga.probe_compensation(child_flow, id("child"), value.Int(3), value.Int(4))
  Nil
}

fn operation() -> saga.Activity(Int, Int, Failure, UndoFailure) {
  let contract =
    saga.ActivityContract(
      saga.VersionedCodec(version(), blueprint.field("input", blueprint.int())),
      saga.VersionedCodec(version(), blueprint.int()),
      saga.VersionedCodec(version(), unavailable_error_codec()),
      saga.VersionedCodec(version(), unavailable_undo_codec()),
    )
  saga.activity(
    step("increment"),
    version(),
    contract,
    fn(input) {
      case input < 0 {
        True -> Error(Offline)
        False -> Ok(input + 1)
      }
    },
    saga.Compensate(fn(input, output) {
      case output == input + 1 {
        True -> Ok(Nil)
        False -> Error(UnexpectedReceipt)
      }
    }),
  )
}

fn unavailable_error_codec() -> blueprint.Codec(Failure) {
  blueprint.new(
    fn(_) { Error(blueprint.CannotEncode("not serializable")) },
    fn(_) { Error(blueprint.CannotDecode("not serializable")) },
  )
}

fn unavailable_undo_codec() -> blueprint.Codec(UndoFailure) {
  blueprint.new(
    fn(_) { Error(blueprint.CannotEncode("not serializable")) },
    fn(_) { Error(blueprint.CannotDecode("not serializable")) },
  )
}

fn version() -> saga.Version {
  let assert Ok(version) = saga.version(1)
  version
}

fn id(name: String) -> saga.NodeId {
  let assert Ok(id) = saga.node_id(name)
  id
}

fn definition_id() -> saga.DefinitionId {
  let assert Ok(id) = saga.definition_id("execution-ownership")
  id
}

fn step(name: String) -> saga.StepId {
  let assert Ok(id) = saga.step_id(name)
  id
}
