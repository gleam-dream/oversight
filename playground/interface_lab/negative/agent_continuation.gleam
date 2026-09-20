// THROWAWAY: Can a controller be rebound to a different continuation type?
import lab/fabric_agent

pub fn cannot_change_provider_continuation(
  controller: fabric_agent.Controller(String, Int),
) -> fabric_agent.Controller(String, Bool) {
  controller
}
