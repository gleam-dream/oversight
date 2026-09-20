// THROWAWAY: Can a one-call model interface be consumed independently of Fabric?
import lab/blueprint.{type Codec, type DecodeError}
import lab/value.{type Value}

pub type Message {
  User(String)
  Assistant(String)
}

pub type Request {
  Request(messages: List(Message), max_output_tokens: Int)
}

pub type CallError {
  TransportUnavailable
  RateLimited
  Cancelled
  DeadlineExceeded
  Refused(String)
  UnsupportedCapability
  InvalidStructuredOutput(DecodeError)
}

pub opaque type Provider {
  Provider(call: fn(Request) -> Result(Value, CallError))
}

pub fn provider(call: fn(Request) -> Result(Value, CallError)) -> Provider {
  Provider(call)
}

pub fn structured(
  provider: Provider,
  request: Request,
  output: Codec(o),
) -> Result(o, CallError) {
  case provider.call(request) {
    Error(e) -> Error(e)
    Ok(raw) ->
      case blueprint.decode(output, raw) {
        Ok(o) -> Ok(o)
        Error(e) -> Error(InvalidStructuredOutput(e))
      }
  }
}
