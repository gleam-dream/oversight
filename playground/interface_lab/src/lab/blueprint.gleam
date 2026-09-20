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
    TextSchema -> value.Object([#("type", value.Text("string"))])
    IntSchema -> value.Object([#("type", value.Text("integer"))])
    BoolSchema -> value.Object([#("type", value.Text("boolean"))])
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
  let codec =
    new(
      fn(item) {
        case encode(inner, item) {
          Ok(raw) -> Ok(value.Object([#(name, raw)]))
          Error(error) -> Error(EncodeAtField(name, error))
        }
      },
      fn(raw) {
        case raw {
          value.Object([#(key, item)]) if key == name ->
            case decode(inner, item) {
              Ok(item) -> Ok(item)
              Error(error) -> Error(DecodeAtField(name, error))
            }
          _ ->
            Error(DecodeAtField(
              name,
              CannotDecode("Expected exactly one named field"),
            ))
        }
      },
    )
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
