// THROWAWAY: Can a finite runtime schema validate Values without producing a Codec?
import lab/blueprint
import lab/value.{type Value}

@external(erlang, "blueprint_runtime_ffi", "string_less")
fn string_less(left: String, right: String) -> Bool

pub opaque type RuntimeContract {
  RuntimeContract(schema: blueprint.Schema)
}

pub opaque type ValidatedValue {
  ValidatedValue(value: Value, schema: blueprint.Schema)
}

pub type ContractError {
  UnknownSchema
  ReversedIntegerRange(minimum: Int, maximum: Int)
  DuplicateSchemaProperty(String)
  DuplicateSchemaTag(String)
}

pub fn from_schema(
  schema: blueprint.Schema,
) -> Result(RuntimeContract, ContractError) {
  case normalize(schema) {
    Error(error) -> Error(error)
    Ok(normalized) -> Ok(RuntimeContract(normalized))
  }
}

pub fn from_codec(
  codec: blueprint.Codec(a),
) -> Result(RuntimeContract, ContractError) {
  case blueprint.schema(codec) {
    Error(blueprint.UnknownSchema) -> Error(UnknownSchema)
    Ok(schema) -> from_schema(schema)
  }
}

pub fn schema(contract: RuntimeContract) -> blueprint.Schema {
  contract.schema
}

pub fn validate(
  contract: RuntimeContract,
  value: Value,
) -> Result(ValidatedValue, ValidationError) {
  case validate_at(contract.schema, value, []) {
    Error(error) -> Error(error)
    Ok(Nil) -> Ok(ValidatedValue(value, contract.schema))
  }
}

pub fn encoded(value: ValidatedValue) -> Value {
  value.value
}

pub fn matches(contract: RuntimeContract, value: ValidatedValue) -> Bool {
  contract.schema == value.schema
}

pub fn same_schema(left: RuntimeContract, right: RuntimeContract) -> Bool {
  left.schema == right.schema
}

pub type PathSegment {
  Property(String)
  Index(Int)
  TaggedBranch(String)
}

pub type ValidationReason {
  ExpectedText
  ExpectedInteger
  ExpectedBoolean
  ExpectedArray
  ExpectedObject
  MissingProperty(String)
  UnknownProperty(String)
  DuplicateProperty(String)
  WrongTupleLength(expected: Int, actual: Int)
  IntegerOutsideRange(minimum: Int, maximum: Int, actual: Int)
  MissingTag
  NonTextTag
  UnknownTag(String)
}

pub type ValidationError {
  ValidationError(path: List(PathSegment), reason: ValidationReason)
}

type Maybe(a) {
  Nothing
  Something(a)
}

fn normalize(
  schema: blueprint.Schema,
) -> Result(blueprint.Schema, ContractError) {
  case schema {
    blueprint.TextSchema -> Ok(blueprint.TextSchema)
    blueprint.IntSchema -> Ok(blueprint.IntSchema)
    blueprint.BoolSchema -> Ok(blueprint.BoolSchema)
    blueprint.PairSchema(left, right) -> {
      use normalized_left <- bind(normalize(left))
      use normalized_right <- bind(normalize(right))
      Ok(blueprint.PairSchema(normalized_left, normalized_right))
    }
    blueprint.FieldSchema(name, inner) -> {
      use normalized_inner <- bind(normalize(inner))
      Ok(
        blueprint.ObjectSchema([
          blueprint.PropertySchema(name, True, normalized_inner),
        ]),
      )
    }
    blueprint.ListSchema(inner) -> {
      use normalized <- bind(normalize(inner))
      Ok(blueprint.ListSchema(normalized))
    }
    blueprint.NullableSchema(inner) -> {
      use normalized <- bind(normalize(inner))
      Ok(blueprint.NullableSchema(normalized))
    }
    blueprint.ObjectSchema(properties) -> normalize_object(properties)
    blueprint.TaggedSchema(left_tag, left, right_tag, right) ->
      normalize_tagged(left_tag, left, right_tag, right)
    blueprint.IntegerRangeSchema(minimum, maximum) ->
      case minimum <= maximum {
        True -> Ok(blueprint.IntegerRangeSchema(minimum, maximum))
        False -> Error(ReversedIntegerRange(minimum, maximum))
      }
  }
}

