// THROWAWAY: Can one scripted native profile bind its schema policy and callbacks?
import lab/blueprint
import lab/blueprint_requirements as requirements
import lab/llm
import lab/llm_structured
import lab/llm_turn

pub type NativeModel {
  AlphaCompact
}

pub type OutputMode {
  StrictJsonSchema
}

pub type NativeConfig {
  NativeConfig(model: NativeModel, output_mode: OutputMode, string_enums: Bool)
}

pub type UnsupportedFeature {
  AlphaUnsupportedRequirement(requirements.Requirement)
}

pub type AdapterError {
  UnknownAlphaModel(String)
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
    "alpha-json-compact" -> {
      let config = NativeConfig(AlphaCompact, StrictJsonSchema, True)
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
    _ -> Error(UnknownAlphaModel(model_name))
  }
}

fn unsupported(
  config: NativeConfig,
  _location: llm_structured.SchemaLocation,
  schema: blueprint.Schema,
) -> List(UnsupportedFeature) {
  case config.string_enums {
    True -> reject_tuples(requirements.requirements(schema))
    False -> reject_enums(requirements.requirements(schema))
  }
}

fn reject_tuples(
  items: List(requirements.Requirement),
) -> List(UnsupportedFeature) {
  case items {
    [] -> []
    [item, ..rest] ->
      case item.feature {
        requirements.FixedTuple -> [
          AlphaUnsupportedRequirement(item),
          ..reject_tuples(rest)
        ]
        _ -> reject_tuples(rest)
      }
  }
}

fn reject_enums(
  items: List(requirements.Requirement),
) -> List(UnsupportedFeature) {
  case items {
    [] -> []
    [item, ..rest] ->
      case item.feature {
        requirements.StringEnumValues(_) -> [
          AlphaUnsupportedRequirement(item),
          ..reject_enums(rest)
        ]
        _ -> reject_enums(rest)
      }
  }
}
