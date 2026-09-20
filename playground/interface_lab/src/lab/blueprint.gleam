// THROWAWAY: Can one bidirectional codec serve independent adapters?
import lab/value.{type Value}

pub type EncodeError {
  CannotEncode(String)
  EncodeAtField(String, EncodeError)
  EncodeAtIndex(Int, EncodeError)
}

pub type DecodeError {
  CannotDecode(String)
  DecodeAtField(String, DecodeError)
  DecodeAtIndex(Int, DecodeError)
}

// Total maps do not prove that caller-supplied mappings are inverse functions.
// This preserves a codec representation; it does not certify schema agreement.
pub fn imap(codec: Codec(a), from: fn(a) -> b, to: fn(b) -> a) -> Codec(b) {
  let mapped =
    new(fn(value) { encode(codec, to(value)) }, fn(raw) {
      case decode(codec, raw) {
        Ok(value) -> Ok(from(value))
        Error(error) -> Error(error)
      }
    })
  Codec(..mapped, schema: codec.schema)
}

pub fn pair(left: Codec(a), right: Codec(b)) -> Codec(#(a, b)) {
  let paired =
    new(
      fn(pair: #(a, b)) {
        case encode(left, pair.0) {
          Error(error) -> Error(EncodeAtIndex(0, error))
          Ok(a) ->
            case encode(right, pair.1) {
              Error(error) -> Error(EncodeAtIndex(1, error))
              Ok(b) -> Ok(value.Array([a, b]))
            }
        }
      },
      fn(raw) {
        case raw {
          value.Array([a, b]) ->
            case decode(left, a) {
              Error(error) -> Error(DecodeAtIndex(0, error))
              Ok(a) ->
                case decode(right, b) {
                  Error(error) -> Error(DecodeAtIndex(1, error))
                  Ok(b) -> Ok(#(a, b))
                }
            }
          _ -> Error(CannotDecode("Expected a two-element array"))
        }
      },
    )
  let description = case left.schema, right.schema {
    Ok(a), Ok(b) -> Ok(PairSchema(a, b))
    Error(error), _ -> Error(error)
    _, Error(error) -> Error(error)
  }
  Codec(..paired, schema: description)
}

// This deliberately does not claim JSON Schema agreement or codec roundtrip laws.
pub opaque type Codec(a) {
  Codec(
    encoder: fn(a) -> Result(Value, EncodeError),
    decoder: fn(Value) -> Result(a, DecodeError),
    schema: Result(Schema, SchemaError),
  )
}

pub fn new(
  encode: fn(a) -> Result(Value, EncodeError),
  decode: fn(Value) -> Result(a, DecodeError),
) -> Codec(a) {
  Codec(encode, decode, Error(UnknownSchema))
}

pub fn encode(codec: Codec(a), item: a) -> Result(Value, EncodeError) {
  codec.encoder(item)
}

pub fn decode(codec: Codec(a), item: Value) -> Result(a, DecodeError) {
  codec.decoder(item)
}

pub fn text() -> Codec(String) {
  let codec =
    new(fn(s) { Ok(value.Text(s)) }, fn(v) {
      case v {
        value.Text(s) -> Ok(s)
        _ -> Error(CannotDecode("Expected text"))
      }
    })
  Codec(..codec, schema: Ok(TextSchema))
}

pub fn int() -> Codec(Int) {
  let codec =
    new(fn(n) { Ok(value.Int(n)) }, fn(v) {
      case v {
        value.Int(n) -> Ok(n)
        _ -> Error(CannotDecode("Expected integer"))
      }
    })
  Codec(..codec, schema: Ok(IntSchema))
}

pub fn bool() -> Codec(Bool) {
  let codec =
    new(fn(b) { Ok(value.Bool(b)) }, fn(v) {
      case v {
        value.Bool(b) -> Ok(b)
        _ -> Error(CannotDecode("Expected boolean"))
      }
    })
  Codec(..codec, schema: Ok(BoolSchema))
}

// Only supported constructors can attach this description to a Codec.
// This is the accepted wire shape, not a proof of native roundtrip laws.
pub type Schema {
  TextSchema
  IntSchema
  BoolSchema
  PairSchema(Schema, Schema)
  FieldSchema(String, Schema)
  ListSchema(Schema)
  NullableSchema(Schema)
  ObjectSchema(List(PropertySchema))
}

pub type PropertySchema {
  PropertySchema(name: String, required: Bool, schema: Schema)
}

pub type SchemaError {
  UnknownSchema
}

pub fn schema(codec: Codec(a)) -> Result(Schema, SchemaError) {
  codec.schema
}

// Draft 2020-12 fragment. Full JSON parsing and dialect negotiation are outside
// this prototype. In particular Value has no floating-point number variant.
pub fn schema_value(schema: Schema) -> Value {
  case schema {
    ObjectSchema(properties) ->
      value.Object([
        #("type", value.Text("object")),
        #("properties", value.Object(property_schemas(properties))),
        #("required", value.Array(required_names(properties))),
        #("additionalProperties", value.Bool(False)),
      ])
    TextSchema -> value.Object([#("type", value.Text("string"))])
    IntSchema -> value.Object([#("type", value.Text("integer"))])
    BoolSchema -> value.Object([#("type", value.Text("boolean"))])
    ListSchema(inner) ->
      value.Object([
        #("type", value.Text("array")),
        #("items", schema_value(inner)),
      ])
    NullableSchema(inner) ->
      value.Object([
        #(
          "anyOf",
          value.Array([
            value.Object([#("type", value.Text("null"))]),
            schema_value(inner),
          ]),
        ),
      ])
    FieldSchema(name, inner) ->
      value.Object([
        #("type", value.Text("object")),
        #("properties", value.Object([#(name, schema_value(inner))])),
        #("required", value.Array([value.Text(name)])),
        #("additionalProperties", value.Bool(False)),
      ])
    PairSchema(a, b) ->
      value.Object([
        #("type", value.Text("array")),
        #("prefixItems", value.Array([schema_value(a), schema_value(b)])),
        #("minItems", value.Int(2)),
        #("maxItems", value.Int(2)),
      ])
  }
}

// A closed one-field object can describe protocol inputs without erasing a.
pub fn field(name: String, inner: Codec(a)) -> Codec(a) {
  let codec = object(required(name, inner))
  let description = case inner.schema {
    Ok(schema) -> Ok(FieldSchema(name, schema))
    Error(error) -> Error(error)
  }
  Codec(..codec, schema: description)
}

pub fn schema_document(schema: Schema) -> Value {
  let assert value.Object(fields) = schema_value(schema)
  value.Object([
    #("$schema", value.Text("https://json-schema.org/draft/2020-12/schema")),
    ..fields
  ])
}

pub type Nullable(a) {
  Null
  NonNull(a)
}

// Null is a wire value. Missing object properties are a separate concern.
pub fn nullable(inner: Codec(a)) -> Codec(Nullable(a)) {
  let codec =
    new(
      fn(item) {
        case item {
          Null -> Ok(value.Null)
          NonNull(item) ->
            case encode(inner, item) {
              Ok(value.Null) ->
                Error(CannotEncode("NonNull must encode a non-null value"))
              other -> other
            }
        }
      },
      fn(raw) {
        case raw {
          value.Null -> Ok(Null)
          _ ->
            case decode(inner, raw) {
              Ok(item) -> Ok(NonNull(item))
              Error(error) -> Error(error)
            }
        }
      },
    )
  let description = case inner.schema {
    Ok(schema) -> Ok(NullableSchema(schema))
    Error(error) -> Error(error)
  }
  Codec(..codec, schema: description)
}

pub fn list(inner: Codec(a)) -> Codec(List(a)) {
  let codec =
    new(
      fn(items) {
        case encode_items(inner, items, 0) {
          Ok(items) -> Ok(value.Array(items))
          Error(error) -> Error(error)
        }
      },
      fn(raw) {
        case raw {
          value.Array(items) -> decode_items(inner, items, 0)
          _ -> Error(CannotDecode("Expected array"))
        }
      },
    )
  let description = case inner.schema {
    Ok(schema) -> Ok(ListSchema(schema))
    Error(error) -> Error(error)
  }
  Codec(..codec, schema: description)
}

fn encode_items(
  codec: Codec(a),
  items: List(a),
  index: Int,
) -> Result(List(Value), EncodeError) {
  case items {
    [] -> Ok([])
    [item, ..rest] ->
      case encode(codec, item) {
        Error(error) -> Error(EncodeAtIndex(index, error))
        Ok(raw) ->
          case encode_items(codec, rest, index + 1) {
            Ok(rest) -> Ok([raw, ..rest])
            Error(error) -> Error(error)
          }
      }
  }
}

fn decode_items(
  codec: Codec(a),
  items: List(Value),
  index: Int,
) -> Result(List(a), DecodeError) {
  case items {
    [] -> Ok([])
    [item, ..rest] ->
      case decode(codec, item) {
        Error(error) -> Error(DecodeAtIndex(index, error))
        Ok(decoded) ->
          case decode_items(codec, rest, index + 1) {
            Ok(rest) -> Ok([decoded, ..rest])
            Error(error) -> Error(error)
          }
      }
  }
}

pub type Optional(a) {
  Missing
  Present(a)
}

pub type PropertyError {
  DuplicateProperty(String)
}

pub opaque type Properties(a) {
  Properties(
    encode: fn(a) -> Result(List(#(String, Value)), EncodeError),
    decode: fn(List(#(String, Value))) -> Result(a, DecodeError),
    names: List(String),
    schemas: Result(List(PropertySchema), SchemaError),
  )
}

pub fn empty() -> Properties(Nil) {
  Properties(fn(_) { Ok([]) }, fn(_) { Ok(Nil) }, [], Ok([]))
}

pub fn required(name: String, codec: Codec(a)) -> Properties(a) {
  Properties(
    fn(item) { encode_property(name, codec, item) },
    fn(fields) {
      case lookup(fields, name) {
        Missing ->
          Error(DecodeAtField(name, CannotDecode("Missing required property")))
        Present(raw) -> decode_property(name, codec, raw)
      }
    },
    [name],
    property_description(name, True, codec),
  )
}

pub fn optional(name: String, codec: Codec(a)) -> Properties(Optional(a)) {
  Properties(
    fn(item) {
      case item {
        Missing -> Ok([])
        Present(item) -> encode_property(name, codec, item)
      }
    },
    fn(fields) {
      case lookup(fields, name) {
        Missing -> Ok(Missing)
        Present(raw) ->
          case decode_property(name, codec, raw) {
            Ok(item) -> Ok(Present(item))
            Error(error) -> Error(error)
          }
      }
    },
    [name],
    property_description(name, False, codec),
  )
}

pub fn combine(
  left: Properties(a),
  right: Properties(b),
) -> Result(Properties(#(a, b)), PropertyError) {
  case overlap(left.names, right.names) {
    Present(name) -> Error(DuplicateProperty(name))
    Missing ->
      Ok(
        Properties(
          fn(items: #(a, b)) {
            case left.encode(items.0) {
              Error(error) -> Error(error)
              Ok(a) ->
                case right.encode(items.1) {
                  Error(error) -> Error(error)
                  Ok(b) -> Ok(append(a, b))
                }
            }
          },
          fn(fields) {
            case left.decode(fields) {
              Error(error) -> Error(error)
              Ok(a) ->
                case right.decode(fields) {
                  Error(error) -> Error(error)
                  Ok(b) -> Ok(#(a, b))
                }
            }
          },
          append(left.names, right.names),
          case left.schemas, right.schemas {
            Ok(a), Ok(b) -> Ok(append(a, b))
            Error(error), _ -> Error(error)
            _, Error(error) -> Error(error)
          },
        ),
      )
  }
}

// The complete object boundary owns unknown/duplicate-key checks exactly once.
pub fn object(properties: Properties(a)) -> Codec(a) {
  Codec(
    fn(item) {
      case properties.encode(item) {
        Ok(fields) -> Ok(value.Object(fields))
        Error(error) -> Error(error)
      }
    },
    fn(raw) {
      case raw {
        value.Object(fields) ->
          case check_keys(fields, properties.names, []) {
            Ok(Nil) -> properties.decode(fields)
            Error(error) -> Error(error)
          }
        _ -> Error(CannotDecode("Expected object"))
      }
    },
    case properties.schemas {
      Ok(properties) -> Ok(ObjectSchema(properties))
      Error(error) -> Error(error)
    },
  )
}

fn property_description(
  name: String,
  required: Bool,
  codec: Codec(a),
) -> Result(List(PropertySchema), SchemaError) {
  case codec.schema {
    Ok(schema) -> Ok([PropertySchema(name, required, schema)])
    Error(error) -> Error(error)
  }
}

fn encode_property(
  name: String,
  codec: Codec(a),
  item: a,
) -> Result(List(#(String, Value)), EncodeError) {
  case encode(codec, item) {
    Ok(raw) -> Ok([#(name, raw)])
    Error(error) -> Error(EncodeAtField(name, error))
  }
}

fn decode_property(
  name: String,
  codec: Codec(a),
  raw: Value,
) -> Result(a, DecodeError) {
  case decode(codec, raw) {
    Ok(item) -> Ok(item)
    Error(error) -> Error(DecodeAtField(name, error))
  }
}

fn lookup(fields: List(#(String, Value)), name: String) -> Optional(Value) {
  case fields {
    [] -> Missing
    [#(key, raw), ..] if key == name -> Present(raw)
    [_, ..rest] -> lookup(rest, name)
  }
}

fn contains(items: List(String), item: String) -> Bool {
  case items {
    [] -> False
    [head, ..] if head == item -> True
    [_, ..rest] -> contains(rest, item)
  }
}

fn overlap(left: List(String), right: List(String)) -> Optional(String) {
  case left {
    [] -> Missing
    [head, ..rest] ->
      case contains(right, head) {
        True -> Present(head)
        False -> overlap(rest, right)
      }
  }
}

fn append(left: List(a), right: List(a)) -> List(a) {
  case left {
    [] -> right
    [head, ..rest] -> [head, ..append(rest, right)]
  }
}

fn check_keys(
  fields: List(#(String, Value)),
  names: List(String),
  seen: List(String),
) -> Result(Nil, DecodeError) {
  case fields {
    [] -> Ok(Nil)
    [#(name, _), ..rest] ->
      case contains(seen, name), contains(names, name) {
        True, _ ->
          Error(DecodeAtField(name, CannotDecode("Duplicate property")))
        _, False -> Error(DecodeAtField(name, CannotDecode("Unknown property")))
        False, True -> check_keys(rest, names, [name, ..seen])
      }
  }
}

fn property_schemas(
  properties: List(PropertySchema),
) -> List(#(String, Value)) {
  case properties {
    [] -> []
    [PropertySchema(name, _, schema), ..rest] -> [
      #(name, schema_value(schema)),
      ..property_schemas(rest)
    ]
  }
}

fn required_names(properties: List(PropertySchema)) -> List(Value) {
  case properties {
    [] -> []
    [PropertySchema(name, True, _), ..rest] -> [
      value.Text(name),
      ..required_names(rest)
    ]
    [_, ..rest] -> required_names(rest)
  }
}