fn normalize_object(
  properties: List(blueprint.PropertySchema),
) -> Result(blueprint.Schema, ContractError) {
  case duplicate_schema_property(properties, []) {
    Something(name) -> Error(DuplicateSchemaProperty(name))
    Nothing -> {
      use normalized <- bind(normalize_properties(properties))
      Ok(blueprint.ObjectSchema(sort_properties(normalized)))
    }
  }
}

fn normalize_properties(
  properties: List(blueprint.PropertySchema),
) -> Result(List(blueprint.PropertySchema), ContractError) {
  case properties {
    [] -> Ok([])
    [blueprint.PropertySchema(name, required, schema), ..rest] -> {
      use normalized_schema <- bind(normalize(schema))
      use normalized_rest <- bind(normalize_properties(rest))
      Ok([
        blueprint.PropertySchema(name, required, normalized_schema),
        ..normalized_rest
      ])
    }
  }
}

fn duplicate_schema_property(
  properties: List(blueprint.PropertySchema),
  seen: List(String),
) -> Maybe(String) {
  case properties {
    [] -> Nothing
    [blueprint.PropertySchema(name, _, _), ..rest] ->
      case contains_string(seen, name) {
        True -> Something(name)
        False -> duplicate_schema_property(rest, [name, ..seen])
      }
  }
}

fn sort_properties(
  properties: List(blueprint.PropertySchema),
) -> List(blueprint.PropertySchema) {
  case properties {
    [] -> []
    [property, ..rest] -> insert_property(property, sort_properties(rest))
  }
}

fn insert_property(
  property: blueprint.PropertySchema,
  sorted: List(blueprint.PropertySchema),
) -> List(blueprint.PropertySchema) {
  case sorted {
    [] -> [property]
    [blueprint.PropertySchema(head_name, _, _) as head, ..tail] ->
      // Duplicate names are rejected first, so the property's leading field is
      // a unique ordering key for the complete normalized entry.
      case string_less(property_name(property), head_name) {
        True -> [property, ..sorted]
        False -> [head, ..insert_property(property, tail)]
      }
  }
}

fn property_name(property: blueprint.PropertySchema) -> String {
  let blueprint.PropertySchema(name, _, _) = property
  name
}

fn normalize_tagged(
  left_tag: String,
  left: blueprint.Schema,
  right_tag: String,
  right: blueprint.Schema,
) -> Result(blueprint.Schema, ContractError) {
  case left_tag == right_tag {
    True -> Error(DuplicateSchemaTag(left_tag))
    False -> {
      use normalized_left <- bind(normalize(left))
      use normalized_right <- bind(normalize(right))
      case string_less(left_tag, right_tag) {
        True ->
          Ok(blueprint.TaggedSchema(
            left_tag,
            normalized_left,
            right_tag,
            normalized_right,
          ))
        False ->
          Ok(blueprint.TaggedSchema(
            right_tag,
            normalized_right,
            left_tag,
            normalized_left,
          ))
      }
    }
  }
}

