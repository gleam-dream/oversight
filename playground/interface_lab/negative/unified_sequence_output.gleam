// THROWAWAY: Reject a typed sequential edge with mismatched adjacent ports.
import lab/saga

pub fn invalid(
  first: saga.Definition(String, Int, Nil, Nil),
  second: saga.Definition(String, String, Nil, Nil),
) {
  saga.and_then("invalid-edge:v1", first, second)
}
