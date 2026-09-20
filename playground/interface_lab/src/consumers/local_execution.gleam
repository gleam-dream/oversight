// THROWAWAY: Can a canonical Saga definition run through explicit local work?
import lab/blueprint
import lab/saga
import lab/value

pub type BusinessError {
  SharedProducerRepeated
  StopAfterThree
}

pub type UndoError {
  UndoRejected(String)
}

pub type OrderId {
  OrderId(Int)
}

pub type CreditReview {
  CreditReview(order: OrderId, score: Int)
}

pub type StockReview {
  StockReview(order: OrderId, score: Int)
}

pub type ReviewSummary {
  ReviewSummary(order: OrderId, score: Int)
}

pub type ProbeError {
  AdmissionRejected(saga.LocalAdmissionError)
  ControllerRejected(saga.LocalControlError)
  UnexpectedControllerTransition
}

@external(erlang, "erlang", "unique_integer")
fn fresh_order_number() -> Int

pub fn probe() -> Nil {
  let shared_result = run(shared_graph(), "request")
  let assert Ok(saga.LocalExecutionSucceeded(ReviewSummary(_, 9), [])) =
    shared_result

  let reverse_result = run(fail_after_three(), "start")
  let first_address = saga.NamedAddress(required_node_id("local.first"))
  let second_address = saga.NamedAddress(required_node_id("local.second"))
  let third_address = saga.NamedAddress(required_node_id("local.third"))
  let stop_address = saga.NamedAddress(required_node_id("local.stop"))
  let assert Ok(saga.LocalExecutionFailed(
    saga.LocalFailed(
      saga.LocalApplicationCause(failure_node, StopAfterThree),
      reverse_undo_failures,
    ),
    uncompensated,
  )) = reverse_result
  let assert True = failure_node == stop_address
  let assert True =
    reverse_undo_failures
    == [
      saga.LocalUndoFailed(third_address, UndoRejected("third")),
      saga.LocalUndoFailed(second_address, UndoRejected("second")),
      saga.LocalUndoFailed(first_address, UndoRejected("first")),
    ]
  let assert True = uncompensated == []

  let cancellation_result = cancel_after_two(cancel_graph(), "cancel")
  let cancel_second = saga.NamedAddress(required_node_id("cancel.second"))
  let assert Ok(saga.LocalExecutionFailed(
    saga.LocalCancelled(undo_failures),
    [],
  )) = cancellation_result
  let assert True =
    undo_failures
    == [
      saga.LocalUndoFailed(cancel_second, UndoRejected("cancel.second")),
    ]

  let encode_failure = run(activity_output_encode_failure(), "encode")
  let encode_node = saga.NamedAddress(required_node_id("encode.effect"))
  let assert Ok(saga.LocalExecutionFailed(
    saga.LocalFailed(
      saga.LocalBoundaryCause(
        saga.LocalNodeAt(encode_node),
        saga.LocalActivityOutputEncodingFailed(_),
      ),
      encode_undo_failures,
    ),
    [],
  )) = encode_failure
  let assert True =
    encode_undo_failures
    == [
      saga.LocalUndoFailed(encode_node, UndoRejected("encoded-output")),
    ]

  let final_decode_failure = run(final_output_decode_failure(), "decode")
  let decode_node = saga.NamedAddress(required_node_id("decode.effect"))
  let assert Ok(saga.LocalExecutionFailed(
    saga.LocalFailed(
      saga.LocalBoundaryCause(
        saga.LocalDefinitionOutput,
        saga.LocalFinalOutputDecodingFailed(_),
      ),
      decode_undo_failures,
    ),
    [],
  )) = final_decode_failure
  let assert True =
    decode_undo_failures
    == [
      saga.LocalUndoFailed(decode_node, UndoRejected("decode-output")),
    ]

  let adapter_failure = run(sequence_adapter_failure(), "adapt")
  let adapter_effect =
    saga.SequenceLeft(saga.NamedAddress(required_node_id("adapter.first")))
  let assert Ok(saga.LocalExecutionFailed(
    saga.LocalFailed(
      saga.LocalBoundaryCause(
        saga.LocalNodeAt(saga.SequenceBoundaryAddress),
        saga.LocalAdapterBoundaryFailed(saga.InputValueDidNotEncode(blueprint.CannotEncode(
          "sequence target",
        ))),
      ),
      adapter_undo_failures,
    ),
    [],
  )) = adapter_failure
  let assert True =
    adapter_undo_failures
    == [
      saga.LocalUndoFailed(adapter_effect, UndoRejected("adapter.first")),
    ]

  let no_compensation = run(uncompensated_activity(), "open")
  let open_address = saga.NamedAddress(required_node_id("open.effect"))
  let assert Ok(saga.LocalExecutionSucceeded(
    "effect survived",
    uncompensated_effects,
  )) = no_compensation
  let assert True = uncompensated_effects == [open_address]

  let identity = run(identity_definition(), "identity")
  let assert Ok(saga.LocalExecutionSucceeded("identity", [])) = identity

  let assert Error(saga.LocalNodeKindNotSupported(saga.NamedAddress(_))) =
    saga.start_local(unsupported_definition(), "must not encode")

  let correlation_checks =
    check_completion_correlation(simple_activity(), "correlation")
  let assert True = correlation_checks
  Nil
}

