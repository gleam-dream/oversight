// THROWAWAY: Can heterogeneous MCP tool contracts preserve typed registration?
import lab/blueprint.{type Codec, type DecodeError, type EncodeError}
import lab/value.{type Value}

pub type InvocationError {
  InvalidInput(DecodeError)
  InvalidOutput(EncodeError)
  InvalidError(EncodeError)
  ApplicationFailure(Value)
}

pub opaque type Tool {
  Tool(
    name: String,
    invoke: fn(Value) -> Result(Value, InvocationError),
    input_schema: Result(blueprint.Schema, blueprint.SchemaError),
  )
}

pub fn tool(
  name: String,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  handler: fn(i) -> Result(o, e),
) -> Tool {
  Tool(
    name,
    fn(raw) {
      case blueprint.decode(input, raw) {
        Error(e) -> Error(InvalidInput(e))
        Ok(i) ->
          case handler(i) {
            Ok(o) ->
              case blueprint.encode(output, o) {
                Ok(v) -> Ok(v)
                Error(e) -> Error(InvalidOutput(e))
              }
            Error(e) ->
              case blueprint.encode(error, e) {
                Ok(v) -> Error(ApplicationFailure(v))
                Error(e) -> Error(InvalidError(e))
              }
          }
      }
    },
    blueprint.schema(input),
  )
}

pub fn invoke(tool: Tool, input: Value) -> Result(Value, InvocationError) {
  tool.invoke(input)
}

// Registration carries the handler. No transport, authorization, or discovery.
pub fn name(tool: Tool) -> String {
  tool.name
}

// A registry can be built once while invocation supplies request-owned context.
// Context remains adapter-specific and is not part of the encoded business input.
pub opaque type ContextTool(context) {
  ContextTool(
    name: String,
    bind: fn(context) -> Tool,
    declaration: Result(Declaration, DeclarationError),
  )
}

pub fn context_tool(
  name: String,
  input: Codec(i),
  output: Codec(o),
  error: Codec(e),
  handler: fn(context, i) -> Result(o, e),
) -> ContextTool(context) {
  ContextTool(
    name,
    fn(context) {
      tool(name, input, output, error, fn(input) { handler(context, input) })
    },
    describe(name, blueprint.schema(input)),
  )
}

pub fn bind_context(tool: ContextTool(context), context: context) -> Tool {
  tool.bind(context)
}

pub fn invoke_context(
  tool: ContextTool(context),
  context: context,
  input: Value,
) -> Result(Value, InvocationError) {
  invoke(bind_context(tool, context), input)
}

// Declaration is derived from the exact codec retained by registration.
pub type Declaration {
  Declaration(name: String, input_schema: blueprint.Schema)
}

fn describe(
  name: String,
  schema: Result(blueprint.Schema, blueprint.SchemaError),
) -> Result(Declaration, DeclarationError) {
  case schema {
    Ok(blueprint.FieldSchema(_, _) as schema) -> Ok(Declaration(name, schema))
    Ok(_) -> Error(InputMustBeObject)
    Error(error) -> Error(SchemaUnavailable(error))
  }
}

pub fn declaration(tool: Tool) -> Result(Declaration, DeclarationError) {
  describe(tool.name, tool.input_schema)
}

pub fn context_declaration(
  tool: ContextTool(c),
) -> Result(Declaration, DeclarationError) {
  tool.declaration
}

pub type DeclarationError {
  SchemaUnavailable(blueprint.SchemaError)
  InputMustBeObject
}

// Registry creation validates identity and discovery without invocation context.
pub opaque type Registry(c) {
  Registry(entries: List(#(Declaration, ContextTool(c))))
}

pub type RegistryError {
  DuplicateName(String)
  InvalidDeclaration(String, DeclarationError)
}

pub type DispatchError {
  UnknownTool(String)
  InvocationFailed(InvocationError)
}

pub fn registry(
  tools: List(ContextTool(c)),
) -> Result(Registry(c), RegistryError) {
  build_registry(tools, [])
}

fn build_registry(
  tools: List(ContextTool(c)),
  entries: List(#(Declaration, ContextTool(c))),
) -> Result(Registry(c), RegistryError) {
  case tools {
    [] -> Ok(Registry(reverse_entries(entries, [])))
    [tool, ..rest] ->
      case context_declaration(tool) {
        Error(error) -> Error(InvalidDeclaration(tool.name, error))
        Ok(declaration) ->
          case has_name(entries, declaration.name) {
            True -> Error(DuplicateName(declaration.name))
            False -> build_registry(rest, [#(declaration, tool), ..entries])
          }
      }
  }
}

fn has_name(
  entries: List(#(Declaration, ContextTool(c))),
  name: String,
) -> Bool {
  case entries {
    [] -> False
    [#(declaration, _), ..rest] ->
      declaration.name == name || has_name(rest, name)
  }
}

pub fn declarations(registry: Registry(c)) -> List(Declaration) {
  catalog(registry.entries)
}

fn catalog(entries: List(#(Declaration, ContextTool(c)))) -> List(Declaration) {
  case entries {
    [] -> []
    [#(declaration, _), ..rest] -> [declaration, ..catalog(rest)]
  }
}

pub fn dispatch(
  registry: Registry(c),
  context: c,
  name: String,
  input: Value,
) -> Result(Value, DispatchError) {
  dispatch_entries(registry.entries, context, name, input)
}

fn dispatch_entries(
  entries: List(#(Declaration, ContextTool(c))),
  context: c,
  name: String,
  input: Value,
) -> Result(Value, DispatchError) {
  case entries {
    [] -> Error(UnknownTool(name))
    [#(declaration, tool), ..rest] ->
      case declaration.name == name {
        False -> dispatch_entries(rest, context, name, input)
        True ->
          case invoke_context(tool, context, input) {
            Ok(output) -> Ok(output)
            Error(error) -> Error(InvocationFailed(error))
          }
      }
  }
}

fn reverse_entries(items: List(a), acc: List(a)) -> List(a) {
  case items {
    [] -> acc
    [item, ..rest] -> reverse_entries(rest, [item, ..acc])
  }
}
