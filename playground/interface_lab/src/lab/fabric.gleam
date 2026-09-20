// THROWAWAY: Can bounded agents and typed tools compose without owning a graph?
import lab/blueprint.{type Codec, type DecodeError, type EncodeError}
import lab/value.{type Value}

pub type ToolError {
  InputRejected(DecodeError)
  OutputRejected(EncodeError)
  ErrorRejected(EncodeError)
  ActionFailed(Value)
}

pub opaque type Tool {
  Tool(name: String, invoke: fn(Value) -> Result(Value, ToolError))
}

pub fn tool(
  name: String,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  handler: fn(i) -> Result(o, e),
) -> Tool {
  Tool(name, fn(raw) {
    case blueprint.decode(input, raw) {
      Error(e) -> Error(InputRejected(e))
      Ok(i) ->
        case handler(i) {
          Ok(o) ->
            case blueprint.encode(output, o) {
              Ok(v) -> Ok(v)
              Error(e) -> Error(OutputRejected(e))
            }
          Error(e) ->
            case blueprint.encode(error, e) {
              Ok(v) -> Error(ActionFailed(v))
              Error(e) -> Error(ErrorRejected(e))
            }
        }
    }
  })
}

pub fn invoke(tool: Tool, input: Value) -> Result(Value, ToolError) {
  tool.invoke(input)
}

pub opaque type Agent(i, o, e) {
  Agent(call: fn(i) -> Result(o, e), tools: List(Tool))
}

// Caller supplies a bounded invocation; no loop implementation is claimed here.
pub fn bounded(
  call: fn(i) -> Result(o, e),
  tools: List(Tool),
) -> Agent(i, o, e) {
  Agent(call, tools)
}

pub fn invoke_agent(agent: Agent(i, o, e), input: i) -> Result(o, e) {
  agent.call(input)
}

// A registry can be built once while invocation supplies request-owned context.
// Context remains adapter-specific and is not part of the encoded business input.
pub opaque type ContextTool(context) {
  ContextTool(bind: fn(context) -> Tool)
}

pub fn context_tool(
  name: String,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  handler: fn(context, i) -> Result(o, e),
) -> ContextTool(context) {
  ContextTool(fn(context) {
    tool(name, input, output, error, fn(input) { handler(context, input) })
  })
}

pub fn bind_context(tool: ContextTool(context), context: context) -> Tool {
  tool.bind(context)
}

pub fn invoke_context(
  tool: ContextTool(context),
  context: context,
  input: Value,
) -> Result(Value, ToolError) {
  invoke(bind_context(tool, context), input)
}
