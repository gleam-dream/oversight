// THROWAWAY: Reject invalid plain compensation composition.
import lab/saga

pub fn invalid(completion: saga.ChildCompletion(String)) {
  saga.request_child_compensation(completion)
}
