import consumers/enum_codec
import lab/blueprint

pub fn invalid() -> Result(
  blueprint.Codec(enum_codec.Priority),
  blueprint.EnumError,
) {
  blueprint.string_enum([#("low", "a string is not a Priority")])
}
