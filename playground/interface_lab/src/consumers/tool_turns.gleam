// THROWAWAY: Can caller-owned approval separate tool execution from continuation?
import lab/blueprint
import lab/fabric
import lab/fabric_turn
import lab/llm
import lab/llm_turn as model
import lab/value

pub type PreviousResponseId {
  PreviousResponseId(String)
}

pub type TranscriptPhase {
  AwaitReadResult
  AwaitWriteResult
}

pub type Transcript {
  Transcript(messages: List(llm.Message), phase: TranscriptPhase)
}

pub type ReadContext {
  ReadContext(tenant: String)
}

pub type WriteContext {
  WriteContext(tenant: String)
}

pub type ToolFault {
  ToolFault(String)
}

pub type ProbeError {
  TurnRejected(fabric_turn.TurnError)
  UnexpectedReply
  WrongCall(String)
}

// Provider schemas below are raw Value fixtures. They are not provider schema
// conformance evidence and no transport is involved.
pub fn previous_response_provider() -> model.Provider(PreviousResponseId) {
  model.provider(
    fn(_request, _tools) {
      Ok(model.RequestsTools(PreviousResponseId("after-read"), [read_call()]))
    },
    fn(continuation, results) {
      case continuation, results {
        PreviousResponseId("after-read"), [model.ToolSucceeded(_, _)] ->
          Ok(
            model.RequestsTools(PreviousResponseId("after-write"), [
              write_call(),
            ]),
          )
        PreviousResponseId("after-write"), [model.ToolSucceeded(_, output)] ->
          Ok(model.Final(output))
        PreviousResponseId("after-write"), [model.ToolFailed(_, error)] ->
          Ok(model.Final(error))
        _, _ -> Error(llm.UnsupportedCapability)
      }
    },
  )
}

pub fn transcript_provider() -> model.Provider(Transcript) {
  model.provider(
    fn(request, _tools) {
      Ok(
        model.RequestsTools(Transcript(request.messages, AwaitReadResult), [
          read_call(),
        ]),
      )
    },
    fn(continuation, results) {
      case continuation.phase, results {
        AwaitReadResult, [model.ToolSucceeded(_, _output)] ->
          Ok(
            model.RequestsTools(
              Transcript(
                append(continuation.messages, [llm.Assistant("read complete")]),
                AwaitWriteResult,
              ),
              [write_call()],
            ),
          )
        AwaitWriteResult, [model.ToolSucceeded(_, output)] ->
          Ok(model.Final(output))
        AwaitWriteResult, [model.ToolFailed(_, error)] -> Ok(model.Final(error))
        _, _ -> Error(llm.UnsupportedCapability)
      }
    },
  )
}

pub type CallerAction(continuation) {
  ReturnResults(List(model.ToolResult))
  PendingApproval(ApprovalPending(continuation))
}

pub opaque type ApprovalPending(continuation) {
  ApprovalPending(
    pending: fabric_turn.Pending(continuation),
    call: model.ToolCall,
    context: WriteContext,
  )
}

pub fn wait_for_sensitive_write(
  provider: model.Provider(continuation),
  read_context: ReadContext,
  write_context: WriteContext,
) -> Result(ApprovalPending(continuation), ProbeError) {
  case fabric_turn.begin(provider, request(), declarations()) {
    Error(error) -> Error(TurnRejected(error))
    Ok(fabric_turn.Finished(_)) -> Error(UnexpectedReply)
    Ok(fabric_turn.NeedsTools(read_pending)) ->
      case fabric_turn.calls(read_pending) {
        [call] ->
          case call.name {
            model.ToolName("read") -> {
              let result = execute_read(read_tool(), read_context, call)
              case fabric_turn.resume(read_pending, [result]) {
                Error(error) -> Error(TurnRejected(error))
                Ok(fabric_turn.Finished(_)) -> Error(UnexpectedReply)
                Ok(fabric_turn.NeedsTools(write_pending)) ->
                  case caller_action(write_pending, write_context) {
                    Error(error) -> Error(error)
                    Ok(PendingApproval(waiting)) -> Ok(waiting)
                    Ok(ReturnResults(_)) -> Error(UnexpectedReply)
                  }
              }
            }
            _ -> Error(WrongCall("expected read tool"))
          }
        _ -> Error(WrongCall("expected one read call"))
      }
  }
}

// This branch returns the opaque pending turn and does not invoke the write tool.
fn caller_action(
  pending: fabric_turn.Pending(continuation),
  context: WriteContext,
) -> Result(CallerAction(continuation), ProbeError) {
  case fabric_turn.calls(pending) {
    [call] ->
      case call.name {
        model.ToolName("sensitive_write") ->
          Ok(PendingApproval(ApprovalPending(pending, call, context)))
        _ -> Error(WrongCall("expected sensitive write tool"))
      }
    _ -> Error(WrongCall("expected one sensitive write call"))
  }
}

// Approval is an explicit input. Only the accepted branch invokes the sensitive
// tool; denial is sent back to the provider as a failed tool result.
pub fn approve_and_resume(
  waiting: ApprovalPending(continuation),
  approved: Bool,
) -> Result(fabric_turn.Next(continuation), ProbeError) {
  let ApprovalPending(pending, call, context) = waiting
  let result = case approved {
    True -> execute_write(write_tool(), context, call)
    False -> model.ToolFailed(call.id, value.Text("approval denied"))
  }
  case fabric_turn.resume(pending, [result]) {
    Ok(next) -> Ok(next)
    Error(error) -> Error(TurnRejected(error))
  }
}

