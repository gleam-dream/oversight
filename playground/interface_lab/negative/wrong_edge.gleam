// THROWAWAY: Reject invalid wrong edge composition.
import lab/saga

pub fn invalid(
  first: saga.Definition(Int, String, Nil, Nil),
  second: saga.Definition(Int, Bool, Nil, Nil),
) {
  saga.and_then("wrong-edge", first, second)
}
