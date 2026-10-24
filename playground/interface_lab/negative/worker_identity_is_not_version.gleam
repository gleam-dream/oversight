// THROWAWAY: Worker names cannot stand in for an exact deployed version.
import lab/grind
import lab/grind_registry

pub fn invalid(
  registry: grind_registry.Registry,
  route: grind.QueueRoute,
  id: grind.WorkerId,
) {
  grind_registry.select(registry, route, id, id)
}
