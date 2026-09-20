// THROWAWAY: Can an already parsed finite schema document become a runtime contract?
import lab/blueprint
import lab/blueprint_runtime as runtime
import lab/value

const draft_2020_12 = "https://json-schema.org/draft/2020-12/schema"

pub type PathSegment {
  Property(String)
  Index(Int)
}

pub type DocumentError {
  MalformedDocument(path: List(PathSegment), reason: MalformedReason)
  UnsupportedDocument(path: List(PathSegment), reason: UnsupportedReason)
  UnsupportedDialect(path: List(PathSegment), actual: String)
  SchemaInvariant(path: List(PathSegment), reason: runtime.ContractError)
}

pub type MalformedReason {
  ExpectedObject
  ExpectedText
  ExpectedInteger
  ExpectedBoolean
  ExpectedArray
  MissingField(String)
  DuplicateKey(String)
  DuplicateRequiredName(String)
  UndeclaredRequiredName(String)
  InvalidNullableAlternatives
  InvalidTaggedAlternatives
  InvalidTupleShape
  IncompleteIntegerRange
  ExpectedObjectSchema
  ExpectedClosedTag
}

pub type UnsupportedReason {
  UnsupportedKeyword(String)
  NestedDialect
  UnsupportedSchemaForm
  OpenObject
  ArbitraryUnion
  UnboundedArray
  UnsupportedTupleForm
  UnsupportedTaggedShape
}

type Maybe(a) {
  Nothing
  Something(a)
}

type ParsedSchema {
  ParsedSchema(schema: blueprint.Schema, invariants: List(InvariantLocation))
}

type InvariantLocation {
  InvariantLocation(reason: runtime.ContractError, path: List(PathSegment))
}

pub fn load(
  document: value.Value,
) -> Result(runtime.RuntimeContract, DocumentError) {
  use fields <- bind(object_fields(document, []))
  use dialect <- bind(required_field(fields, "$schema", []))
  case dialect {
    value.Text(actual) if actual == draft_2020_12 -> {
      let schema_fields = without_field(fields, "$schema")
      use parsed <- bind(parse_schema(value.Object(schema_fields), []))
      case runtime.from_schema(parsed.schema) {
        Ok(contract) -> Ok(contract)
        Error(reason) ->
          Error(SchemaInvariant(
            invariant_path(reason, parsed.invariants),
            reason,
          ))
      }
    }
    value.Text(actual) ->
      Error(UnsupportedDialect([Property("$schema")], actual))
    _ -> Error(MalformedDocument([Property("$schema")], ExpectedText))
  }
}

fn parse_schema(
  document: value.Value,
  path: List(PathSegment),
) -> Result(ParsedSchema, DocumentError) {
  use fields <- bind(object_fields(document, path))
  use _ <- bind(known_schema_keywords(fields, path))
  case lookup(fields, "anyOf") {
    Something(alternatives) -> {
      use _ <- bind(only_fields(fields, ["anyOf"], path))
      parse_nullable(alternatives, append_path(path, Property("anyOf")))
    }
    Nothing -> {
      use kind <- bind(required_field(fields, "type", path))
      case kind {
        value.Text("string") -> parse_string_schema(fields, path)
        value.Text("integer") -> parse_integer(fields, path)
        value.Text("boolean") ->
          parse_primitive(fields, path, blueprint.BoolSchema)
        value.Text("object") -> parse_object_or_tagged(fields, path)
        value.Text("array") -> parse_array(fields, path)
        value.Text("null") ->
          Error(UnsupportedDocument(path, UnsupportedSchemaForm))
        value.Text(_) -> Error(UnsupportedDocument(path, UnsupportedSchemaForm))
        _ ->
          Error(MalformedDocument(
            append_path(path, Property("type")),
            ExpectedText,
          ))
      }
    }
  }
}

