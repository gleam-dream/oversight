// THROWAWAY: Can a host inspect an action under another context type?
import lab/fabric_agent

pub fn cannot_change_context(
  controller: fabric_agent.Controller(String, Nil),
  action: fabric_agent.ActionIdentity,
) {
  fabric_agent.inspect_action(controller, 42, action)
}
