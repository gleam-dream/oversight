//// Adapters from one Blueprint codec to the codec types of Grind and Saga,
//// so a value has one wire definition (`domain`, `jobs`, `publish`) and the
//// two durable runtimes only differ in the version they stamp on it.

import gleam/result
import grind/worker
import json/blueprint/codec
import saga/codec as saga_codec

/// A Grind codec. Grind's encoder has no failure channel, so a value the
/// codec cannot encode (a definition mistake) crashes where it is encoded
/// instead of storing a `null` that no decoder accepts.
pub fn grind(version: String, c: codec.Codec(a)) -> worker.Codec(a) {
  let assert Ok(wire) =
    worker.codec(
      version,
      fn(value) {
        case codec.to_json(c, value) {
          Ok(json) -> json
          Error(error) -> panic as codec.describe_encode_error(error)
        }
      },
      codec.decoder(c),
    )
  wire
}

/// A Saga codec: the codec's JSON text, with its errors as readable text.
pub fn saga(version: String, c: codec.Codec(a)) -> saga_codec.Codec(a) {
  saga_codec.new(
    version,
    fn(value) {
      codec.encode_json(c, value)
      |> result.map_error(codec.describe_encode_error)
    },
    fn(text) {
      codec.decode_json(c, text)
      |> result.map_error(codec.describe_decode_error)
    },
  )
}
