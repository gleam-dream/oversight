// THROWAWAY: Can one provider turn expose tool requests without executing tools?
import lab/llm
import lab/value.{type Value}

// Provider adapter owns validation of model, transport and continuation identity.
pub type CallId {
  CallId(String)
}

pub type ToolName {
  ToolName(String)
}

pub type ToolCall {
  ToolCall(id: CallId, name: ToolName, arguments: Value)
}

pub type ToolResult {
  ToolSucceeded(id: CallId, output: Value)
  ToolFailed(id: CallId, error: Value)
}

pub type CallBatchError {
  EmptyToolBatch
  DuplicateCallId(CallId)
}

pub type ResultSetError {
  UnknownToolResult(CallId)
  DuplicateToolResult(CallId)
  MissingToolResult(CallId)
}

// This validation belongs to the generic provider boundary so Fabric and
// standalone structured calls agree on identity coverage before continuation.
pub fn validate_calls(calls: List(ToolCall)) -> Result(Nil, CallBatchError) {
  case calls {
    [] -> Error(EmptyToolBatch)
    [_, ..] -> validate_unique_calls(calls, [])
  }
}

pub fn validate_results(
  expected_calls: List(ToolCall),
  results: List(ToolResult),
) -> Result(Nil, ResultSetError) {
  validate_result_ids(expected_calls, map_results(results, result_id), [])
}

// Schema is an explicit external data boundary, not a validated schema witness.
// Blueprint schema derivation and provider dialect negotiation remain unproven.
pub type ToolDeclaration {
  ToolDeclaration(name: ToolName, description: String, input_schema: Value)
}

pub type Reply(continuation) {
  Final(Value)
  RequestsTools(continuation, List(ToolCall))
}

pub opaque type Provider(continuation) {
  Provider(
    start: fn(llm.Request, List(ToolDeclaration)) ->
      Result(Reply(continuation), llm.CallError),
    continue: fn(continuation, List(ToolResult)) ->
      Result(Reply(continuation), llm.CallError),
  )
}

pub fn provider(
  start: fn(llm.Request, List(ToolDeclaration)) ->
    Result(Reply(c), llm.CallError),
  continue: fn(c, List(ToolResult)) -> Result(Reply(c), llm.CallError),
) -> Provider(c) {
  Provider(start, continue)
}

pub fn start(
  provider: Provider(c),
  request: llm.Request,
  tools: List(ToolDeclaration),
) -> Result(Reply(c), llm.CallError) {
  provider.start(request, tools)
}

pub fn continue(
  provider: Provider(c),
  continuation: c,
  results: List(ToolResult),
) -> Result(Reply(c), llm.CallError) {
  provider.continue(continuation, results)
}

pub fn result_id(result: ToolResult) -> CallId {
  case result {
    ToolSucceeded(id, _) -> id
    ToolFailed(id, _) -> id
  }
}

fn validate_unique_calls(
  calls: List(ToolCall),
  seen: List(CallId),
) -> Result(Nil, CallBatchError) {
  case calls {
    [] -> Ok(Nil)
    [call, ..rest] ->
      case contains(seen, call.id) {
        True -> Error(DuplicateCallId(call.id))
        False -> validate_unique_calls(rest, [call.id, ..seen])
      }
  }
}

fn validate_result_ids(
  expected_calls: List(ToolCall),
  supplied_ids: List(CallId),
  seen: List(CallId),
) -> Result(Nil, ResultSetError) {
  case supplied_ids {
    [] -> require_all_results(expected_calls, seen)
    [id, ..rest] ->
      case contains_call_id(expected_calls, id), contains(seen, id) {
        False, _ -> Error(UnknownToolResult(id))
        True, True -> Error(DuplicateToolResult(id))
        True, False -> validate_result_ids(expected_calls, rest, [id, ..seen])
      }
  }
}

fn require_all_results(
  expected_calls: List(ToolCall),
  supplied_ids: List(CallId),
) -> Result(Nil, ResultSetError) {
  case expected_calls {
    [] -> Ok(Nil)
    [call, ..rest] ->
      case contains(supplied_ids, call.id) {
        True -> require_all_results(rest, supplied_ids)
        False -> Error(MissingToolResult(call.id))
      }
  }
}

fn contains_call_id(calls: List(ToolCall), wanted: CallId) -> Bool {
  case calls {
    [] -> False
    [call, ..rest] -> call.id == wanted || contains_call_id(rest, wanted)
  }
}

fn contains(items: List(CallId), wanted: CallId) -> Bool {
  case items {
    [] -> False
    [head, ..rest] -> head == wanted || contains(rest, wanted)
  }
}

fn map_results(items: List(a), f: fn(a) -> b) -> List(b) {
  case items {
    [] -> []
    [head, ..rest] -> [f(head), ..map_results(rest, f)]
  }
}
