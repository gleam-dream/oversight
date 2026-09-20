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
  let expected = map(pending.calls, fn(call) { call.id })
  let supplied = map(results, model.result_id)
  case validate_results(supplied, expected, []) {
    Error(error) -> Error(error)
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
    Ok(model.RequestsTools(_, [])) -> Error(EmptyToolBatch)
    Ok(model.RequestsTools(continuation, calls)) ->
      case unique_calls(calls, []) {
        Error(error) -> Error(error)
        Ok(Nil) -> Ok(NeedsTools(Pending(provider, continuation, calls)))
      }
  }
}

fn unique_calls(
  calls: List(model.ToolCall),
  seen: List(model.CallId),
) -> Result(Nil, TurnError) {
  case calls {
    [] -> Ok(Nil)
    [call, ..rest] ->
      case contains(seen, call.id) {
        True -> Error(DuplicateCallId(call.id))
        False -> unique_calls(rest, [call.id, ..seen])
      }
  }
}

fn validate_results(
  supplied: List(model.CallId),
  expected: List(model.CallId),
  seen: List(model.CallId),
) -> Result(Nil, TurnError) {
  case supplied {
    [] -> require_all(expected, seen)
    [id, ..rest] ->
      case contains(expected, id), contains(seen, id) {
        False, _ -> Error(UnknownToolResult(id))
        True, True -> Error(DuplicateToolResult(id))
        True, False -> validate_results(rest, expected, [id, ..seen])
      }
  }
}

fn require_all(
  expected: List(model.CallId),
  supplied: List(model.CallId),
) -> Result(Nil, TurnError) {
  case expected {
    [] -> Ok(Nil)
    [id, ..rest] ->
      case contains(supplied, id) {
        True -> require_all(rest, supplied)
        False -> Error(MissingToolResult(id))
      }
  }
}

fn contains(items: List(a), wanted: a) -> Bool {
  case items {
    [] -> False
    [head, ..rest] ->
      case head == wanted {
        True -> True
        False -> contains(rest, wanted)
      }
  }
}

fn map(items: List(a), f: fn(a) -> b) -> List(b) {
  case items {
    [] -> []
    [head, ..rest] -> [f(head), ..map(rest, f)]
  }
}
