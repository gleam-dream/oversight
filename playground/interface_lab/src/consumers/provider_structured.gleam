// THROWAWAY: Can schema policy, requested schemas, and typed continuations stay provider-bound?
import consumers/structured_adapter_alpha as alpha
import consumers/structured_adapter_beta as beta
import lab/blueprint
import lab/blueprint_requirements as requirements
import lab/blueprint_runtime as runtime
import lab/llm
import lab/llm_catalog
import lab/llm_structured as structured
import lab/llm_turn
import lab/value

pub type Outcome {
  Declined
  Placed
}

pub fn probe() -> Nil {
  let assert Ok(output) = outcome_codec()
  let assert Ok(tools) = tool_catalog()
  let assert Ok(alpha_provider) =
    alpha.select("alpha-json-compact", alpha_start, alpha_resume)
  let assert Error(structured.EmptyModelIdentifier) = structured.model_id("")
  let assert "alpha-json-compact" = structured.configured_model(alpha_provider)
  let assert Ok(prepared) =
    structured.prepare(alpha_provider, request(), tools, output)
  let assert Ok(structured.NeedsTools(first_pending)) =
    structured.start(prepared)
  let first_result =
    llm_turn.ToolSucceeded(
      llm_turn.CallId("lookup-first"),
      value.Text("first page"),
    )
  let assert Ok(structured.NeedsTools(second_pending)) =
    structured.resume(first_pending, [first_result])
  let second_result =
    llm_turn.ToolSucceeded(
      llm_turn.CallId("lookup-second"),
      value.Text("second page"),
    )
  let assert Ok(structured.Finished(Placed)) =
    structured.resume(second_pending, [second_result])

  // Alpha and beta share the same continuation type (llm.Request). The second
  // provider is passed to this probe helper but the opaque pending turn retains
  // and invokes only alpha's continuation callback.
  let assert Ok(beta_provider) =
    beta.select("beta-object-regional", beta_start, beta_resume_panics)
  let assert Ok(beta_prepared) =
    structured.prepare(
      beta_provider,
      llm.Request([llm.User("beta text")], 32),
      tools,
      blueprint.text(),
    )
  let assert Ok(structured.Finished("beta-result")) =
    structured.start(beta_prepared)
  let assert Ok(Nil) =
    origin_retains_alpha(first_pending, beta_provider, first_result)

  // Missing and duplicate result IDs fail before the retained callback.
  let assert Ok(panic_resume_provider) =
    alpha.select(
      "alpha-json-compact",
      alpha_start_one_call,
      alpha_resume_panics,
    )
  let assert Ok(one_call_prepared) =
    structured.prepare(panic_resume_provider, request(), tools, output)
  let assert Ok(structured.NeedsTools(one_call)) =
    structured.start(one_call_prepared)
  let assert Error(structured.MissingToolResult(llm_turn.CallId("lookup-first"))) =
    structured.resume(one_call, [])
  let duplicate_result =
    llm_turn.ToolSucceeded(
      llm_turn.CallId("lookup-first"),
      value.Text("same call twice"),
    )
  let assert Error(structured.DuplicateToolResult(llm_turn.CallId(
    "lookup-first",
  ))) = structured.resume(one_call, [duplicate_result, duplicate_result])

  let assert Ok(sentinel_model) = structured.model_id("schema-order-sentinel")
  let invalid_final_provider =
    structured.configured_provider(
      sentinel_model,
      fn(_, _) { [] },
      fn(_request, _output_schema, _tools) {
        Ok(
          llm_turn.RequestsTools(alpha_continuation("sentinel"), [
            lookup_call("lookup-first"),
          ]),
        )
      },
      fn(_continuation, _results) {
        Ok(
          llm_turn.Final(
            value.Array([
              value.Text("valid-first"),
              value.Text("unknown-enum"),
            ]),
          ),
        )
      },
    )
  let assert Ok(panic_mapping_output) = panicking_output_pair_codec()
  let assert Ok(invalid_final_prepared) =
    structured.prepare(
      invalid_final_provider,
      request(),
      tools,
      panic_mapping_output,
    )
  let assert Ok(structured.NeedsTools(invalid_final_pending)) =
    structured.start(invalid_final_prepared)
  // The raw pair has a valid text in component zero and an invalid enum in
  // component one. Decoding the pair eagerly would invoke the first component
  // mapping before discovering the second error, so the panic proves schema
  // validation rejects the entire value before any native decoder runs.
  let assert Error(structured.FinalValueOutsideSchema(_)) =
    structured.resume(invalid_final_pending, [first_result])

  let assert Error(alpha.UnknownAlphaModel("missing-alpha-model")) =
    alpha.select("missing-alpha-model", panic_alpha_start, alpha_resume_panics)
  let assert Error(beta.UnknownBetaModel("missing-beta-model")) =
    beta.select("missing-beta-model", panic_beta_start, beta_resume_panics)

  // A valid but profile-unsupported enum is rejected at the nested schema path.
  let assert Ok(beta_provider_for_policy) =
    beta.select("beta-object-regional", panic_beta_start, beta_resume_panics)
  let nested_enum = blueprint.field("payload", output)
  let assert Error(structured.UnsupportedSchemas([
    structured.SchemaRejection(
      structured.StructuredOutput,
      beta.BetaStringEnumUnsupported(requirements.Requirement(
        [requirements.Property("payload")],
        requirements.StringEnumValues(["declined", "placed"]),
      )),
    ),
  ])) =
    structured.prepare(beta_provider_for_policy, request(), tools, nested_enum)

  let nested_enum_tool =
    llm_catalog.Entry(
      llm_turn.ToolName("mode"),
      "mode input",
      blueprint.FieldSchema(
        "payload",
        blueprint.StringEnumSchema([
          "declined",
          "placed",
        ]),
      ),
    )
  let assert Ok(enum_tool_catalog) = llm_catalog.catalog([nested_enum_tool])
  let assert Error(structured.UnsupportedSchemas([
    structured.SchemaRejection(
      structured.ToolInput(llm_turn.ToolName("mode")),
      beta.BetaStringEnumUnsupported(requirements.Requirement(
        [requirements.Property("payload")],
        requirements.StringEnumValues(["declined", "placed"]),
      )),
    ),
  ])) =
    structured.prepare(
      beta_provider_for_policy,
      request(),
      enum_tool_catalog,
      blueprint.text(),
    )

  let scalar_tool =
    llm_catalog.Entry(
      llm_turn.ToolName("scalar"),
      "scalar input",
      blueprint.IntSchema,
    )
  let assert Ok(scalar_tool_catalog) = llm_catalog.catalog([scalar_tool])
  let assert Error(structured.UnsupportedSchemas([
    structured.SchemaRejection(
      structured.ToolInput(llm_turn.ToolName("scalar")),
      beta.BetaToolRootMustBeObject,
    ),
  ])) =
    structured.prepare(
      beta_provider_for_policy,
      request(),
      scalar_tool_catalog,
      blueprint.text(),
    )

  // Unknown-schema output codecs and nonpositive request limits stop locally.
  let unknown_schema_codec =
    blueprint.new(fn(text) { Ok(value.Text(text)) }, fn(raw) {
      case raw {
        value.Text(text) -> Ok(text)
        _ -> Error(blueprint.CannotDecode("Expected text"))
      }
    })
  let assert Ok(no_schema_provider) =
    alpha.select("alpha-json-compact", panic_alpha_start, alpha_resume_panics)
  let assert Error(structured.OutputSchemaUnavailable) =
    structured.prepare(
      no_schema_provider,
      request(),
      tools,
      unknown_schema_codec,
    )
  let assert Error(structured.NonPositiveOutputLimit(0)) =
    structured.prepare(
      no_schema_provider,
      llm.Request([llm.User("bad limit")], 0),
      tools,
      output,
    )

  let invalid_tool =
    llm_catalog.Entry(
      llm_turn.ToolName("invalid"),
      "bad schema",
      blueprint.ObjectSchema([
        blueprint.PropertySchema("state", True, blueprint.StringEnumSchema([])),
      ]),
    )
  let assert Ok(invalid_tool_catalog) = llm_catalog.catalog([invalid_tool])
  let assert Error(structured.InvalidToolSchema(
    llm_turn.ToolName("invalid"),
    runtime.EmptyStringEnum,
  )) =
    structured.prepare(alpha_provider, request(), invalid_tool_catalog, output)

  let assert Error(structured.UnknownToolCallName(llm_turn.ToolName("hidden"))) =
    unknown_tool_name(tools, output)

  let assert Error(structured.RemoteCallFailed(llm.RateLimited)) =
    remote_failure(tools, output)
  let assert Error(structured.DuplicateToolCallId(llm_turn.CallId("same"))) =
    duplicate_provider_calls(tools, output)
  Nil
}

