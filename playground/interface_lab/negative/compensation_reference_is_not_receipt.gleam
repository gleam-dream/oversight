// THROWAWAY: Can a saved routing reference grant compensation authority?
import lab/saga_grind
import lab/saga_run_identity as identity

pub fn invalid(
  owner: saga_grind.DurableOwner,
  reference: saga_grind.DurableCompensationReceiptRef,
  command: identity.CommandId,
) {
  saga_grind.request_child_compensation(owner, reference, command)
}
