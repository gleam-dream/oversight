// THROWAWAY: Does a finite root object schema generate a deterministic typed codec?
import lab/blueprint
import lab/blueprint_runtime as runtime

@external(erlang, "blueprint_codegen_ffi", "string_literal")
fn string_literal(value: String) -> String

@external(erlang, "blueprint_codegen_ffi", "integer_to_string")
fn integer_to_string(value: Int) -> String

pub opaque type GeneratedSource {
  GeneratedSource(String)
}

pub type PathSegment {
  Property(String)
  NullableValue
}

pub type UnsupportedReason {
  RootMustBeObject
  NestedObject
  ListSchema
  PairSchema
  TaggedSchema
}

pub type GenerationError {
  UnsupportedGeneration(path: List(PathSegment), reason: UnsupportedReason)
}

type Maybe(a) {
  Nothing
  Something(a)
}

type RangeBinding {
  RangeBinding(name: String, minimum: Int, maximum: Int)
}

type EnumVariant {
  EnumVariant(label: String, constructor: String)
}

type EnumBinding {
  EnumBinding(
    type_name: String,
    codec_name: String,
    variants: List(EnumVariant),
  )
}

type Analysis {
  Analysis(
    native_type: String,
    codec: String,
    range: Maybe(RangeBinding),
    enumeration: Maybe(EnumBinding),
  )
}

type Field {
  Field(index: Int, wire_name: String, required: Bool, analysis: Analysis)
}

pub fn generate(
  contract: runtime.RuntimeContract,
) -> Result(GeneratedSource, GenerationError) {
  case runtime.schema(contract) {
    blueprint.ObjectSchema(properties) -> {
      use fields <- bind(analyse_fields(properties, 0, []))
      Ok(GeneratedSource(render_source(fields)))
    }
    _ -> Error(UnsupportedGeneration([], RootMustBeObject))
  }
}

pub fn source(generated: GeneratedSource) -> String {
  let GeneratedSource(text) = generated
  text
}

fn analyse_fields(
  properties: List(blueprint.PropertySchema),
  index: Int,
  reversed: List(Field),
) -> Result(List(Field), GenerationError) {
  case properties {
    [] -> Ok(reverse(reversed))
    [blueprint.PropertySchema(name, required, schema), ..rest] -> {
      use analysis <- bind(analyse_schema(schema, index, [Property(name)]))
      analyse_fields(rest, index + 1, [
        Field(index, name, required, analysis),
        ..reversed
      ])
    }
  }
}

fn analyse_schema(
  schema: blueprint.Schema,
  index: Int,
  path: List(PathSegment),
) -> Result(Analysis, GenerationError) {
  case schema {
    blueprint.TextSchema ->
      Ok(Analysis("String", "blueprint.text()", Nothing, Nothing))
    blueprint.StringEnumSchema(labels) -> {
      let type_name = enum_type_name(index)
      let codec_name = enum_codec_name(index)
      Ok(Analysis(
        type_name,
        codec_name,
        Nothing,
        Something(EnumBinding(
          type_name,
          codec_name,
          enum_variants(index, labels, 0),
        )),
      ))
    }
    blueprint.IntSchema ->
      Ok(Analysis("Int", "blueprint.int()", Nothing, Nothing))
    blueprint.BoolSchema ->
      Ok(Analysis("Bool", "blueprint.bool()", Nothing, Nothing))
    blueprint.IntegerRangeSchema(minimum, maximum) -> {
      let binding = "bounded_" <> integer_to_string(index)
      Ok(Analysis(
        "Int",
        binding,
        Something(RangeBinding(binding, minimum, maximum)),
        Nothing,
      ))
    }
    blueprint.NullableSchema(inner) -> {
      use analysed <- bind(analyse_schema(
        inner,
        index,
        append_path(path, NullableValue),
      ))
      Ok(Analysis(
        "blueprint.Nullable(" <> analysed.native_type <> ")",
        "blueprint.nullable(" <> analysed.codec <> ")",
        analysed.range,
        analysed.enumeration,
      ))
    }
    blueprint.ObjectSchema(_) | blueprint.FieldSchema(_, _) ->
      Error(UnsupportedGeneration(path, NestedObject))
    blueprint.ListSchema(_) -> Error(UnsupportedGeneration(path, ListSchema))
    blueprint.PairSchema(_, _) -> Error(UnsupportedGeneration(path, PairSchema))
    blueprint.TaggedSchema(_, _, _, _) ->
      Error(UnsupportedGeneration(path, TaggedSchema))
  }
}

