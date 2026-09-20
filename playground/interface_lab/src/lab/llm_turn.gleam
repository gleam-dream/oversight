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
