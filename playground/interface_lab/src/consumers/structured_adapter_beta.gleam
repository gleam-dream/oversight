// THROWAWAY: Can another closed native config reject schemas before transport?
import lab/blueprint
import lab/blueprint_requirements as requirements
import lab/llm
import lab/llm_structured
import lab/llm_turn

pub type Deployment {
  BetaRegional
}

pub type SchemaDialect {
  FiniteJsonSchema
}

pub type NativeConfig {
  NativeConfig(
    deployment: Deployment,
    dialect: SchemaDialect,
    allow_integer_ranges: Bool,
  )
}

pub type UnsupportedFeature {
  BetaStringEnumUnsupported(requirements.Requirement)
  BetaIntegerRangeUnsupported(requirements.Requirement)
  BetaToolRootMustBeObject
}

pub type AdapterError {
  UnknownBetaModel(String)
}

pub fn select(
  model_name: String,
  transport_start: fn(
    NativeConfig,
    llm.Request,
    blueprint.Schema,
    List(llm_turn.ToolDeclaration),
  ) -> Result(llm_structured.Reply(llm.Request), llm.CallError),
  transport_resume: fn(NativeConfig, llm.Request, List(llm_turn.ToolResult)) ->
    Result(llm_structured.Reply(llm.Request), llm.CallError),
) -> Result(
  llm_structured.Provider(llm.Request, UnsupportedFeature),
  AdapterError,
) {
  case model_name {
    "beta-object-regional" -> {
      let config = NativeConfig(BetaRegional, FiniteJsonSchema, False)
      let assert Ok(model) = llm_structured.model_id(model_name)
      Ok(
        llm_structured.configured_provider(
          model,
          fn(location, schema) { unsupported(config, location, schema) },
          fn(request, output_schema, tools) {
            transport_start(config, request, output_schema, tools)
          },
          fn(continuation, results) {
            transport_resume(config, continuation, results)
          },
        ),
      )
    }
    _ -> Error(UnknownBetaModel(model_name))
  }
}

fn unsupported(
  config: NativeConfig,
  location: llm_structured.SchemaLocation,
  schema: blueprint.Schema,
) -> List(UnsupportedFeature) {
  let root_issue = case location {
    llm_structured.ToolInput(_) ->
      case schema {
        blueprint.FieldSchema(_, _)
        | blueprint.ObjectSchema(_)
        | blueprint.TaggedSchema(_, _, _, _) -> []
        _ -> [BetaToolRootMustBeObject]
      }
    llm_structured.StructuredOutput -> []
  }
  append(
    root_issue,
    reject_requirements(config, requirements.requirements(schema)),
  )
}

fn reject_requirements(
  config: NativeConfig,
  items: List(requirements.Requirement),
) -> List(UnsupportedFeature) {
  case items {
    [] -> []
    [item, ..rest] -> {
      let issue = case item.feature {
        requirements.StringEnumValues(_) -> [BetaStringEnumUnsupported(item)]
        requirements.IntegerBounds(_, _) if !config.allow_integer_ranges -> [
          BetaIntegerRangeUnsupported(item),
        ]
        _ -> []
      }
      append(issue, reject_requirements(config, rest))
    }
  }
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [first, ..rest] -> [first, ..append(rest, right)]
  }
}
