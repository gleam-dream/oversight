// THROWAWAY: Can heterogeneous MCP tool contracts preserve typed registration?
import lab/blueprint.{type Codec, type DecodeError, type EncodeError}
import lab/value.{type Value}

pub type InvocationError {
  InvalidInput(DecodeError)
  InvalidOutput(EncodeError)
  InvalidError(EncodeError)
  ApplicationFailure(Value)
}

pub opaque type Tool {
  Tool(name: String, invoke: fn(Value) -> Result(Value, InvocationError))
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
      Error(e) -> Error(InvalidInput(e))
      Ok(i) ->
        case handler(i) {
          Ok(o) ->
            case blueprint.encode(output, o) {
              Ok(v) -> Ok(v)
              Error(e) -> Error(InvalidOutput(e))
            }
          Error(e) ->
            case blueprint.encode(error, e) {
              Ok(v) -> Error(ApplicationFailure(v))
              Error(e) -> Error(InvalidError(e))
            }
        }
    }
  })
}

pub fn invoke(tool: Tool, input: Value) -> Result(Value, InvocationError) {
  tool.invoke(input)
}

// Registration carries the handler. No transport, authorization, or discovery.
pub fn name(tool: Tool) -> String {
  tool.name
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
) -> Result(Value, InvocationError) {
  invoke(bind_context(tool, context), input)
}
