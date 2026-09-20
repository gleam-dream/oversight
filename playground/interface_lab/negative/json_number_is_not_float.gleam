// THROWAWAY: An exact decimal requires an explicit checked Float projection.
import lab/json_number

pub fn invalid(number: json_number.JsonNumber) -> Float {
  number
}
