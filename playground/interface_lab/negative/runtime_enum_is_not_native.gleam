import consumers/enum_codec
import lab/blueprint_runtime as runtime

pub fn invalid(value: runtime.ValidatedValue) -> enum_codec.Priority {
  value
}