fn origin_retains_alpha(
  pending: structured.PendingTurn(
    Outcome,
    llm.Request,
    alpha.UnsupportedFeature,
  ),
  replacement: structured.Provider(llm.Request, beta.UnsupportedFeature),
  result: llm_turn.ToolResult,
) -> Result(Nil, structured.TurnError) {
  let _ = replacement
  case structured.resume(pending, [result]) {
    Ok(structured.NeedsTools(_)) -> Ok(Nil)
    Ok(structured.Finished(_)) -> Error(structured.EmptyToolBatch)
    Error(error) -> Error(error)
  }
}

fn unknown_tool_name(
  tools: llm_catalog.Catalog,
  output: blueprint.Codec(Outcome),
) -> Result(Nil, structured.TurnError) {
  let assert Ok(unlisted_provider) =
    alpha.select(
      "alpha-json-compact",
      alpha_start_unlisted,
      alpha_resume_panics,
    )
  let assert Ok(prepared) =
    structured.prepare(unlisted_provider, request(), tools, output)
  case structured.start(prepared) {
    Error(error) -> Error(error)
    Ok(structured.NeedsTools(_)) -> Error(structured.EmptyToolBatch)
    Ok(structured.Finished(_)) -> Error(structured.EmptyToolBatch)
  }
}