fn known_schema_keywords(
  fields: List(#(String, value.Value)),
  path: List(PathSegment),
) -> Result(Nil, DocumentError) {
  check_known_keywords(
    fields,
    [
      "type",
      "enum",
      "minimum",
      "maximum",
      "properties",
      "required",
      "additionalProperties",
      "items",
      "prefixItems",
      "minItems",
      "maxItems",
      "anyOf",
      "oneOf",
    ],
    path,
  )
}

fn parse_string_schema(
  fields: List(#(String, value.Value)),
  path: List(PathSegment),
) -> Result(ParsedSchema, DocumentError) {
  case lookup(fields, "enum") {
    Nothing -> parse_primitive(fields, path, blueprint.TextSchema)
    Something(raw) -> {
      use _ <- bind(only_fields(fields, ["type", "enum"], path))
      let enum_path = append_path(path, Property("enum"))
      use labels <- bind(parse_enum_labels(raw, enum_path))
      let invariants = case labels {
        [] -> [InvariantLocation(runtime.EmptyStringEnum, enum_path)]
        [_, ..] ->
          case duplicate_enum_label(labels, [], 0) {
            Nothing -> []
            Something(#(label, index)) -> [
              InvariantLocation(
                runtime.DuplicateSchemaEnumLabel(label),
                append_path(enum_path, Index(index)),
              ),
            ]
          }
      }
      Ok(ParsedSchema(blueprint.StringEnumSchema(labels), invariants))
    }
  }
}

fn parse_enum_labels(
  raw: value.Value,
  path: List(PathSegment),
) -> Result(List(String), DocumentError) {
  case raw {
    value.Array(items) -> parse_enum_label_items(items, path, 0, [])
    _ -> Error(MalformedDocument(path, ExpectedArray))
  }
}

fn parse_enum_label_items(
  items: List(value.Value),
  path: List(PathSegment),
  index: Int,
  reversed: List(String),
) -> Result(List(String), DocumentError) {
  case items {
    [] -> Ok(reverse(reversed))
    [value.Text(label), ..rest] ->
      parse_enum_label_items(rest, path, index + 1, [label, ..reversed])
    [_, ..] ->
      Error(MalformedDocument(append_path(path, Index(index)), ExpectedText))
  }
}

fn duplicate_enum_label(
  labels: List(String),
  seen: List(String),
  index: Int,
) -> Maybe(#(String, Int)) {
  case labels {
    [] -> Nothing
    [label, ..rest] ->
      case contains(seen, label) {
        True -> Something(#(label, index))
        False -> duplicate_enum_label(rest, [label, ..seen], index + 1)
      }
  }
}

fn check_known_keywords(
  fields: List(#(String, value.Value)),
  known: List(String),
  path: List(PathSegment),
) -> Result(Nil, DocumentError) {
  case fields {
    [] -> Ok(Nil)
    [#("$schema", _), ..] ->
      Error(UnsupportedDocument(
        append_path(path, Property("$schema")),
        NestedDialect,
      ))
    [#(name, _), ..rest] ->
      case contains(known, name) {
        True -> check_known_keywords(rest, known, path)
        False ->
          Error(UnsupportedDocument(
            append_path(path, Property(name)),
            UnsupportedKeyword(name),
          ))
      }
  }
}

fn parse_primitive(
  fields: List(#(String, value.Value)),
  path: List(PathSegment),
  schema: blueprint.Schema,
) -> Result(ParsedSchema, DocumentError) {
  use _ <- bind(only_fields(fields, ["type"], path))
  Ok(ParsedSchema(schema, []))
}

fn parse_integer(
  fields: List(#(String, value.Value)),
  path: List(PathSegment),
) -> Result(ParsedSchema, DocumentError) {
  use _ <- bind(only_fields(fields, ["type", "minimum", "maximum"], path))
  case lookup(fields, "minimum"), lookup(fields, "maximum") {
    Nothing, Nothing -> Ok(ParsedSchema(blueprint.IntSchema, []))
    Something(minimum), Something(maximum) -> {
      use minimum <- bind(expect_integer(
        minimum,
        append_path(path, Property("minimum")),
      ))
      use maximum <- bind(expect_integer(
        maximum,
        append_path(path, Property("maximum")),
      ))
      let schema = blueprint.IntegerRangeSchema(minimum, maximum)
      let invariants = case minimum > maximum {
        True -> [
          InvariantLocation(
            runtime.ReversedIntegerRange(minimum, maximum),
            append_path(path, Property("minimum")),
          ),
        ]
        False -> []
      }
      Ok(ParsedSchema(schema, invariants))
    }
    _, _ -> Error(MalformedDocument(path, IncompleteIntegerRange))
  }
}

fn parse_object_or_tagged(
  fields: List(#(String, value.Value)),
  path: List(PathSegment),
) -> Result(ParsedSchema, DocumentError) {
  case lookup(fields, "oneOf") {
    Something(alternatives) -> {
      use _ <- bind(only_fields(fields, ["type", "oneOf"], path))
      parse_tagged(alternatives, append_path(path, Property("oneOf")))
    }
    Nothing -> parse_object(fields, path)
  }
}

fn parse_object(
  fields: List(#(String, value.Value)),
  path: List(PathSegment),
) -> Result(ParsedSchema, DocumentError) {
  use _ <- bind(only_fields(
    fields,
    ["type", "properties", "required", "additionalProperties"],
    path,
  ))
  use properties_value <- bind(required_field(fields, "properties", path))
  use required_value <- bind(required_field(fields, "required", path))
  use additional <- bind(required_field(fields, "additionalProperties", path))
  use _ <- bind(check_closed_object(
    additional,
    append_path(path, Property("additionalProperties")),
  ))
  use properties <- bind(object_fields(
    properties_value,
    append_path(path, Property("properties")),
  ))
  use required <- bind(required_names(
    required_value,
    append_path(path, Property("required")),
  ))
  use _ <- bind(check_declared_required(
    required,
    properties,
    append_path(path, Property("required")),
    0,
  ))
  use parsed <- bind(parse_properties(
    properties,
    required,
    append_path(path, Property("properties")),
  ))
  Ok(ParsedSchema(blueprint.ObjectSchema(parsed.0), parsed.1))
}

fn parse_properties(
  properties: List(#(String, value.Value)),
  required: List(String),
  path: List(PathSegment),
) -> Result(
  #(List(blueprint.PropertySchema), List(InvariantLocation)),
  DocumentError,
) {
  case properties {
    [] -> Ok(#([], []))
    [#(name, raw), ..rest] -> {
      use parsed <- bind(parse_schema(raw, append_path(path, Property(name))))
      use tail <- bind(parse_properties(rest, required, path))
      Ok(#(
        [
          blueprint.PropertySchema(
            name,
            contains(required, name),
            parsed.schema,
          ),
          ..tail.0
        ],
        append_locations(parsed.invariants, tail.1),
      ))
    }
  }
}

fn parse_array(
  fields: List(#(String, value.Value)),
  path: List(PathSegment),
) -> Result(ParsedSchema, DocumentError) {
  case lookup(fields, "items"), lookup(fields, "prefixItems") {
    Something(items), Nothing -> {
      use _ <- bind(only_fields(fields, ["type", "items"], path))
      use parsed <- bind(parse_schema(
        items,
        append_path(path, Property("items")),
      ))
      Ok(ParsedSchema(blueprint.ListSchema(parsed.schema), parsed.invariants))
    }
    Nothing, Something(prefix_items) -> parse_tuple(fields, prefix_items, path)
    Nothing, Nothing -> Error(UnsupportedDocument(path, UnboundedArray))
    Something(_), Something(_) ->
      Error(UnsupportedDocument(path, UnsupportedTupleForm))
  }
}

fn parse_tuple(
  fields: List(#(String, value.Value)),
  prefix_items: value.Value,
  path: List(PathSegment),
) -> Result(ParsedSchema, DocumentError) {
  use _ <- bind(only_fields(
    fields,
    ["type", "prefixItems", "minItems", "maxItems"],
    path,
  ))
  use minimum <- bind(required_field(fields, "minItems", path))
  use maximum <- bind(required_field(fields, "maxItems", path))
  use minimum <- bind(expect_integer(
    minimum,
    append_path(path, Property("minItems")),
  ))
  use maximum <- bind(expect_integer(
    maximum,
    append_path(path, Property("maxItems")),
  ))
  case prefix_items, minimum, maximum {
    value.Array([first, second]), 2, 2 -> {
      use left <- bind(parse_schema(
        first,
        append_path(append_path(path, Property("prefixItems")), Index(0)),
      ))
      use right <- bind(parse_schema(
        second,
        append_path(append_path(path, Property("prefixItems")), Index(1)),
      ))
      Ok(ParsedSchema(
        blueprint.PairSchema(left.schema, right.schema),
        append_locations(left.invariants, right.invariants),
      ))
    }
    value.Array(_), _, _ ->
      Error(UnsupportedDocument(path, UnsupportedTupleForm))
    _, _, _ ->
      Error(MalformedDocument(
        append_path(path, Property("prefixItems")),
        ExpectedArray,
      ))
  }
}

fn parse_nullable(
  alternatives: value.Value,
  path: List(PathSegment),
) -> Result(ParsedSchema, DocumentError) {
  case alternatives {
    value.Array([left, right]) -> {
      let left_path = append_path(path, Index(0))
      let right_path = append_path(path, Index(1))
      use left_fields <- bind(object_fields(left, left_path))
      use right_fields <- bind(object_fields(right, right_path))
      case is_null_schema(left_fields), is_null_schema(right_fields) {
        True, False -> {
          use parsed <- bind(parse_schema(right, right_path))
          Ok(ParsedSchema(
            blueprint.NullableSchema(parsed.schema),
            parsed.invariants,
          ))
        }
        False, True -> {
          use parsed <- bind(parse_schema(left, left_path))
          Ok(ParsedSchema(
            blueprint.NullableSchema(parsed.schema),
            parsed.invariants,
          ))
        }
        _, _ -> Error(UnsupportedDocument(path, ArbitraryUnion))
      }
    }
    value.Array(_) -> Error(UnsupportedDocument(path, ArbitraryUnion))
    _ -> Error(MalformedDocument(path, ExpectedArray))
  }
}

fn is_null_schema(fields: List(#(String, value.Value))) -> Bool {
  case fields {
    [#("type", value.Text("null"))] -> True
    _ -> False
  }
}

fn parse_tagged(
  alternatives: value.Value,
  path: List(PathSegment),
) -> Result(ParsedSchema, DocumentError) {
  case alternatives {
    value.Array([left, right]) -> {
      let left_path = append_path(path, Index(0))
      let right_path = append_path(path, Index(1))
      use parsed_left <- bind(parse_tagged_alternative(left, left_path))
      use parsed_right <- bind(parse_tagged_alternative(right, right_path))
      let duplicate = case parsed_left.0 == parsed_right.0 {
        True -> [
          InvariantLocation(
            runtime.DuplicateSchemaTag(parsed_left.0),
            append_path(
              append_path(
                append_path(right_path, Property("properties")),
                Property("tag"),
              ),
              Property("const"),
            ),
          ),
        ]
        False -> []
      }
      Ok(ParsedSchema(
        blueprint.TaggedSchema(
          parsed_left.0,
          parsed_left.1.schema,
          parsed_right.0,
          parsed_right.1.schema,
        ),
        append_locations(
          duplicate,
          append_locations(parsed_left.1.invariants, parsed_right.1.invariants),
        ),
      ))
    }
    value.Array(_) -> Error(MalformedDocument(path, InvalidTaggedAlternatives))
    _ -> Error(MalformedDocument(path, ExpectedArray))
  }
}

fn parse_tagged_alternative(
  alternative: value.Value,
  path: List(PathSegment),
) -> Result(#(String, ParsedSchema), DocumentError) {
  use fields <- bind(object_fields(alternative, path))
  use _ <- bind(only_fields(
    fields,
    ["type", "properties", "required", "additionalProperties"],
    path,
  ))
  use kind <- bind(required_field(fields, "type", path))
  use _ <- bind(check_object_kind(kind, append_path(path, Property("type"))))
  use properties_value <- bind(required_field(fields, "properties", path))
  use required_value <- bind(required_field(fields, "required", path))
  use additional <- bind(required_field(fields, "additionalProperties", path))
  use _ <- bind(check_closed_object(
    additional,
    append_path(path, Property("additionalProperties")),
  ))
  let properties_path = append_path(path, Property("properties"))
  use properties <- bind(object_fields(properties_value, properties_path))
  use required <- bind(required_names(
    required_value,
    append_path(path, Property("required")),
  ))
  use _ <- bind(check_declared_required(
    required,
    properties,
    append_path(path, Property("required")),
    0,
  ))
  case lookup(properties, "tag"), lookup(properties, "value") {
    Something(tag_schema), Something(payload_schema) -> {
      use _ <- bind(check_tag_properties(properties, path))
      use _ <- bind(check_tag_required(
        required,
        append_path(path, Property("required")),
      ))
      let tag_path = append_path(properties_path, Property("tag"))
      let payload_path = append_path(properties_path, Property("value"))
      use tag_fields <- bind(object_fields(tag_schema, tag_path))
      use _ <- bind(only_fields(tag_fields, ["const"], tag_path))
      use tag_value <- bind(required_field(tag_fields, "const", tag_path))
      use tag <- bind(expect_text(
        tag_value,
        append_path(tag_path, Property("const")),
      ))
      use parsed_payload <- bind(parse_schema(payload_schema, payload_path))
      Ok(#(tag, parsed_payload))
    }
    _, _ -> Error(MalformedDocument(properties_path, ExpectedClosedTag))
  }
}

fn check_tag_required(
  required: List(String),
  path: List(PathSegment),
) -> Result(Nil, DocumentError) {
  case
    contains(required, "tag"),
    contains(required, "value"),
    list_length(required)
  {
    True, True, 2 -> Ok(Nil)
    _, _, _ -> Error(MalformedDocument(path, InvalidTaggedAlternatives))
  }
}

fn check_tag_properties(
  properties: List(#(String, value.Value)),
  path: List(PathSegment),
) -> Result(Nil, DocumentError) {
  case list_length(properties) {
    2 -> Ok(Nil)
    _ -> Error(UnsupportedDocument(path, UnsupportedTaggedShape))
  }
}

fn check_object_kind(
  kind: value.Value,
  path: List(PathSegment),
) -> Result(Nil, DocumentError) {
  case kind {
    value.Text("object") -> Ok(Nil)
    _ -> Error(MalformedDocument(path, ExpectedObjectSchema))
  }
}

fn check_closed_object(
  additional: value.Value,
  path: List(PathSegment),
) -> Result(Nil, DocumentError) {
  case additional {
    value.Bool(False) -> Ok(Nil)
    value.Bool(True) -> Error(UnsupportedDocument(path, OpenObject))
    _ -> Error(MalformedDocument(path, ExpectedBoolean))
  }
}

fn required_names(
  value: value.Value,
  path: List(PathSegment),
) -> Result(List(String), DocumentError) {
  case value {
    value.Array(items) -> parse_required_names(items, path, 0, [])
    _ -> Error(MalformedDocument(path, ExpectedArray))
  }
}

fn parse_required_names(
  items: List(value.Value),
  path: List(PathSegment),
  index: Int,
  seen: List(String),
) -> Result(List(String), DocumentError) {
  case items {
    [] -> Ok(reverse(seen))
    [value.Text(name), ..rest] -> {
      let item_path = append_path(path, Index(index))
      case contains(seen, name) {
        True -> Error(MalformedDocument(item_path, DuplicateRequiredName(name)))
        False -> {
          parse_required_names(rest, path, index + 1, [name, ..seen])
        }
      }
    }
    [_, ..] ->
      Error(MalformedDocument(append_path(path, Index(index)), ExpectedText))
  }
}

fn check_declared_required(
  required: List(String),
  properties: List(#(String, value.Value)),
  path: List(PathSegment),
  index: Int,
) -> Result(Nil, DocumentError) {
  case required {
    [] -> Ok(Nil)
    [name, ..rest] ->
      case has_key(properties, name) {
        True -> check_declared_required(rest, properties, path, index + 1)
        False ->
          Error(MalformedDocument(
            append_path(path, Index(index)),
            UndeclaredRequiredName(name),
          ))
      }
  }
}

fn expect_integer(
  value: value.Value,
  path: List(PathSegment),
) -> Result(Int, DocumentError) {
  case value {
    value.Int(integer) -> Ok(integer)
    _ -> Error(MalformedDocument(path, ExpectedInteger))
  }
}

fn expect_text(
  value: value.Value,
  path: List(PathSegment),
) -> Result(String, DocumentError) {
  case value {
    value.Text(text) -> Ok(text)
    _ -> Error(MalformedDocument(path, ExpectedText))
  }
}

fn object_fields(
  value: value.Value,
  path: List(PathSegment),
) -> Result(List(#(String, value.Value)), DocumentError) {
  case value {
    value.Object(fields) -> check_duplicate_keys(fields, path, [])
    _ -> Error(MalformedDocument(path, ExpectedObject))
  }
}

fn check_duplicate_keys(
  fields: List(#(String, value.Value)),
  path: List(PathSegment),
  seen: List(String),
) -> Result(List(#(String, value.Value)), DocumentError) {
  case fields {
    [] -> Ok([])
    [#(name, value), ..rest] -> {
      let key_path = append_path(path, Property(name))
      case contains(seen, name) {
        True -> Error(MalformedDocument(key_path, DuplicateKey(name)))
        False -> {
          use checked <- bind(check_duplicate_keys(rest, path, [name, ..seen]))
          Ok([#(name, value), ..checked])
        }
      }
    }
  }
}

fn only_fields(
  fields: List(#(String, value.Value)),
  allowed: List(String),
  path: List(PathSegment),
) -> Result(Nil, DocumentError) {
  case fields {
    [] -> Ok(Nil)
    [#("$schema", _), ..] ->
      Error(UnsupportedDocument(
        append_path(path, Property("$schema")),
        NestedDialect,
      ))
    [#(name, _), ..rest] ->
      case contains(allowed, name) {
        True -> only_fields(rest, allowed, path)
        False ->
          Error(UnsupportedDocument(
            append_path(path, Property(name)),
            UnsupportedKeyword(name),
          ))
      }
  }
}

fn required_field(
  fields: List(#(String, value.Value)),
  name: String,
  path: List(PathSegment),
) -> Result(value.Value, DocumentError) {
  case lookup(fields, name) {
    Something(value) -> Ok(value)
    Nothing ->
      Error(MalformedDocument(
        append_path(path, Property(name)),
        MissingField(name),
      ))
  }
}

fn lookup(
  fields: List(#(String, value.Value)),
  name: String,
) -> Maybe(value.Value) {
  case fields {
    [] -> Nothing
    [#(key, value), ..rest] ->
      case key == name {
        True -> Something(value)
        False -> lookup(rest, name)
      }
  }
}

fn without_field(
  fields: List(#(String, value.Value)),
  name: String,
) -> List(#(String, value.Value)) {
  case fields {
    [] -> []
    [#(key, value), ..rest] ->
      case key == name {
        True -> without_field(rest, name)
        False -> [#(key, value), ..without_field(rest, name)]
      }
  }
}

fn has_key(fields: List(#(String, value.Value)), name: String) -> Bool {
  case fields {
    [] -> False
    [#(key, _), ..rest] -> key == name || has_key(rest, name)
  }
}

fn contains(items: List(String), name: String) -> Bool {
  case items {
    [] -> False
    [head, ..rest] -> head == name || contains(rest, name)
  }
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
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

fn append_path(
  path: List(PathSegment),
  segment: PathSegment,
) -> List(PathSegment) {
  case path {
    [] -> [segment]
    [head, ..rest] -> [head, ..append_path(rest, segment)]
  }
}

fn append_locations(
  left: List(InvariantLocation),
  right: List(InvariantLocation),
) -> List(InvariantLocation) {
  case left {
    [] -> right
    [head, ..rest] -> [head, ..append_locations(rest, right)]
  }
}

fn invariant_path(
  reason: runtime.ContractError,
  locations: List(InvariantLocation),
) -> List(PathSegment) {
  case locations {
    [] -> []
    [InvariantLocation(candidate, path), ..rest] ->
      case same_contract_error(reason, candidate) {
        True -> path
        False -> invariant_path(reason, rest)
      }
  }
}

fn same_contract_error(
  left: runtime.ContractError,
  right: runtime.ContractError,
) -> Bool {
  case left, right {
    runtime.UnknownSchema, runtime.UnknownSchema -> True
    runtime.ReversedIntegerRange(left_min, left_max),
      runtime.ReversedIntegerRange(right_min, right_max)
    -> left_min == right_min && left_max == right_max
    runtime.DuplicateSchemaProperty(left_name),
      runtime.DuplicateSchemaProperty(right_name)
    -> left_name == right_name
    runtime.DuplicateSchemaTag(left_tag), runtime.DuplicateSchemaTag(right_tag)
    -> left_tag == right_tag
    runtime.EmptyStringEnum, runtime.EmptyStringEnum -> True
    runtime.DuplicateSchemaEnumLabel(left_label),
      runtime.DuplicateSchemaEnumLabel(right_label)
    -> left_label == right_label
    _, _ -> False
  }
}

fn bind(
  result: Result(a, DocumentError),
  next: fn(a) -> Result(b, DocumentError),
) -> Result(b, DocumentError) {
  case result {
    Error(error) -> Error(error)
    Ok(value) -> next(value)
  }
}
