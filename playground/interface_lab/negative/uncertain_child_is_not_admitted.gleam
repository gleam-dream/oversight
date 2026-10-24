// THROWAWAY: Can an uncertain commit be used as an admitted child?
import lab/saga_grind

pub fn cannot_observe_uncertain(
  owner: saga_grind.DurableOwner,
  uncertain: saga_grind.UncertainSubmission(Int, String, String),
) {
  saga_grind.observe_child(owner, uncertain)
}
