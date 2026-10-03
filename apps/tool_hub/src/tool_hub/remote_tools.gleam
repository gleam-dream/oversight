//// Glue: Relay MCP tools mounted as fabric agent tools.
////
//// Typed path: a Relay `Definition` already owns the name, description and
//// codecs, so the fabric definition is derived from it, and the handler calls
//// the remote tool with the same definition. Dynamic path: a declaration
//// listed at runtime carries its input schema as a Blueprint `Value`, which
//// `input_contract` loads and `contract.value_codec` validates against.

import fabric/tool as fabric_tool
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/contract
import relay/client
import relay/content
import relay/tool as relay_tool

/// Why a remote MCP call did not produce its output.
pub type RemoteFailure {
  /// The remote tool ran and answered `isError: true` with this text.
  RemoteToolError(message: String)
  /// The remote tool asked for client input, which this agent cannot give.
  InputNotSupported
  /// The call failed; the error says whether it may have reached the peer.
  CallFailed(client.Error)
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

/// The peer under the run's correlation, so the call's Relay and HTTP Gun
/// events join the question's.
fn inbound(
  peer: Peer(context),
  context: context,
  call: fabric_tool.Call,
) -> client.Client {
  client.with_correlation(peer(context), call.correlation)
}

// --- typed path --------------------------------------------------------------

/// The fabric definition for a Relay definition. One way only: fabric's
/// definition accessors are `@internal`, so a fabric tool cannot be turned
/// into a Relay definition.
pub fn fabric_definition(
  definition: relay_tool.Definition(input, output),
) -> fabric_tool.Definition(input, output) {
  // Every definition this app mounts is structured.
  let assert option.Some(output) = relay_tool.output_codec(definition)
  fabric_tool.define(
    relay_tool.name(definition),
    option.unwrap(relay_tool.declaration(definition).description, ""),
    relay_tool.input_codec(definition),
    output,
  )
}

/// A fabric tool that calls the Relay tool `definition` on the peer.
pub fn mount(
  definition: relay_tool.Definition(input, output),
  peer: Peer(context),
) -> fabric_tool.Tool(context) {
  let effect = effect_of(relay_tool.declaration(definition))
  fabric_tool.bind(
    fabric_definition(definition),
    fn(context, call, input) {
      client.call(inbound(peer, context, call), definition, input) |> outcome
    },
    classify(effect, _),
  )
}

// --- dynamic path ------------------------------------------------------------

pub type DiscoveryError {
  ListingFailed(client.Error)
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
  declaration: relay_tool.Declaration,
  peer: Peer(context),
) -> Result(fabric_tool.Tool(context), DiscoveryError) {
  use remote <- result.map(
    relay_tool.input_contract(declaration)
    |> result.map_error(fn(error) {
      UnsupportedSchema(
        declaration.name,
        contract.describe_document_error(error),
      )
    }),
  )
  let definition =
    fabric_tool.define(
      declaration.name,
      option.unwrap(declaration.description, ""),
      contract.value_codec(remote),
      // The output is forwarded as the peer sent it.
      codec.value(),
    )
  fabric_tool.bind(
    definition,
    fn(context, call, arguments) {
      client.call_discovered(
        inbound(peer, context, call),
        declaration,
        arguments,
      )
      |> outcome
    },
    classify(effect_of(declaration), _),
  )
}

// --- outcome mapping -----------------------------------------------------------

fn outcome(
  result: Result(client.ToolResult(output), client.Error),
) -> Result(output, RemoteFailure) {
  case result {
    Ok(client.Succeeded(output, _content)) -> Ok(output)
    Ok(client.ToolFailed(blocks, _structured)) ->
      Error(RemoteToolError(text_of(blocks)))
    Ok(client.InputRequired(..)) -> Error(InputNotSupported)
    Error(error) -> Error(CallFailed(error))
  }
}

fn effect_of(declaration: relay_tool.Declaration) -> Effect {
  case declaration.annotations.read_only_hint {
    option.Some(True) -> ReadOnly
    _ -> MayChange
  }
}

/// MCP failures in fabric's vocabulary. A definite remote error, and a call
/// that never reached the peer, are shown to the model. A call that may have
/// reached the peer is uncertain for a tool that may change state: the run
/// waits for a person instead of letting the model retry it.
pub fn classify(effect: Effect, failure: RemoteFailure) -> fabric_tool.Failure {
  case failure {
    RemoteToolError(message) -> fabric_tool.Explain(message)
    InputNotSupported ->
      fabric_tool.Explain("the tool needs input this assistant cannot give")
    CallFailed(error) ->
      case client.evidence(error), effect {
        client.MaybeSent, MayChange ->
          fabric_tool.Uncertain("call lost: " <> describe(error))
        _, _ ->
          case client.kind(error) {
            client.Unreachable | client.Timeout ->
              fabric_tool.Explain(
                "the inventory is unavailable: " <> describe(error),
              )
            _ ->
              fabric_tool.Explain(
                "the inventory call failed: " <> describe(error),
              )
          }
      }
  }
}

/// The error's description and its stable name, such as
/// `the MCP request timed out (timed_out.maybe_sent)`.
pub fn describe(error: client.Error) -> String {
  client.describe_error(error) <> " (" <> client.name(error) <> ")"
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