fn validate_at(
  schema: blueprint.Schema,
  value: Value,
  path: List(PathSegment),
) -> Result(Nil, ValidationError) {
  case schema, value {
    blueprint.TextSchema, value.Text(_) -> Ok(Nil)
    blueprint.TextSchema, _ -> invalid(path, ExpectedText)
    blueprint.IntSchema, value.Int(_) -> Ok(Nil)
    blueprint.IntSchema, _ -> invalid(path, ExpectedInteger)
    blueprint.BoolSchema, value.Bool(_) -> Ok(Nil)
    blueprint.BoolSchema, _ -> invalid(path, ExpectedBoolean)
    blueprint.IntegerRangeSchema(minimum, maximum), value.Int(actual)
      if actual >= minimum && actual <= maximum
    -> Ok(Nil)
    blueprint.IntegerRangeSchema(minimum, maximum), value.Int(actual) ->
      invalid(path, IntegerOutsideRange(minimum, maximum, actual))
    blueprint.IntegerRangeSchema(_, _), _ -> invalid(path, ExpectedInteger)
    blueprint.PairSchema(first_schema, second_schema),
      value.Array([first, second])
    -> {
      use _ <- bind_validation(validate_at(
        first_schema,
        first,
        extend(path, Index(0)),
      ))
      validate_at(second_schema, second, extend(path, Index(1)))
    }
    blueprint.PairSchema(_, _), value.Array(items) ->
      invalid(path, WrongTupleLength(2, list_length(items)))
    blueprint.PairSchema(_, _), _ -> invalid(path, ExpectedArray)
    blueprint.ListSchema(inner), value.Array(items) ->
      validate_items(inner, items, 0, path)
    blueprint.ListSchema(_), _ -> invalid(path, ExpectedArray)
    blueprint.NullableSchema(_), value.Null -> Ok(Nil)
    blueprint.NullableSchema(inner), _ -> validate_at(inner, value, path)
    blueprint.ObjectSchema(properties), value.Object(fields) ->
      validate_object(properties, fields, path)
    blueprint.ObjectSchema(_), _ -> invalid(path, ExpectedObject)
    blueprint.TaggedSchema(left_tag, left, right_tag, right),
      value.Object(fields)
    -> validate_tagged_value(left_tag, left, right_tag, right, fields, path)
    blueprint.TaggedSchema(_, _, _, _), _ -> invalid(path, ExpectedObject)
    blueprint.FieldSchema(_, _), _ ->
      // Contracts normalize every field schema before validation.
      invalid(path, ExpectedObject)
  }
}

fn validate_items(
  schema: blueprint.Schema,
  items: List(Value),
  index: Int,
  path: List(PathSegment),
) -> Result(Nil, ValidationError) {
  case items {
    [] -> Ok(Nil)
    [item, ..rest] -> {
      use _ <- bind_validation(validate_at(
        schema,
        item,
        extend(path, Index(index)),
      ))
      validate_items(schema, rest, index + 1, path)
    }
  }
}

