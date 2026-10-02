//// Glue: Relay MCP tools mounted as fabric agent tools.
////
//// Typed path: a Relay `Definition` already owns the name, description and
//// codecs, so the fabric definition is derived from it, and the handler calls
//// the remote tool with the same definition. Dynamic path: a declaration
//// listed at runtime has only a JSON Schema, which becomes a Blueprint
//// contract and a `Codec(Value)` that validates against it.

import fabric/tool as fabric_tool
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/parser
import json/blueprint/runtime
import json/blueprint/value.{type Value}
import relay/client
import relay/content
import relay/tool as relay_tool

/// Why a remote MCP call did not produce its output.
pub type RemoteFailure {
  /// The remote tool ran and answered `isError: true` with this text.
  RemoteToolError(message: String)
  /// The peer could not be reached, or its reply was lost. Relay does not
  /// say whether the request was sent.
  RemoteUnreachable(client.TransportError)
  /// The peer answered with something this client could not read.
  RemoteProtocol(reason: String)
  /// The arguments could not be encoded (a local defect).
  NotEncodable
  /// The remote tool asked for client input, which this agent cannot give.
  InputNotSupported
}

/// Whether a tool's effect can safely be treated as absent on failure.
pub type Effect {
  /// The peer says the tool changes nothing (`readOnlyHint: true`).
  ReadOnly
  /// The tool may change remote state.
  MayChange
}

/// The peer the tools call, taken from the agent's context per call.
pub type Peer(context) =
  fn(context) -> client.Client

// --- typed path --------------------------------------------------------------

/// The fabric definition for a Relay definition. One way only: fabric's
/// definition accessors are `@internal`, so a fabric tool cannot be turned
/// into a Relay definition.
pub fn fabric_definition(
  definition: relay_tool.Definition(input, output),
) -> fabric_tool.Definition(input, output) {
  let metadata = relay_tool.definition_metadata(definition)
  fabric_tool.define(
    relay_tool.definition_name(definition) |> relay_tool.tool_name_to_string,
    option.unwrap(metadata.description, ""),
    relay_tool.definition_input_codec(definition),
    relay_tool.definition_output_codec(definition),
  )
}

/// A fabric tool that calls the Relay tool `definition` on the peer.
pub fn mount(
  definition: relay_tool.Definition(input, output),
  peer: Peer(context),
) -> fabric_tool.Tool(context) {
  let effect = effect_of(relay_tool.definition_metadata(definition).annotations)
  fabric_tool.bind(
    fabric_definition(definition),
    fn(context, input) {
      client.call_definition(peer(context), definition, input) |> outcome
    },
    classify(effect, _),
  )
}

// --- dynamic path ------------------------------------------------------------

pub type DiscoveryError {
  ListingFailed(reason: String)
  /// Blueprint cannot admit the advertised input schema.
  UnsupportedSchema(tool: String, reason: String)
}

/// Lists the peer's tools now and mounts each one without a native type.
/// Arguments are validated against the advertised schema before the call.
pub fn discover(
  connected: client.Client,
  peer: Peer(context),
) -> Result(List(fabric_tool.Tool(context)), DiscoveryError) {
  use declarations <- result.try(
    client.list_tools(connected) |> result.map_error(ListingFailed),
  )
  list.try_map(declarations, mount_discovered(_, peer))
}

pub fn mount_discovered(
  declaration: client.ToolDeclaration,
  peer: Peer(context),
) -> Result(fabric_tool.Tool(context), DiscoveryError) {
  use contract <- result.map(
    parser.parse_schema_document_from_string(
      parser.default_limits(),
      json.to_string(declaration.input_schema),
    )
    |> result.map_error(fn(error) {
      UnsupportedSchema(declaration.name, string.inspect(error))
    }),
  )
  let definition =
    fabric_tool.define(
      declaration.name,
      option.unwrap(declaration.description, ""),
      contract_codec(contract),
      // The output is forwarded as the peer sent it.
      codec.new(Ok, Ok),
    )
  fabric_tool.bind(
    definition,
    fn(context, arguments) {
      client.call_discovered(peer(context), declaration, arguments) |> outcome
    },
    classify(effect_of(declaration.annotations), _),
  )
}

/// A `Codec(Value)` whose schema is the contract's and whose decoder
/// validates against it. Blueprint has no constructor for this, and its
/// validation errors use a vocabulary parallel to its decode errors.
fn contract_codec(contract: runtime.RuntimeContract) -> codec.Codec(Value) {
  codec.from_parts(
    Ok,
    fn(value) {
      runtime.validate(contract, value)
      |> result.map(runtime.encoded)
      |> result.map_error(decode_error)
    },
    runtime.schema(contract),
  )
}

