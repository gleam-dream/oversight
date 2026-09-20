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