fn render_source(fields: List(Field)) -> String {
  let enum_types = render_enum_types(fields)
  let declaration = render_type(fields)
  let function_body = render_codec_body(fields)
  "import lab/blueprint\n\n"
  <> enum_types
  <> declaration
  <> "\n\npub fn codec() -> blueprint.Codec(Document) {\n"
  <> indent_lines(function_body, "  ")
  <> "}\n"
}

fn render_type(fields: List(Field)) -> String {
  case fields {
    [] -> "pub type Document {\n  Document\n}"
    _ ->
      "pub type Document {\n  Document(\n"
      <> indent_lines(render_type_fields(fields), "    ")
      <> "  )\n}"
  }
}

fn render_enum_types(fields: List(Field)) -> String {
  case fields {
    [] -> ""
    [Field(_, _, _, Analysis(_, _, _, Nothing)), ..rest] ->
      render_enum_types(rest)
    [Field(_, _, _, Analysis(_, _, _, Something(binding))), ..rest] ->
      render_enum_type(binding) <> "\n\n" <> render_enum_types(rest)
  }
}

fn render_enum_type(binding: EnumBinding) -> String {
  let EnumBinding(type_name, _, variants) = binding
  "pub type "
  <> type_name
  <> " {\n"
  <> indent_lines(enum_constructors(variants), "  ")
  <> "}"
}

fn enum_constructors(variants: List(EnumVariant)) -> List(String) {
  case variants {
    [] -> []
    [EnumVariant(_, constructor), ..rest] -> [
      constructor,
      ..enum_constructors(rest)
    ]
  }
}

fn render_type_fields(fields: List(Field)) -> List(String) {
  map_type_fields(fields, 0, list_length(fields))
}

fn map_type_fields(
  fields: List(Field),
  index: Int,
  total: Int,
) -> List(String) {
  case fields {
    [] -> []
    [field, ..rest] -> {
      let suffix = case index == total - 1 {
        True -> ""
        False -> ","
      }
      [
        field_label(field) <> ": " <> field_type(field) <> suffix,
        ..map_type_fields(rest, index + 1, total)
      ]
    }
  }
}

fn field_type(field: Field) -> String {
  let Field(_, _, required, analysis) = field
  case analysis {
    Analysis(native_type, _, _, _) ->
      case required {
        True -> native_type
        False -> "blueprint.Optional(" <> native_type <> ")"
      }
  }
}

fn render_codec_body(fields: List(Field)) -> List(String) {
  append(
    range_bindings(fields),
    append(
      enum_bindings(fields),
      append(
        property_bindings(fields),
        append(combination_bindings(fields), [
          "blueprint.imap(",
          "  blueprint.object(" <> properties_value(fields) <> "),",
          "  fn(raw) { " <> construct_document(fields) <> " },",
          "  fn(document) { " <> deconstruct_document(fields) <> " },",
          ")",
        ]),
      ),
    ),
  )
}

fn range_bindings(fields: List(Field)) -> List(String) {
  case fields {
    [] -> []
    [
      Field(_, _, _, Analysis(_, _, Something(RangeBinding(name, min, max)), _)),
      ..rest
    ] -> [
      "let assert Ok("
        <> name
        <> ") = blueprint.integer_between("
        <> integer_to_string(min)
        <> ", "
        <> integer_to_string(max)
        <> ")",
      ..range_bindings(rest)
    ]
    [_, ..rest] -> range_bindings(rest)
  }
}

fn enum_bindings(fields: List(Field)) -> List(String) {
  case fields {
    [] -> []
    [Field(_, _, _, Analysis(_, _, _, Nothing)), ..rest] -> enum_bindings(rest)
    [Field(_, _, _, Analysis(_, _, _, Something(binding))), ..rest] -> [
      render_enum_binding(binding),
      ..enum_bindings(rest)
    ]
  }
}

fn render_enum_binding(binding: EnumBinding) -> String {
  let EnumBinding(_, codec_name, variants) = binding
  "let assert Ok("
  <> codec_name
  <> ") = blueprint.string_enum(["
  <> join_inline(render_enum_values(variants))
  <> "])"
}

fn render_enum_values(variants: List(EnumVariant)) -> List(String) {
  case variants {
    [] -> []
    [EnumVariant(label, constructor), ..rest] -> [
      "#(" <> string_literal(label) <> ", " <> constructor <> ")",
      ..render_enum_values(rest)
    ]
  }
}

fn property_bindings(fields: List(Field)) -> List(String) {
  case fields {
    [] -> []
    [field, ..rest] -> {
      let Field(index, name, required, Analysis(_, codec, _, _)) = field
      let property = case required {
        True ->
          "blueprint.required(" <> string_literal(name) <> ", " <> codec <> ")"
        False ->
          "blueprint.optional(" <> string_literal(name) <> ", " <> codec <> ")"
      }
      [
        "let property_" <> integer_to_string(index) <> " = " <> property,
        ..property_bindings(rest)
      ]
    }
  }
}