fn shared_graph() -> saga.Definition(
  String,
  ReviewSummary,
  BusinessError,
  UndoError,
) {
  let #(builder, request) =
    saga.begin(blueprint.text(), business_error_codec(), undo_error_codec())
  let #(builder, order) =
    add_activity(
      builder,
      request,
      "shared.create",
      blueprint.text(),
      order_codec(),
      fn(_) { Ok(OrderId(fresh_order_number())) },
      saga.Compensate(fn(_, _) { Ok(Nil) }),
    )
  let #(builder, credit) =
    add_activity(
      builder,
      order,
      "shared.credit",
      order_codec(),
      credit_codec(),
      fn(order_id) { Ok(CreditReview(order_id, 4)) },
      saga.Compensate(fn(_, _) { Ok(Nil) }),
    )
  let #(builder, stock) =
    add_activity(
      builder,
      order,
      "shared.stock",
      order_codec(),
      stock_codec(),
      fn(order_id) { Ok(StockReview(order_id, 5)) },
      saga.Compensate(fn(_, _) { Ok(Nil) }),
    )
  let assert Ok(#(builder, both)) = saga.pair(builder, credit, stock)
  let #(builder, summary) =
    add_activity(
      builder,
      both,
      "shared.summary",
      blueprint.pair(credit_codec(), stock_codec()),
      summary_codec(),
      fn(pair) {
        case pair.0.order == pair.1.order {
          True -> Ok(ReviewSummary(pair.0.order, pair.0.score + pair.1.score))
          False -> Error(SharedProducerRepeated)
        }
      },
      saga.Compensate(fn(_, _) { Ok(Nil) }),
    )
  finish(builder, summary, "shared.graph")
}

fn fail_after_three() -> saga.Definition(
  String,
  String,
  BusinessError,
  UndoError,
) {
  let #(builder, input) =
    saga.begin(blueprint.text(), business_error_codec(), undo_error_codec())
  let #(builder, first) =
    add_activity(
      builder,
      input,
      "local.first",
      blueprint.text(),
      blueprint.text(),
      fn(text) { Ok(text <> ":first") },
      saga.Compensate(fn(_, _) { Error(UndoRejected("first")) }),
    )
  let #(builder, second) =
    add_activity(
      builder,
      first,
      "local.second",
      blueprint.text(),
      blueprint.text(),
      fn(text) { Ok(text <> ":second") },
      saga.Compensate(fn(_, _) { Error(UndoRejected("second")) }),
    )
  let #(builder, third) =
    add_activity(
      builder,
      second,
      "local.third",
      blueprint.text(),
      blueprint.text(),
      fn(text) { Ok(text <> ":third") },
      saga.Compensate(fn(_, _) { Error(UndoRejected("third")) }),
    )
  let #(builder, stopped) =
    add_activity(
      builder,
      third,
      "local.stop",
      blueprint.text(),
      blueprint.text(),
      fn(_) { Error(StopAfterThree) },
      saga.Uncompensated,
    )
  finish(builder, stopped, "fail.after-three")
}

fn cancel_graph() -> saga.Definition(
  String,
  #(String, String),
  BusinessError,
  UndoError,
) {
  let #(builder, input) =
    saga.begin(blueprint.text(), business_error_codec(), undo_error_codec())
  let #(builder, first) =
    add_activity(
      builder,
      input,
      "cancel.first",
      blueprint.text(),
      blueprint.text(),
      fn(text) { Ok(text <> ":first") },
      saga.Compensate(fn(_, _) { Ok(Nil) }),
    )
  let #(builder, second) =
    add_activity(
      builder,
      input,
      "cancel.second",
      blueprint.text(),
      blueprint.text(),
      fn(text) { Ok(text <> ":second") },
      saga.Compensate(fn(_, _) { Error(UndoRejected("cancel.second")) }),
    )
  let assert Ok(#(builder, pair)) = saga.pair(builder, first, second)
  finish(builder, pair, "cancel.graph")
}

fn activity_output_encode_failure() -> saga.Definition(
  String,
  String,
  BusinessError,
  UndoError,
) {
  let output =
    blueprint.new(
      fn(_) { Error(blueprint.CannotEncode("activity output")) },
      fn(raw) {
        case raw {
          value.Text(text) -> Ok(text)
          _ -> Error(blueprint.CannotDecode("expected text"))
        }
      },
    )
  definition(
    "encode.effect",
    blueprint.text(),
    output,
    fn(text) { Ok(text <> ":effect") },
    saga.Compensate(fn(_, _) { Error(UndoRejected("encoded-output")) }),
  )
}

fn final_output_decode_failure() -> saga.Definition(
  String,
  String,
  BusinessError,
  UndoError,
) {
  let output =
    blueprint.new(fn(text) { Ok(value.Text(text)) }, fn(_) {
      Error(blueprint.CannotDecode("final output"))
    })
  definition(
    "decode.effect",
    blueprint.text(),
    output,
    fn(text) { Ok(text <> ":effect") },
    saga.Compensate(fn(_, _) { Error(UndoRejected("decode-output")) }),
  )
}

fn sequence_adapter_failure() -> saga.Definition(
  String,
  String,
  BusinessError,
  UndoError,
) {
  let first =
    definition(
      "adapter.first",
      blueprint.text(),
      blueprint.text(),
      fn(text) { Ok(text <> ":first") },
      saga.Compensate(fn(_, _) { Error(UndoRejected("adapter.first")) }),
    )
  let incompatible_input =
    blueprint.new(
      fn(_) { Error(blueprint.CannotEncode("sequence target")) },
      fn(raw) {
        case raw {
          value.Text(text) -> Ok(text)
          _ -> Error(blueprint.CannotDecode("expected text"))
        }
      },
    )
  let second =
    definition(
      "adapter.second",
      incompatible_input,
      blueprint.text(),
      fn(_) { todo as "the successor must not run after adapter failure" },
      saga.Uncompensated,
    )
  saga.and_then("adapter.failure", first, second)
}

fn uncompensated_activity() -> saga.Definition(
  String,
  String,
  BusinessError,
  UndoError,
) {
  definition(
    "open.effect",
    blueprint.text(),
    blueprint.text(),
    fn(_) { Ok("effect survived") },
    saga.Uncompensated,
  )
}

fn unsupported_definition() -> saga.Definition(
  String,
  saga.ApprovalResult(String, Bool),
  BusinessError,
  UndoError,
) {
  let panic_codec =
    blueprint.new(
      fn(_) { todo as "local admission must reject approval before encoding" },
      fn(_) { todo as "local admission must reject approval before decoding" },
    )
  let #(builder, input) =
    saga.begin(panic_codec, business_error_codec(), undo_error_codec())
  let panic_activity =
    typed_activity(
      "unsupported.before-approval",
      panic_codec,
      panic_codec,
      fn(_) { todo as "the admission pass must not execute activities" },
      saga.Uncompensated,
    )
  let assert Ok(#(builder, activity_output)) =
    saga.add_activity(
      builder,
      input,
      required_node_id("unsupported.activity"),
      panic_activity,
    )
  let approval =
    saga.approval(
      required_step_id("unsupported.approval"),
      required_version(1),
      required_version(1),
      required_version(1),
      required_version(1),
      required_version(1),
      blueprint.text(),
      blueprint.bool(),
      business_error_codec(),
      undo_error_codec(),
    )
  let assert Ok(#(builder, approval_output)) =
    saga.add_approval(
      builder,
      activity_output,
      required_node_id("unsupported.approval-node"),
      approval,
    )
  finish(builder, approval_output, "unsupported.graph")
}

fn identity_definition() -> saga.Definition(
  String,
  String,
  BusinessError,
  UndoError,
) {
  let #(builder, input) =
    saga.begin(blueprint.text(), business_error_codec(), undo_error_codec())
  finish(builder, input, "identity")
}

fn simple_activity() -> saga.Definition(
  String,
  String,
  BusinessError,
  UndoError,
) {
  definition(
    "correlation.activity",
    blueprint.text(),
    blueprint.text(),
    fn(text) { Ok(text) },
    saga.Uncompensated,
  )
}

fn check_completion_correlation(
  workflow: saga.Definition(String, String, BusinessError, UndoError),
  input: String,
) -> Bool {
  let assert Ok(first_run) = saga.start_local(workflow, input)
  let assert saga.LocalWorkIssued(first_waiting, first_work) =
    saga.advance_local(first_run, saga.ContinueLocal)
  let assert Ok(second_run) = saga.start_local(workflow, input)
  let assert saga.LocalWorkIssued(_, second_work) =
    saga.advance_local(second_run, saga.ContinueLocal)
  let second_completion = saga.perform_local(second_work)
  let cross_run_rejected = case
    saga.advance_local(first_waiting, saga.CompleteLocal(second_completion))
  {
    saga.LocalControlRejected(_, saga.LocalCompletionDoesNotMatch) -> True
    _ -> False
  }
  let cancel_while_pending_rejected = case
    saga.advance_local(first_waiting, saga.CancelLocal)
  {
    saga.LocalControlRejected(_, saga.LocalWorkStillPending) -> True
    _ -> False
  }
  let first_completion = saga.perform_local(first_work)
  let assert saga.LocalExecutionPaused(after_first) =
    saga.advance_local(first_waiting, saga.CompleteLocal(first_completion))
  let duplicate_rejected = case
    saga.advance_local(after_first, saga.CompleteLocal(first_completion))
  {
    saga.LocalControlRejected(_, saga.LocalCompletionNotExpected) -> True
    _ -> False
  }
  cross_run_rejected && cancel_while_pending_rejected && duplicate_rejected
}

fn cancel_after_two(
  definition: saga.Definition(
    String,
    #(String, String),
    BusinessError,
    UndoError,
  ),
  input: String,
) -> Result(
  saga.LocalReport(#(String, String), BusinessError, UndoError),
  ProbeError,
) {
  let first_address = saga.NamedAddress(required_node_id("cancel.first"))
  let second_address = saga.NamedAddress(required_node_id("cancel.second"))
  case saga.start_local(definition, input) {
    Error(error) -> Error(AdmissionRejected(error))
    Ok(execution) ->
      case run_one_work(execution) {
        Error(error) -> Error(error)
        Ok(#(after_input, input_work)) -> {
          let assert saga.LocalInputEncoding = input_work
          case run_one_work(after_input) {
            Error(error) -> Error(error)
            Ok(#(after_first, first_work)) -> {
              let assert True =
                first_work == saga.LocalActivityAt(first_address)
              case run_one_work(after_first) {
                Error(error) -> Error(error)
                Ok(#(after_second, second_work)) -> {
                  let assert True =
                    second_work == saga.LocalActivityAt(second_address)
                  case saga.advance_local(after_second, saga.CancelLocal) {
                    saga.LocalExecutionPaused(cancelled) ->
                      case drive_to_report_traced(cancelled) {
                        Error(error) -> Error(error)
                        Ok(#(report, descriptors)) -> {
                          let expected = [
                            saga.LocalUndoAt(second_address),
                            saga.LocalUndoAt(first_address),
                          ]
                          let assert True = descriptors == expected
                          Ok(report)
                        }
                      }
                    saga.LocalExecutionFinished(_, report) -> Ok(report)
                    saga.LocalControlRejected(_, error) ->
                      Error(ControllerRejected(error))
                    saga.LocalWorkIssued(_, _) ->
                      Error(UnexpectedControllerTransition)
                  }
                }
              }
            }
          }
        }
      }
  }
}

fn run_one_work(
  execution: saga.LocalExecution(o, BusinessError, UndoError),
) -> Result(
  #(saga.LocalExecution(o, BusinessError, UndoError), saga.LocalWorkDescriptor),
  ProbeError,
) {
  case saga.advance_local(execution, saga.ContinueLocal) {
    saga.LocalWorkIssued(waiting, work) -> {
      let descriptor = saga.local_work_descriptor(work)
      let completion = saga.perform_local(work)
      case saga.advance_local(waiting, saga.CompleteLocal(completion)) {
        saga.LocalExecutionPaused(next) -> Ok(#(next, descriptor))
        saga.LocalControlRejected(_, error) -> Error(ControllerRejected(error))
        saga.LocalExecutionFinished(_, _) | saga.LocalWorkIssued(_, _) ->
          Error(UnexpectedControllerTransition)
      }
    }
    saga.LocalExecutionPaused(_) -> Error(UnexpectedControllerTransition)
    saga.LocalControlRejected(_, error) -> Error(ControllerRejected(error))
    saga.LocalExecutionFinished(_, _) | saga.LocalWorkIssued(_, _) ->
      Error(UnexpectedControllerTransition)
  }
}

fn drive_to_report_traced(
  execution: saga.LocalExecution(o, BusinessError, UndoError),
) -> Result(
  #(
    saga.LocalReport(o, BusinessError, UndoError),
    List(saga.LocalWorkDescriptor),
  ),
  ProbeError,
) {
  case saga.advance_local(execution, saga.ContinueLocal) {
    saga.LocalWorkIssued(waiting, work) -> {
      let descriptor = saga.local_work_descriptor(work)
      let completion = saga.perform_local(work)
      case saga.advance_local(waiting, saga.CompleteLocal(completion)) {
        saga.LocalExecutionPaused(next) ->
          case drive_to_report_traced(next) {
            Error(error) -> Error(error)
            Ok(#(report, remaining)) -> Ok(#(report, [descriptor, ..remaining]))
          }
        saga.LocalExecutionFinished(_, report) -> Ok(#(report, [descriptor]))
        saga.LocalControlRejected(_, error) -> Error(ControllerRejected(error))
        saga.LocalWorkIssued(_, _) -> Error(UnexpectedControllerTransition)
      }
    }
    saga.LocalExecutionPaused(next) -> drive_to_report_traced(next)
    saga.LocalExecutionFinished(_, report) -> Ok(#(report, []))
    saga.LocalControlRejected(_, error) -> Error(ControllerRejected(error))
  }
}

fn run(
  definition: saga.Definition(i, o, BusinessError, UndoError),
  input: i,
) -> Result(saga.LocalReport(o, BusinessError, UndoError), ProbeError) {
  case saga.start_local(definition, input) {
    Error(error) -> Error(AdmissionRejected(error))
    Ok(execution) -> drive_to_report(execution)
  }
}

fn drive_to_report(
  execution: saga.LocalExecution(o, BusinessError, UndoError),
) -> Result(saga.LocalReport(o, BusinessError, UndoError), ProbeError) {
  case saga.advance_local(execution, saga.ContinueLocal) {
    saga.LocalWorkIssued(waiting, work) -> {
      let completion = saga.perform_local(work)
      case saga.advance_local(waiting, saga.CompleteLocal(completion)) {
        saga.LocalExecutionPaused(next) -> drive_to_report(next)
        saga.LocalExecutionFinished(_, report) -> Ok(report)
        saga.LocalControlRejected(_, error) -> Error(ControllerRejected(error))
        saga.LocalWorkIssued(_, _) -> Error(UnexpectedControllerTransition)
      }
    }
    saga.LocalExecutionPaused(next) -> drive_to_report(next)
    saga.LocalExecutionFinished(_, report) -> Ok(report)
    saga.LocalControlRejected(_, error) -> Error(ControllerRejected(error))
  }
}

fn definition(
  name: String,
  input: blueprint.Codec(i),
  output: blueprint.Codec(o),
  execute: fn(i) -> Result(o, BusinessError),
  compensation: saga.Compensation(i, o, UndoError),
) -> saga.Definition(i, o, BusinessError, UndoError) {
  let version = required_version(1)
  let contract =
    saga.ActivityContract(
      saga.VersionedCodec(version, input),
      saga.VersionedCodec(version, output),
      saga.VersionedCodec(version, business_error_codec()),
      saga.VersionedCodec(version, undo_error_codec()),
    )
  let activity =
    saga.activity(
      required_step_id(name),
      version,
      contract,
      execute,
      compensation,
    )
  saga.define(
    required_definition_id(name <> ".definition"),
    version,
    name <> ":v1",
    activity,
  )
}

fn typed_activity(
  name: String,
  input: blueprint.Codec(i),
  output: blueprint.Codec(o),
  execute: fn(i) -> Result(o, BusinessError),
  compensation: saga.Compensation(i, o, UndoError),
) -> saga.Activity(i, o, BusinessError, UndoError) {
  let version = required_version(1)
  saga.activity(
    required_step_id(name),
    version,
    saga.ActivityContract(
      saga.VersionedCodec(version, input),
      saga.VersionedCodec(version, output),
      saga.VersionedCodec(version, business_error_codec()),
      saga.VersionedCodec(version, undo_error_codec()),
    ),
    execute,
    compensation,
  )
}

fn add_activity(
  builder: saga.Builder(String, BusinessError, UndoError),
  input_port: saga.Port(a),
  name: String,
  input: blueprint.Codec(a),
  output: blueprint.Codec(b),
  execute: fn(a) -> Result(b, BusinessError),
  compensation: saga.Compensation(a, b, UndoError),
) -> #(saga.Builder(String, BusinessError, UndoError), saga.Port(b)) {
  let activity = typed_activity(name, input, output, execute, compensation)
  let assert Ok(result) =
    saga.add_activity(builder, input_port, required_node_id(name), activity)
  result
}

fn finish(
  builder: saga.Builder(String, BusinessError, UndoError),
  output: saga.Port(o),
  name: String,
) -> saga.Definition(String, o, BusinessError, UndoError) {
  let assert Ok(definition) =
    saga.finish(
      builder,
      output,
      required_definition_id(name),
      required_version(1),
      name <> ":v1",
    )
  definition
}

fn order_codec() -> blueprint.Codec(OrderId) {
  blueprint.imap(blueprint.int(), fn(number) { OrderId(number) }, fn(order) {
    let OrderId(number) = order
    number
  })
}

fn credit_codec() -> blueprint.Codec(CreditReview) {
  blueprint.imap(
    blueprint.pair(order_codec(), blueprint.int()),
    fn(pair) { CreditReview(pair.0, pair.1) },
    fn(review) { #(review.order, review.score) },
  )
}

fn stock_codec() -> blueprint.Codec(StockReview) {
  blueprint.imap(
    blueprint.pair(order_codec(), blueprint.int()),
    fn(pair) { StockReview(pair.0, pair.1) },
    fn(review) { #(review.order, review.score) },
  )
}

fn summary_codec() -> blueprint.Codec(ReviewSummary) {
  blueprint.imap(
    blueprint.pair(order_codec(), blueprint.int()),
    fn(pair) { ReviewSummary(pair.0, pair.1) },
    fn(summary) { #(summary.order, summary.score) },
  )
}

fn business_error_codec() -> blueprint.Codec(BusinessError) {
  blueprint.imap(
    blueprint.text(),
    fn(message) {
      case message {
        "shared producer repeated" -> SharedProducerRepeated
        _ -> StopAfterThree
      }
    },
    fn(error) {
      case error {
        SharedProducerRepeated -> "shared producer repeated"
        StopAfterThree -> "stop after three"
      }
    },
  )
}

fn undo_error_codec() -> blueprint.Codec(UndoError) {
  blueprint.imap(blueprint.text(), UndoRejected, fn(error) {
    case error {
      UndoRejected(message) -> message
    }
  })
}

fn required_node_id(name: String) -> saga.NodeId {
  let assert Ok(id) = saga.node_id(name)
  id
}

fn required_definition_id(name: String) -> saga.DefinitionId {
  let assert Ok(id) = saga.definition_id(name)
  id
}

fn required_step_id(name: String) -> saga.StepId {
  let assert Ok(id) = saga.step_id(name)
  id
}

fn required_version(number: Int) -> saga.Version {
  let assert Ok(version) = saga.version(number)
  version
}
