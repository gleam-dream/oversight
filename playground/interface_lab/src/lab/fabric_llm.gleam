// THROWAWAY: Adapter direction is Fabric -> LLM; neither core knows the other.
import lab/blueprint
import lab/fabric
import lab/llm_catalog
import lab/llm_turn

pub fn catalog(
  registry: fabric.Registry(c),
) -> Result(llm_catalog.Catalog, llm_catalog.CatalogError) {
  llm_catalog.catalog(structured_entries(fabric.declarations(registry)))
}

fn structured_entries(
  items: List(fabric.Declaration),
) -> List(llm_catalog.Entry) {
  case items {
    [] -> []
    [item, ..rest] -> [
      llm_catalog.Entry(llm_turn.ToolName(item.name), "", item.input_schema),
      ..structured_entries(rest)
    ]
  }
}

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