pub fn probe() -> Nil {
  case approved_probe() {
    Ok(value.Text("sensitive-write:tenant-approved")) ->
      case denied_probe() {
        Ok(value.Text("approval denied")) ->
          case invalid_results_probe() {
            Ok(Nil) -> Nil
            Error(_) ->
              panic as "missing and duplicate results must fail before the provider continuation"
          }
        _ -> panic as "denied approval must not execute the sensitive write"
      }
    _ ->
      panic as "the previous-response provider must complete the approved read/write loop"
  }
}

fn approved_probe() -> Result(value.Value, ProbeError) {
  use waiting <- result_try(wait_for_sensitive_write(
    previous_response_provider(),
    ReadContext("tenant-approved"),
    WriteContext("tenant-approved"),
  ))
  use next <- result_try(approve_and_resume(waiting, True))
  case next {
    fabric_turn.Finished(output) -> Ok(output)
    fabric_turn.NeedsTools(_) -> Error(UnexpectedReply)
  }
}

fn denied_probe() -> Result(value.Value, ProbeError) {
  use waiting <- result_try(wait_for_sensitive_write(
    transcript_provider(),
    ReadContext("tenant-denied"),
    WriteContext("tenant-denied"),
  ))
  use next <- result_try(approve_and_resume(waiting, False))
  case next {
    fabric_turn.Finished(output) -> Ok(output)
    fabric_turn.NeedsTools(_) -> Error(UnexpectedReply)
  }
}

fn invalid_results_probe() -> Result(Nil, ProbeError) {
  case
    fabric_turn.begin(previous_response_provider(), request(), declarations())
  {
    Error(error) -> Error(TurnRejected(error))
    Ok(fabric_turn.Finished(_)) -> Error(UnexpectedReply)
    Ok(fabric_turn.NeedsTools(pending)) ->
      case fabric_turn.calls(pending) {
        [call] -> {
          let result = model.ToolSucceeded(call.id, value.Text("read result"))
          let missing = fabric_turn.resume(pending, [])
          let duplicate = fabric_turn.resume(pending, [result, result])
          case missing, duplicate {
            Error(fabric_turn.MissingToolResult(_)),
              Error(fabric_turn.DuplicateToolResult(_))
            -> Ok(Nil)
            Error(error), _ -> Error(TurnRejected(error))
            _, Error(error) -> Error(TurnRejected(error))
            _, _ -> Error(UnexpectedReply)
          }
        }
        _ -> Error(WrongCall("expected one read call"))
      }
  }
}

fn read_call() -> model.ToolCall {
  model.ToolCall(
    model.CallId("read-call"),
    model.ToolName("read"),
    value.Text("inventory"),
  )
}

fn write_call() -> model.ToolCall {
  model.ToolCall(
    model.CallId("write-call"),
    model.ToolName("sensitive_write"),
    value.Text("checkout"),
  )
}

fn declarations() -> List(model.ToolDeclaration) {
  let toy_schema = value.Object([#("type", value.Text("string"))])
  [
    model.ToolDeclaration(model.ToolName("read"), "toy read", toy_schema),
    model.ToolDeclaration(
      model.ToolName("sensitive_write"),
      "toy write",
      toy_schema,
    ),
  ]
}

fn request() -> llm.Request {
  llm.Request([llm.User("process checkout")], 64)
}

fn read_tool() -> fabric.ContextTool(ReadContext) {
  fabric.context_tool(
    "read",
    blueprint.text(),
    blueprint.text(),
    fault_codec(),
    fn(context, item) {
      let ReadContext(tenant) = context
      Ok("read:" <> tenant <> ":" <> item)
    },
  )
}

fn write_tool() -> fabric.ContextTool(WriteContext) {
  fabric.context_tool(
    "sensitive_write",
    blueprint.text(),
    blueprint.text(),
    fault_codec(),
    fn(context, _item) {
      let WriteContext(tenant) = context
      Ok("sensitive-write:" <> tenant)
    },
  )
}

fn execute_read(
  tool: fabric.ContextTool(ReadContext),
  context: ReadContext,
  call: model.ToolCall,
) -> model.ToolResult {
  case fabric.invoke_context(tool, context, call.arguments) {
    Ok(output) -> model.ToolSucceeded(call.id, output)
    Error(_) -> model.ToolFailed(call.id, value.Text("read failed"))
  }
}

fn execute_write(
  tool: fabric.ContextTool(WriteContext),
  context: WriteContext,
  call: model.ToolCall,
) -> model.ToolResult {
  case fabric.invoke_context(tool, context, call.arguments) {
    Ok(output) -> model.ToolSucceeded(call.id, output)
    Error(_) -> model.ToolFailed(call.id, value.Text("write failed"))
  }
}

fn fault_codec() -> blueprint.Codec(ToolFault) {
  blueprint.new(
    fn(fault) {
      let ToolFault(message) = fault
      Ok(value.Text(message))
    },
    fn(raw) {
      case raw {
        value.Text(message) -> Ok(ToolFault(message))
        _ -> Error(blueprint.CannotDecode("Expected tool fault"))
      }
    },
  )
}

fn result_try(
  result: Result(a, e),
  callback: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Error(error) -> Error(error)
    Ok(value) -> callback(value)
  }
}

fn append(first: List(a), second: List(a)) -> List(a) {
  case first {
    [] -> second
    [head, ..tail] -> [head, ..append(tail, second)]
  }
}