fn validate_object(
  properties: List(blueprint.PropertySchema),
  fields: List(#(String, Value)),
  path: List(PathSegment),
) -> Result(Nil, ValidationError) {
  case duplicate_field(fields, []) {
    Something(name) ->
      invalid(extend(path, Property(name)), DuplicateProperty(name))
    Nothing ->
      case unknown_field(fields, properties) {
        Something(name) ->
          invalid(extend(path, Property(name)), UnknownProperty(name))
        Nothing -> validate_properties(properties, fields, path)
      }
  }
}

fn validate_properties(
  properties: List(blueprint.PropertySchema),
  fields: List(#(String, Value)),
  path: List(PathSegment),
) -> Result(Nil, ValidationError) {
  case properties {
    [] -> Ok(Nil)
    [blueprint.PropertySchema(name, required, schema), ..rest] ->
      case lookup(fields, name) {
        Nothing if required ->
          invalid(extend(path, Property(name)), MissingProperty(name))
        Nothing -> validate_properties(rest, fields, path)
        Something(value) -> {
          use _ <- bind_validation(validate_at(
            schema,
            value,
            extend(path, Property(name)),
          ))
          validate_properties(rest, fields, path)
        }
      }
  }
}

fn validate_tagged_value(
  left_tag: String,
  left: blueprint.Schema,
  right_tag: String,
  right: blueprint.Schema,
  fields: List(#(String, Value)),
  path: List(PathSegment),
) -> Result(Nil, ValidationError) {
  case duplicate_field(fields, []) {
    Something(name) ->
      invalid(extend(path, Property(name)), DuplicateProperty(name))
    Nothing ->
      case unknown_tagged_field(fields) {
        Something(name) ->
          invalid(extend(path, Property(name)), UnknownProperty(name))
        Nothing ->
          case lookup(fields, "tag") {
            Nothing -> invalid(extend(path, Property("tag")), MissingTag)
            Something(value.Text(tag)) -> {
              let payload_schema = case tag {
                _ if tag == left_tag -> Something(left)
                _ if tag == right_tag -> Something(right)
                _ -> Nothing
              }
              case payload_schema {
                Nothing ->
                  invalid(extend(path, Property("tag")), UnknownTag(tag))
                Something(schema) ->
                  case lookup(fields, "value") {
                    Nothing ->
                      invalid(
                        extend(
                          extend(path, Property("value")),
                          TaggedBranch(tag),
                        ),
                        MissingProperty("value"),
                      )
                    Something(payload) ->
                      validate_at(
                        schema,
                        payload,
                        extend(
                          extend(path, Property("value")),
                          TaggedBranch(tag),
                        ),
                      )
                  }
              }
            }
            Something(_) -> invalid(extend(path, Property("tag")), NonTextTag)
          }
      }
  }
}

fn unknown_tagged_field(fields: List(#(String, Value))) -> Maybe(String) {
  case fields {
    [] -> Nothing
    [#(key, _), ..rest] ->
      case key == "tag" || key == "value" {
        True -> unknown_tagged_field(rest)
        False -> Something(key)
      }
  }
}

fn duplicate_field(
  fields: List(#(String, Value)),
  seen: List(String),
) -> Maybe(String) {
  case fields {
    [] -> Nothing
    [#(key, _), ..rest] ->
      case contains_string(seen, key) {
        True -> Something(key)
        False -> duplicate_field(rest, [key, ..seen])
      }
  }
}

fn unknown_field(
  fields: List(#(String, Value)),
  properties: List(blueprint.PropertySchema),
) -> Maybe(String) {
  case fields {
    [] -> Nothing
    [#(key, _), ..rest] ->
      case has_property(properties, key) {
        True -> unknown_field(rest, properties)
        False -> Something(key)
      }
  }
}

fn has_property(
  properties: List(blueprint.PropertySchema),
  name: String,
) -> Bool {
  case properties {
    [] -> False
    [blueprint.PropertySchema(property, _, _), ..rest] ->
      property == name || has_property(rest, name)
  }
}

fn lookup(fields: List(#(String, Value)), name: String) -> Maybe(Value) {
  case fields {
    [] -> Nothing
    [#(key, value), ..rest] ->
      case key == name {
        True -> Something(value)
        False -> lookup(rest, name)
      }
  }
}

fn contains_string(items: List(String), name: String) -> Bool {
  case items {
    [] -> False
    [head, ..rest] -> head == name || contains_string(rest, name)
  }
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

fn extend(path: List(PathSegment), segment: PathSegment) -> List(PathSegment) {
  case path {
    [] -> [segment]
    [head, ..rest] -> [head, ..extend(rest, segment)]
  }
}

fn invalid(
  path: List(PathSegment),
  reason: ValidationReason,
) -> Result(Nil, ValidationError) {
  Error(ValidationError(path, reason))
}

fn bind(
  result: Result(a, ContractError),
  next: fn(a) -> Result(b, ContractError),
) -> Result(b, ContractError) {
  case result {
    Error(error) -> Error(error)
    Ok(value) -> next(value)
  }
}

fn bind_validation(
  result: Result(a, ValidationError),
  next: fn(a) -> Result(b, ValidationError),
) -> Result(b, ValidationError) {
  case result {
    Error(error) -> Error(error)
    Ok(value) -> next(value)
  }
}
