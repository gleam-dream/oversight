// THROWAWAY: Can one configured provider own schema admission and structured continuations?
import lab/blueprint
import lab/blueprint_runtime as runtime
import lab/llm
import lab/llm_catalog
import lab/llm_turn
import lab/value.{type Value}

pub opaque type ModelId {
  ModelId(String)
}

pub type ProviderConfigurationError {
  EmptyModelIdentifier
}

pub fn model_id(raw: String) -> Result(ModelId, ProviderConfigurationError) {
  case raw {
    "" -> Error(EmptyModelIdentifier)
    _ -> Ok(ModelId(raw))
  }
}

// Provider configuration closes over its model-specific native options,
// full-schema policy and both transport callbacks.
pub opaque type Provider(continuation, reason) {
  Provider(
    model: ModelId,
    schema_policy: fn(SchemaLocation, blueprint.Schema) -> List(reason),
    start: fn(llm.Request, blueprint.Schema, List(llm_turn.ToolDeclaration)) ->
      Result(Reply(continuation), llm.CallError),
    resume: fn(continuation, List(llm_turn.ToolResult)) ->
      Result(Reply(continuation), llm.CallError),
  )
}

pub fn configured_provider(
  model: ModelId,
  schema_policy: fn(SchemaLocation, blueprint.Schema) -> List(reason),
  start: fn(llm.Request, blueprint.Schema, List(llm_turn.ToolDeclaration)) ->
    Result(Reply(c), llm.CallError),
  resume: fn(c, List(llm_turn.ToolResult)) -> Result(Reply(c), llm.CallError),
) -> Provider(c, reason) {
  Provider(model, schema_policy, start, resume)
}

pub fn configured_model(provider: Provider(c, r)) -> String {
  let ModelId(name) = provider.model
  name
}

pub type Reply(continuation) =
  llm_turn.Reply(continuation)

pub type SchemaLocation {
  StructuredOutput
  ToolInput(llm_turn.ToolName)
}

pub type SchemaRejection(reason) {
  SchemaRejection(location: SchemaLocation, reason: reason)
}

pub opaque type PreparedTurn(output, continuation, reason) {
  PreparedTurn(
    provider: Provider(continuation, reason),
    request: llm.Request,
    output_codec: blueprint.Codec(output),
    output_contract: runtime.RuntimeContract,
    tools: List(AdmittedTool),
  )
}

type AdmittedTool {
  AdmittedTool(declaration: llm_turn.ToolDeclaration, schema: blueprint.Schema)
}

pub type PrepareError(reason) {
  NonPositiveOutputLimit(Int)
  OutputSchemaUnavailable
  InvalidOutputSchema(runtime.ContractError)
  InvalidToolSchema(llm_turn.ToolName, runtime.ContractError)
  UnsupportedSchemas(List(SchemaRejection(reason)))
}

pub fn prepare(
  provider: Provider(c, reason),
  request: llm.Request,
  catalog: llm_catalog.Catalog,
  output: blueprint.Codec(o),
) -> Result(PreparedTurn(o, c, reason), PrepareError(reason)) {
  case request {
    llm.Request(_, max_output_tokens) if max_output_tokens <= 0 ->
      Error(NonPositiveOutputLimit(max_output_tokens))
    llm.Request(_, _) -> {
      use output_contract <- result_try(case runtime.from_codec(output) {
        Ok(contract) -> Ok(contract)
        Error(runtime.UnknownSchema) -> Error(OutputSchemaUnavailable)
        Error(error) -> Error(InvalidOutputSchema(error))
      })
      use tools <- result_try(normalize_tools(llm_catalog.entries(catalog)))
      let output_schema = runtime.schema(output_contract)
      let rejections =
        append_rejections(
          located_rejections(
            StructuredOutput,
            provider.schema_policy(StructuredOutput, output_schema),
          ),
          collect_tool_rejections(provider.schema_policy, tools),
        )
      case rejections {
        [] ->
          Ok(PreparedTurn(provider, request, output, output_contract, tools))
        _ -> Error(UnsupportedSchemas(rejections))
      }
    }
  }
}

pub opaque type PendingTurn(output, continuation, reason) {
  PendingTurn(
    prepared: PreparedTurn(output, continuation, reason),
    continuation: continuation,
    calls: List(llm_turn.ToolCall),
  )
}

pub type StartedTurn(output, continuation, reason) {
  Finished(output)
  NeedsTools(PendingTurn(output, continuation, reason))
}

pub type TurnError {
  RemoteCallFailed(llm.CallError)
  EmptyToolBatch
  DuplicateToolCallId(llm_turn.CallId)
  UnknownToolCallName(llm_turn.ToolName)
  UnknownToolResult(llm_turn.CallId)
  DuplicateToolResult(llm_turn.CallId)
  MissingToolResult(llm_turn.CallId)
  FinalValueOutsideSchema(runtime.ValidationError)
  FinalValueRejectedByCodec(blueprint.DecodeError)
}

pub fn start(
  prepared: PreparedTurn(o, c, reason),
) -> Result(StartedTurn(o, c, reason), TurnError) {
  let output_schema = runtime.schema(prepared.output_contract)
  case
    prepared.provider.start(
      prepared.request,
      output_schema,
      tool_declarations(prepared.tools),
    )
  {
    Error(error) -> Error(RemoteCallFailed(error))
    Ok(reply) -> accept(prepared, reply)
  }
}

