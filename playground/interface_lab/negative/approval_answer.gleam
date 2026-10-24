// THROWAWAY: Reject invalid approval answer composition.
import lab/saga_checkpoint as checkpoint

pub fn invalid(
  approval: checkpoint.ApprovalRef(Bool),
  command: checkpoint.CommandId,
) {
  checkpoint.signal(approval, command, "yes")
}
