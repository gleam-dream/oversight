// THROWAWAY: Can an approval reference itself execute a tool?
import lab/fabric_agent

pub fn cannot_execute_review(reference: fabric_agent.ApprovalReference) {
  fabric_agent.execute_prepared(reference)
}