fn remote_failure(
  tools: llm_catalog.Catalog,
  output: blueprint.Codec(Outcome),
) -> Result(Nil, structured.TurnError) {
  let assert Ok(failing_provider) =
    alpha.select(
      "alpha-json-compact",
      alpha_start_remote_failure,
      alpha_resume_panics,
    )
  let assert Ok(prepared) =
    structured.prepare(failing_provider, request(), tools, output)
  case structured.start(prepared) {
    Error(error) -> Error(error)
    Ok(structured.NeedsTools(_)) -> Error(structured.EmptyToolBatch)
    Ok(structured.Finished(_)) -> Error(structured.EmptyToolBatch)
  }
}

fn duplicate_provider_calls(
  tools: llm_catalog.Catalog,
  output: blueprint.Codec(Outcome),
) -> Result(Nil, structured.TurnError) {
  let assert Ok(malformed_provider) =
    alpha.select(
      "alpha-json-compact",
      alpha_start_duplicate_calls,
      alpha_resume_panics,
    )
  let assert Ok(prepared) =
    structured.prepare(malformed_provider, request(), tools, output)
  case structured.start(prepared) {
    Error(error) -> Error(error)
    Ok(structured.NeedsTools(_)) -> Error(structured.EmptyToolBatch)
    Ok(structured.Finished(_)) -> Error(structured.EmptyToolBatch)
  }
}

