// THROWAWAY: Reject invalid handle output composition.
import lab/saga_grind

pub fn invalid(handle: saga_grind.RunHandle(String, Nil, Nil)) -> String {
  handle
}