fn decode_error(error: runtime.ValidationError) -> codec.DecodeError {
  let runtime.ValidationError(path:, reason:) = error
  list.fold_right(
    path,
    codec.CannotDecode(decode_reason(reason)),
    fn(inner, at) {
      case at {
        runtime.Property(name) -> codec.DecodeAtField(name, inner)
        runtime.Index(index) -> codec.DecodeAtIndex(index, inner)
        runtime.TaggedBranch(tag) -> codec.DecodeAtField(tag, inner)
      }
    },
  )
}

fn decode_reason(reason: runtime.ValidationReason) -> codec.DecodeReason {
  case reason {
    runtime.ExpectedString -> codec.DecodeExpectedString
    runtime.UnknownEnumLabel(label) -> codec.DecodeUnknownEnumLabel(label)
    runtime.ExpectedInteger -> codec.DecodeExpectedInt
    runtime.ExpectedNumber -> codec.DecodeExpectedNumber
    runtime.ExpectedBoolean -> codec.DecodeExpectedBool
    runtime.ExpectedArray -> codec.DecodeExpectedArray
    runtime.ExpectedObject -> codec.DecodeExpectedObject
    runtime.MissingProperty(name) -> codec.DecodeMissingProperty(name)
    runtime.UnknownProperty(name) -> codec.DecodeUnknownProperty(name)
    runtime.DuplicateProperty(name) -> codec.DecodeDuplicateProperty(name)
    runtime.WrongTupleLength(expected, actual) ->
      codec.DecodeWrongTupleLength(expected, actual)
    runtime.IntegerOutsideRange(minimum, maximum, actual) ->
      codec.DecodeIntegerOutsideRange(minimum, maximum, actual)
    runtime.NumberOutsideRange(minimum, maximum, actual) ->
      codec.DecodeNumberOutsideRange(minimum, maximum, actual)
    runtime.MissingTag -> codec.DecodeMissingTag
    runtime.NonStringTag -> codec.DecodeExpectedTaggedObject
    runtime.UnknownTag(tag) -> codec.DecodeUnknownTag(tag)
  }
}

// --- outcome mapping -----------------------------------------------------------

fn outcome(
  result: client.ToolCallOutcome(output),
) -> Result(output, RemoteFailure) {
  case result {
    client.StructuredSuccess(output, _content) -> Ok(output)
    client.ToolFailure(blocks) -> Error(RemoteToolError(text_of(blocks)))
    client.TransportFailure(reason) -> Error(RemoteUnreachable(reason))
    client.ProtocolFailure(reason) -> Error(RemoteProtocol(reason))
    client.ContentOnlySuccess(_) ->
      Error(RemoteProtocol("structured content missing"))
    client.InputEncodingFailure -> Error(NotEncodable)
    client.InputRequired(..) | client.InvalidInputResponses ->
      Error(InputNotSupported)
  }
}

fn effect_of(annotations: Option(relay_tool.ToolAnnotations)) -> Effect {
  case annotations {
    Some(relay_tool.ToolAnnotations(read_only_hint: Some(True), ..)) -> ReadOnly
    _ -> MayChange
  }
}

/// MCP failures in fabric's vocabulary. A definite remote error is shown to
/// the model. A lost call to a tool that may change state is uncertain: the
/// run waits for a person instead of letting the model retry it.
pub fn classify(effect: Effect, failure: RemoteFailure) -> fabric_tool.Failure {
  case failure, effect {
    RemoteToolError(message), _ -> fabric_tool.Explain(message)
    NotEncodable, _ -> fabric_tool.Explain("the arguments could not be sent")
    InputNotSupported, _ ->
      fabric_tool.Explain("the tool needs input this assistant cannot give")
    RemoteUnreachable(reason), ReadOnly ->
      fabric_tool.Explain("the inventory is unavailable: " <> describe(reason))
    RemoteUnreachable(reason), MayChange ->
      fabric_tool.Uncertain("call lost: " <> describe(reason))
    RemoteProtocol(reason), ReadOnly ->
      fabric_tool.Explain("unreadable reply: " <> reason)
    RemoteProtocol(reason), MayChange ->
      fabric_tool.Uncertain("unreadable reply: " <> reason)
  }
}

pub fn describe(reason: client.TransportError) -> String {
  case reason {
    client.ConnectionClosed -> "connection closed"
    client.RequestCancelled -> "request cancelled"
    client.RequestTimedOut -> "request timed out"
    client.ResponseLimitExceeded -> "response too large"
    client.TransportFault(detail) -> "transport fault (" <> detail <> ")"
  }
}

fn text_of(blocks: List(content.ContentBlock)) -> String {
  blocks
  |> list.filter_map(fn(block) {
    case block {
      content.TextContent(text, ..) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("\n")
}