fn alpha_start(
  config: alpha.NativeConfig,
  request: llm.Request,
  output_schema: blueprint.Schema,
  tools: List(llm_turn.ToolDeclaration),
) -> Result(structured.Reply(llm.Request), llm.CallError) {
  case config {
    alpha.NativeConfig(alpha.AlphaCompact, alpha.StrictJsonSchema, True) ->
      case
        request == request_value(),
        output_schema == expected_output_schema(),
        tool_declarations_match(tools)
      {
        True, True, True ->
          Ok(
            llm_turn.RequestsTools(alpha_continuation("alpha-first"), [
              lookup_call("lookup-first"),
            ]),
          )
        _, _, _ -> Error(llm.UnsupportedCapability)
      }
    _ -> Error(llm.UnsupportedCapability)
  }
}

fn alpha_start_one_call(
  config: alpha.NativeConfig,
  _request: llm.Request,
  _output_schema: blueprint.Schema,
  _tools: List(llm_turn.ToolDeclaration),
) -> Result(structured.Reply(llm.Request), llm.CallError) {
  case config {
    alpha.NativeConfig(alpha.AlphaCompact, alpha.StrictJsonSchema, True) ->
      Ok(
        llm_turn.RequestsTools(alpha_continuation("alpha-first"), [
          lookup_call("lookup-first"),
        ]),
      )
    _ -> Error(llm.UnsupportedCapability)
  }
}

fn alpha_start_unlisted(
  _config: alpha.NativeConfig,
  _request: llm.Request,
  _output_schema: blueprint.Schema,
  _tools: List(llm_turn.ToolDeclaration),
) -> Result(structured.Reply(llm.Request), llm.CallError) {
  Ok(
    llm_turn.RequestsTools(alpha_continuation("alpha-first"), [
      llm_turn.ToolCall(
        llm_turn.CallId("hidden-call"),
        llm_turn.ToolName("hidden"),
        value.Text("not advertised"),
      ),
    ]),
  )
}

fn alpha_start_remote_failure(
  _config: alpha.NativeConfig,
  _request: llm.Request,
  _output_schema: blueprint.Schema,
  _tools: List(llm_turn.ToolDeclaration),
) -> Result(llm_turn.Reply(llm.Request), llm.CallError) {
  Error(llm.RateLimited)
}

fn alpha_start_duplicate_calls(
  _config: alpha.NativeConfig,
  _request: llm.Request,
  _output_schema: blueprint.Schema,
  _tools: List(llm_turn.ToolDeclaration),
) -> Result(llm_turn.Reply(llm.Request), llm.CallError) {
  Ok(
    llm_turn.RequestsTools(alpha_continuation("alpha-first"), [
      lookup_call("same"),
      lookup_call("same"),
    ]),
  )
}

fn alpha_resume(
  _config: alpha.NativeConfig,
  continuation: llm.Request,
  results: List(llm_turn.ToolResult),
) -> Result(structured.Reply(llm.Request), llm.CallError) {
  case continuation.messages, results {
    [llm.Assistant("alpha-first")],
      [
        llm_turn.ToolSucceeded(
          llm_turn.CallId("lookup-first"),
          value.Text("first page"),
        ),
      ]
    ->
      Ok(
        llm_turn.RequestsTools(alpha_continuation("alpha-second"), [
          lookup_call("lookup-second"),
        ]),
      )
    [llm.Assistant("alpha-second")],
      [
        llm_turn.ToolSucceeded(
          llm_turn.CallId("lookup-second"),
          value.Text("second page"),
        ),
      ]
    -> Ok(llm_turn.Final(value.Text("placed")))
    _, _ -> Error(llm.UnsupportedCapability)
  }
}

fn alpha_resume_panics(
  _config: alpha.NativeConfig,
  _continuation: llm.Request,
  _results: List(llm_turn.ToolResult),
) -> Result(structured.Reply(llm.Request), llm.CallError) {
  panic as "result identity validation must precede the provider continuation"
}