// Result correlation is set-based; after validation, the original caller order
// is passed to the retained continuation callback.
pub fn resume(
  pending: PendingTurn(o, c, reason),
  results: List(llm_turn.ToolResult),
) -> Result(StartedTurn(o, c, reason), TurnError) {
  case llm_turn.validate_results(pending.calls, results) {
    Error(llm_turn.UnknownToolResult(id)) -> Error(UnknownToolResult(id))
    Error(llm_turn.DuplicateToolResult(id)) -> Error(DuplicateToolResult(id))
    Error(llm_turn.MissingToolResult(id)) -> Error(MissingToolResult(id))
    Ok(Nil) ->
      case pending.prepared.provider.resume(pending.continuation, results) {
        Error(error) -> Error(RemoteCallFailed(error))
        Ok(reply) -> accept(pending.prepared, reply)
      }
  }
}

pub fn requested_calls(
  pending: PendingTurn(o, c, r),
) -> List(llm_turn.ToolCall) {
  pending.calls
}

fn accept(
  prepared: PreparedTurn(o, c, r),
  reply: Reply(c),
) -> Result(StartedTurn(o, c, r), TurnError) {
  case reply {
    llm_turn.Final(raw) -> decode_final(prepared, raw)
    llm_turn.RequestsTools(_, []) -> Error(EmptyToolBatch)
    llm_turn.RequestsTools(continuation, calls) ->
      case llm_turn.validate_calls(calls) {
        Error(llm_turn.EmptyToolBatch) -> Error(EmptyToolBatch)
        Error(llm_turn.DuplicateCallId(id)) -> Error(DuplicateToolCallId(id))
        Ok(Nil) ->
          case validate_admitted_names(calls, prepared.tools) {
            Error(name) -> Error(UnknownToolCallName(name))
            Ok(Nil) ->
              Ok(NeedsTools(PendingTurn(prepared, continuation, calls)))
          }
      }
  }
}

fn decode_final(
  prepared: PreparedTurn(o, c, r),
  raw: Value,
) -> Result(StartedTurn(o, c, r), TurnError) {
  case runtime.validate(prepared.output_contract, raw) {
    Error(error) -> Error(FinalValueOutsideSchema(error))
    Ok(validated) ->
      case blueprint.decode(prepared.output_codec, runtime.encoded(validated)) {
        Error(error) -> Error(FinalValueRejectedByCodec(error))
        Ok(output) -> Ok(Finished(output))
      }
  }
}

fn validate_admitted_names(
  calls: List(llm_turn.ToolCall),
  admitted: List(AdmittedTool),
) -> Result(Nil, llm_turn.ToolName) {
  case calls {
    [] -> Ok(Nil)
    [call, ..rest] ->
      case contains_admitted_name(admitted, call.name) {
        False -> Error(call.name)
        True -> validate_admitted_names(rest, admitted)
      }
  }
}

fn contains_admitted_name(
  admitted: List(AdmittedTool),
  name: llm_turn.ToolName,
) -> Bool {
  case admitted {
    [] -> False
    [AdmittedTool(declaration, _), ..rest] ->
      declaration.name == name || contains_admitted_name(rest, name)
  }
}

fn normalize_tools(
  entries: List(llm_catalog.Entry),
) -> Result(List(AdmittedTool), PrepareError(reason)) {
  case entries {
    [] -> Ok([])
    [entry, ..rest] ->
      case runtime.from_schema(entry.input_schema) {
        Error(error) -> Error(InvalidToolSchema(entry.name, error))
        Ok(contract) ->
          case normalize_tools(rest) {
            Error(error) -> Error(error)
            Ok(normalized_rest) -> {
              let normalized_schema = runtime.schema(contract)
              let declaration =
                llm_turn.ToolDeclaration(
                  entry.name,
                  entry.description,
                  blueprint.schema_value(normalized_schema),
                )
              Ok([
                AdmittedTool(declaration, normalized_schema),
                ..normalized_rest
              ])
            }
          }
      }
  }
}

fn tool_declarations(
  tools: List(AdmittedTool),
) -> List(llm_turn.ToolDeclaration) {
  case tools {
    [] -> []
    [AdmittedTool(declaration, _), ..rest] -> [
      declaration,
      ..tool_declarations(rest)
    ]
  }
}

fn collect_tool_rejections(
  policy: fn(SchemaLocation, blueprint.Schema) -> List(reason),
  tools: List(AdmittedTool),
) -> List(SchemaRejection(reason)) {
  case tools {
    [] -> []
    [AdmittedTool(declaration, schema), ..rest] ->
      append_rejections(
        located_rejections(
          ToolInput(declaration.name),
          policy(ToolInput(declaration.name), schema),
        ),
        collect_tool_rejections(policy, rest),
      )
  }
}

fn located_rejections(
  location: SchemaLocation,
  reasons: List(reason),
) -> List(SchemaRejection(reason)) {
  case reasons {
    [] -> []
    [reason, ..rest] -> [
      SchemaRejection(location, reason),
      ..located_rejections(location, rest)
    ]
  }
}

fn append_rejections(
  left: List(SchemaRejection(a)),
  right: List(SchemaRejection(a)),
) -> List(SchemaRejection(a)) {
  case left {
    [] -> right
    [head, ..rest] -> [head, ..append_rejections(rest, right)]
  }
}

fn result_try(
  result: Result(a, PrepareError(reason)),
  next: fn(a) -> Result(b, PrepareError(reason)),
) -> Result(b, PrepareError(reason)) {
  case result {
    Error(error) -> Error(error)
    Ok(value) -> next(value)
  }
}
