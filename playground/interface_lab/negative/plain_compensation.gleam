// THROWAWAY: Does a child observation grant compensation authority?
import lab/saga_grind
import lab/saga_run_identity as identity

pub fn invalid(
  owner: saga_grind.DurableOwner,
  completion: saga_grind.DurableChildState(String, String, String),
  command: identity.CommandId,
) {
  saga_grind.request_child_compensation(owner, completion, command)
}
