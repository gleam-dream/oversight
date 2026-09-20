// THROWAWAY: Token admission limits do not authorize arbitrary bigint expansion.
import lab/json_number

pub fn invalid(
  number: json_number.JsonNumber,
  limits: json_number.NumberLimits,
) {
  json_number.to_int_exact(number, limits)
}
