// THROWAWAY: Does successful encoding grant a durable run handle?
import lab/saga_grind

pub fn cannot_observe_prepared(
  owner: saga_grind.DurableOwner,
  prepared: saga_grind.PreparedChild(Int, String, String),
) {
  saga_grind.observe_child(owner, prepared)
}
