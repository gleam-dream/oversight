// THROWAWAY: Retain typed schema metadata through explicit admission and rendering.
import lab/blueprint
import lab/llm_turn

// Public metadata is constructible. Use entry_from_codec or a registry adapter
// when consistency with a registered decoder is required.
pub type Entry {
  Entry(
    name: llm_turn.ToolName,
    description: String,
    input_schema: blueprint.Schema,
  )
}

pub fn entry_from_codec(
  name: llm_turn.ToolName,
  description: String,
  codec: blueprint.Codec(a),
) -> Result(Entry, blueprint.SchemaError) {
  case blueprint.schema(codec) {
    Ok(schema) -> Ok(Entry(name, description, schema))
    Error(error) -> Error(error)
  }
}

pub type CatalogError {
  DuplicateName(llm_turn.ToolName)
}

pub opaque type Catalog {
  Catalog(entries: List(Entry))
}

pub opaque type AdmittedCatalog {
  AdmittedCatalog(entries: List(Entry))
}

pub type Rejection(reason) {
  Rejection(tool: llm_turn.ToolName, reason: reason)
}

pub fn catalog(entries: List(Entry)) -> Result(Catalog, CatalogError) {
  case check_names(entries, []) {
    Ok(Nil) -> Ok(Catalog(entries))
    Error(error) -> Error(error)
  }
}

pub fn entries(catalog: Catalog) -> List(Entry) {
  catalog.entries
}

// The policy receives the complete AST, so positional and combined constraints
// need not be guessed from a detached list of supported feature flags.
pub fn admit(
  catalog: Catalog,
  policy: fn(Entry) -> List(reason),
) -> Result(AdmittedCatalog, List(Rejection(reason))) {
  case rejected(catalog.entries, policy) {
    [] -> Ok(AdmittedCatalog(catalog.entries))
    issues -> Error(issues)
  }
}

// Admission refers only to the supplied policy; a live provider must use its own
// configured policy and still handle remote rejection.
pub fn render(catalog: AdmittedCatalog) -> List(llm_turn.ToolDeclaration) {
  render_entries(catalog.entries)
}

fn render_entries(entries: List(Entry)) -> List(llm_turn.ToolDeclaration) {
  case entries {
    [] -> []
    [entry, ..rest] -> [
      llm_turn.ToolDeclaration(
        entry.name,
        entry.description,
        blueprint.schema_value(entry.input_schema),
      ),
      ..render_entries(rest)
    ]
  }
}

fn check_names(
  entries: List(Entry),
  names: List(llm_turn.ToolName),
) -> Result(Nil, CatalogError) {
  case entries {
    [] -> Ok(Nil)
    [entry, ..rest] ->
      case contains(names, entry.name) {
        True -> Error(DuplicateName(entry.name))
        False -> check_names(rest, [entry.name, ..names])
      }
  }
}

fn contains(names: List(llm_turn.ToolName), name: llm_turn.ToolName) -> Bool {
  case names {
    [] -> False
    [first, ..rest] -> first == name || contains(rest, name)
  }
}

fn rejected(
  entries: List(Entry),
  policy: fn(Entry) -> List(reason),
) -> List(Rejection(reason)) {
  case entries {
    [] -> []
    [entry, ..rest] ->
      append(for_tool(entry.name, policy(entry)), rejected(rest, policy))
  }
}

fn for_tool(
  name: llm_turn.ToolName,
  reasons: List(reason),
) -> List(Rejection(reason)) {
  case reasons {
    [] -> []
    [reason, ..rest] -> [Rejection(name, reason), ..for_tool(name, rest)]
  }
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [first, ..rest] -> [first, ..append(rest, right)]
  }
}
