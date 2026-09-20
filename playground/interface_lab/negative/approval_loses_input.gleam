// THROWAWAY: Reject an approval answer that omits the original proposal.
import consumers/approval_context
import lab/saga

pub fn invalid(answer: saga.ApprovalDecision(Bool)) {
  approval_context.decide(answer)
}
