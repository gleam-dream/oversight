// THROWAWAY: Does typed composition retain a conversion between differing codecs?
import lab/blueprint
import lab/saga
import lab/value

fn boxed_text() -> blueprint.Codec(String) {
  blueprint.new(
    fn(text) { Ok(value.Object([#("text", value.Text(text))])) },
    fn(raw) {
      case raw {
        value.Object([#("text", value.Text(text))]) -> Ok(text)
        _ -> Error(blueprint.CannotDecode("Expected boxed text"))
      }
    },
  )
}

fn nil_codec() -> blueprint.Codec(Nil) {
  blueprint.new(fn(_) { Ok(value.Null) }, fn(raw) {
    case raw {
      value.Null -> Ok(Nil)
      _ -> Error(blueprint.CannotDecode("Expected null"))
    }
  })
}

// Literal identities are fixture data. This assembles handlers but executes none.
pub fn example() -> saga.Definition(String, String, Nil, Nil) {
  let assert Ok(version) = saga.version(1)
  let assert Ok(first_id) = saga.step_id("plain")
  let assert Ok(second_id) = saga.step_id("boxed")
  let assert Ok(definition_id) = saga.definition_id("codec-connections")
  let producer =
    saga.activity(
      first_id,
      version,
      saga.ActivityContract(
        saga.VersionedCodec(version, blueprint.text()),
        saga.VersionedCodec(version, blueprint.text()),
        saga.VersionedCodec(version, nil_codec()),
        saga.VersionedCodec(version, nil_codec()),
      ),
      fn(text) { Ok(text) },
      saga.Uncompensated,
    )
  let consumer =
    saga.activity(
      second_id,
      version,
      saga.ActivityContract(
        saga.VersionedCodec(version, boxed_text()),
        saga.VersionedCodec(version, boxed_text()),
        saga.VersionedCodec(version, nil_codec()),
        saga.VersionedCodec(version, nil_codec()),
      ),
      fn(text) { Ok(text) },
      saga.Uncompensated,
    )
  saga.and_then(
    "asserted-plain-to-boxed-v1",
    saga.define(definition_id, version, "asserted-plain-v1", producer),
    saga.define(definition_id, version, "asserted-boxed-v1", consumer),
  )
}
