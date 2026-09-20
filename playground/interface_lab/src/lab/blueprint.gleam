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
  new(fn(value) { encode(codec, to(value)) }, fn(raw) {
    case decode(codec, raw) {
      Ok(value) -> Ok(from(value))
      Error(error) -> Error(error)
    }
  })
}

pub fn pair(left: Codec(a), right: Codec(b)) -> Codec(#(a, b)) {
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
}

// This deliberately does not claim JSON Schema agreement or codec roundtrip laws.
pub opaque type Codec(a) {
  Codec(
    encoder: fn(a) -> Result(Value, EncodeError),
    decoder: fn(Value) -> Result(a, DecodeError),
  )
}

pub fn new(
  encode: fn(a) -> Result(Value, EncodeError),
  decode: fn(Value) -> Result(a, DecodeError),
) -> Codec(a) {
  Codec(encode, decode)
}

pub fn encode(codec: Codec(a), item: a) -> Result(Value, EncodeError) {
  codec.encoder(item)
}

pub fn decode(codec: Codec(a), item: Value) -> Result(a, DecodeError) {
  codec.decoder(item)
}

pub fn text() -> Codec(String) {
  new(fn(s) { Ok(value.Text(s)) }, fn(v) {
    case v {
      value.Text(s) -> Ok(s)
      _ -> Error(CannotDecode("Expected text"))
    }
  })
}

pub fn int() -> Codec(Int) {
  new(fn(n) { Ok(value.Int(n)) }, fn(v) {
    case v {
      value.Int(n) -> Ok(n)
      _ -> Error(CannotDecode("Expected integer"))
    }
  })
}

pub fn bool() -> Codec(Bool) {
  new(fn(b) { Ok(value.Bool(b)) }, fn(v) {
    case v {
      value.Bool(b) -> Ok(b)
      _ -> Error(CannotDecode("Expected boolean"))
    }
  })
}
