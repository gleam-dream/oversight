// THROWAWAY: Can an application own tool policy while Fabric retains continuation?
import lab/llm
import lab/llm_turn as model
import lab/value.{type Value}

pub opaque type Pending(c) {
  Pending(
    provider: model.Provider(c),
    continuation: c,
    calls: List(model.ToolCall),
  )
}

pub type Next(c) {
  Finished(Value)
  NeedsTools(Pending(c))
}

pub type TurnError {
  ModelFailed(llm.CallError)
  EmptyToolBatch
  DuplicateCallId(model.CallId)
  UnknownToolResult(model.CallId)
  DuplicateToolResult(model.CallId)
  MissingToolResult(model.CallId)
}

pub fn begin(
  provider: model.Provider(c),
  request: llm.Request,
  tools: List(model.ToolDeclaration),
) -> Result(Next(c), TurnError) {
  accept(provider, model.start(provider, request, tools))
}

pub fn calls(pending: Pending(c)) -> List(model.ToolCall) {
  pending.calls
}

// The caller may await approval before returning results. Nothing executes a
// tool here, and this in-memory Pending value is not a durable continuation.
pub fn resume(
  pending: Pending(c),
  results: List(model.ToolResult),
) -> Result(Next(c), TurnError) {
  case model.validate_results(pending.calls, results) {
    Error(model.UnknownToolResult(id)) -> Error(UnknownToolResult(id))
    Error(model.DuplicateToolResult(id)) -> Error(DuplicateToolResult(id))
    Error(model.MissingToolResult(id)) -> Error(MissingToolResult(id))
    Ok(Nil) ->
      accept(
        pending.provider,
        model.continue(pending.provider, pending.continuation, results),
      )
  }
}

fn accept(
  provider: model.Provider(c),
  reply: Result(model.Reply(c), llm.CallError),
) -> Result(Next(c), TurnError) {
  case reply {
    Error(error) -> Error(ModelFailed(error))
    Ok(model.Final(output)) -> Ok(Finished(output))
    Ok(model.RequestsTools(continuation, calls)) ->
      case model.validate_calls(calls) {
        Error(model.EmptyToolBatch) -> Error(EmptyToolBatch)
        Error(model.DuplicateCallId(id)) -> Error(DuplicateCallId(id))
        Ok(Nil) -> Ok(NeedsTools(Pending(provider, continuation, calls)))
      }
  }
}