fn panic_alpha_start(
  _config: alpha.NativeConfig,
  _request: llm.Request,
  _output_schema: blueprint.Schema,
  _tools: List(llm_turn.ToolDeclaration),
) -> Result(structured.Reply(llm.Request), llm.CallError) {
  panic as "invalid model/schema/request must fail before alpha transport"
}

fn beta_start(
  config: beta.NativeConfig,
  request: llm.Request,
  output_schema: blueprint.Schema,
  tools: List(llm_turn.ToolDeclaration),
) -> Result(structured.Reply(llm.Request), llm.CallError) {
  case config {
    beta.NativeConfig(beta.BetaRegional, beta.FiniteJsonSchema, False) ->
      case
        request == llm.Request([llm.User("beta text")], 32),
        output_schema == blueprint.TextSchema,
        tool_declarations_match(tools)
      {
        True, True, True -> Ok(llm_turn.Final(value.Text("beta-result")))
        _, _, _ -> Error(llm.UnsupportedCapability)
      }
    _ -> Error(llm.UnsupportedCapability)
  }
}

fn beta_resume_panics(
  _config: beta.NativeConfig,
  _continuation: llm.Request,
  _results: List(llm_turn.ToolResult),
) -> Result(structured.Reply(llm.Request), llm.CallError) {
  panic as "the beta continuation must not replace an alpha pending callback"
}

fn panic_beta_start(
  _config: beta.NativeConfig,
  _request: llm.Request,
  _output_schema: blueprint.Schema,
  _tools: List(llm_turn.ToolDeclaration),
) -> Result(structured.Reply(llm.Request), llm.CallError) {
  panic as "unsupported beta schema must fail before transport"
}

fn request() -> llm.Request {
  request_value()
}

fn request_value() -> llm.Request {
  llm.Request([llm.User("structured lookup")], 64)
}

fn alpha_continuation(phase: String) -> llm.Request {
  llm.Request([llm.Assistant(phase)], 64)
}

fn lookup_call(id: String) -> llm_turn.ToolCall {
  llm_turn.ToolCall(
    llm_turn.CallId(id),
    llm_turn.ToolName("lookup"),
    value.Object([#("query", value.Text("inventory"))]),
  )
}

fn outcome_codec() -> Result(blueprint.Codec(Outcome), blueprint.EnumError) {
  blueprint.string_enum([#("placed", Placed), #("declined", Declined)])
}

fn panicking_output_pair_codec() -> Result(
  blueprint.Codec(#(String, Bool)),
  blueprint.EnumError,
) {
  use outcome <- result_try(
    blueprint.string_enum([#("placed", True), #("declined", False)]),
  )
  let text =
    blueprint.imap(
      blueprint.text(),
      fn(_) { panic as "schema-invalid final reached the first native decoder" },
      fn(text) { text },
    )
  Ok(blueprint.pair(text, outcome))
}

fn tool_catalog() -> Result(llm_catalog.Catalog, llm_catalog.CatalogError) {
  let assert Ok(entry) =
    llm_catalog.entry_from_codec(
      llm_turn.ToolName("lookup"),
      "lookup query",
      blueprint.field("query", blueprint.text()),
    )
  llm_catalog.catalog([entry])
}

fn expected_output_schema() -> blueprint.Schema {
  blueprint.StringEnumSchema(["declined", "placed"])
}

fn tool_declarations_match(tools: List(llm_turn.ToolDeclaration)) -> Bool {
  case tools {
    [llm_turn.ToolDeclaration(name, description, schema)] ->
      name == llm_turn.ToolName("lookup")
      && description == "lookup query"
      && schema
      == blueprint.schema_value(
        blueprint.ObjectSchema([
          blueprint.PropertySchema("query", True, blueprint.TextSchema),
        ]),
      )
    _ -> False
  }
}

fn result_try(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Error(error) -> Error(error)
    Ok(value) -> next(value)
  }
}
