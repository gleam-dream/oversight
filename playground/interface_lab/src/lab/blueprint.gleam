// THROWAWAY: Can one bidirectional codec serve independent adapters?
import lab/value.{type Value}

pub type EncodeError {
  CannotEncode(String)
}

pub type DecodeError {
  CannotDecode(String)
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