fn combination_bindings(fields: List(Field)) -> List(String) {
  case fields {
    [] | [_] -> []
    [first, ..rest] -> {
      let Field(first_index, _, _, _) = first
      combine_rest(rest, "property_" <> integer_to_string(first_index))
    }
  }
}

fn combine_rest(fields: List(Field), accumulated_name: String) -> List(String) {
  case fields {
    [] -> []
    [field, ..rest] -> {
      let Field(index, _, _, _) = field
      let combined_name = "properties_" <> integer_to_string(index)
      [
        "let assert Ok("
          <> combined_name
          <> ") = blueprint.combine("
          <> accumulated_name
          <> ", property_"
          <> integer_to_string(index)
          <> ")",
        ..combine_rest(rest, combined_name)
      ]
    }
  }
}

fn properties_value(fields: List(Field)) -> String {
  case fields {
    [] -> "blueprint.empty()"
    [Field(index, _, _, _)] -> "property_" <> integer_to_string(index)
    _ -> "properties_" <> integer_to_string(list_length(fields) - 1)
  }
}

fn enum_type_name(index: Int) -> String {
  "Field" <> integer_to_string(index) <> "Enum"
}

fn enum_codec_name(index: Int) -> String {
  "enum_codec_" <> integer_to_string(index)
}

fn enum_variants(
  field_index: Int,
  labels: List(String),
  index: Int,
) -> List(EnumVariant) {
  case labels {
    [] -> []
    [label, ..rest] -> [
      EnumVariant(label, enum_constructor_name(field_index, index)),
      ..enum_variants(field_index, rest, index + 1)
    ]
  }
}

fn enum_constructor_name(field_index: Int, value_index: Int) -> String {
  "Field"
  <> integer_to_string(field_index)
  <> "Value"
  <> integer_to_string(value_index)
}

fn construct_document(fields: List(Field)) -> String {
  case fields {
    [] -> "Document"
    _ ->
      "Document("
      <> join_inline(map_constructor_fields(fields, list_length(fields)))
      <> ")"
  }
}

fn map_constructor_fields(fields: List(Field), total: Int) -> List(String) {
  case fields {
    [] -> []
    [field, ..rest] -> {
      let Field(index, _, _, _) = field
      [
        field_label(field) <> ": raw" <> tuple_projection(index, total),
        ..map_constructor_fields(rest, total)
      ]
    }
  }
}

fn deconstruct_document(fields: List(Field)) -> String {
  case fields {
    [] -> "Nil"
    [first, ..rest] -> {
      let first_value = "document." <> field_label(first)
      tuple_expression(rest, first_value)
    }
  }
}

fn tuple_expression(fields: List(Field), accumulated: String) -> String {
  case fields {
    [] -> accumulated
    [field, ..rest] ->
      tuple_expression(
        rest,
        "#(" <> accumulated <> ", document." <> field_label(field) <> ")",
      )
  }
}

fn tuple_projection(index: Int, count: Int) -> String {
  case count {
    0 | 1 -> ""
    _ if index == count - 1 -> ".1"
    _ -> ".0" <> tuple_projection(index, count - 1)
  }
}

fn field_label(field: Field) -> String {
  let Field(index, _, _, _) = field
  "field_" <> integer_to_string(index)
}

fn append_path(
  path: List(PathSegment),
  segment: PathSegment,
) -> List(PathSegment) {
  case path {
    [] -> [segment]
    [head, ..rest] -> [head, ..append_path(rest, segment)]
  }
}

fn reverse(items: List(a)) -> List(a) {
  reverse_into(items, [])
}

fn reverse_into(items: List(a), reversed: List(a)) -> List(a) {
  case items {
    [] -> reversed
    [head, ..rest] -> reverse_into(rest, [head, ..reversed])
  }
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [head, ..rest] -> [head, ..append(rest, right)]
  }
}

fn join_inline(lines: List(String)) -> String {
  case lines {
    [] -> ""
    [line] -> line
    [line, ..rest] -> line <> ", " <> join_inline(rest)
  }
}

fn indent_lines(lines: List(String), indentation: String) -> String {
  case lines {
    [] -> ""
    [line] -> indentation <> line <> "\n"
    [line, ..rest] ->
      indentation <> line <> "\n" <> indent_lines(rest, indentation)
  }
}

fn bind(
  result: Result(a, GenerationError),
  next: fn(a) -> Result(b, GenerationError),
) -> Result(b, GenerationError) {
  case result {
    Error(error) -> Error(error)
    Ok(value) -> next(value)
  }
}
