// THROWAWAY: Adapter direction is Fabric -> LLM; neither core knows the other.
import lab/blueprint
import lab/fabric
import lab/llm_turn

pub fn declarations(
  registry: fabric.Registry(c),
) -> List(llm_turn.ToolDeclaration) {
  convert(fabric.declarations(registry))
}

fn convert(items: List(fabric.Declaration)) -> List(llm_turn.ToolDeclaration) {
  case items {
    [] -> []
    [item, ..rest] -> [
      llm_turn.ToolDeclaration(
        llm_turn.ToolName(item.name),
        "",
        blueprint.schema_value(item.input_schema),
      ),
      ..convert(rest)
    ]
  }
}
