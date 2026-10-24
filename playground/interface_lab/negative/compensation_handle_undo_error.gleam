// THROWAWAY: Can asynchronous compensation change its undo-error type?
import lab/saga_grind

pub fn invalid(
  handle: saga_grind.CompensationHandle(Int),
) -> saga_grind.CompensationHandle(String) {
  handle
}
